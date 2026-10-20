#!/usr/bin/env bash
# =====================================================================
# Apex Trader :: one-command setup.
#
#   ./scripts/setup.sh          migrate, seed and start
#   ./scripts/setup.sh --fresh  drop the database first, then all of that
#
# Exists because the steps have a required ORDER -- migrate before seed,
# seed before start -- and running them out of order produces a failure
# that points at a missing table rather than at the skipped step. This
# runs them in order and stops at the first one that fails.
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FRESH=0
DAYS="${APEX_SEED_DAYS:-45}"
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=1;;
    --days=*) DAYS="${a#*=}";;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "unknown option: $a" >&2; exit 2;;
  esac
done

step()  { printf '\n\033[36m[%s/4] %s\033[0m\n' "$1" "$2"; }
die()   { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

# ---- 0. prerequisites -------------------------------------------------
command -v psql >/dev/null || die "psql not found. Install PostgreSQL 15+ and put it on PATH."
pg_isready -q || die "PostgreSQL is not running. Start it (e.g. brew services start postgresql@16)."

# The same credentials db.sh uses. Without exporting these the version
# probe below authenticates as the shell user against a server that only
# knows `apex`, fails, and -- because the failure was swallowed into
# `|| echo 0` -- reports "PostgreSQL 15 or newer is required (found 0)".
# That sends you off to upgrade a database that was never the problem.
export PGPASSWORD="${PGPASSWORD:-apex_dev_pw}"
PGHOST="${PGHOST:-127.0.0.1}"; PGUSER="${PGUSER:-apex}"

PGVER="$(psql -h "$PGHOST" -U "$PGUSER" -d postgres -tAc 'SHOW server_version_num' 2>/dev/null)"
if [ -z "$PGVER" ]; then
  die "Could not connect to PostgreSQL as '$PGUSER' on $PGHOST.
    The server is running (pg_isready passed), so this is the role or its password.
    Create it with:
        createuser -s $PGUSER
        createdb -O $PGUSER ${PGDATABASE:-apex_trader}
        psql -d ${PGDATABASE:-apex_trader} -c \"ALTER ROLE $PGUSER WITH PASSWORD 'apex_dev_pw';\"
    Or point this at an existing role:
        PGUSER=you PGPASSWORD=yourpw ./scripts/setup.sh"
fi
if [ "$PGVER" -lt 150000 ] 2>/dev/null; then
  die "PostgreSQL 15 or newer is required (found $PGVER). Migration 005 uses NULLS NOT DISTINCT."
fi

# Build the virtualenv rather than complaining that it is absent.
#
# The tarball deliberately excludes .venv -- it is tens of megabytes of
# platform-specific binaries and a macOS venv is useless on Linux -- so a
# fresh extract legitimately has none, and "Python environment missing"
# is a true statement that solves nothing. Two commands the script can
# run itself should not be homework.
if [ ! -x "$ROOT/.venv/bin/python" ]; then
  echo "No virtualenv here (the archive does not ship one). Creating it..."
  command -v python3 >/dev/null || die "python3 not found. Install Python 3.11 or newer."
  python3 -m venv "$ROOT/.venv" || die "could not create .venv"
  "$ROOT/.venv/bin/pip" install --quiet --upgrade pip
  "$ROOT/.venv/bin/pip" install --quiet -r "$ROOT/backend/requirements.txt" \
    || die "installing dependencies. Try:
    .venv/bin/pip install -r backend/requirements.txt"
  echo "virtualenv ready"
fi

# ---- 1. database ------------------------------------------------------
step 1 "Applying migrations"
if [ "$FRESH" = "1" ]; then
  ./scripts/db.sh reset || die "database reset"
else
  ./scripts/db.sh migrate || die "migrations (run ./scripts/db.sh status to see where it stopped)"
fi

# ---- 2. verify the schema really is current ---------------------------
step 2 "Verifying schema"
PENDING="$(./scripts/db.sh status 2>/dev/null | grep -c PENDING || true)"
[ "${PENDING:-0}" = "0" ] || die "$PENDING migration(s) still pending. See ./scripts/db.sh status"
./scripts/db.sh psql -tAc "SELECT 'integrity: '||bool_and(passed) FROM ledger.verify_integrity();" \
  || die "ledger integrity check"

# ---- 3. demo data -----------------------------------------------------
step 3 "Seeding demo data (${DAYS} sessions)"
.venv/bin/python scripts/seed.py --days "$DAYS" --reset || die "seeding"

# ---- 4. run -----------------------------------------------------------
step 4 "Starting the API"
./scripts/api.sh restart || die "starting the API"

ACCOUNTS="$(./scripts/db.sh psql -tAc \
  "SELECT string_agg(email, ', ' ORDER BY user_id) FROM identity.app_user WHERE role='trader';" 2>/dev/null)"

# api.sh honours APEX_HOST/APEX_PORT, so this line must too -- it printed
# a hardcoded :8000 while the server was listening on something else.
printf '\n\033[32mReady.\033[0m  Open http://%s:%s\n\n' \
  "${APEX_HOST:-127.0.0.1}" "${APEX_PORT:-8000}"
printf '  Sign in with any of: %s\n' "$ACCOUNTS"
printf '  Password: Apex@2026\n\n'
