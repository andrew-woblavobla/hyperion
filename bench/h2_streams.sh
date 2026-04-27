#!/usr/bin/env bash
# bench/h2_streams.sh — measure h2 multi-stream throughput on one TCP
# connection. Useful for verifying the per-stream send queue + writer fiber
# (1.6.0 architectural rewrite) actually lifts the per-connection write
# bottleneck.
#
# Pre-1.6.0: every framer write (HEADERS / DATA / RST_STREAM / GOAWAY)
# serialized through one Mutex around `socket.write`. Throughput on a
# single-TCP-connection / many-stream workload was capped by "one write
# at a time across all streams."
#
# Post-1.6.0: encode happens under the encode mutex (microseconds, in-memory),
# the actual socket.write happens off-fiber on a dedicated writer fiber that
# drains a per-connection queue. Encode and write overlap across streams.
#
# Requires `h2load` (from nghttp2) on PATH:
#   apt-get install -y nghttp2-client     # Ubuntu / Debian
#   brew install nghttp2                  # macOS
#
# Usage:
#   ./bench/h2_streams.sh                  # defaults: c=1 m=100 n=5000
#   PORT=9443 N=10000 M=200 ./bench/h2_streams.sh
#
# Env knobs:
#   PORT      - h2 listen port (default 9443; expects hyperion already up)
#   HOST      - listen host    (default 127.0.0.1)
#   C         - TCP connections (-c) — keep at 1 to bench single-conn h2
#   M         - max concurrent streams per conn (-m)
#   N         - total requests (-n)
#   PATHURI   - URL path on the target (default "/")
#   RACKUP    - bench app to boot if SERVER_BIN is set (default bench/hello.ru)
#   SERVER_BIN- if set, this script will start hyperion before benching
#               and stop it after. Otherwise expects an already-running server.
#
# Expected pre/post comparison shape (single-stream-handler workload, no
# disk / DB):
#   1.5.0:  rps capped well below per-stream serialised handler bound;
#           h2load reports time waiting on send/recv largely on send side.
#   1.6.0:  rps closer to the per-stream serialised handler bound;
#           CPU on the server is the new ceiling, not socket-write Mutex.
#
# This script writes a one-line JSON summary to stdout (and to OUT_FILE if
# set) so it can be diffed across releases.
set -uo pipefail

export PATH="$HOME/.asdf/bin:$HOME/.asdf/shims:$PATH"

PORT=${PORT:-9443}
HOST=${HOST:-127.0.0.1}
C=${C:-1}
M=${M:-100}
N=${N:-5000}
PATHURI=${PATHURI:-/}
SERVER_BIN=${SERVER_BIN:-}
RACKUP=${RACKUP:-bench/hello.ru}
OUT_FILE=${OUT_FILE:-}

if ! command -v h2load >/dev/null 2>&1; then
  echo "[h2_streams] h2load not found on PATH — skipping" >&2
  echo "[h2_streams] install nghttp2-client (Linux) or 'brew install nghttp2'" >&2
  exit 2
fi

server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -n "$SERVER_BIN" ]; then
  echo "[h2_streams] booting $SERVER_BIN with $RACKUP on https://$HOST:$PORT"
  # Self-signed TLS cert is required for ALPN h2 negotiation. The bench
  # invoker is responsible for arranging that (--tls-cert/--tls-key) — we
  # assume SERVER_BIN already takes care of it.
  "$SERVER_BIN" --host "$HOST" --port "$PORT" "$RACKUP" &
  server_pid=$!

  # Wait for bind.
  deadline=$(( $(date +%s) + 5 ))
  while ! nc -z "$HOST" "$PORT" 2>/dev/null; do
    [ "$(date +%s)" -gt "$deadline" ] && { echo "[h2_streams] server didn't bind"; exit 1; }
    sleep 0.1
  done
fi

URL="https://$HOST:$PORT$PATHURI"
echo "[h2_streams] benching $URL  c=$C m=$M n=$N"

# h2load output is human-readable; we grep the headline rps line.
raw=$(h2load -c "$C" -m "$M" -n "$N" "$URL" 2>&1)
echo "$raw"

rps=$(echo "$raw" | awk '/^finished in/ {for (i=1;i<=NF;i++) if ($i ~ /req\/s/) {print $(i-1); exit}}')
mean_time=$(echo "$raw" | awk '/time for request:/ {print $4; exit}')

summary=$(printf '{"variant":"h2_streams","host":"%s","port":%s,"c":%s,"m":%s,"n":%s,"rps":"%s","mean_request_time":"%s"}' \
  "$HOST" "$PORT" "$C" "$M" "$N" "${rps:-unknown}" "${mean_time:-unknown}")
echo "$summary"

if [ -n "$OUT_FILE" ]; then
  echo "$summary" >> "$OUT_FILE"
fi
