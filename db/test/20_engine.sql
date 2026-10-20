-- =====================================================================
-- Suite: engine -- matching, order types, time-in-force, risk gates.
-- =====================================================================
\set QUIET on
\i db/test/_fixture.sql
\set QUIET off

DO $$
DECLARE
    v_iid INTEGER; v_alice BIGINT; v_bob BIGINT; v_carol BIGINT; v_dave BIGINT;
    r RECORD; v_o1 BIGINT; v_o2 BIGINT; v_o3 BIGINT;
    v_n INTEGER; v_px NUMERIC;
BEGIN
    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='AAPL';
    SELECT a.account_id INTO v_alice FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
    SELECT a.account_id INTO v_bob   FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io';
    SELECT a.account_id INTO v_carol FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='carol@apex.io';
    SELECT a.account_id INTO v_dave  FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='dave@apex.io';

    -- ---------- PRICE-TIME PRIORITY ----------
    SELECT order_id INTO v_o1 FROM engine.submit_order(v_bob,  v_iid,'sell','limit',100,182.50);
    SELECT order_id INTO v_o2 FROM engine.submit_order(v_carol,v_iid,'sell','limit',200,182.40);
    SELECT order_id INTO v_o3 FROM engine.submit_order(v_bob,  v_iid,'sell','limit',150,182.40);

    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',400,182.50);
    PERFORM t.eq('engine','aggressor fully filled sweeping 3 levels', r.filled_qty, 400::numeric);

    -- The earliest order at the best price must fill first.
    PERFORM t.eq('engine','price priority: 182.40 filled before 182.50',
        (SELECT e.price FROM trading.execution e ORDER BY e.execution_id LIMIT 1), 182.40::price_amt);
    PERFORM t.eq('engine','time priority: earlier order at same price fills first',
        (SELECT e.sell_order_id FROM trading.execution e ORDER BY e.execution_id LIMIT 1), v_o2);
    PERFORM t.eq('engine','second fill goes to the later order at the same price',
        (SELECT e.sell_order_id FROM trading.execution e ORDER BY e.execution_id OFFSET 1 LIMIT 1), v_o3);

    -- The resting order sets the price, so the aggressor is improved.
    PERFORM t.ok('engine','aggressor receives price improvement',
        r.avg_fill_price < 182.50, format('avg fill %s vs limit 182.50', r.avg_fill_price));

    -- Maker/taker fees are asymmetric.
    PERFORM t.ok('engine','taker pays more than maker',
        (SELECT e.buy_fee > e.sell_fee FROM trading.execution e ORDER BY e.execution_id LIMIT 1));

    -- ---------- SWEEP TAKES THE CHEAPEST LIQUIDITY FIRST ----------
    -- Bob's 182.50 order still has 50 left. An incoming buy must take
    -- that cheaper remainder BEFORE a more expensive order, even though
    -- the expensive one was entered later.
    SELECT order_id INTO v_o1 FROM engine.submit_order(v_carol,v_iid,'sell','limit',500,183.00);
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',120,183.00);
    PERFORM t.eq('engine','sweep fills in full across two price levels', r.filled_qty, 120::numeric);
    -- Only 70 of the 120 came from Carol: the engine took Bob's cheaper
    -- 50 @182.50 first, so Carol's 500 has 430 left, not 380.
    PERFORM t.eq('engine','cheaper leftover liquidity is consumed first',
        (SELECT leaves_qty FROM trading.trade_order WHERE order_id=v_o1), 430::numeric,
        'only 70 of the 120 came from Carol; Bob''s 50 @182.50 filled first');
    PERFORM t.eq('engine','partially filled order stays on the book',
        (SELECT status FROM trading.trade_order WHERE order_id=v_o1),
        'partially_filled'::trading.order_status);

    -- ---------- CLEAN BOOK from here on ----------
    PERFORM t.clear_book();

    -- ---------- MARKET ORDER does not rest ----------
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','market',100000);
    PERFORM t.ok('engine','market order with excess size does not rest',
        r.status IN ('cancelled','filled','rejected'), r.status::text);

    -- ---------- IOC ----------
    PERFORM t.clear_book();
    PERFORM engine.submit_order(v_bob, v_iid,'sell','limit',50,184.00);
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',500,184.00,NULL,'ioc');
    PERFORM t.eq('engine','IOC fills exactly the available liquidity', r.filled_qty, 50::numeric);
    PERFORM t.eq('engine','IOC cancels the remainder instead of resting',
                 r.status, 'cancelled'::trading.order_status);
    PERFORM t.eq('engine','IOC leaves nothing on the book',
        (SELECT count(*) FROM trading.v_book_depth WHERE instrument_id=v_iid AND side='buy'),
        0::bigint);

    -- ---------- FOK ----------
    PERFORM t.clear_book();
    PERFORM engine.submit_order(v_bob, v_iid,'sell','limit',40,185.00);
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',500,185.00,NULL,'fok');
    PERFORM t.eq('engine','FOK with insufficient liquidity fills nothing', r.filled_qty, 0::numeric);
    PERFORM t.eq('engine','FOK with insufficient liquidity is cancelled',
                 r.status, 'cancelled'::trading.order_status);
    PERFORM t.ok('engine','FOK leaves the resting order untouched',
        (SELECT leaves_qty FROM trading.trade_order
          WHERE instrument_id=v_iid AND limit_price=185.00 AND side='sell') = 40);

    -- FOK that CAN be satisfied must fill completely.
    SELECT * INTO r FROM engine.submit_order(v_alice,v_iid,'buy','limit',40,185.00,NULL,'fok');
    PERFORM t.eq('engine','satisfiable FOK fills in full', r.filled_qty, 40::numeric);

    -- ---------- STOP ORDER ELECTION ----------
    PERFORM t.clear_book();
    SELECT COUNT(*) INTO v_n FROM trading.execution;
    -- Dave places a sell stop below the market; it must not trade yet.
    PERFORM ledger.post_entry('adjustment','give dave shares',
        ARRAY[ ROW((SELECT account_id FROM trading.account WHERE system_code='SECURITY_FLOAT'),'security',v_iid,-1000,NULL)::ledger.leg,
               ROW(v_dave,'security',v_iid,1000,NULL)::ledger.leg ]);
    SELECT order_id INTO v_o1 FROM engine.submit_order(v_dave,v_iid,'sell','stop',100,NULL,170.00);
    PERFORM t.ok('engine','stop order is armed, not resting on the book',
        (SELECT stop_armed FROM trading.trade_order WHERE order_id=v_o1));
    PERFORM t.eq('engine','armed stop does not appear in the depth ladder',
        (SELECT count(*) FROM trading.v_book_depth WHERE instrument_id=v_iid AND side='sell' AND price=170.00),
        0::bigint);

    -- Trade down through the stop price to elect it.
    PERFORM engine.submit_order(v_carol,v_iid,'sell','limit',10,169.00);
    PERFORM engine.submit_order(v_alice,v_iid,'buy','limit',10,169.00);
    PERFORM t.ok('engine','stop is elected once its trigger price trades',
        NOT (SELECT stop_armed FROM trading.trade_order WHERE order_id=v_o1),
        (SELECT status::text FROM trading.trade_order WHERE order_id=v_o1));

    -- ---------- ICEBERG ----------
    PERFORM t.clear_book();
    SELECT order_id INTO v_o1 FROM engine.submit_order(
        v_bob,v_iid,'sell','iceberg',1000,190.00,NULL,'gtc',NULL,100);
    PERFORM t.eq('engine','iceberg shows only its display size publicly',
        (SELECT visible_qty FROM trading.v_book_depth
          WHERE instrument_id=v_iid AND side='sell' AND price=190.00), 100::numeric);
    PERFORM t.eq('engine','iceberg true size is tracked internally',
        (SELECT true_qty FROM trading.v_book_depth
          WHERE instrument_id=v_iid AND side='sell' AND price=190.00), 1000::numeric);

    -- ---------- IDEMPOTENCY ----------
    DECLARE v_key UUID := gen_random_uuid(); v_a BIGINT; v_b BIGINT;
    BEGIN
        SELECT order_id INTO v_a FROM engine.submit_order(
            v_alice,v_iid,'buy','limit',10,100.00,NULL,'gtc',NULL,NULL,v_key);
        SELECT order_id INTO v_b FROM engine.submit_order(
            v_alice,v_iid,'buy','limit',10,100.00,NULL,'gtc',NULL,NULL,v_key);
        PERFORM t.eq('engine','replaying a client_order_id returns the same order', v_b, v_a);
        PERFORM t.eq('engine','replay does not create a duplicate order',
            (SELECT count(*) FROM trading.trade_order WHERE client_order_id=v_key), 1::bigint);
    END;

    -- ---------- CANCEL ----------
    SELECT order_id INTO v_o1 FROM engine.submit_order(v_bob,v_iid,'sell','limit',100,195.00);
    PERFORM engine.cancel_order(v_o1);
    PERFORM t.eq('engine','cancel removes the order from the book',
        (SELECT status FROM trading.trade_order WHERE order_id=v_o1),
        'cancelled'::trading.order_status);
    PERFORM t.eq('engine','cancelled order leaves the depth ladder',
        (SELECT count(*) FROM trading.v_book_depth
          WHERE instrument_id=v_iid AND side='sell' AND price=195.00), 0::bigint);
END $$;

-- Cancelling someone else's order must fail.
SELECT t.raises('engine','cannot cancel another account''s order', $q$
    DO $i$
    DECLARE v_o BIGINT; v_bob BIGINT; v_alice BIGINT; v_iid INTEGER;
    BEGIN
        SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='AAPL';
        SELECT a.account_id INTO v_bob FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io';
        SELECT a.account_id INTO v_alice FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
        SELECT order_id INTO v_o FROM engine.submit_order(v_bob,v_iid,'sell','limit',10,199.00);
        PERFORM engine.cancel_order(v_o, v_alice);
    END $i$;
$q$, 'does not belong');

-- Already-filled orders cannot be cancelled.
SELECT t.raises('engine','cannot cancel a filled order', $q$
    SELECT engine.cancel_order((SELECT order_id FROM trading.trade_order WHERE status='filled' LIMIT 1));
$q$, 'cannot be cancelled');

-- Order-shape grammar is enforced by CHECK, not by application code.
SELECT t.raises('engine','market order may not carry a limit price',
    $q$INSERT INTO trading.trade_order (account_id,instrument_id,side,kind,quantity,limit_price)
       VALUES (1,(SELECT instrument_id FROM reference.instrument LIMIT 1),'buy','market',10,100)$q$,
    'order_shape_matches_kind');
SELECT t.raises('engine','limit order requires a limit price',
    $q$INSERT INTO trading.trade_order (account_id,instrument_id,side,kind,quantity)
       VALUES (1,(SELECT instrument_id FROM reference.instrument LIMIT 1),'buy','limit',10)$q$,
    'order_shape_matches_kind');
SELECT t.raises('engine','stop order requires a stop price',
    $q$INSERT INTO trading.trade_order (account_id,instrument_id,side,kind,quantity)
       VALUES (1,(SELECT instrument_id FROM reference.instrument LIMIT 1),'buy','stop',10)$q$,
    'order_shape_matches_kind');
SELECT t.raises('engine','an order cannot be filled beyond its quantity',
    $q$UPDATE trading.trade_order SET filled_qty = quantity + 1
        WHERE order_id = (SELECT min(order_id) FROM trading.trade_order)$q$,
    'fill_within_order');
