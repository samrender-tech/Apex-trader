-- =====================================================================
-- Apex Trader :: 018_short_selling.sql
-- Make short selling an explicit, per-account privilege.
--
-- REPORTED PROBLEM: a trader sold 10 QQQ they did not own and ended up
-- with a -10 position in their holdings. The engine was behaving as
-- designed -- the account was a margin account and QQQ was flagged
-- shortable, which is exactly the condition risk.pretrade_check allowed
-- a short sale under -- but that is the wrong DEFAULT.
--
-- Short selling carries unlimited downside and, at a real broker, needs
-- a separate agreement and a locate on borrowable stock. It should never
-- be something a trader falls into by typing a quantity larger than
-- their holding. Having `kind = margin` should not silently imply it.
--
-- So the permission is now a third, explicit condition on the ACCOUNT.
-- Overselling a long position is an error by default, which is what a
-- trader expects; the capability still exists for accounts that opt in.
-- =====================================================================

ALTER TABLE trading.account
    ADD COLUMN IF NOT EXISTS allow_short_selling BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN trading.account.allow_short_selling IS
  'Explicit per-account permission to hold a negative position. Default '
  'FALSE: selling more than you hold is an error, not a short. A margin '
  'account does NOT imply this -- shorting needs its own agreement.';

-- A cash account can never short, regardless of the flag. Encoding it as
-- a CHECK means the contradictory combination cannot be stored at all.
ALTER TABLE trading.account
    DROP CONSTRAINT IF EXISTS short_requires_margin;
ALTER TABLE trading.account
    ADD CONSTRAINT short_requires_margin
    CHECK (NOT allow_short_selling OR kind = 'margin' OR is_system);

-- System accounts (the float, the market maker) must still go negative:
-- that is how shares are issued into the market in the first place.
UPDATE trading.account SET allow_short_selling = TRUE WHERE is_system;

-- ---------------------------------------------------------------------
-- Pre-trade gate: three conditions now, not two.
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
    v_est      money_amt;
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

    v_est := round(v_mark * p_quantity, 8);

    -- ---- 1. Order-size cap ----------------------------------------
    IF v_est > v_l.max_order_notional THEN
        RETURN format('order notional %s exceeds your limit of %s',
                      round(v_est,2), v_l.max_order_notional);
    END IF;

    -- ---- 2. Open-order count --------------------------------------
    SELECT count(*) INTO v_open_cnt FROM trading.trade_order o
     WHERE o.account_id = p_account_id AND o.status IN ('working','partially_filled');
    IF v_open_cnt >= v_l.max_open_orders THEN
        RETURN format('too many open orders (%s)', v_open_cnt);
    END IF;

    -- ---- 3. Order-rate throttle -----------------------------------
    SELECT count(*) INTO v_rate FROM trading.trade_order o
     WHERE o.account_id = p_account_id AND o.placed_at > now() - INTERVAL '1 minute';
    IF v_rate > v_l.max_orders_per_minute THEN
        RETURN format('order rate limit exceeded (%s/min)', v_rate);
    END IF;

    -- ---- 4. Daily loss circuit breaker ----------------------------
    IF risk.pnl_today(p_account_id) < -v_l.max_daily_loss THEN
        RETURN format('daily loss limit of %s reached (P&L today %s); trading halted for this account',
                      v_l.max_daily_loss, round(risk.pnl_today(p_account_id),2));
    END IF;

    IF p_side = 'buy' THEN
        -- ---- 5. Buying power, including committed cash ------------
        IF v_est + risk.open_buy_exposure(p_account_id) > risk.buying_power(p_account_id) THEN
            RETURN format('insufficient buying power: need %s, have %s (%s already committed to open orders)',
                          round(v_est,2),
                          round(risk.buying_power(p_account_id),2),
                          round(risk.open_buy_exposure(p_account_id),2));
        END IF;

        -- ---- 6. Concentration limit -------------------------------
        v_nav  := risk.account_nav(p_account_id);
        v_held := ledger.position_qty(p_account_id, p_instrument_id) * v_mark;
        IF v_nav > 0 AND (v_held + v_est) > v_nav * v_l.max_position_pct_nav / 100.0 THEN
            RETURN format('position in %s would be %s%% of your portfolio, limit is %s%%',
                          v_i.symbol,
                          round((v_held + v_est) / v_nav * 100, 1),
                          v_l.max_position_pct_nav);
        END IF;

    ELSE
        -- =============================================================
        -- 7. SELL: you may not sell what you do not have.
        --
        -- "Free" shares = held, less whatever is already promised to
        -- other resting sell orders. Selling more is a SHORT SALE, which
        -- now requires three separate things to be true.
        -- =============================================================
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

            IF v_a.kind <> 'margin' THEN
                RETURN 'short selling requires a margin account';
            END IF;

            IF NOT v_i.is_shortable THEN
                RETURN format('%s is not available to borrow (not shortable)', v_i.symbol);
            END IF;
        END IF;
    END IF;

    RETURN NULL;   -- cleared
END;
$$;

COMMENT ON FUNCTION risk.pretrade_check IS
  'The pre-trade gate. Runs inside the order transaction, so no client '
  'path can skip it. Selling more than you hold is rejected unless the '
  'account has short selling explicitly enabled AND is a margin account '
  'AND the instrument is borrowable.';

-- ---------------------------------------------------------------------
-- The ledger stays the last line of defence. It already refused an
-- unauthorised negative balance; it must now consult the new flag too,
-- so the two layers cannot disagree about what is permitted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger.apply_posting_to_balance() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_new_balance money_amt;
    v_acct        trading.account;
    v_symbol      TEXT;
BEGIN
    INSERT INTO ledger.balance AS b (account_id, asset_class, instrument_id, balance, updated_at)
    VALUES (NEW.account_id, NEW.asset_class, NEW.instrument_id, NEW.amount, now())
    ON CONFLICT (account_id, asset_class, instrument_id) DO UPDATE
        SET balance = b.balance + EXCLUDED.balance, updated_at = now()
    RETURNING b.balance INTO v_new_balance;

    IF v_new_balance < 0 THEN
        SELECT * INTO v_acct FROM trading.account a WHERE a.account_id = NEW.account_id;

        IF NEW.asset_class = 'cash' AND NOT v_acct.allows_negative_cash THEN
            RAISE EXCEPTION
                'account % would be overdrawn: cash balance %', v_acct.account_no, v_new_balance
                USING ERRCODE = '23514';
        END IF;

        IF NEW.asset_class = 'security' AND NOT v_acct.is_system THEN
            SELECT symbol INTO v_symbol FROM reference.instrument
             WHERE instrument_id = NEW.instrument_id;

            IF NOT v_acct.allow_short_selling THEN
                RAISE EXCEPTION
                    'account % cannot hold a negative position in % (would be %); short selling is not enabled',
                    v_acct.account_no, v_symbol, v_new_balance
                    USING ERRCODE = '23514';
            END IF;

            IF v_acct.kind <> 'margin'
               OR NOT (SELECT i.is_shortable FROM reference.instrument i
                        WHERE i.instrument_id = NEW.instrument_id) THEN
                RAISE EXCEPTION
                    'account % cannot short % (qty %)', v_acct.account_no, v_symbol, v_new_balance
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------
-- Tidy the read model: a position that has been fully closed is not a
-- holding. The row is kept (it carries realised P&L history) but the
-- portfolio view already filters quantity <> 0, so a fully-sold stock
-- disappears from Holdings on its own.
--
-- This function removes genuinely empty rows that also have no realised
-- P&L worth remembering, so the table does not accumulate noise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trading.prune_empty_positions()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER;
BEGIN
    WITH gone AS (
        DELETE FROM trading.position p
         WHERE p.quantity = 0 AND p.realized_pnl = 0
        RETURNING 1
    ) SELECT count(*) INTO v_n FROM gone;
    RETURN v_n;
END;
$$;
