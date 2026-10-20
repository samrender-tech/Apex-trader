-- =====================================================================
-- 026_tick_trade_flag.sql
--
-- VOLUME WAS COUNTING THINGS THAT ARE NOT TRADES
--
-- market.tick carries two different kinds of row:
--
--   * a FILL, written by engine.settle_fill(), whose volume is the
--     quantity that actually changed hands;
--   * a MARK, written by the ingestion worker once per poll to record
--     the external reference price. It has no quantity at all, so the
--     worker wrote volume = 1 as a placeholder, with a comment saying
--     as much.
--
-- market.build_candles_1m() summed both. So a live minute bar reported
-- volume 12 -- twelve polls -- sitting next to a backfilled bar at 2,500.
-- The volume histogram on the chart flatlined at the right-hand edge,
-- VWAP was pulled toward a price nothing traded at, and the
-- volume-anomaly surveillance rule was comparing bars whose volumes mean
-- different things. A placeholder had become data.
--
-- A mark is a price observation. It belongs in OHLC -- it is the best
-- information we have about where the instrument is between fills -- and
-- it does not belong in volume, trade count or VWAP.
--
-- is_trade makes that distinction explicit rather than leaving it
-- encoded in a source string that the aggregator would have to know the
-- vocabulary of. DEFAULT TRUE is deliberate: the engine's inserts do not
-- mention the column, and every one of them is a real trade.
-- =====================================================================

ALTER TABLE market.tick
    ADD COLUMN IF NOT EXISTS is_trade BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN market.tick.is_trade IS
  'TRUE for a fill (volume is a real quantity), FALSE for an external '
  'reference-price mark (no quantity). Candle OHLC uses every print; '
  'volume, trade_count and VWAP use trades only.';

-- A mark has no quantity, so its volume must be allowed to be zero.
-- market.tick.volume was qty_amt (CHECK VALUE > 0), which is right for a
-- fill and is exactly why the placeholder 1 was invented in the first
-- place -- the schema left no way to say "no quantity". qty_amt0 allows
-- zero and still forbids negative, so a mark can be honest about having
-- traded nothing.
ALTER TABLE market.tick
    ALTER COLUMN volume TYPE qty_amt0;

-- Existing rows: anything the engine did not write is a mark, and its
-- placeholder volume of 1 is not a quantity. Zero it.
UPDATE market.tick SET is_trade = FALSE, volume = 0
 WHERE source <> 'internal' AND is_trade;

-- The aggregator filters on it, and nearly every tick in a live window
-- is a mark, so it is worth indexing the trades.
CREATE INDEX IF NOT EXISTS ix_tick_trades
    ON market.tick (instrument_id, ts) WHERE is_trade;

-- ---------------------------------------------------------------------
-- Candle aggregation: prices from all prints, size from trades only.
--
-- Keeps 023's provenance guard -- a backfilled bar is still never
-- overwritten -- and keeps idempotence: the window is recomputed from
-- scratch, never accumulated.
--
-- A minute with marks but no fills now yields volume 0, trade_count 0
-- and a NULL vwap. That is the honest answer: the price moved, nothing
-- traded. The alternative -- inventing a volume of 1 per poll -- is what
-- this migration exists to undo.
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
           date_trunc('minute', t.ts)                                  AS bucket_start,
           (array_agg(t.price ORDER BY t.ts, t.tick_id))[1]            AS open,
           max(t.price)                                                AS high,
           min(t.price)                                                AS low,
           (array_agg(t.price ORDER BY t.ts DESC, t.tick_id DESC))[1]  AS close,
           COALESCE(sum(t.volume) FILTER (WHERE t.is_trade), 0)        AS volume,
           count(*) FILTER (WHERE t.is_trade)                          AS trade_count,
           ROUND(sum(t.price * t.volume) FILTER (WHERE t.is_trade)
                 / NULLIF(sum(t.volume) FILTER (WHERE t.is_trade), 0), 8) AS vwap,
           'tick'
      FROM market.tick t
     WHERE t.ts >= p_from AND t.ts < p_to
       AND (p_instrument_id IS NULL OR t.instrument_id = p_instrument_id)
     GROUP BY t.instrument_id, date_trunc('minute', t.ts)
    ON CONFLICT (instrument_id, bucket_start) DO UPDATE
       SET open = EXCLUDED.open, high = EXCLUDED.high, low = EXCLUDED.low,
           close = EXCLUDED.close, volume = EXCLUDED.volume,
           trade_count = EXCLUDED.trade_count, vwap = EXCLUDED.vwap
     WHERE c.source = 'tick';

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- ---------------------------------------------------------------------
-- market.quote.day_volume had the same problem one layer up: settle_fill
-- accumulates the traded quantity, which is right, but nothing reset it
-- and the mark path never touched it. Left alone -- the fix there is a
-- session rollover, which 015_maintenance.sql already owns. Noted here
-- so the next reader does not assume this migration covered it.
-- ---------------------------------------------------------------------
