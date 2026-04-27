# Hyperion

High-performance Ruby HTTP server. Falcon-class fiber concurrency, Puma-class compatibility.

[![CI](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml/badge.svg)](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/hyperion-rb.svg)](https://rubygems.org/gems/hyperion-rb)
[![License: MIT](https://img.shields.io/github/license/andrew-woblavobla/hyperion.svg)](https://github.com/andrew-woblavobla/hyperion/blob/master/LICENSE)

```sh
gem install hyperion-rb
bundle exec hyperion config.ru
```

## Highlights

- **HTTP/1.1 + HTTP/2 + TLS** out of the box (HTTP/2 with per-stream fiber multiplexing, WINDOW_UPDATE-aware flow control, ALPN auto-negotiation).
- **Pre-fork cluster** with per-OS worker model: `SO_REUSEPORT` on Linux, master-bind + worker-fd-share on macOS/BSD (Darwin's `SO_REUSEPORT` doesn't load-balance).
- **Hybrid concurrency**: fiber-per-connection for I/O, OS-thread pool for `app.call(env)` — synchronous Rack handlers (Rails, ActiveRecord, anything holding a global mutex) get true OS-thread concurrency.
- **Vendored llhttp 9.3.0** C parser; pure-Ruby fallback for non-MRI runtimes.
- **Default-ON structured access logs** (one JSON or text line per request) with hot-path optimisations: per-thread cached timestamp, hand-rolled line builder, lock-free per-thread write buffer.
- **12-factor logger split**: info/debug → stdout, warn/error/fatal → stderr.
- **Ruby DSL config file** (`config/hyperion.rb`) with lifecycle hooks (`before_fork`, `on_worker_boot`, `on_worker_shutdown`).
- **Object pooling** for the Rack `env` hash and `rack.input` IO — amortizes per-request allocations across the worker's lifetime.
- **`Hyperion::FiberLocal`** opt-in shim for older Rails idioms that store request-scoped data via `Thread.current.thread_variable_*`.

## Benchmarks

All numbers are real wrk runs against published Hyperion configs. Hyperion ships **with default-ON structured access logs**; Puma comparisons use Puma defaults (no per-request log emission).

### Hello-world Rack app

`bench/hello.ru`, single worker, parity threads (`-t 5` vs Puma `-t 5:5`), 4 wrk threads / 100 connections / 15s, macOS arm64 / Ruby 3.3.3, Hyperion 1.2.0:

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

**Wait-bound workload** (`bench/pg_concurrent.ru`: `SELECT pg_sleep(0.05)` + tiny JSON):

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

**Mixed CPU+wait** (`bench/pg_mixed.ru`: same query + 50-key JSON serialization, ~5 ms CPU):

| | r/s | p99 | RSS | vs Puma `-t 30` |
|---|---:|---:|---:|---:|
| Puma 8.0 `-t 30` pool=30 | 351.7 | 963 ms | 127 MB | 1.0× |
| Hyperion `--async-io -t 5` pool=32 | 371.2 | 919 ms | 151 MB | 1.05× |
| Hyperion `--async-io -t 5` pool=64 | 741.5 | 681 ms | 161 MB | 2.1× |
| **Hyperion `--async-io -t 5` pool=128** | **1739.9** | **512 ms** | **201 MB** | **4.9×** |
| Falcon `--count 1` pool=128 | 1642.1 | 531 ms | 213 MB | 4.7× |

**Takeaways:**
1. **Linear scaling with pool size** under `--async-io` — `r/s ≈ pool × 12` on this WAN bench. Single-worker pool=200 hits 2381 r/s, **42× Puma `-t 5`** and **5.9× Puma's best** (`-t 30`).
2. **Mixed workload doesn't kill the win** — Hyperion `--async-io` pool=128 actually goes *up* on mixed (1740 vs 1344 r/s) because CPU work overlaps other fibers' PG-wait windows. This is the honest "what happens to a real Rails handler" answer.
3. **Hyperion ≈ Falcon within 3-7%** across pool sizes; both fiber-native architectures extract similar value from `hyperion-async-pg`.
4. **RSS at single-worker scale isn't the architectural moat** — Linux thread stacks are demand-paged; PG connection buffers dominate RSS at pool sizes ≤ 200. The MB-vs-GB story shows up at **idle keep-alive connection scale** (10k+ conns), not in this PG-bound throughput bench. See [Concurrency at scale](#concurrency-at-scale-architectural-advantages) for the connection-count win.
5. **`-w 4` cold-start caveat** — multi-worker p99 inflates because the bench rackup uses lazy per-process pool init (each worker pays full pool fill on its first request). Production apps avoid this with `on_worker_boot { Hyperion::AsyncPg::FiberPool.new(...).fill }`.

Three things must all be true to get this win:
1. **`async_io: true`** in your Hyperion config (or `--async-io` CLI flag). Default is off to keep 1.2.0's raw-loop perf for fiber-unaware apps.
2. **`hyperion-async-pg`** installed: `gem 'hyperion-async-pg', require: 'hyperion/async_pg'` + `Hyperion::AsyncPg.install!` at boot.
3. **Fiber-aware connection pool.** The popular `connection_pool` gem is NOT — its Mutex blocks the OS thread. Use [`async-pool`](https://github.com/socketry/async-pool), `Async::Semaphore`, or hand-roll one (see `bench/pg_concurrent.ru` for a ~30-line FiberPool example).

Skip any of these and you get parity with Puma at the same `-t`. Run the bench yourself: `MODE=async DATABASE_URL=... PG_POOL_SIZE=200 bundle exec hyperion --async-io -t 5 bench/pg_concurrent.ru` (in the [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg) repo).

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

Hyperion holds each connection in a ~1 KB fiber stack; Puma needs an OS thread (~1–8 MB each, capped at `max_threads`). At 10k concurrent connections Hyperion serves **~5× the throughput** of Puma with **~20% fewer dropped requests**, while the per-connection bookkeeping cost is bounded by fiber size, not by `max_threads`.

**HTTP/2 multiplexing — 1 connection × 100 concurrent streams (handler sleeps 50 ms):**

| | wall time |
|---|---:|
| Hyperion (per-stream fiber dispatch) | **1.04 s** |
| Serial baseline (100 × 50 ms) | 5.00 s |

Hyperion fans 100 in-flight streams across separate fibers within a single TCP connection. A serial server would take 5 s; the fiber-multiplexed result (1.04 s, ~96 req/s on one socket) is bounded by single-handler sleep time plus framing overhead. Puma has no native HTTP/2 path — production deployments terminate h2 at nginx and forward h1 to the worker pool, which serializes again.

### Reproduce

```sh
# hello-world
bundle exec ruby bench/compare.rb
HYPERION_WORKERS=4 PUMA_WORKERS=4 FALCON_COUNT=4 bundle exec ruby bench/compare.rb

# Real Rails / Grape: see bench/db.ru for the schema
```

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

```ruby
require 'hyperion'
Hyperion.stats
# => {connections_accepted: 1234, connections_active: 7, requests_total: 8910, …}
```

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
