#!/usr/bin/env bash
# bench/h2_rails_shape.sh — A/B/C the HPACK adapter variants on a
# Rails-shape (~25-header) response. Originally landed in 2.5-B as a
# 2-way (Ruby fallback vs native), 2.11-B extended it to a 3-way
# (Ruby fallback vs native v2/Fiddle vs native v3/CGlue) so the
# Fiddle-marshalling overhead can be isolated from the Rust HPACK win.
#
# 2.5-B's two-variant bench measured native v3 at +18% over Ruby
# fallback on the 25-header workload, which flipped the
# native-vs-Ruby default to ON. The remaining open question for
# 2.11-B: how much of that +18% is the Rust HPACK encoder, and how
# much is the C-glue path's elimination of per-call Fiddle marshalling?
# A v2-only variant gives the answer:
#
#   * `cglue` ≥ +15% rps over `native`  ⇒ flip the default cglue path
#                                          ON (`HYPERION_H2_NATIVE_HPACK=cglue`
#                                           at startup, replace 2.5-B's auto-cglue
#                                           dance)
#   * `cglue` parity / +5-10% (within noise) ⇒ keep opt-in, file as deferred
#   * `cglue` ≥ −2% (negative)              ⇒ investigate, do not ship
#
# Bench noise on h2load runs is 3-5%. This script runs each variant 3x
# and prints all rps numbers + the median for each column.
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
#   variant=cglue  run1=<rps> run2=<rps> run3=<rps> median=<rps>
#   delta_native_vs_ruby=<+/-X.X%>
#   delta_cglue_vs_native=<+/-X.X%>   decision=<flip|keep|investigate>
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
  echo "[2.11-B] h2load not found on PATH — install nghttp2-client" >&2
  exit 2
fi

if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  echo "[2.11-B] TLS cert/key not found at $TLS_CERT / $TLS_KEY" >&2
  echo "[2.11-B]   openssl req -x509 -newkey rsa:2048 -keyout $TLS_KEY -out $TLS_CERT -days 1 -nodes -subj /CN=localhost" >&2
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
  echo "[2.11-B] booting hyperion ($label) on https://$HOST:$PORT — $RACKUP"
  "$@" "$HYPERION" \
       --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" \
       -t "$THREADS" -w "$WORKERS" \
       --h2-max-total-streams "$STREAMS" \
       -p "$PORT" "$RACKUP" >/tmp/hyperion-2.11-b.log 2>&1 &
  server_pid=$!

  local deadline=$(( $(date +%s) + 10 ))
  while ! nc -z "$HOST" "$PORT" 2>/dev/null; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
      echo "[2.11-B] server didn't bind in 10s — log:" >&2
      tail -50 /tmp/hyperion-2.11-b.log >&2
      exit 1
    fi
    sleep 0.1
  done

  # 2.11-B — verify the boot log selected the variant we asked for. The
  # h2 codec selection is logged the first time `Http2Handler.new` is
  # invoked, which happens lazily on the first connection (not at
  # `nc -z` socket-bind time). We hit the server with a quick curl
  # probe so the log line is guaranteed to be present, then grep
  # `hpack_path` to surface the actual selection alongside the
  # requested label. If the operator accidentally booted with a stale
  # env var (e.g. forgot to `unset`) the mismatch is visible here
  # before the bench burns its h2load run.
  curl -sk --http2 "https://$HOST:$PORT/" -o /dev/null --max-time 5 || true
  selected=""
  for _ in 1 2 3 4 5; do
    selected=$(grep -m1 'h2 codec selected' /tmp/hyperion-2.11-b.log 2>/dev/null \
                | sed -n 's/.*"hpack_path":"\([^"]*\)".*/\1/p')
    [ -n "$selected" ] && break
    sleep 0.2
  done
  echo "[2.11-B]   boot-log hpack_path=${selected:-<not-logged>}"
}

# 2.11-B — `wrk` and `h2load` both follow the same pattern: parse the
# rps line out of the formatted output. h2load's "finished in N s, RPS
# req/s" — extract the RPS column.
#
# IMPORTANT: only the rps number goes to stdout (the caller does
# `rps=$(run_h2load ...)`); the chatty status + h2load's full output
# go to stderr so they don't get captured into the array. This was
# the pre-2.11-B bug where the median3 inputs looked like
# "[2.11-B] h2load run ..." — bash's $(...) captures every stdout
# byte, not just the last line.
run_h2load() {
  local label=$1
  echo "[2.11-B] h2load run -- variant=$label  c=$C m=$M n=$N" >&2
  raw=$(h2load -c "$C" -m "$M" -n "$N" "https://$HOST:$PORT/" 2>&1)
  printf '%s\n' "$raw" >&2
  printf '%s\n' "$raw" | awk '/^finished in/ {for (i=1;i<=NF;i++) if ($i ~ /req\/s/) {print $(i-1); exit}}'
}

median3() {
  # median of 3 floating-point numbers
  printf '%s\n' "$@" | sort -n | awk 'NR==2'
}

declare -a ruby_rps native_rps cglue_rps

# === BASELINE — Ruby fallback (HYPERION_H2_NATIVE_HPACK=off) ===
# Pre-2.11-B this variant was driven by `unset HYPERION_H2_NATIVE_HPACK`,
# but since 2.5-B unset means "native auto" — use the explicit `=off`
# token so the harness is robust against ambient env on the bench host.
start_server "Ruby fallback (=off)" env HYPERION_H2_NATIVE_HPACK=off
for i in $(seq 1 "$RUNS"); do
  rps=$(run_h2load "ruby_run${i}")
  ruby_rps+=("$rps")
done
stop_server

# === NATIVE — v2 path (HYPERION_H2_NATIVE_HPACK=v2) ===
# 2.11-B introduced `=v2` / `=fiddle` to FORCE the v2 path even on a
# host where the C glue installed successfully. Without this the
# bench's `native` variant would silently pick v3 (auto-cglue) and
# this rig would be unable to measure the Fiddle-marshalling overhead
# in isolation.
start_server "native v2 (=v2 — Fiddle marshalling per call)" env HYPERION_H2_NATIVE_HPACK=v2
for i in $(seq 1 "$RUNS"); do
  rps=$(run_h2load "native_run${i}")
  native_rps+=("$rps")
done
stop_server

# === CGLUE — v3 path (HYPERION_H2_NATIVE_HPACK=cglue) ===
# 2.11-B introduced `=cglue` / `=v3` to force-select the C glue path.
# Equivalent to the auto-default on a host where cglue is available;
# the explicit token is documented for ops + makes the bench
# self-explanatory.
start_server "native v3 (=cglue — no Fiddle per call)" env HYPERION_H2_NATIVE_HPACK=cglue
for i in $(seq 1 "$RUNS"); do
  rps=$(run_h2load "cglue_run${i}")
  cglue_rps+=("$rps")
done
stop_server

ruby_med=$(median3 "${ruby_rps[@]}")
native_med=$(median3 "${native_rps[@]}")
cglue_med=$(median3 "${cglue_rps[@]}")

# bash floating-point: shell out to awk
delta_native_vs_ruby=$(awk -v r="$ruby_med" -v n="$native_med" \
  'BEGIN { if (r==0) print "n/a"; else printf "%+.1f", (n-r)/r*100 }')
delta_cglue_vs_native=$(awk -v n="$native_med" -v c="$cglue_med" \
  'BEGIN { if (n==0) print "n/a"; else printf "%+.1f", (c-n)/n*100 }')
delta_cglue_vs_ruby=$(awk -v r="$ruby_med" -v c="$cglue_med" \
  'BEGIN { if (r==0) print "n/a"; else printf "%+.1f", (c-r)/r*100 }')

# 2.11-B decision rule — keyed off the cglue-vs-native delta (the
# headline question is "does cutting per-call Fiddle marshalling buy
# us anything on top of the v2 path"). The v2-vs-ruby column is
# informational — it should reproduce the 2.5-B +18% number; if it
# regresses materially that's a separate signal worth flagging.
flip_threshold=15.0
neg_threshold=-2.0
flipped=$(awk -v d="$delta_cglue_vs_native" -v t="$flip_threshold" \
  'BEGIN { print (d+0 >= t) ? "1" : "0" }')
negative=$(awk -v d="$delta_cglue_vs_native" -v t="$neg_threshold" \
  'BEGIN { print (d+0 <= t) ? "1" : "0" }')

decision="keep cglue opt-in (within-noise)"
if [ "$flipped" = "1" ]; then
  decision="flip cglue default ON"
elif [ "$negative" = "1" ]; then
  decision="investigate — cglue regressing"
fi

echo
echo "=================== 2.11-B — Rails-shape h2 bench ==================="
echo "host         : $(uname -srm) $(hostname)"
echo "rackup       : $RACKUP"
echo "h2load       : -c $C -m $M -n $N"
echo "runs/variant : $RUNS"
echo "ruby (=off)  : ${ruby_rps[*]}    median=$ruby_med"
echo "native (=v2) : ${native_rps[*]}    median=$native_med"
echo "cglue  (=v3) : ${cglue_rps[*]}    median=$cglue_med"
echo "delta_native_vs_ruby   : $delta_native_vs_ruby% (informational — reproduce 2.5-B win)"
echo "delta_cglue_vs_native  : $delta_cglue_vs_native% (HEADLINE — Fiddle marshalling overhead)"
echo "delta_cglue_vs_ruby    : $delta_cglue_vs_ruby% (informational — total native win)"
echo "decision     : $decision"
echo "===================================================================="
