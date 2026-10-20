-- =====================================================================
-- Suite: ledger -- the double-entry invariants.
-- =====================================================================
\set QUIET on
TRUNCATE t.result;
\i db/test/_fixture.sql
\set QUIET off

DO $$
DECLARE
    v_bank BIGINT; v_alice BIGINT; v_entry BIGINT; v_before money_amt;
BEGIN
    SELECT account_id INTO v_bank FROM trading.account WHERE system_code='EXTERNAL_CASH';
    SELECT a.account_id INTO v_alice FROM trading.account a
      JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';

    -- A balanced entry is accepted and moves the balance exactly.
    v_before := ledger.cash_balance(v_alice);
    v_entry := ledger.post_entry('deposit','test deposit',
        ARRAY[ ROW(v_bank,'cash',NULL,-2500,NULL)::ledger.leg,
               ROW(v_alice,'cash',NULL,2500,NULL)::ledger.leg ]);
    -- The cast is load-bearing: money_amt is a DOMAIN over NUMERIC, and
    -- subtracting two domain values yields plain numeric. t.eq takes
    -- ANYELEMENT for both sides, so numeric vs money_amt resolved to no
    -- function at all -- and with ON_ERROR_STOP off for the suite (the
    -- raises() tests need it off) the statement simply errored and the
    -- assertion was never recorded. The suite went on reporting green
    -- with one fewer check than it had. scripts/test.sh now fails on any
    -- unexpected psql error for exactly this reason.
    PERFORM t.eq('ledger','balanced entry moves cash by exactly the amount',
                 (ledger.cash_balance(v_alice) - v_before)::money_amt,
                 2500::money_amt);

    PERFORM t.ok('ledger','entry is retrievable', EXISTS(
        SELECT 1 FROM ledger.journal_entry WHERE entry_id = v_entry));

    -- Conservation holds across the whole system.
    PERFORM t.eq('ledger','system-wide cash nets to zero',
        (SELECT COALESCE(sum(amount),0) FROM ledger.posting WHERE asset_class='cash')::money_amt,
        0::money_amt);
END $$;

-- A single-legged entry cannot commit.
BEGIN;
SELECT t.raises('ledger','single-leg entry rejected at COMMIT', $q$
    DO $i$
    DECLARE e BIGINT;
    BEGIN
        INSERT INTO ledger.journal_entry(kind,description)
        VALUES ('deposit','unbalanced') RETURNING entry_id INTO e;
        INSERT INTO ledger.posting(entry_id,account_id,asset_class,currency,amount)
        VALUES (e, (SELECT account_id FROM trading.account WHERE system_code='EXTERNAL_CASH'),
                'cash', 'USD', 999);
        -- Force the deferred constraint to fire inside this block.
        SET CONSTRAINTS ALL IMMEDIATE;
    END $i$;
$q$, 'double-entry requires at least two');
COMMIT;

-- An entry whose legs do not sum to zero cannot commit.
BEGIN;
SELECT t.raises('ledger','unbalanced two-leg entry rejected', $q$
    DO $i$
    DECLARE e BIGINT; b BIGINT; a BIGINT;
    BEGIN
        SELECT account_id INTO b FROM trading.account WHERE system_code='EXTERNAL_CASH';
        SELECT a2.account_id INTO a FROM trading.account a2
          JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
        INSERT INTO ledger.journal_entry(kind,description)
        VALUES ('deposit','lopsided') RETURNING entry_id INTO e;
        INSERT INTO ledger.posting(entry_id,account_id,asset_class,currency,amount) VALUES (e,b,'cash','USD',-100);
        INSERT INTO ledger.posting(entry_id,account_id,asset_class,currency,amount) VALUES (e,a,'cash','USD', 150);
        SET CONSTRAINTS ALL IMMEDIATE;
    END $i$;
$q$, 'does not balance');
COMMIT;

-- Cash and securities must balance independently within one entry.
BEGIN;
SELECT t.raises('ledger','cash cannot settle a share deficit in one entry', $q$
    DO $i$
    DECLARE e BIGINT; a BIGINT; b BIGINT; i2 INTEGER;
    BEGIN
        SELECT account_id INTO b FROM trading.account WHERE system_code='EXTERNAL_CASH';
        SELECT a2.account_id INTO a FROM trading.account a2
          JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
        SELECT instrument_id INTO i2 FROM reference.instrument WHERE symbol='AAPL';
        INSERT INTO ledger.journal_entry(kind,description)
        VALUES ('adjustment','cross-asset') RETURNING entry_id INTO e;
        -- Currency is required on a cash posting since migration 019;
        -- without it the shape CHECK rejects the row before the balance
        -- trigger is reached, which would test the wrong thing.
        INSERT INTO ledger.posting(entry_id,account_id,asset_class,currency,amount)
        VALUES (e,b,'cash','USD',-100);
        INSERT INTO ledger.posting(entry_id,account_id,asset_class,instrument_id,amount)
        VALUES (e,a,'security',i2,100);
        SET CONSTRAINTS ALL IMMEDIATE;
    END $i$;
$q$, 'does not balance');
COMMIT;

-- History is immutable.
SELECT t.raises('ledger','posted rows cannot be UPDATEd',
    'UPDATE ledger.posting SET amount = 1 WHERE posting_id = (SELECT min(posting_id) FROM ledger.posting)',
    'append-only');
SELECT t.raises('ledger','posted rows cannot be DELETEd',
    'DELETE FROM ledger.posting WHERE posting_id = (SELECT min(posting_id) FROM ledger.posting)',
    'append-only');
SELECT t.raises('ledger','journal entries cannot be UPDATEd',
    'UPDATE ledger.journal_entry SET description = ''x'' WHERE entry_id = (SELECT min(entry_id) FROM ledger.journal_entry)',
    'append-only');

-- A cash account cannot be overdrawn.
SELECT t.raises('ledger','overdraft is impossible on a cash account', $q$
    SELECT ledger.post_entry('withdrawal','overdraw',
      ARRAY[ ROW((SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id)
                   WHERE u.email='alice@apex.io'),'cash',NULL,-99999999,NULL)::ledger.leg,
             ROW((SELECT account_id FROM trading.account WHERE system_code='EXTERNAL_CASH'),
                 'cash',NULL,99999999,NULL)::ledger.leg ]);
$q$, 'overdrawn');

-- A cash posting must not name an instrument, and vice versa.
SELECT t.raises('ledger','cash posting cannot carry an instrument', $q$
    DO $i$
    DECLARE e BIGINT;
    BEGIN
        INSERT INTO ledger.journal_entry(kind,description) VALUES ('adjustment','x') RETURNING entry_id INTO e;
        INSERT INTO ledger.posting(entry_id,account_id,asset_class,instrument_id,amount)
        VALUES (e,(SELECT account_id FROM trading.account WHERE system_code='HOUSE_FEES'),
                'cash',(SELECT instrument_id FROM reference.instrument LIMIT 1),10);
    END $i$;
$q$, 'asset_instrument_agreement');

-- Integrity proof passes.
DO $$
DECLARE v RECORD;
BEGIN
    FOR v IN SELECT * FROM ledger.verify_integrity() LOOP
        PERFORM t.ok('ledger','integrity: '||v.check_name, v.passed, v.detail);
    END LOOP;
END $$;
