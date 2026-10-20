-- =====================================================================
-- Suite: risk -- the pre-trade gate.
-- =====================================================================
\set QUIET on
\i db/test/_fixture.sql
\set QUIET off

DO $$
DECLARE
    v_iid INTEGER; v_alice BIGINT; v_bob BIGINT; v_dave BIGINT; r RECORD;
BEGIN
    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='AAPL';
    SELECT a.account_id INTO v_alice FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
    SELECT a.account_id INTO v_bob   FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io';
    SELECT a.account_id INTO v_dave  FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='dave@apex.io';

    -- Buying power: Alice has 1,000,000 cash on a cash account.
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',100000,180.00);
    PERFORM t.eq('risk','order beyond buying power is rejected', r.status, 'rejected'::trading.order_status);
    PERFORM t.ok('risk','rejection explains which limit was hit',
        r.reject_reason LIKE '%exceeds your limit%'
     OR r.reject_reason LIKE '%buying power%', r.reject_reason);

    -- Short selling blocked on a cash account.
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'sell','limit',500,180.00);
    PERFORM t.eq('risk','naked short on a cash account is rejected', r.status, 'rejected'::trading.order_status);
    PERFORM t.ok('risk','short rejection names what you actually hold',
        r.reject_reason LIKE '%you hold%'
    AND r.reject_reason LIKE '%Short selling is not enabled%', r.reject_reason);

    -- Shares already committed to a resting sell cannot be sold twice.
    -- Sizes chosen to stay under the 1,000,000 per-order notional cap so
    -- that THIS rule is what rejects the second order, not that one.
    PERFORM t.clear_book();
    -- Bob holds 10,000. Commit 6,000, then try to sell 5,000 more:
    -- only 4,000 are left uncommitted, so the second order must fail.
    PERFORM engine.submit_order(v_bob,v_iid,'sell','limit',6000,150.00);
    PERFORM t.eq('risk','first sell order rests, committing the shares',
        (SELECT risk.open_sell_qty(v_bob,v_iid)), 6000::money_amt);
    SELECT * INTO r FROM engine.submit_order(v_bob,v_iid,'sell','limit',5000,150.00);
    PERFORM t.eq('risk','the same shares cannot back two sell orders',
                 r.status, 'rejected'::trading.order_status);
    PERFORM t.ok('risk','rejection accounts for shares committed to open orders',
        r.reject_reason LIKE '%committed to open sell orders%', r.reject_reason);

    -- The new short-selling gate, asserted directly.
    PERFORM t.ok('risk','a cash account may not go short',
        NOT (SELECT allow_short_selling FROM trading.account WHERE account_id=v_alice));
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'sell','limit',1,180.00);
    PERFORM t.ok('risk','selling one share you do not own is rejected',
        r.status = 'rejected' AND r.reject_reason LIKE '%Short selling is not enabled%',
        r.reject_reason);

    -- Tick size and lot size.
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',10,180.005);
    PERFORM t.eq('risk','sub-tick price is rejected', r.status, 'rejected'::trading.order_status);
    PERFORM t.ok('risk','tick rejection is explicit', r.reject_reason LIKE '%tick size%', r.reject_reason);

    -- Price band / fat-finger protection.
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',10,900.00);
    PERFORM t.eq('risk','price far outside the band is rejected', r.status, 'rejected'::trading.order_status);
    PERFORM t.ok('risk','band rejection reports the allowed range',
        r.reject_reason LIKE '%band%', r.reject_reason);

    -- Order notional cap.
    UPDATE risk.risk_limit SET max_order_notional = 1000 WHERE account_id = v_alice;
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',100,180.00);
    PERFORM t.eq('risk','per-order notional cap is enforced', r.status, 'rejected'::trading.order_status);
    UPDATE risk.risk_limit SET max_order_notional = 1000000 WHERE account_id = v_alice;

    -- Concentration limit.
    UPDATE risk.risk_limit SET max_position_pct_nav = 5 WHERE account_id = v_alice;
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',2000,180.00);
    PERFORM t.eq('risk','concentration limit is enforced', r.status, 'rejected'::trading.order_status);
    PERFORM t.ok('risk','concentration rejection reports the percentage',
        r.reject_reason LIKE '%of your portfolio%', r.reject_reason);
    UPDATE risk.risk_limit SET max_position_pct_nav = 40 WHERE account_id = v_alice;

    -- Suspended account cannot trade.
    UPDATE trading.account SET status='suspended' WHERE account_id = v_alice;
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',10,180.00);
    PERFORM t.eq('risk','suspended account is blocked', r.reject_reason, 'account_suspended');
    UPDATE trading.account SET status='active' WHERE account_id = v_alice;

    -- Trading halt blocks new orders.
    INSERT INTO risk.trading_halt (instrument_id, halted_until, reason)
    VALUES (v_iid, now() + INTERVAL '10 minutes', 'manual');
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',10,180.00);
    PERFORM t.eq('risk','halted instrument rejects orders', r.reject_reason, 'instrument_halted');
    DELETE FROM risk.trading_halt WHERE instrument_id = v_iid;

    -- Margin account gets leveraged buying power.
    PERFORM t.ok('risk','margin account buying power exceeds its cash',
        risk.buying_power(v_dave) > ledger.cash_balance(v_dave),
        format('bp=%s cash=%s', risk.buying_power(v_dave), ledger.cash_balance(v_dave)));
END $$;

-- Overlapping halts on one instrument are structurally impossible.
SELECT t.raises('risk','overlapping trading halts are rejected by the exclusion constraint', $q$
    DO $i$
    DECLARE v_iid INTEGER;
    BEGIN
        SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='MSFT';
        INSERT INTO risk.trading_halt (instrument_id, halted_from, halted_until, reason)
        VALUES (v_iid, now(), now() + INTERVAL '1 hour', 'manual');
        INSERT INTO risk.trading_halt (instrument_id, halted_from, halted_until, reason)
        VALUES (v_iid, now() + INTERVAL '30 minutes', now() + INTERVAL '2 hours', 'manual');
    END $i$;
$q$, 'no_overlapping_halts');

-- A trader must not be able to raise their own risk limits.
SELECT t.raises('risk','KYC state and timestamp cannot disagree',
    $q$UPDATE identity.app_user SET kyc_state='verified', kyc_verified_at=NULL
        WHERE email='alice@apex.io'$q$,
    'kyc_timestamp_consistent');

-- A delisted instrument cannot remain tradable.
SELECT t.raises('risk','delisted instrument cannot be tradable',
    $q$UPDATE reference.instrument SET delisted_on = CURRENT_DATE
        WHERE symbol='MSFT' AND is_tradable$q$,
    'delisted_not_tradable');

-- =====================================================================
-- Regression: the RLS predicate helper must not recurse.
--
-- identity.current_user_is_privileged() reads identity.app_user, and
-- identity.app_user's RLS policy calls that function. Without
-- SECURITY DEFINER this self-reference aborts every read of a user's own
-- profile with "stack depth limit exceeded". This asserts the guard is
-- in place, because the symptom only appears for non-superusers and is
-- therefore easy to miss in development.
-- =====================================================================
SELECT t.ok('risk','RLS helper is SECURITY DEFINER (no policy recursion)',
    (SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='identity' AND p.proname='current_user_is_privileged'));

SELECT t.ok('risk','RLS helper has a pinned search_path',
    (SELECT p.proconfig IS NOT NULL FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='identity' AND p.proname='current_user_is_privileged'));

-- =====================================================================
-- Regression: the SECURITY DEFINER RLS helper must test SESSION_USER,
-- not CURRENT_USER.
--
-- Inside a SECURITY DEFINER function current_user is the function owner.
-- The owner is a superuser, and pg_has_role() treats a superuser as a
-- member of every role -- so pg_has_role(current_user, 'apex_compliance',
-- 'MEMBER') returns TRUE for EVERY caller and silently disables Row Level
-- Security across the entire database. This bug is invisible when testing
-- as a superuser (RLS is bypassed anyway), so it needs a static check.
-- =====================================================================
SELECT t.ok('risk','RLS helper does not test current_user (privilege escalation)',
    (SELECT prosrc NOT LIKE '%pg_has_role(current_user%'
       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='identity' AND p.proname='current_user_is_privileged'));

SELECT t.ok('risk','RLS helper tests session_user instead',
    (SELECT prosrc LIKE '%pg_has_role(session_user%'
       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='identity' AND p.proname='current_user_is_privileged'));

-- Every RLS-protected table must actually have RLS enabled.
SELECT t.eq('risk','all tenant tables have RLS enabled',
    (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE c.relkind='r' AND NOT c.relrowsecurity
        AND (n.nspname||'.'||c.relname) IN (
            'identity.app_user','identity.user_session','trading.account',
            'trading.trade_order','trading.position','ledger.balance',
            'ledger.posting','risk.risk_limit','surveil.alert',
            'social.strategy','social.copy_subscription',
            'analytics.account_snapshot')),
    0::bigint);

-- ---------------------------------------------------------------------
-- Regression: a VIEW must not launder away the RLS policy underneath it.
--
-- RLS on the tables was proved above, and it was true -- for a query
-- against the table. Every view here is owned by the role that owns the
-- tables, and a view runs as its owner by default, and a table owner is
-- exempt from its own RLS. So reading the same data through a view
-- consulted no policy at all. /api/watchlist had no account predicate of
-- its own and returned every user's watchlists; the other endpoints were
-- masked only because they happened to filter in Python.
--
-- Migration 024 set security_invoker on the views over user data, and
-- ops.assert_rls_intact() makes the condition checkable rather than
-- remembered -- the next view added to these schemas has to make the
-- decision deliberately instead of inheriting the unsafe default.
-- ---------------------------------------------------------------------
SELECT t.eq('risk','no view bypasses the RLS underneath it',
    (SELECT count(*) FROM ops.assert_rls_intact() WHERE verdict LIKE 'LEAK%'),
    0::bigint);

SELECT t.ok('risk','the watchlist view runs as the caller, not the owner',
    (SELECT security_invoker FROM ops.assert_rls_intact()
      WHERE view_name = 'social.v_watchlist'));

-- The order book is the deliberate exception: depth is public market
-- data and must show every participant's size, not only the viewer's.
-- Pinned so that "fix the last two" cannot silently break the ladder.
SELECT t.ok('risk','the public depth ladder stays owner-run on purpose',
    (SELECT NOT security_invoker AND verdict NOT LIKE 'LEAK%'
       FROM ops.assert_rls_intact() WHERE view_name = 'trading.v_book_depth'));

-- Proving the policy BITES through the view cannot be done from this
-- suite, and the reason is worth writing down. identity.current_user_id()
-- reads a session GUC, so SET LOCAL ROLE + set_config() gets us most of
-- the way -- but the policy's second disjunct is
-- identity.current_user_is_privileged(), which tests SESSION_USER, and
-- SET ROLE does not change session_user. This suite runs as `apex`,
-- which is a member of the compliance role, so the bypass branch is
-- legitimately true for us no matter which role we assume.
--
-- The structural assertions above are what SQL can prove here. The
-- end-to-end proof -- two real logins, one view, no predicate, each
-- seeing only their own rows -- lives in scripts/api_smoke.py, where
-- the connection is genuinely a non-privileged one.
--
-- What CAN be checked from here is that the privileged branch is the
-- only reason this session sees everything.
SELECT t.ok('risk','this suite sees all watchlists only via the privileged branch',
    identity.current_user_is_privileged());

-- =====================================================================
-- Regression: audit tuning (017) must not lose compliance-relevant data.
--
-- 017 stopped auditing intermediate matching state to cut ~70% off order
-- latency. These assertions pin down exactly what must still be captured,
-- so a future tweak cannot quietly drop a regulator-relevant event.
-- =====================================================================
DO $$
DECLARE
    v_iid INTEGER; v_alice BIGINT; v_bob BIGINT; v_o BIGINT; r RECORD;
    v_n0 BIGINT; v_n1 BIGINT;
BEGIN
    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='AAPL';
    SELECT a.account_id INTO v_alice FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
    SELECT a.account_id INTO v_bob   FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io';
    PERFORM t.clear_book();

    -- Order creation is always audited.
    SELECT count(*) INTO v_n0 FROM audit.activity_log WHERE table_name='trade_order';
    SELECT order_id INTO v_o FROM engine.submit_order(v_bob,v_iid,'sell','limit',10,181.00);
    SELECT count(*) INTO v_n1 FROM audit.activity_log WHERE table_name='trade_order';
    PERFORM t.ok('risk','order creation is audited', v_n1 > v_n0,
                 format('%s new audit row(s)', v_n1 - v_n0));

    -- Cancellation (a terminal state) is audited.
    SELECT count(*) INTO v_n0 FROM audit.activity_log WHERE table_name='trade_order' AND operation='UPDATE';
    PERFORM engine.cancel_order(v_o);
    SELECT count(*) INTO v_n1 FROM audit.activity_log WHERE table_name='trade_order' AND operation='UPDATE';
    PERFORM t.ok('risk','order cancellation is audited', v_n1 > v_n0);

    -- A risk rejection is audited, with its reason.
    SELECT count(*) INTO v_n0 FROM audit.activity_log WHERE table_name='trade_order' AND operation='UPDATE';
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',9999999,181.00);
    SELECT count(*) INTO v_n1 FROM audit.activity_log WHERE table_name='trade_order' AND operation='UPDATE';
    PERFORM t.ok('risk','order rejection is audited', v_n1 > v_n0, r.reject_reason);

    -- The RESTING order's partial-fill churn is NOT audited: it goes
    -- working -> partially_filled -> partially_filled, none of which is
    -- a terminal state. That detail lives in trading.execution instead.
    PERFORM t.clear_book();
    SELECT order_id INTO v_o FROM engine.submit_order(v_bob,v_iid,'sell','limit',100,181.00);
    PERFORM engine.submit_order(v_alice,v_iid,'buy','limit',10,181.00);   -- partial fill
    PERFORM engine.submit_order(v_alice,v_iid,'buy','limit',10,181.00);   -- partial fill

    PERFORM t.eq('risk','resting order partial-fill churn is not audited',
        (SELECT count(*) FROM audit.activity_log
          WHERE table_name='trade_order' AND operation='UPDATE'
            AND row_key = v_o::text), 0::bigint,
        'fills are recorded in trading.execution instead');

    PERFORM t.eq('risk','the resting order really did partially fill',
        (SELECT filled_qty::numeric FROM trading.trade_order WHERE order_id=v_o), 20::numeric);

    -- But an order reaching a TERMINAL state is always audited, including
    -- the aggressors that filled completely here.
    PERFORM t.ok('risk','aggressor orders reaching filled are audited',
        (SELECT count(*) FROM audit.activity_log al
          WHERE al.table_name='trade_order' AND al.operation='UPDATE'
            AND al.new_row->>'status' = 'filled') >= 2);

    -- ...and the fills themselves ARE still fully recorded.
    PERFORM t.eq('risk','every fill is recorded on the tape',
        (SELECT count(*) FROM trading.execution e
          WHERE e.instrument_id=v_iid AND e.price=181.00), 2::bigint);
END $$;

-- The write-amplifying GIN indexes must stay gone.
SELECT t.eq('risk','unused GIN index on audit payload stays dropped',
    (SELECT count(*) FROM pg_indexes
      WHERE schemaname='audit' AND indexname IN ('ix_audit_newrow','ix_audit_changed')),
    0::bigint);
