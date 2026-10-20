-- =====================================================================
-- Apex Trader :: 007_risk.sql
-- Pre-trade risk, margin, and trading halts.
--
-- Pre-trade risk is the control that stops a bad order BEFORE it reaches
-- the book. It lives in the database, in the same transaction as the
-- order, which is the only place it cannot be bypassed -- an application
-- bug, a rogue script or a direct psql session all hit the same gate.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TRADING HALT :: an instrument can be suspended for a window.
-- ---------------------------------------------------------------------
CREATE TABLE risk.trading_halt (
    halt_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instrument_id INTEGER NOT NULL REFERENCES reference.instrument(instrument_id),
    halted_from   TIMESTAMPTZ NOT NULL DEFAULT now(),
    halted_until  TIMESTAMPTZ NOT NULL,
    reason        risk.halt_reason NOT NULL,
    detail        TEXT,
    reference_price NUMERIC(20,8),
    created_by    BIGINT REFERENCES identity.app_user(user_id),
    CONSTRAINT halt_window_ordered CHECK (halted_until > halted_from),

    -- EXCLUSION CONSTRAINT (needs btree_gist): two halts on the SAME
    -- instrument may not cover overlapping time ranges. A plain UNIQUE
    -- cannot express "no overlapping intervals" -- this is the one tool
    -- that can, and it is enforced by the index, not by application code.
    CONSTRAINT no_overlapping_halts EXCLUDE USING gist (
        instrument_id WITH =,
        tstzrange(halted_from, halted_until) WITH &&
    )
);

CREATE INDEX ix_halt_active ON risk.trading_halt (instrument_id, halted_until)
    WHERE halted_until > '2000-01-01'::timestamptz;

COMMENT ON CONSTRAINT no_overlapping_halts ON risk.trading_halt IS
  'GiST exclusion constraint: prevents two overlapping halt windows for '
  'one instrument, which a UNIQUE constraint is incapable of expressing.';

-- ---------------------------------------------------------------------
-- RISK LIMITS :: per account, with a seeded default profile.
-- ---------------------------------------------------------------------
CREATE TABLE risk.risk_limit (
    account_id            BIGINT PRIMARY KEY REFERENCES trading.account(account_id) ON DELETE CASCADE,
    max_order_notional    money_amt NOT NULL DEFAULT 1000000 CHECK (max_order_notional > 0),
    max_position_pct_nav  pct       NOT NULL DEFAULT 40,
    max_daily_loss        money_amt NOT NULL DEFAULT 50000  CHECK (max_daily_loss > 0),
    max_open_orders       INTEGER   NOT NULL DEFAULT 200    CHECK (max_open_orders > 0),
    max_orders_per_minute INTEGER   NOT NULL DEFAULT 60     CHECK (max_orders_per_minute > 0),
    breach_action         risk.breach_action NOT NULL DEFAULT 'block',
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Every non-system account gets a limit profile automatically. Doing it
-- with a trigger means there is no code path that creates an account
-- without risk limits attached.
CREATE OR REPLACE FUNCTION risk.attach_default_limits() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT NEW.is_system THEN
        INSERT INTO risk.risk_limit (account_id) VALUES (NEW.account_id)
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_account_default_limits
    AFTER INSERT ON trading.account
    FOR EACH ROW EXECUTE FUNCTION risk.attach_default_limits();

-- ---------------------------------------------------------------------
-- Account valuation: net asset value marked to the live market.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION risk.account_nav(p_account_id BIGINT)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT (ledger.cash_balance(p_account_id)
            + COALESCE((
                SELECT sum(b.balance * COALESCE(q.last_price, q.prev_close, 0))
                  FROM ledger.balance b
                  LEFT JOIN market.quote q ON q.instrument_id = b.instrument_id
                 WHERE b.account_id = p_account_id
                   AND b.asset_class = 'security'
              ), 0))::money_amt;
$$;

-- Buying power: cash for a cash account, cash x leverage for margin.
CREATE OR REPLACE FUNCTION risk.buying_power(p_account_id BIGINT)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT (ledger.cash_balance(p_account_id)
            * COALESCE((SELECT a.leverage FROM trading.account a
                         WHERE a.account_id = p_account_id), 1))::money_amt;
$$;

-- Cash already committed to resting buy orders. Without this, a trader
-- could place ten orders each affordable alone but not together.
CREATE OR REPLACE FUNCTION risk.open_buy_exposure(p_account_id BIGINT)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(o.leaves_qty * COALESCE(o.limit_price, o.stop_price, 0)),0)::money_amt
      FROM trading.trade_order o
     WHERE o.account_id = p_account_id
       AND o.side = 'buy'
       AND o.status IN ('working','partially_filled');
$$;

-- Shares already committed to resting sell orders, so the same 100
-- shares cannot be sold twice.
CREATE OR REPLACE FUNCTION risk.open_sell_qty(p_account_id BIGINT, p_instrument_id INTEGER)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(o.leaves_qty),0)::money_amt
      FROM trading.trade_order o
     WHERE o.account_id = p_account_id
       AND o.instrument_id = p_instrument_id
       AND o.side = 'sell'
       AND o.status IN ('working','partially_filled');
$$;

-- ---------------------------------------------------------------------
-- DAILY P&L -- and the distinction that matters.
--
-- An earlier version of this file measured the daily loss limit as net
-- CASH FLOW across today's fills. That is wrong, and wrong in a way that
-- breaks the product: buying 400 shares for 73,000 is a 73,000 cash
-- OUTFLOW but not a loss -- you hold 73,000 of stock. The effect was
-- that any trader who bought more than their loss limit got frozen out
-- of their own account for the rest of the day.
--
-- Three different quantities, kept deliberately separate:
--   cash_flow_today    -- net cash movement        (for the blotter)
--   realized_pnl_today -- P&L from CLOSING trades  (taxable-style P&L)
--   pnl_today          -- realized + mark-to-market (what risk limits)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION risk.cash_flow_today(p_account_id BIGINT)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(
             CASE WHEN e.buy_account_id = p_account_id THEN -(e.price*e.quantity + e.buy_fee)
                  ELSE  (e.price*e.quantity - e.sell_fee) END), 0)::money_amt
      FROM trading.execution e
     WHERE e.executed_at >= date_trunc('day', now())
       AND (e.buy_account_id = p_account_id OR e.sell_account_id = p_account_id);
$$;

-- Realised P&L booked today: cumulative realised P&L now, less whatever
-- it was at the previous session's close.
-- plpgsql (not sql) because it reads analytics.account_snapshot, which is
-- created in a later migration; plpgsql resolves names at run time.
CREATE OR REPLACE FUNCTION risk.realized_pnl_today(p_account_id BIGINT)
RETURNS money_amt LANGUAGE plpgsql STABLE AS $$
DECLARE v_now money_amt; v_prior money_amt;
BEGIN
    SELECT COALESCE(sum(p.realized_pnl),0) INTO v_now
      FROM trading.position p WHERE p.account_id = p_account_id;

    SELECT COALESCE(s.realized_pnl_cum, 0) INTO v_prior
      FROM analytics.account_snapshot s
     WHERE s.account_id = p_account_id AND s.as_of < CURRENT_DATE
     ORDER BY s.as_of DESC LIMIT 1;

    RETURN (v_now - COALESCE(v_prior,0))::money_amt;
END;
$$;

-- Total P&L today, marked to market. This is what the daily loss limit
-- is measured against, because a risk desk cares about the value of the
-- book, not just closed trades.
CREATE OR REPLACE FUNCTION risk.pnl_today(p_account_id BIGINT)
RETURNS money_amt LANGUAGE plpgsql STABLE AS $$
DECLARE v_prior_nav money_amt;
BEGIN
    SELECT s.nav INTO v_prior_nav
      FROM analytics.account_snapshot s
     WHERE s.account_id = p_account_id AND s.as_of < CURRENT_DATE
     ORDER BY s.as_of DESC LIMIT 1;

    -- With no prior snapshot there is no baseline to measure a daily
    -- move against, so fall back to realised P&L rather than inventing a
    -- number (which is what the cash-flow version effectively did).
    IF v_prior_nav IS NULL THEN
        RETURN risk.realized_pnl_today(p_account_id);
    END IF;

    RETURN (risk.account_nav(p_account_id) - v_prior_nav)::money_amt;
END;
$$;

-- =====================================================================
-- THE PRE-TRADE GATE
-- Returns NULL to allow, or a human-readable reason to reject. Called
-- by engine.submit_order inside the order transaction.
-- =====================================================================
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
    v_nav      money_amt;
    v_open_cnt INTEGER;
    v_rate     INTEGER;
BEGIN
    SELECT * INTO v_a FROM trading.account WHERE account_id = p_account_id;
    IF NOT FOUND                  THEN RETURN 'unknown_account'; END IF;
    IF v_a.status = 'closed'      THEN RETURN 'account_closed'; END IF;
    IF v_a.status = 'suspended'   THEN RETURN 'account_suspended'; END IF;

    -- System accounts (the market maker, the float) are the venue's own
    -- plumbing and bypass client risk limits by design.
    IF v_a.is_system THEN RETURN NULL; END IF;

    IF v_a.status = 'restricted' AND p_side = 'buy' THEN
        RETURN 'account_restricted_to_closing_trades_only';
    END IF;

    SELECT * INTO v_l FROM risk.risk_limit WHERE account_id = p_account_id;
    SELECT * INTO v_i FROM reference.instrument WHERE instrument_id = p_instrument_id;

    -- A market order has no price of its own; mark it to the live quote
    -- so risk is still measured against a real number.
    SELECT COALESCE(p_price, q.last_price, q.ask, q.prev_close)
      INTO v_mark FROM market.quote q WHERE q.instrument_id = p_instrument_id;
    v_mark := COALESCE(v_mark, p_price);
    IF v_mark IS NULL THEN RETURN 'no_reference_price_for_risk_check'; END IF;

    v_est := round(v_mark * p_quantity, 8);

    -- ---- 1. Order-size cap ----------------------------------------
    IF v_est > v_l.max_order_notional THEN
        RETURN format('order notional %s exceeds limit %s', round(v_est,2), v_l.max_order_notional);
    END IF;

    -- ---- 2. Open-order count --------------------------------------
    SELECT count(*) INTO v_open_cnt FROM trading.trade_order o
     WHERE o.account_id = p_account_id AND o.status IN ('working','partially_filled');
    IF v_open_cnt >= v_l.max_open_orders THEN
        RETURN format('too many open orders (%s)', v_open_cnt);
    END IF;

    -- ---- 3. Order-rate throttle (anti-runaway-algo) ---------------
    SELECT count(*) INTO v_rate FROM trading.trade_order o
     WHERE o.account_id = p_account_id AND o.placed_at > now() - INTERVAL '1 minute';
    IF v_rate > v_l.max_orders_per_minute THEN
        RETURN format('order rate limit exceeded (%s/min)', v_rate);
    END IF;

    -- ---- 4. Daily loss circuit breaker ----------------------------
    -- Measured on mark-to-market P&L, NOT cash flow: buying an asset
    -- moves cash without being a loss.
    IF risk.pnl_today(p_account_id) < -v_l.max_daily_loss THEN
        RETURN format('daily loss limit of %s reached (P&L today %s); trading halted for this account',
                      v_l.max_daily_loss, round(risk.pnl_today(p_account_id),2));
    END IF;

    IF p_side = 'buy' THEN
        -- ---- 5. Buying power, including cash already committed ----
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
            RETURN format('position in %s would be %s%% of NAV, limit is %s%%',
                          v_i.symbol,
                          round((v_held + v_est) / v_nav * 100, 1),
                          v_l.max_position_pct_nav);
        END IF;
    ELSE
        -- ---- 7. Short-sale control --------------------------------
        -- Shares held, less shares already promised to other sell orders.
        v_held := ledger.position_qty(p_account_id, p_instrument_id)
                  - risk.open_sell_qty(p_account_id, p_instrument_id);
        IF p_quantity > v_held THEN
            IF v_a.kind <> 'margin' OR NOT v_i.is_shortable THEN
                RETURN format('insufficient shares: %s available (%s held, %s committed to open sell orders)',
                              greatest(v_held,0),
                              ledger.position_qty(p_account_id, p_instrument_id),
                              risk.open_sell_qty(p_account_id, p_instrument_id));
            END IF;
        END IF;
    END IF;

    RETURN NULL;   -- cleared
END;
$$;

COMMENT ON FUNCTION risk.pretrade_check IS
  'The pre-trade gate. Runs inside the order transaction, so no client '
  'path -- app, script or psql -- can place an order that skips it. '
  'Returns NULL to allow or a human-readable reason to reject.';

-- ---------------------------------------------------------------------
-- MARGIN monitoring
-- ---------------------------------------------------------------------
CREATE TABLE risk.margin_call (
    call_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id    BIGINT NOT NULL REFERENCES trading.account(account_id) ON DELETE CASCADE,
    issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    nav           money_amt NOT NULL,
    margin_used   money_amt NOT NULL,
    equity_pct    pct NOT NULL,
    required_pct  pct NOT NULL,
    shortfall     money_amt NOT NULL,
    cured_at      TIMESTAMPTZ,
    liquidated_at TIMESTAMPTZ
);
CREATE INDEX ix_margin_open ON risk.margin_call (account_id) WHERE cured_at IS NULL;

-- Scan margin accounts and raise calls where equity has fallen below the
-- maintenance requirement. Designed to be run on a schedule.
CREATE OR REPLACE FUNCTION risk.scan_margin()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER := 0; v_r RECORD;
BEGIN
    FOR v_r IN
        SELECT a.account_id, a.maintenance_margin_pct,
               risk.account_nav(a.account_id) AS nav,
               -- Borrowed amount = the negative part of the cash balance.
               GREATEST(-ledger.cash_balance(a.account_id), 0) AS borrowed
          FROM trading.account a
         WHERE a.kind = 'margin' AND NOT a.is_system AND a.status = 'active'
    LOOP
        CONTINUE WHEN v_r.borrowed <= 0 OR v_r.nav <= 0;

        IF (v_r.nav / NULLIF(v_r.nav + v_r.borrowed, 0)) * 100 < v_r.maintenance_margin_pct THEN
            INSERT INTO risk.margin_call
                (account_id, nav, margin_used, equity_pct, required_pct, shortfall)
            VALUES (v_r.account_id, v_r.nav, v_r.borrowed,
                    round((v_r.nav / (v_r.nav + v_r.borrowed)) * 100, 4),
                    v_r.maintenance_margin_pct,
                    round((v_r.nav + v_r.borrowed) * v_r.maintenance_margin_pct/100.0 - v_r.nav, 8));

            UPDATE trading.account SET status = 'restricted' WHERE account_id = v_r.account_id;
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- Volatility circuit breaker: halt an instrument that moves too far too
-- fast, mirroring exchange-level LULD rules.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION risk.check_circuit_breaker(p_instrument_id INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_ref NUMERIC; v_last NUMERIC; v_band pct; v_move NUMERIC;
BEGIN
    SELECT COALESCE(q.prev_close, q.reference_price), q.last_price, i.price_band_pct
      INTO v_ref, v_last, v_band
      FROM market.quote q JOIN reference.instrument i USING (instrument_id)
     WHERE q.instrument_id = p_instrument_id;

    IF v_ref IS NULL OR v_last IS NULL OR v_ref = 0 THEN RETURN FALSE; END IF;

    v_move := abs(v_last - v_ref) / v_ref * 100;
    IF v_move < v_band THEN RETURN FALSE; END IF;

    -- Only open a new halt if one is not already running; the exclusion
    -- constraint would reject an overlap anyway, but checking first
    -- keeps the function idempotent rather than error-prone.
    IF EXISTS (SELECT 1 FROM risk.trading_halt h
                WHERE h.instrument_id = p_instrument_id AND h.halted_until > now()) THEN
        RETURN TRUE;
    END IF;

    INSERT INTO risk.trading_halt
        (instrument_id, halted_until, reason, detail, reference_price)
    VALUES (p_instrument_id, now() + INTERVAL '5 minutes', 'circuit_breaker',
            format('moved %s%% from reference %s (band %s%%)', round(v_move,2), v_ref, v_band),
            v_ref);

    PERFORM pg_notify('apex_events', json_build_object(
        'type','halt','instrument_id',p_instrument_id,
        'move_pct',round(v_move,2),'until',now() + INTERVAL '5 minutes')::text);

    RETURN TRUE;
END;
$$;
