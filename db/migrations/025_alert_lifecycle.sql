-- =====================================================================
-- 025_alert_lifecycle.sql
--
-- TWO RULES THAT CONTRADICTED EACH OTHER
--
-- 022 gave risk.alert_fire both of these:
--
--   alert_id BIGINT NOT NULL REFERENCES risk.price_alert(alert_id)
--                                                  ON DELETE CASCADE
--   CREATE TRIGGER ... BEFORE UPDATE OR DELETE ON risk.alert_fire
--       EXECUTE FUNCTION ledger.forbid_mutation();
--
-- The first says "when the alert goes, its fire history goes with it".
-- The second says "this table is append-only; nothing in it is ever
-- deleted". Both are defensible on their own. Together they mean that
-- an alert which has ever fired can NEVER be deleted: the cascade tries
-- to remove the fire rows, the append-only trigger refuses, and the
-- whole DELETE aborts with "append-only (attempted DELETE)".
--
-- That is not a hypothetical. DELETE /api/alerts/{id} returned a 500 for
-- every alert a user had actually been notified about -- the only ones
-- they are likely to want to clear.
--
-- ON DELETE SET NULL does not fix it either, for the same reason one
-- level down: SET NULL is an UPDATE, and the trigger forbids UPDATE too.
--
-- THE DECISION
--
-- A fire is history; an alert is configuration. History wins. The FK
-- becomes RESTRICT -- an explicit refusal instead of a cascade that
-- cannot complete -- and an alert that has fired is ARCHIVED rather than
-- deleted. The user's list stops showing it, the audit trail keeps every
-- notification that was ever sent, and the referential integrity between
-- the two is never broken.
--
-- An alert that never fired has no history to protect, so that one is
-- still deleted outright. risk.remove_alert() picks between the two so
-- the caller does not have to know which case it is in.
-- =====================================================================

ALTER TABLE risk.price_alert
    ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

COMMENT ON COLUMN risk.price_alert.archived_at IS
  'Set instead of deleting an alert that has fire history. The fire rows '
  'are append-only, so the alert they reference must outlive the user''s '
  'decision to stop watching it.';

-- An archived alert must not be live. Not a nicety: evaluate_price_alerts
-- would otherwise keep firing an alert the user believes they removed.
DO $$
BEGIN
    ALTER TABLE risk.price_alert
        ADD CONSTRAINT archived_alert_is_inactive
        CHECK (archived_at IS NULL OR NOT is_active);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Replace the cascade. Finding the constraint by catalog rather than by
-- name because 022 let PostgreSQL generate the name.
DO $$
DECLARE v_con TEXT;
BEGIN
    SELECT conname INTO v_con
      FROM pg_constraint
     WHERE conrelid = 'risk.alert_fire'::regclass
       AND contype = 'f'
       AND confrelid = 'risk.price_alert'::regclass;
    IF v_con IS NOT NULL THEN
        EXECUTE format('ALTER TABLE risk.alert_fire DROP CONSTRAINT %I', v_con);
    END IF;
END $$;

ALTER TABLE risk.alert_fire
    ADD CONSTRAINT alert_fire_alert_fk
    FOREIGN KEY (alert_id) REFERENCES risk.price_alert(alert_id)
    ON DELETE RESTRICT;

-- Don't scan the archived ones on every evaluation sweep.
CREATE INDEX IF NOT EXISTS ix_price_alert_live
    ON risk.price_alert (instrument_id)
 WHERE is_active AND archived_at IS NULL;

-- ---------------------------------------------------------------------
-- Removal, with the choice made in one place.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION risk.remove_alert(p_alert_id BIGINT)
RETURNS TEXT LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_fires BIGINT;
BEGIN
    -- RLS on risk.price_alert scopes this to the caller's own alerts, so
    -- a missing row and someone else's row are indistinguishable here --
    -- which is the correct answer to give either way.
    IF NOT EXISTS (SELECT 1 FROM risk.price_alert
                    WHERE alert_id = p_alert_id AND archived_at IS NULL) THEN
        RETURN 'not_found';
    END IF;

    SELECT count(*) INTO v_fires FROM risk.alert_fire WHERE alert_id = p_alert_id;

    IF v_fires = 0 THEN
        DELETE FROM risk.price_alert WHERE alert_id = p_alert_id;
        RETURN 'deleted';
    END IF;

    UPDATE risk.price_alert
       SET is_active = FALSE, archived_at = now()
     WHERE alert_id = p_alert_id;
    RETURN 'archived';
END;
$$;

COMMENT ON FUNCTION risk.remove_alert(BIGINT) IS
  'Deletes an alert that never fired; archives one that did, because its '
  'fire rows are append-only and still reference it. Returns deleted / '
  'archived / not_found.';

GRANT EXECUTE ON FUNCTION risk.remove_alert(BIGINT) TO apex_app;

-- ---------------------------------------------------------------------
-- Keep the evaluation sweep off archived alerts.
--
-- Identical to 022's version in every other respect -- same NOTIFY
-- channel and payload, same five-minute rate limit on repeating alerts,
-- same SECURITY INVOKER so RLS still scopes a non-admin caller to their
-- own alerts. The single change is the archived_at predicate: without
-- it, archiving stops the alert appearing in the user's list but the
-- sweep keeps firing it, and they keep getting notified about something
-- they removed.
-- ---------------------------------------------------------------------
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
           AND a.archived_at IS NULL
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

GRANT EXECUTE ON FUNCTION risk.evaluate_price_alerts() TO apex_app;

-- ---------------------------------------------------------------------
-- While here: the append-only error named the wrong schema.
--
-- ledger.forbid_mutation() hardcoded 'ledger.%' into its message, so the
-- trigger 022 attached to risk.alert_fire reported the violation as
-- "ledger.alert_fire is append-only" -- a table that does not exist.
-- Anyone debugging it would go looking in the wrong schema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger.forbid_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        '%.% is append-only (attempted %)',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = '42501',
              HINT = 'post a reversing entry instead of mutating history';
END;
$$;
