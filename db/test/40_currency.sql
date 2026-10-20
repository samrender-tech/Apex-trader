-- =====================================================================
-- Suite: currency -- FX rates, conversion, and cross-currency settlement.
--
-- This suite exists because migration 019 once aborted halfway and left
-- the database with no convert_currency and no FX board at all, and the
-- whole test run still passed -- nothing exercised the currency path.
-- A feature with no test is a feature that can vanish silently.
-- =====================================================================
\set QUIET on
\i db/test/_fixture.sql
\set QUIET off

-- ---- the migration actually completed ----
SELECT t.ok('currency','convert_currency exists',
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='ledger' AND p.proname='convert_currency') = 1);
SELECT t.ok('currency','ensure_currency exists with the timestamp argument',
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='ledger' AND p.proname='ensure_currency') = 1);
SELECT t.ok('currency','cash_balance takes a currency',
    (SELECT pg_get_function_identity_arguments(p.oid) LIKE '%currency%'
       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='ledger' AND p.proname='cash_balance'));
SELECT t.ok('currency','FX board view exists and is populated',
    (SELECT count(*) FROM analytics.v_fx_board) >= 5);
SELECT t.ok('currency','no ambiguous function overloads anywhere',
    (SELECT count(*) FROM (
        SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname IN ('ledger','risk','engine','trading','market',
                             'reference','analytics','ops','social','surveil')
         GROUP BY n.nspname, p.proname HAVING count(*) > 1) x) = 0);

-- ---- rate arithmetic ----
SELECT t.eq('currency','a currency converts to itself at 1',
    reference.fx_rate_at('USD','USD'), 1::numeric);
SELECT t.ok('currency','direct pair is read from the table',
    reference.fx_rate_at('USD','INR') > 50);
SELECT t.ok('currency','inverse is the reciprocal of the direct rate',
    abs(reference.fx_rate_at('INR','USD')
        - 1/reference.fx_rate_at('USD','INR')) < 1e-9,
    'so USD/INR and INR/USD can never disagree');
SELECT t.ok('currency','cross rate triangulates through USD',
    abs(reference.fx_rate_at('INR','EUR')
        - (reference.fx_rate_at('USD','EUR') / reference.fx_rate_at('USD','INR'))) < 1e-9);
SELECT t.ok('currency','a round trip returns roughly the original amount',
    abs(reference.fx_convert(reference.fx_convert(1000,'USD','INR'),'INR','USD') - 1000) < 1);
SELECT t.raises('currency','an unknown currency raises',
    $q$SELECT reference.fx_rate_at('USD','XYZ')$q$, 'no FX rate');

-- ---- historical rates ----
SELECT t.ok('currency','a rate exists for any historical instant',
    reference.fx_rate_at('USD','INR', now() - INTERVAL '5 years') > 0,
    'baseline rows are dated far in the past so backfill can convert');

DO $$
DECLARE
    v_acct BIGINT; v_bank BIGINT; v_iid INTEGER; r RECORD;
    v_usd0 money_amt; v_inr0 money_amt; v_entry BIGINT; v_legs INTEGER;
BEGIN
    SELECT a.account_id INTO v_acct FROM trading.account a
      JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
    SELECT account_id INTO v_bank FROM trading.account WHERE system_code='EXTERNAL_CASH';
    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='AAPL';

    -- ---- conversion mechanics ----
    v_usd0 := ledger.cash_balance(v_acct,'USD');
    SELECT * INTO r FROM ledger.convert_currency(v_acct,'USD','INR',10000,'test');
    v_entry := r.entry_id;

    PERFORM t.eq('currency','conversion books exactly four legs',
        (SELECT count(*) FROM ledger.posting WHERE entry_id = v_entry), 4::bigint);
    PERFORM t.eq('currency','the source currency balances to zero',
        (SELECT sum(amount) FROM ledger.posting
          WHERE entry_id=v_entry AND currency='USD')::money_amt, 0::money_amt);
    PERFORM t.eq('currency','the destination currency balances to zero',
        (SELECT sum(amount) FROM ledger.posting
          WHERE entry_id=v_entry AND currency='INR')::money_amt, 0::money_amt);
    PERFORM t.eq('currency','USD left the account',
        ledger.cash_balance(v_acct,'USD'), (v_usd0 - 10000)::money_amt);
    PERFORM t.eq('currency','INR arrived in the account',
        ledger.cash_balance(v_acct,'INR'), r.amount_to);
    PERFORM t.ok('currency','the FX desk takes the other side',
        (SELECT count(*) FROM ledger.posting p
           JOIN trading.account a USING (account_id)
          WHERE p.entry_id=v_entry AND a.system_code='FX_DESK') = 2);

    PERFORM t.ok('currency','cash_total_in sums across currencies',
        ledger.cash_total_in(v_acct,'USD') > 0
    AND abs(ledger.cash_total_in(v_acct,'USD')
            - (ledger.cash_balance(v_acct,'USD')
               + reference.fx_convert(ledger.cash_balance(v_acct,'INR'),'INR','USD'))) < 1);

    PERFORM t.eq('currency','cash_by_currency reports both holdings',
        (SELECT count(*) FROM ledger.cash_by_currency(v_acct)), 2::bigint);

    -- ---- cross-currency settlement ----
    -- Move every dollar out, then buy a USD-priced stock anyway.
    PERFORM ledger.convert_currency(v_acct,'USD','INR',
            ledger.cash_balance(v_acct,'USD'),'drain USD');
    PERFORM t.eq('currency','the account now holds no USD at all',
        ledger.cash_balance(v_acct,'USD'), 0::money_amt);

    PERFORM engine.submit_order(
        (SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id)
          WHERE u.email='bob@apex.io'), v_iid,'sell','limit',10,182.00);
    SELECT * INTO r FROM engine.submit_order(v_acct,v_iid,'buy','limit',10,182.00);

    PERFORM t.eq('currency','a rupee-only account can still buy a dollar stock',
        r.status, 'filled'::trading.order_status, r.reject_reason);
    PERFORM t.ok('currency','the broker booked an auto-conversion for it',
        EXISTS (SELECT 1 FROM ledger.journal_entry
                 WHERE kind='fx_conversion'
                   AND description LIKE '%Auto-conversion%'));
    PERFORM t.ok('currency','settlement happened in the instrument currency',
        (SELECT bool_and(p.currency = i.currency)
           FROM ledger.posting p
           JOIN ledger.journal_entry je USING (entry_id)
           CROSS JOIN reference.instrument i
          WHERE je.kind='trade_settlement' AND p.asset_class='cash'
            AND i.instrument_id = v_iid));
END $$;

-- ---- shape constraints ----
SELECT t.raises('currency','a cash posting without a currency is rejected',
    $q$DO $i$
       DECLARE e BIGINT;
       BEGIN
         INSERT INTO ledger.journal_entry(kind,description)
         VALUES ('adjustment','no ccy') RETURNING entry_id INTO e;
         INSERT INTO ledger.posting(entry_id,account_id,asset_class,amount)
         VALUES (e,(SELECT account_id FROM trading.account WHERE system_code='HOUSE_FEES'),
                 'cash',10);
       END $i$;$q$, 'asset_instrument_agreement');

SELECT t.raises('currency','a security posting may not carry a currency',
    $q$DO $i$
       DECLARE e BIGINT;
       BEGIN
         INSERT INTO ledger.journal_entry(kind,description)
         VALUES ('adjustment','ccy on security') RETURNING entry_id INTO e;
         INSERT INTO ledger.posting(entry_id,account_id,asset_class,instrument_id,currency,amount)
         VALUES (e,(SELECT account_id FROM trading.account WHERE system_code='SECURITY_FLOAT'),
                 'security',(SELECT instrument_id FROM reference.instrument LIMIT 1),'USD',10);
       END $i$;$q$, 'asset_instrument_agreement');

-- Mixing currencies inside one entry must not balance by accident.
SELECT t.raises('currency','dollars cannot settle a rupee deficit',
    $q$DO $i$
       DECLARE e BIGINT; a BIGINT; b BIGINT;
       BEGIN
         SELECT account_id INTO b FROM trading.account WHERE system_code='EXTERNAL_CASH';
         SELECT a2.account_id INTO a FROM trading.account a2
           JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
         INSERT INTO ledger.journal_entry(kind,description)
         VALUES ('adjustment','mixed ccy') RETURNING entry_id INTO e;
         INSERT INTO ledger.posting(entry_id,account_id,asset_class,currency,amount)
         VALUES (e,b,'cash','USD',-100), (e,a,'cash','INR',100);
         SET CONSTRAINTS ALL IMMEDIATE;
       END $i$;$q$, 'does not balance');

-- ---- integrity still holds ----
DO $$
DECLARE v RECORD;
BEGIN
    FOR v IN SELECT * FROM ledger.verify_integrity() LOOP
        PERFORM t.ok('currency','integrity: '||v.check_name, v.passed, v.detail);
    END LOOP;
END $$;
