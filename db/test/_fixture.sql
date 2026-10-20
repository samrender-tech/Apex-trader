-- Deterministic fixture used by the test suite: one exchange, two
-- instruments, four funded traders with share inventory.
--
-- Wrapped in a single transaction on purpose. The API's ingestion worker
-- may be running and inserting ticks every few seconds; without this the
-- wipe races it and `DELETE FROM reference.instrument` fails on a freshly
-- inserted tick's foreign key. TRUNCATE takes ACCESS EXCLUSIVE, so inside
-- one transaction the worker simply waits.
BEGIN;
TRUNCATE trading.execution, ledger.posting, ledger.journal_entry, ledger.balance,
         trading.position, trading.trade_order, market.tick, market.quote,
         market.candle_1m, risk.trading_halt, risk.margin_call, surveil.alert,
         social.copy_link, social.copy_queue, social.copy_subscription,
         social.follow, social.strategy, analytics.account_snapshot,
         audit.activity_log,
         -- Append-only and FK-restricted; only TRUNCATE can clear them.
         risk.alert_fire, risk.price_alert,
         social.watchlist_item, social.watchlist CASCADE;
DELETE FROM reference.corporate_action;
DELETE FROM reference.trading_session;
DELETE FROM trading.account WHERE NOT is_system;
DELETE FROM identity.app_user;
DELETE FROM reference.instrument;
DELETE FROM reference.exchange;
ALTER SEQUENCE engine.order_seq RESTART WITH 1;

INSERT INTO reference.exchange (code,name,country_code,timezone,currency,session_open,session_close)
VALUES ('XNAS','Nasdaq','US','America/New_York','USD','09:30','16:00');

INSERT INTO reference.instrument (symbol,exchange_id,name,sector,tick_size,lot_size,is_shortable)
SELECT v.sym, e.exchange_id, v.nm, 'Technology', 0.01, 1, TRUE
  FROM reference.exchange e,
       (VALUES ('AAPL','Apple Inc.'),('MSFT','Microsoft Corp.')) AS v(sym,nm)
 WHERE e.code='XNAS';

INSERT INTO market.quote (instrument_id, prev_close, reference_price)
SELECT instrument_id, 180.00, 180.00 FROM reference.instrument;

INSERT INTO identity.app_user (email,password_hash,full_name,kyc_state,kyc_verified_at) VALUES
 ('alice@apex.io', identity.hash_password('pw'), 'Alice Buyer',  'verified', now()),
 ('bob@apex.io',   identity.hash_password('pw'), 'Bob Seller',   'verified', now()),
 ('carol@apex.io', identity.hash_password('pw'), 'Carol Seller', 'verified', now()),
 ('dave@apex.io',  identity.hash_password('pw'), 'Dave Margin',  'verified', now());

INSERT INTO trading.account (account_no,user_id,kind,leverage)
SELECT 'APX-'||lpad(u.user_id::text,5,'0'), u.user_id,
       CASE WHEN u.email='dave@apex.io' THEN 'margin' ELSE 'cash' END::trading.account_kind,
       CASE WHEN u.email='dave@apex.io' THEN 4.00 ELSE 1.00 END
  FROM identity.app_user u;

DO $$
DECLARE v_bank BIGINT; v_float BIGINT; v_a RECORD; v_i RECORD;
BEGIN
  SELECT account_id INTO v_bank  FROM trading.account WHERE system_code='EXTERNAL_CASH';
  SELECT account_id INTO v_float FROM trading.account WHERE system_code='SECURITY_FLOAT';

  FOR v_a IN SELECT account_id FROM trading.account WHERE NOT is_system LOOP
    PERFORM ledger.post_entry('deposit','Initial funding',
      ARRAY[ ROW(v_bank,'cash',NULL,-1000000,NULL)::ledger.leg,
             ROW(v_a.account_id,'cash',NULL,1000000,NULL)::ledger.leg ]);
  END LOOP;

  -- Bob and Carol hold inventory to sell.
  FOR v_a IN SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id)
              WHERE u.email IN ('bob@apex.io','carol@apex.io') LOOP
    FOR v_i IN SELECT instrument_id FROM reference.instrument LOOP
      PERFORM ledger.post_entry('adjustment','Share issuance',
        ARRAY[ ROW(v_float,'security',v_i.instrument_id,-10000,NULL)::ledger.leg,
               ROW(v_a.account_id,'security',v_i.instrument_id,10000,NULL)::ledger.leg ]);
      -- Shares that arrive outside the engine still need a cost basis.
      PERFORM trading.set_cost_basis(v_a.account_id, v_i.instrument_id, 180.00);
    END LOOP;
  END LOOP;
END $$;

COMMIT;
