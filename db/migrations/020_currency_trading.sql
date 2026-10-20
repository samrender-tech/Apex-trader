-- =====================================================================
-- Apex Trader :: 020_currency_trading.sql
-- Trade settlement across currencies.
--
-- A trade settles in the INSTRUMENT'S currency -- that is what the
-- exchange quotes and what the counterparty expects to receive. If the
-- buyer does not hold that currency, the broker converts for them
-- first, and that conversion is booked as its own FX entry before the
-- trade settles.
--
-- This is exactly what a real broker does when you buy a US stock from
-- a rupee account, and it keeps the trade entry single-currency, so the
-- per-currency zero-sum invariant stays simple to reason about.
-- =====================================================================

CREATE OR REPLACE FUNCTION engine.settle_fill(
    p_instrument_id  INTEGER,
    p_buy_order_id   BIGINT,
    p_sell_order_id  BIGINT,
    p_price          price_amt,
    p_qty            qty_amt,
    p_aggressor      trading.order_side
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_buy_acct   BIGINT;
    v_sell_acct  BIGINT;
    v_notional   money_amt;
    v_buy_fee    money_amt;
    v_sell_fee   money_amt;
    v_entry_id   BIGINT;
    v_exec_id    BIGINT;
    v_fees_acct  BIGINT;
    v_ccy        CHAR(3);
    v_legs       ledger.leg[];
    v_buyer_sys  BOOLEAN;
BEGIN
    SELECT account_id INTO v_buy_acct  FROM trading.trade_order WHERE order_id = p_buy_order_id;
    SELECT account_id INTO v_sell_acct FROM trading.trade_order WHERE order_id = p_sell_order_id;
    SELECT account_id INTO v_fees_acct FROM trading.account WHERE system_code = 'HOUSE_FEES';

    -- The instrument's own quote currency governs the settlement.
    SELECT currency INTO v_ccy FROM reference.instrument WHERE instrument_id = p_instrument_id;

    v_notional := round(p_price * p_qty, 8);
    v_buy_fee  := round(v_notional * (CASE WHEN p_aggressor = 'buy'
                        THEN ops.cfg('taker_fee_bps') ELSE ops.cfg('maker_fee_bps') END)/10000.0, 8);
    v_sell_fee := round(v_notional * (CASE WHEN p_aggressor = 'sell'
                        THEN ops.cfg('taker_fee_bps') ELSE ops.cfg('maker_fee_bps') END)/10000.0, 8);

    -- ---- Convert into the settlement currency if the buyer is short --
    -- System accounts (the market maker) are funded in USD and permitted
    -- to go negative, so they skip this.
    SELECT is_system INTO v_buyer_sys FROM trading.account WHERE account_id = v_buy_acct;
    IF NOT v_buyer_sys THEN
        PERFORM ledger.ensure_currency(v_buy_acct, v_ccy, v_notional + v_buy_fee);
    END IF;

    v_legs := ARRAY[
        ROW(v_buy_acct,  'cash',     NULL,            -(v_notional + v_buy_fee), 'buy consideration + fee')::ledger.leg,
        ROW(v_sell_acct, 'cash',     NULL,             (v_notional - v_sell_fee),'sell proceeds - fee')::ledger.leg,
        ROW(v_buy_acct,  'security', p_instrument_id,  p_qty,                    'shares received')::ledger.leg,
        ROW(v_sell_acct, 'security', p_instrument_id, -p_qty,                    'shares delivered')::ledger.leg
    ];
    IF (v_buy_fee + v_sell_fee) > 0 THEN
        v_legs := v_legs || ROW(v_fees_acct, 'cash', NULL,
                                (v_buy_fee + v_sell_fee), 'commission revenue')::ledger.leg;
    END IF;

    v_entry_id := ledger.post_entry(
        'trade_settlement',
        format('%s x %s @ %s %s', p_qty, (SELECT symbol FROM reference.instrument
                                           WHERE instrument_id = p_instrument_id), p_price, v_ccy),
        v_legs, 'execution', NULL, NULL, NULL, v_ccy);

    INSERT INTO trading.execution
        (instrument_id, price, quantity, buy_order_id, sell_order_id,
         buy_account_id, sell_account_id, aggressor_side,
         buy_fee, sell_fee, settlement_entry_id)
    VALUES
        (p_instrument_id, p_price, p_qty, p_buy_order_id, p_sell_order_id,
         v_buy_acct, v_sell_acct, p_aggressor, v_buy_fee, v_sell_fee, v_entry_id)
    RETURNING execution_id INTO v_exec_id;

    UPDATE trading.trade_order o SET
        filled_qty     = o.filled_qty + p_qty,
        avg_fill_price = round(((COALESCE(o.avg_fill_price,0) * o.filled_qty)
                                + p_price * p_qty) / (o.filled_qty + p_qty), 8),
        status         = CASE WHEN o.filled_qty + p_qty >= o.quantity
                              THEN 'filled'::trading.order_status
                              ELSE 'partially_filled'::trading.order_status END,
        updated_at     = now()
     WHERE o.order_id IN (p_buy_order_id, p_sell_order_id);

    PERFORM trading.apply_fill_to_position(v_buy_acct,  p_instrument_id,  p_qty, p_price);
    PERFORM trading.apply_fill_to_position(v_sell_acct, p_instrument_id, -p_qty, p_price);

    INSERT INTO market.tick (instrument_id, ts, price, volume, source)
    VALUES (p_instrument_id, now(), p_price, p_qty, 'internal');

    INSERT INTO market.quote AS q (instrument_id, last_price, last_size, day_volume,
                                   day_open, day_high, day_low, updated_at)
    VALUES (p_instrument_id, p_price, p_qty, p_qty, p_price, p_price, p_price, now())
    ON CONFLICT (instrument_id) DO UPDATE SET
        last_price = p_price, last_size = p_qty,
        day_volume = q.day_volume + p_qty,
        day_open   = COALESCE(q.day_open, p_price),
        day_high   = GREATEST(COALESCE(q.day_high, p_price), p_price),
        day_low    = LEAST(COALESCE(q.day_low, p_price), p_price),
        updated_at = now();

    PERFORM pg_notify('apex_events', json_build_object(
        'type','execution', 'instrument_id', p_instrument_id,
        'execution_id', v_exec_id, 'price', p_price, 'qty', p_qty,
        'currency', v_ccy, 'aggressor', p_aggressor, 'ts', now()
    )::text);

    RETURN v_exec_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Pre-trade risk: compare like with like.
--
-- The order's value is in the instrument's currency; buying power is in
-- the account's base currency. Comparing them unconverted would let a
-- rupee-funded account buy roughly 83 times what it can afford.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION risk.pretrade_check(
    p_account_id    BIGINT,
    p_instrument_id INTEGER,
    p_side          trading.order_side,
    p_quantity      qty_amt,
    p_price         NUMERIC
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_a        trading.account;
    v_l        risk.risk_limit;
    v_i        reference.instrument;
    v_est      money_amt;     -- in the instrument's currency
    v_est_base money_amt;     -- the same value in the account's currency
    v_mark     NUMERIC;
    v_held     money_amt;
    v_free     money_amt;
    v_nav      money_amt;
    v_open_cnt INTEGER;
    v_rate     INTEGER;
BEGIN
    SELECT * INTO v_a FROM trading.account WHERE account_id = p_account_id;
    IF NOT FOUND                  THEN RETURN 'unknown_account'; END IF;
    IF v_a.status = 'closed'      THEN RETURN 'account_closed'; END IF;
    IF v_a.status = 'suspended'   THEN RETURN 'account_suspended'; END IF;
    IF v_a.is_system              THEN RETURN NULL; END IF;

    IF v_a.status = 'restricted' AND p_side = 'buy' THEN
        RETURN 'account_restricted_to_closing_trades_only';
    END IF;

    SELECT * INTO v_l FROM risk.risk_limit WHERE account_id = p_account_id;
    SELECT * INTO v_i FROM reference.instrument WHERE instrument_id = p_instrument_id;

    SELECT COALESCE(p_price, q.last_price, q.ask, q.prev_close)
      INTO v_mark FROM market.quote q WHERE q.instrument_id = p_instrument_id;
    v_mark := COALESCE(v_mark, p_price);
    IF v_mark IS NULL THEN RETURN 'no_reference_price_for_risk_check'; END IF;

    v_est      := round(v_mark * p_quantity, 8);
    v_est_base := risk.order_value_in_base(p_account_id, p_instrument_id, v_est);

    -- ---- 1. Order-size cap (measured in base currency) -------------
    IF v_est_base > v_l.max_order_notional THEN
        RETURN format('order value %s %s exceeds your limit of %s %s',
                      round(v_est_base,2), v_a.base_currency,
                      v_l.max_order_notional, v_a.base_currency);
    END IF;

    SELECT count(*) INTO v_open_cnt FROM trading.trade_order o
     WHERE o.account_id = p_account_id AND o.status IN ('working','partially_filled');
    IF v_open_cnt >= v_l.max_open_orders THEN
        RETURN format('too many open orders (%s)', v_open_cnt);
    END IF;

    SELECT count(*) INTO v_rate FROM trading.trade_order o
     WHERE o.account_id = p_account_id AND o.placed_at > now() - INTERVAL '1 minute';
    IF v_rate > v_l.max_orders_per_minute THEN
        RETURN format('order rate limit exceeded (%s/min)', v_rate);
    END IF;

    IF risk.pnl_today(p_account_id) < -v_l.max_daily_loss THEN
        RETURN format('daily loss limit of %s reached (P&L today %s); trading halted for this account',
                      v_l.max_daily_loss, round(risk.pnl_today(p_account_id),2));
    END IF;

    IF p_side = 'buy' THEN
        IF v_est_base + risk.open_buy_exposure(p_account_id) > risk.buying_power(p_account_id) THEN
            RETURN format('insufficient buying power: need %s %s, have %s %s (%s already committed to open orders)',
                          round(v_est_base,2), v_a.base_currency,
                          round(risk.buying_power(p_account_id),2), v_a.base_currency,
                          round(risk.open_buy_exposure(p_account_id),2));
        END IF;

        v_nav  := risk.account_nav(p_account_id);
        v_held := risk.order_value_in_base(p_account_id, p_instrument_id,
                    ledger.position_qty(p_account_id, p_instrument_id) * v_mark);
        IF v_nav > 0 AND (v_held + v_est_base) > v_nav * v_l.max_position_pct_nav / 100.0 THEN
            RETURN format('position in %s would be %s%% of your portfolio, limit is %s%%',
                          v_i.symbol,
                          round((v_held + v_est_base) / v_nav * 100, 1),
                          v_l.max_position_pct_nav);
        END IF;

    ELSE
        v_held := ledger.position_qty(p_account_id, p_instrument_id);
        v_free := v_held - risk.open_sell_qty(p_account_id, p_instrument_id);

        IF p_quantity > v_free THEN
            IF NOT v_a.allow_short_selling THEN
                RETURN format(
                    'cannot sell %s %s: you hold %s%s. Short selling is not enabled on this account.',
                    p_quantity, v_i.symbol, greatest(v_held, 0),
                    CASE WHEN risk.open_sell_qty(p_account_id, p_instrument_id) > 0
                         THEN format(' and %s is already committed to open sell orders',
                                     risk.open_sell_qty(p_account_id, p_instrument_id))
                         ELSE '' END);
            END IF;
            IF v_a.kind <> 'margin' THEN RETURN 'short selling requires a margin account'; END IF;
            IF NOT v_i.is_shortable THEN
                RETURN format('%s is not available to borrow (not shortable)', v_i.symbol);
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

-- open_buy_exposure must also be expressed in base currency.
CREATE OR REPLACE FUNCTION risk.open_buy_exposure(p_account_id BIGINT)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(reference.fx_convert(
             o.leaves_qty * COALESCE(o.limit_price, o.stop_price, 0),
             i.currency,
             (SELECT a.base_currency FROM trading.account a WHERE a.account_id = p_account_id))
           ),0)::money_amt
      FROM trading.trade_order o
      JOIN reference.instrument i USING (instrument_id)
     WHERE o.account_id = p_account_id
       AND o.side = 'buy'
       AND o.status IN ('working','partially_filled');
$$;

-- =====================================================================
-- Views that now have to say which currency.
--
-- These gain columns in the middle, and CREATE OR REPLACE VIEW can only
-- append columns -- it cannot reorder or rename them. So they are
-- dropped first, in dependency order (the summary reads the portfolio).
-- =====================================================================
DROP VIEW IF EXISTS analytics.v_account_summary;
DROP VIEW IF EXISTS analytics.v_portfolio;

CREATE OR REPLACE VIEW analytics.v_portfolio AS
SELECT p.account_id, a.account_no, a.user_id, a.base_currency,
       p.instrument_id, i.symbol, i.name, i.sector, i.currency AS quote_currency,
       p.quantity, p.avg_cost,
       COALESCE(q.last_price, q.prev_close) AS mark_price,
       round(p.quantity * COALESCE(q.last_price, q.prev_close, 0), 2) AS market_value,
       round(reference.fx_convert(p.quantity * COALESCE(q.last_price, q.prev_close, 0),
                                  i.currency, a.base_currency), 2)    AS market_value_base,
       round(p.quantity * p.avg_cost, 2)                              AS cost_basis,
       round(p.quantity * (COALESCE(q.last_price, q.prev_close, 0) - p.avg_cost), 2)
                                                                      AS unrealized_pnl,
       CASE WHEN p.avg_cost > 0
            THEN round((COALESCE(q.last_price, q.prev_close, 0) - p.avg_cost)
                       / p.avg_cost * 100, 4) END                     AS unrealized_pct,
       p.realized_pnl,
       round(100 * (p.quantity * COALESCE(q.last_price, q.prev_close, 0))
             / NULLIF(SUM(p.quantity * COALESCE(q.last_price, q.prev_close, 0))
                      OVER (PARTITION BY p.account_id), 0), 2)        AS pct_of_holdings,
       p.updated_at
  FROM trading.position p
  JOIN trading.account a USING (account_id)
  JOIN reference.instrument i USING (instrument_id)
  LEFT JOIN market.quote q ON q.instrument_id = p.instrument_id
 WHERE p.quantity <> 0 AND NOT a.is_system;

CREATE OR REPLACE VIEW analytics.v_account_summary AS
SELECT a.account_id, a.account_no, a.kind, a.status, a.leverage,
       a.base_currency, c.symbol AS currency_symbol, a.allow_short_selling,
       u.user_id, u.full_name, u.email, u.kyc_state,
       ledger.cash_total_in(a.account_id, a.base_currency)      AS cash,
       ledger.cash_balance(a.account_id, a.base_currency)       AS cash_base_currency,
       COALESCE(mv.market_value, 0)                             AS securities_value,
       risk.account_nav(a.account_id)                            AS nav,
       risk.buying_power(a.account_id)                           AS buying_power,
       risk.open_buy_exposure(a.account_id)                      AS committed_to_open_orders,
       COALESCE(mv.unrealized_pnl, 0)                            AS unrealized_pnl,
       COALESCE(mv.realized_pnl, 0)                              AS realized_pnl,
       risk.cash_flow_today(a.account_id)                        AS cash_flow_today,
       risk.realized_pnl_today(a.account_id)                     AS realized_pnl_today,
       risk.pnl_today(a.account_id)                              AS pnl_today,
       COALESCE(oo.open_orders, 0)                               AS open_orders,
       COALESCE(mv.positions, 0)                                 AS position_count,
       (SELECT count(*) FROM ledger.balance b
         WHERE b.account_id = a.account_id AND b.asset_class='cash' AND b.balance <> 0)
                                                                 AS currencies_held,
       rl.max_order_notional, rl.max_daily_loss, rl.max_position_pct_nav,
       EXISTS (SELECT 1 FROM risk.margin_call mc
                WHERE mc.account_id = a.account_id AND mc.cured_at IS NULL) AS under_margin_call
  FROM trading.account a
  LEFT JOIN reference.currency c ON c.code = a.base_currency
  LEFT JOIN identity.app_user u USING (user_id)
  LEFT JOIN risk.risk_limit rl ON rl.account_id = a.account_id
  LEFT JOIN LATERAL (
        SELECT count(*) AS positions,
               sum(v.market_value_base) AS market_value,
               sum(v.unrealized_pnl)    AS unrealized_pnl,
               sum(v.realized_pnl)      AS realized_pnl
          FROM analytics.v_portfolio v WHERE v.account_id = a.account_id
      ) mv ON TRUE
  LEFT JOIN LATERAL (
        SELECT count(*) AS open_orders FROM trading.trade_order o
         WHERE o.account_id = a.account_id
           AND o.status IN ('working','partially_filled')
      ) oo ON TRUE
 WHERE NOT a.is_system;

-- Live FX board for the dashboard.
CREATE OR REPLACE VIEW analytics.v_fx_board AS
SELECT c.code, c.name, c.symbol, c.minor_units,
       reference.fx_rate_at('USD', c.code) AS per_usd,
       reference.fx_rate_at(c.code, 'USD') AS in_usd,
       (SELECT max(r.as_of) FROM reference.fx_rate r
         WHERE r.quote_ccy = c.code OR r.base_ccy = c.code) AS last_updated
  FROM reference.currency c
 WHERE c.is_active
 ORDER BY c.display_order;

-- =====================================================================
-- Snapshot functions must convert, not just add.
--
-- Both of these summed a `balance` column straight into NAV. With one
-- currency that was correct; with several it would quietly add rupees to
-- dollars and report a portfolio 83x too large.
-- =====================================================================
CREATE OR REPLACE FUNCTION analytics.take_snapshots(p_as_of DATE DEFAULT CURRENT_DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER;
BEGIN
    INSERT INTO analytics.account_snapshot
        (account_id, as_of, cash, securities_value, nav, realized_pnl_cum, position_count)
    SELECT a.account_id, p_as_of,
           ledger.cash_total_in(a.account_id, a.base_currency),
           COALESCE((SELECT sum(v.market_value_base) FROM analytics.v_portfolio v
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

CREATE OR REPLACE FUNCTION ops.backfill_snapshots(p_from DATE, p_to DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_day   DATE := p_from;
    v_count INTEGER := 0;
BEGIN
    WHILE v_day <= p_to LOOP
        INSERT INTO analytics.account_snapshot
            (account_id, as_of, cash, securities_value, nav, realized_pnl_cum, position_count)
        SELECT a.account_id, v_day,
               COALESCE(h.cash, 0), COALESCE(h.securities, 0),
               COALESCE(h.cash, 0) + COALESCE(h.securities, 0),
               0, COALESCE(h.n_positions, 0)
          FROM trading.account a
          LEFT JOIN LATERAL (
              SELECT
                -- Cash converted from each holding currency into base.
                sum(CASE WHEN x.asset_class='cash'
                         THEN reference.fx_convert(x.balance, x.currency, a.base_currency)
                         ELSE 0 END) AS cash,
                -- Securities marked at THAT DAY's close, then converted.
                sum(CASE WHEN x.asset_class='security'
                         THEN reference.fx_convert(
                                x.balance * COALESCE(
                                  (SELECT c.close FROM market.candle_1m c
                                    WHERE c.instrument_id = x.instrument_id
                                      AND c.bucket_start < (v_day + 1)::timestamptz
                                    ORDER BY c.bucket_start DESC LIMIT 1), 0),
                                (SELECT i.currency FROM reference.instrument i
                                  WHERE i.instrument_id = x.instrument_id),
                                a.base_currency)
                         ELSE 0 END) AS securities,
                count(*) FILTER (WHERE x.asset_class='security' AND x.balance <> 0) AS n_positions
              FROM ledger.balance_as_of(a.account_id, (v_day + 1)::timestamptz) x
          ) h ON TRUE
         WHERE NOT a.is_system
        ON CONFLICT (account_id, as_of) DO UPDATE
           SET cash = EXCLUDED.cash, securities_value = EXCLUDED.securities_value,
               nav = EXCLUDED.nav, position_count = EXCLUDED.position_count,
               taken_at = now();

        v_count := v_count + 1;
        v_day := v_day + 1;
    END LOOP;
    RETURN v_count;
END;
$$;
