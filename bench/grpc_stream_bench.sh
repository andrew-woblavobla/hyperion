#!/usr/bin/env bash
# 2.13-D — ghz bench harness for Hyperion's gRPC streaming + unary paths.
#
# Boots Hyperion on a self-signed TLS cert, runs three trials each of:
#   1. Server-streaming: 50 concurrent streams, 100 replies per stream
#   2. Unary baseline: 50 concurrent, single-message responses
#
# Output is one CSV-ish line per trial; the harness reports the median
# of the three trials per workload at the end.
#
# Required: ghz on $PATH. Falcon side is OPTIONAL — Falcon does not run
# Rack-shaped gRPC; the comparison falls back to Hyperion-vs-Hyperion-2.11.0
# when Falcon is unavailable. See the bench [bench] commit message for the
# documented limits of the cross-server comparison.
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

mkdir -p "$TLS_DIR" "$LOG_DIR"

# Self-signed cert; ghz drives it with --insecure (skip cert verify).
if [[ ! -f "$TLS_DIR/cert.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$TLS_DIR/key.pem" \
    -out "$TLS_DIR/cert.pem" -sha256 -days 30 -nodes \
    -subj "/CN=localhost" >/dev/null 2>&1
fi

start_hyperion() {
  local label="$1"
  local logfile="$LOG_DIR/hyperion-$label.log"
  echo "  start: $label (workers=$WORKERS threads=$THREADS port=$PORT)" >&2
  HYPERION_LOG_LEVEL=warn nohup bin/hyperion \
    -b 127.0.0.1 -p "$PORT" -w "$WORKERS" -t "$THREADS" \
    --tls-cert "$TLS_DIR/cert.pem" --tls-key "$TLS_DIR/key.pem" \
    --h2-max-total-streams unbounded \
    --no-log-requests \
    bench/grpc_stream.ru >"$logfile" 2>&1 &
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
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

run_ghz_streaming() {
  local trial="$1"
  "$GHZ" --skipTLS \
    --proto bench/grpc_stream.proto \
    --call hyperion.bench.EchoStream/ServerStream \
    -d '{"count":100,"payload":"YQ=="}' \
    -c "$CONCURRENCY" -z "$DURATION" \
    --connections "$CONCURRENCY" \
    --format=json \
    "127.0.0.1:$PORT" 2>"$LOG_DIR/ghz-stream-trial$trial.err" \
    > "$LOG_DIR/ghz-stream-trial$trial.json"
}

run_ghz_unary() {
  local trial="$1"
  "$GHZ" --skipTLS \
    --proto bench/grpc_stream.proto \
    --call hyperion.bench.EchoStream/Unary \
    -d '{"count":1,"payload":"YQ=="}' \
    -c "$CONCURRENCY" -z "$DURATION" \
    --connections "$CONCURRENCY" \
    --format=json \
    "127.0.0.1:$PORT" 2>"$LOG_DIR/ghz-unary-trial$trial.err" \
    > "$LOG_DIR/ghz-unary-trial$trial.json"
}

# Extract: total RPCs, RPCs/s, average latency (ns), p50, p95.
summarize() {
  local jsonfile="$1"
  python3 -c "
import json, sys
with open('$jsonfile') as f:
    d = json.load(f)
rps = d.get('rps', 0)
count = d.get('count', 0)
avg_ms = d.get('average', 0) / 1e6
p50_ms = d.get('latencyDistribution', [{}])[2].get('latency', 0) / 1e6 if d.get('latencyDistribution') else 0
p95_ms = next((s['latency'] for s in d.get('latencyDistribution', []) if s.get('percentage') == 95), 0) / 1e6
errors = d.get('errorDistribution', {})
err_count = sum(errors.values()) if errors else 0
print(f'rps={rps:.1f} count={count} avg_ms={avg_ms:.2f} p50_ms={p50_ms:.2f} p95_ms={p95_ms:.2f} errors={err_count}')
"
}

median_rps() {
  python3 -c "
import json, sys, statistics
files = sys.argv[1:]
rps = []
for fn in files:
    with open(fn) as f:
        rps.append(json.load(f).get('rps', 0))
print(f'{statistics.median(rps):.1f}')
" "$@"
}

main() {
  echo "==== Hyperion gRPC streaming bench (2.13-D) ===="
  echo "  workers=$WORKERS threads=$THREADS concurrency=$CONCURRENCY duration=$DURATION trials=$TRIALS"
  echo

  echo "--- server-streaming (one request → 100 messages of 10 bytes) ---"
  for trial in $(seq 1 "$TRIALS"); do
    pid="$(start_hyperion "stream-trial$trial")"
    wait_for_port "$pid" || { stop_hyperion "$pid"; exit 1; }
    sleep 0.5
    echo -n "  trial $trial: "
    run_ghz_streaming "$trial"
    summarize "$LOG_DIR/ghz-stream-trial$trial.json"
    stop_hyperion "$pid"
    sleep 0.5
  done
  local stream_files=()
  for trial in $(seq 1 "$TRIALS"); do stream_files+=("$LOG_DIR/ghz-stream-trial$trial.json"); done
  echo "  median rps: $(median_rps "${stream_files[@]}")"

  echo
  echo "--- unary baseline (one request → one message of 10 bytes) ---"
  for trial in $(seq 1 "$TRIALS"); do
    pid="$(start_hyperion "unary-trial$trial")"
    wait_for_port "$pid" || { stop_hyperion "$pid"; exit 1; }
    sleep 0.5
    echo -n "  trial $trial: "
    run_ghz_unary "$trial"
    summarize "$LOG_DIR/ghz-unary-trial$trial.json"
    stop_hyperion "$pid"
    sleep 0.5
  done
  local unary_files=()
  for trial in $(seq 1 "$TRIALS"); do unary_files+=("$LOG_DIR/ghz-unary-trial$trial.json"); done
  echo "  median rps: $(median_rps "${unary_files[@]}")"
  echo
  echo "logs in: $LOG_DIR"
}

main "$@"
