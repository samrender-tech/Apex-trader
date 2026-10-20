-- =====================================================================
-- 024_view_security_invoker.sql
--
-- A ROW LEVEL SECURITY HOLE, AND WHY IT WAS INVISIBLE
--
-- Every per-user table in this schema carries an RLS policy keyed on
-- identity.current_user_id(), and 014_security.sql has regression tests
-- proving those policies hold. They do hold -- when you query the TABLE.
--
-- A view is different. By default a view executes with the privileges of
-- its OWNER, and RLS on the underlying tables is evaluated against that
-- owner too. Every view here is owned by `apex`, which owns the tables,
-- and a table owner is exempt from its own RLS unless FORCE ROW LEVEL
-- SECURITY is set. So a SELECT through a view read EVERY row -- the
-- policies were simply not consulted.
--
-- Nothing caught it because almost every endpoint also passes an
-- explicit account_id predicate, so the leak was masked by application
-- code doing the filtering the database was supposed to be doing. The
-- RLS layer was decoration.
--
-- /api/watchlist was the endpoint that had no predicate -- its docstring
-- said, in as many words, "No user_id predicate: Row Level Security
-- scopes this to the caller". It returned all eight demo users' lists.
--
-- PostgreSQL 15 added `security_invoker`, which makes a view run as the
-- CALLER so the underlying policies apply. That is what this turns on.
--
-- ONE VIEW IS DELIBERATELY EXCLUDED
--
-- trading.v_book_depth aggregates the order book into a price ladder.
-- The book is public market data: a trader must see the full depth, not
-- only their own resting orders. Running it as invoker would filter it
-- down to the caller's own orders, which is not a security improvement
-- but a functional break -- the depth ladder would show one side of a
-- market that only the viewer is in. It exposes price and size only,
-- never an account, so there is nothing to leak. The exclusion is the
-- considered answer, not an oversight, and the test below asserts it
-- stays excluded on purpose.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Views over per-user data. These now run as the caller.
-- ---------------------------------------------------------------------
ALTER VIEW social.v_watchlist            SET (security_invoker = true);
ALTER VIEW analytics.v_portfolio         SET (security_invoker = true);
ALTER VIEW analytics.v_account_summary   SET (security_invoker = true);
ALTER VIEW analytics.v_blotter           SET (security_invoker = true);
ALTER VIEW analytics.v_open_orders       SET (security_invoker = true);

COMMENT ON VIEW social.v_watchlist IS
  'security_invoker: runs as the caller so social.watchlist''s RLS policy '
  'applies. Without it a view owned by the table owner bypasses RLS entirely.';

COMMENT ON VIEW trading.v_book_depth IS
  'Aggregated public order book. Deliberately NOT security_invoker: depth is '
  'market data and must show every participant''s resting size. Exposes price '
  'and quantity only -- no account identity -- so there is nothing to scope.';

-- ---------------------------------------------------------------------
-- A VIEW IS NOT THE ONLY WAY TO LOSE RLS
--
-- ops.assert_rls_intact() makes the invariant checkable instead of
-- remembered. It reports any view in a user-data schema that is still
-- running as its owner, so the next view someone adds has to make the
-- same decision explicitly rather than inheriting the unsafe default.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.assert_rls_intact()
RETURNS TABLE (view_name TEXT, security_invoker BOOLEAN, verdict TEXT)
LANGUAGE sql STABLE AS $$
    WITH v AS (
        SELECT (c.relnamespace::regnamespace || '.' || c.relname)::TEXT AS vname,
               COALESCE((SELECT o.option_value = 'true'
                           FROM pg_options_to_table(c.reloptions) o
                          WHERE o.option_name = 'security_invoker'), FALSE) AS si
          FROM pg_class c
         WHERE c.relkind = 'v'
           AND c.relnamespace::regnamespace::TEXT IN
               ('analytics','social','trading','risk','surveil','ledger')
    )
    SELECT v.vname, v.si,
           CASE
             -- Reviewed and intentionally owner-run; see the comment above.
             WHEN v.vname = 'trading.v_book_depth'
               THEN 'public market data -- owner-run by design'
             WHEN v.si THEN 'ok'
             ELSE 'LEAK: view bypasses RLS on its base tables'
           END
      FROM v ORDER BY v.si, v.vname;
$$;

COMMENT ON FUNCTION ops.assert_rls_intact() IS
  'Lists every view over user data that does not run as the caller. A view '
  'owned by the table owner is exempt from the base tables'' RLS, so an '
  'un-flagged view silently disables the policies underneath it.';

GRANT EXECUTE ON FUNCTION ops.assert_rls_intact() TO apex_app, apex_compliance;

-- ---------------------------------------------------------------------
-- The two remaining views, decided rather than left.
--
-- analytics.v_alert_queue reads surveil.alert, which IS RLS-protected
-- (compliance and admin only). Run it as the caller so a trader hitting
-- the endpoint gets an empty queue from the DATABASE, not from a role
-- check in Python that someone can forget to write.
--
-- analytics.v_fx_board reads reference.currency and reference.fx_rate.
-- Neither carries RLS -- a USD/INR rate is the same fact for everybody,
-- and the board is on the public markets page. There is no policy for a
-- security_invoker view to enforce, so flagging it would only suggest a
-- protection that does not exist.
-- ---------------------------------------------------------------------
ALTER VIEW analytics.v_alert_queue SET (security_invoker = true);

CREATE OR REPLACE FUNCTION ops.assert_rls_intact()
RETURNS TABLE (view_name TEXT, security_invoker BOOLEAN, verdict TEXT)
LANGUAGE sql STABLE AS $$
    WITH v AS (
        SELECT (c.relnamespace::regnamespace || '.' || c.relname)::TEXT AS vname,
               COALESCE((SELECT o.option_value = 'true'
                           FROM pg_options_to_table(c.reloptions) o
                          WHERE o.option_name = 'security_invoker'), FALSE) AS si
          FROM pg_class c
         WHERE c.relkind = 'v'
           AND c.relnamespace::regnamespace::TEXT IN
               ('analytics','social','trading','risk','surveil','ledger')
    )
    SELECT v.vname, v.si,
           CASE
             WHEN v.vname = 'trading.v_book_depth'
               THEN 'public market data -- owner-run by design'
             WHEN v.vname = 'analytics.v_fx_board'
               THEN 'public reference data -- no RLS underneath'
             WHEN v.si THEN 'ok'
             ELSE 'LEAK: view bypasses RLS on its base tables'
           END
      FROM v ORDER BY v.si, v.vname;
$$;
