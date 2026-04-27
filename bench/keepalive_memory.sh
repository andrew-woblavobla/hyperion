#!/usr/bin/env bash
# bench/keepalive_memory.sh — sweep hyperion / puma / falcon across N values,
# capture RSS at idle keep-alive scale, print a summary table.
#
# Run on Linux (uses /proc). Bumps the bench process file-descriptor limit
# so it can open >1k sockets and the spawned server inherits it.
#
# Tunables:
#   N_VALUES   - space-separated connection-count list (default "1000 5000 10000")
#   SERVERS    - subset of "hyperion puma falcon" (default all)
#   HOLD_SEC   - per-run idle hold (default 30)
#   RACKUP     - rackup file (default bench/hello.ru)
#   OUT_DIR    - results dir (default ./keepalive_memory_results)
#   PORT_BASE  - first port (default 19990; +1 per run)
#
# Usage:
#   ./bench/keepalive_memory.sh
#   N_VALUES="10000" SERVERS="hyperion" ./bench/keepalive_memory.sh
set -uo pipefail

export PATH="$HOME/.asdf/bin:$HOME/.asdf/shims:$PATH"

# Resolve the script's own directory so the wrapper works whether run from
# the project root (`./bench/keepalive_memory.sh`) or from anywhere else
# (e.g. ssh-deployed under ~/bench/keepalive_memory.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUBY_BENCH="$SCRIPT_DIR/keepalive_memory.rb"
DEFAULT_RACKUP="$SCRIPT_DIR/hello.ru"

# Need a high FD ceiling so we can open thousands of sockets. The server
# inherits this when we spawn it from Ruby.
ulimit -n 65536 2>/dev/null || ulimit -n 20000 2>/dev/null || true

N_VALUES=${N_VALUES:-"1000 5000 10000"}
SERVERS=${SERVERS:-"hyperion puma falcon"}
HOLD_SEC=${HOLD_SEC:-30}
RACKUP=${RACKUP:-$DEFAULT_RACKUP}
OUT_DIR=${OUT_DIR:-./keepalive_memory_results}
PORT_BASE=${PORT_BASE:-19990}

mkdir -p "$OUT_DIR"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
log_file="$OUT_DIR/run-$stamp.log"
json_file="$OUT_DIR/run-$stamp.jsonl"

echo "[sweep] writing log to $log_file"
echo "[sweep] writing jsonl to $json_file"
echo "[sweep] N_VALUES=$N_VALUES SERVERS=$SERVERS HOLD_SEC=$HOLD_SEC RACKUP=$RACKUP" | tee -a "$log_file"

port=$PORT_BASE
for n in $N_VALUES; do
  for s in $SERVERS; do
    echo "" | tee -a "$log_file"
    echo "===== run: server=$s N=$n port=$port =====" | tee -a "$log_file"

    # Run the bench, capture stdout+stderr to log; tail the JSON line out.
    out=$(SERVER="$s" N="$n" PORT="$port" HOLD_SEC="$HOLD_SEC" RACKUP="$RACKUP" \
            ruby "$RUBY_BENCH" 2>&1)
    rc=$?
    echo "$out" | tee -a "$log_file" > /dev/null

    # The script's last line is JSON. Extract it.
    json=$(echo "$out" | grep -E '^\{"server":' | tail -n 1)
    if [ -n "$json" ]; then
      echo "$json" | tee -a "$json_file" > /dev/null
    else
      echo "{\"server\":\"$s\",\"target_n\":$n,\"error\":\"no-json (rc=$rc)\"}" | tee -a "$json_file" > /dev/null
    fi

    port=$((port + 1))
    sleep 2 # let the kernel reap sockets / TIME_WAIT before next run
  done
done

echo "" | tee -a "$log_file"
echo "===== SUMMARY =====" | tee -a "$log_file"
printf "  %-10s %8s %8s %8s %12s %12s\n" \
  server N held dropped peak_rss_MB drain_rss_MB | tee -a "$log_file"
printf "  %-10s %8s %8s %8s %12s %12s\n" \
  ---------- -------- -------- -------- ------------ ------------ | tee -a "$log_file"

while IFS= read -r line; do
  [ -z "$line" ] && continue
  ruby -rjson -e '
    j = JSON.parse(STDIN.read)
    if j["error"]
      printf("  %-10s %8d %8s %8s %12s %12s\n",
             j["server"], j["target_n"], "-", "-", "-", "-")
      printf("    error: %s\n", j["error"])
    else
      peak  = ((j["peak_rss_kb"]    || 0) / 1024.0).round(1)
      drain = ((j["drained_rss_kb"] || 0) / 1024.0).round(1)
      printf("  %-10s %8d %8d %8d %12.1f %12.1f\n",
             j["server"], j["target_n"], j["succeeded"], j["dropped"],
             peak, drain)
    end
  ' <<< "$line" | tee -a "$log_file"
done < "$json_file"

echo "" | tee -a "$log_file"
echo "[sweep] done — full log: $log_file"
echo "[sweep] jsonl: $json_file"
