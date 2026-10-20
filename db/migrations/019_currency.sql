-- =====================================================================
-- Apex Trader :: 019_currency.sql
-- MULTI-CURRENCY TRADING AND SETTLEMENT.
--
-- The instruments on this venue are priced in USD. Traders are not all
-- in the US. So an account funded in INR buying a USD-priced stock has
-- to cross a currency somewhere, and WHERE that happens is the whole
-- design question.
--
-- The wrong answer is to multiply by a rate in the application and store
-- one number. Then the books no longer say what actually happened, and
-- a rate change silently rewrites history.
--
-- The right answer is that a currency conversion is a TRADE, and gets
-- recorded like one. ledger.posting now carries a currency, and the
-- zero-sum invariant applies INDEPENDENTLY PER CURRENCY:
--
--     USD legs must sum to zero   AND   INR legs must sum to zero
--
-- A conversion is therefore a four-legged entry through an FX desk
-- account -- rupees leave the trader and arrive at the desk, dollars
-- leave the desk and arrive at the trader -- which is exactly how real
-- FX settlement is booked, and the trigger will not let it be recorded
-- any other way.
--
-- NOTE ON SCOPE: post_entry() takes ONE currency for the whole entry,
-- because every cash leg of a trade, fee or deposit is in the same
-- currency. Only a conversion mixes currencies in one entry, and that
-- has its own purpose-built function below. This keeps all 34 existing
-- post_entry call sites working unchanged.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Currency master
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reference.currency (
    code         CHAR(3) PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
    name         TEXT NOT NULL,
    symbol       TEXT NOT NULL,
    -- JPY has no minor unit; most have two. Rounding money correctly
    -- requires knowing this, so it is data rather than an assumption.
    minor_units  SMALLINT NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 4),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    display_order SMALLINT NOT NULL DEFAULT 99
);

INSERT INTO reference.currency (code,name,symbol,minor_units,display_order) VALUES
 ('USD','US Dollar',         '$',   2, 1),
 ('INR','Indian Rupee',      '₹',   2, 2),
 ('EUR','Euro',              '€',   2, 3),
 ('GBP','Pound Sterling',    '£',   2, 4),
 ('JPY','Japanese Yen',      '¥',   0, 5),
 ('AED','UAE Dirham',        'د.إ', 2, 6),
 ('SGD','Singapore Dollar',  'S$',  2, 7),
 ('AUD','Australian Dollar', 'A$',  2, 8),
 ('CAD','Canadian Dollar',   'C$',  2, 9),
 ('CHF','Swiss Franc',       'Fr',  2, 10)
ON CONFLICT (code) DO UPDATE SET name=EXCLUDED.name, symbol=EXCLUDED.symbol;

-- ---------------------------------------------------------------------
-- FX rates as a TIME SERIES, not a single current value.
--
-- Storing only "the" rate makes it impossible to value a historical
-- position correctly, which would reintroduce the look-ahead error the
-- NAV snapshots exist to avoid.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reference.fx_rate (
    base_ccy  CHAR(3) NOT NULL REFERENCES reference.currency(code),
    quote_ccy CHAR(3) NOT NULL REFERENCES reference.currency(code),
    as_of     TIMESTAMPTZ NOT NULL DEFAULT now(),
    rate      NUMERIC(20,10) NOT NULL CHECK (rate > 0),
    source    TEXT NOT NULL DEFAULT 'seed',
    PRIMARY KEY (base_ccy, quote_ccy, as_of),
    CONSTRAINT fx_pair_distinct CHECK (base_ccy <> quote_ccy)
);

CREATE INDEX IF NOT EXISTS ix_fx_latest ON reference.fx_rate (base_ccy, quote_ccy, as_of DESC);

COMMENT ON TABLE reference.fx_rate IS
  'Rate history. rate = how many quote_ccy one base_ccy buys. Only USD-base '
  'pairs are stored; the inverse and all cross rates are derived, so a pair '
  'cannot disagree with its own inverse.';

-- Seed USD-base rates. Every other pair is derived from these, which
-- means USD/INR and INR/USD can never drift out of step.
--
-- These baseline rows are dated FAR IN THE PAST deliberately. fx_rate_at()
-- picks the most recent row at or before the requested instant, so a
-- lookup for a historical trade must find something. Seeding them at
-- "now" leaves every date before now with no rate at all, and valuing
-- any historical position raises. (That is exactly what happened the
-- first time: backfilled trades for non-USD accounts all failed with
-- "no FX rate available".)
INSERT INTO reference.fx_rate (base_ccy, quote_ccy, rate, as_of, source) VALUES
 ('USD','INR', 83.25,   TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','EUR',  0.9210, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','GBP',  0.7880, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','JPY',149.3000, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','AED',  3.6725, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','SGD',  1.3420, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','AUD',  1.5180, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','CAD',  1.3640, TIMESTAMPTZ '2015-01-01','baseline'),
 ('USD','CHF',  0.8810, TIMESTAMPTZ '2015-01-01','baseline')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Rate lookup. Handles identity, direct, inverse and cross pairs, all
-- derived from the USD-base rows so they stay mutually consistent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reference.fx_rate_at(
    p_from CHAR(3), p_to CHAR(3), p_at TIMESTAMPTZ DEFAULT now()
) RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_direct NUMERIC; v_from_usd NUMERIC; v_to_usd NUMERIC;
BEGIN
    IF p_from = p_to THEN RETURN 1; END IF;

    -- direct pair
    SELECT r.rate INTO v_direct FROM reference.fx_rate r
     WHERE r.base_ccy = p_from AND r.quote_ccy = p_to AND r.as_of <= p_at
     ORDER BY r.as_of DESC LIMIT 1;
    IF v_direct IS NOT NULL THEN RETURN v_direct; END IF;

    -- inverse of a stored pair
    SELECT r.rate INTO v_direct FROM reference.fx_rate r
     WHERE r.base_ccy = p_to AND r.quote_ccy = p_from AND r.as_of <= p_at
     ORDER BY r.as_of DESC LIMIT 1;
    IF v_direct IS NOT NULL THEN RETURN 1 / v_direct; END IF;

    -- cross rate, triangulated through USD
    IF p_from = 'USD' THEN v_from_usd := 1;
    ELSE
        SELECT r.rate INTO v_from_usd FROM reference.fx_rate r
         WHERE r.base_ccy='USD' AND r.quote_ccy = p_from AND r.as_of <= p_at
         ORDER BY r.as_of DESC LIMIT 1;
    END IF;

    IF p_to = 'USD' THEN v_to_usd := 1;
    ELSE
        SELECT r.rate INTO v_to_usd FROM reference.fx_rate r
         WHERE r.base_ccy='USD' AND r.quote_ccy = p_to AND r.as_of <= p_at
         ORDER BY r.as_of DESC LIMIT 1;
    END IF;

    IF v_from_usd IS NULL OR v_to_usd IS NULL THEN
        RAISE EXCEPTION 'no FX rate available for %/% at %', p_from, p_to, p_at
              USING ERRCODE = 'P0002';
    END IF;

    RETURN v_to_usd / v_from_usd;
END;
$$;

CREATE OR REPLACE FUNCTION reference.fx_convert(
    p_amount NUMERIC, p_from CHAR(3), p_to CHAR(3), p_at TIMESTAMPTZ DEFAULT now()
) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT round(p_amount * reference.fx_rate_at(p_from, p_to, p_at),
                 (SELECT minor_units FROM reference.currency WHERE code = p_to));
$$;

-- A conversion is its own kind of business event, not an 'adjustment'.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                    WHERE t.typname = 'entry_kind' AND e.enumlabel = 'fx_conversion') THEN
        ALTER TYPE ledger.entry_kind ADD VALUE 'fx_conversion';
    END IF;
END $$;

-- =====================================================================
-- Give the ledger a currency dimension.
-- =====================================================================
ALTER TABLE ledger.posting ADD COLUMN IF NOT EXISTS currency CHAR(3);
ALTER TABLE ledger.balance ADD COLUMN IF NOT EXISTS currency CHAR(3);

-- ---------------------------------------------------------------------
-- Backfill: everything booked before this migration was USD.
--
-- ledger.posting is append-only and its trigger refuses UPDATE -- which
-- is exactly right, and it fired on the first attempt at this migration.
-- Suspending it here is legitimate and narrow: filling in a newly added
-- column is not rewriting a recorded fact. The currency of these
-- postings was always USD; the schema simply had no place to say so.
--
-- The trigger is restored immediately afterwards, and the restoration is
-- asserted at the end of this file so a failed migration cannot leave
-- the ledger mutable.
-- ---------------------------------------------------------------------
ALTER TABLE ledger.posting DISABLE TRIGGER trg_posting_immutable;
UPDATE ledger.posting SET currency = 'USD' WHERE asset_class = 'cash' AND currency IS NULL;
ALTER TABLE ledger.posting ENABLE TRIGGER trg_posting_immutable;

UPDATE ledger.balance SET currency = 'USD' WHERE asset_class = 'cash' AND currency IS NULL;

ALTER TABLE ledger.posting DROP CONSTRAINT IF EXISTS asset_instrument_agreement;
ALTER TABLE ledger.posting ADD CONSTRAINT asset_instrument_agreement CHECK (
        (asset_class = 'cash'     AND instrument_id IS NULL AND currency IS NOT NULL)
     OR (asset_class = 'security' AND instrument_id IS NOT NULL AND currency IS NULL)
);

ALTER TABLE ledger.posting
    DROP CONSTRAINT IF EXISTS posting_currency_fk,
    ADD CONSTRAINT posting_currency_fk
        FOREIGN KEY (currency) REFERENCES reference.currency(code);

-- The balance cache is now keyed per currency as well.
DROP INDEX IF EXISTS ledger.uq_balance_slot;
CREATE UNIQUE INDEX uq_balance_slot
    ON ledger.balance (account_id, asset_class, currency, instrument_id) NULLS NOT DISTINCT;

CREATE INDEX IF NOT EXISTS ix_posting_currency ON ledger.posting (currency, account_id)
    WHERE asset_class = 'cash';

-- =====================================================================
-- THE INVARIANT, now per currency.
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.assert_entry_balanced() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_entry_id BIGINT := COALESCE(NEW.entry_id, OLD.entry_id);
    v_bad      RECORD;
    v_legs     INTEGER;
BEGIN
    SELECT count(*) INTO v_legs FROM ledger.posting p WHERE p.entry_id = v_entry_id;
    IF v_legs = 0 THEN RETURN NULL; END IF;

    IF v_legs < 2 THEN
        RAISE EXCEPTION
            'ledger entry % has % posting(s): double-entry requires at least two',
            v_entry_id, v_legs
            USING ERRCODE = '23514', HINT = 'value must move between two named accounts';
    END IF;

    -- Balance is required INDEPENDENTLY for each currency and each
    -- security. You cannot settle a rupee deficit with dollars, any more
    -- than you can settle a share deficit with cash -- an FX conversion
    -- must name both sides and balance both.
    SELECT p.asset_class, p.currency, p.instrument_id, sum(p.amount) AS imbalance
      INTO v_bad
      FROM ledger.posting p
     WHERE p.entry_id = v_entry_id
     GROUP BY p.asset_class, p.currency, p.instrument_id
    HAVING sum(p.amount) <> 0
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'ledger entry % does not balance: % % is off by %',
            v_entry_id,
            COALESCE(v_bad.currency, (SELECT symbol FROM reference.instrument
                                       WHERE instrument_id = v_bad.instrument_id)),
            v_bad.asset_class, v_bad.imbalance
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END;
$$;

-- Balance cache, now currency-aware.
CREATE OR REPLACE FUNCTION ledger.apply_posting_to_balance() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_new_balance money_amt;
    v_acct        trading.account;
    v_symbol      TEXT;
BEGIN
    INSERT INTO ledger.balance AS b
           (account_id, asset_class, currency, instrument_id, balance, updated_at)
    VALUES (NEW.account_id, NEW.asset_class, NEW.currency, NEW.instrument_id, NEW.amount, now())
    ON CONFLICT (account_id, asset_class, currency, instrument_id) DO UPDATE
        SET balance = b.balance + EXCLUDED.balance, updated_at = now()
    RETURNING b.balance INTO v_new_balance;

    IF v_new_balance < 0 THEN
        SELECT * INTO v_acct FROM trading.account a WHERE a.account_id = NEW.account_id;

        IF NEW.asset_class = 'cash' AND NOT v_acct.allows_negative_cash THEN
            RAISE EXCEPTION
                'account % would be overdrawn: % balance %',
                v_acct.account_no, NEW.currency, v_new_balance
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
                RAISE EXCEPTION 'account % cannot short % (qty %)',
                      v_acct.account_no, v_symbol, v_new_balance USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

-- =====================================================================
-- post_entry gains a currency for the whole entry (defaults to USD, so
-- every existing call site keeps working untouched).
-- =====================================================================
-- The 7-argument version from migration 005 must go. Leaving both in
-- place makes any call with fewer than 7 arguments ambiguous -- PostgreSQL
-- cannot tell which overload is meant, and every existing caller breaks
-- with "function is not unique".
DROP FUNCTION IF EXISTS ledger.post_entry(
    ledger.entry_kind, TEXT, ledger.leg[], TEXT, BIGINT, TIMESTAMPTZ, BIGINT);

CREATE OR REPLACE FUNCTION ledger.post_entry(
    p_kind        ledger.entry_kind,
    p_description TEXT,
    p_legs        ledger.leg[],
    p_source_kind TEXT   DEFAULT NULL,
    p_source_id   BIGINT DEFAULT NULL,
    p_occurred_at TIMESTAMPTZ DEFAULT NULL,
    p_created_by  BIGINT DEFAULT NULL,
    p_currency    CHAR(3) DEFAULT 'USD'
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_entry_id BIGINT;
    v_leg      ledger.leg;
BEGIN
    INSERT INTO ledger.journal_entry
           (kind, description, source_kind, source_id, occurred_at, created_by)
    VALUES (p_kind, p_description, p_source_kind, p_source_id,
            COALESCE(p_occurred_at, now()), p_created_by)
    RETURNING entry_id INTO v_entry_id;

    FOREACH v_leg IN ARRAY p_legs LOOP
        INSERT INTO ledger.posting
               (entry_id, account_id, asset_class, instrument_id, currency, amount, memo)
        VALUES (v_entry_id, v_leg.account_id, v_leg.asset_class, v_leg.instrument_id,
                CASE WHEN v_leg.asset_class = 'cash' THEN p_currency END,
                v_leg.amount, v_leg.memo);
    END LOOP;

    RETURN v_entry_id;
END;
$$;

-- =====================================================================
-- Readers, now currency-aware.
-- =====================================================================
-- Drop the single-argument version from 005. A default parameter does
-- NOT replace an older narrower signature -- both remain callable, and
-- every one-argument call then fails with "function is not unique".
--
-- analytics.v_account_summary (from 012) calls the one-argument form, so
-- PostgreSQL refuses to drop it while that view exists. The view is
-- rebuilt, currency-aware, in migration 020 -- so it is dropped here
-- first. Without this the migration aborts mid-file and leaves the
-- database half-converted: convert_currency and v_fx_board never get
-- created, and nothing downstream notices until a currency call fails.
DROP VIEW IF EXISTS analytics.v_account_summary;
DROP FUNCTION IF EXISTS ledger.cash_balance(BIGINT);

CREATE OR REPLACE FUNCTION ledger.cash_balance(
    p_account_id BIGINT, p_currency CHAR(3) DEFAULT 'USD'
) RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT b.balance FROM ledger.balance b
                      WHERE b.account_id = p_account_id
                        AND b.asset_class = 'cash'
                        AND b.currency = p_currency), 0)::money_amt;
$$;

-- All cash the account holds, expressed in one currency.
CREATE OR REPLACE FUNCTION ledger.cash_total_in(
    p_account_id BIGINT, p_currency CHAR(3) DEFAULT 'USD'
) RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(reference.fx_convert(b.balance, b.currency, p_currency)), 0)::money_amt
      FROM ledger.balance b
     WHERE b.account_id = p_account_id AND b.asset_class = 'cash' AND b.balance <> 0;
$$;

CREATE OR REPLACE FUNCTION ledger.cash_by_currency(p_account_id BIGINT)
RETURNS TABLE (currency CHAR(3), symbol TEXT, balance money_amt, in_base money_amt)
LANGUAGE sql STABLE AS $$
    SELECT b.currency, c.symbol, b.balance,
           reference.fx_convert(b.balance, b.currency,
               (SELECT a.base_currency FROM trading.account a
                 WHERE a.account_id = p_account_id))::money_amt
      FROM ledger.balance b
      JOIN reference.currency c ON c.code = b.currency
     WHERE b.account_id = p_account_id AND b.asset_class='cash' AND b.balance <> 0
     ORDER BY c.display_order;
$$;

-- =====================================================================
-- CURRENCY CONVERSION -- the four-legged entry.
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.convert_currency(
    p_account_id  BIGINT,
    p_from        CHAR(3),
    p_to          CHAR(3),
    p_amount_from money_amt,
    p_memo        TEXT DEFAULT NULL
) RETURNS TABLE (entry_id BIGINT, rate NUMERIC, amount_to money_amt)
LANGUAGE plpgsql AS $$
DECLARE
    v_rate    NUMERIC;
    v_to_amt  money_amt;
    v_fx      BIGINT;
    v_entry   BIGINT;
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

    v_rate   := reference.fx_rate_at(p_from, p_to);
    v_to_amt := reference.fx_convert(p_amount_from, p_from, p_to);

    INSERT INTO ledger.journal_entry (kind, description, source_kind)
    VALUES ('fx_conversion',
            COALESCE(p_memo, format('Convert %s %s to %s %s at %s',
                     p_amount_from, p_from, v_to_amt, p_to, round(v_rate,6))),
            'fx')
    RETURNING ledger.journal_entry.entry_id INTO v_entry;

    -- Four legs. The FROM currency balances between the trader and the
    -- desk; the TO currency balances the other way. Neither currency
    -- gains or loses value -- they simply change hands. The deferred
    -- trigger verifies both independently at COMMIT.
    INSERT INTO ledger.posting (entry_id, account_id, asset_class, currency, amount, memo) VALUES
      (v_entry, p_account_id, 'cash', p_from, -p_amount_from, format('sold %s', p_from)),
      (v_entry, v_fx,         'cash', p_from,  p_amount_from, 'FX desk receives'),
      (v_entry, v_fx,         'cash', p_to,   -v_to_amt,      'FX desk delivers'),
      (v_entry, p_account_id, 'cash', p_to,    v_to_amt,      format('bought %s', p_to));

    RETURN QUERY SELECT v_entry, v_rate, v_to_amt;
END;
$$;

COMMENT ON FUNCTION ledger.convert_currency(BIGINT, CHAR, CHAR, money_amt, TEXT) IS
  'Books an FX conversion as a four-legged entry through the FX desk. '
  'Each currency balances to zero independently, so the trade is '
  'recorded rather than the result of an arithmetic shortcut.';

-- ---------------------------------------------------------------------
-- Top up a currency from the account''s base currency when short.
-- This is what lets a rupee-funded account buy a dollar-priced stock.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger.ensure_currency(
    p_account_id BIGINT, p_currency CHAR(3), p_amount money_amt
) RETURNS money_amt LANGUAGE plpgsql AS $$
DECLARE
    v_have     money_amt;
    v_short    money_amt;
    v_base     CHAR(3);
    v_need_src money_amt;
    v_src_bal  money_amt;
    v_src      CHAR(3);
BEGIN
    v_have := ledger.cash_balance(p_account_id, p_currency);
    IF v_have >= p_amount THEN RETURN 0; END IF;

    v_short := p_amount - v_have;
    SELECT base_currency INTO v_base FROM trading.account WHERE account_id = p_account_id;

    -- Prefer the base currency; otherwise take from the largest holding
    -- that can cover it.
    v_src := v_base;
    IF v_src = p_currency THEN v_src := NULL; END IF;

    IF v_src IS NOT NULL THEN
        v_need_src := reference.fx_convert(v_short, p_currency, v_src);
        v_src_bal  := ledger.cash_balance(p_account_id, v_src);
        IF v_src_bal < v_need_src THEN v_src := NULL; END IF;
    END IF;

    IF v_src IS NULL THEN
        SELECT b.currency INTO v_src
          FROM ledger.balance b
         WHERE b.account_id = p_account_id AND b.asset_class='cash'
           AND b.currency <> p_currency
           AND b.balance >= reference.fx_convert(v_short, p_currency, b.currency)
         ORDER BY reference.fx_convert(b.balance, b.currency, p_currency) DESC
         LIMIT 1;
    END IF;

    IF v_src IS NULL THEN
        RAISE EXCEPTION
            'insufficient funds to obtain % %: no currency holding can cover it',
            v_short, p_currency
            USING ERRCODE = '23514';
    END IF;

    -- Convert a little over the shortfall so rounding cannot leave the
    -- account a fraction short and fail the settlement.
    v_need_src := reference.fx_convert(v_short * 1.001, p_currency, v_src);
    PERFORM ledger.convert_currency(p_account_id, v_src, p_currency, v_need_src,
              format('Auto-conversion to settle a %s trade', p_currency));

    RETURN v_short;
END;
$$;

-- ---------------------------------------------------------------------
-- The FX desk counterparty. Like the bank and the float, it is what
-- makes the conversion balance -- the other currency has to come from
-- somewhere nameable.
-- ---------------------------------------------------------------------
INSERT INTO trading.account (account_no, kind, is_system, system_code,
                             allows_negative_cash, base_currency)
VALUES ('SYS-FX','cash', TRUE, 'FX_DESK', TRUE, 'USD')
ON CONFLICT (account_no) DO NOTHING;

UPDATE trading.account SET allow_short_selling = TRUE WHERE is_system;

-- ---------------------------------------------------------------------
-- Assert the ledger is immutable again. If this migration ever fails
-- between DISABLE and ENABLE above, this turns a silent hole into a
-- loud failure.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgrelid = 'ledger.posting'::regclass
           AND tgname = 'trg_posting_immutable'
           AND tgenabled <> 'D')
    THEN
        RAISE EXCEPTION
            'ledger.posting immutability trigger is still disabled after migration 019';
    END IF;
END $$;

-- =====================================================================
-- PART 2 :: teach the rest of the system about the currency dimension.
--
-- Adding a dimension to the ledger is not finished when the ledger
-- compiles. Everything that aggregated cash now has to say WHICH cash,
-- or it silently adds rupees to dollars. The integrity check caught this
-- immediately -- it reported six drifted slots because it was comparing
-- a per-currency cache against a currency-blind journal sum.
-- =====================================================================

CREATE OR REPLACE FUNCTION ledger.verify_integrity()
RETURNS TABLE (check_name TEXT, passed BOOLEAN, detail TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- 1. Cache equals the journal, slot by slot -- now per currency.
    RETURN QUERY
    WITH truth AS (
        SELECT p.account_id, p.asset_class, p.currency, p.instrument_id,
               sum(p.amount) AS amt
          FROM ledger.posting p GROUP BY 1,2,3,4
    ), drift AS (
        SELECT COUNT(*) AS n FROM truth t
        FULL JOIN ledger.balance b
               ON b.account_id   = t.account_id
              AND b.asset_class  = t.asset_class
              AND b.currency     IS NOT DISTINCT FROM t.currency
              AND b.instrument_id IS NOT DISTINCT FROM t.instrument_id
        WHERE COALESCE(t.amt,0) <> COALESCE(b.balance,0)
    )
    SELECT 'balance_cache_matches_journal', d.n = 0,
           d.n || ' drifted slot(s)' FROM drift d;

    -- 2. Every entry balances, per currency and per security.
    RETURN QUERY
    WITH bad AS (
        SELECT p.entry_id FROM ledger.posting p
         GROUP BY p.entry_id, p.asset_class, p.currency, p.instrument_id
        HAVING sum(p.amount) <> 0
    )
    SELECT 'every_entry_balances', NOT EXISTS (SELECT 1 FROM bad),
           COALESCE((SELECT count(DISTINCT entry_id)::text FROM bad), '0') || ' unbalanced entry/entries';

    -- 3. Closed system: every currency and every security nets to zero
    --    across all accounts. An FX conversion moves value between
    --    currencies but creates none, so this must still hold.
    RETURN QUERY
    WITH net AS (
        SELECT p.asset_class, p.currency, p.instrument_id, sum(p.amount) AS amt
          FROM ledger.posting p GROUP BY 1,2,3 HAVING sum(p.amount) <> 0
    )
    SELECT 'closed_system_conservation', NOT EXISTS (SELECT 1 FROM net),
           COALESCE((SELECT count(*)::text FROM net),'0') || ' non-conserved asset(s)';

    -- 4. No unauthorised overdraft, in any currency.
    RETURN QUERY
    WITH od AS (
        SELECT b.account_id FROM ledger.balance b
          JOIN trading.account a USING (account_id)
         WHERE b.asset_class='cash' AND b.balance < 0 AND NOT a.allows_negative_cash
    )
    SELECT 'no_unauthorised_overdraft', NOT EXISTS (SELECT 1 FROM od),
           COALESCE((SELECT count(*)::text FROM od),'0') || ' overdrawn account(s)';

    -- 5. Every cash posting names its currency.
    RETURN QUERY
    SELECT 'every_cash_posting_has_currency',
           NOT EXISTS (SELECT 1 FROM ledger.posting
                        WHERE asset_class='cash' AND currency IS NULL),
           (SELECT count(*)::text FROM ledger.posting
             WHERE asset_class='cash' AND currency IS NULL) || ' posting(s) without a currency';
END;
$$;

-- Point-in-time reconstruction, per currency.
-- The return type gained a column, so the old signature must go first --
-- CREATE OR REPLACE cannot change an OUT-parameter row type.
DROP FUNCTION IF EXISTS ledger.balance_as_of(BIGINT, TIMESTAMPTZ);
CREATE OR REPLACE FUNCTION ledger.balance_as_of(
    p_account_id BIGINT, p_as_of TIMESTAMPTZ
) RETURNS TABLE (asset_class ledger.asset_class, currency CHAR(3),
                 instrument_id INTEGER, symbol TEXT, balance money_amt)
LANGUAGE sql STABLE AS $$
    SELECT p.asset_class, p.currency, p.instrument_id, i.symbol, sum(p.amount)::money_amt
      FROM ledger.posting p
      JOIN ledger.journal_entry je USING (entry_id)
      LEFT JOIN reference.instrument i USING (instrument_id)
     WHERE p.account_id = p_account_id
       AND je.occurred_at <= p_as_of
     GROUP BY p.asset_class, p.currency, p.instrument_id, i.symbol
    HAVING sum(p.amount) <> 0
     ORDER BY p.asset_class, p.currency, i.symbol;
$$;

-- =====================================================================
-- Risk, now denominated in the account's base currency.
-- =====================================================================
CREATE OR REPLACE FUNCTION risk.account_nav(p_account_id BIGINT)
RETURNS money_amt LANGUAGE plpgsql STABLE AS $$
DECLARE v_base CHAR(3); v_cash money_amt; v_sec money_amt;
BEGIN
    SELECT base_currency INTO v_base FROM trading.account WHERE account_id = p_account_id;
    IF v_base IS NULL THEN RETURN 0; END IF;

    -- All cash holdings, each converted from its own currency.
    v_cash := ledger.cash_total_in(p_account_id, v_base);

    -- Securities marked at their own quote currency, then converted.
    SELECT COALESCE(sum(
             reference.fx_convert(b.balance * COALESCE(q.last_price, q.prev_close, 0),
                                  i.currency, v_base)), 0)
      INTO v_sec
      FROM ledger.balance b
      JOIN reference.instrument i ON i.instrument_id = b.instrument_id
      LEFT JOIN market.quote q ON q.instrument_id = b.instrument_id
     WHERE b.account_id = p_account_id AND b.asset_class = 'security' AND b.balance <> 0;

    RETURN (v_cash + v_sec)::money_amt;
END;
$$;

CREATE OR REPLACE FUNCTION risk.buying_power(p_account_id BIGINT)
RETURNS money_amt LANGUAGE plpgsql STABLE AS $$
DECLARE v_base CHAR(3); v_lev NUMERIC;
BEGIN
    SELECT base_currency, leverage INTO v_base, v_lev
      FROM trading.account WHERE account_id = p_account_id;
    IF v_base IS NULL THEN RETURN 0; END IF;
    -- Spendable cash across ALL currencies, in base terms, times leverage.
    RETURN (ledger.cash_total_in(p_account_id, v_base) * COALESCE(v_lev,1))::money_amt;
END;
$$;

CREATE OR REPLACE FUNCTION risk.cash_flow_today(p_account_id BIGINT)
RETURNS money_amt LANGUAGE plpgsql STABLE AS $$
DECLARE v_base CHAR(3); v_total money_amt;
BEGIN
    SELECT base_currency INTO v_base FROM trading.account WHERE account_id = p_account_id;
    SELECT COALESCE(sum(reference.fx_convert(
             CASE WHEN e.buy_account_id = p_account_id
                  THEN -(e.price*e.quantity + e.buy_fee)
                  ELSE  (e.price*e.quantity - e.sell_fee) END,
             i.currency, v_base)), 0)
      INTO v_total
      FROM trading.execution e
      JOIN reference.instrument i USING (instrument_id)
     WHERE e.executed_at >= date_trunc('day', now())
       AND (e.buy_account_id = p_account_id OR e.sell_account_id = p_account_id);
    RETURN v_total;
END;
$$;

-- Pre-trade check: the order estimate is in the INSTRUMENT's currency,
-- but buying power is in the account's base currency. Comparing them
-- without converting would let a rupee account buy dollars 83x over.
CREATE OR REPLACE FUNCTION risk.order_value_in_base(
    p_account_id BIGINT, p_instrument_id INTEGER, p_value NUMERIC
) RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT reference.fx_convert(
             p_value,
             (SELECT i.currency FROM reference.instrument i WHERE i.instrument_id = p_instrument_id),
             (SELECT a.base_currency FROM trading.account a WHERE a.account_id = p_account_id)
           )::money_amt;
$$;
