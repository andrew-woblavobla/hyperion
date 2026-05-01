#!/usr/bin/env bash
# bench/h2_falcon_compare.sh — 2.9-B harness. Hyperion vs Falcon head-to-head
# on the h2 path (apples-to-apples; Puma 8 has no native h2). Three rackups:
#
#   * hello.ru            — 2-header response (HPACK encode <1% of CPU)
#   * h2_post.ru          — POST body with HPACK + frame ser/de
#   * h2_rails_shape.ru   — 25-header response (the shape where 2.5-B's
#                           native HPACK shows +18% over the Ruby fallback)
#
# Drives each rackup × {hyperion, falcon} 3 times with h2load -c 1 -m 100
# -n 5000, captures rps + max-latency, takes median.
#
# Hyperion: -t 64 -w 1 --h2-max-total-streams unbounded, default-on Rust HPACK
#           (HYPERION_H2_NATIVE_HPACK unset = ON since 2.5-B).
# Falcon:   --hybrid -n 1 --forks 1 --threads 5 (1 process, 5 threads — the
#           closest single-process apples-to-apples to Hyperion's -w 1 -t 64
#           fiber pool given Falcon's CLI doesn't expose a "fiber pool size"
#           knob).
#
# Requires:
#   * h2load on PATH (apt install nghttp2-client)
#   * /tmp/cert.pem + /tmp/key.pem (regenerate with openssl req -x509 -newkey
#     rsa:2048 -keyout /tmp/key.pem -out /tmp/cert.pem -days 1 -nodes
#     -subj /CN=localhost if missing; the certs don't survive reboot on the
#     bench host)
#   * ~/hyperion checked out + bundled (Hyperion gem + Rust ext built)
#   * ~/bench-falcon checked out + bundled (rack 3.x + falcon ~> 0.55)
#
# Usage (from openclaw-vm):
#   ~/hyperion/bench/h2_falcon_compare.sh
#
# Output: per-rackup per-server table of run1/run2/run3/median + max-latency,
# then a final verdict line per rackup.

set -uo pipefail

export PATH="$HOME/.asdf/bin:$HOME/.asdf/shims:$PATH"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

PORT=${PORT:-9602}
HOST=${HOST:-127.0.0.1}
C=${C:-1}
M=${M:-100}
N=${N:-5000}
RUNS=${RUNS:-3}
TLS_CERT=${TLS_CERT:-/tmp/cert.pem}
TLS_KEY=${TLS_KEY:-/tmp/key.pem}
THREADS=${THREADS:-64}
WORKERS=${WORKERS:-1}
STREAMS=${STREAMS:-unbounded}

HYPERION_DIR=${HYPERION_DIR:-$HOME/hyperion}
FALCON_DIR=${FALCON_DIR:-$HOME/bench-falcon}

if ! command -v h2load >/dev/null 2>&1; then
  echo "[2.9-B] h2load not found on PATH — install nghttp2-client" >&2
  exit 2
fi

if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "[2.9-B] TLS cert/key missing at $TLS_CERT / $TLS_KEY — regenerating" >&2
  openssl req -x509 -newkey rsa:2048 -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -days 1 -nodes -subj /CN=localhost >/dev/null 2>&1 || {
    echo "[2.9-B] cert regen failed" >&2
    exit 2
  }
fi

server_pid=""
stop_server() {
  if [ -n "$server_pid" ]; then
    # Falcon's hybrid container forks 1 child + spawns N threads. The
    # parent ($server_pid) holds the listener; SIGTERM it first, then
    # mop up any straggler with -9.
    kill -TERM "$server_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
  # Belt-and-braces: sweep both server families on this port.
  pkill -KILL -f "bin/hyperion .*-p $PORT" 2>/dev/null || true
  pkill -KILL -f "falcon serve.*$PORT" 2>/dev/null || true
  pkill -KILL -f "falcon serve.*localhost:$PORT" 2>/dev/null || true
  # Wait for the kernel to release the listener socket. Falcon's
  # async-container child can outlive the parent for ~2 s — without
  # this loop the next bind() races EADDRINUSE.
  local waited=0
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT$"; do
    sleep 0.5
    waited=$((waited + 1))
    if [ $waited -ge 20 ]; then
      echo "[stop_server] port $PORT still busy after 10 s — sweeping by lsof" >&2
      lsof -i ":$PORT" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | xargs -r kill -KILL 2>/dev/null || true
      sleep 1
      break
    fi
  done
}
trap 'stop_server' EXIT INT TERM

start_hyperion() {
  local rackup="$1"
  local logfile="$2"
  cd "$HYPERION_DIR"
  bundle exec bin/hyperion \
    --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" \
    -t "$THREADS" -w "$WORKERS" \
    --h2-max-total-streams "$STREAMS" \
    -p "$PORT" "$rackup" \
    >"$logfile" 2>&1 &
  server_pid=$!
  sleep 5
}

start_falcon() {
  local rackup="$1"
  local logfile="$2"
  cd "$FALCON_DIR"
  bundle exec falcon serve \
    --bind "https://localhost:$PORT" \
    --hybrid -n 1 --forks 1 --threads 5 \
    -c "$rackup" \
    >"$logfile" 2>&1 &
  server_pid=$!
  sleep 5
}

# Run h2load once. Echoes "rps maxlat_ms succeeded" on success.
# Saves the full h2load output to $H2LOAD_LOG for debugging.
run_h2load() {
  local url="$1"
  local extra="${2:-}"
  local label="${3:-run}"
  local out
  if [ -n "$extra" ]; then
    out=$(h2load -c "$C" -m "$M" -n "$N" $extra "$url" 2>&1) || true
  else
    out=$(h2load -c "$C" -m "$M" -n "$N" "$url" 2>&1) || true
  fi
  if [ -n "${H2LOAD_LOG:-}" ]; then
    {
      echo "----- $label -----"
      echo "$out"
    } >> "$H2LOAD_LOG"
  fi
  local rps
  rps=$(echo "$out" | awk '/finished in/ { for (i=1; i<=NF; i++) if ($i == "req/s,") print $(i-1) }' | head -1)
  local maxlat
  maxlat=$(echo "$out" | awk '/time for request:/ { print $4 }' | head -1)
  local succ
  succ=$(echo "$out" | awk '/requests:.*succeeded/ { for (i=1; i<=NF; i++) if ($i == "succeeded,") print $(i-1) }' | head -1)
  echo "${rps:-NA} ${maxlat:-NA} ${succ:-NA}"
}

median3() {
  printf '%s\n' "$@" | sort -g | awk 'NR==2'
}

bench_rackup_server() {
  local server="$1"
  local rackup_path="$2"
  local label="$3"
  local extra_h2load="${4:-}"
  local rackup_basename
  rackup_basename=$(basename "$rackup_path")

  echo "=== $label / server=$server / rackup=$rackup_basename ==="
  stop_server

  local server_log="/tmp/h2-falcon-cmp-${server}-${label}.log"
  case "$server" in
    hyperion) start_hyperion "$rackup_path" "$server_log" ;;
    falcon)   start_falcon   "$rackup_path" "$server_log" ;;
    *) echo "unknown server $server"; exit 2 ;;
  esac

  if ! curl -sk --http2 "https://$HOST:$PORT/" -o /dev/null --max-time 5; then
    echo "[$server/$label] server failed to come up — server log follows:"
    tail -40 "$server_log"
    stop_server
    return 1
  fi

  local rps_list=()
  local maxlat_list=()
  local succ_list=()
  for i in $(seq 1 "$RUNS"); do
    local result rps maxlat succ
    result=$(run_h2load "https://$HOST:$PORT/" "$extra_h2load" "$server/$label/run=$i")
    rps=$(echo "$result" | awk '{print $1}')
    maxlat=$(echo "$result" | awk '{print $2}')
    succ=$(echo "$result" | awk '{print $3}')
    rps_list+=("$rps")
    maxlat_list+=("$maxlat")
    succ_list+=("$succ")
    echo "[$server/$label] run=$i rps=$rps max_lat=$maxlat succeeded=$succ/$N"
    # h2 servers sometimes need a moment between fresh connections to release
    # per-conn fiber state; 2 s avoids the run-2 0-rps misfire seen on Hyperion
    # h2_post / rails_shape in the first script revision.
    sleep 2
    # Check server is still alive between runs.
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "[$server/$label] server died after run=$i — log tail:"
      tail -20 "$server_log"
      break
    fi
  done
  stop_server

  local rps_med maxlat_med
  rps_med=$(median3 "${rps_list[@]}")
  maxlat_med=$(median3 "${maxlat_list[@]/ms/}")
  echo "[$server/$label] MEDIAN rps=$rps_med max_lat=$maxlat_med (runs: ${rps_list[*]})"
}

# rackup paths are relative to the server's cwd (HYPERION_DIR or FALCON_DIR).
# Both dirs hold identical copies of the rackups, so we use bench/<name> for
# Hyperion and <name> for Falcon (bench-falcon flat layout).

run_for_rackup() {
  local label="$1"
  local extra_h2load="${2:-}"
  local hyp_path="$3"
  local fal_path="$4"

  bench_rackup_server hyperion "$hyp_path" "$label" "$extra_h2load"
  bench_rackup_server falcon   "$fal_path" "$label" "$extra_h2load"
}

# ---- Generate POST data file (h2_post needs a body for h2load -d) ----
POST_DATA=/tmp/h2_falcon_post_data.txt
if [ ! -f "$POST_DATA" ]; then
  printf '{"hello":"world","run":"2.9-B"}' > "$POST_DATA"
fi

# ---- Run all combos ----
: "${H2LOAD_LOG:=/tmp/h2_falcon_compare_h2load.log}"
: > "$H2LOAD_LOG"
export H2LOAD_LOG

echo "============================================================"
echo "2.9-B Falcon h2 head-to-head bench"
echo "h2load -c $C -m $M -n $N, $RUNS runs each, median taken"
echo "Hyperion: $HYPERION_DIR  -t $THREADS -w $WORKERS streams=$STREAMS"
echo "Falcon:   $FALCON_DIR    --hybrid -n 1 --forks 1 --threads 5"
echo "TLS cert: $TLS_CERT"
echo "Per-run h2load output: $H2LOAD_LOG"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================================"

run_for_rackup "hello"       ""                          "bench/hello.ru"           "hello.ru"
run_for_rackup "h2_post"     "-d $POST_DATA"             "bench/h2_post.ru"         "h2_post.ru"
run_for_rackup "rails_shape" ""                          "bench/h2_rails_shape.ru"  "h2_rails_shape.ru"

echo "============================================================"
echo "2.9-B bench complete — see lines starting with 'MEDIAN' for the table."
echo "============================================================"
