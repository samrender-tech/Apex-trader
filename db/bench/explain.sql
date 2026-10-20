-- =====================================================================
-- Apex Trader :: performance evidence
--
-- Each section below states a claim about the physical design and then
-- proves it with EXPLAIN ANALYZE. Run after seeding:
--     ./scripts/db.sh bench
-- =====================================================================
\timing on
\pset pager off

\echo ''
\echo '####################################################################'
\echo '# 1. PARTITION PRUNING'
\echo '#    Claim: a time-bounded query on a 280k-row partitioned table'
\echo '#    reads ONE partition, not all ten.'
\echo '####################################################################'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT count(*), avg(close)
  FROM market.candle_1m
 WHERE bucket_start >= date_trunc('month', now())
   AND bucket_start <  date_trunc('month', now()) + INTERVAL '1 month';

\echo ''
\echo '--- the same query with NO time predicate reads every partition ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM market.candle_1m;

\echo ''
\echo '####################################################################'
\echo '# 2. THE ORDER BOOK INDEX'
\echo '#    Claim: ix_book_asks serves price-time priority directly, so'
\echo '#    the engine finds top-of-book with an index scan and NO SORT.'
\echo '#    A Sort node here would mean the engine re-sorts the book on'
\echo '#    every single incoming order.'
\echo '####################################################################'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT c.order_id, c.limit_price, c.leaves_qty
  FROM trading.trade_order c
 WHERE c.instrument_id = (SELECT instrument_id FROM reference.instrument WHERE symbol='AAPL')
   AND c.side = 'sell'
   AND c.status IN ('working','partially_filled')
   AND NOT c.stop_armed
   AND c.limit_price IS NOT NULL
 ORDER BY c.limit_price ASC, c.seq_no ASC
 LIMIT 1;

\echo ''
\echo '####################################################################'
\echo '# 3. PARTIAL INDEX SIZE'
\echo '#    Claim: indexing only LIVE orders keeps the book index sized by'
\echo '#    the book, not by order history -- which grows forever.'
\echo '####################################################################'
SELECT
  (SELECT count(*) FROM trading.trade_order)                              AS orders_total,
  (SELECT count(*) FROM trading.trade_order
    WHERE status IN ('working','partially_filled'))                       AS orders_live,
  pg_size_pretty(pg_relation_size('trading.ix_book_asks'))                AS ix_book_asks_size,
  pg_size_pretty(pg_relation_size('trading.ix_order_account'))            AS ix_full_size,
  round(100.0 * (SELECT count(*) FROM trading.trade_order
                  WHERE status IN ('working','partially_filled'))
        / NULLIF((SELECT count(*) FROM trading.trade_order),0), 1)        AS pct_rows_indexed;

\echo ''
\echo '####################################################################'
\echo '# 4. BRIN vs B-TREE on append-only time-series'
\echo '#    Claim: because ticks/candles arrive in timestamp order, BRIN'
\echo '#    gives range-scan pruning at a tiny fraction of the size.'
\echo '####################################################################'
SELECT i.indexrelname AS index_name,
       am.amname      AS index_type,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size,
       i.idx_scan     AS scans
  FROM pg_stat_user_indexes i
  JOIN pg_class c  ON c.oid = i.indexrelid
  JOIN pg_am    am ON am.oid = c.relam
 WHERE i.schemaname = 'market'
 ORDER BY pg_relation_size(i.indexrelid) DESC
 LIMIT 10;

\echo ''
\echo '####################################################################'
\echo '# 5. TRIGRAM SEARCH'
\echo '#    Claim: fuzzy symbol/name search CAN be served by a GIN'
\echo '#    trigram index rather than a LIKE sequential scan.'
\echo '#'
\echo '#    Honest caveat: the demo instrument master holds 16 rows, and'
\echo '#    on 16 rows a sequential scan genuinely IS cheaper -- the'
\echo '#    planner is right to ignore the index. The index earns its'
\echo '#    keep at a realistic universe size (thousands of listings).'
\echo '#    Below, the planner chooses freely first, then we disable'
\echo '#    seq scans to show the index is present and usable.'
\echo '####################################################################'
\echo '--- planner free choice (expect Seq Scan at this table size) ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT symbol, name FROM reference.instrument
 WHERE name ILIKE '%micro%' OR symbol ILIKE '%ms%';

\echo '--- same query, seq scans disabled: the trigram index is used ---'
SET enable_seqscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT symbol, name FROM reference.instrument
 WHERE name ILIKE '%micro%' OR symbol ILIKE '%ms%';
RESET enable_seqscan;

\echo ''
\echo '####################################################################'
\echo '# 6. COVERING INDEX / INDEX-ONLY SCAN'
\echo '#    Claim: INCLUDE columns let the hot instrument listing be'
\echo '#    answered from the index alone (no heap fetches).'
\echo '####################################################################'
\echo '--- planner free choice ---'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT symbol, name, sector FROM reference.instrument
 WHERE is_tradable
   AND exchange_id = (SELECT exchange_id FROM reference.exchange WHERE code='XNAS')
 ORDER BY symbol;

\echo '--- seq scans disabled: Index Only Scan, zero heap fetches ---'
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT symbol, name, sector FROM reference.instrument
 WHERE is_tradable
   AND exchange_id = (SELECT exchange_id FROM reference.exchange WHERE code='XNAS')
 ORDER BY symbol;
RESET enable_seqscan;

\echo ''
\echo '####################################################################'
\echo '# 7. MATERIALIZED VIEW PAYOFF'
\echo '#    Claim: the leaderboard aggregate is materially cheaper to read'
\echo '#    pre-computed than to recompute from snapshots on every page.'
\echo '####################################################################'
\echo '--- reading the materialized view ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM analytics.mv_strategy_leaderboard ORDER BY sharpe_rank LIMIT 10;

\echo '--- recomputing the same thing live ---'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
WITH curve AS (
    SELECT s.strategy_id, sn.as_of, sn.nav,
           lag(sn.nav) OVER (PARTITION BY s.strategy_id ORDER BY sn.as_of) AS prev_nav
      FROM social.strategy s
      JOIN analytics.account_snapshot sn ON sn.account_id = s.source_account_id
)
SELECT strategy_id,
       avg((nav - prev_nav)/NULLIF(prev_nav,0)*100) AS avg_ret,
       stddev_samp((nav - prev_nav)/NULLIF(prev_nav,0)*100) AS vol
  FROM curve GROUP BY strategy_id;

\echo ''
\echo '####################################################################'
\echo '# 8. CANDLE ROLLUP -- 1m base aggregated to any interval'
\echo '####################################################################'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT * FROM market.candles(
    (SELECT instrument_id FROM reference.instrument WHERE symbol='AAPL'),
    INTERVAL '1 hour', now() - INTERVAL '30 days', now());

\echo ''
\echo '####################################################################'
\echo '# 9. STORAGE FOOTPRINT'
\echo '####################################################################'
SELECT * FROM ops.v_table_sizes LIMIT 14;

\echo ''
\echo '####################################################################'
\echo '# 10. UNUSED INDEXES -- write amplification with no read benefit'
\echo '####################################################################'
SELECT table_name, index_name, index_size, times_used, verdict
  FROM ops.v_index_usage WHERE verdict LIKE 'UNUSED%' LIMIT 12;
\timing off
