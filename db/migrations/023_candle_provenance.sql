-- =====================================================================
-- 023_candle_provenance.sql
--
-- WHY THIS MIGRATION EXISTS
--
-- market.candle_1m held bars from two different sources with no way to
-- tell them apart:
--
--   * BACKFILL bars -- a real OHLCV history loaded from the provider (or
--     the simulator) in bulk. Each bar is a true minute of trading with
--     thousands of shares of volume.
--   * TICK bars -- built by market.build_candles_1m() from the prints in
--     market.tick, which on this venue are our own fills plus one unit
--     price point per ingestion poll.
--
-- The ingestion worker rolls the last 15 minutes into candles every 50
-- seconds, and build_candles_1m() UPSERTed with an unconditional
-- DO UPDATE. For an equity that is harmless -- the backfill stops at the
-- previous session close, so the two windows never overlap. For crypto
-- it is destructive: crypto trades 24x7, so its backfill runs right up
-- to the current minute, and the next roll REPLACED those real bars with
-- a bar synthesised from a handful of unit ticks.
--
-- The visible symptom was a chart whose final bars collapsed to volume 7
-- and 10 against a neighbouring 1,110, and -- because market.quote's
-- reference_price is marked off those bars -- a price band computed from
-- a corrupted mark, which then rejected every market-maker order on the
-- crypto books.
--
-- The fix is provenance. A bar records where it came from, and the
-- tick aggregator is only allowed to overwrite bars it owns. A backfilled
-- bar is authoritative and immutable to the roller.
--
-- Also here: reference.align_price(), because "round the price to 2
-- decimals" is an equity assumption. DOGE-USD has a tick of 0.00001.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PROVENANCE COLUMN
--
-- DEFAULT 'tick' is deliberate for existing rows: it is the permissive
-- value. Marking legacy rows 'backfill' would freeze whatever corruption
-- is already in the table against repair, whereas 'tick' lets the next
-- roll recompute them. The seeder then writes 'backfill' explicitly.
-- ---------------------------------------------------------------------
ALTER TABLE market.candle_1m
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'tick';

DO $$
BEGIN
    ALTER TABLE market.candle_1m
        ADD CONSTRAINT candle_source_known
        CHECK (source IN ('tick', 'backfill', 'provider'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN market.candle_1m.source IS
  'Provenance. ''backfill''/''provider'' bars are authoritative history and '
  'are never overwritten by market.build_candles_1m(); ''tick'' bars are '
  'derived from market.tick and are recomputed on every roll.';

-- ---------------------------------------------------------------------
-- 2. TICK AGGREGATION, PROVENANCE-AWARE
--
-- Still idempotent -- it recomputes a window from scratch rather than
-- accumulating -- but now it declines to touch a bar it did not write.
-- Returns the number of bars actually written so a caller can see the
-- difference between "nothing to do" and "all of it was protected".
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION market.build_candles_1m(
    p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_instrument_id INTEGER DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_rows INTEGER;
BEGIN
    INSERT INTO market.candle_1m AS c
          (instrument_id, bucket_start, open, high, low, close,
           volume, trade_count, vwap, source)
    SELECT t.instrument_id,
           date_trunc('minute', t.ts)                                AS bucket_start,
           (array_agg(t.price ORDER BY t.ts, t.tick_id))[1]          AS open,
           max(t.price)                                              AS high,
           min(t.price)                                              AS low,
           (array_agg(t.price ORDER BY t.ts DESC, t.tick_id DESC))[1] AS close,
           sum(t.volume)                                             AS volume,
           count(*)                                                  AS trade_count,
           ROUND(sum(t.price * t.volume) / NULLIF(sum(t.volume),0), 8) AS vwap,
           'tick'
      FROM market.tick t
     WHERE t.ts >= p_from AND t.ts < p_to
       AND (p_instrument_id IS NULL OR t.instrument_id = p_instrument_id)
     GROUP BY t.instrument_id, date_trunc('minute', t.ts)
    ON CONFLICT (instrument_id, bucket_start) DO UPDATE
       SET open = EXCLUDED.open, high = EXCLUDED.high, low = EXCLUDED.low,
           close = EXCLUDED.close, volume = EXCLUDED.volume,
           trade_count = EXCLUDED.trade_count, vwap = EXCLUDED.vwap
     -- The guard. A backfilled bar wins over a tick-derived one.
     WHERE c.source = 'tick';

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. TICK-SIZE-AWARE ROUNDING
--
-- Every price this system accepts must sit on the instrument's tick
-- grid -- engine.validate_order() enforces it. Callers that compute a
-- price (the market maker's spread, a simulated quote, a percentage
-- offset) were rounding to 2 decimals, which is an equity assumption:
-- rounding DOGE-USD's 0.00001 tick to 0.01 moves the price by 1,000
-- ticks and rounding XRP-USD's 0.0001 tick silently flattens the book.
--
-- IMMUTABLE is wrong here (tick_size is table data), but STABLE lets the
-- planner still call it once per row within a statement.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reference.align_price(
    p_instrument_id INTEGER, p_price NUMERIC
) RETURNS price_amt LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
             ROUND(p_price / i.tick_size) * i.tick_size,
             i.tick_size
           )::price_amt
      FROM reference.instrument i
     WHERE i.instrument_id = p_instrument_id;
$$;

COMMENT ON FUNCTION reference.align_price(INTEGER, NUMERIC) IS
  'Snap a computed price onto the instrument''s tick grid, never below one '
  'tick. Use instead of ROUND(x,2), which is an equity-only assumption.';

-- ---------------------------------------------------------------------
-- 4. REPAIR
--
-- Rebuild the marks that the corruption poisoned. reference_price is the
-- anchor for the price band and the circuit breaker, so a bad mark is
-- not cosmetic -- it rejects orders. Re-derive it from the last bar the
-- roller is allowed to have written.
-- ---------------------------------------------------------------------
UPDATE market.quote q
   SET reference_price = c.close, updated_at = now()
  FROM (SELECT DISTINCT ON (instrument_id) instrument_id, close
          FROM market.candle_1m
         ORDER BY instrument_id, bucket_start DESC) c
 WHERE c.instrument_id = q.instrument_id
   AND q.reference_price IS DISTINCT FROM c.close;

GRANT EXECUTE ON FUNCTION reference.align_price(INTEGER, NUMERIC) TO apex_app;
