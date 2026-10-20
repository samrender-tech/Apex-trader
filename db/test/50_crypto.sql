-- =====================================================================
-- Suite: crypto -- 24x7 instruments, candle provenance, tick grids.
--
-- Every assertion here exists because something broke. Crypto was the
-- first asset class on this venue whose history has no gap between
-- "yesterday's close" and "now", and that exposed assumptions the
-- equity-only code had been getting away with.
-- =====================================================================
\set QUIET on
\i db/test/_fixture.sql
\set QUIET off

-- ---------------------------------------------------------------------
-- Crypto fixture. _fixture.sql deliberately wipes reference.instrument,
-- so the crypto listings created by migration 022 go with it. Rebuild
-- them from the same function the seeder uses -- never a second copy of
-- the definition, or the test stops testing what ships.
--
-- Then plant a short run of BACKFILLED bars ending at the current minute.
-- That overlap between loaded history and the live tick window is the
-- precise condition that only a 24x7 instrument creates, and it is what
-- the provenance guard exists for.
-- ---------------------------------------------------------------------
BEGIN;
SELECT reference.ensure_crypto_instruments();

INSERT INTO market.candle_1m
      (instrument_id, bucket_start, open, high, low, close,
       volume, trade_count, vwap, source)
SELECT i.instrument_id,
       date_trunc('minute', now()) - (g || ' minutes')::interval,
       p.px, p.px * 1.001, p.px * 0.999, p.px,
       1110, 12, p.px, 'backfill'
  FROM reference.instrument i
  CROSS JOIN generate_series(0, 120) AS g
  CROSS JOIN LATERAL (SELECT CASE i.symbol
                               WHEN 'BTC-USD'  THEN 92000.00
                               WHEN 'ETH-USD'  THEN  4200.00
                               WHEN 'SOL-USD'  THEN   310.00
                               WHEN 'AVAX-USD' THEN    25.00
                               WHEN 'LINK-USD' THEN    33.00
                               WHEN 'XRP-USD'  THEN     0.7200
                               WHEN 'ADA-USD'  THEN     0.3900
                               WHEN 'DOGE-USD' THEN     0.12700
                             END AS px) p
 WHERE i.kind = 'crypto';

INSERT INTO market.quote (instrument_id, last_price, prev_close, reference_price)
SELECT c.instrument_id, c.close, c.close, c.close
  FROM (SELECT DISTINCT ON (instrument_id) instrument_id, close
          FROM market.candle_1m ORDER BY instrument_id, bucket_start DESC) c
  JOIN reference.instrument i USING (instrument_id)
 WHERE i.kind = 'crypto'
ON CONFLICT (instrument_id) DO UPDATE
   SET last_price = EXCLUDED.last_price,
       reference_price = EXCLUDED.reference_price;

-- Give one trader coin inventory so the sell side of each book can rest.
DO $$
DECLARE v_float BIGINT; v_bob BIGINT; v_i RECORD;
BEGIN
    SELECT account_id INTO v_float FROM trading.account WHERE system_code='SECURITY_FLOAT';
    SELECT a.account_id INTO v_bob FROM trading.account a
      JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io';
    FOR v_i IN SELECT instrument_id FROM reference.instrument WHERE kind='crypto' LOOP
        PERFORM ledger.post_entry('adjustment','Coin issuance',
          ARRAY[ ROW(v_float,'security',v_i.instrument_id,-50,NULL)::ledger.leg,
                 ROW(v_bob, 'security',v_i.instrument_id, 50,NULL)::ledger.leg ]);
        PERFORM trading.set_cost_basis(v_bob, v_i.instrument_id,
                (SELECT last_price FROM market.quote WHERE instrument_id=v_i.instrument_id));
    END LOOP;
END $$;
COMMIT;

-- ---------------------------------------------------------------------
-- Listings exist and are marked as never closing.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_n BIGINT;
BEGIN
    SELECT count(*) INTO v_n FROM reference.instrument WHERE kind='crypto';
    PERFORM t.ok('crypto','crypto instruments are listed', v_n >= 8, v_n::text);

    SELECT count(*) INTO v_n FROM reference.instrument
     WHERE kind='crypto' AND NOT trades_24x7;
    PERFORM t.eq('crypto','every crypto listing trades 24x7', v_n, 0::bigint);

    SELECT count(*) INTO v_n FROM reference.instrument
     WHERE kind='crypto' AND tick_size > 0.01;
    PERFORM t.eq('crypto','no crypto listing uses a coarser tick than a stock', v_n, 0::bigint);

    -- A sub-dollar coin needs a sub-cent tick or its book collapses onto
    -- a handful of price levels.
    SELECT count(*) INTO v_n
      FROM reference.instrument i JOIN market.quote q USING (instrument_id)
     WHERE i.kind='crypto' AND q.last_price < 1 AND i.tick_size >= 0.01;
    PERFORM t.eq('crypto','sub-dollar coins have a sub-cent tick', v_n, 0::bigint);

    -- Fractional lots: nobody buys whole bitcoins.
    SELECT count(*) INTO v_n FROM reference.instrument
     WHERE kind='crypto' AND lot_size >= 1;
    PERFORM t.eq('crypto','crypto lots are fractional', v_n, 0::bigint);
END $$;

-- ---------------------------------------------------------------------
-- Market hours: equities close, crypto does not.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_open BOOLEAN; v_iid INTEGER;
BEGIN
    SELECT instrument_id INTO v_iid FROM reference.instrument
     WHERE kind='crypto' LIMIT 1;
    -- 03:00 UTC on a Sunday: no equity market on earth is open.
    SELECT reference.is_instrument_open(v_iid, '2026-10-11 03:00:00+00')
      INTO v_open;
    PERFORM t.ok('crypto','crypto is open on a Sunday night', v_open);

    SELECT instrument_id INTO v_iid FROM reference.instrument
     WHERE symbol='AAPL';
    SELECT reference.is_instrument_open(v_iid, '2026-10-11 03:00:00+00')
      INTO v_open;
    PERFORM t.ok('crypto','an equity is closed on a Sunday night', NOT v_open);
END $$;

-- ---------------------------------------------------------------------
-- CANDLE PROVENANCE
--
-- The bug: build_candles_1m() rolls the last 15 minutes of ticks into
-- bars every poll with an UPSERT. For an equity the backfill stops at
-- the previous close, so the windows never meet. Crypto's backfill runs
-- to the current minute, so the roller landed straight on top of real
-- bars and replaced a 1,110-volume bar with one built from two unit
-- ticks -- which then became the reference mark, which then made the
-- price band reject every order on the book.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_iid INTEGER; v_bucket TIMESTAMPTZ;
    v_close price_amt; v_vol qty_amt0; v_written INTEGER;
BEGIN
    SELECT i.instrument_id INTO v_iid
      FROM reference.instrument i WHERE i.kind='crypto'
       AND EXISTS (SELECT 1 FROM market.candle_1m c
                    WHERE c.instrument_id=i.instrument_id AND c.source='backfill')
     LIMIT 1;
    PERFORM t.ok('crypto','crypto has backfilled candle history', v_iid IS NOT NULL);

    SELECT c.bucket_start, c.close, c.volume INTO v_bucket, v_close, v_vol
      FROM market.candle_1m c
     WHERE c.instrument_id=v_iid AND c.source='backfill'
     ORDER BY c.bucket_start DESC LIMIT 1;

    -- Plant a tick inside that bar at a wildly wrong price, then roll.
    INSERT INTO market.tick (instrument_id, ts, price, volume, source)
    VALUES (v_iid, v_bucket + INTERVAL '10 seconds', v_close * 100, 1, 'test');

    SELECT market.build_candles_1m(v_bucket, v_bucket + INTERVAL '1 minute', v_iid)
      INTO v_written;
    PERFORM t.eq('crypto','roller writes no bar over backfilled history', v_written, 0);

    PERFORM t.eq('crypto','backfilled close survives a contradicting tick',
        (SELECT close FROM market.candle_1m
          WHERE instrument_id=v_iid AND bucket_start=v_bucket), v_close);
    PERFORM t.eq('crypto','backfilled volume survives a contradicting tick',
        (SELECT volume FROM market.candle_1m
          WHERE instrument_id=v_iid AND bucket_start=v_bucket), v_vol);

    -- The same roll over a window the backfill does NOT own must still
    -- work -- the guard protects history, it does not disable the roller.
    INSERT INTO market.tick (instrument_id, ts, price, volume, source)
    VALUES (v_iid, v_bucket + INTERVAL '1 minute 5 seconds', v_close, 3, 'test'),
           (v_iid, v_bucket + INTERVAL '1 minute 40 seconds', v_close, 4, 'test');
    SELECT market.build_candles_1m(v_bucket + INTERVAL '1 minute',
                                   v_bucket + INTERVAL '2 minutes', v_iid)
      INTO v_written;
    PERFORM t.eq('crypto','roller still builds bars it owns', v_written, 1);
    PERFORM t.eq('crypto','tick-built bar is marked as such',
        (SELECT source FROM market.candle_1m
          WHERE instrument_id=v_iid AND bucket_start=v_bucket + INTERVAL '1 minute'),
        'tick');
    PERFORM t.eq('crypto','tick-built bar sums its tick volume',
        (SELECT volume FROM market.candle_1m
          WHERE instrument_id=v_iid AND bucket_start=v_bucket + INTERVAL '1 minute'),
        7::qty_amt0);

    -- Idempotent: rolling the same window twice must not double-count.
    PERFORM market.build_candles_1m(v_bucket + INTERVAL '1 minute',
                                    v_bucket + INTERVAL '2 minutes', v_iid);
    PERFORM t.eq('crypto','re-rolling a window does not double-count volume',
        (SELECT volume FROM market.candle_1m
          WHERE instrument_id=v_iid AND bucket_start=v_bucket + INTERVAL '1 minute'),
        7::qty_amt0);

    DELETE FROM market.tick WHERE instrument_id=v_iid AND source='test';
    DELETE FROM market.candle_1m
     WHERE instrument_id=v_iid AND bucket_start=v_bucket + INTERVAL '1 minute'
       AND source='tick';
END $$;

-- ---------------------------------------------------------------------
-- No candle may carry an unknown provenance, and the backfill must
-- actually be marked -- a seeder that forgets re-opens the bug.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_n BIGINT;
BEGIN
    SELECT count(*) INTO v_n FROM market.candle_1m WHERE source='backfill';
    PERFORM t.ok('crypto','loaded history is marked backfill', v_n > 0, v_n::text);
    SELECT count(*) INTO v_n FROM market.candle_1m WHERE source NOT IN ('tick','backfill','provider');
    PERFORM t.eq('crypto','no candle carries an unknown provenance', v_n, 0::bigint);
END $$;

-- ---------------------------------------------------------------------
-- TICK ALIGNMENT
--
-- align_price() replaced ROUND(x,2) everywhere a price is computed.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_iid INTEGER; v_p price_amt;
BEGIN
    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='DOGE-USD';

    SELECT reference.align_price(v_iid, 0.123456789) INTO v_p;
    PERFORM t.eq('crypto','align_price snaps to a 0.00001 tick', v_p, 0.12346::price_amt);

    -- The old behaviour, for contrast: ROUND(0.123456789, 2) = 0.12,
    -- which is 1,234 ticks away from the real price.
    PERFORM t.ok('crypto','align_price beats rounding to 2dp',
        reference.align_price(v_iid, 0.123456789) <> ROUND(0.123456789, 2));

    SELECT reference.align_price(v_iid, 0.0000000001) INTO v_p;
    PERFORM t.eq('crypto','align_price never returns below one tick',
                 v_p, 0.00001::price_amt);

    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='AAPL';
    PERFORM t.eq('crypto','align_price leaves an equity on the cent grid',
                 reference.align_price(v_iid, 195.004), 195.00::price_amt);
END $$;

-- ---------------------------------------------------------------------
-- Every resting price on every book sits on its instrument's tick grid.
-- The market maker used to floor its spread at 0.01, which on a 0.00001
-- tick is a 1,000-tick spread -- and the resulting prices failed the
-- engine's own validation, so most crypto books had no quotes at all.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_n BIGINT; v_alice BIGINT; v_bob BIGINT; v_i RECORD;
    v_mid price_amt; v_spread NUMERIC; v_placed INTEGER := 0;
BEGIN
    SELECT a.account_id INTO v_alice FROM trading.account a
      JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io';
    SELECT a.account_id INTO v_bob FROM trading.account a
      JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io';

    FOR v_i IN SELECT instrument_id, tick_size, lot_size, symbol
                 FROM reference.instrument WHERE kind='crypto' LOOP
        SELECT last_price INTO v_mid FROM market.quote
         WHERE instrument_id = v_i.instrument_id;
        -- Four basis points, floored at one tick -- the production rule.
        v_spread := GREATEST(ROUND(v_mid * 0.0004 / v_i.tick_size) * v_i.tick_size,
                             v_i.tick_size);
        BEGIN
            PERFORM engine.submit_order(v_alice, v_i.instrument_id, 'buy', 'limit',
                     (10 / v_mid)::qty_amt,
                     reference.align_price(v_i.instrument_id, v_mid - v_spread),
                     NULL, 'gtc');
            PERFORM engine.submit_order(v_bob, v_i.instrument_id, 'sell', 'limit',
                     (10 / v_mid)::qty_amt,
                     reference.align_price(v_i.instrument_id, v_mid + v_spread),
                     NULL, 'gtc');
            v_placed := v_placed + 1;
        EXCEPTION WHEN OTHERS THEN
            PERFORM t.ok('crypto','engine accepts a tick-aligned '||v_i.symbol||
                         ' quote', FALSE, SQLERRM);
        END;
    END LOOP;

    PERFORM t.eq('crypto','engine quotes both sides of every crypto book',
                 v_placed, 8);

    SELECT count(*) INTO v_n
      FROM trading.trade_order o JOIN reference.instrument i USING (instrument_id)
     WHERE o.status IN ('working','partially_filled')
       AND o.limit_price IS NOT NULL
       AND MOD(o.limit_price, i.tick_size) <> 0;
    PERFORM t.eq('crypto','every resting price is on the tick grid', v_n, 0::bigint);

    SELECT count(DISTINCT i.instrument_id) INTO v_n
      FROM reference.instrument i
     WHERE i.kind='crypto'
       AND EXISTS (SELECT 1 FROM trading.trade_order o
                    WHERE o.instrument_id=i.instrument_id
                      AND o.status IN ('working','partially_filled'));
    PERFORM t.ok('crypto','every crypto book has a resting quote', v_n = 8, v_n::text);

    -- A sub-cent quote must survive a round trip through the book intact.
    SELECT instrument_id INTO v_n FROM reference.instrument WHERE symbol='DOGE-USD';
    PERFORM t.ok('crypto','a sub-cent quote keeps its precision on the book',
        EXISTS (SELECT 1 FROM trading.trade_order
                 WHERE instrument_id = v_n::INTEGER AND side='buy'
                   AND status='working'
                   AND limit_price < 0.127 AND limit_price > 0.1265),
        (SELECT limit_price::text FROM trading.trade_order
          WHERE instrument_id = v_n::INTEGER AND side='buy' AND status='working'
          LIMIT 1));
END $$;

-- ---------------------------------------------------------------------
-- The reference mark must agree with the last bar. A mark that drifts
-- from the tape produces a price band that rejects honest orders.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_n BIGINT;
BEGIN
    SELECT count(*) INTO v_n
      FROM reference.instrument i
      JOIN market.quote q USING (instrument_id)
      JOIN LATERAL (SELECT close FROM market.candle_1m
                     WHERE instrument_id=i.instrument_id
                     ORDER BY bucket_start DESC LIMIT 1) c ON TRUE
     WHERE i.kind='crypto'
       AND abs(q.reference_price - c.close) / c.close > 0.25;
    PERFORM t.eq('crypto','no crypto mark has drifted off its own tape', v_n, 0::bigint);
END $$;

-- ---------------------------------------------------------------------
-- THE BAND MUST CONTAIN THE BOOK
--
-- engine.validate_order() anchors the price band on
-- market.quote.reference_price, which the ingestion worker writes from
-- an external feed. The order book is priced from this venue's own tape.
-- Those are different sources, and when they disagree the band stops
-- containing the book -- every order in that instrument is then rejected
-- as "outside the band", with nothing logged and nothing corrupted.
--
-- Seeding from the simulator and then running the API on a live feed is
-- the way to produce it: simulator META is ~$335, real META is ~$709.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_iid INTEGER; v_ref price_amt; v_n BIGINT; v_err TEXT;
BEGIN
    -- BTC-USD, not AAPL: _fixture.sql gives the equity quote a prev_close
    -- and a reference but no last_price, and divergence is meaningless
    -- without a venue price to diverge FROM. The crypto fixture at the top
    -- of this file sets last_price, which is what this needs.
    SELECT instrument_id INTO v_iid FROM reference.instrument WHERE symbol='BTC-USD';

    PERFORM t.eq('crypto','no band excludes its own book in a seeded database',
        (SELECT count(*) FROM market.mark_divergence(0.25)
          WHERE NOT band_contains_book), 0::bigint);

    -- Now break it exactly the way a provider switch does, and prove both
    -- the detection and the consequence.
    SELECT reference_price INTO v_ref FROM market.quote WHERE instrument_id=v_iid;
    UPDATE market.quote SET reference_price = v_ref * 2.1 WHERE instrument_id=v_iid;

    SELECT count(*) INTO v_n FROM market.mark_divergence(0.25)
     WHERE symbol='BTC-USD' AND NOT band_contains_book;
    PERFORM t.eq('crypto','a doubled external mark is detected', v_n, 1::bigint);

    PERFORM t.ok('crypto','health reports an untradable book',
        EXISTS (SELECT 1 FROM ops.health_check()
                 WHERE check_name='bands_contain_their_books' AND status='FAIL'));

    -- The consequence: an order at the venue's own price is now refused.
    v_err := engine.validate_order(v_iid, 10::qty_amt, v_ref, 'buy');
    PERFORM t.ok('crypto','an order at the venue price is rejected by the band',
                 v_err IS NOT NULL AND v_err LIKE '%outside%band%', COALESCE(v_err,'accepted'));

    UPDATE market.quote SET reference_price = v_ref WHERE instrument_id=v_iid;
    PERFORM t.ok('crypto','restoring the mark makes the book tradable again',
                 engine.validate_order(v_iid, 10::qty_amt, v_ref, 'buy') IS NULL);
END $$;
