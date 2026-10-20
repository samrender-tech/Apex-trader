-- =====================================================================
-- Apex Trader :: 005_accounts_ledger.sql
--
-- THE CENTRAL DESIGN DECISION OF THIS PROJECT.
--
-- The original Apex Trader stored a `balance` column on ACCOUNT and a
-- `quantity` column on HOLDING, and mutated them with UPDATE on every
-- trade. That is the design every trading tutorial uses, and it has a
-- fatal property: the current balance is the ONLY record of itself. If a
-- bug, a partial failure or a race writes the wrong number, the correct
-- number is gone forever and there is nothing to reconcile against.
--
-- Here, balances are DERIVED. Every movement of value is recorded as a
-- set of signed POSTINGS inside a JOURNAL ENTRY, and the entry is only
-- valid if its postings sum to exactly zero -- enforced by a DEFERRED
-- CONSTRAINT TRIGGER that fires at COMMIT. Value is therefore never
-- created or destroyed, only moved between accounts.
--
--   buy 10 shares @ 100:   buyer cash  -1000   seller cash  +1000  -> 0
--                          buyer stock   +10   seller stock   -10  -> 0
--
-- `ledger.balance` exists only as a trigger-maintained CACHE, and
-- `ledger.verify_integrity()` proves at any moment that the cache still
-- equals the sum of the journal. This is how real clearing systems work.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TRADING ACCOUNT -- note the conspicuous absence of a balance column.
-- ---------------------------------------------------------------------
CREATE TABLE trading.account (
    account_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_no    TEXT NOT NULL UNIQUE,
    user_id       BIGINT REFERENCES identity.app_user(user_id) ON DELETE RESTRICT,
    kind          trading.account_kind   NOT NULL DEFAULT 'cash',
    status        trading.account_status NOT NULL DEFAULT 'active',
    base_currency currency_code NOT NULL DEFAULT 'USD',

    -- Margin parameters. A cash account is leverage 1.0 by definition.
    leverage          NUMERIC(5,2) NOT NULL DEFAULT 1.00 CHECK (leverage BETWEEN 1 AND 10),
    maintenance_margin_pct pct NOT NULL DEFAULT 25,

    -- System accounts are the ledger's counterparties to the outside
    -- world (the bank, the house's fee revenue, the share float). Without
    -- them a deposit could not balance, because the money has to come
    -- FROM somewhere nameable.
    is_system     BOOLEAN NOT NULL DEFAULT FALSE,
    system_code   TEXT UNIQUE,
    allows_negative_cash BOOLEAN NOT NULL DEFAULT FALSE,

    opened_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at     TIMESTAMPTZ,

    CONSTRAINT system_account_shape CHECK (
        (is_system AND user_id IS NULL AND system_code IS NOT NULL)
     OR (NOT is_system AND user_id IS NOT NULL AND system_code IS NULL)
    ),
    CONSTRAINT cash_account_no_leverage CHECK (kind <> 'cash' OR leverage = 1.00),
    CONSTRAINT closed_status_consistent CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);

CREATE INDEX ix_account_user ON trading.account (user_id) WHERE NOT is_system;

COMMENT ON TABLE trading.account IS
  'Has NO balance column by design. Balances live in ledger.balance as a '
  'cache over ledger.posting, which is the book of record.';

-- ---------------------------------------------------------------------
-- JOURNAL ENTRY -- the header: one business event.
-- ---------------------------------------------------------------------
CREATE TABLE ledger.journal_entry (
    entry_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind         ledger.entry_kind NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    description  TEXT NOT NULL,
    -- Soft reference to whatever caused this entry (an execution, a
    -- deposit request, a corporate action). Kept as (type,id) rather than
    -- a dozen nullable FKs.
    source_kind  TEXT,
    source_id    BIGINT,
    -- Correction mechanism: you never UPDATE a posted entry, you post a
    -- reversing entry that points back at it. The audit trail stays whole.
    reverses_entry_id BIGINT REFERENCES ledger.journal_entry(entry_id),
    created_by   BIGINT REFERENCES identity.app_user(user_id),
    CONSTRAINT no_self_reversal CHECK (reverses_entry_id IS DISTINCT FROM entry_id)
);

CREATE INDEX ix_journal_occurred ON ledger.journal_entry (occurred_at DESC);
CREATE INDEX ix_journal_source   ON ledger.journal_entry (source_kind, source_id);

-- ---------------------------------------------------------------------
-- POSTING -- the lines. Signed amounts; the sign IS the debit/credit.
-- ---------------------------------------------------------------------
CREATE TABLE ledger.posting (
    posting_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_id      BIGINT NOT NULL REFERENCES ledger.journal_entry(entry_id) ON DELETE CASCADE,
    account_id    BIGINT NOT NULL REFERENCES trading.account(account_id),
    asset_class   ledger.asset_class NOT NULL,
    instrument_id INTEGER REFERENCES reference.instrument(instrument_id),
    -- Positive = value flows INTO this account, negative = OUT of it.
    amount        money_amt NOT NULL CHECK (amount <> 0),
    memo          TEXT,

    -- Cash has no instrument; a security posting is meaningless without
    -- one. Encoding this as a CHECK means a malformed posting cannot be
    -- written at all.
    CONSTRAINT asset_instrument_agreement CHECK (
        (asset_class = 'cash'     AND instrument_id IS NULL)
     OR (asset_class = 'security' AND instrument_id IS NOT NULL)
    )
);

CREATE INDEX ix_posting_entry   ON ledger.posting (entry_id);
CREATE INDEX ix_posting_account ON ledger.posting (account_id, asset_class, instrument_id);

-- =====================================================================
-- INVARIANT 1 :: every journal entry must balance to zero, per asset.
--
-- This is a DEFERRABLE INITIALLY DEFERRED constraint trigger, which is
-- the only correct tool here: the legs of an entry are inserted one row
-- at a time, so the entry is legitimately unbalanced *during* the
-- transaction. The check must therefore run at COMMIT, not per statement.
-- =====================================================================
-- SECURITY DEFINER is load-bearing here, and for a non-obvious reason.
--
-- This is a DEFERRED constraint trigger, so it fires at COMMIT -- after
-- ledger.post_entry() (which IS security definer) has already returned.
-- At that moment the effective user is the ordinary application role
-- again, and ledger.posting has a Row Level Security policy restricting
-- visibility to the caller's own accounts.
--
-- The trigger would therefore see only ONE SIDE of a trade: the buyer's
-- legs without the seller's. Their cash would sum to -(notional+fee)
-- instead of zero, and EVERY trade between two different users would be
-- rejected as unbalanced -- while still passing every test run as a
-- superuser, because superusers bypass RLS.
--
-- The invariant is a property of the whole entry, so the check must see
-- the whole entry.
CREATE OR REPLACE FUNCTION ledger.assert_entry_balanced() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_entry_id BIGINT := COALESCE(NEW.entry_id, OLD.entry_id);
    v_bad      RECORD;
    v_legs     INTEGER;
BEGIN
    SELECT count(*) INTO v_legs FROM ledger.posting p WHERE p.entry_id = v_entry_id;

    -- The entry may have been deleted entirely (cascade); nothing to check.
    IF v_legs = 0 THEN RETURN NULL; END IF;

    IF v_legs < 2 THEN
        RAISE EXCEPTION
            'ledger entry % has % posting(s): double-entry requires at least two',
            v_entry_id, v_legs
            USING ERRCODE = '23514', HINT = 'value must move between two named accounts';
    END IF;

    -- Balance is required INDEPENDENTLY for cash and for each security:
    -- you cannot settle a share deficit with dollars inside one entry.
    SELECT p.asset_class, p.instrument_id, sum(p.amount) AS imbalance
      INTO v_bad
      FROM ledger.posting p
     WHERE p.entry_id = v_entry_id
     GROUP BY p.asset_class, p.instrument_id
    HAVING sum(p.amount) <> 0
     LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            'ledger entry % does not balance: % (instrument %) is off by %',
            v_entry_id, v_bad.asset_class, COALESCE(v_bad.instrument_id::text,'-'), v_bad.imbalance
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_posting_balanced
    AFTER INSERT OR UPDATE OR DELETE ON ledger.posting
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger.assert_entry_balanced();

COMMENT ON FUNCTION ledger.assert_entry_balanced IS
  'Deferred double-entry invariant: sum(amount) = 0 per (asset_class, '
  'instrument) within every journal entry, verified at COMMIT.';

-- =====================================================================
-- INVARIANT 2 :: the ledger is append-only. Posted history is immutable;
-- mistakes are corrected with a reversing entry, never an UPDATE.
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.forbid_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'ledger.% is append-only (attempted %)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = '42501',
              HINT = 'post a reversing journal entry instead of mutating history';
END;
$$;

CREATE TRIGGER trg_posting_immutable
    BEFORE UPDATE OR DELETE ON ledger.posting
    FOR EACH ROW EXECUTE FUNCTION ledger.forbid_mutation();

CREATE TRIGGER trg_journal_immutable
    BEFORE UPDATE OR DELETE ON ledger.journal_entry
    FOR EACH ROW EXECUTE FUNCTION ledger.forbid_mutation();

-- ---------------------------------------------------------------------
-- BALANCE CACHE -- a derived read model, maintained by trigger.
-- ---------------------------------------------------------------------
CREATE TABLE ledger.balance (
    account_id    BIGINT  NOT NULL REFERENCES trading.account(account_id) ON DELETE CASCADE,
    asset_class   ledger.asset_class NOT NULL,
    instrument_id INTEGER REFERENCES reference.instrument(instrument_id),
    balance       money_amt NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- NULLS NOT DISTINCT (PostgreSQL 15+) lets a single unique index cover
-- both the cash row (instrument_id IS NULL) and per-security rows. Before
-- PG15 this needed a sentinel value or two separate partial indexes.
CREATE UNIQUE INDEX uq_balance_slot
    ON ledger.balance (account_id, asset_class, instrument_id) NULLS NOT DISTINCT;

CREATE INDEX ix_balance_nonzero ON ledger.balance (instrument_id, account_id)
    WHERE balance <> 0;

CREATE OR REPLACE FUNCTION ledger.apply_posting_to_balance() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_new_balance money_amt;
    v_acct        trading.account;
BEGIN
    INSERT INTO ledger.balance AS b (account_id, asset_class, instrument_id, balance, updated_at)
    VALUES (NEW.account_id, NEW.asset_class, NEW.instrument_id, NEW.amount, now())
    ON CONFLICT (account_id, asset_class, instrument_id) DO UPDATE
        SET balance = b.balance + EXCLUDED.balance, updated_at = now()
    RETURNING b.balance INTO v_new_balance;

    -- Safety net, not the primary control. Pre-trade risk checks are
    -- supposed to prevent this; if one is ever bypassed, the ledger
    -- itself refuses to represent an overdrawn cash account.
    IF v_new_balance < 0 THEN
        SELECT * INTO v_acct FROM trading.account a WHERE a.account_id = NEW.account_id;

        IF NEW.asset_class = 'cash' AND NOT v_acct.allows_negative_cash THEN
            RAISE EXCEPTION
                'account % would be overdrawn: cash balance %', v_acct.account_no, v_new_balance
                USING ERRCODE = '23514';
        END IF;

        -- A negative security balance is a short position. Only allowed
        -- if the instrument is flagged shortable and the account is margin.
        IF NEW.asset_class = 'security' AND NOT v_acct.is_system THEN
            IF v_acct.kind <> 'margin'
               OR NOT (SELECT i.is_shortable FROM reference.instrument i
                        WHERE i.instrument_id = NEW.instrument_id) THEN
                RAISE EXCEPTION
                    'account % cannot hold a short position in instrument % (qty %)',
                    v_acct.account_no, NEW.instrument_id, v_new_balance
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_posting_updates_balance
    AFTER INSERT ON ledger.posting
    FOR EACH ROW EXECUTE FUNCTION ledger.apply_posting_to_balance();

-- ---------------------------------------------------------------------
-- Convenience writer: post a whole balanced entry in one call.
-- p_legs is an array of (account_id, asset_class, instrument_id, amount).
-- ---------------------------------------------------------------------
CREATE TYPE ledger.leg AS (
    account_id    BIGINT,
    asset_class   ledger.asset_class,
    instrument_id INTEGER,
    amount        money_amt,
    memo          TEXT
);

CREATE OR REPLACE FUNCTION ledger.post_entry(
    p_kind        ledger.entry_kind,
    p_description TEXT,
    p_legs        ledger.leg[],
    p_source_kind TEXT   DEFAULT NULL,
    p_source_id   BIGINT DEFAULT NULL,
    p_occurred_at TIMESTAMPTZ DEFAULT NULL,
    p_created_by  BIGINT DEFAULT NULL
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
               (entry_id, account_id, asset_class, instrument_id, amount, memo)
        VALUES (v_entry_id, v_leg.account_id, v_leg.asset_class,
                v_leg.instrument_id, v_leg.amount, v_leg.memo);
    END LOOP;

    RETURN v_entry_id;  -- balance invariant is verified at COMMIT
END;
$$;

-- ---------------------------------------------------------------------
-- Readers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger.cash_balance(p_account_id BIGINT)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT b.balance FROM ledger.balance b
                      WHERE b.account_id = p_account_id
                        AND b.asset_class = 'cash'), 0)::money_amt;
$$;

CREATE OR REPLACE FUNCTION ledger.position_qty(p_account_id BIGINT, p_instrument_id INTEGER)
RETURNS money_amt LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT b.balance FROM ledger.balance b
                      WHERE b.account_id = p_account_id
                        AND b.asset_class = 'security'
                        AND b.instrument_id = p_instrument_id), 0)::money_amt;
$$;

-- =====================================================================
-- POINT-IN-TIME RECONSTRUCTION
--
-- Because the journal is append-only, the portfolio at ANY past instant
-- is just a filtered aggregation. A mutable-balance design cannot answer
-- this question at all -- the history was overwritten.
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.balance_as_of(
    p_account_id BIGINT, p_as_of TIMESTAMPTZ
) RETURNS TABLE (asset_class ledger.asset_class, instrument_id INTEGER,
                 symbol TEXT, balance money_amt)
LANGUAGE sql STABLE AS $$
    SELECT p.asset_class, p.instrument_id, i.symbol, sum(p.amount)::money_amt
      FROM ledger.posting p
      JOIN ledger.journal_entry je USING (entry_id)
      LEFT JOIN reference.instrument i USING (instrument_id)
     WHERE p.account_id = p_account_id
       AND je.occurred_at <= p_as_of
     GROUP BY p.asset_class, p.instrument_id, i.symbol
    HAVING sum(p.amount) <> 0
     ORDER BY p.asset_class, i.symbol;
$$;

COMMENT ON FUNCTION ledger.balance_as_of IS
  'Time travel: replays the journal up to an instant. Answers "what did '
  'this portfolio hold last Tuesday at 14:32" -- impossible to answer in '
  'a design that mutates a balance column.';

-- =====================================================================
-- INTEGRITY PROOF -- run this any time to show the cache has not drifted
-- and that the whole system is still conservative (nothing created).
-- =====================================================================
CREATE OR REPLACE FUNCTION ledger.verify_integrity()
RETURNS TABLE (check_name TEXT, passed BOOLEAN, detail TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- 1. Cache equals the journal, slot by slot.
    RETURN QUERY
    WITH truth AS (
        SELECT p.account_id, p.asset_class, p.instrument_id, sum(p.amount) AS amt
          FROM ledger.posting p
         GROUP BY 1,2,3
    ), drift AS (
        SELECT COUNT(*) AS n FROM truth t
        FULL JOIN ledger.balance b
               ON b.account_id = t.account_id
              AND b.asset_class = t.asset_class
              AND b.instrument_id IS NOT DISTINCT FROM t.instrument_id
        WHERE COALESCE(t.amt,0) <> COALESCE(b.balance,0)
    )
    SELECT 'balance_cache_matches_journal', d.n = 0,
           d.n || ' drifted slot(s)' FROM drift d;

    -- 2. Every entry balances (should be guaranteed by the trigger;
    --    verifying it independently is the point of a proof).
    RETURN QUERY
    WITH bad AS (
        SELECT p.entry_id FROM ledger.posting p
         GROUP BY p.entry_id, p.asset_class, p.instrument_id
        HAVING sum(p.amount) <> 0
    )
    SELECT 'every_entry_balances', NOT EXISTS (SELECT 1 FROM bad),
           COALESCE((SELECT count(DISTINCT entry_id)::text FROM bad), '0') || ' unbalanced entry/entries';

    -- 3. System-wide conservation: summed across ALL accounts, every
    --    asset nets to zero. Value only ever moved.
    RETURN QUERY
    WITH net AS (
        SELECT p.asset_class, p.instrument_id, sum(p.amount) AS amt
          FROM ledger.posting p GROUP BY 1,2 HAVING sum(p.amount) <> 0
    )
    SELECT 'closed_system_conservation', NOT EXISTS (SELECT 1 FROM net),
           COALESCE((SELECT count(*)::text FROM net),'0') || ' non-conserved asset(s)';

    -- 4. No non-margin account is overdrawn.
    RETURN QUERY
    WITH od AS (
        SELECT b.account_id FROM ledger.balance b
          JOIN trading.account a USING (account_id)
         WHERE b.asset_class='cash' AND b.balance < 0 AND NOT a.allows_negative_cash
    )
    SELECT 'no_unauthorised_overdraft', NOT EXISTS (SELECT 1 FROM od),
           COALESCE((SELECT count(*)::text FROM od),'0') || ' overdrawn account(s)';
END;
$$;

-- ---------------------------------------------------------------------
-- System counterparty accounts. These make the ledger a closed system.
-- ---------------------------------------------------------------------
INSERT INTO trading.account (account_no, kind, is_system, system_code,
                             allows_negative_cash, base_currency)
VALUES
 ('SYS-BANK',   'cash', TRUE, 'EXTERNAL_CASH', TRUE, 'USD'),
 ('SYS-FEES',   'cash', TRUE, 'HOUSE_FEES',    TRUE, 'USD'),
 ('SYS-FLOAT',  'cash', TRUE, 'SECURITY_FLOAT',TRUE, 'USD'),
 ('SYS-MM',     'margin', TRUE, 'MARKET_MAKER',  TRUE, 'USD');

COMMENT ON COLUMN trading.account.system_code IS
  'EXTERNAL_CASH = the bank/outside world, HOUSE_FEES = commission revenue, '
  'SECURITY_FLOAT = the share pool instruments are issued from, '
  'MARKET_MAKER = synthetic liquidity provider. Without these the ledger '
  'could not balance a deposit, because the cash has to come from a named place.';
