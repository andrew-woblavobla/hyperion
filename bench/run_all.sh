#!/usr/bin/env bash
# bench/run_all.sh — 2.15-A canonical bench harness.
#
# Drives every workload that contributes to the README headline table
# in a single command. Designed to be re-runnable: any future
# maintainer can `./bench/run_all.sh` and reproduce the published
# numbers (within bench-host drift).
#
# Workloads (rows match docs/BENCH_HYPERION_2_14.md):
#
#   Row | Workload                                            | Tool | Rackup
#   ----+-----------------------------------------------------+------+----------------------------------
#    1  | Hyperion handle_static + io_uring (peak headline)   | wrk  | bench/hello_static.ru
#    2  | Hyperion handle_static + accept4 (default plain)    | wrk  | bench/hello_static.ru
#    3  | Hyperion Server.handle BLOCK form                   | wrk  | bench/hello_handle_block.ru
#    4  | Hyperion generic Rack hello                         | wrk  | bench/hello.ru
#    5  | Hyperion CPU JSON (Server.handle block, work.ru)    | wrk  | bench/work.ru
#    6  | Hyperion gRPC unary, h2/TLS                         | ghz  | bench/grpc_stream.ru
#    7  | Reference: Agoo on hello                            | wrk  | bench/hello.ru
#    8  | Reference: Falcon on hello                          | wrk  | bench/hello.ru
#    9  | Reference: Puma on hello                            | wrk  | bench/hello.ru
#   10  | Reference: Falcon async-grpc on grpc unary          | ghz  | bench/grpc_stream_falcon.rb
#
# Usage:
#   ./bench/run_all.sh                       # all rows
#   ./bench/run_all.sh --row 1               # single row
#   ./bench/run_all.sh --rows 1,2,3,4,5      # subset
#   ./bench/run_all.sh --skip-grpc           # rows 1-5 + 7-9
#   ./bench/run_all.sh --rails              # Rails matrix only (rows 11-32)
#   ./bench/run_all.sh --with-rails         # default rows + Rails matrix
#
# Knobs (env):
#   PORT=9810 DURATION=20s WRK_THREADS=4 WRK_CONNS=100 RUNS=3
#   GHZ=/path/to/ghz   (default: /tmp/ghz)
#
# Output: writes a CSV at $OUT_CSV (default /tmp/hyperion-2.15-bench.csv)
# and a markdown table at $OUT_MD (default /tmp/hyperion-2.15-bench.md).
# Each line in CSV: row,label,tool,rackup,rps_med,p99_med,trials.
#
# Convention: one server per row, killed before the next row starts.
# Three trials per row; median is the headline number. SO_REUSEPORT
# noise is mitigated by waiting for the kernel to release the listener
# before booting the next server.

set -u

[[ -f "$HOME/.asdf/asdf.sh" ]] && . "$HOME/.asdf/asdf.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$ROOT/bench/Gemfile.4way}"
export HYPERION_PATH="${HYPERION_PATH:-$ROOT}"

PORT="${PORT:-9810}"
HOST="${HOST:-127.0.0.1}"
DURATION="${DURATION:-20s}"
WRK_THREADS="${WRK_THREADS:-4}"
WRK_CONNS="${WRK_CONNS:-100}"
RUNS="${RUNS:-3}"
GHZ="${GHZ:-/tmp/ghz}"
OUT_CSV="${OUT_CSV:-/tmp/hyperion-2.15-bench.csv}"
OUT_MD="${OUT_MD:-/tmp/hyperion-2.15-bench.md}"

ROWS_FILTER=""
SKIP_GRPC=0
RAILS_ONLY=0
INCLUDE_RAILS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --row) ROWS_FILTER="$2"; shift 2 ;;
    --rows) ROWS_FILTER="$2"; shift 2 ;;
    --skip-grpc) SKIP_GRPC=1; shift ;;
    --rails) RAILS_ONLY=1; INCLUDE_RAILS=1; shift ;;
    --with-rails) INCLUDE_RAILS=1; shift ;;
    -h|--help) sed -n '1,57p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

want_row() {
  local n="$1"
  # If --rails was given without --rows, run only Rails rows (11-32).
  # If --rows was also given, the explicit list wins.
  if [ -z "$ROWS_FILTER" ] && [ "$RAILS_ONLY" = "1" ]; then
    [ "$n" -ge 11 ] && [ "$n" -le 32 ]
    return $?
  fi
  # If --rows was given, only those rows run.
  if [ -n "$ROWS_FILTER" ]; then
    echo ",$ROWS_FILTER," | grep -q ",$n,"
    return $?
  fi
  # Default: rows 1-10 (existing behavior); skip Rails rows unless --with-rails.
  if [ "$n" -ge 11 ] && [ "$n" -le 32 ]; then
    [ "$INCLUDE_RAILS" = "1" ]
    return $?
  fi
  return 0
}

PID=""
stop_port() {
  if [ -n "$PID" ]; then
    kill -KILL "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
  pkill -KILL -f "[ :=]$PORT( |$)" 2>/dev/null || true
  local waited=0
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT$"; do
    sleep 0.5
    waited=$((waited + 1))
    [ $waited -ge 20 ] && break
  done
}
trap 'stop_port' EXIT INT TERM

wait_for_bind() {
  local label="$1" url_path="${2:-/}"
  for i in $(seq 1 12); do
    sleep 1
    if curl -sS -o /dev/null --max-time 1 "http://$HOST:$PORT$url_path" 2>/dev/null; then
      echo "[$label] bound after ${i}s"
      return 0
    fi
  done
  return 1
}

# After bind, hit a cheap path 3x so YJIT compiles the hot path
# before wrk starts the real run. Without this, the first ~500ms
# of the wrk window is YJIT compilation noise that drags the median
# down. Used by the Rails rows (Tasks 15-19) which point /healthz
# at an inline Rack lambda — ultra-cheap, no controller dispatch.
warmup_hit() {
  local label="$1" url_path="${2:-/healthz}"
  for _ in 1 2 3; do
    curl -sS -o /dev/null --max-time 2 "http://$HOST:$PORT$url_path" 2>/dev/null
  done
  echo "[$label] warmup: 3x GET $url_path"
}

median() {
  printf '%s\n' "$@" | sort -g | awk -v n=$# 'NR == int((n+1)/2) { print; exit }'
}

# Run wrk RUNS times against the currently bound server, write
# "row,label,wrk,rackup,rps_med,p99_med,trials" to OUT_CSV.
bench_wrk_row() {
  local row="$1" label="$2" rackup="$3" url_path="${4:-/}"
  local rps_list=() p99_list=()
  for run in $(seq 1 "$RUNS"); do
    local out rps p99
    out=$(wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$DURATION" --latency \
      "http://$HOST:$PORT$url_path" 2>&1)
    rps=$(echo "$out" | awk '/Requests\/sec:/ { print $2 }')
    p99=$(echo "$out" | awk '/^ *99%/ { print $2 }')
    rps_list+=("${rps:-NA}")
    p99_list+=("${p99:-NA}")
    echo "[$label] wrk run=$run rps=$rps p99=$p99"
    sleep 2
  done
  local rps_med p99_med trials
  rps_med=$(median "${rps_list[@]}")
  p99_med=$(median "${p99_list[@]}")
  trials="${rps_list[*]}"
  echo "[$label] WRK MEDIAN rps=$rps_med p99=$p99_med (runs: $trials)"
  echo "$row,$label,wrk,$rackup,$rps_med,$p99_med,${trials// /|}," >> "$OUT_CSV"
}

# macOS doesn't ship `setsid`. Use it on Linux for clean process-group
# isolation (so a SIGINT to the harness doesn't double-fire into the
# server); fall back to plain `nohup` on macOS where the smoke runs
# (Task 20) are short-lived and isolation matters less.
if command -v setsid >/dev/null 2>&1; then
  SETSID="setsid"
else
  SETSID=""
fi

# Boot a Hyperion server in background. Uses setsid (Linux) for clean
# process-group isolation. Returns the PID.
boot_hyperion() {
  local label="$1" rackup="$2"; shift 2
  local extra_env="${HYPERION_EXTRA_ENV:-}"
  echo "[$label] boot: $extra_env bundle exec hyperion $* $rackup"
  # shellcheck disable=SC2086
  env $extra_env $SETSID nohup bundle exec hyperion "$@" "$rackup" \
    > "/tmp/2.15-bench-$label.log" 2>&1 < /dev/null &
  PID=$!
  disown 2>/dev/null || true
}

# Boot a Puma / Falcon / Agoo server.
boot_puma() {
  local rackup="$1" workers="${2:-1}"
  echo "[puma] boot: bundle exec puma -t 5:5 -w $workers -b tcp://$HOST:$PORT $rackup"
  $SETSID nohup bundle exec puma -t 5:5 -w "$workers" -b "tcp://$HOST:$PORT" "$rackup" \
    > "/tmp/2.15-bench-puma.log" 2>&1 < /dev/null &
  PID=$!
}
boot_falcon() {
  local rackup="$1" forks="${2:-1}"
  echo "[falcon] boot: bundle exec falcon serve --bind http://localhost:$PORT --hybrid -n 1 --forks $forks --threads 5 --config $rackup"
  $SETSID nohup bundle exec falcon serve \
    --bind "http://localhost:$PORT" --hybrid -n 1 --forks "$forks" --threads 5 \
    --config "$rackup" > "/tmp/2.15-bench-falcon.log" 2>&1 < /dev/null &
  PID=$!
}
boot_agoo() {
  local rackup="$1" workers="${2:-1}"
  echo "[agoo] boot: bundle exec ruby bench/agoo_boot.rb $rackup $PORT 5 $workers"
  $SETSID nohup bundle exec ruby bench/agoo_boot.rb "$rackup" "$PORT" 5 "$workers" \
    > "/tmp/2.15-bench-agoo.log" 2>&1 < /dev/null &
  PID=$!
}

: > "$OUT_CSV"
echo "row,label,tool,rackup,rps_med,p99_med,trials,bar" >> "$OUT_CSV"

echo "============================================================"
echo "Hyperion 2.15-A canonical bench"
echo "Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host:     $(uname -a)"
echo "Ruby:     $(ruby --version)"
echo "Hyperion: $(ruby -I lib -r hyperion/version -e 'puts Hyperion::VERSION')"
echo "wrk:      -t$WRK_THREADS -c$WRK_CONNS -d$DURATION   ($RUNS runs/row)"
echo "Output:   $OUT_CSV"
echo "============================================================"

# ---------- Row 1: Hyperion handle_static + io_uring ----------
if want_row 1; then
  echo
  echo "=== Row 1: Hyperion handle_static + io_uring ==="
  stop_port
  HYPERION_EXTRA_ENV="HYPERION_IO_URING_ACCEPT=1" \
    boot_hyperion "row1" "bench/hello_static.ru" \
      -t 32 -w 1 -p "$PORT"
  if wait_for_bind "row1"; then
    bench_wrk_row 1 "hyperion_handle_static_iouring" "bench/hello_static.ru"
  else
    echo "row1: BOOT-FAIL"
    echo "1,hyperion_handle_static_iouring,wrk,bench/hello_static.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 2: Hyperion handle_static + accept4 ----------
if want_row 2; then
  echo
  echo "=== Row 2: Hyperion handle_static + accept4 ==="
  stop_port
  boot_hyperion "row2" "bench/hello_static.ru" \
    -t 32 -w 1 -p "$PORT"
  if wait_for_bind "row2"; then
    bench_wrk_row 2 "hyperion_handle_static_accept4" "bench/hello_static.ru"
  else
    echo "2,hyperion_handle_static_accept4,wrk,bench/hello_static.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 3: Hyperion Server.handle BLOCK ----------
if want_row 3; then
  echo
  echo "=== Row 3: Hyperion Server.handle block form ==="
  stop_port
  boot_hyperion "row3" "bench/hello_handle_block.ru" \
    -t 5 -w 1 -p "$PORT"
  if wait_for_bind "row3"; then
    bench_wrk_row 3 "hyperion_handle_block" "bench/hello_handle_block.ru"
  else
    echo "3,hyperion_handle_block,wrk,bench/hello_handle_block.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 4: Hyperion generic Rack hello ----------
if want_row 4; then
  echo
  echo "=== Row 4: Hyperion generic Rack hello ==="
  stop_port
  boot_hyperion "row4" "bench/hello.ru" \
    -t 5 -w 1 -p "$PORT"
  if wait_for_bind "row4"; then
    bench_wrk_row 4 "hyperion_rack_hello" "bench/hello.ru"
  else
    echo "4,hyperion_rack_hello,wrk,bench/hello.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 5: Hyperion CPU JSON ----------
if want_row 5; then
  echo
  echo "=== Row 5: Hyperion CPU JSON (work.ru) ==="
  stop_port
  boot_hyperion "row5" "bench/work.ru" \
    -t 5 -w 1 -p "$PORT"
  if wait_for_bind "row5"; then
    bench_wrk_row 5 "hyperion_cpu_json" "bench/work.ru"
  else
    echo "5,hyperion_cpu_json,wrk,bench/work.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 6: Hyperion gRPC unary, h2/TLS ----------
if want_row 6 && [ "$SKIP_GRPC" = "0" ]; then
  if [ -x "$GHZ" ]; then
    echo
    echo "=== Row 6: Hyperion gRPC unary (h2/TLS) ==="
    # Defer to the existing harness which sets up self-signed TLS,
    # boots Hyperion with the right config, and runs ghz with
    # canonical knobs (50c x 50,000 calls). It writes its own
    # logs under /tmp/hyperion-grpc-bench-logs; we extract the
    # unary median from its summary line.
    bench/grpc_stream_bench.sh > /tmp/2.15-bench-row6.log 2>&1 || true
    rps_med=$(grep -E "unary MEDIAN" /tmp/2.15-bench-row6.log | head -1 | awk '{ print $4 }')
    p99_med=$(grep -E "unary MEDIAN" /tmp/2.15-bench-row6.log | head -1 | awk '{ print $6 }')
    echo "[row6] unary rps_med=$rps_med p99_med=$p99_med"
    echo "6,hyperion_grpc_unary,ghz,bench/grpc_stream.ru,${rps_med:-NA},${p99_med:-NA},see-grpc-bench-log," >> "$OUT_CSV"
  else
    echo "[row6] ghz binary not at $GHZ — skipping; install via 'go install github.com/bojand/ghz/cmd/ghz@latest'"
    echo "6,hyperion_grpc_unary,ghz,bench/grpc_stream.ru,SKIP,SKIP,ghz-not-installed," >> "$OUT_CSV"
  fi
fi

# ---------- Row 7: Reference Agoo on hello ----------
if want_row 7; then
  echo
  echo "=== Row 7: Reference Agoo on hello ==="
  stop_port
  boot_agoo "bench/hello.ru"
  if wait_for_bind "agoo"; then
    bench_wrk_row 7 "ref_agoo" "bench/hello.ru"
  else
    echo "7,ref_agoo,wrk,bench/hello.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 8: Reference Falcon on hello ----------
if want_row 8; then
  echo
  echo "=== Row 8: Reference Falcon on hello ==="
  stop_port
  boot_falcon "bench/hello.ru"
  if wait_for_bind "falcon"; then
    bench_wrk_row 8 "ref_falcon" "bench/hello.ru"
  else
    echo "8,ref_falcon,wrk,bench/hello.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 9: Reference Puma on hello ----------
if want_row 9; then
  echo
  echo "=== Row 9: Reference Puma on hello ==="
  stop_port
  boot_puma "bench/hello.ru"
  if wait_for_bind "puma"; then
    bench_wrk_row 9 "ref_puma" "bench/hello.ru"
  else
    echo "9,ref_puma,wrk,bench/hello.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 10: Reference Falcon async-grpc unary ----------
if want_row 10 && [ "$SKIP_GRPC" = "0" ]; then
  if [ -x "$GHZ" ]; then
    echo
    echo "=== Row 10: Reference Falcon async-grpc unary ==="
    bench/grpc_stream_falcon_bench.sh > /tmp/2.15-bench-row10.log 2>&1 || true
    rps_med=$(grep -E "unary MEDIAN" /tmp/2.15-bench-row10.log | head -1 | awk '{ print $4 }')
    p99_med=$(grep -E "unary MEDIAN" /tmp/2.15-bench-row10.log | head -1 | awk '{ print $6 }')
    echo "[row10] unary rps_med=$rps_med p99_med=$p99_med"
    echo "10,ref_falcon_grpc_unary,ghz,bench/grpc_stream_falcon.rb,${rps_med:-NA},${p99_med:-NA},see-grpc-bench-log," >> "$OUT_CSV"
  else
    echo "[row10] ghz binary not at $GHZ — skipping"
    echo "10,ref_falcon_grpc_unary,ghz,bench/grpc_stream_falcon.rb,SKIP,SKIP,ghz-not-installed," >> "$OUT_CSV"
  fi
fi

# ============================================================
# Rails matrix (rows 11-32) — opt-in via --rails or --with-rails
# ============================================================

# ---------- Row 11: Hyperion Rails API-only (1w x 5t) ----------
if want_row 11; then
  echo
  echo "=== Row 11: Hyperion Rails API-only (1w x 5t) ==="
  stop_port
  boot_hyperion "row11" "bench/rails_api.ru" -t 5 -w 1 -p "$PORT"
  if wait_for_bind "row11" "/healthz"; then
    warmup_hit "row11" "/api/users"
    bench_wrk_row 11 "hyperion_rails_api_1w" "bench/rails_api.ru" "/api/users"
  else
    echo "11,hyperion_rails_api_1w,wrk,bench/rails_api.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 12: Agoo Rails API-only (1w x 5t) ----------
if want_row 12; then
  echo
  echo "=== Row 12: Agoo Rails API-only (1w x 5t) ==="
  stop_port
  boot_agoo "bench/rails_api.ru" 1
  if wait_for_bind "agoo-row12" "/healthz"; then
    warmup_hit "row12" "/api/users"
    bench_wrk_row 12 "agoo_rails_api_1w" "bench/rails_api.ru" "/api/users"
  else
    echo "12,agoo_rails_api_1w,wrk,bench/rails_api.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 13: Falcon Rails API-only (1w x 5t) ----------
if want_row 13; then
  echo
  echo "=== Row 13: Falcon Rails API-only (1w x 5t) ==="
  stop_port
  boot_falcon "bench/rails_api.ru" 1
  if wait_for_bind "falcon-row13" "/healthz"; then
    warmup_hit "row13" "/api/users"
    bench_wrk_row 13 "falcon_rails_api_1w" "bench/rails_api.ru" "/api/users"
  else
    echo "13,falcon_rails_api_1w,wrk,bench/rails_api.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 14: Puma Rails API-only (1w x 5t) ----------
if want_row 14; then
  echo
  echo "=== Row 14: Puma Rails API-only (1w x 5t) ==="
  stop_port
  boot_puma "bench/rails_api.ru" 1
  if wait_for_bind "puma-row14" "/healthz"; then
    warmup_hit "row14" "/api/users"
    bench_wrk_row 14 "puma_rails_api_1w" "bench/rails_api.ru" "/api/users"
  else
    echo "14,puma_rails_api_1w,wrk,bench/rails_api.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 15: Hyperion Rails ERB (1w x 5t) ----------
if want_row 15; then
  echo
  echo "=== Row 15: Hyperion Rails ERB (1w x 5t) ==="
  stop_port
  boot_hyperion "row15" "bench/rails_erb.ru" -t 5 -w 1 -p "$PORT"
  if wait_for_bind "row15" "/healthz"; then
    warmup_hit "row15" "/page"
    bench_wrk_row 15 "hyperion_rails_erb_1w" "bench/rails_erb.ru" "/page"
  else
    echo "15,hyperion_rails_erb_1w,wrk,bench/rails_erb.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 16: Agoo Rails ERB (1w x 5t) ----------
if want_row 16; then
  echo
  echo "=== Row 16: Agoo Rails ERB (1w x 5t) ==="
  stop_port
  boot_agoo "bench/rails_erb.ru" 1
  if wait_for_bind "agoo-row16" "/healthz"; then
    warmup_hit "row16" "/page"
    bench_wrk_row 16 "agoo_rails_erb_1w" "bench/rails_erb.ru" "/page"
  else
    echo "16,agoo_rails_erb_1w,wrk,bench/rails_erb.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 17: Falcon Rails ERB (1w x 5t) ----------
if want_row 17; then
  echo
  echo "=== Row 17: Falcon Rails ERB (1w x 5t) ==="
  stop_port
  boot_falcon "bench/rails_erb.ru" 1
  if wait_for_bind "falcon-row17" "/healthz"; then
    warmup_hit "row17" "/page"
    bench_wrk_row 17 "falcon_rails_erb_1w" "bench/rails_erb.ru" "/page"
  else
    echo "17,falcon_rails_erb_1w,wrk,bench/rails_erb.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 18: Puma Rails ERB (1w x 5t) ----------
if want_row 18; then
  echo
  echo "=== Row 18: Puma Rails ERB (1w x 5t) ==="
  stop_port
  boot_puma "bench/rails_erb.ru" 1
  if wait_for_bind "puma-row18" "/healthz"; then
    warmup_hit "row18" "/page"
    bench_wrk_row 18 "puma_rails_erb_1w" "bench/rails_erb.ru" "/page"
  else
    echo "18,puma_rails_erb_1w,wrk,bench/rails_erb.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 19: Hyperion Rails AR-CRUD (1w x 5t) ----------
if want_row 19; then
  echo
  echo "=== Row 19: Hyperion Rails AR-CRUD (1w x 5t) ==="
  stop_port
  boot_hyperion "row19" "bench/rails_ar.ru" -t 5 -w 1 -p "$PORT"
  if wait_for_bind "row19" "/healthz"; then
    warmup_hit "row19" "/users.json"
    bench_wrk_row 19 "hyperion_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
  else
    echo "19,hyperion_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 20: Agoo Rails AR-CRUD (1w x 5t) ----------
if want_row 20; then
  echo
  echo "=== Row 20: Agoo Rails AR-CRUD (1w x 5t) ==="
  stop_port
  boot_agoo "bench/rails_ar.ru" 1
  if wait_for_bind "agoo-row20" "/healthz"; then
    warmup_hit "row20" "/users.json"
    bench_wrk_row 20 "agoo_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
  else
    echo "20,agoo_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 21: Falcon Rails AR-CRUD (1w x 5t) ----------
if want_row 21; then
  echo
  echo "=== Row 21: Falcon Rails AR-CRUD (1w x 5t) ==="
  stop_port
  boot_falcon "bench/rails_ar.ru" 1
  if wait_for_bind "falcon-row21" "/healthz"; then
    warmup_hit "row21" "/users.json"
    bench_wrk_row 21 "falcon_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
  else
    echo "21,falcon_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

# ---------- Row 22: Puma Rails AR-CRUD (1w x 5t) ----------
if want_row 22; then
  echo
  echo "=== Row 22: Puma Rails AR-CRUD (1w x 5t) ==="
  stop_port
  boot_puma "bench/rails_ar.ru" 1
  if wait_for_bind "puma-row22" "/healthz"; then
    warmup_hit "row22" "/users.json"
    bench_wrk_row 22 "puma_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
  else
    echo "22,puma_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
  fi
  stop_port
fi

echo
echo "============================================================"
echo "Final CSV: $OUT_CSV"
column -t -s , "$OUT_CSV"
echo "============================================================"

# Post-process: fill in the `bar` column for gated Rails rows.
# Pairs (Hyperion, Agoo) are colocated in the table:
#   API-only 1w:  rows 11 vs 12     |  4w: 23 vs 24
#   ERB      1w:  rows 15 vs 16     |  4w: 25 vs 26
#   AR-CRUD  1w:  rows 19 vs 20     |  4w: 27 vs 28
# For each pair, "pass" if Hyperion rps_med >= Agoo rps_med; "fail" otherwise.
# The Agoo row gets "ref" so it's distinguishable from a non-gated row.
fill_bar_column() {
  local tmp; tmp=$(mktemp)
  awk -F, 'BEGIN { OFS="," }
    NR == 1 { print; next }
    {
      row = $1
      rps[row] = $5
      lines[row] = $0
    }
    END {
      pairs = "11:12 15:16 19:20 23:24 25:26 27:28"
      n = split(pairs, ps, " ")
      for (i = 1; i <= n; i++) {
        split(ps[i], p, ":"); h = p[1]; a = p[2]
        if (lines[h] != "" && lines[a] != "") {
          # numeric-safe compare: treat NA / BOOT-FAIL as 0
          hr = (rps[h] + 0); ar = (rps[a] + 0)
          bar = (hr >= ar && hr > 0) ? "pass" : "fail"
          # Hyperion row gets the bar value; Agoo row gets "ref" for symmetry
          sub(/,$/, "," bar, lines[h])
          sub(/,$/, ",ref", lines[a])
        }
      }
      # Print all rows in their original order (we may not see them in 1..32 order
      # because --rows can run a subset). Iterate using the keys we collected.
      # AWK does not preserve insertion order; we sort numerically by row.
      n_rows = 0
      for (r in lines) row_keys[++n_rows] = r
      # simple insertion sort
      for (i = 2; i <= n_rows; i++) {
        v = row_keys[i]
        j = i - 1
        while (j >= 1 && (row_keys[j] + 0) > (v + 0)) {
          row_keys[j+1] = row_keys[j]
          j--
        }
        row_keys[j+1] = v
      }
      for (i = 1; i <= n_rows; i++) print lines[row_keys[i]]
    }
  ' "$OUT_CSV" > "$tmp"
  mv "$tmp" "$OUT_CSV"
}

# Print the bar-d summary block to stdout. Returns 0 if all 6 gated rows
# passed (bar d met), non-zero otherwise.
print_bar_summary() {
  echo
  echo "=================== Bar d summary ==================="
  awk -F, 'NR > 1 && ($8 == "pass" || $8 == "fail") {
    printf "row %2s  %-40s  rps=%s  %s\n", $1, $2, $5, $8
  }' "$OUT_CSV"
  echo "------------------------------------------------------"
  local pass_count fail_count
  pass_count=$(awk -F, 'NR > 1 && $8 == "pass"' "$OUT_CSV" | wc -l | tr -d ' ')
  fail_count=$(awk -F, 'NR > 1 && $8 == "fail"' "$OUT_CSV" | wc -l | tr -d ' ')
  echo "passed: $pass_count / 6 gated rows  (failed: $fail_count)"
  echo "======================================================"
  [ "$pass_count" = "6" ] && return 0 || return 1
}

fill_bar_column
print_bar_summary || true   # don't abort on bar fail; the CSV is the truth

# Render markdown table
{
  echo "# Hyperion 2.15-A bench results"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Host:      $(uname -a)"
  echo "Ruby:      $(ruby --version)"
  echo
  echo "| Row | Label | Tool | Rackup | rps (median) | p99 (median) | Bar |"
  echo "|----:|-------|------|--------|-------------:|-------------:|:---:|"
  tail -n +2 "$OUT_CSV" | while IFS=, read -r row label tool rackup rps p99 trials bar; do
    printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
      "$row" "$label" "$tool" "\`$rackup\`" "$rps" "$p99" "${bar:--}"
  done
} > "$OUT_MD"

echo
echo "Markdown table: $OUT_MD"
echo
cat "$OUT_MD"
