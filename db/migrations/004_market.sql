-- =====================================================================
-- Apex Trader :: 004_market.sql
-- Time-series market data: raw ticks, live quote snapshots, OHLCV candles.
--
-- Slide 09 listed "Limited Scalability Features". Market data is the table
-- that actually grows without bound (one row per trade, per symbol, per
-- day), so it is DECLARATIVELY PARTITIONED BY RANGE on time. Benefits:
--   * old months are detached/archived in O(1) instead of a mass DELETE
--   * the planner prunes irrelevant partitions before reading anything
--   * each partition's indexes stay small enough to live in cache
-- =====================================================================

-- ---------------------------------------------------------------------
-- Generic partition manager. Called by a maintenance job; keeps the
-- partition DDL in one tested place instead of scattered scripts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.ensure_time_partitions(
    p_schema   TEXT,
    p_table    TEXT,
    p_from     DATE,
    p_to       DATE,
    p_interval INTERVAL DEFAULT '1 month'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_start DATE := date_trunc('month', p_from)::date;
    v_end   DATE;
    v_name  TEXT;
    v_made  INTEGER := 0;
BEGIN
    IF p_interval = INTERVAL '1 day' THEN
        v_start := p_from;
    END IF;

    WHILE v_start < p_to LOOP
        v_end  := (v_start + p_interval)::date;
        v_name := format('%s_p%s', p_table, to_char(v_start,
                    CASE WHEN p_interval = INTERVAL '1 day' THEN 'YYYYMMDD' ELSE 'YYYYMM' END));

        IF NOT EXISTS (
            SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = p_schema AND c.relname = v_name
        ) THEN
            EXECUTE format(
                'CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                p_schema, v_name, p_schema, p_table, v_start, v_end);
            v_made := v_made + 1;
        END IF;
        v_start := v_end;
    END LOOP;
    RETURN v_made;
END;
$$;

COMMENT ON FUNCTION ops.ensure_time_partitions IS
  'Idempotently creates range partitions covering [p_from, p_to). Safe to '
  're-run; used both by the seeder and by the nightly maintenance job.';

-- ---------------------------------------------------------------------
-- TICK :: every print that crosses the tape
-- ---------------------------------------------------------------------
CREATE TABLE market.tick (
    tick_id       BIGINT GENERATED ALWAYS AS IDENTITY,
    instrument_id INTEGER     NOT NULL REFERENCES reference.instrument(instrument_id),
    ts            TIMESTAMPTZ NOT NULL,
    price         price_amt   NOT NULL,
    volume        qty_amt     NOT NULL,
    source        TEXT        NOT NULL DEFAULT 'internal',  -- 'finnhub' | 'internal' | 'sim'
    -- The PK must contain the partition key: that is the price of
    -- declarative partitioning, and it is the right trade here because
    -- every query on ticks is time-bounded anyway.
    PRIMARY KEY (ts, instrument_id, tick_id)
) PARTITION BY RANGE (ts);

-- BRIN, not B-tree, on the time column: tick data arrives in timestamp
-- order, so a BRIN index is ~1000x smaller than a B-tree while still
-- pruning blocks effectively on range scans.
CREATE INDEX ix_tick_ts_brin ON market.tick USING brin (ts) WITH (pages_per_range = 32);
CREATE INDEX ix_tick_instrument_ts ON market.tick (instrument_id, ts DESC);

SELECT ops.ensure_time_partitions('market','tick',
    (CURRENT_DATE - INTERVAL '6 months')::date,
    (CURRENT_DATE + INTERVAL '3 months')::date, '1 month');

-- ---------------------------------------------------------------------
-- QUOTE :: one row per instrument, the live top-of-book snapshot.
-- Deliberately NOT partitioned and deliberately narrow: this is read on
-- every page load and updated on every tick, so it must stay in cache.
-- ---------------------------------------------------------------------
CREATE TABLE market.quote (
    instrument_id INTEGER PRIMARY KEY REFERENCES reference.instrument(instrument_id) ON DELETE CASCADE,
    bid           NUMERIC(20,8) CHECK (bid IS NULL OR bid > 0),
    bid_size      qty_amt0 NOT NULL DEFAULT 0,
    ask           NUMERIC(20,8) CHECK (ask IS NULL OR ask > 0),
    ask_size      qty_amt0 NOT NULL DEFAULT 0,
    last_price    NUMERIC(20,8) CHECK (last_price IS NULL OR last_price > 0),
    last_size     qty_amt0 NOT NULL DEFAULT 0,
    day_open      NUMERIC(20,8),
    day_high      NUMERIC(20,8),
    day_low       NUMERIC(20,8),
    prev_close    NUMERIC(20,8),
    day_volume    qty_amt0 NOT NULL DEFAULT 0,
    reference_price NUMERIC(20,8),   -- external feed mark, anchors the price band
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A crossed book (bid >= ask) means the matching engine failed to do
    -- its job. Assert it at the storage layer so a bug surfaces loudly
    -- instead of quietly corrupting the market.
    CONSTRAINT book_not_crossed CHECK (bid IS NULL OR ask IS NULL OR bid < ask)
);

-- Generated/computed read model for day change, so every client shows the
-- same number instead of each recomputing it.
CREATE OR REPLACE VIEW market.quote_enriched AS
SELECT q.*,
       i.symbol, i.name, i.currency, i.sector, e.code AS exchange_code,
       (q.ask - q.bid)                                   AS spread_abs,
       ROUND(((q.ask - q.bid) / NULLIF(q.ask,0)) * 10000, 2) AS spread_bps,
       (q.last_price - q.prev_close)                     AS change_abs,
       ROUND(((q.last_price - q.prev_close) / NULLIF(q.prev_close,0)) * 100, 4) AS change_pct,
       reference.is_market_open(i.exchange_id, now())    AS market_open
  FROM market.quote q
  JOIN reference.instrument i USING (instrument_id)
  JOIN reference.exchange   e ON e.exchange_id = i.exchange_id;

-- ---------------------------------------------------------------------
-- CANDLE :: 1-minute OHLCV base table. Higher intervals are derived by
-- aggregation (see 010_analytics.sql) rather than stored redundantly --
-- one source of truth, no risk of a 5m bar disagreeing with its 1m bars.
-- ---------------------------------------------------------------------
CREATE TABLE market.candle_1m (
    instrument_id INTEGER     NOT NULL REFERENCES reference.instrument(instrument_id),
    bucket_start  TIMESTAMPTZ NOT NULL,
    open          price_amt   NOT NULL,
    high          price_amt   NOT NULL,
    low           price_amt   NOT NULL,
    close         price_amt   NOT NULL,
    volume        qty_amt0    NOT NULL DEFAULT 0,
    trade_count   INTEGER     NOT NULL DEFAULT 0 CHECK (trade_count >= 0),
    vwap          NUMERIC(20,8),
    PRIMARY KEY (instrument_id, bucket_start),
    -- OHLC has an internal arithmetic truth: high is the max, low is the
    -- min. A feed bug that violates it is rejected at write time.
    CONSTRAINT ohlc_coherent CHECK (
        high >= low AND high >= open AND high >= close
                    AND low  <= open AND low  <= close
    ),
    CONSTRAINT bucket_aligned CHECK (date_trunc('minute', bucket_start) = bucket_start)
) PARTITION BY RANGE (bucket_start);

CREATE INDEX ix_candle_1m_bucket_brin ON market.candle_1m USING brin (bucket_start);

SELECT ops.ensure_time_partitions('market','candle_1m',
    (CURRENT_DATE - INTERVAL '6 months')::date,
    (CURRENT_DATE + INTERVAL '3 months')::date, '1 month');

COMMENT ON TABLE market.candle_1m IS
  'Base OHLCV resolution. 5m/15m/1h/1d bars are AGGREGATED from this table '
  'so they can never disagree with the underlying minute bars.';

-- ---------------------------------------------------------------------
-- Tick -> candle aggregation. Incremental and idempotent: re-running it
-- for a window recomputes that window rather than double-counting.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION market.build_candles_1m(
    p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_instrument_id INTEGER DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_rows INTEGER;
BEGIN
    INSERT INTO market.candle_1m AS c
          (instrument_id, bucket_start, open, high, low, close, volume, trade_count, vwap)
    SELECT t.instrument_id,
           date_trunc('minute', t.ts)                              AS bucket_start,
           -- FIRST_VALUE / LAST_VALUE semantics expressed as ordered
           -- aggregates: the open is the first print in the bucket, the
           -- close is the last.
           (array_agg(t.price ORDER BY t.ts, t.tick_id))[1]         AS open,
           max(t.price)                                             AS high,
           min(t.price)                                             AS low,
           (array_agg(t.price ORDER BY t.ts DESC, t.tick_id DESC))[1] AS close,
           sum(t.volume)                                            AS volume,
           count(*)                                                 AS trade_count,
           ROUND(sum(t.price * t.volume) / NULLIF(sum(t.volume),0), 8) AS vwap
      FROM market.tick t
     WHERE t.ts >= p_from AND t.ts < p_to
       AND (p_instrument_id IS NULL OR t.instrument_id = p_instrument_id)
     GROUP BY t.instrument_id, date_trunc('minute', t.ts)
    ON CONFLICT (instrument_id, bucket_start) DO UPDATE
       SET open = EXCLUDED.open, high = EXCLUDED.high, low = EXCLUDED.low,
           close = EXCLUDED.close, volume = EXCLUDED.volume,
           trade_count = EXCLUDED.trade_count, vwap = EXCLUDED.vwap;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;
