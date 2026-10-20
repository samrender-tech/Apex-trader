-- =====================================================================
-- Apex Trader :: 011_audit.sql
-- A single generic audit trigger that works on ANY table.
--
-- The trick is that PL/pgSQL can convert NEW/OLD to JSONB with to_jsonb,
-- so one function handles every table rather than one trigger function
-- per table. The changed-field list is computed by diffing the two JSONB
-- documents, which also keeps the log compact for wide tables.
-- =====================================================================

CREATE TABLE audit.activity_log (
    log_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_schema  TEXT NOT NULL,
    table_name    TEXT NOT NULL,
    operation     TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    row_key       TEXT,
    old_row       JSONB,
    new_row       JSONB,
    changed_fields TEXT[],
    -- Who did it, from the session variable the API sets per request.
    acted_by      BIGINT,
    db_user       TEXT NOT NULL DEFAULT current_user,
    client_addr   INET DEFAULT inet_client_addr(),
    txid          BIGINT NOT NULL DEFAULT txid_current(),
    acted_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_audit_table   ON audit.activity_log (table_schema, table_name, acted_at DESC);
CREATE INDEX ix_audit_actor   ON audit.activity_log (acted_by, acted_at DESC);
CREATE INDEX ix_audit_row     ON audit.activity_log (table_name, row_key);
CREATE INDEX ix_audit_changed ON audit.activity_log USING gin (changed_fields);
CREATE INDEX ix_audit_newrow  ON audit.activity_log USING gin (new_row jsonb_path_ops);

-- The audit log is itself append-only, or it is not an audit log.
CREATE OR REPLACE FUNCTION audit.forbid_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.activity_log is append-only (attempted %)', TG_OP
          USING ERRCODE='42501';
END;
$$;
CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON audit.activity_log
    FOR EACH ROW EXECUTE FUNCTION audit.forbid_mutation();

-- ---------------------------------------------------------------------
-- Current actor, read from a session GUC the API sets on checkout:
--   SET LOCAL apex.current_user_id = '42';
-- Returns NULL when run from a maintenance job or raw psql.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.current_actor() RETURNS BIGINT
LANGUAGE plpgsql STABLE AS $$
DECLARE v TEXT;
BEGIN
    v := current_setting('apex.current_user_id', TRUE);   -- TRUE = don't error if unset
    IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
    RETURN v::BIGINT;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------
-- The universal audit trigger.
-- Attach with:  CREATE TRIGGER ... EXECUTE FUNCTION audit.track('pk_col')
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.track() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_old      JSONB;
    v_new      JSONB;
    v_changed  TEXT[];
    v_key_col  TEXT := COALESCE(TG_ARGV[0], NULL);
    v_key      TEXT;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        -- Diff the documents: keep only keys whose value actually moved.
        SELECT array_agg(k ORDER BY k) INTO v_changed
          FROM jsonb_object_keys(v_new) AS k
         WHERE v_new -> k IS DISTINCT FROM v_old -> k;

        -- A no-op UPDATE is noise, not history.
        IF v_changed IS NULL THEN RETURN NULL; END IF;
    END IF;

    IF v_key_col IS NOT NULL THEN
        v_key := COALESCE(v_new, v_old) ->> v_key_col;
    END IF;

    INSERT INTO audit.activity_log
        (table_schema, table_name, operation, row_key,
         old_row, new_row, changed_fields, acted_by)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, v_key,
            v_old, v_new, v_changed, audit.current_actor());

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION audit.track IS
  'One generic AFTER trigger for every audited table. to_jsonb(NEW/OLD) '
  'makes it table-agnostic; the changed-field list is a JSONB diff, so '
  'wide-table updates do not bloat the log.';

-- ---------------------------------------------------------------------
-- Attach to the tables where "who changed this, and when" actually
-- matters. Market data and the ledger are deliberately excluded: ticks
-- are too high-volume, and the ledger is already immutable history.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_audit_user AFTER INSERT OR UPDATE OR DELETE ON identity.app_user
    FOR EACH ROW EXECUTE FUNCTION audit.track('user_id');

CREATE TRIGGER trg_audit_account AFTER INSERT OR UPDATE OR DELETE ON trading.account
    FOR EACH ROW EXECUTE FUNCTION audit.track('account_id');

CREATE TRIGGER trg_audit_order AFTER INSERT OR UPDATE OR DELETE ON trading.trade_order
    FOR EACH ROW EXECUTE FUNCTION audit.track('order_id');

CREATE TRIGGER trg_audit_risk_limit AFTER INSERT OR UPDATE OR DELETE ON risk.risk_limit
    FOR EACH ROW EXECUTE FUNCTION audit.track('account_id');

CREATE TRIGGER trg_audit_instrument AFTER INSERT OR UPDATE OR DELETE ON reference.instrument
    FOR EACH ROW EXECUTE FUNCTION audit.track('instrument_id');

CREATE TRIGGER trg_audit_alert AFTER UPDATE ON surveil.alert
    FOR EACH ROW EXECUTE FUNCTION audit.track('alert_id');

CREATE TRIGGER trg_audit_halt AFTER INSERT OR UPDATE OR DELETE ON risk.trading_halt
    FOR EACH ROW EXECUTE FUNCTION audit.track('halt_id');

-- ---------------------------------------------------------------------
-- Reconstruct the full change history of one row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.row_history(p_table TEXT, p_key TEXT)
RETURNS TABLE (acted_at TIMESTAMPTZ, operation TEXT, acted_by BIGINT,
               actor_email TEXT, changed_fields TEXT[], diff JSONB)
LANGUAGE sql STABLE AS $$
    SELECT l.acted_at, l.operation, l.acted_by, u.email::TEXT, l.changed_fields,
           -- Show only what moved, as {field: {from, to}}.
           CASE WHEN l.operation = 'UPDATE' THEN
               (SELECT jsonb_object_agg(f, jsonb_build_object(
                           'from', l.old_row -> f, 'to', l.new_row -> f))
                  FROM unnest(l.changed_fields) AS f)
                ELSE COALESCE(l.new_row, l.old_row) END
      FROM audit.activity_log l
      LEFT JOIN identity.app_user u ON u.user_id = l.acted_by
     WHERE l.table_name = p_table AND l.row_key = p_key
     ORDER BY l.acted_at, l.log_id;
$$;
