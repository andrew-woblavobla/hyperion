#!/usr/bin/env bash
# bench/cluster_distribution.sh — 2.12-E SO_REUSEPORT load-balancing audit.
#
# Boots Hyperion in cluster mode (`-w 4 -t 1`) against bench/hello_static.ru
# (`Hyperion::Server.handle_static` route — engages the 2.12-C C accept loop
# on Linux, the path most likely to expose SO_REUSEPORT imbalance because
# every request is a single-syscall write inside the kernel). Drives wrk
# at sustained load for 30s, then scrapes `/-/metrics` repeatedly until
# all 4 workers have responded at least once. Reports the per-worker
# request distribution, the mean/stddev, the max-vs-min ratio, and a
# verdict:
#
#   balanced       max/min <= 1.10   (kernel hash is doing its job)
#   mild           1.10 < max/min <= 1.50  (note in CHANGELOG; no fix)
#   severe         max/min > 1.50    (file follow-up; do NOT ship as-is)
#
# Three runs back-to-back so noise is visible; per-run verdict +
# aggregate verdict at the end.
#
# Bench host requirements: Linux 6.x (so SO_REUSEPORT distributor is
# active — Darwin uses the master-bind/worker-fd-share path which is
# documented as known-imbalanced and benched separately by the
# operator), wrk >= 4.x on PATH, jq for metric parsing, curl.
#
# Operator escape hatches via env:
#   PORT             listener port           (default 9292)
#   WORKERS          worker count            (default 4)
#   THREADS          per-worker -t value     (default 1)
#   DURATION         per-run wrk -d arg      (default 30s)
#   WRK_THREADS      wrk -t arg              (default 8)
#   WRK_CONNS        wrk -c arg              (default 200)
#   RUNS             number of runs          (default 3)
#   TOLERANCE_MILD   max/min threshold for mild verdict   (default 1.10)
#   TOLERANCE_SEVERE max/min threshold for severe verdict (default 1.50)
#   IO_URING         set =1 to opt into the 2.12-D io_uring loop
#                    (HYPERION_IO_URING_ACCEPT=1 propagates to workers)
#   ADMIN_TOKEN      bearer token for /-/metrics
#                    (default: random per-run via /dev/urandom)
#
# This script is intentionally Bash-only — the bench host doesn't need
# Ruby just to score a Hyperion bench result. All metric parsing is
# done with awk/grep so we don't pull in heavy deps.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$REPO_ROOT/Gemfile}"

# Don't pollute LC_ALL globally — LC_ALL=C breaks Ruby's UTF-8 source
# loading (rack's `[]` regex against an invalid byte sequence in a
# rackup with any non-ASCII byte). We force LC_NUMERIC=C *only on the
# awk calls* below so printf "%.3f" emits a period rather than a
# locale-dependent comma (ru_RU emits "1,000" which the verdict
# comparison parses as one thousand). Pattern: prepend `LC_NUMERIC=C`
# to each awk invocation that produces decimal numbers we read back.

PORT="${PORT:-9292}"
HOST="${HOST:-127.0.0.1}"
WORKERS="${WORKERS:-4}"
THREADS="${THREADS:-1}"
DURATION="${DURATION:-30s}"
WRK_THREADS="${WRK_THREADS:-8}"
WRK_CONNS="${WRK_CONNS:-200}"
RUNS="${RUNS:-3}"
TOLERANCE_MILD="${TOLERANCE_MILD:-1.10}"
TOLERANCE_SEVERE="${TOLERANCE_SEVERE:-1.50}"
RACKUP="${RACKUP:-bench/hello_static.ru}"
ADMIN_TOKEN="${ADMIN_TOKEN:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
LOG="/tmp/2.12-E-cluster-distribution.log"
SUMMARY="/tmp/2.12-E-cluster-distribution-summary.log"

: > "$LOG"
: > "$SUMMARY"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fatal() { log "FATAL: $*"; exit 1; }

# Validate host requirements up front so the operator hits a clean
# error message rather than a silent NaN at the end.
for tool in wrk curl awk grep sort uniq; do
  command -v "$tool" >/dev/null 2>&1 || fatal "missing required tool: $tool"
done

if [ ! -f "$REPO_ROOT/$RACKUP" ]; then
  fatal "rackup not found: $REPO_ROOT/$RACKUP"
fi

stop_port() {
  # Kill the master AND every worker. `lsof -ti tcp:$PORT` only
  # reports processes with the listening socket open — workers DO
  # share the listener (SO_REUSEPORT or fd-share), so they show up
  # too, but the master is the supervisor: killing only the workers
  # makes it respawn fresh ones into the same SO_REUSEPORT group,
  # and those then handle the next run's traffic alongside whatever
  # we boot — corrupting the per-worker request distribution
  # numbers. Match by pgrep on `bin/hyperion` so master + every
  # worker (which all carry the same exec name) goes down together.
  local pids
  pids=$(pgrep -f "[h]yperion .*-p $PORT" 2>/dev/null || true)
  if [ -z "$pids" ]; then
    pids=$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
  fi
  if [ -n "$pids" ]; then
    log "[harness] killing master+workers on port $PORT: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
    sleep 2
    # Belt-and-suspenders: any remaining LISTEN-fd holder gets a
    # second SIGKILL pass after the master had its chance to reap.
    pids=$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
    if [ -n "$pids" ]; then
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
      sleep 1
    fi
  fi
}

trap 'stop_port' EXIT INT TERM

wait_for_bind() {
  local i
  for i in $(seq 1 15); do
    sleep 1
    if curl -sS -o /dev/null --max-time 1 "http://$HOST:$PORT/" 2>/dev/null; then
      log "[harness] bound after ${i}s"
      return 0
    fi
  done
  log "[harness] FAILED to bind within 15s"
  return 1
}

# Scrape /-/metrics N times, parse out the
# `hyperion_requests_dispatch_total{worker_id="…"}` series. Each scrape
# lands on whichever worker SO_REUSEPORT routed us to; we may need
# several scrapes to enumerate all WORKERS workers. We keep the MAX
# value seen per PID — the counter is monotonic, so the largest
# observation per PID is the freshest count from that worker's
# perspective. Stops early if all WORKERS PIDs have been seen.
#
# Implementation note: macOS ships bash 3.2 which doesn't support
# `declare -A` (associative arrays). We accumulate raw `pid count` rows
# into a tmp file and let awk reduce to "max count per pid" at the
# end. One extra fork per scrape is invisible cost vs the wrk run.
#
# Output format (stdout, one row per worker PID):
#   PID COUNT
collect_distribution() {
  local seen_pids=0
  local max_attempts=$((WORKERS * 6 + 10))
  local raw
  raw=$(mktemp -t cluster_dist.XXXXXX) || return 1
  : > "$raw"
  local attempt
  for attempt in $(seq 1 "$max_attempts"); do
    local body
    body=$(curl -sS --max-time 5 \
      -H "X-Hyperion-Admin-Token: $ADMIN_TOKEN" \
      "http://$HOST:$PORT/-/metrics" 2>/dev/null) || continue

    # Extract any line shape:
    #   hyperion_requests_dispatch_total{worker_id="12345"} 67890
    # Two-step parse so the count comes from the LAST whitespace-
    # separated field of the original line, not from a field split
    # by the worker_id="" delimiter (the latter would put the closing
    # `"} 67890` chunk into the same field as the count and we'd
    # printf the wrong half). Split-then-rejoin via two awks keeps
    # the logic boring — one extracts the pid, one extracts the
    # final number; paste joins them per-line.
    paste \
      <(echo "$body" \
          | grep '^hyperion_requests_dispatch_total{worker_id="' \
          | awk -F 'worker_id="' '{ split($2, a, "\""); print a[1] }') \
      <(echo "$body" \
          | grep '^hyperion_requests_dispatch_total{worker_id="' \
          | awk '{ print $NF }') \
      >> "$raw" || true

    seen_pids=$(awk '{ print $1 }' "$raw" | sort -u | wc -l | tr -d ' ')
    if [ "$seen_pids" -ge "$WORKERS" ]; then
      break
    fi
    sleep 0.05
  done

  if [ ! -s "$raw" ]; then
    rm -f "$raw"
    return 0
  fi

  # Reduce: max count per pid (the counter is monotonic; freshest =
  # highest), then sort ascending by count for human-friendly output.
  awk '
    {
      if (!($1 in best) || $2 > best[$1]) best[$1] = $2
    }
    END {
      for (p in best) printf "%s %s\n", p, best[p]
    }
  ' "$raw" | sort -k2 -n

  rm -f "$raw"
}

# Compute stats for a list of "PID COUNT" rows passed on stdin.
# Emits: workers_seen, total, mean, stddev, min, max, ratio (max/min),
#        per-worker share (count/total).
analyze_distribution() {
  LC_NUMERIC=C awk -v workers="$WORKERS" '
    {
      pid[NR] = $1
      cnt[NR] = $2
      total += $2
      n++
      if (NR == 1 || $2 < min) min = $2
      if (NR == 1 || $2 > max) max = $2
    }
    END {
      if (n == 0) {
        printf "ERROR: no workers observed (scrape failed?)\n"
        exit 1
      }
      mean = total / n
      ssum = 0
      for (i = 1; i <= n; i++) {
        d = cnt[i] - mean
        ssum += d * d
      }
      stddev = sqrt(ssum / n)
      ratio = (min > 0) ? (max / min) : 999.99
      printf "workers_seen=%d expected=%d total=%d\n", n, workers, total
      printf "min=%d max=%d mean=%.1f stddev=%.1f ratio=%.3f\n", min, max, mean, stddev, ratio
      for (i = 1; i <= n; i++) {
        printf "  worker pid=%s requests=%d share=%.2f%%\n", pid[i], cnt[i], (cnt[i] * 100.0 / total)
      }
    }
  '
}

# Compute the verdict for a single ratio (numeric awk comparison).
verdict_for_ratio() {
  local ratio="$1"
  LC_NUMERIC=C awk -v r="$ratio" -v mild="$TOLERANCE_MILD" -v severe="$TOLERANCE_SEVERE" '
    BEGIN {
      if (r <= mild) print "balanced"
      else if (r <= severe) print "mild"
      else print "severe"
    }
  '
}

# Reset per-worker counters between runs by SIGUSR1 the workers — but
# Hyperion has no metrics-reset signal. Easiest reset: respawn the
# whole cluster between runs. Cost: ~3s of boot per run. Acceptable
# for the audit.

run_one() {
  local run="$1"
  log
  log "=== run $run/$RUNS ==="
  stop_port

  # Build the boot command. `setsid nohup … & disown` is the pattern
  # documented in the ticket header — keeps the cluster alive after
  # the harness shell exits, important when the harness is invoked
  # over ssh.
  local boot_log="/tmp/2.12-E-hyperion-run-${run}.log"
  : > "$boot_log"

  local extra_env=()
  if [ "${IO_URING:-0}" = "1" ]; then
    extra_env+=(HYPERION_IO_URING_ACCEPT=1)
  fi

  log "[harness] cmd: bundle exec hyperion -w $WORKERS -t $THREADS -p $PORT --admin-token=*** $RACKUP"
  # `set -u` + `${arr[@]}` on an empty array errors on bash <4.4 / macOS.
  # `${arr[@]+"${arr[@]}"}` is the safe expansion that yields nothing
  # when the array is empty and the original element list otherwise.
  #
  # `setsid` is Linux-canonical for "leave the harness's controlling
  # terminal" so the cluster survives the harness shell exiting (which
  # matters when the harness is invoked via ssh + the connection drops
  # mid-bench). Darwin doesn't ship setsid by default; fall back to
  # plain `nohup` there — `disown` plus stdin redirection is enough
  # for local validation. The bench HOST (Linux) takes the setsid
  # branch, which is the path the audit number actually relies on.
  local prefix=()
  if command -v setsid >/dev/null 2>&1; then
    prefix=(setsid nohup)
  else
    prefix=(nohup)
  fi

  (
    cd "$REPO_ROOT" || exit 1
    # shellcheck disable=SC2086
    env ${extra_env[@]+"${extra_env[@]}"} \
      "${prefix[@]}" \
      bundle exec hyperion \
        -w "$WORKERS" -t "$THREADS" -p "$PORT" \
        --admin-token "$ADMIN_TOKEN" \
        "$RACKUP" \
      > "$boot_log" 2>&1 < /dev/null &
    disown
  )

  if ! wait_for_bind; then
    log "[harness] BOOT-FAILURE — boot log tail:"
    tail -40 "$boot_log" | tee -a "$LOG"
    stop_port
    return 1
  fi

  # Smoke a single 200 to confirm the static route serves before we
  # trust the bench result.
  local smoke_code
  smoke_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
    "http://$HOST:$PORT/")
  log "[harness] smoke GET / -> HTTP $smoke_code"
  if [ "$smoke_code" != "200" ]; then
    log "[harness] SMOKE-FAILURE (non-200) — aborting run"
    tail -40 "$boot_log" | tee -a "$LOG"
    stop_port
    return 1
  fi

  log "[harness] starting wrk: -t$WRK_THREADS -c$WRK_CONNS -d$DURATION http://$HOST:$PORT/"
  local wrk_out
  wrk_out=$(wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"$DURATION" --latency \
    "http://$HOST:$PORT/" 2>&1)
  echo "$wrk_out" | tee -a "$LOG"

  local rps
  rps=$(echo "$wrk_out" | awk '/Requests\/sec:/ { print $2 }')
  log "[harness] wrk rps=$rps"

  log "[harness] gathering /-/metrics from each worker via repeated SO_REUSEPORT scrape…"
  local distribution
  distribution=$(collect_distribution)
  if [ -z "$distribution" ]; then
    log "[harness] FAILED to gather metrics distribution"
    stop_port
    return 1
  fi

  log "[harness] raw distribution (pid count):"
  echo "$distribution" | sed 's/^/    /' | tee -a "$LOG"

  log "[harness] analysis:"
  local stats
  stats=$(echo "$distribution" | analyze_distribution)
  echo "$stats" | tee -a "$LOG"

  local ratio
  ratio=$(echo "$stats" | awk '/^min=/ { for (i=1;i<=NF;i++) if ($i ~ /^ratio=/) print substr($i, 7) }')
  local verdict
  verdict=$(verdict_for_ratio "$ratio")
  log "[harness] run $run verdict: $verdict (max/min=$ratio, threshold mild=$TOLERANCE_MILD severe=$TOLERANCE_SEVERE)"

  printf 'run=%d rps=%s ratio=%s verdict=%s\n' "$run" "$rps" "$ratio" "$verdict" >> "$SUMMARY"

  # Graceful shutdown so the next run starts clean.
  stop_port
}

log "=== 2.12-E SO_REUSEPORT load-balancing audit ==="
log "host=$(uname -a)"
log "ruby=$(ruby --version 2>/dev/null || echo unknown)"
log "workers=$WORKERS threads=$THREADS port=$PORT duration=$DURATION runs=$RUNS"

for run in $(seq 1 "$RUNS"); do
  run_one "$run" || log "[harness] run $run errored — continuing to next run"
done

log
log "============================================================"
log "=== SUMMARY ==="
cat "$SUMMARY" | tee -a "$LOG"
log "============================================================"

# Aggregate verdict: take the WORST verdict across runs (one severe
# run is enough to fail the audit).
agg_verdict="balanced"
while read -r row; do
  v=$(echo "$row" | awk -F 'verdict=' '{print $2}')
  case "$v" in
    severe) agg_verdict="severe" ;;
    mild)
      [ "$agg_verdict" != "severe" ] && agg_verdict="mild"
      ;;
  esac
done < "$SUMMARY"

log "Aggregate verdict across $RUNS runs: $agg_verdict"
log "Full log at: $LOG"
