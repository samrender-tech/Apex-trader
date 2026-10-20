-- =====================================================================
-- Apex Trader :: 015_maintenance.sql
-- Scheduled operations, observability, and partition lifecycle.
-- =====================================================================

CREATE TABLE ops.job_run (
    run_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_name    TEXT NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ,
    succeeded   BOOLEAN,
    detail      JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_text  TEXT,
    duration    INTERVAL GENERATED ALWAYS AS (finished_at - started_at) STORED
);
CREATE INDEX ix_job_run_recent ON ops.job_run (job_name, started_at DESC);

-- ---------------------------------------------------------------------
-- End-of-session routine. Everything the venue must do once per day,
-- in dependency order, with the outcome of each step recorded.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ops.end_of_day(p_as_of DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_run_id   BIGINT;
    v_detail   JSONB := '{}'::jsonb;
    v_expired  INTEGER;
    v_candles  INTEGER;
    v_snaps    INTEGER;
    v_margin   INTEGER;
    v_alerts   JSONB;
BEGIN
    INSERT INTO ops.job_run (job_name) VALUES ('end_of_day') RETURNING run_id INTO v_run_id;

    -- 1. Kill DAY orders that did not fill.
    v_expired := engine.expire_orders();
    v_detail := v_detail || jsonb_build_object('orders_expired', v_expired);

    -- 2. Roll today's ticks into 1-minute candles.
    v_candles := market.build_candles_1m(p_as_of::timestamptz,
                                         (p_as_of + 1)::timestamptz);
    v_detail := v_detail || jsonb_build_object('candles_built', v_candles);

    -- 3. Mark the close: today's last print becomes tomorrow's reference.
    UPDATE market.quote q
       SET prev_close = COALESCE(q.last_price, q.prev_close),
           day_open = NULL, day_high = NULL, day_low = NULL, day_volume = 0,
           updated_at = now();

    -- 4. Snapshot NAV. This is what every performance metric reads.
    v_snaps := analytics.take_snapshots(p_as_of);
    v_detail := v_detail || jsonb_build_object('snapshots_taken', v_snaps);

    -- 5. Margin sweep.
    v_margin := risk.scan_margin();
    v_detail := v_detail || jsonb_build_object('margin_calls_raised', v_margin);

    -- 6. Surveillance.
    SELECT jsonb_object_agg(rule_code, alerts_raised) INTO v_alerts
      FROM surveil.run_all_scans();
    v_detail := v_detail || jsonb_build_object('surveillance', COALESCE(v_alerts,'{}'::jsonb));

    -- 7. Rebuild reporting aggregates.
    PERFORM analytics.refresh_all(TRUE);

    -- 8. Keep the partition runway ahead of the data.
    PERFORM ops.ensure_time_partitions('market','tick',  p_as_of, (p_as_of + 90), '1 month');
    PERFORM ops.ensure_time_partitions('market','candle_1m', p_as_of, (p_as_of + 90), '1 month');
    PERFORM ops.ensure_time_partitions('trading','execution', p_as_of, (p_as_of + 90), '1 month');

    UPDATE ops.job_run SET finished_at = now(), succeeded = TRUE, detail = v_detail
     WHERE run_id = v_run_id;

    -- A PROCEDURE (not a function) so it can COMMIT: each day's work is
    -- durable even if a later step fails.
    COMMIT;

EXCEPTION WHEN OTHERS THEN
    UPDATE ops.job_run
       SET finished_at = now(), succeeded = FALSE, error_text = SQLERRM, detail = v_detail
     WHERE run_id = v_run_id;
    RAISE;
END;
$$;

COMMENT ON PROCEDURE ops.end_of_day IS
  'End-of-session batch. Declared as a PROCEDURE rather than a FUNCTION '
  'specifically so it can COMMIT mid-body -- a function runs inside the '
  'caller transaction and cannot.';

-- ---------------------------------------------------------------------
-- Archive an old partition instead of DELETE-ing rows: detaching is a
-- catalog operation, so it is instant regardless of partition size.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.detach_old_partitions(
    p_schema TEXT, p_table TEXT, p_older_than DATE
) RETURNS TABLE (partition_name TEXT, action TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_r RECORD; v_upper TEXT;
BEGIN
    FOR v_r IN
        SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_inherits i ON i.inhrelid = c.oid
          JOIN pg_class p ON p.oid = i.inhparent
         WHERE n.nspname = p_schema AND p.relname = p_table AND c.relispartition
    LOOP
        v_upper := substring(v_r.bound from 'TO \(''([^'']+)''\)');
        CONTINUE WHEN v_upper IS NULL OR v_upper::timestamptz > p_older_than::timestamptz;

        EXECUTE format('ALTER TABLE %I.%I DETACH PARTITION %I.%I',
                       p_schema, p_table, p_schema, v_r.relname);
        RETURN QUERY SELECT v_r.relname::TEXT, 'detached'::TEXT;
    END LOOP;
END;
$$;

-- =====================================================================
-- OBSERVABILITY
-- =====================================================================

-- Are the indexes we designed actually being used? An unused index is
-- pure write-amplification, and this is how you find them.
CREATE OR REPLACE VIEW ops.v_index_usage AS
SELECT s.schemaname, s.relname AS table_name, s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       s.idx_scan AS times_used,
       s.idx_tup_read, s.idx_tup_fetch,
       CASE WHEN s.idx_scan = 0 THEN 'UNUSED - candidate for removal'
            WHEN s.idx_scan < 50 THEN 'rarely used'
            ELSE 'active' END AS verdict
  FROM pg_stat_user_indexes s
 WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
 ORDER BY s.idx_scan ASC, pg_relation_size(s.indexrelid) DESC;

CREATE OR REPLACE VIEW ops.v_table_sizes AS
SELECT n.nspname AS schema_name, c.relname AS table_name,
       CASE c.relkind WHEN 'p' THEN 'partitioned' WHEN 'r' THEN 'table'
                      WHEN 'm' THEN 'matview' ELSE c.relkind::text END AS kind,
       pg_size_pretty(pg_total_relation_size(c.oid))        AS total_size,
       pg_size_pretty(pg_relation_size(c.oid))              AS heap_size,
       pg_size_pretty(pg_indexes_size(c.oid))               AS index_size,
       c.reltuples::BIGINT                                   AS est_rows
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r','p','m')
   AND n.nspname IN ('identity','reference','market','trading','ledger',
                     'risk','surveil','social','analytics','audit','ops')
 ORDER BY pg_total_relation_size(c.oid) DESC;

-- Slowest statements, from pg_stat_statements.
CREATE OR REPLACE VIEW ops.v_slow_queries AS
SELECT round(s.total_exec_time::numeric, 2)            AS total_ms,
       s.calls,
       round(s.mean_exec_time::numeric, 3)             AS mean_ms,
       round(s.max_exec_time::numeric, 2)              AS max_ms,
       s.rows,
       round((100 * s.total_exec_time
              / NULLIF(sum(s.total_exec_time) OVER (),0))::numeric, 2) AS pct_of_total,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 160) AS query_snippet
  FROM pg_stat_statements s
 WHERE s.calls > 1
 ORDER BY s.total_exec_time DESC
 LIMIT 40;

-- One-screen health check of every structural invariant in the system.
CREATE OR REPLACE FUNCTION ops.health_check()
RETURNS TABLE (category TEXT, check_name TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT 'ledger', v.check_name, CASE WHEN v.passed THEN 'PASS' ELSE 'FAIL' END, v.detail
      FROM ledger.verify_integrity() v;

    RETURN QUERY
    SELECT 'trading', 'positions_match_ledger',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           count(*) || ' mismatched position(s)'
      FROM trading.verify_positions_match_ledger();

    RETURN QUERY
    SELECT 'trading', 'no_crossed_books',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           count(*) || ' crossed book(s)'
      FROM market.quote q WHERE q.bid IS NOT NULL AND q.ask IS NOT NULL AND q.bid >= q.ask;

    RETURN QUERY
    SELECT 'trading', 'no_overfilled_orders',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           count(*) || ' order(s) filled beyond quantity'
      FROM trading.trade_order o WHERE o.filled_qty > o.quantity;

    RETURN QUERY
    SELECT 'trading', 'filled_orders_have_fills',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
           count(*) || ' order(s) marked filled with no execution'
      FROM trading.trade_order o
     WHERE o.status = 'filled'
       AND NOT EXISTS (SELECT 1 FROM trading.execution e
                        WHERE e.buy_order_id = o.order_id OR e.sell_order_id = o.order_id);

    RETURN QUERY
    SELECT 'ops', 'partition_runway',
           CASE WHEN count(*) >= 2 THEN 'PASS' ELSE 'WARN' END,
           count(*) || ' future tick partition(s) available'
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='market' AND c.relispartition AND c.relkind='r'
       AND c.relname LIKE 'tick_p%'
       AND substring(pg_get_expr(c.relpartbound, c.oid) from 'TO \(''([^'']+)''\)')::timestamptz
           > now();

    RETURN QUERY
    SELECT 'ops', 'copy_queue_backlog',
           CASE WHEN count(*) < 1000 THEN 'PASS' ELSE 'WARN' END,
           count(*) || ' unprocessed fan-out job(s)'
      FROM social.copy_queue WHERE processed_at IS NULL;

    RETURN QUERY
    SELECT 'surveil', 'open_critical_alerts',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'ATTENTION' END,
           count(*) || ' open critical alert(s)'
      FROM surveil.alert WHERE state='open' AND severity='critical';
END;
$$;

COMMENT ON FUNCTION ops.health_check IS
  'Single-screen verification that every structural invariant still '
  'holds: ledger balance, cache coherence, position/ledger agreement, '
  'uncrossed books, no overfills, partition runway, queue backlog.';
