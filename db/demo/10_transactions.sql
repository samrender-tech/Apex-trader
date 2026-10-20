-- =====================================================================
-- TRANSACTION CONTROL -- COMMIT, ROLLBACK, SAVEPOINT
--
--   ./scripts/db.sh psql -f db/demo/10_transactions.sql
--
-- Every write in this system already runs inside a transaction; the
-- matching engine depends on it. This file makes that visible, by
-- demonstrating the four properties against the real schema rather than
-- a toy table:
--
--   1. ROLLBACK undoes a multi-table change completely
--   2. COMMIT makes it durable
--   3. SAVEPOINT rolls back PART of a transaction
--   4. A DEFERRED constraint is not checked until COMMIT -- which is the
--      whole reason double-entry works here
-- =====================================================================

\echo ''
\echo '=== 1. ROLLBACK: an order and its audit row vanish together ==='

SELECT count(*) AS orders_before FROM trading.trade_order;

BEGIN;
    INSERT INTO trading.trade_order
        (account_id, instrument_id, side, kind, quantity, limit_price, tif, status)
    SELECT a.account_id, i.instrument_id, 'buy', 'limit', 1, 100.00, 'day', 'pending_new'
      FROM trading.account a, reference.instrument i
     WHERE a.is_system = FALSE AND i.symbol = 'AAPL'
     LIMIT 1;

    \echo '-- inside the transaction, the row exists:'
    SELECT count(*) AS orders_inside FROM trading.trade_order;
ROLLBACK;

\echo '-- after ROLLBACK, it never happened:'
SELECT count(*) AS orders_after FROM trading.trade_order;


\echo ''
\echo '=== 2. COMMIT: a funding entry is durable, and balances are DERIVED ==='

BEGIN;
    SELECT ledger.post_entry('deposit', 'transaction demo deposit',
        ARRAY[ ROW((SELECT account_id FROM trading.account WHERE system_code='EXTERNAL_CASH'),
                   'cash', NULL, -1000, 'USD')::ledger.leg,
               ROW((SELECT a.account_id FROM trading.account a
                      JOIN identity.app_user u USING(user_id)
                     WHERE u.email='samrender@apex.io'),
                   'cash', NULL,  1000, 'USD')::ledger.leg ]) AS entry_id;
COMMIT;

\echo '-- the balance is not a stored column; it is the sum of the journal:'
SELECT ledger.cash_balance(
         (SELECT a.account_id FROM trading.account a
            JOIN identity.app_user u USING(user_id)
           WHERE u.email='samrender@apex.io'), 'USD') AS cash_after_commit;


\echo ''
\echo '=== 3. SAVEPOINT: undo part of a transaction, keep the rest ==='

BEGIN;
    INSERT INTO reference.currency (code, name, symbol, minor_units)
    VALUES ('XTS', 'Test Currency One', 'T1', 2);

    SAVEPOINT after_first;

    INSERT INTO reference.currency (code, name, symbol, minor_units)
    VALUES ('XTT', 'Test Currency Two', 'T2', 2);

    \echo '-- both inserted so far:'
    SELECT code, name FROM reference.currency WHERE code IN ('XTS','XTT') ORDER BY code;

    ROLLBACK TO SAVEPOINT after_first;

    \echo '-- after ROLLBACK TO SAVEPOINT, only the first survives:'
    SELECT code, name FROM reference.currency WHERE code IN ('XTS','XTT') ORDER BY code;
ROLLBACK;

\echo '-- the outer ROLLBACK removed that one too:'
SELECT count(*) AS test_currencies FROM reference.currency WHERE code IN ('XTS','XTT');


\echo ''
\echo '=== 4. DEFERRED constraint: checked at COMMIT, not at INSERT ==='
\echo '-- A journal entry is legitimately unbalanced WHILE it is being'
\echo '-- written -- the legs arrive one row at a time. A normal CHECK'
\echo '-- would reject the first leg. A DEFERRABLE INITIALLY DEFERRED'
\echo '-- constraint trigger waits until COMMIT, when the entry is whole.'

BEGIN;
    -- A data-modifying statement cannot sit in a plain subquery; it has
    -- to be a CTE. WITH ... INSERT ... RETURNING is the standard way to
    -- capture a generated key in the same statement.
    CREATE TEMP TABLE demo_entry AS
    WITH new_entry AS (
        INSERT INTO ledger.journal_entry (kind, description)
        VALUES ('adjustment', 'deliberately unbalanced')
        RETURNING entry_id)
    SELECT entry_id FROM new_entry;

    INSERT INTO ledger.posting (entry_id, account_id, asset_class, amount, currency)
    SELECT (SELECT entry_id FROM demo_entry),
           (SELECT account_id FROM trading.account WHERE system_code='HOUSE_FEES'),
           'cash', 500, 'USD';

    \echo '-- the single leg INSERTed without complaint:'
    SELECT count(*) AS legs_so_far FROM ledger.posting
     WHERE entry_id = (SELECT entry_id FROM demo_entry);
\echo '-- now COMMIT, which is where the zero-sum rule is enforced:'
COMMIT;

\echo ''
\echo '-- ^ that COMMIT failed, and it was SUPPOSED to. 500 does not sum to'
\echo '--   zero, so the entry was refused as a whole. Value cannot be'
\echo '--   created, and no half-written entry survives.'
\echo ''

SELECT check_name, passed, detail FROM ledger.verify_integrity();
