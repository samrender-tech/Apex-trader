-- =====================================================================
-- 028_mark_divergence.sql
--
-- A VENUE AND ITS FEED CAN BE TWO DIFFERENT PRICE UNIVERSES
--
-- market.quote carries two prices that mean different things:
--
--   last_price      what last traded HERE, discovered by our own engine
--   reference_price the external mark, written by the ingestion worker
--
-- Keeping them separate is deliberate (see 01-architecture.md): a feed
-- must never be able to claim a trade happened at a price nobody traded.
--
-- But engine.validate_order() anchors the price band on reference_price,
-- so the two are not independent in practice. If the external mark walks
-- away from the venue's own tape, the band walks with it and stops
-- containing the order book -- at which point every order on that book
-- is rejected as "outside the band".
--
-- That is not hypothetical. Seed the demo from the SIMULATOR, whose META
-- trades around $335, then start the API on a LIVE feed where META is
-- $709, and the band becomes [567, 851] around a book sitting at 335.
-- Nothing errors. Nothing is corrupt. The venue just silently stops
-- accepting trades, and the only visible symptom is a rejection message
-- quoting a band that looks arbitrary.
--
-- Two defences are in place upstream: the seeder anchors its synthetic
-- history to the live provider's current price, and the ingestion worker
-- refuses a mark more than 50% away from the venue's own last trade.
-- This makes the condition itself checkable, so it cannot sit unnoticed
-- in a database that predates either of them.
-- =====================================================================

CREATE OR REPLACE FUNCTION market.mark_divergence(p_limit NUMERIC DEFAULT 0.25)
RETURNS TABLE (symbol TEXT, venue_last price_amt, feed_mark price_amt,
               divergence_pct NUMERIC, band_contains_book BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT i.symbol::TEXT,
           q.last_price,
           q.reference_price,
           round(abs(q.reference_price - q.last_price)
                 / NULLIF(q.last_price, 0) * 100, 2),
           -- The question that actually matters: can anything on this
           -- book still be priced inside the band?
           COALESCE(
             q.last_price BETWEEN q.reference_price * (1 - i.price_band_pct/100.0)
                              AND q.reference_price * (1 + i.price_band_pct/100.0),
             TRUE)
      FROM market.quote q
      JOIN reference.instrument i USING (instrument_id)
     WHERE q.last_price IS NOT NULL
       AND q.reference_price IS NOT NULL
       AND q.last_price > 0
       AND abs(q.reference_price - q.last_price) / q.last_price > p_limit
     ORDER BY abs(q.reference_price - q.last_price) / q.last_price DESC;
$$;

COMMENT ON FUNCTION market.mark_divergence(NUMERIC) IS
  'Instruments whose external mark has walked away from this venue''s own '
  'last traded price. Because the price band is anchored on the mark, a '
  'large divergence makes the band exclude the order book and every order '
  'in that instrument is rejected.';

GRANT EXECUTE ON FUNCTION market.mark_divergence(NUMERIC)
      TO apex_app, apex_compliance, apex_readonly;

-- ---------------------------------------------------------------------
-- Report it alongside the other structural invariants.
--
-- 027's checks move into health_check_core() verbatim and health_check()
-- becomes core + this one. Appending to a 150-line function body by
-- copy-paste is how the two drift.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.health_check_core()
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


CREATE OR REPLACE FUNCTION ops.health_check()
RETURNS TABLE (category TEXT, check_name TEXT, status TEXT, detail TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_n BIGINT; v_d TEXT;
BEGIN
    RETURN QUERY SELECT * FROM ops.health_check_core();

    SELECT count(*), string_agg(d.symbol, ', ')
      INTO v_n, v_d
      FROM market.mark_divergence(0.25) d
     WHERE NOT d.band_contains_book;
    RETURN QUERY
    SELECT 'market'::TEXT, 'bands_contain_their_books'::TEXT,
           CASE WHEN v_n = 0 THEN 'PASS' ELSE 'FAIL' END::TEXT,
           CASE WHEN v_n = 0
                THEN 'every price band still contains its own order book'
                ELSE v_n || ' instrument(s) untradable -- the external mark has '
                     'left the venue''s own price behind: ' || left(v_d, 90) ||
                     '. Reseed to re-anchor: scripts/seed.py --reset' END;
END;
$$;
