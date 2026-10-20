-- =====================================================================
-- Apex Trader :: 021_currency_backfill.sql
-- Historical loading across currencies.
--
-- ops.backfill_execution still booked every cash leg in USD. For a
-- rupee- or sterling-funded account that meant an instant overdraft, so
-- the seeder's historical trades for every non-USD account were silently
-- skipped -- the accounts ended up with a deposit and no history.
--
-- Backfilled conversions also have to happen AT THE HISTORICAL DATE, at
-- that date's rate. Converting yesterday's trade at today's rate is the
-- same look-ahead error that NAV snapshots are careful to avoid.
-- =====================================================================

-- Let a conversion be booked in the past, at that moment's rate.
-- The 5-argument version from 019 must be dropped: leaving both makes
-- any 5-argument call ambiguous, the same trap post_entry hit.
DROP FUNCTION IF EXISTS ledger.convert_currency(BIGINT, CHAR, CHAR, money_amt, TEXT);

CREATE OR REPLACE FUNCTION ledger.convert_currency(
    p_account_id  BIGINT,
    p_from        CHAR(3),
    p_to          CHAR(3),
    p_amount_from money_amt,
    p_memo        TEXT DEFAULT NULL,
    p_at          TIMESTAMPTZ DEFAULT NULL
) RETURNS TABLE (entry_id BIGINT, rate NUMERIC, amount_to money_amt)
LANGUAGE plpgsql AS $$
DECLARE
    v_rate   NUMERIC;
    v_to_amt money_amt;
    v_fx     BIGINT;
    v_entry  BIGINT;
    v_at     TIMESTAMPTZ := COALESCE(p_at, now());
BEGIN
    IF p_from = p_to THEN
        RAISE EXCEPTION 'cannot convert % to itself', p_from USING ERRCODE='22023';
    END IF;
    IF p_amount_from <= 0 THEN
        RAISE EXCEPTION 'conversion amount must be positive' USING ERRCODE='22023';
    END IF;

    SELECT account_id INTO v_fx FROM trading.account WHERE system_code = 'FX_DESK';
    IF v_fx IS NULL THEN
        RAISE EXCEPTION 'FX desk account is missing' USING ERRCODE='P0002';
    END IF;

    -- The rate AS IT WAS at v_at, not today's.
    v_rate   := reference.fx_rate_at(p_from, p_to, v_at);
    v_to_amt := reference.fx_convert(p_amount_from, p_from, p_to, v_at);

    INSERT INTO ledger.journal_entry (kind, description, source_kind, occurred_at)
    VALUES ('fx_conversion',
            COALESCE(p_memo, format('Convert %s %s to %s %s at %s',
                     p_amount_from, p_from, v_to_amt, p_to, round(v_rate,6))),
            'fx', v_at)
    RETURNING ledger.journal_entry.entry_id INTO v_entry;

    INSERT INTO ledger.posting (entry_id, account_id, asset_class, currency, amount, memo) VALUES
      (v_entry, p_account_id, 'cash', p_from, -p_amount_from, format('sold %s', p_from)),
      (v_entry, v_fx,         'cash', p_from,  p_amount_from, 'FX desk receives'),
      (v_entry, v_fx,         'cash', p_to,   -v_to_amt,      'FX desk delivers'),
      (v_entry, p_account_id, 'cash', p_to,    v_to_amt,      format('bought %s', p_to));

    RETURN QUERY SELECT v_entry, v_rate, v_to_amt;
END;
$$;

-- Same trap as cash_balance: the 3-argument version from 019 stays
-- callable unless it is explicitly dropped.
DROP FUNCTION IF EXISTS ledger.ensure_currency(BIGINT, CHAR, money_amt);

CREATE OR REPLACE FUNCTION ledger.ensure_currency(
    p_account_id BIGINT, p_currency CHAR(3), p_amount money_amt,
    p_at TIMESTAMPTZ DEFAULT NULL
) RETURNS money_amt LANGUAGE plpgsql AS $$
DECLARE
    v_have money_amt; v_short money_amt; v_base CHAR(3);
    v_need_src money_amt; v_src CHAR(3);
    v_at TIMESTAMPTZ := COALESCE(p_at, now());
BEGIN
    v_have := ledger.cash_balance(p_account_id, p_currency);
    IF v_have >= p_amount THEN RETURN 0; END IF;

    v_short := p_amount - v_have;
    SELECT base_currency INTO v_base FROM trading.account WHERE account_id = p_account_id;

    v_src := CASE WHEN v_base = p_currency THEN NULL ELSE v_base END;

    IF v_src IS NOT NULL THEN
        v_need_src := reference.fx_convert(v_short, p_currency, v_src, v_at);
        IF ledger.cash_balance(p_account_id, v_src) < v_need_src THEN v_src := NULL; END IF;
    END IF;

    -- Fall back to whichever other holding can cover it.
    IF v_src IS NULL THEN
        SELECT b.currency INTO v_src
          FROM ledger.balance b
         WHERE b.account_id = p_account_id AND b.asset_class='cash'
           AND b.currency <> p_currency
           AND b.balance >= reference.fx_convert(v_short, p_currency, b.currency, v_at)
         ORDER BY reference.fx_convert(b.balance, b.currency, p_currency, v_at) DESC
         LIMIT 1;
    END IF;

    IF v_src IS NULL THEN
        RAISE EXCEPTION
            'insufficient funds to obtain % %: no currency holding can cover it',
            round(v_short,2), p_currency
            USING ERRCODE = '23514';
    END IF;

    -- Slightly over-convert so rounding cannot leave the account a
    -- fraction short and fail the settlement it was called for.
    v_need_src := reference.fx_convert(v_short * 1.001, p_currency, v_src, v_at);
    PERFORM ledger.convert_currency(p_account_id, v_src, p_currency, v_need_src,
              format('Auto-conversion to settle a %s trade', p_currency), v_at);

    RETURN v_short;
END;
$$;

-- ---------------------------------------------------------------------
-- Historical fills, settled in the instrument's currency.
-- ---------------------------------------------------------------------
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
    v_ccy        CHAR(3);
    v_legs       ledger.leg[];
    v_buyer_sys  BOOLEAN;
BEGIN
    SELECT account_id INTO v_fees_acct FROM trading.account WHERE system_code='HOUSE_FEES';
    SELECT currency   INTO v_ccy       FROM reference.instrument WHERE instrument_id = p_instrument_id;

    v_notional := round(p_price * p_qty, 8);
    v_buy_fee  := round(v_notional * (CASE WHEN p_aggressor='buy'
                        THEN ops.cfg('taker_fee_bps') ELSE ops.cfg('maker_fee_bps') END)/10000.0, 8);
    v_sell_fee := round(v_notional * (CASE WHEN p_aggressor='sell'
                        THEN ops.cfg('taker_fee_bps') ELSE ops.cfg('maker_fee_bps') END)/10000.0, 8);

    SELECT is_system INTO v_buyer_sys FROM trading.account WHERE account_id = p_buy_account;
    IF NOT v_buyer_sys THEN
        PERFORM ledger.ensure_currency(p_buy_account, v_ccy, v_notional + v_buy_fee, p_at);
    END IF;

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

    v_entry := ledger.post_entry('trade_settlement',
                 format('backfill %s @ %s %s', p_qty, p_price, v_ccy),
                 v_legs, 'backfill', NULL, p_at, NULL, v_ccy);

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
