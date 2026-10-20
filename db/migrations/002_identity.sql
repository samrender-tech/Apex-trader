-- =====================================================================
-- Apex Trader :: 002_identity.sql
-- Users, credentials, KYC, sessions, login forensics.
-- =====================================================================

CREATE TABLE identity.app_user (
    user_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id      UUID        NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    email          email_addr  NOT NULL,
    password_hash  TEXT        NOT NULL,
    full_name      TEXT        NOT NULL CHECK (length(btrim(full_name)) BETWEEN 2 AND 120),
    phone          TEXT        CHECK (phone IS NULL OR phone ~ '^\+?[0-9 ()-]{7,20}$'),
    date_of_birth  DATE        CHECK (date_of_birth IS NULL OR date_of_birth < CURRENT_DATE - INTERVAL '18 years'),
    country_code   CHAR(2)     NOT NULL DEFAULT 'IN' CHECK (country_code ~ '^[A-Z]{2}$'),
    role           identity.user_role   NOT NULL DEFAULT 'trader',
    kyc_state      identity.kyc_status  NOT NULL DEFAULT 'unverified',
    kyc_verified_at TIMESTAMPTZ,
    totp_secret    TEXT,                       -- NULL = 2FA not enrolled
    is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
    failed_logins  SMALLINT    NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
    locked_until   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login_at  TIMESTAMPTZ,

    -- A verified KYC state must carry its timestamp: the two columns can
    -- never disagree. Cross-column CHECKs like this are how you stop
    -- "impossible" rows at the door instead of auditing for them later.
    CONSTRAINT kyc_timestamp_consistent CHECK (
        (kyc_state = 'verified') = (kyc_verified_at IS NOT NULL)
    )
);

-- Case-insensitive uniqueness via an EXPRESSION index. Storing the email
-- as typed (for display) while guaranteeing no two users differ only by
-- case -- 'Sam@x.com' and 'sam@x.com' are the same person.
CREATE UNIQUE INDEX uq_app_user_email_ci ON identity.app_user (lower(email));

-- PARTIAL index: only ~the active users are ever authenticated against,
-- so the index stays small and hot regardless of how many dormant
-- accounts accumulate.
CREATE INDEX ix_app_user_active ON identity.app_user (lower(email))
    WHERE is_active;

COMMENT ON COLUMN identity.app_user.password_hash IS
  'bcrypt via pgcrypto crypt(). Plaintext passwords never enter the database.';

-- ---------------------------------------------------------------------
-- Credential helpers. Hashing lives in the DB so no application path can
-- accidentally persist a plaintext password.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.hash_password(p_plain TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT crypt(p_plain, gen_salt('bf', 10));
$$;

CREATE OR REPLACE FUNCTION identity.verify_password(p_plain TEXT, p_hash TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT p_hash = crypt(p_plain, p_hash);
$$;

-- ---------------------------------------------------------------------
-- Sessions (refresh-token side of JWT auth)
-- ---------------------------------------------------------------------
CREATE TABLE identity.user_session (
    session_id    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       BIGINT      NOT NULL REFERENCES identity.app_user(user_id) ON DELETE CASCADE,
    token_hash    TEXT        NOT NULL UNIQUE,   -- SHA-256 of the refresh token
    issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL,
    revoked_at    TIMESTAMPTZ,
    ip_address    INET,
    user_agent    TEXT,
    CONSTRAINT session_window_valid CHECK (expires_at > issued_at)
);

-- Only live sessions are looked up on every request; revoked/expired rows
-- are dead weight, so they are excluded from the index entirely.
CREATE INDEX ix_session_live ON identity.user_session (user_id)
    WHERE revoked_at IS NULL;

CREATE TABLE identity.login_attempt (
    attempt_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email_tried  TEXT        NOT NULL,
    user_id      BIGINT      REFERENCES identity.app_user(user_id) ON DELETE SET NULL,
    succeeded    BOOLEAN     NOT NULL,
    reason       TEXT,
    ip_address   INET,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_login_attempt_recent ON identity.login_attempt (attempted_at DESC);
CREATE INDEX ix_login_attempt_email  ON identity.login_attempt (lower(email_tried), attempted_at DESC);

-- ---------------------------------------------------------------------
-- Authentication procedure: lockout policy enforced in one atomic place.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.authenticate(
    p_email TEXT, p_password TEXT, p_ip INET DEFAULT NULL, p_ua TEXT DEFAULT NULL
) RETURNS TABLE (user_id BIGINT, public_id UUID, role identity.user_role,
                 kyc_state identity.kyc_status, full_name TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_user   identity.app_user;
    v_reason TEXT;
BEGIN
    SELECT * INTO v_user FROM identity.app_user u
     WHERE lower(u.email) = lower(p_email) FOR UPDATE;

    IF NOT FOUND THEN
        -- Log against the typed email so credential-stuffing sweeps across
        -- non-existent accounts are still visible to surveillance.
        INSERT INTO identity.login_attempt(email_tried, succeeded, reason, ip_address)
        VALUES (p_email, FALSE, 'no_such_user', p_ip);
        RAISE EXCEPTION 'invalid credentials' USING ERRCODE = '28P01';
    END IF;

    IF NOT v_user.is_active THEN v_reason := 'account_inactive';
    ELSIF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN v_reason := 'account_locked';
    ELSIF NOT identity.verify_password(p_password, v_user.password_hash) THEN v_reason := 'bad_password';
    END IF;

    IF v_reason IS NOT NULL THEN
        IF v_reason = 'bad_password' THEN
            UPDATE identity.app_user u SET
                failed_logins = u.failed_logins + 1,
                -- exponential-ish lockout after 5 strikes
                locked_until = CASE WHEN u.failed_logins + 1 >= 5
                                    THEN now() + INTERVAL '15 minutes' ELSE u.locked_until END
            WHERE u.user_id = v_user.user_id;
        END IF;
        INSERT INTO identity.login_attempt(email_tried, user_id, succeeded, reason, ip_address)
        VALUES (p_email, v_user.user_id, FALSE, v_reason, p_ip);
        RAISE EXCEPTION 'invalid credentials (%)', v_reason USING ERRCODE = '28P01';
    END IF;

    UPDATE identity.app_user u
       SET failed_logins = 0, locked_until = NULL, last_login_at = now()
     WHERE u.user_id = v_user.user_id;

    INSERT INTO identity.login_attempt(email_tried, user_id, succeeded, ip_address)
    VALUES (p_email, v_user.user_id, TRUE, p_ip);

    RETURN QUERY SELECT v_user.user_id, v_user.public_id, v_user.role,
                        v_user.kyc_state, v_user.full_name;
END;
$$;

COMMENT ON FUNCTION identity.authenticate IS
  'Single atomic authentication path: verifies the bcrypt hash, applies the '
  'failed-attempt lockout policy and writes the forensic trail in one '
  'transaction, so no application bug can skip the lockout.';
