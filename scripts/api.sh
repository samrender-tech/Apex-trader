#!/usr/bin/env bash
# Start/stop/restart the API. Uses a PID file so stopping never relies on
# pattern-matching process lists (which can match the caller itself).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/.api.pid"
LOG="${APEX_API_LOG:-/tmp/apex-api.log}"
HOST="${APEX_HOST:-127.0.0.1}"; PORT="${APEX_PORT:-8000}"

# The contract version in the source on disk, and the one the live server
# reports. If they differ, the running process is not this code.
disk_contract() { grep -oE '^API_CONTRACT = [0-9]+' "$ROOT/backend/app/main.py" | grep -oE '[0-9]+'; }

# Is ANYTHING answering on the port? This has to be asked separately from
# "what contract does it report", because the first version of this code
# conflated them: live_contract() returned an empty string both when
# nothing was listening AND when an old server was listening without the
# field -- which is exactly the server we most need to replace. The
# replacement branch was gated on that string being non-empty, so against
# a genuinely old server it did nothing, uvicorn then failed to bind the
# busy port, and the only evidence was a warning telling the user to run
# lsof by hand.
live_responding() { curl -sf -m 3 "http://$HOST:$PORT/api/health" >/dev/null 2>&1; }

live_contract() {
  curl -sf -m 3 "http://$HOST:$PORT/api/health" 2>/dev/null \
    | sed -n 's/.*"api_contract":[ ]*\([0-9]*\).*/\1/p'
}

# Free the port, whoever holds it. `stop` only knows about a process this
# script started; an old server from another checkout, another shell or a
# previous boot is not in our PID file and has to be evicted by port.
free_port() {
  stop >/dev/null 2>&1
  live_responding || return 0
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti:"$PORT" 2>/dev/null | xargs kill 2>/dev/null
    for _ in $(seq 1 10); do live_responding || return 0; sleep 0.5; done
    lsof -ti:"$PORT" 2>/dev/null | xargs kill -9 2>/dev/null
    for _ in $(seq 1 10); do live_responding || return 0; sleep 0.5; done
  fi
  live_responding && return 1
  return 0
}

start() {
  # "Already running" is only good news if what is running is THIS code.
  #
  # The old check was `kill -0 $PID` on a PID file, which is true for any
  # process that happens to hold that number after a reboot, and says
  # nothing about which version is serving. The result was a new frontend
  # unpacked over a server left over from an earlier session: unregistered
  # /api routes fall through to the static mount, so search and history
  # answered "Not Found", the markets page came up empty, the watchlist
  # said "Method Not Allowed" and the currency dropdowns were blank --
  # six symptoms, one stale process, and `api.sh start` cheerfully
  # reporting "already running" the whole time.
  WANT="$(disk_contract)"

  if live_responding; then
    HAVE="$(live_contract)"
    if [ -n "$HAVE" ] && [ "$HAVE" = "$WANT" ]; then
      echo "already running and current (contract $HAVE) on http://$HOST:$PORT"; return 0
    fi
    echo "port $PORT is held by a server reporting contract ${HAVE:-none (pre-versioning build)},"
    echo "but this source tree is $WANT. Replacing it..."
    if ! free_port; then
      echo "could not free port $PORT -- something is holding it that this script" >&2
      echo "cannot stop. Identify and kill it, then try again:" >&2
      echo "    lsof -i:$PORT" >&2
      return 1
    fi
    echo "port $PORT is clear"
  elif [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    # A PID file pointing at something that does not answer /api/health.
    # Either still booting or not ours at all; do not trust it.
    echo "stale pid file (pid $(cat "$PIDFILE") is not serving); clearing"
    stop
  fi
  # Fail on the real cause rather than on a missing binary. The archive
  # ships no .venv, so a fresh extract has nothing to run until setup.sh
  # has built one.
  if [ ! -x "$ROOT/.venv/bin/uvicorn" ]; then
    echo "No Python environment in $ROOT/.venv" >&2
    echo "The archive does not ship one. Build it with:" >&2
    echo "    ./scripts/setup.sh" >&2
    echo "or by hand:" >&2
    echo "    python3 -m venv .venv" >&2
    echo "    .venv/bin/pip install -r backend/requirements.txt" >&2
    return 1
  fi

  cd "$ROOT/backend"
  nohup "$ROOT/.venv/bin/uvicorn" app.main:app \
      --host "$HOST" --port "$PORT" --log-level warning > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 30); do
    if curl -sf "http://$HOST:$PORT/api/health" >/dev/null 2>&1; then
      GOT="$(live_contract)"
      if [ -n "$WANT" ] && [ "$GOT" != "$WANT" ]; then
        echo "ERROR: the server answering on port $PORT reports contract ${GOT:-none}," >&2
        echo "       but this source tree is $WANT -- so our process did not get the" >&2
        echo "       port and something else still has it. Last lines of our log:" >&2
        tail -5 "$LOG" >&2
        echo "       Identify the holder with:  lsof -i:$PORT" >&2
        stop >/dev/null 2>&1
        return 1
      fi
      echo "started (pid $(cat "$PIDFILE")) on http://$HOST:$PORT  [contract $GOT]"
      return 0
    fi
    sleep 0.5
  done
  echo "failed to become healthy; last log lines:" >&2; tail -20 "$LOG" >&2; return 1
}

stop() {
  if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE")"
    kill "$PID" 2>/dev/null && echo "stopped (pid $PID)"
    for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$PID" 2>/dev/null
    rm -f "$PIDFILE"
  else
    echo "not running"
  fi
}

case "${1:-start}" in
  start) start;;
  stop) stop;;
  # restart means RESTART. start() deliberately leaves a server alone when
  # its contract already matches, which is right for `start` and wrong
  # here: during development the API surface is unchanged far more often
  # than the code behind it, so "already running and current" would skip
  # the very reload that was asked for. Free the port unconditionally --
  # including a server this script did not launch, whose PID file we may
  # no longer have.
  restart) free_port || { echo "could not free port $PORT" >&2; exit 1; }
           sleep 1; start;;
  status) [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null \
            && echo "running (pid $(cat "$PIDFILE"))" || echo "not running";;
  logs) tail -n "${2:-40}" "$LOG";;
  *) echo "usage: api.sh {start|stop|restart|status|logs}" >&2; exit 2;;
esac
