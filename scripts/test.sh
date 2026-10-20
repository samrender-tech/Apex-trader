#!/usr/bin/env bash
# Runs the SQL test suite and exits non-zero on any failure.
set -uo pipefail
export PGPASSWORD="${PGPASSWORD:-apex_dev_pw}"
PGHOST="${PGHOST:-127.0.0.1}"; PGUSER="${PGUSER:-apex}"; PGDATABASE="${PGDATABASE:-apex_trader}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
pg() { psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" "$@"; }

pg -q -v ON_ERROR_STOP=1 -f db/test/00_harness.sql || exit 1

# ON_ERROR_STOP is deliberately OFF: t.raises() expects failures, and it
# traps them itself inside plpgsql. So nothing should ever reach psql's
# own error channel -- and if something does, it means an assertion
# STATEMENT failed to run rather than failed to hold. Those are invisible
# in t.result (no row is written at all), so the suite would report green
# while quietly having checked less than it claims. Collect them.
ERR_LOG="$(mktemp)"
trap 'rm -f "$ERR_LOG"' EXIT

for f in db/test/[1-9]*.sql; do
  printf '\033[36m==> %s\033[0m\n' "$(basename "$f")"
  pg -q -f "$f" 2>&1 \
    | tee >(grep -E "^psql:.*(ERROR|FATAL)" >> "$ERR_LOG") \
    | grep -Ev "^(DO|SELECT|INSERT|UPDATE|DELETE|TRUNCATE|ALTER|NOTICE)" | sed '/^$/d' || true
done

echo ""
pg -c "SELECT suite, passed, failed FROM t.report();"
FAILED=$(pg -tAc "SELECT count(*) FROM t.result WHERE NOT passed")
if [ "$FAILED" != "0" ]; then
  echo ""
  printf '\033[31m%s FAILING ASSERTION(S)\033[0m\n' "$FAILED"
  pg -x -c "SELECT suite, name, expected, actual FROM t.result WHERE NOT passed ORDER BY id"
  exit 1
fi
if [ -s "$ERR_LOG" ]; then
  echo ""
  printf '\033[31mASSERTION STATEMENT(S) FAILED TO RUN -- the suite checked less than it reports\033[0m\n'
  cat "$ERR_LOG"
  exit 1
fi

TOTAL=$(pg -tAc "SELECT count(*) FROM t.result")
printf '\033[32mall %s assertions passed\033[0m\n' "$TOTAL"
