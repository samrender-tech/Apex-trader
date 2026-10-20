-- =====================================================================
-- Apex Trader :: 014_security.sql
-- Roles, grants and ROW LEVEL SECURITY.
--
-- Multi-tenant isolation is enforced by the DATABASE, not by remembering
-- to add "WHERE user_id = ?" in every query. The API connects as a
-- non-superuser role and sets one session variable per request:
--
--     SET LOCAL apex.current_user_id = '42';
--
-- From that point PostgreSQL itself refuses to return another trader's
-- orders, positions or ledger rows -- even if the application has a SQL
-- injection bug or a developer forgets a predicate. A missing filter
-- becomes an empty result instead of a data breach.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='apex_app') THEN
        -- The API's role. Deliberately NOT superuser and NOT the table
        -- owner: RLS is bypassed by both, which would defeat the point.
        CREATE ROLE apex_app LOGIN PASSWORD 'apex_app_pw';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='apex_compliance') THEN
        CREATE ROLE apex_compliance LOGIN PASSWORD 'apex_compliance_pw';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='apex_readonly') THEN
        CREATE ROLE apex_readonly LOGIN PASSWORD 'apex_readonly_pw';
    END IF;
END $$;

GRANT USAGE ON SCHEMA identity, reference, market, trading, ledger,
                       risk, surveil, social, analytics, engine, audit, ops
   TO apex_app, apex_compliance, apex_readonly;

GRANT SELECT ON ALL TABLES IN SCHEMA reference, market, analytics, ops
   TO apex_app, apex_compliance, apex_readonly;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA identity, trading, social
   TO apex_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA ledger TO apex_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA risk, surveil TO apex_app;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO apex_compliance;
GRANT SELECT, UPDATE ON surveil.alert TO apex_compliance;
GRANT SELECT ON ALL TABLES IN SCHEMA identity, trading, ledger, risk, surveil, social
   TO apex_compliance;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA engine, trading, identity, ledger, social, surveil
   TO apex_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA engine, ledger, risk, market, analytics,
                                       identity, trading, social, surveil, reference, ops
   TO apex_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA analytics, surveil, audit, ledger, risk
   TO apex_compliance;

-- Future tables inherit these grants automatically.
ALTER DEFAULT PRIVILEGES IN SCHEMA reference, market, analytics
    GRANT SELECT ON TABLES TO apex_app, apex_readonly, apex_compliance;

-- ---------------------------------------------------------------------
-- Session context helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION identity.current_user_id() RETURNS BIGINT
LANGUAGE plpgsql STABLE AS $$
DECLARE v TEXT;
BEGIN
    v := current_setting('apex.current_user_id', TRUE);
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    RETURN v::BIGINT;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$;

-- A compliance officer or admin sees everything; a trader sees only
-- their own rows. The role is read from the database, not from the
-- client, so a client cannot claim to be compliance.
--
-- SECURITY DEFINER is REQUIRED here, not a convenience. This function
-- reads identity.app_user, and identity.app_user has an RLS policy that
-- calls this function -- so without SECURITY DEFINER the policy recurses
-- into itself and PostgreSQL aborts with "stack depth limit exceeded"
-- the moment anyone reads their own profile. Running as the definer
-- bypasses RLS for this one narrow lookup, which is exactly the standard
-- way to write an RLS predicate helper.
CREATE OR REPLACE FUNCTION identity.current_user_is_privileged() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(
        (SELECT u.role IN ('compliance','admin')
           FROM identity.app_user u
          WHERE u.user_id = identity.current_user_id()),
        FALSE)
    -- SESSION_USER, never CURRENT_USER.
    --
    -- Inside a SECURITY DEFINER function current_user is the function's
    -- OWNER. The owner here is a superuser, and pg_has_role() reports a
    -- superuser as a member of EVERY role -- so current_user would make
    -- this predicate return TRUE for every caller and silently disable
    -- Row Level Security across the whole database.
    --
    -- session_user stays the role that actually connected (apex_app for
    -- the API), so this escape hatch only fires for a direct connection
    -- as apex_compliance, which is what it is for.
    OR pg_has_role(session_user, 'apex_compliance', 'MEMBER');
$$;

-- =====================================================================
-- RLS POLICIES
-- =====================================================================

-- ---- Users: you see yourself; compliance sees everyone -------------
ALTER TABLE identity.app_user ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_user_self ON identity.app_user;
CREATE POLICY p_user_self ON identity.app_user FOR SELECT
    USING (user_id = identity.current_user_id() OR identity.current_user_is_privileged());
DROP POLICY IF EXISTS p_user_update_self ON identity.app_user;
CREATE POLICY p_user_update_self ON identity.app_user FOR UPDATE
    USING (user_id = identity.current_user_id() OR identity.current_user_is_privileged());
-- Registration happens before a session exists, so INSERT stays open;
-- the unique email index is what prevents abuse here.
DROP POLICY IF EXISTS p_user_insert ON identity.app_user;
CREATE POLICY p_user_insert ON identity.app_user FOR INSERT WITH CHECK (TRUE);

-- ---- Sessions ------------------------------------------------------
ALTER TABLE identity.user_session ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_session_own ON identity.user_session;
CREATE POLICY p_session_own ON identity.user_session FOR ALL
    USING (user_id = identity.current_user_id() OR identity.current_user_is_privileged())
    WITH CHECK (user_id = identity.current_user_id());

-- ---- Accounts ------------------------------------------------------
ALTER TABLE trading.account ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_account_own ON trading.account;
CREATE POLICY p_account_own ON trading.account FOR SELECT
    USING (user_id = identity.current_user_id()
           OR is_system                                 -- system accounts are public plumbing
           OR identity.current_user_is_privileged());
DROP POLICY IF EXISTS p_account_insert ON trading.account;
CREATE POLICY p_account_insert ON trading.account FOR INSERT
    WITH CHECK (user_id = identity.current_user_id() OR identity.current_user_is_privileged());

-- ---- Orders --------------------------------------------------------
ALTER TABLE trading.trade_order ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_order_own ON trading.trade_order;
CREATE POLICY p_order_own ON trading.trade_order FOR SELECT
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));
DROP POLICY IF EXISTS p_order_insert ON trading.trade_order;
CREATE POLICY p_order_insert ON trading.trade_order FOR INSERT
    WITH CHECK (identity.current_user_is_privileged()
                OR account_id IN (SELECT a.account_id FROM trading.account a
                                   WHERE a.user_id = identity.current_user_id()));
DROP POLICY IF EXISTS p_order_update ON trading.trade_order;
CREATE POLICY p_order_update ON trading.trade_order FOR UPDATE
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));

-- ---- Positions, balances, snapshots --------------------------------
ALTER TABLE trading.position ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_position_own ON trading.position;
CREATE POLICY p_position_own ON trading.position FOR SELECT
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));

ALTER TABLE ledger.balance ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_balance_own ON ledger.balance;
CREATE POLICY p_balance_own ON ledger.balance FOR SELECT
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));

ALTER TABLE ledger.posting ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_posting_own ON ledger.posting;
CREATE POLICY p_posting_own ON ledger.posting FOR SELECT
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));
DROP POLICY IF EXISTS p_posting_insert ON ledger.posting;
CREATE POLICY p_posting_insert ON ledger.posting FOR INSERT WITH CHECK (TRUE);

ALTER TABLE analytics.account_snapshot ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_snapshot_own ON analytics.account_snapshot;
CREATE POLICY p_snapshot_own ON analytics.account_snapshot FOR SELECT
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));

-- ---- Risk limits ---------------------------------------------------
ALTER TABLE risk.risk_limit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_risklimit_own ON risk.risk_limit;
CREATE POLICY p_risklimit_own ON risk.risk_limit FOR SELECT
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()));
-- Only compliance may loosen a limit. A trader raising their own risk
-- cap is exactly the thing this prevents.
DROP POLICY IF EXISTS p_risklimit_admin ON risk.risk_limit;
CREATE POLICY p_risklimit_admin ON risk.risk_limit FOR UPDATE
    USING (identity.current_user_is_privileged());

-- ---- Surveillance alerts: compliance only --------------------------
ALTER TABLE surveil.alert ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_alert_compliance ON surveil.alert;
CREATE POLICY p_alert_compliance ON surveil.alert FOR ALL
    USING (identity.current_user_is_privileged());

-- ---- Strategies: public ones are visible to all --------------------
ALTER TABLE social.strategy ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_strategy_visible ON social.strategy;
CREATE POLICY p_strategy_visible ON social.strategy FOR SELECT
    USING (visibility = 'public'
           OR owner_user_id = identity.current_user_id()
           OR identity.current_user_is_privileged()
           OR (visibility = 'followers'
               AND EXISTS (SELECT 1 FROM social.follow f
                            WHERE f.strategy_id = social.strategy.strategy_id
                              AND f.follower_user_id = identity.current_user_id())));
DROP POLICY IF EXISTS p_strategy_own_write ON social.strategy;
CREATE POLICY p_strategy_own_write ON social.strategy FOR ALL
    USING (owner_user_id = identity.current_user_id())
    WITH CHECK (owner_user_id = identity.current_user_id());

ALTER TABLE social.copy_subscription ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_sub_own ON social.copy_subscription;
CREATE POLICY p_sub_own ON social.copy_subscription FOR ALL
    USING (identity.current_user_is_privileged()
           OR account_id IN (SELECT a.account_id FROM trading.account a
                              WHERE a.user_id = identity.current_user_id()))
    WITH CHECK (account_id IN (SELECT a.account_id FROM trading.account a
                                WHERE a.user_id = identity.current_user_id()));

-- ---------------------------------------------------------------------
-- The matching engine and the ledger writer run as SECURITY DEFINER so
-- they can touch the counterparty's rows during a fill -- a buyer's
-- order must be allowed to update a stranger's resting sell order. The
-- functions are the only sanctioned way to cross that boundary, which
-- is precisely why the privilege lives in them and not in the role.
-- ---------------------------------------------------------------------
ALTER FUNCTION engine.submit_order(BIGINT,INTEGER,trading.order_side,trading.order_kind,
                                   qty_amt,NUMERIC,NUMERIC,trading.time_in_force,
                                   NUMERIC,NUMERIC,UUID,BIGINT,BIGINT) SECURITY DEFINER;
ALTER FUNCTION engine.match_order(BIGINT)                SECURITY DEFINER;
ALTER FUNCTION engine.settle_fill(INTEGER,BIGINT,BIGINT,price_amt,qty_amt,trading.order_side)
                                                         SECURITY DEFINER;
ALTER FUNCTION engine.cancel_order(BIGINT,BIGINT)        SECURITY DEFINER;
ALTER FUNCTION engine.refresh_top_of_book(INTEGER)       SECURITY DEFINER;
ALTER FUNCTION engine.elect_stops(INTEGER)               SECURITY DEFINER;
ALTER FUNCTION ledger.post_entry(ledger.entry_kind,TEXT,ledger.leg[],TEXT,BIGINT,
                                 TIMESTAMPTZ,BIGINT)     SECURITY DEFINER;
ALTER FUNCTION identity.authenticate(TEXT,TEXT,INET,TEXT) SECURITY DEFINER;
ALTER FUNCTION trading.apply_fill_to_position(BIGINT,INTEGER,money_amt,price_amt) SECURITY DEFINER;
ALTER FUNCTION social.process_copy_queue(INTEGER)        SECURITY DEFINER;

-- SECURITY DEFINER functions must never trust a caller-supplied
-- search_path, or a caller could shadow a table name and hijack the
-- function's privileges. Pinning it closes that hole.
DO $$
DECLARE v_fn TEXT;
BEGIN
    FOR v_fn IN
        SELECT format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosecdef
           AND n.nspname IN ('engine','ledger','identity','trading','social','audit','risk')
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, public, '
                       'engine, ledger, trading, identity, reference, market, '
                       'risk, social, surveil, analytics, audit, ops', v_fn);
    END LOOP;
END $$;
