-- =====================================================================
-- Apex Trader :: 016_backfill.sql
-- Historical-data loading utilities.
--
-- The matching engine always stamps fills with now(), which is correct
-- for live trading and useless for loading history. Migrating a venue's
-- back history (or seeding a demo with a believable past) needs a path
-- that writes a fill AT A GIVEN TIMESTAMP while still producing a fully
-- balanced ledger entry.
--
-- This is that path. It bypasses MATCHING but not SETTLEMENT: the
-- double-entry invariant, the balance cache and the position model all
-- apply exactly as they do for a live trade, so backfilled history is
-- indistinguishable from traded history downstream.
-- =====================================================================

CREATE OR REPLACE FUNCTION ops.backfill_execution(
    p_instrument_id INTEGER,
    p_buy_account   BIGINT,
    p_sell_account  BIGINT,
    p_price         price_amt,
    p_qty           qty_amt,
    p_at            TIMESTAMPTZ,
    p_aggressor     trading.order_side DEFAULT 'buy'
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_buy_order  BIGINT;
    v_sell_order BIGINT;
    v_notional   money_amt;
    v_buy_fee    money_amt;
    v_sell_fee   money_amt;
    v_fees_acct  BIGINT;
    v_entry      BIGINT;
    v_exec       BIGINT;
    v_legs       ledger.leg[];
BEGIN
    SELECT account_id INTO v_fees_acct FROM trading.account WHERE system_code='HOUSE_FEES';

    v_notional := round(p_price * p_qty, 8);
    v_buy_fee  := round(v_notional * (CASE WHEN p_aggressor='buy'
                        THEN ops.cfg('taker_fee_bps') ELSE ops.cfg('maker_fee_bps') END)/10000.0, 8);
    v_sell_fee := round(v_notional * (CASE WHEN p_aggressor='sell'
                        THEN ops.cfg('taker_fee_bps') ELSE ops.cfg('maker_fee_bps') END)/10000.0, 8);

    -- Both sides need an order record for referential integrity; they are
    -- created already-filled, because the match is a historical fact.
    INSERT INTO trading.trade_order
        (account_id, instrument_id, side, kind, tif, quantity, limit_price,
         filled_qty, avg_fill_price, status, placed_at, updated_at)
    VALUES (p_buy_account, p_instrument_id, 'buy', 'limit', 'day', p_qty, p_price,
            p_qty, p_price, 'filled', p_at, p_at)
    RETURNING order_id INTO v_buy_order;

    INSERT INTO trading.trade_order
        (account_id, instrument_id, side, kind, tif, quantity, limit_price,
         filled_qty, avg_fill_price, status, placed_at, updated_at)
    VALUES (p_sell_account, p_instrument_id, 'sell', 'limit', 'day', p_qty, p_price,
            p_qty, p_price, 'filled', p_at, p_at)
    RETURNING order_id INTO v_sell_order;

    v_legs := ARRAY[
        ROW(p_buy_account,  'cash',     NULL,            -(v_notional + v_buy_fee), 'backfill buy')::ledger.leg,
        ROW(p_sell_account, 'cash',     NULL,             (v_notional - v_sell_fee),'backfill sell')::ledger.leg,
        ROW(p_buy_account,  'security', p_instrument_id,  p_qty,                    'backfill shares in')::ledger.leg,
        ROW(p_sell_account, 'security', p_instrument_id, -p_qty,                    'backfill shares out')::ledger.leg
    ];
    IF (v_buy_fee + v_sell_fee) > 0 THEN
        v_legs := v_legs || ROW(v_fees_acct,'cash',NULL,(v_buy_fee+v_sell_fee),'backfill fees')::ledger.leg;
    END IF;

    -- occurred_at is backdated, which is the whole point: point-in-time
    -- queries over the journal then return historically correct answers.
    v_entry := ledger.post_entry('trade_settlement',
                 format('backfill %s @ %s', p_qty, p_price),
                 v_legs, 'backfill', NULL, p_at);

    INSERT INTO trading.execution
        (executed_at, instrument_id, price, quantity, buy_order_id, sell_order_id,
         buy_account_id, sell_account_id, aggressor_side, buy_fee, sell_fee, settlement_entry_id)
    VALUES (p_at, p_instrument_id, p_price, p_qty, v_buy_order, v_sell_order,
            p_buy_account, p_sell_account, p_aggressor, v_buy_fee, v_sell_fee, v_entry)
    RETURNING execution_id INTO v_exec;

    PERFORM trading.apply_fill_to_position(p_buy_account,  p_instrument_id,  p_qty, p_price);
    PERFORM trading.apply_fill_to_position(p_sell_account, p_instrument_id, -p_qty, p_price);

    RETURN v_exec;
END;
$$;

COMMENT ON FUNCTION ops.backfill_execution IS
  'Loads a historical fill at an explicit timestamp. Bypasses matching '
  'but NOT settlement, so the double-entry invariant and position model '
  'hold for backfilled history exactly as for live trades.';

-- =====================================================================
-- SNAPSHOT BACKFILL :: rebuild NAV history from the journal.
--
-- This is only possible because the ledger is append-only. For each past
-- date we replay the journal up to that date (ledger.balance_as_of) and
-- mark the resulting holdings at THAT DATE's closing price -- not at
-- today's price, which would be a look-ahead error that flatters every
-- performance statistic.
-- =====================================================================
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
               COALESCE(h.cash, 0),
               COALESCE(h.securities, 0),
               COALESCE(h.cash, 0) + COALESCE(h.securities, 0),
               0,
               COALESCE(h.n_positions, 0)
          FROM trading.account a
          LEFT JOIN LATERAL (
              SELECT
                sum(CASE WHEN x.asset_class='cash' THEN x.balance ELSE 0 END) AS cash,
                sum(CASE WHEN x.asset_class='security'
                         THEN x.balance * COALESCE(
                              -- That day's closing price, from the candle
                              -- series. No look-ahead.
                              (SELECT c.close FROM market.candle_1m c
                                WHERE c.instrument_id = x.instrument_id
                                  AND c.bucket_start < (v_day + 1)::timestamptz
                                ORDER BY c.bucket_start DESC LIMIT 1), 0)
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

COMMENT ON FUNCTION ops.backfill_snapshots IS
  'Reconstructs NAV history by replaying the append-only journal to each '
  'past date and marking holdings at THAT date''s close. A mutable-balance '
  'schema cannot do this at all -- the history was overwritten.';
