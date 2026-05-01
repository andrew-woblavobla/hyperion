#!/usr/bin/env bash
# bench/4way_compare.sh — 2.10-A harness.
#
# Drives a single rackup (default bench/hello.ru) against all four
# major Ruby web servers in turn on the same port, capturing wrk
# requests/sec + p99 latency for three back-to-back 20 s runs each.
#
#   * Hyperion — bin/hyperion (this repo)
#   * Puma     — 8.0.x       (no async-Ruby, threads only)
#   * Falcon   — 0.55+       (async-Ruby fiber pool)
#   * Agoo     — 2.15.x      (pure-C HTTP core, see bench/agoo_boot.rb)
#
# Single shell script on purpose: 2.10-B (the actual bench run) wants
# one command to drive the whole suite, not four. To bench just a
# subset, pass server names after the rackup:
#
#   bench/4way_compare.sh bench/hello.ru hyperion agoo
#
# Defaults to all four if no subset is given.
#
# Concurrency budget per server is matched: -t 5 -w 1 (5 threads /
# fibers, 1 worker / process). Each server gets a fresh PORT bind on
# 9810 — the previous server is SIGKILL'd and given 5 s for the
# kernel to release the listener before the next bind.
#
# Boot recipes (also documented in CHANGELOG 2.10-A):
#
#   Hyperion: bundle exec hyperion -t 5 -w 1 -p 9810 hello.ru
#   Puma:     bundle exec puma -t 5:5 -w 1 -b tcp://127.0.0.1:9810 hello.ru
#   Falcon:   bundle exec falcon serve --bind http://localhost:9810 \
#               --hybrid -n 1 --forks 1 --threads 5 --config hello.ru
#   Agoo:     bundle exec ruby bench/agoo_boot.rb hello.ru 9810 5
#
# Output: per-server "run=N rps=… p99=…" lines + a per-server
# median-of-3 summary at the end.

set -u

export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$REPO_ROOT/bench/Gemfile.4way}"

RACKUP="${1:-bench/hello.ru}"
shift || true
SUBSET=("$@")
if [ ${#SUBSET[@]} -eq 0 ]; then
  SUBSET=(hyperion puma falcon agoo)
fi

PORT="${PORT:-9810}"
HOST="${HOST:-127.0.0.1}"
DURATION="${DURATION:-20s}"
WRK_THREADS="${WRK_THREADS:-4}"
WRK_CONNS="${WRK_CONNS:-100}"
RUNS="${RUNS:-3}"
LOG="/tmp/4way-$$.log"

echo "============================================================"
echo "2.10-A 4-way bench harness"
echo "Rackup:   $RACKUP"
echo "Port:     $PORT"
echo "wrk:      -t$WRK_THREADS -c$WRK_CONNS -d$DURATION   ($RUNS runs/server)"
echo "Servers:  ${SUBSET[*]}"
echo "Gemfile:  $BUNDLE_GEMFILE"
echo "Logfile:  $LOG"
echo "Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"

PID=""

stop_port() {
  if [ -n "$PID" ]; then
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
  pkill -KILL -f "[ :=]$PORT( |$)" 2>/dev/null || true
  # Wait for the kernel to release the listener.
  local waited=0
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT$"; do
    sleep 0.5
    waited=$((waited + 1))
    if [ $waited -ge 20 ]; then
      lsof -i ":$PORT" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u \
        | xargs -r kill -KILL 2>/dev/null || true
      sleep 1
      break
    fi
  done
}

trap 'stop_port' EXIT INT TERM

wait_for_bind() {
  local label="$1"
  for i in $(seq 1 7); do
    sleep 1
    if curl -sS -o /dev/null --max-time 1 "http://$HOST:$PORT/" 2>/dev/null; then
      echo "[$label] bound after ${i}s" | tee -a "$LOG"
      return 0
    fi
  done
  echo "[$label] FAILED to bind within 7s" | tee -a "$LOG"
  return 1
}

# extract median of N space-separated numbers
median() {
  printf '%s\n' "$@" | sort -g | awk -v n=$# 'NR == int((n+1)/2) { print; exit }'
}

run_server() {
  local label="$1"
  shift
  local cmd=("$@")

  echo | tee -a "$LOG"
  echo "=== $label ===" | tee -a "$LOG"
  stop_port

  local server_log="/tmp/4way-${label}.log"
  : > "$server_log"
  echo "[$label] cmd: ${cmd[*]}" | tee -a "$LOG"
  "${cmd[@]}" > "$server_log" 2>&1 &
  PID=$!

  if ! wait_for_bind "$label"; then
    echo "[$label] BOOT-FAILURE — server log tail:" | tee -a "$LOG"
    tail -20 "$server_log" | tee -a "$LOG"
    stop_port
    echo "$label: BOOT-FAILURE" >> "/tmp/4way-summary.log"
    return 1
  fi

  # Smoke a single 200.
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "http://$HOST:$PORT/" || echo "000")
  echo "[$label] smoke GET / -> HTTP $code" | tee -a "$LOG"
  if [ "$code" != "200" ]; then
    echo "[$label] SMOKE-FAILURE (non-200)" | tee -a "$LOG"
    stop_port
    echo "$label: SMOKE-FAILURE (HTTP $code)" >> "/tmp/4way-summary.log"
    return 1
  fi

  # If the user passed --smoke-only via env, stop here.
  if [ "${SMOKE_ONLY:-0}" = "1" ]; then
    echo "[$label] SMOKE_ONLY=1 — skipping wrk" | tee -a "$LOG"
    stop_port
    echo "$label: SMOKE-OK" >> "/tmp/4way-summary.log"
    return 0
  fi

  if ! command -v wrk >/dev/null 2>&1; then
    echo "[$label] wrk not on PATH — skipping bench (smoke only)" | tee -a "$LOG"
    stop_port
    echo "$label: SMOKE-OK (no wrk)" >> "/tmp/4way-summary.log"
    return 0
  fi

  local rps_list=()
  local p99_list=()
  for run in $(seq 1 "$RUNS"); do
    local out rps p99
    out=$(wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$DURATION" --latency \
      "http://$HOST:$PORT/" 2>&1)
    rps=$(echo "$out" | awk '/Requests\/sec:/ { print $2 }')
    p99=$(echo "$out" | awk '/^ *99%/ { print $2 }')
    rps_list+=("${rps:-NA}")
    p99_list+=("${p99:-NA}")
    echo "[$label] run=$run rps=$rps p99=$p99" | tee -a "$LOG"
    sleep 2
  done

  local rps_med p99_med
  rps_med=$(median "${rps_list[@]}")
  p99_med=$(median "${p99_list[@]}")
  echo "[$label] MEDIAN rps=$rps_med p99=$p99_med (runs: ${rps_list[*]})" | tee -a "$LOG"
  echo "$label: rps_med=$rps_med p99_med=$p99_med" >> "/tmp/4way-summary.log"

  stop_port
}

: > /tmp/4way-summary.log

for srv in "${SUBSET[@]}"; do
  case "$srv" in
    hyperion)
      run_server hyperion bundle exec hyperion -t 5 -w 1 -p "$PORT" "$RACKUP"
      ;;
    puma)
      run_server puma bundle exec puma -t 5:5 -w 1 \
        -b "tcp://127.0.0.1:$PORT" "$RACKUP"
      ;;
    falcon)
      # Falcon serve takes the rackup via --config. The --threads flag is
      # documented as "hybrid only", so we explicitly select --hybrid and
      # pin -n 1 / --forks 1 / --threads 5 for the 5-thread, 1-process
      # apples-to-apples budget. (Verified against `falcon serve --help`
      # on the bench host before this commit landed.) --bind takes a URL.
      run_server falcon bundle exec falcon serve \
        --bind "http://localhost:$PORT" \
        --hybrid -n 1 --forks 1 --threads 5 \
        --config "$RACKUP"
      ;;
    agoo)
      run_server agoo bundle exec ruby "$REPO_ROOT/bench/agoo_boot.rb" \
        "$RACKUP" "$PORT" 5
      ;;
    *)
      echo "[harness] unknown server '$srv' — skipping" | tee -a "$LOG"
      ;;
  esac
done

echo
echo "============================================================"
echo "=== SUMMARY ==="
cat /tmp/4way-summary.log
echo "============================================================"
echo "Full log: $LOG"
echo "Per-server boot logs: /tmp/4way-<label>.log"
