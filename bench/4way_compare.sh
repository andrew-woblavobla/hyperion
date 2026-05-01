#!/usr/bin/env bash
# bench/4way_compare.sh — 2.10-A harness, extended in 2.12-B for a
# Hyperion handle_static variant.
#
# Drives a single rackup (default bench/hello.ru) against all four
# major Ruby web servers in turn on the same port, capturing wrk
# requests/sec + p99 latency for three back-to-back 20 s runs each.
#
#   * hyperion              — bin/hyperion (this repo, generic Rack rackup)
#   * hyperion_handle_static — bin/hyperion against an alternate rackup
#                             (bench/hello_static.ru / static_handle_static.ru)
#                             that calls `Hyperion::Server.handle_static`
#                             at boot so the request hot path is the
#                             2.10-D direct route + 2.10-F C-ext fast path
#                             (only applicable to hello + small static).
#   * puma                  — 8.0.x       (no async-Ruby, threads only)
#   * falcon                — 0.55+       (async-Ruby fiber pool)
#   * agoo                  — 2.15.x      (pure-C HTTP core, see bench/agoo_boot.rb)
#
# Single shell script on purpose: 2.10-B (the actual bench run) wants
# one command to drive the whole suite, not four. To bench just a
# subset, pass server names after the rackup:
#
#   bench/4way_compare.sh bench/hello.ru hyperion agoo
#
# 2.12-B — to bench the handle_static variant on a row, pass
# `hyperion_handle_static` and point HYPERION_STATIC_RACKUP at the
# alternate rackup:
#
#   HYPERION_STATIC_RACKUP=bench/hello_static.ru \
#     bench/4way_compare.sh bench/hello.ru \
#       hyperion hyperion_handle_static puma falcon agoo
#
# When HYPERION_STATIC_RACKUP is unset the handle_static variant
# falls back to the same RACKUP as the generic variant (in which
# case it is a no-op duplicate; harmless but wasteful).
#
# Defaults to all four servers (no handle_static variant) if no
# subset is given — preserves the 2.10-B baseline harness shape.
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
# Output: per-server "wrk run=N rps=… p99=…" + "perfer run=N rps=… p99=…"
# lines + a per-server median-of-3 summary at the end.
#
# 2.10-B: also runs Agoo's `perfer` (https://github.com/ohler55/perfer) on
# the same workload so we have a head-to-head against agoo's headline
# numbers (which are published with perfer, not wrk). Perfer must be
# pre-built at $PERFER_BIN (default /tmp/perfer/bin/perfer). Build it via
#   git clone https://github.com/ohler55/perfer.git /tmp/perfer && (cd /tmp/perfer && make)
# Perfer's recv code uses case-sensitive strstr for "Content-Length:" —
# this hangs against RFC 9110 lowercase headers (Hyperion). Patch drop.c
# to use strcasestr (and add `#define _GNU_SOURCE` + rebuild) before use.
# Set SKIP_PERFER=1 to disable.

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
# Path the smoke check + wrk hit. Defaults to "/" but rackups like
# bench/static.ru need a real file path (e.g. /hyperion_bench_1k.bin).
URL_PATH="${URL_PATH:-/}"
WRK_TIMEOUT="${WRK_TIMEOUT:-}"
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
    if curl -sS -o /dev/null --max-time 1 "http://$HOST:$PORT$URL_PATH" 2>/dev/null; then
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
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "http://$HOST:$PORT$URL_PATH" || echo "000")
  echo "[$label] smoke GET $URL_PATH -> HTTP $code" | tee -a "$LOG"
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
  local wrk_extra=()
  if [ -n "$WRK_TIMEOUT" ]; then
    wrk_extra+=(--timeout "$WRK_TIMEOUT")
  fi
  for run in $(seq 1 "$RUNS"); do
    local out rps p99
    out=$(wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$DURATION" --latency \
      "${wrk_extra[@]}" \
      "http://$HOST:$PORT$URL_PATH" 2>&1)
    rps=$(echo "$out" | awk '/Requests\/sec:/ { print $2 }')
    p99=$(echo "$out" | awk '/^ *99%/ { print $2 }')
    rps_list+=("${rps:-NA}")
    p99_list+=("${p99:-NA}")
    echo "[$label] wrk run=$run rps=$rps p99=$p99" | tee -a "$LOG"
    sleep 2
  done

  local rps_med p99_med
  rps_med=$(median "${rps_list[@]}")
  p99_med=$(median "${p99_list[@]}")
  echo "[$label] WRK MEDIAN rps=$rps_med p99=$p99_med (runs: ${rps_list[*]})" | tee -a "$LOG"
  echo "$label: wrk_rps_med=$rps_med wrk_p99_med=$p99_med" >> "/tmp/4way-summary.log"

  # 2.10-B: also run perfer (Agoo's bench tool) for apples-to-apples vs Agoo's
  # published numbers. Perfer is at $PERFER_BIN (default /tmp/perfer/bin/perfer).
  # If unavailable or it times out, we record "NA" and continue — the wrk
  # numbers above are the headline result either way.
  local perfer_bin="${PERFER_BIN:-/tmp/perfer/bin/perfer}"
  if [ -x "$perfer_bin" ] && [ "${SKIP_PERFER:-0}" != "1" ]; then
    local prps_list=()
    local pp99_list=()
    local pdur="${DURATION%s}"
    for run in $(seq 1 "$RUNS"); do
      local pout prps pp99
      # Perfer can deadlock during warmup against servers with small thread
      # pools (its connect+send-all then recv-all model assumes the server
      # drains quickly). Wrap with a hard timeout and treat as NA on failure.
      pout=$(timeout 60 "$perfer_bin" \
        -t "$WRK_THREADS" -c "$WRK_CONNS" -k -d "$pdur" \
        -l 50,90,99 "http://$HOST:$PORT$URL_PATH" 2>&1)
      if echo "$pout" | grep -q "timed out"; then
        prps="NA"; pp99="NA"
      else
        prps=$(echo "$pout" | awk '/Throughput:/ { print $2 }')
        pp99=$(echo "$pout" | awk '/99\.00%:/ { print $2" "$3 }' | head -1)
      fi
      prps_list+=("${prps:-NA}")
      pp99_list+=("${pp99:-NA}")
      echo "[$label] perfer run=$run rps=$prps p99=$pp99" | tee -a "$LOG"
      sleep 2
    done
    local prps_med pp99_med
    # NA-aware median: if any run is NA, set median to NA.
    if printf '%s\n' "${prps_list[@]}" | grep -q "^NA$"; then
      prps_med="NA"; pp99_med="NA"
    else
      prps_med=$(median "${prps_list[@]}")
      pp99_med=$(median "${pp99_list[@]}")
    fi
    echo "[$label] PERFER MEDIAN rps=$prps_med p99=$pp99_med (runs: ${prps_list[*]})" | tee -a "$LOG"
    echo "$label: perfer_rps_med=$prps_med perfer_p99_med=$pp99_med" >> "/tmp/4way-summary.log"
  fi

  stop_port
}

: > /tmp/4way-summary.log

for srv in "${SUBSET[@]}"; do
  case "$srv" in
    hyperion)
      # HYPERION_EXTRA injects extra flags before -t (e.g. "--async-io" for row 5)
      # shellcheck disable=SC2206
      hyp_extra=(${HYPERION_EXTRA:-})
      run_server hyperion bundle exec hyperion "${hyp_extra[@]}" \
        -t "${HYPERION_THREADS:-5}" -w 1 -p "$PORT" "$RACKUP"
      ;;
    hyperion_handle_static)
      # 2.12-B — Hyperion variant booted against an alternate rackup
      # that pre-registers a handle_static route at boot. The hot path
      # is the direct-dispatch + C-ext fast-path response writer; no
      # Rack adapter, no Rack-env build. Falls back to the generic
      # rackup if HYPERION_STATIC_RACKUP is unset (same data as the
      # `hyperion` row above; lets operators omit the override
      # without the harness erroring).
      hs_rackup="${HYPERION_STATIC_RACKUP:-$RACKUP}"
      if [ ! -f "$hs_rackup" ]; then
        echo "[hyperion_handle_static] missing rackup '$hs_rackup' — skipping" | tee -a "$LOG"
        echo "hyperion_handle_static: SKIP (missing rackup $hs_rackup)" >> "/tmp/4way-summary.log"
        continue
      fi
      # shellcheck disable=SC2206
      hs_extra=(${HYPERION_EXTRA:-})
      run_server hyperion_handle_static bundle exec hyperion "${hs_extra[@]}" \
        -t "${HYPERION_THREADS:-5}" -w 1 -p "$PORT" "$hs_rackup"
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
