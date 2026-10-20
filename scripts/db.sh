#!/usr/bin/env bash
# =====================================================================
# Apex Trader database helper.
#
#   db.sh migrate   apply any migrations this database has not had yet
#   db.sh status    show which migrations are applied and which are pending
#   db.sh reset     drop and rebuild from zero
#   db.sh baseline  mark already-present migrations as applied (no re-run)
#   db.sh seed | test | bench | psql
#
# WHY TRACKING: the migration files are ordinary DDL -- CREATE TABLE,
# CREATE DOMAIN, CREATE TRIGGER -- which fail if run a second time. An
# earlier version of this script simply replayed every file on every
# invocation, so `migrate` worked on a fresh database and died on the
# first statement of 001 on an existing one ("type money_amt already
# exists"), silently leaving new migrations unapplied.
#
# Each file is now recorded in ops.schema_migration once it succeeds, and
# only unrecorded files are applied. Migrations therefore do not need to
# be idempotent -- they need to run exactly once, which is the normal
# contract for a migration.
# =====================================================================
set -uo pipefail
export PGPASSWORD="${PGPASSWORD:-apex_dev_pw}"
PGHOST="${PGHOST:-127.0.0.1}"; PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-apex}"; PGDATABASE="${PGDATABASE:-apex_trader}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pg()  { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"; }
pgq() { pg -tAq "$@"; }

# ---------------------------------------------------------------------
# Portability: this runs on Linux (GNU userland) and macOS (BSD).
#
# Two things differ and both bit this script on a Mac:
#   * `date +%s%3N` is a GNU extension. BSD date does not understand %N
#     and emits it literally, producing "1792268272" + "3N" -- which then
#     fails arithmetic with "value too great for base".
#   * `sha256sum` is GNU coreutils; macOS ships `shasum -a 256` instead.
#
# Both are probed once, at startup, rather than assumed.
# ---------------------------------------------------------------------
if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
  now_ms() { date +%s%3N; }
elif command -v python3 >/dev/null 2>&1; then
  now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
else
  now_ms() { echo $(( $(date +%s) * 1000 )); }   # whole seconds; timing is informational
fi

if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$1" | cut -c1-16; }
elif command -v shasum >/dev/null 2>&1; then
  checksum() { shasum -a 256 "$1" | cut -c1-16; }
else
  checksum() { cksum "$1" | awk '{print $1}'; }
fi

ensure_tracking() {
  pg -q -c "CREATE SCHEMA IF NOT EXISTS ops;" \
        -c "CREATE TABLE IF NOT EXISTS ops.schema_migration (
              filename    TEXT PRIMARY KEY,
              checksum    TEXT NOT NULL,
              applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
              duration_ms INTEGER,
              baselined   BOOLEAN NOT NULL DEFAULT FALSE
            );" >/dev/null || return 1
}

# Sentinel object per migration: how we tell, on a database built before
# tracking existed, which migrations are already in place.
sentinel_sql() {
  case "$1" in
    001_*) echo "SELECT 1 FROM pg_type WHERE typname='money_amt'";;
    002_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='identity' AND c.relname='app_user'";;
    003_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='reference' AND c.relname='instrument'";;
    004_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='market' AND c.relname='tick'";;
    005_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='ledger' AND c.relname='posting'";;
    006_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='trading' AND c.relname='trade_order'";;
    007_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='risk' AND c.relname='risk_limit'";;
    008_*) echo "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='engine' AND p.proname='submit_order'";;
    009_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='surveil' AND c.relname='alert'";;
    010_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='social' AND c.relname='strategy'";;
    011_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='audit' AND c.relname='activity_log'";;
    012_*) echo "SELECT 1 FROM pg_views WHERE schemaname='trading' AND viewname='v_book_depth'";;
    013_*) echo "SELECT 1 FROM pg_matviews WHERE matviewname='mv_strategy_leaderboard'";;
    014_*) echo "SELECT 1 FROM pg_policies WHERE policyname='p_order_own'";;
    015_*) echo "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ops' AND p.proname='end_of_day'";;
    016_*) echo "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ops' AND p.proname='backfill_execution'";;
    017_*) echo "SELECT 1 FROM pg_trigger WHERE tgname='trg_audit_order_material'";;
    018_*) echo "SELECT 1 FROM information_schema.columns WHERE table_schema='trading' AND table_name='account' AND column_name='allow_short_selling'";;
    019_*) echo "SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='reference' AND c.relname='currency'";;
    020_*) echo "SELECT 1 FROM pg_views WHERE schemaname='analytics' AND viewname='v_fx_board'";;
    021_*) echo "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ledger' AND p.proname='convert_currency' AND p.pronargs=6";;
    *)     echo "";;
  esac
}

already_present() {
  local q; q="$(sentinel_sql "$1")"
  [ -z "$q" ] && return 1
  [ "$(pgq -c "SELECT EXISTS($q)")" = "t" ]
}

is_applied() {
  [ "$(pgq -c "SELECT EXISTS(SELECT 1 FROM ops.schema_migration WHERE filename='$1')")" = "t" ]
}

die_rec() {
  echo "ERROR: $1 applied but could not be recorded in ops.schema_migration." >&2
  echo "       Re-running migrate would apply it twice. Record it manually with:" >&2
  echo "       ./scripts/db.sh psql -c \"INSERT INTO ops.schema_migration(filename,checksum) VALUES ('$1','manual')\"" >&2
  exit 1
}

record() {  # filename checksum duration_ms baselined
  pg -q -c "INSERT INTO ops.schema_migration (filename,checksum,duration_ms,baselined)
            VALUES ('$1','$2',$3,$4)
            ON CONFLICT (filename) DO UPDATE
              SET checksum=EXCLUDED.checksum, applied_at=now(),
                  duration_ms=EXCLUDED.duration_ms;" >/dev/null
}

do_baseline() {
  local n=0
  for f in "$ROOT"/db/migrations/*.sql; do
    local b; b="$(basename "$f")"
    is_applied "$b" && continue
    if already_present "$b"; then
      record "$b" "$(checksum "$f")" 0 true
      printf '  \033[33mbaselined\033[0m %s (already present)\n' "$b"
      n=$((n+1))
    fi
  done
  [ "$n" -gt 0 ] && printf '  %s migration(s) marked as already applied\n' "$n"
  return 0
}

do_migrate() {
  ensure_tracking || { echo "could not create tracking table" >&2; exit 1; }

  # A database built before tracking existed has objects but no records.
  # Detect what is already there rather than replaying it.
  if [ "$(pgq -c 'SELECT count(*) FROM ops.schema_migration')" = "0" ]; then
    do_baseline
  fi

  local applied=0 skipped=0
  for f in "$ROOT"/db/migrations/*.sql; do
    local b; b="$(basename "$f")"
    if is_applied "$b"; then skipped=$((skipped+1)); continue; fi

    printf '\033[36m==> %s\033[0m\n' "$b"
    local t0 t1 dur
    t0=$(now_ms)
    # ALTER TYPE ... ADD VALUE cannot be bundled with its own use inside
    # one transaction, so files containing it are applied statement by
    # statement; everything else gets all-or-nothing.
    if grep -q "ALTER TYPE" "$f"; then
      pg -q -f "$f" || { echo "FAILED: $b (not recorded; fix and re-run)" >&2; exit 1; }
    else
      pg -q --single-transaction -f "$f" || { echo "FAILED: $b (rolled back; fix and re-run)" >&2; exit 1; }
    fi
    t1=$(now_ms); dur=$(( t1 - t0 ))
    record "$b" "$(checksum "$f")" "$dur" false \
      || die_rec "$b"   # a migration that ran but was not recorded would be re-run
    applied=$((applied+1))
  done

  if [ "$applied" -eq 0 ]; then
    printf '\033[32mdatabase is up to date\033[0m (%s migration(s) already applied)\n' "$skipped"
  else
    printf '\033[32m%s migration(s) applied\033[0m, %s already present\n' "$applied" "$skipped"
  fi
}

do_status() {
  ensure_tracking || exit 1
  printf '%-34s %-10s %s\n' "MIGRATION" "STATE" "APPLIED"
  for f in "$ROOT"/db/migrations/*.sql; do
    local b; b="$(basename "$f")"
    local row; row="$(pgq -c "SELECT applied_at::timestamp(0)||'|'||baselined FROM ops.schema_migration WHERE filename='$b'")"
    if [ -n "$row" ]; then
      local when="${row%%|*}" base="${row##*|}"
      if [ "$base" = "true" ]; then printf '%-34s \033[33m%-10s\033[0m %s\n' "$b" "baselined" "$when"
      else printf '%-34s \033[32m%-10s\033[0m %s\n' "$b" "applied" "$when"; fi
    else
      printf '%-34s \033[31m%-10s\033[0m\n' "$b" "PENDING"
    fi
  done
}

case "${1:-migrate}" in
  migrate)  do_migrate;;
  status)   do_status;;
  baseline) ensure_tracking && do_baseline;;
  reset)
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -v ON_ERROR_STOP=1 -q \
      -c "DROP DATABASE IF EXISTS $PGDATABASE WITH (FORCE);" \
      -c "CREATE DATABASE $PGDATABASE OWNER $PGUSER;" || exit 1
    echo "database recreated"; do_migrate;;
  seed)   for f in "$ROOT"/db/seed/*.sql;  do printf '\033[36m==> %s\033[0m\n' "$(basename "$f")"; pg -q -f "$f"; done;;
  test)   for f in "$ROOT"/db/test/[0-9]*.sql; do printf '\033[36m==> %s\033[0m\n' "$(basename "$f")"; pg -f "$f"; done;;
  bench)  for f in "$ROOT"/db/bench/*.sql; do printf '\033[36m==> %s\033[0m\n' "$(basename "$f")"; pg -f "$f"; done;;
  psql)   shift; pg "$@";;
  *) echo "usage: db.sh {migrate|status|baseline|reset|seed|test|bench|psql}" >&2; exit 2;;
esac
