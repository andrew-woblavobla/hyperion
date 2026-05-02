# Hyperion

High-performance Ruby HTTP server. Rack 3 + HTTP/2 + WebSockets + gRPC on a single binary.

[![CI](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml/badge.svg)](https://github.com/andrew-woblavobla/hyperion/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/hyperion-rb.svg)](https://rubygems.org/gems/hyperion-rb)
[![License: MIT](https://img.shields.io/github/license/andrew-woblavobla/hyperion.svg)](https://github.com/andrew-woblavobla/hyperion/blob/master/LICENSE)

Hyperion serves a hello-world Rack response at **122,778 r/s with a 1.14 ms p99**
(median of 3 trials, peak 134,573) on a single worker — Linux 6.x, io_uring
accept loop, `Server.handle_static`, **6.7×** Agoo's 18,326 r/s on the same
hardware. Beyond the C-side fast path it's a complete Rack 3 server: HTTP/1.1
+ HTTP/2 with ALPN, WebSockets (RFC 6455), gRPC unary + streaming on the Rack
3 trailers contract, native fiber concurrency for PG-bound apps, and pre-fork
cluster mode with SO_REUSEPORT-balanced workers.

## Quick start

```sh
gem install hyperion-rb
bundle exec hyperion config.ru                          # http://127.0.0.1:9292
bundle exec hyperion -w 4 -t 10 config.ru               # 4 workers × 10 threads
bundle exec hyperion --tls-cert cert.pem --tls-key key.pem -p 9443 config.ru
```

Migrating from Puma? `hyperion -t N -w M` matching your current Puma
`-t N:N -w M` is the recommended drop-in. See
[docs/MIGRATING_FROM_PUMA.md](docs/MIGRATING_FROM_PUMA.md).

## Headline benchmarks

Linux 6.8 / 16-vCPU Ubuntu 24.04 / Ruby 3.3.3, single worker, `wrk -t4 -c100 -d20s`
unless noted. Three trials per row, median reported. Captured 2026-05-02 on
the 2.14.0 release commit. Full reproduction in
[docs/BENCH_HYPERION_2_14.md](docs/BENCH_HYPERION_2_14.md); single-command
re-bench via [`bench/run_all.sh`](bench/run_all.sh).

| Workload                                              | Hyperion r/s | Hyperion p99 | Reference            |
|-------------------------------------------------------|-------------:|-------------:|----------------------|
| Static hello, `handle_static` + io_uring              | **122,778**  | 1.11 ms      | Agoo: 18,326         |
| Static hello, `handle_static` + accept4 fallback      |       16,725 | 90 µs        | Agoo: 18,326         |
| Dynamic block, `Server.handle { \|env\| ... }`        |        8,956 | 190 µs       | Agoo: 18,326         |
| CPU JSON via block (`bench/work.ru`)                  |        5,456 | 327 µs       | Falcon: 6,394        |
| Generic Rack hello (no `Server.handle`)               |        4,231 | 2.33 ms      | Agoo: 18,326         |
| gRPC unary, h2/TLS, `ghz -c50`                        |        1,732 | 29.87 ms     | (Falcon `async-grpc` historical: 1,512) |

Peak trial on row 1: 134,573 r/s. The io_uring loop is opt-in via
`HYPERION_IO_URING_ACCEPT=1` until 2.15; the `accept4` row is the default on
Linux. Falcon and Puma both tail-latency at **>400 ms p99** on the generic
Rack hello row Hyperion serves at 2.33 ms; the closest-competitor's mean is
Hyperion's p99 — read the tail, not the throughput peak.

## Features

- **HTTP/1.1 + HTTP/2 + TLS** with ALPN auto-negotiation. Multiplexed h2
  streams on fibers; smuggling defences inline. See
  [docs/HTTP2_AND_TLS.md](docs/HTTP2_AND_TLS.md).
- **WebSockets** (RFC 6455) over Rack 3 full hijack. ActionCable +
  faye-websocket on the same listener. 463/463 autobahn cases pass. See
  [docs/WEBSOCKETS.md](docs/WEBSOCKETS.md).
- **gRPC** unary, server-stream, client-stream, bidirectional via
  Rack 3 trailers. See [docs/GRPC.md](docs/GRPC.md).
- **`Server.handle_static`** + **`Server.handle { |env| … }`** —
  C-loop direct routes that bypass the Rack adapter for hot paths.
  See [docs/HANDLE_STATIC_AND_HANDLE_BLOCK.md](docs/HANDLE_STATIC_AND_HANDLE_BLOCK.md).
- **Pre-fork cluster mode** — `SO_REUSEPORT` on Linux, master-bind on
  macOS / BSD. 1.004–1.011 max/min worker fairness ratio under steady
  load. See [docs/CLUSTER_AND_SO_REUSEPORT.md](docs/CLUSTER_AND_SO_REUSEPORT.md).
- **Async I/O** for PG-bound apps via `--async-io` +
  [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg).
  Single worker `pool=200` hits 2,381 r/s on `pg_sleep(50ms)` vs Puma's 56
  r/s. See [docs/ASYNC_IO.md](docs/ASYNC_IO.md).
- **Observability** — `/-/metrics` Prometheus endpoint, per-route
  histograms, dispatch-mode counters, kTLS gauge. Pre-built Grafana
  dashboard. See [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md).
- **Default-on structured access logs** — JSON in production, coloured
  text on TTY. Per-thread cached timestamps; ≈ 0.1 µs per logged
  request. See [docs/LOGGING.md](docs/LOGGING.md).
- **io_uring accept loop** (Linux 5.x+, opt-in) — multishot accept +
  per-conn state machine. Compiles out cleanly without liburing.
  Default-flip moves to 2.15 with a fresh 24h soak.

## Compatibility

| Component | Version |
|---|---|
| Ruby | 3.3+ |
| Rack | 3.x |
| Rails | verified up to 8.1 |
| Linux kernel | 5.x+ for io_uring opt-in; 4.x+ otherwise |
| macOS | works (TLS, h2, WebSockets, `accept4` fallback) |

## Documentation

- [BENCH_HYPERION_2_14.md](docs/BENCH_HYPERION_2_14.md) — fresh 2.14.0
  bench (this README's headline numbers, with reproduction commands).
- [BENCH_HYPERION_2_11.md](docs/BENCH_HYPERION_2_11.md) — 4-way
  matrix (Hyperion / Puma / Falcon / Agoo).
- [BENCH_2026_04_27.md](docs/BENCH_2026_04_27.md) — real Rails 8.1
  app sweep (Exodus platform).
- [CONFIGURATION.md](docs/CONFIGURATION.md) — CLI flags, env vars,
  `config/hyperion.rb` DSL.
- [OPERATOR_GUIDANCE.md](docs/OPERATOR_GUIDANCE.md) — what `-w N` /
  `-t N` / `--async-io` actually do on Rails-shaped traffic.
- [HTTP2_AND_TLS.md](docs/HTTP2_AND_TLS.md) — h2 + TLS surface.
- [WEBSOCKETS.md](docs/WEBSOCKETS.md) — RFC 6455 surface.
- [GRPC.md](docs/GRPC.md) — Rack 3 trailers + streaming RPCs.
- [HANDLE_STATIC_AND_HANDLE_BLOCK.md](docs/HANDLE_STATIC_AND_HANDLE_BLOCK.md)
  — direct-route forms.
- [CLUSTER_AND_SO_REUSEPORT.md](docs/CLUSTER_AND_SO_REUSEPORT.md) —
  cluster mode and per-OS worker model.
- [ASYNC_IO.md](docs/ASYNC_IO.md) — `--async-io` for PG-bound apps.
- [OBSERVABILITY.md](docs/OBSERVABILITY.md) — metrics + Grafana.
- [LOGGING.md](docs/LOGGING.md) — access log surface.
- [MIGRATING_FROM_PUMA.md](docs/MIGRATING_FROM_PUMA.md) — drop-in guide.
- [REVERSE_PROXY.md](docs/REVERSE_PROXY.md) — nginx fronting.

## Reproducing benchmarks

```sh
bundle install && bundle exec rake compile
./bench/run_all.sh                  # full table
./bench/run_all.sh --row 1          # single row
./bench/run_all.sh --skip-grpc      # rows 1-5 + 7-9
```

The `bench/run_all.sh` driver boots one server per row, runs `wrk` (or
`ghz` for gRPC), kills it, moves on — no concurrent runs (cross-talk
inflates noise on shared hosts). Output: CSV + markdown table at
`$OUT_CSV` / `$OUT_MD` (default `/tmp/hyperion-2.15-bench.{csv,md}`).

Per-row commands and the host snapshot live in
[docs/BENCH_HYPERION_2_14.md](docs/BENCH_HYPERION_2_14.md). When
your numbers don't match: bench-host noise drifts ±10–30% over days,
Puma version mismatch (sweep used 8.0.x; in-repo Gemfile pins
`~> 6.4`), and different `-t` / `-c` are the usual culprits.

## Release history

See [CHANGELOG.md](CHANGELOG.md). Recent: 2.14.0 (gRPC streaming
ghz; dynamic-block C dispatch; `Server#stop` accept-wake on Linux;
io_uring 4h soak), 2.13.0 (response head builder C-rewrite; gRPC
streaming RPCs), 2.12.0 (C connection lifecycle; io_uring loop;
gRPC unary trailers), 2.11.0 (HPACK CGlue default; h2 dispatch-pool
warmup), 2.10.x (PageCache, `Server.handle` direct routes,
TCP_NODELAY at accept).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `bundle install && bundle exec rake`
gives you a green test suite (1147 examples / 0 failures / 16 pending
on macOS arm64 + Ruby 3.3.3 as of 2.15-A).

## Credits

- Vendored [llhttp](https://github.com/nodejs/llhttp) (Node.js's HTTP
  parser, MIT) under `ext/hyperion_http/llhttp/`.
- HTTP/2 framing and HPACK via [`protocol-http2`](https://github.com/socketry/protocol-http2).
- Fiber scheduler via [`async`](https://github.com/socketry/async).

## License

MIT.
