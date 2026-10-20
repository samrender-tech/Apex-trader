-- =====================================================================
-- Apex Trader :: 006_orders.sql
-- Orders, executions (the trade-history table slide 09 was missing), and
-- the position read model.
-- =====================================================================

-- Global monotonic sequence. This is the "time" in price-TIME priority:
-- wall-clock timestamps can tie (or even go backwards under NTP
-- adjustment), a sequence cannot. Every resting order gets one.
CREATE SEQUENCE IF NOT EXISTS engine.order_seq AS BIGINT START 1;

CREATE TABLE trading.trade_order (
    order_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Client-supplied idempotency key. A retried HTTP POST with the same
    -- key cannot create a second order -- the unique index rejects it.
    -- This is how you make order entry safe over an unreliable network.
    client_order_id UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    seq_no          BIGINT NOT NULL DEFAULT nextval('engine.order_seq'),

    account_id      BIGINT  NOT NULL REFERENCES trading.account(account_id),
    instrument_id   INTEGER NOT NULL REFERENCES reference.instrument(instrument_id),
    side            trading.order_side    NOT NULL,
    kind            trading.order_kind    NOT NULL,
    tif             trading.time_in_force NOT NULL DEFAULT 'day',

    quantity        qty_amt   NOT NULL,
    limit_price     NUMERIC(20,8) CHECK (limit_price IS NULL OR limit_price > 0),
    stop_price      NUMERIC(20,8) CHECK (stop_price  IS NULL OR stop_price  > 0),
    -- Trailing stops: the stop follows the best price seen by this many
    -- percent. peak_price is the high-water mark the trail is measured from.
    trail_pct       pct,
    peak_price      NUMERIC(20,8),
    -- Iceberg: only display_qty is visible in the public book.
    display_qty     NUMERIC(20,8) CHECK (display_qty IS NULL OR display_qty > 0),

    filled_qty      qty_amt0 NOT NULL DEFAULT 0,
    -- GENERATED column: remaining size is arithmetic, not state, so it
    -- cannot drift out of sync with quantity/filled_qty.
    leaves_qty      NUMERIC(20,8) GENERATED ALWAYS AS (quantity - filled_qty) STORED,
    avg_fill_price  NUMERIC(20,8),

    status          trading.order_status NOT NULL DEFAULT 'pending_new',
    stop_armed      BOOLEAN NOT NULL DEFAULT FALSE,   -- stop has been elected
    reject_reason   TEXT,

    -- Order lineage: bracket/OCO children, and copy-trade mirrors, point
    -- at their parent. Walked with a RECURSIVE CTE in 010_analytics.sql.
    parent_order_id BIGINT REFERENCES trading.trade_order(order_id),
    source_strategy_id BIGINT,          -- FK added in 009_social.sql

    placed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ,

    CONSTRAINT fill_within_order   CHECK (filled_qty <= quantity),
    CONSTRAINT no_self_parent      CHECK (parent_order_id IS DISTINCT FROM order_id),
    CONSTRAINT iceberg_display_fits CHECK (display_qty IS NULL OR display_qty <= quantity),

    -- One CHECK encodes the entire order-type grammar. An order whose
    -- shape makes no sense (a market order with a limit price, a stop
    -- order with no stop price) is unstorable rather than merely invalid.
    CONSTRAINT order_shape_matches_kind CHECK (
        CASE kind
            WHEN 'market'        THEN limit_price IS NULL AND stop_price IS NULL AND trail_pct IS NULL
            WHEN 'limit'         THEN limit_price IS NOT NULL AND stop_price IS NULL AND trail_pct IS NULL
            WHEN 'stop'          THEN stop_price IS NOT NULL AND limit_price IS NULL AND trail_pct IS NULL
            WHEN 'stop_limit'    THEN stop_price IS NOT NULL AND limit_price IS NOT NULL AND trail_pct IS NULL
            WHEN 'trailing_stop' THEN trail_pct IS NOT NULL AND limit_price IS NULL
            WHEN 'iceberg'       THEN limit_price IS NOT NULL AND display_qty IS NOT NULL
        END
    ),
    -- A market order cannot rest on the book, so "good till cancelled"
    -- is meaningless for it.
    CONSTRAINT market_order_tif CHECK (kind <> 'market' OR tif IN ('day','ioc','fok')),
    CONSTRAINT avg_price_only_when_filled CHECK ((avg_fill_price IS NOT NULL) = (filled_qty > 0)),
    CONSTRAINT rejected_has_reason CHECK ((status = 'rejected') = (reject_reason IS NOT NULL))
);

-- =====================================================================
-- THE ORDER BOOK INDEX -- the single most performance-critical index in
-- the system. The matching engine asks, thousands of times a second:
-- "for this instrument and side, which resting order is next in
-- price-time priority?"
--
-- It is PARTIAL (only live, resting orders are in it -- filled and
-- cancelled orders, which will dominate the table within days, are not)
-- and its sort order IS price-time priority, so the engine reads the
-- top of book with a single index scan and no sort step at all.
-- =====================================================================
CREATE INDEX ix_book_bids ON trading.trade_order
    (instrument_id, limit_price DESC, seq_no ASC)
    WHERE side = 'buy'  AND status IN ('working','partially_filled') AND stop_armed = FALSE;

CREATE INDEX ix_book_asks ON trading.trade_order
    (instrument_id, limit_price ASC,  seq_no ASC)
    WHERE side = 'sell' AND status IN ('working','partially_filled') AND stop_armed = FALSE;

-- Stop orders waiting to be elected are scanned on every trade print.
CREATE INDEX ix_stops_pending ON trading.trade_order (instrument_id, stop_price)
    WHERE stop_armed AND status IN ('working','partially_filled');

CREATE INDEX ix_order_account   ON trading.trade_order (account_id, placed_at DESC);
CREATE INDEX ix_order_open      ON trading.trade_order (account_id, instrument_id)
    WHERE status IN ('pending_new','working','partially_filled');
CREATE INDEX ix_order_expiring  ON trading.trade_order (expires_at)
    WHERE expires_at IS NOT NULL AND status IN ('working','partially_filled');

COMMENT ON INDEX trading.ix_book_bids IS
  'Price-time priority as an index definition: highest bid first, then '
  'earliest sequence number. Partial on live orders so the index tracks '
  'the size of the BOOK, not the size of order history.';

-- ---------------------------------------------------------------------
-- EXECUTION :: the immutable trade tape. Partitioned by time because
-- this table grows fastest after market.tick and is always queried
-- within a date range.
-- ---------------------------------------------------------------------
CREATE TABLE trading.execution (
    execution_id   BIGINT GENERATED ALWAYS AS IDENTITY,
    executed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    instrument_id  INTEGER NOT NULL REFERENCES reference.instrument(instrument_id),
    price          price_amt NOT NULL,
    quantity       qty_amt   NOT NULL,

    buy_order_id   BIGINT NOT NULL REFERENCES trading.trade_order(order_id),
    sell_order_id  BIGINT NOT NULL REFERENCES trading.trade_order(order_id),
    buy_account_id  BIGINT NOT NULL REFERENCES trading.account(account_id),
    sell_account_id BIGINT NOT NULL REFERENCES trading.account(account_id),

    -- Which side crossed the spread. Exchanges charge the aggressor more
    -- (taker fee) and may rebate the resting side (maker rebate).
    aggressor_side trading.order_side NOT NULL,
    buy_fee        money_amt NOT NULL DEFAULT 0,
    sell_fee       money_amt NOT NULL DEFAULT 0,

    -- Link to the double-entry record that settled this fill. Every
    -- execution is traceable to the exact journal entry that moved the
    -- cash and the shares.
    settlement_entry_id BIGINT REFERENCES ledger.journal_entry(entry_id),

    PRIMARY KEY (executed_at, execution_id),
    CONSTRAINT distinct_sides CHECK (buy_order_id <> sell_order_id)
) PARTITION BY RANGE (executed_at);

CREATE INDEX ix_exec_instrument_time ON trading.execution (instrument_id, executed_at DESC);
CREATE INDEX ix_exec_buy_order  ON trading.execution (buy_order_id);
CREATE INDEX ix_exec_sell_order ON trading.execution (sell_order_id);
CREATE INDEX ix_exec_buy_acct   ON trading.execution (buy_account_id, executed_at DESC);
CREATE INDEX ix_exec_sell_acct  ON trading.execution (sell_account_id, executed_at DESC);
CREATE INDEX ix_exec_time_brin  ON trading.execution USING brin (executed_at);

SELECT ops.ensure_time_partitions('trading','execution',
    (CURRENT_DATE - INTERVAL '6 months')::date,
    (CURRENT_DATE + INTERVAL '3 months')::date, '1 month');

COMMENT ON TABLE trading.execution IS
  'The trade tape. Immutable, partitioned by month, and every row carries '
  'settlement_entry_id so a fill can be tied to the exact ledger entry '
  'that moved the money.';

-- ---------------------------------------------------------------------
-- POSITION :: cost-basis read model.
--
-- Share QUANTITY is already authoritative in ledger.balance. What the
-- ledger does not carry is average cost and realised P&L, which depend
-- on the ORDER fills were applied in. That is what this table adds; a
-- verification function asserts quantity here always equals the ledger.
-- ---------------------------------------------------------------------
CREATE TABLE trading.position (
    account_id     BIGINT  NOT NULL REFERENCES trading.account(account_id) ON DELETE CASCADE,
    instrument_id  INTEGER NOT NULL REFERENCES reference.instrument(instrument_id),
    quantity       money_amt NOT NULL DEFAULT 0,
    avg_cost       NUMERIC(20,8) NOT NULL DEFAULT 0 CHECK (avg_cost >= 0),
    realized_pnl   money_amt NOT NULL DEFAULT 0,
    opened_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, instrument_id)
);

CREATE INDEX ix_position_instrument ON trading.position (instrument_id) WHERE quantity <> 0;

-- =====================================================================
-- POSITION QUANTITY IS DERIVED, NOT TRACKED.
--
-- First iteration of this schema updated trading.position only from
-- trade fills, which silently desynchronised the moment shares moved for
-- any other reason (issuance, a corporate action, a transfer). The fix is
-- structural: share quantity is maintained by a TRIGGER on the ledger
-- itself, so every security posting -- whatever caused it -- lands here
-- too. The two models cannot drift, by construction.
--
-- avg_cost and realized_pnl are NOT derivable from the ledger (they
-- depend on the order fills arrived in), so those are still written by
-- the trade path below.
-- =====================================================================
CREATE OR REPLACE FUNCTION trading.sync_position_qty() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.asset_class <> 'security' THEN RETURN NULL; END IF;

    INSERT INTO trading.position AS pos (account_id, instrument_id, quantity, updated_at)
    VALUES (NEW.account_id, NEW.instrument_id, NEW.amount, now())
    ON CONFLICT (account_id, instrument_id) DO UPDATE
       SET quantity = pos.quantity + EXCLUDED.quantity, updated_at = now();

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_posting_syncs_position
    AFTER INSERT ON ledger.posting
    FOR EACH ROW EXECUTE FUNCTION trading.sync_position_qty();

-- ---------------------------------------------------------------------
-- Weighted-average cost basis and realised P&L, applied per fill.
--
-- Runs AFTER the ledger trigger above has already moved the quantity, so
-- the pre-trade quantity is reconstructed as (current - this fill).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trading.apply_fill_to_position(
    p_account_id BIGINT, p_instrument_id INTEGER,
    p_signed_qty money_amt,      -- +ve buy, -ve sell
    p_price price_amt
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_cur_qty  money_amt;
    v_old_qty  money_amt;
    v_old_cost NUMERIC(20,8);
    v_new_cost NUMERIC(20,8);
    v_realized money_amt := 0;
    v_closing  money_amt;
BEGIN
    SELECT p.quantity, p.avg_cost INTO v_cur_qty, v_old_cost
      FROM trading.position p
     WHERE p.account_id = p_account_id AND p.instrument_id = p_instrument_id
     FOR UPDATE;

    v_cur_qty  := COALESCE(v_cur_qty, 0);
    v_old_cost := COALESCE(v_old_cost, 0);
    v_old_qty  := v_cur_qty - p_signed_qty;   -- quantity before this fill

    IF v_old_qty = 0 OR sign(v_old_qty) = sign(p_signed_qty) THEN
        -- Opening or adding: roll the weighted average cost.
        v_new_cost := CASE WHEN v_cur_qty = 0 THEN 0
                      ELSE (abs(v_old_qty) * v_old_cost + abs(p_signed_qty) * p_price)
                           / abs(v_cur_qty) END;
    ELSE
        -- Reducing or flipping: the overlapping size realises P&L at the
        -- old basis.
        v_closing  := least(abs(p_signed_qty), abs(v_old_qty));
        v_realized := CASE WHEN v_old_qty > 0
                           THEN v_closing * (p_price - v_old_cost)   -- closing a long
                           ELSE v_closing * (v_old_cost - p_price)   -- closing a short
                      END;
        -- If the fill flips the sign, the residual opens at the fill price.
        v_new_cost := CASE WHEN v_cur_qty = 0 THEN 0
                           WHEN sign(v_cur_qty) <> sign(v_old_qty) THEN p_price
                           ELSE v_old_cost END;
    END IF;

    UPDATE trading.position pos
       SET avg_cost     = v_new_cost,
           realized_pnl = pos.realized_pnl + v_realized,
           updated_at   = now()
     WHERE pos.account_id = p_account_id AND pos.instrument_id = p_instrument_id;
END;
$$;

-- Set an opening cost basis for shares that arrived outside the matching
-- engine (issuance, transfers in, migrated history).
CREATE OR REPLACE FUNCTION trading.set_cost_basis(
    p_account_id BIGINT, p_instrument_id INTEGER, p_price price_amt
) RETURNS VOID LANGUAGE sql AS $$
    UPDATE trading.position SET avg_cost = p_price, updated_at = now()
     WHERE account_id = p_account_id AND instrument_id = p_instrument_id;
$$;

-- ---------------------------------------------------------------------
-- Cross-model consistency proof: the cost-basis table and the ledger
-- must agree on every share quantity, for every account.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trading.verify_positions_match_ledger()
RETURNS TABLE (account_no TEXT, symbol TEXT, position_qty money_amt, ledger_qty money_amt)
LANGUAGE sql STABLE AS $$
    WITH pos AS (
        SELECT account_id, instrument_id, quantity FROM trading.position
    ), led AS (
        SELECT account_id, instrument_id, balance FROM ledger.balance
         WHERE asset_class = 'security'
    ), joined AS (
        SELECT COALESCE(p.account_id, l.account_id)       AS account_id,
               COALESCE(p.instrument_id, l.instrument_id) AS instrument_id,
               COALESCE(p.quantity, 0)                    AS pq,
               COALESCE(l.balance, 0)                     AS lq
          FROM pos p
          FULL JOIN led l ON l.account_id = p.account_id
                         AND l.instrument_id = p.instrument_id
    )
    SELECT a.account_no, i.symbol, j.pq::money_amt, j.lq::money_amt
      FROM joined j
      JOIN trading.account a USING (account_id)
      JOIN reference.instrument i USING (instrument_id)
     WHERE j.pq <> j.lq
     ORDER BY a.account_no, i.symbol;
$$;
