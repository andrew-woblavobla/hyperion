# Hyperion

High-performance Ruby HTTP server. Rack 3 + HTTP/2 + WebSockets + gRPC on a single binary.

[![CI](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml/badge.svg)](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/hyperion-rb.svg)](https://rubygems.org/gems/hyperion-rb)
[![License: MIT](https://img.shields.io/github/license/andrew-woblavobla/hyperion.svg)](https://github.com/andrew-woblavobla/hyperion/blob/master/LICENSE)

Hyperion serves a hello-world Rack response at **134,084 r/s with a 1.14 ms p99**
on a single worker (Linux 6.x, io_uring accept loop, `Server.handle_static`),
**7×** Agoo's 19,024 r/s on the same hardware. Beyond the C-side fast path
it's a complete Rack 3 server: HTTP/1.1 + HTTP/2 with ALPN, WebSockets
(RFC 6455), gRPC unary + streaming on the Rack 3 trailers contract, native
fiber concurrency for PG-bound apps, and pre-fork cluster mode with
SO_REUSEPORT-balanced workers.

```sh
gem install hyperion-rb
bundle exec hyperion config.ru                 # http://127.0.0.1:9292
```

## Headline benchmarks

Linux 6.8 / 16-vCPU Ubuntu 24.04 / Ruby 3.3.3, single worker, `wrk -t4 -c100 -d20s`
unless noted. Reproduction commands and the full 6-row 4-way matrix
(Hyperion / Puma / Falcon / Agoo) live in
[docs/BENCH_HYPERION_2_11.md](docs/BENCH_HYPERION_2_11.md).

| Workload                                              | Hyperion r/s | Hyperion p99 | Reference            |
|-------------------------------------------------------|-------------:|-------------:|----------------------|
| Static hello, `handle_static` + io_uring (2.12-D)     | **134,084**  | 1.14 ms      | Agoo 2.15.14: 19,024 |
| Static hello, `handle_static` + accept4 fallback      |       15,685 | 107 µs       | Agoo 2.15.14: 19,024 |
| Dynamic block, `Server.handle { \|env\| ... }` (2.14-A) |        9,422 | 166 µs       | Agoo 2.15.14: 19,024 |
| CPU JSON via block (`bench/work.ru`, 2.14-A)          |        5,897 | 256 µs       | Falcon: 4,226        |
| Generic Rack hello (no `Server.handle`)               |        4,752 | 2.02 ms      | Agoo 2.15.14: 19,024 |
| gRPC unary, h2/TLS, ghz `-c50` (2.14-D)               |        1,618 | 33.3 ms      | Falcon `async-grpc`: 1,512 (+7%) |

The 134,084 r/s row is sustained over a 4-hour soak at **120,684 r/s**
with RSS variance 2.71% and `wrk-truth` p99 1.14 ms (2.14-C). The
io_uring loop is opt-in via `HYPERION_IO_URING_ACCEPT=1` until 2.15;
the `accept4` row is the default on Linux.

## Quick start

```sh
bundle exec hyperion config.ru                          # single process
bundle exec hyperion -w 4 -t 10 config.ru               # 4 workers × 10 threads
bundle exec hyperion -w 0 config.ru                     # one worker per CPU
bundle exec hyperion --tls-cert cert.pem --tls-key key.pem -p 9443 config.ru
```

`bundle exec rake spec` (and the default task) auto-invoke `compile`, so a
fresh checkout just needs `bundle install && bundle exec rake` for a green run.

Migrating from Puma? `hyperion -t N -w M` matching your current Puma
`-t N:N -w M` is the recommended drop-in. See
[docs/MIGRATING_FROM_PUMA.md](docs/MIGRATING_FROM_PUMA.md).

## Features

### HTTP/1.1 + HTTP/2 + TLS

ALPN auto-negotiates `h2` or `http/1.1` per connection. HTTP/2 multiplexes
streams onto fibers within a single connection — slow handlers don't
head-of-line-block other streams. Cluster-mode TLS works (`-w N` +
`--tls-cert` / `--tls-key`).

Smuggling defenses for HTTP/1.1: `Content-Length` + `Transfer-Encoding`
together → 400; non-chunked `Transfer-Encoding` → 501; CRLF in response
header values → `ArgumentError` (response-splitting guard).

### WebSockets (2.1.0+)

RFC 6455 over Rack 3 full hijack, native frame codec, per-connection
wrapper with auto-pong, close handshake, UTF-8 validation, and per-message
size cap. **ActionCable + faye-websocket on a single binary** — one
`hyperion -w 4 -t 10 config.ru` serves HTTP, HTTP/2, TLS, and `/cable`
from the same listener. Conformance: 463/463 autobahn-testsuite cases
pass. See [docs/WEBSOCKETS.md](docs/WEBSOCKETS.md).

### gRPC (2.12-F+)

Hyperion's HTTP/2 path supports gRPC unary, server-streaming,
client-streaming, and bidirectional RPCs via the Rack 3 trailers contract:
any response body that defines `#trailers` gets a final HEADERS frame
(with `END_STREAM=1`) carrying the trailer map after the DATA frames.
Plain HTTP/2 traffic without the gRPC content-type keeps the unary
buffered semantics — no behaviour change for non-gRPC clients.

A minimal unary handler:

```ruby
class GrpcBody
  def initialize(reply); @reply = reply; end
  def each; yield @reply; end
  def trailers; { 'grpc-status' => '0', 'grpc-message' => 'OK' }; end
  def close; end
end

run ->(env) {
  request = env['rack.input'].read
  reply   = handle(request)
  [200, { 'content-type' => 'application/grpc' }, GrpcBody.new(reply)]
}
```

Server-streaming yields one DATA frame per `each`; client-streaming
reads incoming frames off `env['rack.input']` (a streaming IO that
blocks until the next DATA frame lands); bidirectional interleaves
both. Reproducible bench at `bench/grpc_stream.{proto,ru}` +
`bench/grpc_stream_bench.sh` (ghz). Numbers in
[docs/BENCH_HYPERION_2_11.md](docs/BENCH_HYPERION_2_11.md#grpc-ghz-bench--hyperion-vs-falcon-async-grpc-214-d).

### `Server.handle` direct routes

Bypass the Rack adapter for hot paths:

```ruby
Hyperion::Server.handle_static '/health', body: 'ok'
Hyperion::Server.handle(:GET, '/v1/ping') { |env| [200, {}, ['pong']] }
```

`handle_static` bakes the response at boot and serves from the C accept
loop (134k r/s with io_uring, 16k r/s on accept4). The dynamic block
form (2.14-A) runs `app.call(env)` on the C accept loop too — accept +
recv + parse + write release the GVL while the block holds it, so
multi-threaded workers actually parallelise.

### Pre-fork cluster

Per-OS worker model: `SO_REUSEPORT` on Linux (kernel-balanced accept,
1.004–1.011 max/min ratio across workers under steady load — 2.12-E
audit), master-bind + worker-fd-share on macOS/BSD where Darwin's
`SO_REUSEPORT` doesn't load-balance. Lifecycle hooks (`before_fork`,
`on_worker_boot`, `on_worker_shutdown`) for AR / Redis / pool init.

### Async I/O (PG-bound apps)

`--async-io` runs plain HTTP/1.1 connections under `Async::Scheduler`,
turning one OS thread into thousands of in-flight handler invocations.
Paired with [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg)
on a `pg_sleep(50ms)` workload, single-worker `pool=200` hits **2,381 r/s**
vs Puma `-t 5` at 56 r/s (architectural ceiling: pool size, not thread
count). Three things must all be true: `--async-io`, `hyperion-async-pg`
loaded, and a fiber-aware pool (`Hyperion::AsyncPg::FiberPool`,
`async-pool`, or `Async::Semaphore` — **not** the `connection_pool` gem,
whose `Mutex` blocks the OS thread). Skip any one and you get parity
with Puma.

### Observability

`/-/metrics` Prometheus endpoint (admin-token guarded), per-route
latency histograms, per-conn fairness rejections, WebSocket
permessage-deflate ratio, kTLS active connections, ThreadPool queue
depth, dispatch-mode counters (Rack / `handle_static` / dynamic block /
h2 / async-io). Pre-built Grafana dashboard at
[docs/grafana/hyperion-2.4-dashboard.json](docs/grafana/hyperion-2.4-dashboard.json).
Full reference: [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md).

Default-ON structured access logs (one JSON or text line per request)
with hot-path optimisations: per-thread cached iso8601 timestamp,
hand-rolled line builder, lock-free per-thread 4 KiB write buffer.
12-factor logger split: `info`/`debug` → stdout, `warn`/`error`/`fatal`
→ stderr.

### Optional io_uring accept loop

Linux 5.x+, opt-in via `HYPERION_IO_URING_ACCEPT=1`. Multishot accept
+ per-conn RECV/WRITE/CLOSE state machine on top of liburing. One
`io_uring_enter` per N requests instead of N×3 syscalls. Compiles out
cleanly without liburing — the `accept4` path stays the fallback.
macOS keeps using `accept4`. Default-flip moves to 2.15 with a fresh
24h soak.

## Configuration

Three layers, in precedence order: explicit CLI flag > environment
variable > `config/hyperion.rb` > built-in default.

### Most-used CLI flags

| Flag | Default | Notes |
|---|---|---|
| `-b, --bind HOST` | `127.0.0.1` | |
| `-p, --port PORT` | `9292` | |
| `-w, --workers N` | `1` | `0` → `Etc.nprocessors` |
| `-t, --threads N` | `5` | OS-thread Rack handler pool per worker. `0` → run inline (debugging). |
| `-C, --config PATH` | `config/hyperion.rb` if present | Ruby DSL file. |
| `--tls-cert PATH` / `--tls-key PATH` | nil | PEM cert + key for HTTPS. |
| `--[no-]async-io` | off | Run plain HTTP/1.1 under `Async::Scheduler`. Required for `hyperion-async-pg` on plain HTTP. |
| `--preload-static DIR` | nil | Preload static assets from DIR at boot (repeatable, immutable). Rails apps auto-detect from `Rails.configuration.assets.paths`. |
| `--admin-token-file PATH` | unset | Auth file for `/-/quit` and `/-/metrics`. Refuses world-readable files. |
| `--worker-max-rss-mb MB` | unset | Master gracefully recycles a worker exceeding MB RSS. |
| `--max-pending COUNT` | unbounded | Per-worker accept-queue cap before HTTP 503 + `Retry-After: 1`. |
| `--idle-keepalive SECONDS` | `5` | Keep-alive idle timeout. |
| `--graceful-timeout SECONDS` | `30` | Shutdown deadline before SIGKILL. |

`bin/hyperion --help` prints the full set, including `--max-body-bytes`,
`--max-header-bytes`, `--max-request-read-seconds` (slowloris defence),
`--h2-max-total-streams`, `--max-in-flight-per-conn`,
`--tls-handshake-rate-limit`, and the `--[no-]yjit` /
`--[no-]log-requests` toggles.

### Environment variables

`HYPERION_LOG_LEVEL`, `HYPERION_LOG_FORMAT`, `HYPERION_LOG_REQUESTS`
(`0|1|true|false|yes|no|on|off`), `HYPERION_ENV`,
`HYPERION_WORKER_MODEL` (`share|reuseport`), `HYPERION_IO_URING_ACCEPT`
(`0|1`), `HYPERION_H2_DISPATCH_POOL`, `HYPERION_H2_NATIVE_HPACK`
(`v2|ruby|off`), `HYPERION_H2_TIMING`.

### Config file

`config/hyperion.rb` — same shape as Puma's `puma.rb`. Auto-loaded if
present. Strict DSL: unknown methods raise `NoMethodError` at boot.

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

log_level    :info
log_format   :auto
log_requests true

async_io nil    # nil = auto (1.4.0+), true = inline-on-fiber everywhere, false = pool everywhere

before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end

on_worker_boot do |worker_index|
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end
```

A documented sample lives at
[`config/hyperion.example.rb`](config/hyperion.example.rb).

## Operator guidance

Distilled from [docs/BENCH_2026_04_27.md](docs/BENCH_2026_04_27.md)
(Rails 8.1 real-app sweep). Headline finding: **the simplest drop-in
is the right answer.**

### Migrating from Puma

`hyperion -t N -w M` matching your current Puma `-t N:N -w M`. No other
flags. Versus Puma at the same `-t/-w` shape on real Rails endpoints:
**+9% rps on lightweight endpoints, 28× lower p99 on health-style
endpoints, 3.8× lower p99 on PG-touching endpoints.** Same RSS, same
operator surface — keep all your existing config, monitoring, deploy
scripts.

### Knobs that help on synthetic benches but **not** on real Rails

| Knob | Synthetic | Real Rails | Recommendation |
|---|---|---|---|
| `-t 30` | +5–10% on hello-world | **Hurts** p99 vs `-t 10` (3.51 s vs 148 ms on `/up`) — GVL + middleware Mutex contention | Stay at `-t 10`. |
| `--yjit` | +5–10% on CPU-bound | Wash on dev-mode Rails | Skip until you bench production-mode. |
| `RAILS_POOL > 25` | n/a | No improvement at 50 or 100 | Keep your existing AR pool. |
| `--async-io` | 33–42× rps on PG-bound | **Worse** than drop-in (4.14 s p99 on `/up`) until your full I/O stack is fiber-cooperative | Don't enable until `redis-rb` → `async-redis`. |

### When `-w N` helps

| Workload | Recommended | Why |
|---|---|---|
| Pure I/O-bound (PG / Redis / external HTTP) | `-w 1` + larger pool | `-w 1 pool=200` = 87 MB / 2,180 r/s vs `-w 4 pool=64` = 224 MB / 1,680 r/s. **2.6× memory, 0.77× rps** if you pick multi-worker on wait-bound. |
| Pure CPU-bound | `-w N` matching CPU count | Bench: `-w 16 -t 5` hits 98,818 r/s on a 16-vCPU box. |
| Mixed (Rails-shaped, ~5 ms CPU + 50 ms wait) | `-w N/2` (half cores) + medium pool | `-w 4 -t 5 pool=128` = 1,740 r/s on `pg_mixed.ru`, no cold-start spike. |

### Read p99 not mean

| Workload | Hyperion rps / p99 | Closest competitor | rps ratio | p99 ratio |
|---|---|---|---:|---:|
| Hello `-w 4` | 21,215 / 1.87 ms | Falcon 24,061 / 9.78 ms | 0.88× | **5.2× lower** |
| CPU JSON `-w 4` | 15,582 / 2.47 ms | Falcon 18,643 / 13.51 ms | 0.84× | **5.5× lower** |
| Static 1 MiB | 1,919 / 4.22 ms | Puma 2,074 / 55 ms | 0.93× | **13× lower** |
| PG-wait `-w 1` pool=200 | 2,180 / 668 ms | Puma 530 + 200 timeouts | **4.1×** | qualitative crush |

Throughput peaks are easy to fake under controlled conditions; tail
latency reflects what your slowest user actually experiences when the
load balancer fans them onto a busy worker.

## Logging

Default behaviour:

- `info`/`debug` → stdout, `warn`/`error`/`fatal` → stderr (12-factor).
- One structured access-log line per response, `info` level. Disable
  with `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
- Format auto-selects: `RAILS_ENV=production`/`staging` → JSON; TTY →
  coloured text; piped output without env hint → JSON.

Sample text (TTY default):

```
2026-04-26T18:40:04.112Z INFO  [hyperion] message=request method=GET path=/api/v1/health status=200 duration_ms=46.63 remote_addr=127.0.0.1 http_version=HTTP/1.1
```

Sample JSON (production / piped):

```json
{"ts":"2026-04-26T18:38:49.405Z","level":"info","source":"hyperion","message":"request","method":"GET","path":"/api/v1/health","status":200,"duration_ms":46.63,"remote_addr":"127.0.0.1","http_version":"HTTP/1.1"}
```

## Metrics

`Hyperion.stats` returns a snapshot Hash with lock-free per-thread
counters (`connections_accepted`, `connections_active`, `requests_total`,
`requests_in_flight`, `responses_<code>`, `parse_errors`, `app_errors`,
`read_timeouts`, `requests_threadpool_dispatched`,
`requests_async_dispatched`, `c_loop_requests_total`).

When `admin_token` is set, `/-/metrics` emits Prometheus text-format
v0.0.4. Auth is via the `X-Hyperion-Admin-Token` header (same token
guards `POST /-/quit`):

```sh
$ curl -s -H 'X-Hyperion-Admin-Token: secret' http://127.0.0.1:9292/-/metrics
# HELP hyperion_requests_total Total HTTP requests handled
# TYPE hyperion_requests_total counter
hyperion_requests_total 8910
hyperion_responses_status_total{status="200"} 8521
hyperion_responses_status_total{status="404"} 12
```

Any counter not in the known set (added via
`Hyperion.metrics.increment(:custom_thing)`) is auto-exported as
`hyperion_custom_thing` with a generic HELP line. Network-isolate the
admin endpoints if the listener is internet-facing — see
[docs/REVERSE_PROXY.md](docs/REVERSE_PROXY.md) for the nginx
`location /-/ { return 404; }` recipe.

## Compatibility

| Component | Version |
|---|---|
| Ruby | 3.3+ (transitive `protocol-http2 ~> 0.26` floor) |
| Rack | 3.x |
| Rails | verified up to 8.1 |
| Linux kernel | 5.x+ for io_uring opt-in; 4.x+ otherwise |
| macOS | works (TLS, h2, WebSockets, `accept4` fallback path) |

Per-Rack-3-spec: auto-sets `SERVER_SOFTWARE`, `rack.version`,
`REMOTE_ADDR`, IPv6-safe `Host` parsing, CRLF guard. The
`Hyperion::FiberLocal.install!` opt-in shim handles the residual
`Thread.current.thread_variable_*` footgun in older Rails idioms;
modern Rails 7.1+ already uses Fiber storage natively.

## Reproducing benchmarks

Every number in this README is reproducible. Per-row commands:

```sh
# Setup (once)
bundle install
bundle exec rake compile

# Hello via Server.handle_static + io_uring (134k r/s row)
HYPERION_IO_URING_ACCEPT=1 bundle exec bin/hyperion -w 1 -t 5 -p 9292 bench/hello_static.ru &
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9292/

# Dynamic block via Server.handle (9.4k r/s row)
bundle exec bin/hyperion -w 1 -t 5 -p 9292 bench/hello_handle_block.ru &
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9292/

# Generic Rack hello (4.7k r/s row)
bundle exec bin/hyperion -w 1 -t 5 -p 9292 bench/hello.ru &
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9292/

# CPU JSON via block form (5.9k r/s row)
bundle exec bin/hyperion -w 1 -t 5 -p 9292 bench/work.ru &
wrk -t4 -c200 -d15s --latency http://127.0.0.1:9292/

# 4-way comparator (Hyperion vs Puma vs Falcon vs Agoo)
bash bench/4way_compare.sh

# gRPC unary + streaming (Hyperion side)
GHZ=/tmp/ghz TRIALS=3 DURATION=15s WARMUP_DURATION=3s bash bench/grpc_stream_bench.sh

# Idle keep-alive RSS sweep (10k conns × 30s hold)
bash bench/keepalive_memory.sh
```

PG benches (`pg_concurrent.ru`, `pg_mixed.ru`) live in the
[hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg)
companion repo — they require a running Postgres and the companion
gem.

When numbers from your host don't match the published numbers, the
most likely explanations (in order): (1) bench-host noise — single-VM
benches drift 10–30% over days; (2) Puma version mismatch (sweep used
Puma 8.0.1; the in-repo Gemfile pins `~> 6.4`); (3) different kernel
or Ruby; (4) different `-t` / `-c` (apples-to-apples requires
identical worker count, thread count, wrk concurrency, payload, and
TLS cipher).

## Release history

See [CHANGELOG.md](CHANGELOG.md). Recent: 2.14.0 (gRPC streaming ghz
numbers; dynamic-block C dispatch — `Server.handle { |env| ... }` lifts
hello to 9,422 r/s and CPU JSON to 5,897 r/s; `Server#stop` accept-wake
on Linux; io_uring 4h soak), 2.13.0 (response head builder C-rewrite;
gRPC streaming RPCs; soak harness), 2.12.0 (C connection lifecycle;
io_uring loop hits 134k r/s; gRPC unary trailers; SO_REUSEPORT
audit), 2.11.0 (HPACK CGlue default; h2 dispatch-pool warmup), 2.10.x
(`PageCache`, `Server.handle` direct routes, TCP_NODELAY at accept).

## Links

- [CHANGELOG.md](CHANGELOG.md) — per-stream releases.
- [docs/BENCH_HYPERION_2_11.md](docs/BENCH_HYPERION_2_11.md) — current
  4-way matrix + 2.14-D gRPC numbers.
- [docs/BENCH_HYPERION_2_0.md](docs/BENCH_HYPERION_2_0.md) — historical
  2.10-B baseline (preserved for archaeology).
- [docs/BENCH_2026_04_27.md](docs/BENCH_2026_04_27.md) — real Rails 8.1
  app sweep (Exodus platform).
- [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) — metrics + Grafana.
- [docs/WEBSOCKETS.md](docs/WEBSOCKETS.md) — RFC 6455 surface.
- [docs/MIGRATING_FROM_PUMA.md](docs/MIGRATING_FROM_PUMA.md) — drop-in
  guide.
- [docs/REVERSE_PROXY.md](docs/REVERSE_PROXY.md) — nginx fronting.

## Credits

- Vendored [llhttp](https://github.com/nodejs/llhttp) (Node.js's HTTP
  parser, MIT) under `ext/hyperion_http/llhttp/`.
- HTTP/2 framing and HPACK via
  [`protocol-http2`](https://github.com/socketry/protocol-http2).
- Fiber scheduler via [`async`](https://github.com/socketry/async).

## License

MIT.
