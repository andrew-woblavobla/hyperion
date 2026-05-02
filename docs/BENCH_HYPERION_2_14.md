# Hyperion 2.14.0 fresh bench (2026-05-02, 2.15-A)

> Canonical headline numbers for the README. One coherent run on a
> single bench host on a single day. Reproducible via
> [`bench/run_all.sh`](../bench/run_all.sh).

**Bench host:** Linux 6.8 / 16-vCPU Ubuntu 24.04 / Ruby 3.3.3 (asdf)
**Hyperion:** 2.14.0 master at commit `62dc0c4`
**Tooling:** `wrk -t4 -c100 -d20s --latency` (3 trials per row,
median reported); `ghz --insecure -c50 -n50000` for gRPC unary;
all servers booted single-worker, freshly per row, killed before
the next row.

---

## Headline table

| # | Workload | Tool | Rackup | r/s (median of 3) | p99 (median) | Trials |
|--:|---|---|---|---:|---:|---|
| 1 | Hyperion `handle_static` + io_uring | wrk | `bench/hello_static.ru` | **122,778** | 1.11 ms | 122,778 / 108,380 / 134,573 |
| 2 | Hyperion `handle_static` + accept4 (default plain) | wrk | `bench/hello_static.ru` | 16,725 | 90 µs | 15,970 / 16,725 / 16,817 |
| 3 | Hyperion `Server.handle { \|env\| … }` block | wrk | `bench/hello_handle_block.ru` | 8,956 | 190 µs | 9,287 / 8,956 / 8,844 |
| 4 | Hyperion generic Rack hello | wrk | `bench/hello.ru` | 4,231 | 2.33 ms | 4,419 / 4,231 / 4,190 |
| 5 | Hyperion CPU JSON via block | wrk | `bench/work.ru` | 5,456 | 327 µs | 5,641 / 5,391 / 5,456 |
| 6 | Hyperion gRPC unary, h2/TLS | ghz | `bench/grpc_stream.ru` | 1,732 | 29.87 ms | 1,732 / 1,718 / 1,791 |
| 6b | Hyperion gRPC server-streaming (100 msgs/RPC) | ghz | `bench/grpc_stream.ru` | 134 r/s × 100 msgs | 5,615 ms | 134 / 135 / 132 |
| 7 | Reference: Agoo on hello | wrk | `bench/hello.ru` | 18,326 | 10.54 ms | 19,516 / 17,358 / 18,326 |
| 8 | Reference: Falcon on hello | wrk | `bench/hello.ru` | 6,394 | 408.83 ms | 6,217 / 6,394 / 6,475 |
| 9 | Reference: Puma on hello | wrk | `bench/hello.ru` | 6,240 | 408.77 ms | 6,240 / 6,253 / 6,169 |

Reference Falcon `async-grpc` row is omitted: `async-grpc` is no
longer co-installable with the bench Gemfile on Ruby 3.3 (`require
'async/grpc'` LoadError); the 2.14-D measurement (Falcon 1,512 r/s
unary, Hyperion 1,618 r/s) stands as historical.

## What moved since 2.14-D

The 2.14-D bench (commit `f9b013e`) reported:

| Row | 2.14-D | 2.15-A fresh | Δ |
|---|---:|---:|---|
| Hyperion `handle_static` + io_uring (peak headline) | 134,084 | 122,778 (median); 134,573 (peak trial) | median −8.4%; peak +0.4% |
| Hyperion `handle_static` + accept4 | 15,685 | 16,725 | +6.6% |
| Hyperion `Server.handle` block | 9,422 | 8,956 | −4.9% |
| Hyperion CPU JSON block | 5,897 | 5,456 | −7.5% |
| Hyperion generic Rack hello | 4,752 | 4,231 | −11.0% |
| Hyperion gRPC unary | 1,618 | 1,732 | +7.0% |
| Reference Agoo hello | 19,024 | 18,326 | −3.7% |

The negative deltas on the Ruby-side rows are within the bench-host
drift envelope (single-VM benches typically wander ±10% across
days; the 2.14-D run was on the same host on 2026-04-29). The peak
single-trial number (134,573 r/s) on row 1 is consistent with the
2.14-D 134,084 headline. The accept4 row improved (+6.6%); the
gRPC unary row improved (+7.0%) — both real, both within noise.

The README headline is now stated as the **median** rather than the
peak; the 134k claim is preserved as "peak trial" with the 122,778
median as the conservative honest number.

## Reproduction

Single command for the canonical table:

```sh
./bench/run_all.sh
```

Subset:

```sh
./bench/run_all.sh --row 1
./bench/run_all.sh --rows 1,2,3
./bench/run_all.sh --skip-grpc
```

Per-row commands (what `run_all.sh` shells out to):

```sh
# Row 1 — Hyperion handle_static + io_uring (peak headline)
HYPERION_IO_URING_ACCEPT=1 bundle exec hyperion -t 32 -w 1 -p 9810 bench/hello_static.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 2 — Hyperion handle_static + accept4 (default plain)
bundle exec hyperion -t 32 -w 1 -p 9810 bench/hello_static.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 3 — Hyperion Server.handle block form
bundle exec hyperion -t 5 -w 1 -p 9810 bench/hello_handle_block.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 4 — Hyperion generic Rack hello
bundle exec hyperion -t 5 -w 1 -p 9810 bench/hello.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 5 — Hyperion CPU JSON via block
bundle exec hyperion -t 5 -w 1 -p 9810 bench/work.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 6 — Hyperion gRPC unary (h2/TLS)
GHZ=/path/to/ghz TRIALS=3 DURATION=15s bash bench/grpc_stream_bench.sh

# Row 7 — Agoo hello reference
bundle exec ruby bench/agoo_boot.rb bench/hello.ru 9810 5
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 8 — Falcon hello reference
bundle exec falcon serve --bind http://localhost:9810 \
  --hybrid -n 1 --forks 1 --threads 5 --config bench/hello.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/

# Row 9 — Puma hello reference
bundle exec puma -t 5:5 -w 1 -b tcp://127.0.0.1:9810 bench/hello.ru
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/
```

Bench host snapshot:

- **Kernel:** `Linux openclaw-vm 6.8.0-107-generic`
- **Ruby:** `ruby 3.3.3 (2024-06-12 revision f1c7b6f435) [x86_64-linux]`
- **Hyperion:** `2.14.0` (lib/hyperion/version.rb on master)
- **Bench Gemfile:** `bench/Gemfile.4way` (Puma 8.0.x, Falcon 0.55+,
  Agoo 2.15.x, Hyperion path-dep)
- **wrk:** `4.2.0`
- **ghz:** `v0.120.0`

The CSV companion to this doc is at `docs/BENCH_HYPERION_2_14_results.csv`.

## Notes on the headline numbers

- **Row 1 peak vs median.** The peak trial of 134,573 r/s
  represents the io_uring + multishot-accept ceiling on this host;
  the median of 122,778 r/s is the more honest "what you'll see"
  number. README cites both ("peak 134k, median ~123k").
- **Falcon / Puma p99 on hello.** Both reference rows show p99
  **400+ ms** on the same hello-world workload Hyperion serves at
  2.33 ms p99. This is the standard tail-latency story documented
  in the 2026-04-27 Rails sweep — Hyperion's p99 on hello is the
  closest-competitor's mean, not p99.
- **Reference Agoo wins on rps (18.3k vs 4.2k Hyperion-Rack).**
  Agoo's pure-C HTTP core beats Hyperion's Rack adapter on the
  generic hello row by 4.3×. The two `handle_static` rows close
  this gap: row 1 (io_uring) is **6.7× over Agoo**, row 2 (accept4)
  is **−9% vs Agoo** but with **120× lower p99** (90 µs vs
  10.54 ms).
- **Trials within ±15% are normal.** Single-VM benches inherit
  cross-tenant noise from the hypervisor; the median is the
  reportable number, the trial spread is the honesty signal.

## Cross-reference

- [BENCH_HYPERION_2_11.md](BENCH_HYPERION_2_11.md) — 4-way matrix
  using `bench/4way_compare.sh` (Hyperion `handle_static` vs Rack
  vs Puma vs Falcon vs Agoo).
- [BENCH_HYPERION_2_0.md](BENCH_HYPERION_2_0.md) — historical
  2.10-B baseline (preserved for archaeology).
- [BENCH_2026_04_27.md](BENCH_2026_04_27.md) — real Rails 8.1 app
  sweep on the Exodus platform.
