-- =====================================================================
-- Apex Trader :: 012_views.sql
-- Read models. Slide 09 listed "Views... not implemented"; these are the
-- queries the UI actually renders, defined once in the database so every
-- client shows identical numbers.
-- =====================================================================

-- ---------------------------------------------------------------------
-- DEPTH OF MARKET :: the order book ladder.
--
-- Resting orders are aggregated into PRICE LEVELS, and a window function
-- produces the CUMULATIVE depth at each level -- the number a trader
-- actually needs ("if I sweep to 182.50, how much can I get?").
--
-- Iceberg orders contribute only their displayed size, exactly as they
-- would appear on a real venue's public feed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW trading.v_book_depth AS
WITH levels AS (
    SELECT o.instrument_id, o.side, o.limit_price AS price,
           sum(CASE WHEN o.kind = 'iceberg'
                    THEN least(o.leaves_qty, o.display_qty)   -- hidden size stays hidden
                    ELSE o.leaves_qty END)          AS visible_qty,
           sum(o.leaves_qty)                         AS true_qty,
           count(*)                                  AS order_count,
           min(o.seq_no)                             AS best_seq
      FROM trading.trade_order o
     WHERE o.status IN ('working','partially_filled')
       AND NOT o.stop_armed
       AND o.limit_price IS NOT NULL
       AND o.leaves_qty > 0
     GROUP BY o.instrument_id, o.side, o.limit_price
)
SELECT l.instrument_id, i.symbol, l.side, l.price,
       l.visible_qty, l.true_qty, l.order_count,
       -- Rank 1 = best price on this side (highest bid / lowest ask).
       row_number() OVER (PARTITION BY l.instrument_id, l.side
                          ORDER BY CASE WHEN l.side='buy' THEN -l.price ELSE l.price END)
         AS level_rank,
       -- Running total walking away from the touch.
       sum(l.visible_qty) OVER (PARTITION BY l.instrument_id, l.side
                                ORDER BY CASE WHEN l.side='buy' THEN -l.price ELSE l.price END
                                ROWS UNBOUNDED PRECEDING)
         AS cumulative_qty,
       -- Notional required to consume the book up to this level.
       sum(l.visible_qty * l.price) OVER (PARTITION BY l.instrument_id, l.side
                                ORDER BY CASE WHEN l.side='buy' THEN -l.price ELSE l.price END
                                ROWS UNBOUNDED PRECEDING)
         AS cumulative_notional
  FROM levels l
  JOIN reference.instrument i USING (instrument_id);

COMMENT ON VIEW trading.v_book_depth IS
  'Depth-of-market ladder with cumulative size per level. Iceberg orders '
  'expose only display_qty, matching what a real public feed would show.';

-- ---------------------------------------------------------------------
-- PORTFOLIO :: positions marked to the live market.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_portfolio AS
SELECT p.account_id, a.account_no, a.user_id,
       p.instrument_id, i.symbol, i.name, i.sector, i.currency,
       p.quantity, p.avg_cost,
       COALESCE(q.last_price, q.prev_close) AS mark_price,
       round(p.quantity * COALESCE(q.last_price, q.prev_close, 0), 2)   AS market_value,
       round(p.quantity * p.avg_cost, 2)                                AS cost_basis,
       round(p.quantity * (COALESCE(q.last_price, q.prev_close, 0) - p.avg_cost), 2)
                                                                        AS unrealized_pnl,
       CASE WHEN p.avg_cost > 0
            THEN round((COALESCE(q.last_price, q.prev_close, 0) - p.avg_cost)
                       / p.avg_cost * 100, 4) END                       AS unrealized_pct,
       p.realized_pnl,
       -- Share of the account's total equity in this one name: the
       -- concentration number the risk layer enforces.
       round(100 * (p.quantity * COALESCE(q.last_price, q.prev_close, 0))
             / NULLIF(SUM(p.quantity * COALESCE(q.last_price, q.prev_close, 0))
                      OVER (PARTITION BY p.account_id), 0), 2)          AS pct_of_holdings,
       p.updated_at
  FROM trading.position p
  JOIN trading.account a USING (account_id)
  JOIN reference.instrument i USING (instrument_id)
  LEFT JOIN market.quote q ON q.instrument_id = p.instrument_id
 WHERE p.quantity <> 0 AND NOT a.is_system;

-- ---------------------------------------------------------------------
-- ACCOUNT SUMMARY :: one row per account, the dashboard header.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_account_summary AS
SELECT a.account_id, a.account_no, a.kind, a.status, a.leverage,
       u.user_id, u.full_name, u.email, u.kyc_state,
       ledger.cash_balance(a.account_id)                       AS cash,
       COALESCE(mv.market_value, 0)                            AS securities_value,
       risk.account_nav(a.account_id)                           AS nav,
       risk.buying_power(a.account_id)                          AS buying_power,
       risk.open_buy_exposure(a.account_id)                     AS committed_to_open_orders,
       COALESCE(mv.unrealized_pnl, 0)                           AS unrealized_pnl,
       COALESCE(mv.realized_pnl, 0)                             AS realized_pnl,
       risk.cash_flow_today(a.account_id)                       AS cash_flow_today,
       risk.realized_pnl_today(a.account_id)                    AS realized_pnl_today,
       risk.pnl_today(a.account_id)                             AS pnl_today,
       COALESCE(oo.open_orders, 0)                              AS open_orders,
       COALESCE(mv.positions, 0)                                AS position_count,
       rl.max_order_notional, rl.max_daily_loss, rl.max_position_pct_nav,
       EXISTS (SELECT 1 FROM risk.margin_call mc
                WHERE mc.account_id = a.account_id AND mc.cured_at IS NULL) AS under_margin_call
  FROM trading.account a
  LEFT JOIN identity.app_user u USING (user_id)
  LEFT JOIN risk.risk_limit rl ON rl.account_id = a.account_id
  LEFT JOIN LATERAL (
        SELECT count(*) AS positions,
               sum(v.market_value)   AS market_value,
               sum(v.unrealized_pnl) AS unrealized_pnl,
               sum(v.realized_pnl)   AS realized_pnl
          FROM analytics.v_portfolio v WHERE v.account_id = a.account_id
      ) mv ON TRUE
  LEFT JOIN LATERAL (
        SELECT count(*) AS open_orders FROM trading.trade_order o
         WHERE o.account_id = a.account_id
           AND o.status IN ('working','partially_filled')
      ) oo ON TRUE
 WHERE NOT a.is_system;

-- ---------------------------------------------------------------------
-- TRADE BLOTTER :: one row per fill from the account's point of view,
-- with side and signed cash flow resolved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_blotter AS
SELECT e.execution_id, e.executed_at, acct.account_id, acct.account_no,
       i.symbol, i.name,
       CASE WHEN e.buy_account_id = acct.account_id THEN 'buy' ELSE 'sell' END::trading.order_side AS side,
       e.quantity, e.price,
       round(e.quantity * e.price, 2) AS notional,
       CASE WHEN e.buy_account_id = acct.account_id THEN e.buy_fee ELSE e.sell_fee END AS fee,
       -- Cash effect including the fee: negative for a buy.
       CASE WHEN e.buy_account_id = acct.account_id
            THEN -(e.quantity * e.price + e.buy_fee)
            ELSE  (e.quantity * e.price - e.sell_fee) END AS cash_flow,
       -- Did this account cross the spread, or provide liquidity?
       (e.aggressor_side = CASE WHEN e.buy_account_id = acct.account_id
                                THEN 'buy' ELSE 'sell' END::trading.order_side) AS was_aggressor,
       CASE WHEN e.buy_account_id = acct.account_id THEN e.buy_order_id ELSE e.sell_order_id END AS order_id,
       e.settlement_entry_id
  FROM trading.execution e
  JOIN reference.instrument i USING (instrument_id)
  -- One execution yields a row for each of its two counterparties.
  CROSS JOIN LATERAL (
        VALUES (e.buy_account_id), (e.sell_account_id)
      ) AS sides(account_id)
  JOIN trading.account acct ON acct.account_id = sides.account_id
 WHERE NOT acct.is_system;

-- ---------------------------------------------------------------------
-- OPEN ORDERS :: the working-order blotter, with distance to market.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_open_orders AS
SELECT o.order_id, o.client_order_id, o.account_id, a.account_no,
       i.symbol, o.side, o.kind, o.tif,
       o.quantity, o.filled_qty, o.leaves_qty,
       o.limit_price, o.stop_price, o.trail_pct, o.display_qty,
       o.avg_fill_price, o.status, o.stop_armed,
       q.last_price,
       -- How far the limit sits from the market, in percent. The number
       -- that tells a trader whether an order is realistically fillable.
       CASE WHEN o.limit_price IS NOT NULL AND q.last_price IS NOT NULL
            THEN round((o.limit_price - q.last_price) / q.last_price * 100, 4) END AS distance_pct,
       round(o.leaves_qty * COALESCE(o.limit_price, q.last_price, 0), 2) AS open_notional,
       o.placed_at, o.expires_at, o.source_strategy_id
  FROM trading.trade_order o
  JOIN trading.account a USING (account_id)
  JOIN reference.instrument i USING (instrument_id)
  LEFT JOIN market.quote q ON q.instrument_id = o.instrument_id
 WHERE o.status IN ('pending_new','working','partially_filled');

-- ---------------------------------------------------------------------
-- COMPLIANCE QUEUE :: open alerts enriched for the surveillance desk.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_alert_queue AS
SELECT al.alert_id, al.rule_code, r.name AS rule_name, al.severity, al.state,
       al.detected_at, al.window_from, al.window_to, al.score,
       a.account_no, u.full_name AS account_holder, u.email,
       i.symbol, al.evidence,
       age(now(), al.detected_at) AS age
  FROM surveil.alert al
  JOIN surveil.rule r USING (rule_code)
  LEFT JOIN trading.account a ON a.account_id = al.account_id
  LEFT JOIN identity.app_user u ON u.user_id = a.user_id
  LEFT JOIN reference.instrument i ON i.instrument_id = al.instrument_id;
