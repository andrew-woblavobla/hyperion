#!/usr/bin/env bash
# 2.14-D — ghz bench harness for the async-grpc Falcon-side server.
# Mirrors `bench/grpc_stream_bench.sh` so the cross-server numbers are
# directly comparable: same proto, same `EchoStream/{Unary,ServerStream}`
# calls, same -c, -z, --connections, --format.
#
# `bench/grpc_stream_falcon.rb` boots `Async::HTTP::Server` (Falcon's
# wire engine) with `Async::GRPC::Dispatcher` listening on TLS h2. The
# self-signed cert is the same `$TLS_DIR/cert.pem` the Hyperion harness
# uses, so `ghz --skipTLS` drives both servers identically.
#
# Usage:
#   FALCON_SERVER_DIR=/tmp/falcon-grpc \
#   GHZ=/tmp/ghz TRIALS=3 DURATION=15s bash bench/grpc_stream_falcon_bench.sh
set -euo pipefail

[[ -f "$HOME/.asdf/asdf.sh" ]] && . "$HOME/.asdf/asdf.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PORT="${PORT:-19293}"
DURATION="${DURATION:-15s}"
CONCURRENCY="${CONCURRENCY:-50}"
TRIALS="${TRIALS:-3}"
TLS_DIR="${TLS_DIR:-/tmp/hyperion-grpc-bench}"
LOG_DIR="${LOG_DIR:-/tmp/hyperion-grpc-bench-logs}"
GHZ="${GHZ:-/tmp/ghz}"
STREAM_COUNT="${STREAM_COUNT:-100}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-10}"
WARMUP_DURATION="${WARMUP_DURATION:-3s}"
FALCON_SERVER_DIR="${FALCON_SERVER_DIR:-/tmp/falcon-grpc}"
PROTO_FILE="${PROTO_FILE:-$ROOT/bench/grpc_stream.proto}"

mkdir -p "$TLS_DIR" "$LOG_DIR"

if [[ ! -f "$TLS_DIR/cert.pem" ]]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$TLS_DIR/key.pem" \
    -out "$TLS_DIR/cert.pem" -sha256 -days 30 -nodes \
    -subj "/CN=localhost" >/dev/null 2>&1
fi

start_falcon() {
  local label="$1"
  local logfile="$LOG_DIR/falcon-$label.log"
  : >"$logfile"
  echo "  start: falcon-$label (port=$PORT stream_count=$STREAM_COUNT)" >&2
  (
    cd "$FALCON_SERVER_DIR"
    GRPC_STREAM_COUNT="$STREAM_COUNT" GRPC_PAYLOAD_BYTES="$PAYLOAD_BYTES" \
    TLS_DIR="$TLS_DIR" \
    setsid nohup bundle exec ruby grpc_stream_falcon.rb "$PORT" "$STREAM_COUNT" "$PAYLOAD_BYTES" \
      >"$logfile" 2>&1 < /dev/null &
    echo $!
  )
}

wait_for_port() {
  local pid="$1"
  for _ in $(seq 1 100); do
    if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "  falcon exited before binding; see $LOG_DIR" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "  falcon did not bind in 10s" >&2
  return 1
}

stop_falcon() {
  local pid="$1"
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  # Belt-and-braces: clean up the falcon ruby process by its rackup
  # filename. The pattern is intentionally narrow (`grpc_stream_falcon.rb`)
  # so it CANNOT match this harness script (`grpc_stream_falcon_bench.sh`)
  # — pkill -f matches against the full command line, and an earlier
  # version that grepped for `grpc_stream_falcon` killed THIS script too.
  pkill -KILL -f "grpc_stream_falcon\\.rb" 2>/dev/null || true
}

run_ghz() {
  local rpc="$1"; local outfile="$2"; local errfile="$3"
  "$GHZ" --skipTLS \
    --proto "$PROTO_FILE" \
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
  "$GHZ" --skipTLS --proto "$PROTO_FILE" \
    --call "hyperion.bench.EchoStream/$rpc" \
    -d '{"count":1,"payload":"YQ=="}' \
    -c "$CONCURRENCY" -z "$WARMUP_DURATION" \
    --connections "$CONCURRENCY" \
    --format=json \
    "127.0.0.1:$PORT" >/dev/null 2>&1 || true
}

summarize() {
  local jsonfile="$1"
  python3 -c "
import json
with open('$jsonfile') as f: d = json.load(f)
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

median_field() {
  local field="$1"; shift
  python3 -c "
import json, statistics, sys
field = sys.argv[1]
vals = []
for fn in sys.argv[2:]:
    with open(fn) as f: d = json.load(f)
    if field == 'rps':
        vals.append(d.get('rps', 0))
    else:
        pct = {'p50': 50, 'p95': 95, 'p99': 99}[field]
        ld = d.get('latencyDistribution') or []
        for s in ld:
            if s.get('percentage') == pct:
                vals.append(s.get('latency', 0) / 1e6); break
        else:
            vals.append(0)
print(f'{statistics.median(vals):.2f}')
" "$field" "$@"
}

run_workload() {
  local label="$1"; local rpc="$2"; local prefix="$3"

  echo "--- $label ---"
  pid="$(start_falcon "$prefix")"
  trap "stop_falcon $pid" EXIT
  wait_for_port "$pid" || { stop_falcon "$pid"; trap - EXIT; return 1; }
  sleep 0.5
  echo "  warmup ($WARMUP_DURATION) ..."
  warmup "$rpc"
  for trial in $(seq 1 "$TRIALS"); do
    local out="$LOG_DIR/ghz-falcon-$prefix-trial$trial.json"
    local err="$LOG_DIR/ghz-falcon-$prefix-trial$trial.err"
    echo -n "  trial $trial: "
    run_ghz "$rpc" "$out" "$err"
    summarize "$out"
  done
  stop_falcon "$pid"
  trap - EXIT
  local files=()
  for trial in $(seq 1 "$TRIALS"); do
    files+=("$LOG_DIR/ghz-falcon-$prefix-trial$trial.json")
  done
  echo "  median rps:    $(median_field rps "${files[@]}")"
  echo "  median p50_ms: $(median_field p50 "${files[@]}")"
  echo "  median p95_ms: $(median_field p95 "${files[@]}")"
  echo "  median p99_ms: $(median_field p99 "${files[@]}")"
  echo
}

main() {
  echo "==== Falcon (async-grpc) gRPC ghz bench (2.14-D) ===="
  echo "  port=$PORT concurrency=$CONCURRENCY duration=$DURATION trials=$TRIALS"
  echo "  stream_count=$STREAM_COUNT payload_bytes=$PAYLOAD_BYTES"
  echo "  falcon_dir=$FALCON_SERVER_DIR"
  echo

  run_workload "server-streaming (one req → $STREAM_COUNT messages of $PAYLOAD_BYTES bytes)" \
               "ServerStream" "stream"

  run_workload "unary baseline (one req → one message of $PAYLOAD_BYTES bytes)" \
               "Unary" "unary"

  echo "logs in: $LOG_DIR"
}

main "$@"
