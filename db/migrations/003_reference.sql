-- =====================================================================
-- Apex Trader :: 003_reference.sql
-- Reference data: exchanges, the INSTRUMENT (stock) master, the trading
-- calendar, and corporate actions.
--
-- Slide 09 of the original design listed "Stock Data Not Separately
-- Modeled" as a limitation. This file is the fix: instruments are now a
-- first-class entity with their own exchange, tick size, lot size and
-- price-band rules, which the matching engine reads at order time.
-- =====================================================================

CREATE TABLE reference.exchange (
    exchange_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code          TEXT NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{2,12}$'),
    name          TEXT NOT NULL,
    country_code  CHAR(2) NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    timezone      TEXT NOT NULL,            -- IANA name, validated below
    currency      currency_code NOT NULL,
    session_open  TIME NOT NULL,
    session_close TIME NOT NULL,
    -- Validate the timezone against the server's own tz database rather
    -- than trusting a free-text string.
    CONSTRAINT tz_is_real CHECK (now() AT TIME ZONE timezone IS NOT NULL),
    CONSTRAINT session_ordered CHECK (session_close > session_open)
);

-- ---------------------------------------------------------------------
-- INSTRUMENT :: the tradable-security master
-- ---------------------------------------------------------------------
CREATE TABLE reference.instrument (
    instrument_id  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    symbol         symbol_code NOT NULL,
    exchange_id    SMALLINT NOT NULL REFERENCES reference.exchange(exchange_id),
    isin           CHAR(12) CHECK (isin IS NULL OR isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$'),
    name           TEXT NOT NULL,
    kind           reference.instrument_kind NOT NULL DEFAULT 'equity',
    sector         TEXT,
    industry       TEXT,
    currency       currency_code NOT NULL DEFAULT 'USD',

    -- Microstructure rules the engine enforces on every order:
    lot_size       qty_amt   NOT NULL DEFAULT 1,      -- order qty must be a multiple
    tick_size      price_amt NOT NULL DEFAULT 0.01,   -- price must be a multiple
    price_band_pct pct       NOT NULL DEFAULT 20,     -- +/- move before trading halts

    shares_outstanding BIGINT CHECK (shares_outstanding IS NULL OR shares_outstanding > 0),
    is_tradable    BOOLEAN NOT NULL DEFAULT TRUE,
    is_shortable   BOOLEAN NOT NULL DEFAULT FALSE,
    listed_on      DATE NOT NULL DEFAULT CURRENT_DATE,
    delisted_on    DATE,
    metadata       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- logo, website, feed ids...
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT symbol_unique_per_exchange UNIQUE (exchange_id, symbol),
    CONSTRAINT listing_window_ordered CHECK (delisted_on IS NULL OR delisted_on >= listed_on),
    -- A delisted instrument must not be tradable: make the invalid
    -- combination unrepresentable rather than relying on app checks.
    CONSTRAINT delisted_not_tradable CHECK (delisted_on IS NULL OR NOT is_tradable)
);

-- TRIGRAM index: powers "type AAP, get AAPL" fuzzy symbol/name search
-- without a separate search service.
CREATE INDEX ix_instrument_symbol_trgm ON reference.instrument USING gin (symbol gin_trgm_ops);
CREATE INDEX ix_instrument_name_trgm   ON reference.instrument USING gin (name   gin_trgm_ops);
-- GIN over JSONB lets us query metadata keys without a schema migration.
CREATE INDEX ix_instrument_metadata    ON reference.instrument USING gin (metadata jsonb_path_ops);
-- Covering/partial: the hot path is "list tradable instruments on an exchange".
CREATE INDEX ix_instrument_tradable ON reference.instrument (exchange_id, symbol)
    INCLUDE (name, sector) WHERE is_tradable;

COMMENT ON TABLE reference.instrument IS
  'Security master. tick_size/lot_size/price_band_pct are read by the '
  'matching engine on every order, so microstructure rules are data, not code.';

-- ---------------------------------------------------------------------
-- TRADING CALENDAR :: which dates are sessions, and when they open
-- ---------------------------------------------------------------------
CREATE TABLE reference.trading_session (
    exchange_id   SMALLINT NOT NULL REFERENCES reference.exchange(exchange_id),
    session_date  DATE NOT NULL,
    is_trading_day BOOLEAN NOT NULL DEFAULT TRUE,
    open_ts       TIMESTAMPTZ,
    close_ts      TIMESTAMPTZ,
    note          TEXT,                  -- 'Independence Day', 'half day'...
    PRIMARY KEY (exchange_id, session_date),
    CONSTRAINT trading_day_has_window CHECK (
        (NOT is_trading_day AND open_ts IS NULL AND close_ts IS NULL)
     OR (is_trading_day AND open_ts IS NOT NULL AND close_ts > open_ts)
    )
);

CREATE OR REPLACE FUNCTION reference.is_market_open(
    p_exchange_id SMALLINT, p_at TIMESTAMPTZ DEFAULT now()
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT ts.is_trading_day AND p_at BETWEEN ts.open_ts AND ts.close_ts
           FROM reference.trading_session ts
          WHERE ts.exchange_id = p_exchange_id
            AND ts.session_date = (p_at AT TIME ZONE
                  (SELECT e.timezone FROM reference.exchange e WHERE e.exchange_id = p_exchange_id))::date),
        FALSE);
$$;

-- ---------------------------------------------------------------------
-- CORPORATE ACTIONS :: splits and dividends change history retroactively
-- ---------------------------------------------------------------------
CREATE TABLE reference.corporate_action (
    action_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instrument_id INTEGER NOT NULL REFERENCES reference.instrument(instrument_id),
    kind          reference.ca_kind NOT NULL,
    ex_date       DATE NOT NULL,
    record_date   DATE,
    pay_date      DATE,
    -- For a 4:1 split, ratio_from=1, ratio_to=4 (one old share -> four new)
    ratio_from    NUMERIC(12,6) CHECK (ratio_from  IS NULL OR ratio_from  > 0),
    ratio_to      NUMERIC(12,6) CHECK (ratio_to    IS NULL OR ratio_to    > 0),
    cash_per_share money_amt    CHECK (cash_per_share IS NULL OR cash_per_share >= 0),
    is_applied    BOOLEAN NOT NULL DEFAULT FALSE,
    applied_at    TIMESTAMPTZ,
    announced_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Each action kind requires its own payload; one CHECK keeps a
    -- dividend from being stored with a split ratio and vice versa.
    CONSTRAINT ca_payload_matches_kind CHECK (
        CASE kind
            WHEN 'cash_dividend' THEN cash_per_share IS NOT NULL AND ratio_to IS NULL
            WHEN 'split'         THEN ratio_from IS NOT NULL AND ratio_to IS NOT NULL AND ratio_to > ratio_from
            WHEN 'reverse_split' THEN ratio_from IS NOT NULL AND ratio_to IS NOT NULL AND ratio_to < ratio_from
            WHEN 'bonus_issue'   THEN ratio_from IS NOT NULL AND ratio_to IS NOT NULL
            ELSE TRUE
        END
    ),
    CONSTRAINT ca_applied_consistent CHECK (is_applied = (applied_at IS NOT NULL))
);

CREATE INDEX ix_ca_pending ON reference.corporate_action (ex_date)
    WHERE NOT is_applied;
CREATE INDEX ix_ca_instrument ON reference.corporate_action (instrument_id, ex_date DESC);
