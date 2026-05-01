# Hyperion

High-performance Ruby HTTP server. Falcon-class fiber concurrency, Puma-class compatibility.

[![CI](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml/badge.svg)](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/hyperion-rb.svg)](https://rubygems.org/gems/hyperion-rb)
[![License: MIT](https://img.shields.io/github/license/andrew-woblavobla/hyperion.svg)](https://github.com/andrew-woblavobla/hyperion/blob/master/LICENSE)

```sh
gem install hyperion-rb
bundle exec hyperion config.ru
```

## What's new in 2.11.0

**h2 cold-stream latency cut + native HPACK CGlue flipped to default.**
Two perf wins on top of 2.10:

- **2.11-A — h2 first-stream TLS handshake parallelization.** The
  2.10-G `HYPERION_H2_TIMING=1` instrumentation, run against the
  TCP_NODELAY-fixed handler, isolated the residual cold-stream cost
  to **bucket 2**: lazy `task.async {}` fiber spawn for the first
  stream of every connection. Fix: pre-spawn a stream-dispatch fiber
  pool at connection accept (configurable via `HYPERION_H2_DISPATCH_POOL`,
  default 4, ceiling 16). h2load `-c 1 -m 1 -n 50` cold first-run:
  **time-to-1st-byte 20.28 → 9.28 ms (−54%); m=100 throughput +5.5%**.
  Warm steady-state unchanged (no head-of-line blocking under the small
  pool — backlog still spills to ad-hoc `task.async`).
- **2.11-B — HPACK FFI marshalling round-2 (CGlue flipped to default).**
  Three-way bench (`bench/h2_rails_shape.sh` extended): `ruby` (1,585
  r/s) vs `native v2` (1,602 r/s, +1% — noise) vs `native v3 / CGlue`
  (**2,291 r/s, +43% over v2**). The +18-44% native-vs-Ruby headline
  was almost entirely Fiddle marshalling overhead, not the underlying
  Rust HPACK encoder — same encoder, no per-call FFI marshalling, +43%
  rps. Default flipped: unset `HYPERION_H2_NATIVE_HPACK` now selects
  CGlue. Three escape valves stay (`=v2` to force the old path, `=ruby`
  / `=off` for the pure-Ruby fallback) for any operator that needs
  them. Boot log gains a `native_mode` field documenting which path is
  actually live.

Plus operator infrastructure: a stale-`.dylib`-on-Linux cross-platform
host-OS portability fix in `H2Codec.candidate_paths` (was silently
falling through to pure-Ruby on the bench host); `bench/h2_rails_shape.sh`
race-fixed (boot-log probe + stderr routing). Full bench tables and
flip-decision rationale in [`CHANGELOG.md`](CHANGELOG.md).

## What's new in 2.10.1

**Static-asset operator surface (2.10-E) + C-ext fast-path response
writer (2.10-F).** Two follow-on streams to 2.10's static / direct-route
work:

- **2.10-E — Static asset preload + immutable flag.** Boot-time hook
  warms `Hyperion::Http::PageCache` over a tree of files and marks
  every cached entry immutable. Surface: `--preload-static <dir>` (and
  `--no-preload-static`) CLI flags, `preload_static "/path", immutable:
  true` config DSL key, and zero-config Rails auto-detect that pulls
  `Rails.configuration.assets.paths.first(8)` when present. Hyperion
  never `require`s Rails — purely defensive `defined?(::Rails)`
  probing keeps the generic Rack server path clean. **Operator value:
  predictable first-request latency** (the asset is in cache before
  the first request arrives) and the `recheck_seconds` mtime poll is
  skipped on immutable entries. Sustained-load throughput on the
  static-1-KB bench did *not* move (cold 1,929 r/s vs warm 1,886 r/s,
  inside trial noise) because `ResponseWriter` already auto-caches
  Rack::Files responses on the first hit; preload moves that one
  `cache_file` call from request 1 to boot.
- **2.10-F — C-ext fast-path response writer for prebuilt responses.**
  `Server.handle_static`-routed requests now serve from a single
  C function (`rb_pc_serve_request` in `ext/hyperion_http/page_cache.c`)
  that does route lookup → header build → `write()` syscall without
  re-entering Ruby on the response side. GVL is released across the
  `write()` so slow clients no longer block other Ruby work on the
  same VM. Automatic HEAD support (HTTP-mandated) lights up on every
  GET registered via `handle_static` — same buffer, body stripped.
  Bench (3-trial median, `wrk -t4 -c100 -d20s`): **5,768 r/s vs
  2.10-D's 5,619 r/s (+2.6% — inside noise) and p99 1.93 → 1.67 ms
  (−14% — outside noise, reproducible).** The throughput needle didn't
  move because the per-connection lifecycle (accept4 + clone3 + futex
  on GVL handoff) dominates at 100 concurrent connections; 2.10-F
  shrinks the response phase, but the response phase isn't the
  bottleneck on this profile. Durable infrastructure for 2.11+ when
  the accept-loop work closes.

Full per-stream details and bench tables in
[`CHANGELOG.md`](CHANGELOG.md).

## What's new in 2.10.0

**4-way bench harness, page cache, direct routes, and the h2 40 ms
ceiling killed.** This sprint widens the comparison matrix to all four
major Ruby web servers (Hyperion + Puma + Falcon + Agoo) and ships
four substantive perf streams against that backdrop:

- **2.10-A / 2.10-B — 4-way bench harness + honest baseline.**
  `bench/4way_compare.sh` runs the same 6 workloads (hello, static
  1 KB / 1 MiB, CPU JSON, PG-bound, SSE) against all four servers from
  one script. Baseline numbers committed *before* any code changes:
  Agoo wins the static-asset and JSON columns by ~2-4×, Hyperion wins
  the static 1 MiB column by 9× and the SSE column by 3.6-17×.
- **2.10-C — `Hyperion::Http::PageCache` (pre-built static response
  cache).** Open-addressed bucket table behind a pthread mutex
  (GVL-released for writes), engages automatically on `Rack::Files`
  responses. **Static 1 KB: 1,380 → 1,880 r/s (+36%), p99 3.7 → 2.7
  ms.** Closes the Agoo gap from −47% to −28% on that column.
- **2.10-D — `Hyperion::Server.handle` direct route registration.**
  New API for hot Rack-bypass paths (`Server.handle '/health' do …
  end`, `Server.handle_static '/robots.txt', body: '...'`). Skips Rack
  adapter + env-build for matched routes. **`hello` via
  `handle_static`: 4,408 → 5,619 r/s (+27%), p99 1.93 ms** — the
  cleanest p99 in the 4-way matrix.
- **2.10-G — h2 max-latency ceiling at ~40 ms: fixed.** Filed by 2.9-B
  as a "first-stream cost" hypothesis, the instrumentation revealed
  it was paid by *every* h2 stream — the canonical Linux delayed-ACK
  + Nagle interaction on small framer writes. One-line fix:
  TCP_NODELAY at accept time. **h2load `-c 1 -m 1 -n 200`: min
  40.62 → 0.54 ms (−98.7%), throughput 24 → 1,142 r/s (+47.6×).** The
  `HYPERION_H2_TIMING=1` instrumentation stays in place as durable
  diagnostic infrastructure.

Full per-stream details, bench numbers, and follow-up items live in
[`CHANGELOG.md`](CHANGELOG.md).

## What's new in 2.5.0

**Native HPACK ON by default + autobahn 100% conformance + request
hooks.** The Rust HPACK encoder (added in 2.0.0, opt-in until 2.4.x)
flips ON by default in 2.5.0 — verified **+18% rps on Rails-shape h2
workloads** (25-header responses, the bench harness lives at
`bench/h2_rails_shape.ru` + `bench/h2_rails_shape.sh`). RFC 6455
WebSocket conformance hit **463/463 autobahn-testsuite cases passing**
(2.5-A, host openclaw-vm). Request lifecycle hooks
(`Runtime#on_request_start` / `on_request_end`) shipped in 2.5-C —
recipes in [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

## What's new in 2.4.0

**Production observability.** The `/-/metrics` endpoint now exposes
per-route latency histograms, per-conn fairness rejections, WebSocket
permessage-deflate compression ratio, kTLS active connections,
io_uring-active workers, and ThreadPool queue depth — operators can
finally see whether the 2.x knobs are firing and how effective they
are. A pre-built Grafana dashboard ships at
[`docs/grafana/hyperion-2.4-dashboard.json`](docs/grafana/hyperion-2.4-dashboard.json).
Full metric reference + operator playbook in
[`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

## What's new in 2.1.0

**WebSockets.** RFC 6455 over Rack 3 full hijack, native frame codec,
per-connection wrapper with auto-pong / close handshake / UTF-8 validation /
per-message size cap. **ActionCable on Hyperion is now a single-binary
deployment** — one `hyperion -w 4 -t 10 config.ru` process serves HTTP,
HTTP/2, TLS, **and** `/cable` from the same listener; no separate cable
container required. HTTP/1.1 only this release; WS-over-HTTP/2 (RFC 8441
Extended CONNECT) and permessage-deflate (RFC 7692) defer to 2.2.x.
See [`docs/WEBSOCKETS.md`](docs/WEBSOCKETS.md).

## Highlights

- **HTTP/1.1 + HTTP/2 + TLS** out of the box (HTTP/2 with per-stream fiber multiplexing, WINDOW_UPDATE-aware flow control, ALPN auto-negotiation).
- **WebSockets (RFC 6455)** — full handshake, native frame codec, per-connection wrapper. ActionCable + faye-websocket work on a single-binary deploy. See [`docs/WEBSOCKETS.md`](docs/WEBSOCKETS.md). (2.1.0+, HTTP/1.1 only.)
- **Pre-fork cluster** with per-OS worker model: `SO_REUSEPORT` on Linux, master-bind + worker-fd-share on macOS/BSD (Darwin's `SO_REUSEPORT` doesn't load-balance).
- **Hybrid concurrency**: fiber-per-connection for I/O, OS-thread pool for `app.call(env)` — synchronous Rack handlers (Rails, ActiveRecord, anything holding a global mutex) get true OS-thread concurrency.
- **Vendored llhttp 9.3.0** C parser; pure-Ruby fallback for non-MRI runtimes.
- **Default-ON structured access logs** (one JSON or text line per request) with hot-path optimisations: per-thread cached timestamp, hand-rolled line builder, lock-free per-thread write buffer.
- **12-factor logger split**: info/debug → stdout, warn/error/fatal → stderr.
- **Ruby DSL config file** (`config/hyperion.rb`) with lifecycle hooks (`before_fork`, `on_worker_boot`, `on_worker_shutdown`).
- **Object pooling** for the Rack `env` hash and `rack.input` IO — amortizes per-request allocations across the worker's lifetime.
- **`Hyperion::FiberLocal`** opt-in shim for older Rails idioms that store request-scoped data via `Thread.current.thread_variable_*`.

## Benchmarks

All numbers are real wrk runs against published Hyperion configs. Hyperion ships **with default-ON structured access logs**; Puma comparisons use Puma defaults (no per-request log emission). Each section is stamped with the Hyperion version + bench host it was measured against — bench-host drift over time is real (see "Bench-host drift" note below).

**Headline doc**: the most recent comprehensive sweep is
[`docs/BENCH_HYPERION_2_0.md`](docs/BENCH_HYPERION_2_0.md) (Hyperion
2.0.0 vs Puma 8.0.1, 16-vCPU Ubuntu 24.04, 12 workloads). The 1.6.0
matrix at [`docs/BENCH_2026_04_27.md`](docs/BENCH_2026_04_27.md) covers
9 workloads × 25+ configs against hyperion-async-pg 0.5.0; both docs
include caveats and per-row reproduction commands.

> **Bench-host drift note (2026-05-01).** A spot-check rerun on
> `openclaw-vm` 5 days after the 2.0.0 sweep showed Puma 8.0.1 and
> Hyperion 2.0.0 baseline numbers had drifted 14-32% downward from the
> 2026-04-29 sweep with no code changes — the bench host runs other
> workloads in the background and is a single VM (KVM CPU). Numbers in
> this README and BENCH docs are snapshots; expect ±10-30% absolute
> drift between sweep dates. **The relative position (Hyperion vs Puma
> at matched config) is the durable signal**; e.g. Hyperion `-w 16 -t 5`
> hello-world today is 76,593 r/s vs Puma 8.0.1 `-w 16 -t 5:5` at 55,609
> r/s, **+37.7% over Puma** — wider than the 2.0.0 sweep's +27.8% even
> though absolute rps is lower. Reproduce: `bundle exec bin/hyperion
> -p 9501 -w 16 -t 5 bench/hello.ru` then `wrk -t4 -c200 -d20s
> http://127.0.0.1:9501/`.

> **Topology relevance.** Hyperion is built to run **fronted by nginx
> or an L7 load balancer** in most production deployments — plaintext
> HTTP/1.1 upstream, TLS terminated at the LB. The benches in this
> README that match that topology are: hello-world, CPU JSON, static,
> SSE, PG, WebSocket. Benches that are **bench-only for nginx-fronted
> ops** (the LB → upstream hop is plaintext h1 regardless): TLS h1,
> HTTP/2, kTLS_TX. Those rows still ship for operators who terminate
> TLS / h2 at Hyperion directly (small static fleets, edge boxes), but
> don't chase the +60% TLS-h1 win unless you actually terminate TLS at
> Hyperion.

### Hello-world Rack app

`bench/hello.ru`, single worker, parity threads (`-t 5` vs Puma `-t 5:5`), 4 wrk threads / 100 connections / 15s, macOS arm64 / Ruby 3.3.3, Hyperion 1.2.0. **macOS dev numbers; the headline Linux 2.0.0 bench is in [`docs/BENCH_HYPERION_2_0.md`](docs/BENCH_HYPERION_2_0.md)**:

| | r/s | p99 | tail vs Hyperion |
|---|---:|---:|---:|
| **Hyperion 1.2.0** (default, logs ON) | **22,496** | **502 µs** | **1×** |
| Falcon 0.55.3 `--count 1` | 22,199 | 5.36 ms | 11× worse |
| Puma 7.1.0 `-t 5:5` | 20,400 | 422.85 ms | 845× worse |

**Hyperion: 1.10× Puma throughput, parity with Falcon on throughput, ~10× lower p99 than Falcon and ~845× lower than Puma — while emitting structured JSON access logs the others don't.**

### Production cluster config (`-w 4`)

Same bench app, `-w 4` cluster, parity threads (`-t 5` everywhere), 4 wrk threads / 200 connections / 15s, macOS arm64:

| | r/s | p99 | tail vs Hyperion |
|---|---:|---:|---:|
| Falcon `--count 4` | 48,197 | 4.84 ms | 5.9× worse |
| **Hyperion `-w 4 -t 5`** | **40,137** | **825 µs** | **1×** |
| Puma `-w 4 -t 5:5` | 34,793 | 177.76 ms | 215× worse (1 timeout) |

Falcon edges Hyperion ~20% on raw rps at `-w 4` on macOS hello-world. **Hyperion still leads on tail latency by 5.9× over Falcon and 215× over Puma**, and beats Puma on throughput by 1.15×. On Linux production-config and DB-backed workloads (below) Hyperion takes the rps lead too — the macOS hello-world advantage to Falcon disappears once the workload includes any actual work or the kernel is Linux.

### Linux production-config (DB-backed Rack)

`-w 4 -t 10` on Ubuntu 24.04 / Ruby 3.3.3. Rack app does one Postgres `SELECT 1` + one Redis `GET` per request, real network round-trip. wrk `-t4 -c50 -d10s` × 3 runs (median):

| | r/s (median) | vs Puma default |
|---|---:|---:|
| **Hyperion default (rc17, logs ON)** | **5,786** | **1.012×** |
| Hyperion `--no-log-requests` | 6,364 | 1.114× |
| Puma `-w 4 -t 10:10` (no per-req logs) | 5,715 | 1.000× |

Bench is **wait-bound** — ~3-4 ms median is the PG + Redis round-trip, dwarfing the per-request CPU work where Hyperion's optimisations live. With a synchronous `pg` driver, fibers don't help: every in-flight DB call still parks an OS thread, and both servers max out at `workers × threads` concurrent queries. To widen this gap requires either an async PG driver — see [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg) (companion gem; pair with `--async-io` and a fiber-aware pool, see "Async I/O — fiber concurrency on PG-bound apps" below) — or a CPU-bound workload, where Hyperion's lead becomes visible (next section).

### Async I/O — fiber concurrency on PG-bound apps

Ubuntu 24.04 / 16 vCPU / Ruby 3.3.3, Postgres 17 over WAN, `wrk -t4 -c200 -d20s`. Single worker (`-w 1`) unless noted. All configs returned 0 non-2xx and 0 timeouts. RSS sampled mid-run via `ps -o rss`.

**Wait-bound workload** (`pg_concurrent.ru`: `SELECT pg_sleep(0.05)` + tiny JSON; rackup lives in the [hyperion-async-pg companion repo](https://github.com/andrew-woblavobla/hyperion-async-pg) and on the bench host at `~/bench/pg_concurrent.ru`, not in this repo):

| | r/s | p99 | RSS | vs Puma `-t 5` |
|---|---:|---:|---:|---:|
| Puma 8.0 `-t 5` pool=5 | 56.5 | 3.88 s | 87 MB | 1.0× |
| Puma 8.0 `-t 30` pool=30 | 402.1 | 880 ms | 99 MB | 7.1× |
| Puma 8.0 `-t 100` pool=100 | 1067.4 | 557 ms | 121 MB | 18.9× |
| **Hyperion `--async-io -t 5`** pool=32 | 400.4 | 878 ms | 123 MB | 7.1× |
| **Hyperion `--async-io -t 5`** pool=64 | 778.9 | 638 ms | 133 MB | 13.8× |
| **Hyperion `--async-io -t 5`** pool=128 | 1344.2 | 536 ms | 148 MB | 23.8× |
| **Hyperion `--async-io -t 5` pool=200** | **2381.4** | **471 ms** | **164 MB** | **42.2×** |
| Hyperion `--async-io -w 4 -t 5` pool=64 | 1937.5 | 4.84 s | 416 MB | 34.3× (cold-start p99 — see note) |
| Falcon 0.55.3 `--count 1` pool=128 | 1665.7 | 516 ms | 141 MB | 29.5× |

**Mixed CPU+wait** (`pg_mixed.ru`: same query + 50-key JSON serialization, ~5 ms CPU; rackup lives in hyperion-async-pg + on the bench host at `~/bench/pg_mixed.ru`, not in this repo):

| | r/s | p99 | RSS | vs Puma `-t 30` |
|---|---:|---:|---:|---:|
| Puma 8.0 `-t 30` pool=30 | 351.7 | 963 ms | 127 MB | 1.0× |
| Hyperion `--async-io -t 5` pool=32 | 371.2 | 919 ms | 151 MB | 1.05× |
| Hyperion `--async-io -t 5` pool=64 | 741.5 | 681 ms | 161 MB | 2.1× |
| **Hyperion `--async-io -t 5` pool=128** | **1739.9** | **512 ms** | **201 MB** | **4.9×** |
| Falcon `--count 1` pool=128 | 1642.1 | 531 ms | 213 MB | 4.7× |

**Takeaways:**
1. **Linear scaling with pool size** under `--async-io` — `r/s ≈ pool × 12` on this WAN bench. Single-worker pool=200 hits 2381 r/s. The "**42× Puma `-t 5`**" and "**5.9× Puma's best**" framings above use Puma's pool=5 (timeout-floor) and pool=30 (mid-tier) rows respectively — fair comparisons on the *same* bench fixture, but a Puma operator who sizes their pool to match (`-t 100 pool=100` row above) lands at 1,067 r/s, so the **honest "Puma at its own best vs Hyperion at its own best" ratio is 2,381 / 1,067 ≈ 2.2×**, not 42×. The architectural win — fiber-pool grows to pool=200 without OS-thread cost — is real; the 42× headline is a configuration-difference effect, not a steady-state gap on matched configs.
2. **Mixed workload doesn't kill the win** — Hyperion `--async-io` pool=128 actually goes *up* on mixed (1740 vs 1344 r/s) because CPU work overlaps other fibers' PG-wait windows. This is the honest "what happens to a real Rails handler" answer.
3. **Hyperion ≈ Falcon within 3-7%** across pool sizes; both fiber-native architectures extract similar value from `hyperion-async-pg`.
4. **RSS at single-worker scale isn't the architectural moat** — Linux thread stacks are demand-paged; PG connection buffers dominate RSS at pool sizes ≤ 200. The architectural win is **handler concurrency under load**, not idle memory: Hyperion's fiber path runs thousands of in-flight handler invocations per OS thread, so wait-bound handlers don't queue at `max_threads`. See [Concurrency at scale](#concurrency-at-scale-architectural-advantages) for both the throughput-under-load row and a measured 10k-idle-keepalive RSS sweep against Puma and Falcon.
5. **`-w 4` cold-start caveat** — multi-worker p99 inflates because the bench rackup uses lazy per-process pool init (each worker pays full pool fill on its first request). Production apps avoid this with `on_worker_boot { Hyperion::AsyncPg::FiberPool.new(...).fill }`.
6. **Apples-to-apples PG note**: the row above uses `pg.wobla.space` WAN PG with `max_connections=500`. Earlier sweeps that compared Hyperion (WAN, max_conn=500) against Puma (local, max_conn=100) overstated the ratio because the Puma side timed out at the local pool ceiling. The 2.0.0 bench doc carries this caveat in the row 7 verification section; treat any "Hyperion 4× Puma on PG" headline as **indicative**, not precisely calibrated, until rerun against matched-pool PG.

Three things must all be true to get this win:
1. **`async_io: true`** in your Hyperion config (or `--async-io` CLI flag). Default is off to keep 1.2.0's raw-loop perf for fiber-unaware apps.
2. **`hyperion-async-pg`** installed: `gem 'hyperion-async-pg', require: 'hyperion/async_pg'` + `Hyperion::AsyncPg.install!` at boot.
3. **Fiber-aware connection pool.** The popular `connection_pool` gem is NOT — its Mutex blocks the OS thread. Use `Hyperion::AsyncPg::FiberPool` (ships with hyperion-async-pg 0.3.0+), [`async-pool`](https://github.com/socketry/async-pool), or `Async::Semaphore`.

Skip any of these and you get parity with Puma at the same `-t`. Run the bench yourself: `MODE=async DATABASE_URL=... PG_POOL_SIZE=200 bundle exec hyperion --async-io -t 5 bench/pg_concurrent.ru` (in the [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg) repo).

> **TLS + async-pg note (1.4.0+).** TLS / HTTPS already runs each connection on a fiber under `Async::Scheduler` (the TLS path always uses `start_async_loop` for the ALPN handshake). **As of 1.4.0, the post-handshake `app.call` for HTTP/1.1-over-TLS dispatches inline on the calling fiber by default** — so fiber-cooperative libraries (`hyperion-async-pg`, `async-redis`) work on the TLS h1 path without needing `--async-io`. The Async-loop cost is already paid for the handshake; running the handler under the existing scheduler just preserves that context instead of stripping it on a thread-pool hop. h2 streams are always fiber-dispatched and benefit from async-pg without the flag.
>
> Operators who specifically want **TLS + threadpool dispatch** (e.g. CPU-heavy handlers competing for OS threads, where you'd rather not pay fiber yields and want true OS-thread parallelism on a synchronous handler) can pass `async_io: false` in the config to force the pool branch back on. The three-way `async_io` setting:
> - `nil` (default): plain HTTP/1.1 → pool, TLS h1 → inline.
> - `true`: plain HTTP/1.1 → inline, TLS h1 → inline (force fiber dispatch everywhere; needed for `hyperion-async-pg` on plain HTTP).
> - `false`: plain HTTP/1.1 → pool, TLS h1 → pool (explicit opt-out for TLS+threadpool).

### CPU-bound JSON workload

`bench/work.ru` — handler builds a 50-key fixture, JSON-encodes a fresh response per request (~8 KB body), processes a 6-cookie header chain. wrk `-t4 -c200 -d15s`, macOS arm64 / Ruby 3.3.3, 1.2.0:

| | r/s | p99 | tail vs Hyperion |
|---|---:|---:|---:|
| Falcon `--count 4` | 46,166 | 20.17 ms | 24× worse |
| **Hyperion `-w 4 -t 5`** | **43,924** | **824 µs** | **1×** |
| Puma `-w 4 -t 5:5` | 36,383 | 166.30 ms (47 socket errors) | 200× worse |

**1.21× Puma throughput, 200× lower p99.** This is the gap that hides behind PG-round-trip noise on the DB bench. Hyperion's per-request CPU savings (lock-free per-thread metrics, frozen header keys in the Rack adapter, C-ext response head builder, cached iso8601 timestamps, cached HTTP Date header) land on the wire when the workload is CPU-bound. Falcon edges us 5% on raw r/s but with 24× worse tail — a different tradeoff curve. Reproduce: `bundle exec bin/hyperion -w 4 -t 5 -p 9292 bench/work.ru`.

### Real Rails 8.1 app (single worker, parity threads `-t 16`)

Health endpoint that traverses the full middleware chain (rack-attack, locale redirect, structured tagger, geo-location, etc.). Plus a Grape API endpoint reading cached data, and a Rails controller doing a Redis GET + an ActiveRecord query.

| endpoint | server | r/s | p99 | wrk timeouts |
|---|---|---:|---:|---:|
| `/up` (health) | **Hyperion** | **19.03** | **1.12 s** | **0** |
| `/up` (health) | Puma `-t 16:16` | 16.64 | 1.95 s | **138** |
| Grape `/api/v1/cached_data` | **Hyperion** | **16.15** | **779 ms** | 16 |
| Grape `/api/v1/cached_data` | Puma `-t 16:16` | 10.90 | (>2 s, censored) | **110** |
| Rails `/api/v1/health` | **Hyperion** | **15.95** | **992 ms** | 16 |
| Rails `/api/v1/health` | Puma `-t 16:16` | 11.29 | (>2 s, censored) | **114** |

On Grape and Rails-controller workloads Puma hits wrk's 2 s timeout cap on ~⅔ of requests — its real p99 is censored above 2 s. Hyperion serves all of its requests under 1.2 s with 0 to 16 timeouts. **1.14–1.48× Puma throughput** depending on endpoint.

### Static-asset serving (sendfile zero-copy path, 1.2.0+)

`bench/static.ru` (`Rack::Files` over a 1 MiB asset), `-w 1`, `wrk -t4 -c100 -d15s`, macOS arm64 / Ruby 3.3.3:

| | r/s | p99 | transferred | tail vs winner |
|---|---:|---:|---:|---:|
| **Hyperion (sendfile path)** | **2,069** | **3.10 ms** | 30.4 GB | **1×** |
| Puma `-w 1 -t 5:5` | 2,109 | 566.16 ms | 31.0 GB | 183× worse |
| Falcon `--count 1` | 1,269 | 801.01 ms | 18.7 GB | 258× worse (28 timeouts) |

Throughput is bandwidth-bound on localhost (≈2 GB/s = the loopback memory ceiling), so the throughput column looks like parity. The actual win is in the **tail latency** column: Hyperion's `IO.copy_stream` → `sendfile(2)` path skips userspace entirely, while Puma allocates a String per response and Falcon serializes more aggressively. On real network paths sendfile widens the gap further (kernel-to-NIC zero-copy).

Reproduce:
```sh
ruby -e 'File.binwrite("/tmp/hyperion_bench_asset_1m.bin", "x" * (1024*1024))'
bundle exec bin/hyperion -p 9292 bench/static.ru
wrk --latency -t4 -c100 -d15s http://127.0.0.1:9292/hyperion_bench_asset_1m.bin
```

### Concurrency at scale (architectural advantages)

These workloads demonstrate structural differences between Hyperion's fiber-per-connection / fiber-per-stream model and Puma's thread-pool model. Numbers are illustrative; the architecture is what matters. Run on Ubuntu 24.04 / Ruby 3.3.3, single worker, h2load `-c <conns> -n 100000 --rps 1000 --h1`.

**5,000 concurrent keep-alive connections (50,000 requests):**

| | succeeded | r/s | wall | master RSS |
|---|---:|---:|---:|---:|
| Hyperion `-w 1 -t 10` | 50,000 / 50,000 | 3,460 | 14.45 s | 53.5 MB |
| Puma `-w 1 -t 10:10`  | 50,000 / 50,000 | 1,762 | 28.37 s | 36.9 MB |

**10,000 concurrent keep-alive connections (100,000 requests):**

| | succeeded | failed | r/s | wall |
|---|---:|---:|---:|---:|
| Hyperion `-w 1 -t 10` | 93,090 | 6,910 | 3,446 | 27.01 s |
| Puma `-w 1 -t 10:10`  | 77,340 | 22,660 | 706 | 109.59 s |

At 10k concurrent connections under load Hyperion serves **~5× the throughput** of Puma with **~20% fewer dropped requests**. The per-connection bookkeeping cost is bounded by fiber size, not by `max_threads` — workers don't get pinned to long-lived sockets, so a slow handler doesn't starve other connections.

**Memory at idle keep-alive scale — 10,000 idle HTTP/1.1 keep-alive connections:**

Each client opens a TCP connection, sends one keep-alive GET, drains the response, then holds the socket open without sending a follow-up request. RSS is sampled once a second across a 30s idle hold. Same hello-world rackup, single worker, no TLS. Hyperion runs with `async_io true` (fiber-per-connection on the plain HTTP/1.1 path).

| | held | dropped | peak RSS | RSS after drain |
|---|---:|---:|---:|---:|
| Hyperion `-w 1 -t 5 --async-io` | 10,000 / 10,000 | 0 | 173 MB | 155 MB |
| Puma `-w 0 -t 100`               | 10,000 / 10,000 | 0 | 101 MB | 104 MB |
| Falcon `--count 1`               | 10,000 / 10,000 | 0 | 429 MB | 440 MB |

All three hold 10k idle conns without OOMing or dropping — the "MB-per-thread" intuition that thread-based servers can't reach this scale doesn't survive contact with Linux's demand-paged thread stacks plus Puma's reactor-based keep-alive handling. Per-conn RSS lands at ~14 KB (Hyperion fiber + parser state), ~7 KB (Puma reactor entry + tiny thread share), ~36 KB (Falcon Async::Task + protocol-http stack). Bounded, not unbounded — for all three.

The architectural difference shows up under **load**, not at idle: Puma can only run `max_threads` handler invocations concurrently, so wait-bound handlers (DB, HTTP, Redis) starve at higher request concurrency than `max_threads`. Hyperion's fiber-per-connection model + `--async-io` gives one OS thread thousands of in-flight handler executions, paired with [hyperion-async-pg](https://github.com/exodusgaming-io/hyperion-async-pg) for non-blocking DB. The 10k-conn throughput row above (5× Puma) is the consequence — same idle RSS shape, very different behaviour once the handlers actually do work.

**HTTP/2 multiplexing — 1 connection × 100 concurrent streams (handler sleeps 50 ms):**

| | wall time |
|---|---:|
| Hyperion (per-stream fiber dispatch) | **1.04 s** |
| Serial baseline (100 × 50 ms) | 5.00 s |

Hyperion fans 100 in-flight streams across separate fibers within a single TCP connection. A serial server would take 5 s; the fiber-multiplexed result (1.04 s, ~96 req/s on one socket) is bounded by single-handler sleep time plus framing overhead. Puma has no native HTTP/2 path — production deployments terminate h2 at nginx and forward h1 to the worker pool, which serializes again.

> **1.6.0 outbound write path** — `Http2Handler` no longer serializes every framer write through one `Mutex#synchronize { socket.write(...) }`. HPACK encoding (microseconds, in-memory) still serializes on a fast encode mutex, but the actual `socket.write` is owned by a dedicated per-connection writer fiber draining a queue. On per-connection multi-stream workloads where the kernel send buffer or peer reads are slow, encode work for ready streams overlaps the writer's flush of earlier chunks, instead of stacking up behind it. See `bench/h2_streams.sh` (`h2load -c 1 -m 100 -n 5000`) for a recipe to compare 1.5.0 vs 1.6.0 on a workload of your choice.

### Reproducing the benchmarks

Every number in this README and `docs/BENCH_HYPERION_2_0.md` is reproducible. Operators who don't trust headline numbers (and you shouldn't trust *any* benchmark numbers without independent verification) can rerun the workloads on their own host and get their own honest measurements. Per-row reproduction commands:

```sh
# Setup (once)
bundle install
bundle exec rake compile

# Hello-world (rps + p99 ceiling, no I/O)
bundle exec bin/hyperion -p 9292 -w 16 -t 5 bench/hello.ru &
wrk -t4 -c200 -d20s --latency http://127.0.0.1:9292/

# CPU-bound JSON (per-request CPU savings visible)
bundle exec bin/hyperion -p 9292 -w 4 -t 5 bench/work.ru &
wrk -t4 -c200 -d15s --latency http://127.0.0.1:9292/

# Static 1 MiB sendfile path
ruby -e 'File.binwrite("/tmp/hyperion_bench_asset_1m.bin", "x" * (1024*1024))'
bundle exec bin/hyperion -p 9292 -w 1 -t 5 bench/static.ru &
wrk -t4 -c100 -d15s --latency http://127.0.0.1:9292/hyperion_bench_asset_1m.bin

# SSE streaming (Hyperion-shaped rackup with explicit flush sentinel — see caveat in BENCH doc)
bundle exec bin/hyperion -p 9292 -w 1 -t 5 bench/sse.ru &
wrk -t1 -c1 -d10s http://127.0.0.1:9292/

# WebSocket multi-process throughput
bundle exec bin/hyperion -p 9888 -w 4 -t 64 bench/ws_echo.ru &
ruby bench/ws_bench_client_multi.rb --port 9888 --procs 4 --conns 200 --msgs 1000 --bytes 1024 --json

# h2 native HPACK (Rails-shape, 25-header response)
./bench/h2_rails_shape.sh

# Idle keep-alive RSS sweep (1k / 5k / 10k conns, 30s hold per server)
./bench/keepalive_memory.sh

# Hello-world quick comparator (Hyperion vs Puma vs Falcon)
bundle exec ruby bench/compare.rb
HYPERION_WORKERS=4 PUMA_WORKERS=4 FALCON_COUNT=4 bundle exec ruby bench/compare.rb
```

PG benches (`pg_concurrent.ru`, `pg_mixed.ru`, `pg_realistic.ru`) live in the [hyperion-async-pg companion repo](https://github.com/andrew-woblavobla/hyperion-async-pg) — they require a running Postgres + the companion gem and are not part of this repo. The 2.0.0 sweep used `~/bench/pg_concurrent.ru` on the bench host; reproduce by cloning hyperion-async-pg and following its README, or `scp` the rackup + DATABASE_URL.

When numbers from your host don't match the published numbers, the most likely explanations (in order): (1) bench-host noise — single-VM benches drift 10-30% over days; (2) Puma version mismatch — the 2.0.0 sweep used Puma 8.0.1 in the `~/bench/Gemfile`, the hyperion repo's own Gemfile pins Puma `~> 6.4`; (3) different kernel / Ruby; (4) different `-t` / `-c` (apples-to-apples requires identical worker count, thread count, wrk concurrency, payload size, kernel, Ruby, TLS cipher).

## Quick start

```sh
bundle install
bundle exec rake compile                              # build the llhttp C ext
bundle exec hyperion config.ru                        # single-process default
bundle exec hyperion -w 4 -t 10 config.ru             # 4-worker cluster, 10 threads each
bundle exec hyperion -w 0 config.ru                   # 1 worker per CPU
bundle exec hyperion --tls-cert cert.pem --tls-key key.pem -p 9443 config.ru   # HTTPS
curl http://127.0.0.1:9292/                            # => hello

# Chunked POST works:
curl -X POST -H "Transfer-Encoding: chunked" --data-binary @file http://127.0.0.1:9292/

# HTTP/2 (over TLS, ALPN-negotiated):
curl --http2 -k https://127.0.0.1:9443/
```

`bundle exec rake spec` (and the `default` task) auto-invoke `compile`, so a fresh checkout just needs `bundle install && bundle exec rake` to get a green run.

**Migrating from Puma?** See [docs/MIGRATING_FROM_PUMA.md](docs/MIGRATING_FROM_PUMA.md).

## Configuration

Three layers, in precedence order: explicit CLI flag > environment variable > `config/hyperion.rb` > built-in default.

### CLI flags

| Flag | Default | Notes |
|---|---|---|
| `-b, --bind HOST` | `127.0.0.1` | |
| `-p, --port PORT` | `9292` | |
| `-w, --workers N` | `1` | `0` → `Etc.nprocessors` |
| `-t, --threads N` | `5` | OS-thread Rack handler pool per worker. `0` → run inline (no pool, debugging only). |
| `-C, --config PATH` | `config/hyperion.rb` if present | Ruby DSL file. |
| `--tls-cert PATH` | nil | PEM certificate. |
| `--tls-key PATH` | nil | PEM private key. |
| `--log-level LEVEL` | `info` | `debug` / `info` / `warn` / `error` / `fatal`. |
| `--log-format FORMAT` | `auto` | `text` / `json` / `auto`. Auto: JSON when `RAILS_ENV`/`RACK_ENV` is `production`/`staging`, colored text on TTY, JSON otherwise. |
| `--[no-]log-requests` | ON | Per-request access log. |
| `--fiber-local-shim` | off | Patches `Thread#thread_variable_*` to fiber storage for older Rails idioms. |
| `--[no-]yjit` | auto | Force YJIT on/off. Default: auto-on under `RAILS_ENV`/`RACK_ENV` = `production`/`staging`. |
| `--[no-]async-io` | off | Run plain HTTP/1.1 connections under `Async::Scheduler`. Required for `hyperion-async-pg` on plain HTTP. TLS h1 / HTTP/2 always run under the scheduler regardless. |
| `--max-body-bytes BYTES` | `16777216` (16 MiB) | Maximum request body size. |
| `--max-header-bytes BYTES` | `65536` (64 KiB) | Maximum total request-header size. |
| `--max-pending COUNT` | unbounded | Per-worker accept-queue cap before new connections are rejected with HTTP 503 + `Retry-After: 1`. |
| `--max-request-read-seconds SECONDS` | `60` | Total wallclock budget for reading request line + headers + body for ONE request. Slowloris defence. |
| `--admin-token TOKEN` | unset | Bearer token for `POST /-/quit` and `GET /-/metrics`. **Production: prefer `--admin-token-file` — argv is visible via `ps`.** |
| `--admin-token-file PATH` | unset | Read the admin token from a file. Refuses to load if the file is missing or world-readable (mode must mask `0o007`). |
| `--worker-max-rss-mb MB` | unset | Master gracefully recycles a worker once its RSS exceeds this many megabytes. nil = disabled. |
| `--idle-keepalive SECONDS` | `5` | Keep-alive idle timeout. Connection closes after this many seconds of inactivity. |
| `--graceful-timeout SECONDS` | `30` | Shutdown deadline before SIGKILL is delivered to a worker that hasn't drained. |

### Environment variables

`HYPERION_LOG_LEVEL`, `HYPERION_LOG_FORMAT`, `HYPERION_LOG_REQUESTS` (`0|1|true|false|yes|no|on|off`), `HYPERION_ENV`, `HYPERION_WORKER_MODEL` (`share|reuseport`).

### Config file

`config/hyperion.rb` — same shape as Puma's `puma.rb`. Auto-loaded if present.

```ruby
# config/hyperion.rb
bind '0.0.0.0'
port 9292

workers      4
thread_count 10

# tls_cert_path 'config/cert.pem'
# tls_key_path  'config/key.pem'

read_timeout      30
idle_keepalive     5
graceful_timeout  30

max_header_bytes  64 * 1024
max_body_bytes    16 * 1024 * 1024

log_level    :info
log_format   :auto
log_requests true

fiber_local_shim false

async_io nil    # Three-way (1.4.0+): nil (default, auto: inline-on-fiber for TLS h1, pool hop for plain HTTP/1.1), true (force inline-on-fiber everywhere — required for hyperion-async-pg on plain HTTP/1.1), false (force pool hop everywhere — explicit opt-out for TLS+threadpool with CPU-heavy handlers). ~5% throughput hit on hello-world when inline; in exchange one OS thread serves N concurrent in-flight DB queries on wait-bound workloads. TLS / HTTP/2 accept loops always run under Async::Scheduler regardless of this flag.

before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end

on_worker_boot do |worker_index|
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end

on_worker_shutdown do |worker_index|
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end
```

Strict DSL: unknown methods raise `NoMethodError` at boot — typos surface immediately rather than getting silently ignored.

A documented sample lives at [`config/hyperion.example.rb`](config/hyperion.example.rb).

## Operator guidance

Concrete tradeoffs distilled from [`docs/BENCH_2026_04_27.md`](docs/BENCH_2026_04_27.md). If the bench numbers cited below feel surprising, check that doc for the full matrix + caveats.

### When to use `-w N`

| Workload shape | Recommended | Why |
|---|---|---|
| **Pure I/O-bound** (PG / Redis / external HTTP, no significant CPU) | `-w 1` + larger pool | Bench: `-w 1 pool=200` = 87 MB / 2,180 r/s vs `-w 4 pool=64` = 224 MB / 1,680 r/s. **2.6× more memory, 0.77× rps** if you pick multi-worker on a wait-bound workload. |
| **Pure CPU-bound** (heavy JSON / template render / image processing) | `-w N` matching CPU count | Each worker's accept loop is single-threaded under `--async-io`; multi-worker gives CPU-parallelism. Bench: `-w 16 -t 5` hits 98,818 r/s on a 16-vCPU box, 4.7× a `-w 1` ceiling on the same hardware. |
| **Mixed** (Rails-shaped: ~5 ms CPU + 50 ms PG wait per request) | `-w N/2` (half cores) + medium pool | Lets CPU work parallelise while keeping per-worker memory tractable. Bench `pg_mixed.ru` (in hyperion-async-pg repo / `~/bench/`) at `-w 4 -t 5 pool=128` = 1,740 r/s with no cold-start spike (ForkSafe `prefill_in_child: true`). |

Multi-worker on PG-wait workloads is the **wrong** default for most apps — the headline rps doesn't justify the memory and PG-connection cost. Verify your shape with the bench before scaling out.

### When to use `--async-io`

```
                 Are you using a fiber-cooperative I/O library?
                 (hyperion-async-pg, async-redis, async-http)
                              │
                ┌─────────────┴─────────────┐
                yes                          no
                │                            │
        Pair with a fiber-aware       Leave --async-io OFF.
        connection pool               Default thread-pool dispatch
        (FiberPool, async-pool —      is faster for synchronous
        NOT connection_pool gem,      Rails apps. Bench: --async-io
        which uses non-fiber Mutex).  on hello-world = 47% rps
                │                     regression + p99 spike to
        Set --async-io.               3.65 s under no-yield workloads.
        Pool size is the real         No reason to flip the flag.
        concurrency knob; -t is
        decorative for wait-bound.
```

Hyperion warns at boot if you set `--async-io` without any fiber-cooperative library loaded. The setting is still honoured; the warn just nudges operators who flipped it expecting a free perf bump.

### Tuning `-t` and pool sizes

- **Without `--async-io`** (sync server, default): `-t` is the concurrency knob. Each in-flight request holds an OS thread; pool size should match `-t`. Bench shows Puma-style behaviour — at 200 wrk conns hitting a 5-thread server, queue depth dominates p99 (Hyperion `-t 5 -w 1` p50 = 0.95 ms vs Puma's same shape at 59.5 ms — Hyperion's queueing is cheaper but the model still serializes at `-t`).
- **With `--async-io` + a fiber-aware pool**: pool size is the concurrency knob. `-t` is decorative for wait-bound workloads; one accept-loop fiber serves all in-flight queries via the pool. Linear scaling: pool=64 → ~780 r/s, pool=128 → ~1,344 r/s, pool=200 → ~2,180 r/s on 50 ms PG queries.
- **Pool over WAN**: if `PG.connect` round-trip is >50 ms, expect pool fill at startup to take `pool_size / parallel_fill_threads × RTT`. `hyperion-async-pg 0.5.1+` auto-scales `parallel_fill_threads` so pool=200 fills in ~1-2 s.

### How to read p50 vs p99

Tail latency tells the queueing story; rps tells the throughput story. Hyperion's tail wins are **always** bigger than its rps wins — sometimes the rps numbers look close to a competitor while p99 is 5-200× lower:

| Workload | Hyperion rps / p99 | Closest competitor | rps ratio | p99 ratio |
|---|---|---|---:|---:|
| Hello `-w 4` | 21,215 r/s / 1.87 ms | Falcon 24,061 / 9.78 ms | 0.88× | **5.2× lower** |
| CPU JSON `-w 4` | 15,582 r/s / 2.47 ms | Falcon 18,643 / 13.51 ms | 0.84× | **5.5× lower** |
| Static 1 MiB | 1,919 r/s / 4.22 ms | Puma 2,074 / 55 ms | 0.93× | **13× lower** |
| PG-wait `-w 1` pool=200 | 2,180 r/s / 668 ms | Puma 530 r/s + 200 timeouts | **4.1×** | qualitative crush |

**Size capacity by p99, not by mean.** Throughput peaks are easy to fake under controlled bench conditions; tail latency reflects what your slowest user actually experiences when the load balancer fans them onto a busy worker.

### Production tuning (real Rails apps)

Distilled from a real-app bench against the [Exodus platform](https://github.com/andrew-woblavobla/hyperion/blob/master/docs/BENCH_2026_04_27.md) (Rails 8.1, on-LAN PG + Redis at ~0.3 ms RTT, `-w 4 -t 10`, `wrk -t8 -c200 -d30s`). The headline finding: the **simplest drop-in is the right answer**, and the additional knobs operators reach for first don't help on real Rails.

**Recommended for migrating from Puma**: `hyperion -t N -w M` matching your current Puma `-t N:N -w M`. No other flags. That gives you (vs Puma at the same `-t/-w`):

- **+9% rps on lightweight endpoints** (matches the 5-10% per-request CPU savings the rest of the bench section documents).
- **28× lower p99 on health-style endpoints** — the queue-of-doom shape Puma exhibits under sustained 200-conn load doesn't reproduce on Hyperion's worker-owns-connection model.
- **3.8× lower p99 on PG-touching endpoints**.
- **Same RSS, same operator surface** — you keep all your existing config, monitoring, and deploy scripts.

**Knobs that help on synthetic benches but NOT on real Rails — leave them off:**

| Knob | Synthetic bench result | Real Rails result | Recommendation |
|---|---|---|---|
| `-t 30` (more threads/worker) | Helped Hyperion 5-10% on hello-world | **Hurt** p99 vs `-t 10` on real Rails (3.51 s vs 148 ms on /up) — GVL + middleware Mutex contention dominates past `-t 10` | Stay at `-t 10`. Match Puma's recommended `RAILS_MAX_THREADS`. |
| `--yjit` | 5-10% on synthetic CPU-bound | Wash on dev-mode Rails (312 vs 328 rps, p99 worse with YJIT) | Skip for now. Production-mode Rails may behave differently — verify with your own bench before flipping. |
| `RAILS_POOL` > 25 | n/a | No improvement at pool=50 or pool=100 on real Rails (rps within 3%, p99 within noise). Pool starvation is rarely the bottleneck on a `-w 4 -t 10` config | Keep your existing AR pool size. |
| `--async-io` | 33-42× rps on PG-bound (with `hyperion-async-pg`) | **Worse** than drop-in on real Rails (4.14 s p99 on /up vs 148 ms drop-in) | **Don't enable** until your full I/O stack is fiber-cooperative. The synchronous Redis client (`redis-rb`) blocks the OS thread before async-pg can yield, so fibers can't compound. Migrate to `async-redis` *first*, then revisit. |
| `--async-io` + `hyperion-async-pg` AR adapter | Verified 48× rps lift on a single-PG-query bench | Marginal-or-negative on real Rails (similar reason: Redis-first handlers don't yield) | Same — wait for a full-async I/O stack. |

**Why the simple drop-in wins on real Rails:** the per-request budget on a real handler is dominated by the Rails middleware chain (rack-attack, locale redirect, tagger, etc.) + handler logic + DB + cache I/O. Hyperion's per-request CPU optimizations (C-ext header parser, response builder, lock-free metrics, fiber-cooperative TLS dispatch in 1.4.0+) shave ~5-10% off the *non-I/O* portion of the budget consistently — and the [worker-owns-connection model](#concurrency-at-scale-architectural-advantages) prevents the queue-amplification that Puma's thread-pool dispatch shows under sustained load. You don't need to "tune" anything to get those.

## Logging

Default behaviour (rc16+):

- **`info` / `debug` → stdout**, **`warn` / `error` / `fatal` → stderr** (12-factor).
- **One structured access-log line per response**, info level, on stdout. Disable with `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
- **Format auto-selects**: production envs → JSON (line-delimited, parseable by every log aggregator); TTY → coloured text; piped output without env hint → JSON.

### Sample access log lines

Text format (TTY default):

```
2026-04-26T18:40:04.112Z INFO  [hyperion] message=request method=GET path=/api/v1/health status=200 duration_ms=46.63 remote_addr=127.0.0.1 http_version=HTTP/1.1
2026-04-26T18:40:04.123Z INFO  [hyperion] message=request method=GET path=/api/v1/cached_data query="currency=USD" status=200 duration_ms=43.87 remote_addr=127.0.0.1 http_version=HTTP/1.1
```

JSON format (auto-selected on `RAILS_ENV=production`/`staging` or piped output):

```json
{"ts":"2026-04-26T18:38:49.405Z","level":"info","source":"hyperion","message":"request","method":"GET","path":"/api/v1/health","status":200,"duration_ms":46.63,"remote_addr":"127.0.0.1","http_version":"HTTP/1.1"}
{"ts":"2026-04-26T18:38:49.411Z","level":"info","source":"hyperion","message":"request","method":"GET","path":"/api/v1/cached_data","query":"currency=USD","status":200,"duration_ms":40.64,"remote_addr":"127.0.0.1","http_version":"HTTP/1.1"}
```

### Hot-path optimisations

The default-ON access log path is engineered to stay near-zero cost:

- **Per-thread cached `iso8601(3)` timestamp** — one allocation per millisecond per thread, reused across all requests in that millisecond.
- **Hand-rolled single-interpolation line builder** — bypasses generic `Hash#map.join`.
- **Per-thread 4 KiB write buffer** — flushes to stdout when full or on connection close. Cuts ~32× the syscalls under load.
- **Lock-free emit** — POSIX `write(2)` is atomic for writes ≤ PIPE_BUF (4096 B); a log line is ~200 B. No logger mutex.

## Metrics

`Hyperion.stats` returns a snapshot Hash with the following counters (lock-free per-thread aggregation):

| Counter | Meaning |
|---|---|
| `connections_accepted` | Lifetime accept count. |
| `connections_active` | Currently in-flight connections. |
| `requests_total` | Lifetime request count. |
| `requests_in_flight` | Currently in-flight requests. |
| `responses_<code>` | One counter per status code emitted (`responses_200`, `responses_400`, …). |
| `parse_errors` | HTTP parse failures → 400. |
| `app_errors` | Rack app raised → 500. |
| `read_timeouts` | Per-connection read deadline hit. |
| `requests_threadpool_dispatched` | HTTP/1.1 connection handed to the worker pool (or served inline in `start_raw_loop` when `thread_count: 0`). The default dispatch path. |
| `requests_async_dispatched` | HTTP/1.1 connection served inline on the accept-loop fiber under `--async-io`. Operators can use the ratio against `requests_threadpool_dispatched` to verify fiber-cooperative I/O is actually engaged. |

```ruby
require 'hyperion'
Hyperion.stats
# => {connections_accepted: 1234, connections_active: 7, requests_total: 8910, …}
```

### Prometheus exporter

When `admin_token` is set in your config, Hyperion mounts a `/-/metrics` endpoint that emits Prometheus text-format v0.0.4. Same token guards both `/-/metrics` (GET) and `/-/quit` (POST); auth is via the `X-Hyperion-Admin-Token` header.

```sh
$ curl -s -H 'X-Hyperion-Admin-Token: secret' http://127.0.0.1:9292/-/metrics
# HELP hyperion_requests_total Total HTTP requests handled
# TYPE hyperion_requests_total counter
hyperion_requests_total 8910
# HELP hyperion_bytes_written_total Total bytes written to response sockets
# TYPE hyperion_bytes_written_total counter
hyperion_bytes_written_total 2351023
# HELP hyperion_responses_status_total Responses by HTTP status code
# TYPE hyperion_responses_status_total counter
hyperion_responses_status_total{status="200"} 8521
hyperion_responses_status_total{status="404"} 12
hyperion_responses_status_total{status="500"} 3
# … and so on for sendfile_responses_total, rejected_connections_total,
# slow_request_aborts_total, requests_async_dispatched_total, etc.
```

Any counter not in the known set (added by app middleware via `Hyperion.metrics.increment(:custom_thing)`) is auto-exported as `hyperion_custom_thing` with a generic HELP line — no Hyperion config change required.

Point your scraper at it: in Prometheus' `scrape_configs`, set `metrics_path: /-/metrics` and `bearer_token` (or use a custom header relabel — Prometheus 2.42+ supports `authorization.credentials_file` paired with a custom `header` block). Network-isolate the admin endpoints if the listener is internet-facing — see [docs/REVERSE_PROXY.md](docs/REVERSE_PROXY.md) for the nginx `location /-/ { return 404; }` recipe.

## TLS + HTTP/2

Provide a PEM cert + key:

```sh
bundle exec hyperion --tls-cert config/cert.pem --tls-key config/key.pem -p 9443 config.ru
```

ALPN auto-negotiates `h2` (HTTP/2) or `http/1.1` per connection. HTTP/2 multiplexes streams onto fibers within a single connection — slow handlers don't head-of-line-block other streams. Cluster-mode TLS works (`-w N` + `--tls-cert` / `--tls-key`).

Smuggling defenses for HTTP/1.1: `Content-Length` + `Transfer-Encoding` together → 400; non-chunked `Transfer-Encoding` → 501; CRLF in response header values → `ArgumentError` (response-splitting guard).

## Compatibility

- **Ruby 3.3+** required (the `protocol-http2 ~> 0.26` transitive dep imposes this floor; older Ruby installs error at `bundle install`).
- **Rack 3** (auto-sets `SERVER_SOFTWARE`, `rack.version`, `REMOTE_ADDR`, IPv6-safe `Host` parsing, CRLF guard).
- **`Hyperion::FiberLocal.install!`** opt-in shim for older Rails apps that store request-scoped data via `Thread.current.thread_variable_*` (modern Rails 7.1+ already uses Fiber storage natively; the shim handles the residual footgun).
- **`Hyperion::FiberLocal.verify_environment!`** runtime check that `Thread.current[:k]` is fiber-local on the current Ruby (it is on 3.2+).

## Credits

- Vendored [llhttp](https://github.com/nodejs/llhttp) (Node.js's HTTP parser, MIT) under `ext/hyperion_http/llhttp/`.
- HTTP/2 framing and HPACK via [`protocol-http2`](https://github.com/socketry/protocol-http2).
- Fiber scheduler via [`async`](https://github.com/socketry/async).

## License

MIT.
