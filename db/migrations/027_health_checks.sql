-- =====================================================================
-- 027_health_checks.sql
--
-- ops.health_check() is the panel the Compliance tab renders, and its
-- job is to make structural invariants VISIBLE rather than assumed. It
-- covered the ledger, the books and the partition runway. Three things
-- added since are just as capable of breaking quietly, and each one
-- already caused a real defect:
--
--   * a view that bypasses the RLS underneath it (024)
--   * a candle whose provenance would let the tick roller eat loaded
--     history (023)
--   * a resting order priced off its instrument's tick grid (026/023) --
--     which the engine rejects, so a whole book silently empties
--
-- All three share a shape: nothing errors, the screen looks fine, and
-- the invariant is gone. That is exactly what this function is for.
-- =====================================================================

CREATE OR REPLACE FUNCTION ops.health_check()
RETURNS TABLE (category TEXT, check_name TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_n BIGINT; v_d TEXT;
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
    -- ---- security -----------------------------------------------------
    -- A view over user data that runs as its owner reads straight past
    -- the base tables' RLS policies. The policies are still there and
    -- still correct; they are simply never consulted.
    SELECT count(*), string_agg(view_name, ', ')
      INTO v_n, v_d
      FROM ops.assert_rls_intact() WHERE verdict LIKE 'LEAK%';
    RETURN QUERY
    SELECT 'security'::TEXT, 'views_respect_rls'::TEXT,
           CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END::TEXT,
           CASE WHEN v_n = 0
                THEN 'every view over user data runs as the caller'
                ELSE v_n || ' view(s) bypass RLS: ' || v_d END;

    -- ---- market data ---------------------------------------------------
    -- Loaded history must be marked as such, or the ingestion worker's
    -- tick roller will overwrite the tail of it. Only a 24x7 instrument
    -- actually exposes this -- an equity's backfill stops at the previous
    -- close, so the windows never meet -- which is precisely why it went
    -- unnoticed until crypto was listed.
    SELECT count(*) INTO v_n
      FROM reference.instrument i
     WHERE i.trades_24x7
       AND EXISTS (SELECT 1 FROM market.candle_1m c
                    WHERE c.instrument_id = i.instrument_id)
       AND NOT EXISTS (SELECT 1 FROM market.candle_1m c
                        WHERE c.instrument_id = i.instrument_id
                          AND c.source = 'backfill');
    RETURN QUERY
    SELECT 'market'::TEXT, 'history_is_marked_backfill'::TEXT,
           CASE WHEN v_n = 0 THEN 'PASS' ELSE 'ATTENTION' END::TEXT,
           CASE WHEN v_n = 0
                THEN 'loaded history is protected from the tick roller'
                ELSE v_n || ' 24x7 instrument(s) have unmarked history' END;

    -- A mark reports no quantity. If marks are being counted as volume
    -- again, VWAP and the volume-anomaly rule are both measuring noise.
    SELECT count(*) INTO v_n
      FROM market.tick t
     WHERE NOT t.is_trade AND t.volume > 0
       AND t.ts > now() - INTERVAL '1 day';
    RETURN QUERY
    SELECT 'market'::TEXT, 'marks_carry_no_volume'::TEXT,
           CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END::TEXT,
           CASE WHEN v_n = 0 THEN 'reference marks are excluded from volume'
                ELSE v_n || ' non-trade tick(s) carrying volume' END;

    -- ---- microstructure -------------------------------------------------
    -- A price off the tick grid cannot rest: engine.validate_order()
    -- rejects it. One bad rounding rule in a quoting path therefore does
    -- not raise an error anywhere -- it just empties a book.
    SELECT count(*), string_agg(DISTINCT i.symbol, ', ')
      INTO v_n, v_d
      FROM trading.trade_order o
      JOIN reference.instrument i USING (instrument_id)
     WHERE o.status IN ('working', 'partially_filled')
       AND o.limit_price IS NOT NULL
       AND MOD(o.limit_price, i.tick_size) <> 0;
    RETURN QUERY
    SELECT 'market'::TEXT, 'resting_prices_on_tick_grid'::TEXT,
           CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END::TEXT,
           CASE WHEN v_n = 0 THEN 'every resting price is a whole number of ticks'
                ELSE v_n || ' order(s) off-grid: ' || v_d END;

    -- An instrument nobody is quoting is not broken, but it is not
    -- tradable either, and the usual cause is a quoting path that does
    -- not understand this instrument's microstructure.
    SELECT count(*), string_agg(i.symbol, ', ')
      INTO v_n, v_d
      FROM reference.instrument i
     WHERE i.is_tradable
       AND NOT EXISTS (SELECT 1 FROM trading.trade_order o
                        WHERE o.instrument_id = i.instrument_id
                          AND o.status IN ('working', 'partially_filled'));
    RETURN QUERY
    SELECT 'market'::TEXT, 'every_book_has_a_quote'::TEXT,
           CASE WHEN v_n = 0 THEN 'PASS' ELSE 'ATTENTION' END::TEXT,
           CASE WHEN v_n = 0 THEN 'all ' ||
                  (SELECT count(*) FROM reference.instrument WHERE is_tradable) ||
                  ' books are quoted'
                ELSE v_n || ' empty book(s): ' || left(v_d, 120) END;
END;
$$;

COMMENT ON FUNCTION ops.health_check IS
  'Structural invariants, reported rather than assumed. Every check here '
  'corresponds to a defect that produced no error and no visible symptom '
  'until something downstream was already wrong.';
