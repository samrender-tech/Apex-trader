-- =====================================================================
-- Apex Trader :: 010_social.sql
-- Published strategies and copy-trading.
--
-- The interesting database problem here is FAN-OUT. One leader's trade
-- must become N follower orders. Doing that synchronously inside the
-- leader's own order transaction would be wrong: the leader's fill would
-- block on, and could be rolled back by, a stranger's risk failure.
--
-- So the trigger only ENQUEUES, and a worker drains the queue with
-- FOR UPDATE SKIP LOCKED -- the standard PostgreSQL pattern for a
-- concurrent work queue, which lets many workers pull disjoint batches
-- with no coordination and no lost rows.
-- =====================================================================

CREATE TABLE social.strategy (
    strategy_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_user_id BIGINT NOT NULL REFERENCES identity.app_user(user_id) ON DELETE CASCADE,
    -- The account whose trades ARE the strategy's signal.
    source_account_id BIGINT NOT NULL REFERENCES trading.account(account_id) ON DELETE CASCADE,
    name          TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 3 AND 80),
    slug          TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,60}$'),
    description   TEXT,
    visibility    social.visibility NOT NULL DEFAULT 'private',
    -- Performance fee the leader charges copiers, in basis points of
    -- profitable copied notional.
    fee_bps       bps NOT NULL DEFAULT 0,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT one_strategy_per_account UNIQUE (source_account_id)
);

CREATE INDEX ix_strategy_public ON social.strategy (created_at DESC)
    WHERE visibility = 'public' AND is_active;

-- Deferred FK from 006: an order can now name the strategy that spawned it.
ALTER TABLE trading.trade_order
    ADD CONSTRAINT fk_order_strategy
    FOREIGN KEY (source_strategy_id) REFERENCES social.strategy(strategy_id) ON DELETE SET NULL;

CREATE TABLE social.copy_subscription (
    subscription_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    strategy_id     BIGINT NOT NULL REFERENCES social.strategy(strategy_id) ON DELETE CASCADE,
    -- The follower's account that mirrors the leader.
    account_id      BIGINT NOT NULL REFERENCES trading.account(account_id) ON DELETE CASCADE,
    -- Sizing: mirror this percentage of the leader's quantity...
    allocation_pct  pct NOT NULL DEFAULT 100 CHECK (allocation_pct > 0),
    -- ...capped at this notional per copied trade.
    max_trade_notional money_amt NOT NULL DEFAULT 10000 CHECK (max_trade_notional > 0),
    status          social.sub_status NOT NULL DEFAULT 'active',
    subscribed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_at    TIMESTAMPTZ,

    CONSTRAINT one_sub_per_account_strategy UNIQUE (strategy_id, account_id),
    CONSTRAINT cancelled_consistent CHECK ((status='cancelled') = (cancelled_at IS NOT NULL))
);

CREATE INDEX ix_sub_active ON social.copy_subscription (strategy_id)
    WHERE status = 'active';

-- A follower must not copy their own strategy (an infinite mirror).
CREATE OR REPLACE FUNCTION social.forbid_self_copy() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM social.strategy s
                WHERE s.strategy_id = NEW.strategy_id
                  AND s.source_account_id = NEW.account_id) THEN
        RAISE EXCEPTION 'an account cannot copy its own strategy' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_no_self_copy BEFORE INSERT OR UPDATE ON social.copy_subscription
    FOR EACH ROW EXECUTE FUNCTION social.forbid_self_copy();

-- ---------------------------------------------------------------------
-- THE FAN-OUT QUEUE
-- ---------------------------------------------------------------------
CREATE TABLE social.copy_queue (
    job_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    execution_id  BIGINT NOT NULL,
    strategy_id   BIGINT NOT NULL REFERENCES social.strategy(strategy_id) ON DELETE CASCADE,
    instrument_id INTEGER NOT NULL REFERENCES reference.instrument(instrument_id),
    side          trading.order_side NOT NULL,
    quantity      qty_amt NOT NULL,
    price         price_amt NOT NULL,
    enqueued_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at  TIMESTAMPTZ,
    attempts      SMALLINT NOT NULL DEFAULT 0,
    last_error    TEXT
);

-- Partial index on the pending backlog only: the queue table grows
-- forever, the WORK does not.
CREATE INDEX ix_copy_queue_pending ON social.copy_queue (enqueued_at)
    WHERE processed_at IS NULL;

-- Mirror-order lineage, so a copied order can be traced to its origin.
CREATE TABLE social.copy_link (
    link_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    strategy_id      BIGINT NOT NULL REFERENCES social.strategy(strategy_id) ON DELETE CASCADE,
    subscription_id  BIGINT NOT NULL REFERENCES social.copy_subscription(subscription_id) ON DELETE CASCADE,
    leader_execution_id BIGINT NOT NULL,
    follower_order_id   BIGINT NOT NULL REFERENCES trading.trade_order(order_id) ON DELETE CASCADE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_copy_link_strategy ON social.copy_link (strategy_id, created_at DESC);

-- ---------------------------------------------------------------------
-- Enqueue trigger. Fires on the leader's fill, writes one cheap row,
-- and returns. The leader's transaction is not held hostage.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION social.enqueue_copy_fanout() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_strategy_id BIGINT;
    v_side        trading.order_side;
    v_order_id    BIGINT;
    v_is_mirror   BOOLEAN;
BEGIN
    -- Determine which side initiated, and whether that order was itself
    -- already a mirror. Without this guard, a follower who also publishes
    -- a strategy would start an infinite copy cascade.
    FOR v_side, v_order_id IN
        SELECT 'buy'::trading.order_side, NEW.buy_order_id
        UNION ALL
        SELECT 'sell'::trading.order_side, NEW.sell_order_id
    LOOP
        SELECT (o.source_strategy_id IS NOT NULL) INTO v_is_mirror
          FROM trading.trade_order o WHERE o.order_id = v_order_id;
        CONTINUE WHEN v_is_mirror;

        SELECT s.strategy_id INTO v_strategy_id
          FROM social.strategy s
          JOIN trading.trade_order o ON o.account_id = s.source_account_id
         WHERE o.order_id = v_order_id
           AND s.is_active
           AND s.visibility IN ('public','followers');

        IF v_strategy_id IS NOT NULL THEN
            INSERT INTO social.copy_queue
                (execution_id, strategy_id, instrument_id, side, quantity, price)
            VALUES (NEW.execution_id, v_strategy_id, NEW.instrument_id,
                    v_side, NEW.quantity, NEW.price);
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_execution_enqueues_copies
    AFTER INSERT ON trading.execution
    FOR EACH ROW EXECUTE FUNCTION social.enqueue_copy_fanout();

-- =====================================================================
-- THE WORKER
-- FOR UPDATE SKIP LOCKED is the whole point: N workers can call this
-- concurrently and each gets a disjoint batch with no blocking, no
-- double-processing and no central coordinator.
-- =====================================================================
CREATE OR REPLACE FUNCTION social.process_copy_queue(p_batch INTEGER DEFAULT 100)
RETURNS TABLE (jobs_processed INTEGER, orders_placed INTEGER, orders_rejected INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_job     RECORD;
    v_sub     RECORD;
    v_qty     NUMERIC;
    v_result  RECORD;
    v_jobs    INTEGER := 0;
    v_placed  INTEGER := 0;
    v_reject  INTEGER := 0;
    v_lot     NUMERIC;
BEGIN
    FOR v_job IN
        SELECT * FROM social.copy_queue q
         WHERE q.processed_at IS NULL
         ORDER BY q.enqueued_at
         LIMIT p_batch
         FOR UPDATE SKIP LOCKED
    LOOP
        v_jobs := v_jobs + 1;
        SELECT lot_size INTO v_lot FROM reference.instrument
         WHERE instrument_id = v_job.instrument_id;

        FOR v_sub IN
            SELECT cs.* FROM social.copy_subscription cs
             WHERE cs.strategy_id = v_job.strategy_id AND cs.status = 'active'
        LOOP
            -- Scale the leader's size by the follower's allocation, then
            -- cap it by their per-trade notional limit, then round DOWN
            -- to a whole lot so the order is actually valid.
            v_qty := v_job.quantity * v_sub.allocation_pct / 100.0;
            v_qty := least(v_qty, v_sub.max_trade_notional / v_job.price);
            v_qty := floor(v_qty / v_lot) * v_lot;

            CONTINUE WHEN v_qty <= 0;

            BEGIN
                -- Mirrors are sent as market orders so the follower
                -- tracks the leader rather than chasing a stale price.
                SELECT * INTO v_result FROM engine.submit_order(
                    v_sub.account_id, v_job.instrument_id, v_job.side,
                    'market', v_qty, NULL, NULL, 'ioc', NULL, NULL, NULL,
                    v_job.strategy_id, NULL);

                INSERT INTO social.copy_link
                    (strategy_id, subscription_id, leader_execution_id, follower_order_id)
                VALUES (v_job.strategy_id, v_sub.subscription_id,
                        v_job.execution_id, v_result.order_id);

                IF v_result.status = 'rejected' THEN
                    v_reject := v_reject + 1;
                ELSE
                    v_placed := v_placed + 1;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                -- One follower's failure must not abort the batch. A
                -- subtransaction block contains the damage.
                v_reject := v_reject + 1;
                UPDATE social.copy_queue
                   SET last_error = SQLERRM, attempts = attempts + 1
                 WHERE job_id = v_job.job_id;
            END;
        END LOOP;

        UPDATE social.copy_queue SET processed_at = now(), attempts = attempts + 1
         WHERE job_id = v_job.job_id;
    END LOOP;

    RETURN QUERY SELECT v_jobs, v_placed, v_reject;
END;
$$;

COMMENT ON FUNCTION social.process_copy_queue IS
  'Drains the copy-trade fan-out queue. FOR UPDATE SKIP LOCKED allows '
  'horizontal scaling: run this in N sessions and each claims a disjoint '
  'batch with no coordination. Per-follower failures are contained in a '
  'subtransaction so one rejection cannot roll back the batch.';

-- ---------------------------------------------------------------------
-- Follower graph (for the social feed), kept separate from copying:
-- you can watch a trader without mirroring their money.
-- ---------------------------------------------------------------------
CREATE TABLE social.follow (
    follower_user_id BIGINT NOT NULL REFERENCES identity.app_user(user_id) ON DELETE CASCADE,
    strategy_id      BIGINT NOT NULL REFERENCES social.strategy(strategy_id) ON DELETE CASCADE,
    followed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_user_id, strategy_id)
);
