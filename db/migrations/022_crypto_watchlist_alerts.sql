-- =====================================================================
-- Apex Trader :: 022_crypto_watchlist_alerts.sql
--
-- Three additions that share one theme -- the venue stops being a
-- fixed list of 16 US equities open 9:30 to 16:00:
--
--   1. CRYPTO as a first-class asset class. It trades 24/7, in
--      fractional size, with far wider price moves, so the three things
--      the engine reads off the instrument master (session, lot size,
--      price band) all have to become per-instrument rather than
--      per-exchange assumptions.
--   2. WATCHLISTS, per user.
--   3. PRICE ALERTS, evaluated by the ingestion worker and pushed to the
--      browser over the same LISTEN/NOTIFY channel as fills.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. CRYPTO
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                    WHERE t.typname='instrument_kind' AND e.enumlabel='crypto') THEN
        ALTER TYPE reference.instrument_kind ADD VALUE 'crypto';
    END IF;
END $$;

-- A crypto pair never closes, so "is the market open" cannot be answered
-- from the exchange calendar alone.
ALTER TABLE reference.instrument
    ADD COLUMN IF NOT EXISTS trades_24x7 BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN reference.instrument.trades_24x7 IS
  'Crypto has no session. The trading calendar answers for equities; this '
  'flag short-circuits it for instruments that never close.';

-- Per-instrument market-hours check, replacing the exchange-only one.
CREATE OR REPLACE FUNCTION reference.is_instrument_open(
    p_instrument_id INTEGER, p_at TIMESTAMPTZ DEFAULT now()
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN i.trades_24x7 THEN TRUE
                ELSE reference.is_market_open(i.exchange_id, p_at) END
      FROM reference.instrument i
     WHERE i.instrument_id = p_instrument_id;
$$;

-- Listed as a FUNCTION rather than a one-off INSERT, because the demo
-- seeder clears reference.instrument on --reset and must be able to put
-- these back without duplicating the definitions.
CREATE OR REPLACE FUNCTION reference.ensure_crypto_instruments()
RETURNS INTEGER LANGUAGE plpgsql AS $fn$
DECLARE
    v_ex SMALLINT; v_n INTEGER := 0;
    v_sym TEXT; v_name TEXT; v_lot NUMERIC; v_tick NUMERIC; v_band NUMERIC;
BEGIN
    SELECT exchange_id INTO v_ex FROM reference.exchange WHERE code='CRYPTO';
    IF v_ex IS NULL THEN
        INSERT INTO reference.exchange
            (code,name,country_code,timezone,currency,session_open,session_close)
        VALUES ('CRYPTO','Apex Crypto','US','UTC','USD','00:00','23:59')
        RETURNING exchange_id INTO v_ex;
    END IF;

    FOR v_sym, v_name, v_lot, v_tick, v_band IN
        -- Lot sizes are fractional: nobody buys whole bitcoins. The
        -- qty_amt domain is NUMERIC(20,8) -- exactly a satoshi.
        SELECT * FROM (VALUES
            ('BTC-USD','Bitcoin',          0.00000001, 0.01,   30),
            ('ETH-USD','Ethereum',         0.00000001, 0.01,   30),
            ('SOL-USD','Solana',           0.00000001, 0.01,   40),
            ('XRP-USD','XRP',              0.00000001, 0.0001, 40),
            ('ADA-USD','Cardano',          0.00000001, 0.0001, 40),
            ('DOGE-USD','Dogecoin',        0.00000001, 0.00001,50),
            ('AVAX-USD','Avalanche',       0.00000001, 0.01,   45),
            ('LINK-USD','Chainlink',       0.00000001, 0.01,   40)
        ) AS v(sym,nm,lot,tick,band)
    LOOP
        INSERT INTO reference.instrument
            (symbol, exchange_id, name, kind, sector, industry, currency,
             lot_size, tick_size, price_band_pct, is_shortable, trades_24x7, metadata)
        VALUES (v_sym, v_ex, v_name, 'crypto', 'Digital Assets', 'Cryptocurrency',
                'USD', v_lot, v_tick, v_band, FALSE, TRUE,
                jsonb_build_object('asset_class','crypto','feed','yahoo'))
        ON CONFLICT (exchange_id, symbol) DO UPDATE
           SET trades_24x7 = TRUE, kind = 'crypto',
               lot_size = EXCLUDED.lot_size, tick_size = EXCLUDED.tick_size;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$fn$;

SELECT reference.ensure_crypto_instruments();

-- ---------------------------------------------------------------------
-- 2. WATCHLISTS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS social.watchlist (
    watchlist_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      BIGINT NOT NULL REFERENCES identity.app_user(user_id) ON DELETE CASCADE,
    name         TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60),
    is_default   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT one_name_per_user UNIQUE (user_id, name)
);

-- At most one default per user. A partial unique index says that in one
-- line; a trigger would need to handle every update path.
CREATE UNIQUE INDEX IF NOT EXISTS uq_one_default_watchlist
    ON social.watchlist (user_id) WHERE is_default;

CREATE TABLE IF NOT EXISTS social.watchlist_item (
    watchlist_id  BIGINT  NOT NULL REFERENCES social.watchlist(watchlist_id) ON DELETE CASCADE,
    instrument_id INTEGER NOT NULL REFERENCES reference.instrument(instrument_id) ON DELETE CASCADE,
    position      SMALLINT NOT NULL DEFAULT 0,
    note          TEXT,
    added_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (watchlist_id, instrument_id)
);
CREATE INDEX IF NOT EXISTS ix_watchlist_item_order
    ON social.watchlist_item (watchlist_id, position);

-- Every user gets a default list the moment they are created, so the UI
-- never has to handle "no watchlist yet".
CREATE OR REPLACE FUNCTION social.create_default_watchlist() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO social.watchlist (user_id, name, is_default)
    VALUES (NEW.user_id, 'My watchlist', TRUE)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_default_watchlist ON identity.app_user;
CREATE TRIGGER trg_user_default_watchlist
    AFTER INSERT ON identity.app_user
    FOR EACH ROW EXECUTE FUNCTION social.create_default_watchlist();

CREATE OR REPLACE VIEW social.v_watchlist AS
SELECT w.watchlist_id, w.user_id, w.name AS watchlist_name, w.is_default,
       wi.position, wi.note, wi.added_at,
       i.instrument_id, i.symbol, i.name, i.kind::text AS kind, i.sector,
       i.currency, i.trades_24x7,
       q.last_price, q.prev_close, q.bid, q.ask, q.day_volume,
       ROUND((q.last_price - q.prev_close)/NULLIF(q.prev_close,0)*100, 4) AS change_pct,
       reference.is_instrument_open(i.instrument_id) AS market_open
  FROM social.watchlist w
  LEFT JOIN social.watchlist_item wi USING (watchlist_id)
  LEFT JOIN reference.instrument i USING (instrument_id)
  LEFT JOIN market.quote q ON q.instrument_id = i.instrument_id;

-- ---------------------------------------------------------------------
-- 3. PRICE ALERTS
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
                    WHERE n.nspname='risk' AND t.typname='alert_kind') THEN
        CREATE TYPE risk.alert_kind AS ENUM ('above','below','pct_move_up','pct_move_down');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS risk.price_alert (
    alert_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       BIGINT NOT NULL REFERENCES identity.app_user(user_id) ON DELETE CASCADE,
    instrument_id INTEGER NOT NULL REFERENCES reference.instrument(instrument_id) ON DELETE CASCADE,
    kind          risk.alert_kind NOT NULL,
    threshold     NUMERIC(20,8) NOT NULL CHECK (threshold > 0),
    -- For a percentage alert this is the price it is measured from,
    -- captured when the alert is created so it cannot drift.
    reference_price NUMERIC(20,8),
    note          TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    repeat_alert  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ,
    last_fired_at TIMESTAMPTZ,
    fire_count    INTEGER NOT NULL DEFAULT 0 CHECK (fire_count >= 0),

    -- A percentage alert is meaningless without the price it is measured
    -- against; an absolute one does not need it.
    CONSTRAINT pct_alert_needs_reference CHECK (
        kind IN ('above','below') OR reference_price IS NOT NULL
    ),
    CONSTRAINT expiry_in_future CHECK (expires_at IS NULL OR expires_at > created_at)
);

-- Only live alerts are scanned on every tick, so the index tracks the
-- size of the WORK, not the history.
CREATE INDEX IF NOT EXISTS ix_alert_live ON risk.price_alert (instrument_id)
    WHERE is_active;
CREATE INDEX IF NOT EXISTS ix_alert_user ON risk.price_alert (user_id, created_at DESC);

-- Firings are an immutable log: an alert that fired is a fact.
CREATE TABLE IF NOT EXISTS risk.alert_fire (
    fire_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alert_id   BIGINT NOT NULL REFERENCES risk.price_alert(alert_id) ON DELETE CASCADE,
    fired_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    price      NUMERIC(20,8) NOT NULL,
    detail     JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS ix_alert_fire_recent ON risk.alert_fire (fired_at DESC);

DROP TRIGGER IF EXISTS trg_alert_fire_immutable ON risk.alert_fire;
CREATE TRIGGER trg_alert_fire_immutable
    BEFORE UPDATE OR DELETE ON risk.alert_fire
    FOR EACH ROW EXECUTE FUNCTION ledger.forbid_mutation();

-- =====================================================================
-- Alert evaluation.
--
-- One pass over every live alert whose instrument has a current price.
-- Written as a single statement rather than a loop so the whole sweep is
-- one query no matter how many alerts exist.
-- =====================================================================
CREATE OR REPLACE FUNCTION risk.evaluate_price_alerts()
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_n INTEGER := 0; v_r RECORD;
BEGIN
    FOR v_r IN
        SELECT a.alert_id, a.user_id, a.kind, a.threshold, a.reference_price,
               a.repeat_alert, a.note,
               i.symbol, i.instrument_id,
               q.last_price,
               CASE a.kind
                 WHEN 'above' THEN q.last_price >= a.threshold
                 WHEN 'below' THEN q.last_price <= a.threshold
                 WHEN 'pct_move_up' THEN
                      (q.last_price - a.reference_price)
                      / NULLIF(a.reference_price,0) * 100 >= a.threshold
                 WHEN 'pct_move_down' THEN
                      (a.reference_price - q.last_price)
                      / NULLIF(a.reference_price,0) * 100 >= a.threshold
               END AS hit
          FROM risk.price_alert a
          JOIN reference.instrument i USING (instrument_id)
          JOIN market.quote q USING (instrument_id)
         WHERE a.is_active
           AND q.last_price IS NOT NULL
           AND (a.expires_at IS NULL OR a.expires_at > now())
           -- A repeating alert is rate limited so a price oscillating
           -- around the threshold cannot spam the user.
           AND (a.last_fired_at IS NULL
                OR (a.repeat_alert AND a.last_fired_at < now() - INTERVAL '5 minutes'))
    LOOP
        CONTINUE WHEN NOT COALESCE(v_r.hit, FALSE);

        INSERT INTO risk.alert_fire (alert_id, price, detail)
        VALUES (v_r.alert_id, v_r.last_price,
                jsonb_build_object('symbol', v_r.symbol, 'kind', v_r.kind,
                                   'threshold', v_r.threshold,
                                   'reference_price', v_r.reference_price));

        UPDATE risk.price_alert
           SET last_fired_at = now(),
               fire_count    = fire_count + 1,
               is_active     = repeat_alert     -- one-shot alerts retire
         WHERE alert_id = v_r.alert_id;

        -- Same channel the matching engine uses, so the browser needs
        -- no second transport.
        PERFORM pg_notify('apex_events', json_build_object(
            'type','price_alert', 'alert_id', v_r.alert_id,
            'user_id', v_r.user_id, 'symbol', v_r.symbol,
            'instrument_id', v_r.instrument_id,
            'alert_kind', v_r.kind, 'threshold', v_r.threshold,
            'price', v_r.last_price, 'note', v_r.note)::text);

        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION risk.evaluate_price_alerts IS
  'Fires any live alert whose condition the current quote satisfies. '
  'One-shot alerts retire themselves; repeating ones are rate limited to '
  'once per five minutes so a price sitting on the threshold cannot spam.';

-- ---------------------------------------------------------------------
-- Row Level Security on the new tables.
-- ---------------------------------------------------------------------
ALTER TABLE social.watchlist      ENABLE ROW LEVEL SECURITY;
ALTER TABLE social.watchlist_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk.price_alert      ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk.alert_fire       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_watchlist_own ON social.watchlist;
CREATE POLICY p_watchlist_own ON social.watchlist FOR ALL
    USING (user_id = identity.current_user_id() OR identity.current_user_is_privileged())
    WITH CHECK (user_id = identity.current_user_id());

DROP POLICY IF EXISTS p_watchlist_item_own ON social.watchlist_item;
CREATE POLICY p_watchlist_item_own ON social.watchlist_item FOR ALL
    USING (watchlist_id IN (SELECT w.watchlist_id FROM social.watchlist w
                             WHERE w.user_id = identity.current_user_id())
           OR identity.current_user_is_privileged())
    WITH CHECK (watchlist_id IN (SELECT w.watchlist_id FROM social.watchlist w
                                  WHERE w.user_id = identity.current_user_id()));

DROP POLICY IF EXISTS p_alert_own ON risk.price_alert;
CREATE POLICY p_alert_own ON risk.price_alert FOR ALL
    USING (user_id = identity.current_user_id() OR identity.current_user_is_privileged())
    WITH CHECK (user_id = identity.current_user_id());

DROP POLICY IF EXISTS p_alert_fire_own ON risk.alert_fire;
CREATE POLICY p_alert_fire_own ON risk.alert_fire FOR SELECT
    USING (alert_id IN (SELECT a.alert_id FROM risk.price_alert a
                         WHERE a.user_id = identity.current_user_id())
           OR identity.current_user_is_privileged());

GRANT SELECT, INSERT, UPDATE, DELETE ON social.watchlist, social.watchlist_item,
      risk.price_alert TO apex_app;
GRANT SELECT, INSERT ON risk.alert_fire TO apex_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA social, risk TO apex_app;
GRANT SELECT ON social.v_watchlist TO apex_app, apex_readonly, apex_compliance;
GRANT EXECUTE ON FUNCTION risk.evaluate_price_alerts() TO apex_app;
GRANT EXECUTE ON FUNCTION reference.ensure_crypto_instruments() TO apex_app;
GRANT EXECUTE ON FUNCTION reference.is_instrument_open(INTEGER, TIMESTAMPTZ)
      TO apex_app, apex_readonly, apex_compliance;
