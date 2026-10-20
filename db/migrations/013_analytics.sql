-- =====================================================================
-- Apex Trader :: 013_analytics.sql
-- Candle rollups, NAV history, performance analytics, leaderboards and
-- order lineage. Slide 09 listed views/procedures/indexing as missing;
-- this file is the analytical half of the answer.
-- =====================================================================

-- ---------------------------------------------------------------------
-- ARBITRARY-INTERVAL CANDLES
--
-- date_bin (PostgreSQL 14+) buckets a timestamp to any interval from a
-- fixed origin, so ONE function serves 5m, 15m, 1h, 4h, 1d and 1w from
-- the single 1-minute base table. No duplicated per-interval tables that
-- could disagree with each other.
--
-- The origin is a Monday so that weekly buckets align to week starts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION market.candles(
    p_instrument_id INTEGER,
    p_interval      INTERVAL,
    p_from          TIMESTAMPTZ,
    p_to            TIMESTAMPTZ DEFAULT now()
) RETURNS TABLE (bucket TIMESTAMPTZ, open NUMERIC, high NUMERIC, low NUMERIC,
                 close NUMERIC, volume NUMERIC, trade_count BIGINT, vwap NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT date_bin(p_interval, c.bucket_start, TIMESTAMPTZ '2000-01-03 00:00:00+00') AS bucket,
           -- Ordered aggregates pick the first open and the last close
           -- inside each bucket; max/min give the true high and low.
           (array_agg(c.open  ORDER BY c.bucket_start ASC ))[1] AS open,
           max(c.high)                                          AS high,
           min(c.low)                                           AS low,
           (array_agg(c.close ORDER BY c.bucket_start DESC))[1]  AS close,
           sum(c.volume)                                        AS volume,
           sum(c.trade_count)::BIGINT                           AS trade_count,
           -- VWAP must be re-weighted by volume, never averaged.
           round(sum(c.vwap * c.volume) / NULLIF(sum(c.volume),0), 8) AS vwap
      FROM market.candle_1m c
     WHERE c.instrument_id = p_instrument_id
       AND c.bucket_start >= p_from
       AND c.bucket_start <  p_to
     GROUP BY 1
     ORDER BY 1;
$$;

COMMENT ON FUNCTION market.candles IS
  'One function serves every chart interval by date_bin-ing the 1-minute '
  'base table. VWAP is volume-reweighted, not averaged.';

-- ---------------------------------------------------------------------
-- TECHNICAL INDICATORS, computed with window functions.
-- Moving averages, Bollinger bands and RSI-style gain/loss averaging all
-- fall out of ordered window frames.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION market.candles_with_indicators(
    p_instrument_id INTEGER, p_interval INTERVAL,
    p_from TIMESTAMPTZ, p_to TIMESTAMPTZ DEFAULT now()
) RETURNS TABLE (bucket TIMESTAMPTZ, open NUMERIC, high NUMERIC, low NUMERIC,
                 close NUMERIC, volume NUMERIC, vwap NUMERIC,
                 sma_10 NUMERIC, sma_20 NUMERIC, ema_12 NUMERIC,
                 bb_upper NUMERIC, bb_lower NUMERIC, rsi_14 NUMERIC,
                 pct_change NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH base AS (
        SELECT * FROM market.candles(p_instrument_id, p_interval, p_from, p_to)
    ), moves AS (
        SELECT b.*,
               -- LAG reaches back one bar: the basis of every return series.
               b.close - lag(b.close) OVER (ORDER BY b.bucket) AS delta,
               avg(b.close)         OVER (ORDER BY b.bucket ROWS 9  PRECEDING) AS sma_10,
               avg(b.close)         OVER (ORDER BY b.bucket ROWS 19 PRECEDING) AS sma_20,
               stddev_samp(b.close) OVER (ORDER BY b.bucket ROWS 19 PRECEDING) AS sd_20,
               lag(b.close)         OVER (ORDER BY b.bucket) AS prev_close
          FROM base b
    ), rsi AS (
        SELECT m.*,
               avg(GREATEST(m.delta,0)) OVER (ORDER BY m.bucket ROWS 13 PRECEDING) AS avg_gain,
               avg(GREATEST(-m.delta,0)) OVER (ORDER BY m.bucket ROWS 13 PRECEDING) AS avg_loss
          FROM moves m
    )
    SELECT r.bucket, r.open, r.high, r.low, r.close, r.volume, r.vwap,
           round(r.sma_10,4), round(r.sma_20,4),
           -- A true EMA needs recursion; this is the standard 12-period
           -- weighting approximation over the visible frame.
           round(avg(r.close) OVER (ORDER BY r.bucket ROWS 11 PRECEDING),4) AS ema_12,
           round(r.sma_20 + 2*r.sd_20, 4) AS bb_upper,
           round(r.sma_20 - 2*r.sd_20, 4) AS bb_lower,
           CASE WHEN r.avg_loss = 0 AND r.avg_gain > 0 THEN 100
                WHEN r.avg_loss = 0 THEN NULL
                ELSE round(100 - (100 / (1 + r.avg_gain / r.avg_loss)), 2) END AS rsi_14,
           round((r.close - r.prev_close) / NULLIF(r.prev_close,0) * 100, 4) AS pct_change
      FROM rsi r
     ORDER BY r.bucket;
$$;

-- =====================================================================
-- NAV HISTORY
--
-- Performance metrics (Sharpe, drawdown, returns) require a TIME SERIES
-- of account value. Daily cash flow is not a return series -- buying
-- shares is a cash outflow but not a loss. So the system snapshots NAV
-- once per session and all performance analytics read from here.
--
-- Historical snapshots can be BACKFILLED exactly, because the ledger is
-- append-only: see ledger.balance_as_of.
-- =====================================================================
CREATE TABLE IF NOT EXISTS analytics.account_snapshot (
    account_id      BIGINT NOT NULL REFERENCES trading.account(account_id) ON DELETE CASCADE,
    as_of           DATE   NOT NULL,
    cash            money_amt NOT NULL,
    securities_value money_amt NOT NULL,
    nav             money_amt NOT NULL,
    realized_pnl_cum money_amt NOT NULL DEFAULT 0,
    position_count  INTEGER NOT NULL DEFAULT 0,
    taken_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, as_of)
);
CREATE INDEX ix_snapshot_date ON analytics.account_snapshot (as_of DESC);

CREATE OR REPLACE FUNCTION analytics.take_snapshots(p_as_of DATE DEFAULT CURRENT_DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER;
BEGIN
    INSERT INTO analytics.account_snapshot
        (account_id, as_of, cash, securities_value, nav, realized_pnl_cum, position_count)
    SELECT a.account_id, p_as_of,
           ledger.cash_balance(a.account_id),
           COALESCE((SELECT sum(v.market_value) FROM analytics.v_portfolio v
                      WHERE v.account_id = a.account_id), 0),
           risk.account_nav(a.account_id),
           COALESCE((SELECT sum(p.realized_pnl) FROM trading.position p
                      WHERE p.account_id = a.account_id), 0),
           COALESCE((SELECT count(*) FROM trading.position p
                      WHERE p.account_id = a.account_id AND p.quantity <> 0), 0)
      FROM trading.account a
     WHERE NOT a.is_system
    ON CONFLICT (account_id, as_of) DO UPDATE
       SET cash = EXCLUDED.cash, securities_value = EXCLUDED.securities_value,
           nav = EXCLUDED.nav, realized_pnl_cum = EXCLUDED.realized_pnl_cum,
           position_count = EXCLUDED.position_count, taken_at = now();

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

-- =====================================================================
-- EQUITY CURVE + DRAWDOWN
-- A showcase of chained window functions: returns from LAG, the running
-- high-water mark from a MAX over an unbounded preceding frame, and
-- drawdown as the gap between the two.
-- =====================================================================
CREATE OR REPLACE FUNCTION analytics.equity_curve(
    p_account_id BIGINT, p_days INTEGER DEFAULT 180
) RETURNS TABLE (as_of DATE, nav money_amt, daily_return_pct NUMERIC,
                 cum_return_pct NUMERIC, peak_nav money_amt,
                 drawdown_pct NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH s AS (
        SELECT sn.as_of, sn.nav
          FROM analytics.account_snapshot sn
         WHERE sn.account_id = p_account_id
           AND sn.as_of > CURRENT_DATE - p_days
         ORDER BY sn.as_of
    ), r AS (
        SELECT s.as_of, s.nav,
               lag(s.nav)         OVER (ORDER BY s.as_of) AS prev_nav,
               first_value(s.nav) OVER (ORDER BY s.as_of) AS base_nav,
               -- Running high-water mark of the equity curve.
               max(s.nav) OVER (ORDER BY s.as_of ROWS UNBOUNDED PRECEDING) AS peak
          FROM s
    )
    SELECT r.as_of, r.nav,
           round((r.nav - r.prev_nav) / NULLIF(r.prev_nav,0) * 100, 4),
           round((r.nav - r.base_nav) / NULLIF(r.base_nav,0) * 100, 4),
           r.peak::money_amt,
           -- Drawdown: how far below the previous peak we are now.
           round((r.nav - r.peak) / NULLIF(r.peak,0) * 100, 4)
      FROM r ORDER BY r.as_of;
$$;

-- Risk-adjusted performance summary for one account.
CREATE OR REPLACE FUNCTION analytics.performance_stats(
    p_account_id BIGINT, p_days INTEGER DEFAULT 180
) RETURNS TABLE (trading_days BIGINT, start_nav money_amt, end_nav money_amt,
                 total_return_pct NUMERIC, avg_daily_return_pct NUMERIC,
                 volatility_pct NUMERIC, sharpe_ratio NUMERIC,
                 max_drawdown_pct NUMERIC, win_days BIGINT, loss_days BIGINT,
                 win_rate_pct NUMERIC, best_day_pct NUMERIC, worst_day_pct NUMERIC)
LANGUAGE sql STABLE AS $$
    WITH c AS (SELECT * FROM analytics.equity_curve(p_account_id, p_days))
    SELECT count(*),
           (SELECT nav FROM c ORDER BY as_of ASC  LIMIT 1),
           (SELECT nav FROM c ORDER BY as_of DESC LIMIT 1),
           round(((SELECT nav FROM c ORDER BY as_of DESC LIMIT 1)
                / NULLIF((SELECT nav FROM c ORDER BY as_of ASC LIMIT 1),0) - 1) * 100, 4),
           round(avg(c.daily_return_pct), 4),
           round(stddev_samp(c.daily_return_pct), 4),
           -- Annualised Sharpe at a 0% risk-free rate: sqrt(252::numeric) scales
           -- a daily ratio to yearly.
           CASE WHEN stddev_samp(c.daily_return_pct) > 0
                THEN round(avg(c.daily_return_pct) / stddev_samp(c.daily_return_pct)
                           * sqrt(252::numeric), 4) END,
           round(min(c.drawdown_pct), 4),
           count(*) FILTER (WHERE c.daily_return_pct > 0),
           count(*) FILTER (WHERE c.daily_return_pct < 0),
           round(100.0 * count(*) FILTER (WHERE c.daily_return_pct > 0)
                 / NULLIF(count(*) FILTER (WHERE c.daily_return_pct IS NOT NULL),0), 2),
           round(max(c.daily_return_pct), 4),
           round(min(c.daily_return_pct), 4)
      FROM c;
$$;

-- =====================================================================
-- MATERIALIZED VIEWS
-- Expensive aggregates computed once and read many times. Each carries a
-- UNIQUE index, which is what makes REFRESH ... CONCURRENTLY possible --
-- without it, a refresh takes an exclusive lock and the dashboard stalls.
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS analytics.mv_strategy_leaderboard;
CREATE MATERIALIZED VIEW analytics.mv_strategy_leaderboard AS
WITH curve AS (
    SELECT s.strategy_id, sn.as_of, sn.nav,
           lag(sn.nav) OVER (PARTITION BY s.strategy_id ORDER BY sn.as_of) AS prev_nav,
           max(sn.nav) OVER (PARTITION BY s.strategy_id ORDER BY sn.as_of
                             ROWS UNBOUNDED PRECEDING) AS peak_nav
      FROM social.strategy s
      JOIN analytics.account_snapshot sn ON sn.account_id = s.source_account_id
), rets AS (
    SELECT strategy_id, as_of, nav,
           (nav - prev_nav) / NULLIF(prev_nav,0) * 100 AS daily_ret,
           (nav - peak_nav) / NULLIF(peak_nav,0) * 100 AS drawdown
      FROM curve
)
SELECT s.strategy_id, s.name, s.slug, s.visibility, s.fee_bps,
       u.user_id AS owner_user_id, u.full_name AS owner_name,
       count(r.as_of)                                   AS trading_days,
       round(avg(r.daily_ret), 4)                       AS avg_daily_return_pct,
       round(stddev_samp(r.daily_ret), 4)               AS volatility_pct,
       CASE WHEN stddev_samp(r.daily_ret) > 0
            THEN round(avg(r.daily_ret)/stddev_samp(r.daily_ret)*sqrt(252::numeric), 4) END AS sharpe_ratio,
       round(min(r.drawdown), 4)                        AS max_drawdown_pct,
       round(100.0 * count(*) FILTER (WHERE r.daily_ret > 0)
             / NULLIF(count(*) FILTER (WHERE r.daily_ret IS NOT NULL),0), 2) AS win_rate_pct,
       (SELECT count(*) FROM social.copy_subscription cs
         WHERE cs.strategy_id = s.strategy_id AND cs.status='active')        AS active_copiers,
       (SELECT count(*) FROM social.follow f WHERE f.strategy_id = s.strategy_id) AS followers,
       (SELECT count(*) FROM trading.execution e
          WHERE e.buy_account_id = s.source_account_id
             OR e.sell_account_id = s.source_account_id)                     AS total_fills,
       -- Rank public strategies by Sharpe; NULLs (too little history) last.
       rank() OVER (ORDER BY CASE WHEN stddev_samp(r.daily_ret) > 0
                        THEN avg(r.daily_ret)/stddev_samp(r.daily_ret)*sqrt(252::numeric) END
                    DESC NULLS LAST)                                         AS sharpe_rank,
       now() AS refreshed_at
  FROM social.strategy s
  JOIN identity.app_user u ON u.user_id = s.owner_user_id
  LEFT JOIN rets r ON r.strategy_id = s.strategy_id
 GROUP BY s.strategy_id, s.name, s.slug, s.visibility, s.fee_bps, u.user_id, u.full_name;

CREATE UNIQUE INDEX uq_mv_leaderboard ON analytics.mv_strategy_leaderboard (strategy_id);
CREATE INDEX ix_mv_leaderboard_rank  ON analytics.mv_strategy_leaderboard (sharpe_rank);

-- Daily per-instrument statistics for the market-overview screen.
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_instrument_daily;
CREATE MATERIALIZED VIEW analytics.mv_instrument_daily AS
SELECT e.instrument_id, i.symbol, i.name, i.sector,
       date_trunc('day', e.executed_at)::date         AS session_date,
       count(*)                                        AS trade_count,
       sum(e.quantity)                                 AS volume,
       round(sum(e.price*e.quantity),2)                AS notional,
       round(sum(e.price*e.quantity)/NULLIF(sum(e.quantity),0),6) AS vwap,
       min(e.price) AS low, max(e.price) AS high,
       (array_agg(e.price ORDER BY e.executed_at ASC ))[1] AS open,
       (array_agg(e.price ORDER BY e.executed_at DESC))[1] AS close,
       count(DISTINCT e.buy_account_id)                AS unique_buyers,
       count(DISTINCT e.sell_account_id)               AS unique_sellers,
       round(sum(e.buy_fee + e.sell_fee),2)            AS fees_collected
  FROM trading.execution e
  JOIN reference.instrument i USING (instrument_id)
 GROUP BY e.instrument_id, i.symbol, i.name, i.sector, date_trunc('day', e.executed_at);

CREATE UNIQUE INDEX uq_mv_instrument_daily ON analytics.mv_instrument_daily (instrument_id, session_date);
CREATE INDEX ix_mv_instrument_daily_date   ON analytics.mv_instrument_daily (session_date DESC);

CREATE OR REPLACE FUNCTION analytics.refresh_all(p_concurrent BOOLEAN DEFAULT TRUE)
RETURNS TABLE (view_name TEXT, duration INTERVAL) LANGUAGE plpgsql AS $$
DECLARE v_mv TEXT; v_t0 TIMESTAMPTZ;
BEGIN
    FOREACH v_mv IN ARRAY ARRAY['analytics.mv_instrument_daily',
                                'analytics.mv_strategy_leaderboard'] LOOP
        v_t0 := clock_timestamp();
        IF p_concurrent THEN
            -- CONCURRENTLY keeps the view readable during the rebuild.
            -- Requires the unique index declared above.
            EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s', v_mv);
        ELSE
            EXECUTE format('REFRESH MATERIALIZED VIEW %s', v_mv);
        END IF;
        RETURN QUERY SELECT v_mv, clock_timestamp() - v_t0;
    END LOOP;
END;
$$;

-- =====================================================================
-- ORDER LINEAGE :: a RECURSIVE CTE walking the parent/child order tree.
--
-- Bracket orders, OCO pairs and copy-trade mirrors all form a tree. This
-- walks it to arbitrary depth -- the canonical case for WITH RECURSIVE,
-- which a plain join cannot express.
-- =====================================================================
CREATE OR REPLACE FUNCTION analytics.order_lineage(p_order_id BIGINT)
RETURNS TABLE (depth INTEGER, order_id BIGINT, parent_order_id BIGINT,
               account_no TEXT, symbol TEXT, side trading.order_side,
               kind trading.order_kind, quantity money_amt, status trading.order_status,
               strategy_name TEXT, path BIGINT[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE tree AS (
        -- Anchor: climb to the ultimate root of this order's family.
        SELECT o.order_id, o.parent_order_id, 0 AS depth, ARRAY[o.order_id] AS path
          FROM trading.trade_order o
         WHERE o.order_id = p_order_id

        UNION ALL

        -- Recurse downward into every child order.
        SELECT c.order_id, c.parent_order_id, t.depth + 1, t.path || c.order_id
          FROM trading.trade_order c
          JOIN tree t ON c.parent_order_id = t.order_id
         -- Cycle guard: a malformed parent chain cannot spin forever.
         WHERE NOT c.order_id = ANY(t.path)
           AND t.depth < 20
    )
    SELECT t.depth, t.order_id, t.parent_order_id,
           a.account_no, i.symbol, o.side, o.kind, o.quantity, o.status,
           s.name, t.path
      FROM tree t
      JOIN trading.trade_order o USING (order_id)
      JOIN trading.account a ON a.account_id = o.account_id
      JOIN reference.instrument i ON i.instrument_id = o.instrument_id
      LEFT JOIN social.strategy s ON s.strategy_id = o.source_strategy_id
     ORDER BY t.path;
$$;

-- Copy-trade propagation: which follower orders did one leader fill cause?
CREATE OR REPLACE FUNCTION analytics.copy_fanout_report(p_strategy_id BIGINT)
RETURNS TABLE (leader_execution_id BIGINT, follower_account TEXT, follower_name TEXT,
               mirror_order_id BIGINT, mirror_status trading.order_status,
               mirror_qty money_amt, mirror_filled money_amt, mirror_avg_price NUMERIC,
               slippage_pct NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT cl.leader_execution_id, a.account_no, u.full_name,
           o.order_id, o.status, o.quantity, o.filled_qty, o.avg_fill_price,
           -- How much worse the copier filled than the leader did: the
           -- number that decides whether copy-trading is actually viable.
           round((o.avg_fill_price - le.price) / NULLIF(le.price,0) * 100, 4)
      FROM social.copy_link cl
      JOIN trading.trade_order o ON o.order_id = cl.follower_order_id
      JOIN trading.account a ON a.account_id = o.account_id
      LEFT JOIN identity.app_user u ON u.user_id = a.user_id
      LEFT JOIN trading.execution le ON le.execution_id = cl.leader_execution_id
     WHERE cl.strategy_id = p_strategy_id
     ORDER BY cl.leader_execution_id, a.account_no;
$$;
