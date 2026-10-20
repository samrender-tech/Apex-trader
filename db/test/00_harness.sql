-- =====================================================================
-- Minimal assertion harness. Results accumulate in a temp table so the
-- whole suite reports once at the end with a non-zero exit on failure.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS t;

CREATE TABLE IF NOT EXISTS t.result (
    id        SERIAL PRIMARY KEY,
    suite     TEXT NOT NULL,
    name      TEXT NOT NULL,
    passed    BOOLEAN NOT NULL,
    expected  TEXT,
    actual    TEXT,
    ran_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION t.ok(p_suite TEXT, p_name TEXT, p_cond BOOLEAN,
                                p_detail TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO t.result (suite,name,passed,expected,actual)
    VALUES (p_suite, p_name, COALESCE(p_cond,FALSE), 'true', COALESCE(p_detail, p_cond::text));
$$;

CREATE OR REPLACE FUNCTION t.eq(p_suite TEXT, p_name TEXT,
                                p_actual ANYELEMENT, p_expected ANYELEMENT)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO t.result (suite,name,passed,expected,actual)
    VALUES (p_suite, p_name, p_actual IS NOT DISTINCT FROM p_expected,
            p_expected::text, p_actual::text);
$$;

-- Same as t.eq but carries an explanatory note into the result row.
CREATE OR REPLACE FUNCTION t.eq(p_suite TEXT, p_name TEXT,
                                p_actual ANYELEMENT, p_expected ANYELEMENT,
                                p_note TEXT)
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO t.result (suite,name,passed,expected,actual)
    VALUES (p_suite, p_name, p_actual IS NOT DISTINCT FROM p_expected,
            p_expected::text, p_actual::text || ' -- ' || p_note);
$$;

-- Assert that a statement raises. Takes the SQL as text so the error can
-- be trapped rather than aborting the suite.
CREATE OR REPLACE FUNCTION t.raises(p_suite TEXT, p_name TEXT, p_sql TEXT,
                                    p_expect_substring TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_msg TEXT;
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO t.result (suite,name,passed,expected,actual)
        VALUES (p_suite,p_name,FALSE,'an exception','no exception raised');
        RETURN;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
    END;

    INSERT INTO t.result (suite,name,passed,expected,actual)
    VALUES (p_suite, p_name,
            p_expect_substring IS NULL OR position(lower(p_expect_substring) in lower(v_msg)) > 0,
            COALESCE('error containing: '||p_expect_substring,'any error'), v_msg);
END;
$$;

CREATE OR REPLACE FUNCTION t.report()
RETURNS TABLE (suite TEXT, passed BIGINT, failed BIGINT) LANGUAGE sql AS $$
    SELECT r.suite, count(*) FILTER (WHERE r.passed), count(*) FILTER (WHERE NOT r.passed)
      FROM t.result r GROUP BY r.suite ORDER BY r.suite;
$$;

-- Cancel every resting order so a test block starts from an empty book.
-- Tests that assume "no liquidity" must say so explicitly rather than
-- depending on whatever earlier blocks happened to leave behind.
CREATE OR REPLACE FUNCTION t.clear_book() RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_i INTEGER;
BEGIN
    UPDATE trading.trade_order SET status='cancelled', updated_at=now()
     WHERE status IN ('pending_new','working','partially_filled');
    FOR v_i IN SELECT instrument_id FROM reference.instrument LOOP
        PERFORM engine.refresh_top_of_book(v_i);
    END LOOP;
END;
$$;
