#!/usr/bin/env bash
# 2.13-D / 2.14-D — ghz bench harness for Hyperion's gRPC streaming + unary paths.
#
# Boots Hyperion on a self-signed TLS cert (h2 over TLS via ALPN; no h2c
# upgrade path is wired yet), runs three trials each of:
#   1. Server-streaming: 50 concurrent streams, 100 replies per stream
#   2. Unary baseline:   50 concurrent, single-message responses
#
# Knobs (env-driven):
#   PORT, WORKERS, THREADS, DURATION, CONCURRENCY, TRIALS, GHZ
#   STREAM_COUNT — replies per server-stream RPC (default 100)
#   PAYLOAD_BYTES — bytes per EchoReply.payload (default 10)
#
# Output is one summary line per trial (rps + p50/p95/p99) and a median
# r/s + median tail per workload. Raw ghz JSON lives under $LOG_DIR.
# (ghz's `latencyDistribution` only emits up to p99 by default, so p999
# is intentionally omitted — operators who want tighter tail can pass
# `--cpus N --histogram` and parse `histogram[]` themselves.)
#
# Falcon-side comparison is OPTIONAL — Falcon doesn't speak Rack 3 trailers
# natively (`async-grpc` is Falcon's own gRPC server, not a Rack adapter).
# The 2.14-D ticket documents the comparison as best-effort; if async-grpc
# isn't reachable, the bench falls through to "Hyperion-only" output.
set -euo pipefail

# asdf is the canonical Ruby manager on the bench host; non-interactive
# SSH shells don't auto-source it, so source it explicitly when present.
[[ -f "$HOME/.asdf/asdf.sh" ]] && . "$HOME/.asdf/asdf.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-19292}"
WORKERS="${WORKERS:-1}"
THREADS="${THREADS:-0}"
DURATION="${DURATION:-15s}"
CONCURRENCY="${CONCURRENCY:-50}"
TRIALS="${TRIALS:-3}"
TLS_DIR="${TLS_DIR:-/tmp/hyperion-grpc-bench}"
LOG_DIR="${LOG_DIR:-/tmp/hyperion-grpc-bench-logs}"
GHZ="${GHZ:-/tmp/ghz}"
STREAM_COUNT="${STREAM_COUNT:-100}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-10}"
WARMUP_DURATION="${WARMUP_DURATION:-3s}"

mkdir -p "$TLS_DIR" "$LOG_DIR"

# Self-signed cert; ghz drives it with --skipTLS (skip cert verify).
if [[ ! -f "$TLS_DIR/cert.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$TLS_DIR/key.pem" \
    -out "$TLS_DIR/cert.pem" -sha256 -days 30 -nodes \
    -subj "/CN=localhost" >/dev/null 2>&1
fi

start_hyperion() {
  local label="$1"
  local logfile="$LOG_DIR/hyperion-$label.log"
  : >"$logfile"
  echo "  start: $label (workers=$WORKERS threads=$THREADS port=$PORT stream_count=$STREAM_COUNT)" >&2
  # setsid + disown so the daemon survives the parent shell exiting under
  # SSH (the 2.13-D harness used bare nohup which fights ssh's session
  # close).
  HYPERION_LOG_LEVEL=warn \
  GRPC_STREAM_COUNT="$STREAM_COUNT" \
  GRPC_PAYLOAD_BYTES="$PAYLOAD_BYTES" \
  setsid nohup bin/hyperion \
    -b 127.0.0.1 -p "$PORT" -w "$WORKERS" -t "$THREADS" \
    --tls-cert "$TLS_DIR/cert.pem" --tls-key "$TLS_DIR/key.pem" \
    --h2-max-total-streams unbounded \
    --no-log-requests \
    bench/grpc_stream.ru >"$logfile" 2>&1 < /dev/null & disown
  echo $!
}

wait_for_port() {
  local pid="$1"
  for _ in $(seq 1 100); do
    if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "  hyperion exited before binding; see $LOG_DIR" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "  hyperion did not bind in 10s" >&2
  return 1
}

stop_hyperion() {
  local pid="$1"
  # Kill the whole process group so master + worker both go (the master
  # was launched via setsid so its pgid == its pid).
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  # Belt-and-braces: anything still bound to the port goes too.
  pkill -KILL -f "bin/hyperion.*-p $PORT" 2>/dev/null || true
}

run_ghz() {
  local rpc="$1"      # "ServerStream" | "Unary"
  local outfile="$2"
  local errfile="$3"
  "$GHZ" --skipTLS \
    --proto bench/grpc_stream.proto \
    --call "hyperion.bench.EchoStream/$rpc" \
    -d '{"count":1,"payload":"YQ=="}' \
    -c "$CONCURRENCY" -z "$DURATION" \
    --connections "$CONCURRENCY" \
    --format=json \
    "127.0.0.1:$PORT" 2>"$errfile" \
    > "$outfile"
}

warmup() {
  local rpc="$1"
  "$GHZ" --skipTLS \
    --proto bench/grpc_stream.proto \
    --call "hyperion.bench.EchoStream/$rpc" \
    -d '{"count":1,"payload":"YQ=="}' \
    -c "$CONCURRENCY" -z "$WARMUP_DURATION" \
    --connections "$CONCURRENCY" \
    --format=json \
    "127.0.0.1:$PORT" >/dev/null 2>&1 || true
}

# Extract: rps, p50/p99/p999/p95 (ms) — ghz returns latencies in ns.
# `errors` here is the count of non-OK responses ghz reported. Cancelled
# RPCs at the -z deadline are reported as errors but do not affect rps.
summarize() {
  local jsonfile="$1"
  python3 -c "
import json
with open('$jsonfile') as f:
    d = json.load(f)
rps = d.get('rps', 0)
count = d.get('count', 0)
ld = d.get('latencyDistribution') or []
def pick(p):
    for s in ld:
        if s.get('percentage') == p:
            return s.get('latency', 0) / 1e6
    return 0.0
errs = sum((d.get('errorDistribution') or {}).values())
ok = (d.get('statusCodeDistribution') or {}).get('OK', 0)
print(f'rps={rps:9.1f} count={count:6d} ok={ok:6d} p50_ms={pick(50):6.2f} p95_ms={pick(95):6.2f} p99_ms={pick(99):6.2f} errors={errs}')
"
}

# Median of a numeric field across N json files.
median_field() {
  local field="$1"; shift
  python3 -c "
import json, statistics, sys
field = sys.argv[1]
vals = []
for fn in sys.argv[2:]:
    with open(fn) as f:
        d = json.load(f)
    if field == 'rps':
        vals.append(d.get('rps', 0))
    else:
        # percentile fields: 'p50', 'p95', 'p99'
        pct = {'p50': 50, 'p95': 95, 'p99': 99}[field]
        ld = d.get('latencyDistribution') or []
        for s in ld:
            if s.get('percentage') == pct:
                vals.append(s.get('latency', 0) / 1e6)
                break
        else:
            vals.append(0)
print(f'{statistics.median(vals):.2f}')
" "$field" "$@"
}

run_workload() {
  local label="$1"   # human-readable banner
  local rpc="$2"     # ghz call suffix
  local prefix="$3"  # log filename prefix

  echo "--- $label ---"
  pid="$(start_hyperion "$prefix")"
  trap "stop_hyperion $pid" EXIT
  wait_for_port "$pid" || { stop_hyperion "$pid"; trap - EXIT; return 1; }
  sleep 0.5
  echo "  warmup ($WARMUP_DURATION) ..."
  warmup "$rpc"
  for trial in $(seq 1 "$TRIALS"); do
    local out="$LOG_DIR/ghz-$prefix-trial$trial.json"
    local err="$LOG_DIR/ghz-$prefix-trial$trial.err"
    echo -n "  trial $trial: "
    run_ghz "$rpc" "$out" "$err"
    summarize "$out"
  done
  stop_hyperion "$pid"
  trap - EXIT
  local files=()
  for trial in $(seq 1 "$TRIALS"); do
    files+=("$LOG_DIR/ghz-$prefix-trial$trial.json")
  done
  echo "  median rps:    $(median_field rps "${files[@]}")"
  echo "  median p50_ms: $(median_field p50 "${files[@]}")"
  echo "  median p95_ms: $(median_field p95 "${files[@]}")"
  echo "  median p99_ms: $(median_field p99 "${files[@]}")"
  echo
}

main() {
  echo "==== Hyperion gRPC ghz bench (2.14-D) ===="
  echo "  workers=$WORKERS threads=$THREADS concurrency=$CONCURRENCY duration=$DURATION trials=$TRIALS"
  echo "  stream_count=$STREAM_COUNT payload_bytes=$PAYLOAD_BYTES"
  echo

  run_workload "server-streaming (one req → $STREAM_COUNT messages of $PAYLOAD_BYTES bytes)" \
               "ServerStream" "stream"

  run_workload "unary baseline (one req → one message of $PAYLOAD_BYTES bytes)" \
               "Unary" "unary"

  echo "logs in: $LOG_DIR"
}

main "$@"
