#!/usr/bin/env bash
# =====================================================================
# Concurrency proof.
#
# Many independent sessions hammer the SAME instrument at once. The
# things that must hold afterwards:
#   1. no resting order is filled beyond its quantity (no double-fill)
#   2. the ledger still balances to the cent
#   3. no account is overdrawn
#   4. total shares bought == total shares sold
#
# This is the test that justifies the transaction-scoped advisory lock
# in engine.submit_order. Without it, two concurrent buyers can both
# read the same resting sell order and overfill it.
# =====================================================================
set -uo pipefail
export PGPASSWORD="${PGPASSWORD:-apex_dev_pw}"
PGHOST="${PGHOST:-127.0.0.1}"; PGUSER="${PGUSER:-apex}"; PGDATABASE="${PGDATABASE:-apex_trader}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
pg() { psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" "$@"; }

WORKERS="${WORKERS:-12}"
ORDERS_EACH="${ORDERS_EACH:-25}"

echo "=== setup: fresh fixture, one large resting sell order ==="
pg -q -f db/test/_fixture.sql

read -r IID BOB CAROL ALICE DAVE <<<"$(pg -tAF' ' -c "
  SELECT (SELECT instrument_id FROM reference.instrument WHERE symbol='AAPL'),
         (SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='bob@apex.io'),
         (SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='carol@apex.io'),
         (SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='alice@apex.io'),
         (SELECT a.account_id FROM trading.account a JOIN identity.app_user u USING(user_id) WHERE u.email='dave@apex.io');")"

# Widen this account's risk limits for the duration of the test. We are
# deliberately testing the MATCHING ENGINE's concurrency safety here, and
# with default limits the order-rate throttle (60/min) and the 40%-of-NAV
# concentration cap reject most of the flow before it ever reaches the
# book -- which is correct behaviour, but it is not what this test is for.
pg -q -c "UPDATE risk.risk_limit SET max_orders_per_minute = 100000,
                                     max_position_pct_nav  = 100,
                                     max_daily_loss        = 100000000,
                                     max_open_orders       = 100000;"

# One resting sell of exactly 3000 shares. Buyers below will collectively
# try to buy far more than that, so the engine MUST cap fills at 3000.
pg -q -tAc "SELECT order_id FROM engine.submit_order($BOB,$IID,'sell','limit',3000,182.00,NULL,'gtc');" >/dev/null
RESTING=$(pg -tAc "SELECT order_id FROM trading.trade_order WHERE account_id=$BOB AND status='working' ORDER BY order_id DESC LIMIT 1")
echo "  resting sell order #$RESTING for 3000 @ 182.00"
echo "  launching $WORKERS concurrent buyers x $ORDERS_EACH orders each"
echo "  (total demand $((WORKERS * ORDERS_EACH * 10)) shares against 3000 available)"

START=$(date +%s)
for w in $(seq 1 "$WORKERS"); do
  (
    for _ in $(seq 1 "$ORDERS_EACH"); do
      # Round-robin across three buyer accounts, as a real venue would see.
      case $((RANDOM % 3)) in
        0) BUYER=$ALICE ;;
        1) BUYER=$CAROL ;;
        *) BUYER=$DAVE  ;;
      esac
      psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -q -tAc \
        "SELECT order_id FROM engine.submit_order($BUYER,$IID,'buy','limit',10,182.00,NULL,'ioc');" \
        >/dev/null 2>&1
    done
  ) &
done
wait
END=$(date +%s)
echo "  completed in $((END-START))s"
echo ""

echo "=== invariant checks ==="
pg -x <<SQL
SELECT
  (SELECT quantity FROM trading.trade_order WHERE order_id=$RESTING)   AS resting_quantity,
  (SELECT filled_qty FROM trading.trade_order WHERE order_id=$RESTING) AS resting_filled,
  (SELECT status::text FROM trading.trade_order WHERE order_id=$RESTING) AS resting_status,
  (SELECT count(*) FROM trading.execution)                             AS total_fills,
  (SELECT COALESCE(sum(quantity),0) FROM trading.execution)            AS total_shares_traded,
  (SELECT count(*) FROM trading.trade_order WHERE filled_qty > quantity) AS overfilled_orders,
  (SELECT count(*) FROM trading.trade_order WHERE status='rejected')   AS rejected_orders,
  (SELECT COALESCE(sum(amount),0) FROM ledger.posting
    WHERE asset_class='security')                                      AS shares_created_or_destroyed,
  (SELECT COALESCE(sum(amount),0) FROM ledger.posting
    WHERE asset_class='cash')                                          AS cash_created_or_destroyed;
SQL

pg -c "SELECT * FROM ledger.verify_integrity();"
pg -c "SELECT category, check_name, status FROM ops.health_check() WHERE status <> 'PASS';"

FAIL=0
OVER=$(pg -tAc "SELECT count(*) FROM trading.trade_order WHERE filled_qty > quantity")
FILLED=$(pg -tAc "SELECT filled_qty FROM trading.trade_order WHERE order_id=$RESTING")
BAL=$(pg -tAc "SELECT count(*) FROM ledger.verify_integrity() WHERE NOT passed")
CONSERVED=$(pg -tAc "SELECT count(*) FROM (SELECT instrument_id, sum(amount) s FROM ledger.posting WHERE asset_class='security' GROUP BY 1 HAVING sum(amount) <> 0) x")

[ "$OVER" = "0" ]            || { echo "FAIL: $OVER order(s) overfilled"; FAIL=1; }
[ "${FILLED%%.*}" -le 3000 ] || { echo "FAIL: resting order filled $FILLED > 3000"; FAIL=1; }
[ "$BAL" = "0" ]             || { echo "FAIL: ledger integrity broken"; FAIL=1; }
[ "$CONSERVED" = "0" ]       || { echo "FAIL: shares not conserved"; FAIL=1; }

echo ""
if [ "$FAIL" = "0" ]; then
  printf '\033[32mCONCURRENCY TEST PASSED\033[0m -- %s sessions, no double-fill, ledger exact\n' "$WORKERS"
else
  printf '\033[31mCONCURRENCY TEST FAILED\033[0m\n'; exit 1
fi
