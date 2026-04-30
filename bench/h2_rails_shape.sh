#!/usr/bin/env bash
# bench/h2_rails_shape.sh — A/B the v3 native HPACK adapter against the
# Ruby fallback on a Rails-shape (~25-header) response. 2.5-B harness.
#
# 2.4-A's HPACK FFI round-2 (CGlue / v3) measured at parity vs the Ruby
# fallback on bench/hello.ru, because hello.ru ships 2 response headers
# and HPACK encode is <1% of per-stream CPU on that shape. This script
# reruns h2load against bench/h2_rails_shape.ru (25 headers) so we can
# settle the default-flip question:
#
#   * native >= +15% rps over Ruby fallback  => flip default to ON
#   * native parity / +5-10% (within noise)  => keep opt-in (env-var)
#   * native NEGATIVE                        => investigate, do not ship
#
# Bench noise on h2load runs is 3-5%. This script runs each variant 3x
# and prints all rps numbers + the median for both columns.
#
# Requires:
#   * h2load on PATH (apt install nghttp2-client OR brew install nghttp2)
#   * /tmp/cert.pem + /tmp/key.pem (self-signed TLS for ALPN h2 negotiation)
#   * a hyperion binary on PATH or invoked via bundle exec
#
# Usage (from the repo root, on openclaw-vm):
#   ./bench/h2_rails_shape.sh
#
# Env knobs:
#   PORT       - listen port (default 9602 to avoid 2.4-A's 9443/9601)
#   HOST       - listen host (default 127.0.0.1)
#   C          - TCP connections (-c, default 1)
#   M          - max concurrent streams (-m, default 100)
#   N          - total requests (-n, default 5000)
#   RUNS       - how many h2load runs per variant (default 3)
#   HYPERION   - hyperion binary path (default: hyperion on PATH)
#   TLS_CERT   - path to TLS cert (default /tmp/cert.pem)
#   TLS_KEY    - path to TLS key  (default /tmp/key.pem)
#   THREADS    - -t value (default 64)
#   WORKERS    - -w value (default 1)
#   STREAMS    - --h2-max-total-streams value (default unbounded)
#
# Output: prints each h2load run's full output, then a summary block:
#   variant=ruby   run1=<rps> run2=<rps> run3=<rps> median=<rps>
#   variant=native run1=<rps> run2=<rps> run3=<rps> median=<rps>
#   delta=<+/-X.X%>  decision=<flip|keep|investigate>
set -uo pipefail

export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

PORT=${PORT:-9602}
HOST=${HOST:-127.0.0.1}
C=${C:-1}
M=${M:-100}
N=${N:-5000}
RUNS=${RUNS:-3}
HYPERION=${HYPERION:-hyperion}
TLS_CERT=${TLS_CERT:-/tmp/cert.pem}
TLS_KEY=${TLS_KEY:-/tmp/key.pem}
THREADS=${THREADS:-64}
WORKERS=${WORKERS:-1}
STREAMS=${STREAMS:-unbounded}

RACKUP=${RACKUP:-bench/h2_rails_shape.ru}

if ! command -v h2load >/dev/null 2>&1; then
  echo "[2.5-B] h2load not found on PATH — install nghttp2-client" >&2
  exit 2
fi

if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "[2.5-B] TLS cert/key not found at $TLS_CERT / $TLS_KEY" >&2
  echo "[2.5-B]   openssl req -x509 -newkey rsa:2048 -keyout $TLS_KEY -out $TLS_CERT -days 1 -nodes -subj /CN=localhost" >&2
  exit 2
fi

server_pid=""
stop_server() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap stop_server EXIT

start_server() {
  local label=$1
  shift
  echo "[2.5-B] booting hyperion ($label) on https://$HOST:$PORT — $RACKUP"
  "$@" "$HYPERION" \
       --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" \
       -t "$THREADS" -w "$WORKERS" \
       --h2-max-total-streams "$STREAMS" \
       -p "$PORT" "$RACKUP" >/tmp/hyperion-2.5-b.log 2>&1 &
  server_pid=$!

  local deadline=$(( $(date +%s) + 10 ))
  while ! nc -z "$HOST" "$PORT" 2>/dev/null; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "[2.5-B] server didn't bind in 10s — log:" >&2
      tail -50 /tmp/hyperion-2.5-b.log >&2
      exit 1
    fi
    sleep 0.1
  done
}

run_h2load() {
  local label=$1
  echo "[2.5-B] h2load run -- variant=$label  c=$C m=$M n=$N"
  raw=$(h2load -c "$C" -m "$M" -n "$N" "https://$HOST:$PORT/" 2>&1)
  echo "$raw"
  echo "$raw" | awk '/^finished in/ {for (i=1;i<=NF;i++) if ($i ~ /req\/s/) {print $(i-1); exit}}'
}

median3() {
  # median of 3 floating-point numbers
  printf '%s\n' "$@" | sort -n | awk 'NR==2'
}

declare -a ruby_rps native_rps

# === BASELINE — Ruby fallback (HPACK env var unset) ===
unset HYPERION_H2_NATIVE_HPACK
start_server "Ruby fallback"
for i in $(seq 1 "$RUNS"); do
  rps=$(run_h2load "ruby_run${i}")
  ruby_rps+=("$rps")
done
stop_server

# === NATIVE — v3 path (HYPERION_H2_NATIVE_HPACK=1) ===
start_server "native v3" env HYPERION_H2_NATIVE_HPACK=1
for i in $(seq 1 "$RUNS"); do
  rps=$(run_h2load "native_run${i}")
  native_rps+=("$rps")
done
stop_server

ruby_med=$(median3 "${ruby_rps[@]}")
native_med=$(median3 "${native_rps[@]}")

# bash floating-point: shell out to awk
delta_pct=$(awk -v r="$ruby_med" -v n="$native_med" 'BEGIN { if (r==0) print "n/a"; else printf "%+.1f", (n-r)/r*100 }')

decision="keep (within-noise)"
flip_threshold=15.0
neg_threshold=-2.0
flipped=$(awk -v d="$delta_pct" -v t="$flip_threshold" 'BEGIN { print (d+0 >= t) ? "1" : "0" }')
negative=$(awk -v d="$delta_pct" -v t="$neg_threshold" 'BEGIN { print (d+0 <= t) ? "1" : "0" }')
if [ "$flipped" = "1" ]; then
  decision="flip default to ON"
elif [ "$negative" = "1" ]; then
  decision="investigate — native is regressing"
fi

echo
echo "================== 2.5-B — Rails-shape h2 bench =================="
echo "host         : $(uname -srm) $(hostname)"
echo "rackup       : $RACKUP"
echo "h2load       : -c $C -m $M -n $N"
echo "runs/variant : $RUNS"
echo "ruby_fallback: ${ruby_rps[*]}    median=$ruby_med"
echo "native_v3    : ${native_rps[*]}    median=$native_med"
echo "delta        : $delta_pct%"
echo "decision     : $decision"
echo "==================================================================="
