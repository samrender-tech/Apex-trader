-- =====================================================================
-- Apex Trader :: 009_surveillance.sql
-- Market-abuse surveillance, expressed as SQL analytics over the order
-- and execution history.
--
-- This is the module a normal trading-app project does not have at all.
-- A real venue is legally required to monitor for manipulation, and the
-- patterns are naturally relational: self-dealing is a join of executions
-- to accounts, spoofing is a window function over order lifetimes.
-- Every rule below is a query, not application code.
-- =====================================================================

CREATE TABLE surveil.rule (
    rule_code   TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT NOT NULL,
    severity    surveil.severity NOT NULL,
    is_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
    params      JSONB NOT NULL DEFAULT '{}'::jsonb
);

INSERT INTO surveil.rule (rule_code,name,description,severity,params) VALUES
 ('WASH_TRADE','Wash trade / self-match',
  'Both sides of an execution trace back to the same beneficial owner, creating volume without changing economic ownership.',
  'critical','{"lookback_hours":24}'),
 ('SPOOF_LAYERING','Layering / spoofing',
  'A high ratio of rapidly cancelled orders on one side, used to create a false impression of depth and push the price.',
  'high','{"window_minutes":10,"min_orders":8,"cancel_ratio":0.8,"max_lifetime_seconds":30}'),
 ('MOMENTUM_IGNITION','Momentum ignition',
  'A burst of aggressive orders from one account moving price sharply within a short window.',
  'high','{"window_minutes":5,"move_pct":3.0,"min_orders":5}'),
 ('MARKING_THE_CLOSE','Marking the close',
  'Disproportionate aggressive activity in the final minutes of the session, which can distort the closing print.',
  'medium','{"closing_minutes":10,"volume_share":0.3}'),
 ('VOLUME_ANOMALY','Unusual volume',
  'Instrument volume far outside its own recent statistical norm, measured in standard deviations.',
  'low','{"sigma":3.0,"lookback_days":20}')
ON CONFLICT (rule_code) DO NOTHING;

CREATE TABLE surveil.alert (
    alert_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_code     TEXT NOT NULL REFERENCES surveil.rule(rule_code),
    severity      surveil.severity NOT NULL,
    account_id    BIGINT  REFERENCES trading.account(account_id) ON DELETE SET NULL,
    instrument_id INTEGER REFERENCES reference.instrument(instrument_id) ON DELETE SET NULL,
    detected_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    window_from   TIMESTAMPTZ,
    window_to     TIMESTAMPTZ,
    -- Evidence travels with the alert. JSONB because each rule produces a
    -- different shape of evidence and we refuse to add a column per rule.
    evidence      JSONB NOT NULL DEFAULT '{}'::jsonb,
    score         NUMERIC(10,4),
    state         surveil.alert_state NOT NULL DEFAULT 'open',
    reviewed_by   BIGINT REFERENCES identity.app_user(user_id),
    reviewed_at   TIMESTAMPTZ,
    review_note   TEXT,

    -- Dedupe key: one alert per (rule, account, instrument, window). Stops
    -- a scheduled scan re-raising the same finding on every run.
    dedupe_key    TEXT NOT NULL,
    CONSTRAINT review_consistent CHECK ((reviewed_at IS NULL) = (reviewed_by IS NULL))
);

CREATE UNIQUE INDEX uq_alert_dedupe ON surveil.alert (dedupe_key);
CREATE INDEX ix_alert_open     ON surveil.alert (severity, detected_at DESC) WHERE state = 'open';
CREATE INDEX ix_alert_account  ON surveil.alert (account_id, detected_at DESC);
CREATE INDEX ix_alert_evidence ON surveil.alert USING gin (evidence jsonb_path_ops);

-- =====================================================================
-- RULE 1 :: WASH TRADING
-- Both legs of a trade belong to the same beneficial owner. Volume goes
-- up, ownership does not change -- the classic way to fake liquidity.
-- =====================================================================
CREATE OR REPLACE FUNCTION surveil.scan_wash_trades(p_lookback INTERVAL DEFAULT '24 hours')
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER;
BEGIN
    WITH self_matched AS (
        SELECT ba.user_id,
               e.instrument_id,
               count(*)            AS trade_count,
               sum(e.quantity)      AS wash_qty,
               sum(e.price*e.quantity) AS wash_notional,
               min(e.executed_at)   AS first_at,
               max(e.executed_at)   AS last_at,
               array_agg(e.execution_id ORDER BY e.executed_at) AS execution_ids,
               min(ba.account_id)   AS sample_account
          FROM trading.execution e
          JOIN trading.account ba ON ba.account_id = e.buy_account_id
          JOIN trading.account sa ON sa.account_id = e.sell_account_id
         WHERE e.executed_at > now() - p_lookback
           AND ba.user_id IS NOT NULL
           -- Same human on both sides, whether through one account or two.
           AND ba.user_id = sa.user_id
         GROUP BY ba.user_id, e.instrument_id
    ), ins AS (
        INSERT INTO surveil.alert
            (rule_code, severity, account_id, instrument_id, window_from, window_to,
             evidence, score, dedupe_key)
        SELECT 'WASH_TRADE', r.severity, s.sample_account, s.instrument_id,
               s.first_at, s.last_at,
               jsonb_build_object(
                   'user_id', s.user_id,
                   'trade_count', s.trade_count,
                   'washed_quantity', s.wash_qty,
                   'washed_notional', round(s.wash_notional,2),
                   'execution_ids', to_jsonb(s.execution_ids)),
               s.trade_count * 10,
               format('WASH_TRADE:%s:%s:%s', s.user_id, s.instrument_id,
                      to_char(date_trunc('hour', s.first_at),'YYYYMMDDHH24'))
          FROM self_matched s CROSS JOIN surveil.rule r
         WHERE r.rule_code='WASH_TRADE' AND r.is_enabled
        ON CONFLICT (dedupe_key) DO NOTHING
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM ins;
    RETURN v_n;
END;
$$;

-- =====================================================================
-- RULE 2 :: LAYERING / SPOOFING
-- Place size you never intend to trade, let the market react, cancel.
-- The signature is a high cancel ratio combined with very short order
-- lifetimes, concentrated on one side of the book.
-- =====================================================================
CREATE OR REPLACE FUNCTION surveil.scan_spoofing(p_window INTERVAL DEFAULT '10 minutes')
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_n INTEGER;
    v_p JSONB;
BEGIN
    SELECT params INTO v_p FROM surveil.rule WHERE rule_code='SPOOF_LAYERING';

    WITH lifetimes AS (
        SELECT o.account_id, o.instrument_id, o.side, o.status,
               o.quantity, o.filled_qty,
               -- How long the order lived before it was cancelled.
               EXTRACT(EPOCH FROM (o.updated_at - o.placed_at)) AS lifetime_s,
               o.placed_at
          FROM trading.trade_order o
         WHERE o.placed_at > now() - p_window
    ), agg AS (
        SELECT account_id, instrument_id, side,
               count(*) AS total_orders,
               count(*) FILTER (WHERE status='cancelled' AND filled_qty = 0) AS cancelled_unfilled,
               avg(lifetime_s) FILTER (WHERE status='cancelled') AS avg_lifetime_s,
               sum(quantity) FILTER (WHERE status='cancelled' AND filled_qty=0) AS phantom_qty,
               min(placed_at) AS first_at, max(placed_at) AS last_at
          FROM lifetimes
         GROUP BY account_id, instrument_id, side
    ), flagged AS (
        SELECT *,
               cancelled_unfilled::NUMERIC / NULLIF(total_orders,0) AS cancel_ratio
          FROM agg
         WHERE total_orders >= (v_p->>'min_orders')::int
           AND cancelled_unfilled::NUMERIC / NULLIF(total_orders,0) >= (v_p->>'cancel_ratio')::numeric
           AND COALESCE(avg_lifetime_s, 1e9) <= (v_p->>'max_lifetime_seconds')::numeric
    ), ins AS (
        INSERT INTO surveil.alert
            (rule_code, severity, account_id, instrument_id, window_from, window_to,
             evidence, score, dedupe_key)
        SELECT 'SPOOF_LAYERING', r.severity, f.account_id, f.instrument_id,
               f.first_at, f.last_at,
               jsonb_build_object(
                   'side', f.side, 'total_orders', f.total_orders,
                   'cancelled_unfilled', f.cancelled_unfilled,
                   'cancel_ratio', round(f.cancel_ratio,4),
                   'avg_lifetime_seconds', round(f.avg_lifetime_s,2),
                   'phantom_quantity', f.phantom_qty),
               round(f.cancel_ratio * 100, 2),
               format('SPOOF_LAYERING:%s:%s:%s:%s', f.account_id, f.instrument_id, f.side,
                      to_char(date_trunc('hour', f.first_at),'YYYYMMDDHH24'))
          FROM flagged f CROSS JOIN surveil.rule r
         WHERE r.rule_code='SPOOF_LAYERING' AND r.is_enabled
        ON CONFLICT (dedupe_key) DO NOTHING
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM ins;
    RETURN v_n;
END;
$$;

-- =====================================================================
-- RULE 3 :: MOMENTUM IGNITION
-- One account's aggressive flow moves the price sharply. Uses window
-- functions over the tape to measure the move the account caused.
-- =====================================================================
CREATE OR REPLACE FUNCTION surveil.scan_momentum_ignition(p_window INTERVAL DEFAULT '5 minutes')
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER; v_p JSONB;
BEGIN
    SELECT params INTO v_p FROM surveil.rule WHERE rule_code='MOMENTUM_IGNITION';

    WITH tape AS (
        SELECT e.instrument_id, e.executed_at, e.price, e.quantity, e.aggressor_side,
               CASE WHEN e.aggressor_side='buy' THEN e.buy_account_id ELSE e.sell_account_id END
                 AS aggressor_account,
               -- FIRST_VALUE/LAST_VALUE over the whole window per instrument:
               -- the price path the window actually traced.
               first_value(e.price) OVER w AS window_open,
               last_value(e.price)  OVER w AS window_close
          FROM trading.execution e
         WHERE e.executed_at > now() - p_window
        WINDOW w AS (PARTITION BY e.instrument_id ORDER BY e.executed_at
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
    ), per_account AS (
        SELECT instrument_id, aggressor_account,
               count(*) AS aggressive_trades,
               sum(quantity) AS aggressive_qty,
               min(executed_at) AS first_at, max(executed_at) AS last_at,
               max(window_open) AS px_open, max(window_close) AS px_close
          FROM tape
         GROUP BY instrument_id, aggressor_account
    ), flagged AS (
        SELECT *, abs(px_close - px_open) / NULLIF(px_open,0) * 100 AS move_pct
          FROM per_account
         WHERE aggressive_trades >= (v_p->>'min_orders')::int
           AND abs(px_close - px_open) / NULLIF(px_open,0) * 100 >= (v_p->>'move_pct')::numeric
    ), ins AS (
        INSERT INTO surveil.alert
            (rule_code, severity, account_id, instrument_id, window_from, window_to,
             evidence, score, dedupe_key)
        SELECT 'MOMENTUM_IGNITION', r.severity, f.aggressor_account, f.instrument_id,
               f.first_at, f.last_at,
               jsonb_build_object(
                   'aggressive_trades', f.aggressive_trades,
                   'aggressive_quantity', f.aggressive_qty,
                   'price_open', f.px_open, 'price_close', f.px_close,
                   'move_pct', round(f.move_pct,3)),
               round(f.move_pct,2),
               format('MOMENTUM_IGNITION:%s:%s:%s', f.aggressor_account, f.instrument_id,
                      to_char(date_trunc('hour', f.first_at),'YYYYMMDDHH24'))
          FROM flagged f CROSS JOIN surveil.rule r
         WHERE r.rule_code='MOMENTUM_IGNITION' AND r.is_enabled
        ON CONFLICT (dedupe_key) DO NOTHING
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM ins;
    RETURN v_n;
END;
$$;

-- =====================================================================
-- RULE 4 :: UNUSUAL VOLUME
-- Statistical outlier detection against the instrument's OWN history,
-- using stddev_samp as a window aggregate. No fixed threshold, so a
-- thinly traded name is not compared against a mega-cap.
-- =====================================================================
CREATE OR REPLACE FUNCTION surveil.scan_volume_anomaly(p_lookback_days INTEGER DEFAULT 20)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER; v_sigma NUMERIC;
BEGIN
    SELECT (params->>'sigma')::numeric INTO v_sigma
      FROM surveil.rule WHERE rule_code='VOLUME_ANOMALY';

    WITH daily AS (
        SELECT instrument_id, date_trunc('day', executed_at) AS d, sum(quantity) AS vol
          FROM trading.execution
         WHERE executed_at > now() - (p_lookback_days || ' days')::interval
         GROUP BY 1,2
    ), stats AS (
        SELECT instrument_id, d, vol,
               avg(vol)         OVER (PARTITION BY instrument_id) AS mean_vol,
               stddev_samp(vol) OVER (PARTITION BY instrument_id) AS sd_vol,
               count(*)         OVER (PARTITION BY instrument_id) AS n_days
          FROM daily
    ), flagged AS (
        SELECT *, (vol - mean_vol) / NULLIF(sd_vol,0) AS z
          FROM stats
         WHERE n_days >= 5 AND sd_vol > 0
           AND (vol - mean_vol) / NULLIF(sd_vol,0) >= v_sigma
    ), ins AS (
        INSERT INTO surveil.alert
            (rule_code, severity, instrument_id, window_from, window_to,
             evidence, score, dedupe_key)
        SELECT 'VOLUME_ANOMALY', r.severity, f.instrument_id, f.d, f.d + INTERVAL '1 day',
               jsonb_build_object('volume', f.vol, 'mean_volume', round(f.mean_vol,2),
                                  'stddev', round(f.sd_vol,2), 'z_score', round(f.z,3),
                                  'sample_days', f.n_days),
               round(f.z,2),
               format('VOLUME_ANOMALY:%s:%s', f.instrument_id, to_char(f.d,'YYYYMMDD'))
          FROM flagged f CROSS JOIN surveil.rule r
         WHERE r.rule_code='VOLUME_ANOMALY' AND r.is_enabled
        ON CONFLICT (dedupe_key) DO NOTHING
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM ins;
    RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- Run every enabled rule. This is the function the scheduler calls.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION surveil.run_all_scans()
RETURNS TABLE (rule_code TEXT, alerts_raised INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY SELECT 'WASH_TRADE'::TEXT,        surveil.scan_wash_trades();
    RETURN QUERY SELECT 'SPOOF_LAYERING'::TEXT,    surveil.scan_spoofing();
    RETURN QUERY SELECT 'MOMENTUM_IGNITION'::TEXT, surveil.scan_momentum_ignition();
    RETURN QUERY SELECT 'VOLUME_ANOMALY'::TEXT,    surveil.scan_volume_anomaly();
END;
$$;

COMMENT ON FUNCTION surveil.run_all_scans IS
  'Runs the full surveillance suite. Each rule is a single analytical '
  'query; alerts are deduplicated by key so repeated runs are idempotent.';

-- ---------------------------------------------------------------------
-- Real-time self-match PREVENTION (as opposed to after-the-fact
-- detection). Many venues reject a self-match outright; here it is a
-- trigger on the execution table so it cannot be bypassed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION surveil.block_self_match() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_buy_user BIGINT; v_sell_user BIGINT;
BEGIN
    SELECT user_id INTO v_buy_user  FROM trading.account WHERE account_id = NEW.buy_account_id;
    SELECT user_id INTO v_sell_user FROM trading.account WHERE account_id = NEW.sell_account_id;

    IF v_buy_user IS NOT NULL AND v_buy_user = v_sell_user THEN
        RAISE EXCEPTION
            'self-match prevention: user % is on both sides of this execution', v_buy_user
            USING ERRCODE = '23514',
                  HINT = 'cancel the resting order before crossing your own quote';
    END IF;
    RETURN NEW;
END;
$$;

-- Deliberately NOT enabled by default: the demo seeder needs to generate
-- wash trades so the surveillance report has something to find. Flip it
-- on with: ALTER TABLE trading.execution ENABLE ALWAYS TRIGGER trg_block_self_match;
CREATE TRIGGER trg_block_self_match
    BEFORE INSERT ON trading.execution
    FOR EACH ROW EXECUTE FUNCTION surveil.block_self_match();
ALTER TABLE trading.execution DISABLE TRIGGER trg_block_self_match;
