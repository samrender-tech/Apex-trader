-- =====================================================================
-- Apex Trader :: 001_foundation.sql
-- Extensions, schemas (namespaces), domains and enumerated types.
--
-- Design note: the system is split into bounded-context SCHEMAS rather
-- than one flat public schema. This gives us (a) readable qualified
-- names, (b) per-context GRANT surfaces, (c) a natural place to hang
-- Row Level Security policies.
-- =====================================================================

-- ---------- Extensions ----------
CREATE EXTENSION IF NOT EXISTS pgcrypto;            -- password hashing, gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gist;          -- GiST over scalars -> exclusion constraints
CREATE EXTENSION IF NOT EXISTS pg_trgm;             -- trigram index for symbol/name search
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- query performance telemetry

-- ---------- Schemas ----------
CREATE SCHEMA IF NOT EXISTS identity;    -- users, auth, KYC, sessions
CREATE SCHEMA IF NOT EXISTS reference;   -- instruments, exchanges, calendar, corporate actions
CREATE SCHEMA IF NOT EXISTS market;      -- ticks, quotes, OHLCV candles
CREATE SCHEMA IF NOT EXISTS trading;     -- accounts, orders, executions, positions
CREATE SCHEMA IF NOT EXISTS ledger;      -- double-entry journal (the book of record)
CREATE SCHEMA IF NOT EXISTS risk;        -- limits, margin, circuit breakers
CREATE SCHEMA IF NOT EXISTS surveil;     -- market-abuse surveillance
CREATE SCHEMA IF NOT EXISTS social;      -- strategies, copy-trading
CREATE SCHEMA IF NOT EXISTS audit;       -- immutable change log
CREATE SCHEMA IF NOT EXISTS analytics;   -- reporting views / materialized views
CREATE SCHEMA IF NOT EXISTS engine;      -- matching engine internals
CREATE SCHEMA IF NOT EXISTS ops;         -- partition management, maintenance jobs

COMMENT ON SCHEMA ledger IS
  'Append-only double-entry book of record. Cash and security balances are '
  'DERIVED from postings here, never stored as a mutable column.';

-- =====================================================================
-- Domains: give money/quantity a single definition with validation
-- attached, so every column that holds money is provably non-garbage.
-- =====================================================================

-- 8 decimal places supports fractional-share trading and crypto-style
-- precision; NUMERIC (not float) because binary floats cannot represent
-- 0.01 exactly and money must never drift.
CREATE DOMAIN money_amt   AS NUMERIC(28,8);
CREATE DOMAIN price_amt   AS NUMERIC(20,8) CHECK (VALUE > 0);
CREATE DOMAIN qty_amt     AS NUMERIC(20,8) CHECK (VALUE > 0);
CREATE DOMAIN qty_amt0    AS NUMERIC(20,8) CHECK (VALUE >= 0);
CREATE DOMAIN bps         AS NUMERIC(9,4)  CHECK (VALUE >= 0 AND VALUE <= 100000);
CREATE DOMAIN pct         AS NUMERIC(9,4)  CHECK (VALUE >= 0 AND VALUE <= 100);
CREATE DOMAIN currency_code AS CHAR(3) CHECK (VALUE ~ '^[A-Z]{3}$');
CREATE DOMAIN email_addr  AS TEXT
  CHECK (VALUE ~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$');
CREATE DOMAIN symbol_code AS TEXT
  CHECK (VALUE ~ '^[A-Z0-9][A-Z0-9._-]{0,19}$');

COMMENT ON DOMAIN money_amt IS
  'NUMERIC(28,8). Never FLOAT: binary floating point cannot represent 0.01 '
  'exactly, so repeated fills would silently drift the ledger.';

-- =====================================================================
-- Enumerated types
-- =====================================================================
CREATE TYPE identity.user_role     AS ENUM ('trader','market_maker','compliance','admin');
CREATE TYPE identity.kyc_status    AS ENUM ('unverified','pending','verified','rejected');

CREATE TYPE reference.instrument_kind AS ENUM ('equity','etf','index','adr');
CREATE TYPE reference.ca_kind          AS ENUM ('split','reverse_split','cash_dividend','bonus_issue','merger');

CREATE TYPE trading.account_kind   AS ENUM ('cash','margin');
CREATE TYPE trading.account_status AS ENUM ('active','restricted','suspended','closed');

CREATE TYPE trading.order_side  AS ENUM ('buy','sell');
CREATE TYPE trading.order_kind  AS ENUM (
    'market',        -- execute immediately at best available price
    'limit',         -- rest on the book at a price or better
    'stop',          -- becomes a market order once stop price trades
    'stop_limit',    -- becomes a limit order once stop price trades
    'trailing_stop', -- stop that ratchets with favourable price moves
    'iceberg'        -- limit order that only displays part of its size
);
CREATE TYPE trading.time_in_force AS ENUM (
    'day',  -- expires at session close
    'gtc',  -- good till cancelled
    'ioc',  -- immediate-or-cancel: fill what you can, kill the rest
    'fok'   -- fill-or-kill: all at once or nothing
);
CREATE TYPE trading.order_status AS ENUM (
    'pending_new',      -- accepted by API, not yet risk-checked
    'rejected',         -- failed risk / validation
    'working',          -- live on the book (or awaiting stop trigger)
    'partially_filled',
    'filled',
    'cancelled',
    'expired'
);

CREATE TYPE ledger.asset_class  AS ENUM ('cash','security');
CREATE TYPE ledger.entry_kind   AS ENUM (
    'deposit','withdrawal','trade_settlement','fee','commission',
    'dividend','split_adjustment','margin_interest','adjustment','copy_fee'
);

CREATE TYPE risk.breach_action  AS ENUM ('warn','block','liquidate');
CREATE TYPE risk.halt_reason    AS ENUM ('price_band','volatility','news_pending','manual','circuit_breaker');

CREATE TYPE surveil.alert_state AS ENUM ('open','investigating','escalated','dismissed','confirmed');
CREATE TYPE surveil.severity    AS ENUM ('low','medium','high','critical');

CREATE TYPE social.visibility   AS ENUM ('private','followers','public');
CREATE TYPE social.sub_status   AS ENUM ('active','paused','cancelled');
