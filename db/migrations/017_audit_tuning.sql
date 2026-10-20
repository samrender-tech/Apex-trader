-- =====================================================================
-- Apex Trader :: 017_audit_tuning.sql
-- Cut audit write-amplification out of the order hot path.
--
-- MEASURED PROBLEM: one order took 35.7ms, of which 24.7ms was the audit
-- trigger -- roughly 70% of order latency spent writing an audit trail
-- nobody was reading.
--
-- Two causes, both found with ops.v_index_usage (which exists for exactly
-- this) and audit.activity_log itself:
--
--   1. ix_audit_newrow, a 744 kB GIN index over the whole new_row JSONB
--      document, had been scanned ZERO times. GIN insert cost is high --
--      it tokenises every key and value on every write -- so this was
--      pure write amplification with no read benefit.
--
--   2. Every order wrote FOUR audit rows: the INSERT plus three UPDATEs
--      as the matching engine advanced filled_qty and status. 205 of 210
--      recorded UPDATEs changed nothing but `status`.
--
-- The fix for (2) is a judgement about what an audit log is FOR. It
-- should record DECISIONS -- who placed, amended, rejected or cancelled
-- an order -- not the engine's internal progress through a match. The
-- fill-by-fill detail is already in trading.execution, which is immutable,
-- partitioned, and strictly more precise (price, size, counterparty, fee
-- and the settling journal entry per fill).
--
-- Nothing of compliance value is lost. What survives: order creation,
-- every terminal state, rejections with their reason, and any amendment
-- of economic terms.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Drop the unused GIN index.
--
-- An audit log is queried as "the history of row X" or "what did user Y
-- do", which ix_audit_row and ix_audit_actor serve. Containment search
-- across every column of every audited table is not how anyone reads it.
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS audit.ix_audit_newrow;
DROP INDEX IF EXISTS audit.ix_audit_changed;

-- A BRIN index on the timestamp replaces them for the one access pattern
-- that does matter at scale -- "show me everything from this window" --
-- at a tiny fraction of the write cost, because the log is append-only
-- and therefore perfectly correlated with time.
CREATE INDEX IF NOT EXISTS ix_audit_time_brin
    ON audit.activity_log USING brin (acted_at);

-- ---------------------------------------------------------------------
-- 2. Stop auditing intermediate matching state.
--
-- A trigger WHEN clause is evaluated by PostgreSQL BEFORE the trigger
-- function is called, so a skipped row costs nothing -- no function
-- call, no to_jsonb(), no insert.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_audit_order ON trading.trade_order;

CREATE TRIGGER trg_audit_order_write
    AFTER INSERT OR DELETE ON trading.trade_order
    FOR EACH ROW EXECUTE FUNCTION audit.track('order_id');

CREATE TRIGGER trg_audit_order_material
    AFTER UPDATE ON trading.trade_order
    FOR EACH ROW
    WHEN (
        -- a terminal outcome: the thing a regulator asks about
        (OLD.status IS DISTINCT FROM NEW.status
         AND NEW.status IN ('rejected','cancelled','expired','filled'))
        -- or an amendment of the order's economic terms
        OR OLD.quantity      IS DISTINCT FROM NEW.quantity
        OR OLD.limit_price   IS DISTINCT FROM NEW.limit_price
        OR OLD.stop_price    IS DISTINCT FROM NEW.stop_price
        OR OLD.account_id    IS DISTINCT FROM NEW.account_id
        OR OLD.reject_reason IS DISTINCT FROM NEW.reject_reason
    )
    EXECUTE FUNCTION audit.track('order_id');

COMMENT ON TRIGGER trg_audit_order_material ON trading.trade_order IS
  'Audits decisions, not the engine''s progress. Partial-fill churn is '
  'deliberately excluded: trading.execution already records every fill '
  'immutably and in more detail.';
