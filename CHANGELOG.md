# Changelog

## [1.4.0] - 2026-04-27

Default-behaviour change for TLS users: HTTP/1.1-over-TLS now dispatches inline on the calling fiber instead of hopping through the worker thread pool. Fiber-cooperative libraries (`hyperion-async-pg`, `async-redis`) work on the TLS h1 path without `--async-io`. No code-path changes for plain HTTP/1.1 default behaviour.

### Changed
- **TLS h1 inline dispatch by default** — `Hyperion::Server#dispatch` now serves HTTP/1.1-over-TLS inline on the accept-loop fiber under `Async::Scheduler`. Rationale: the TLS path already wraps the accept loop in `Async {}` for ALPN handshake + h2 streams; handing the post-handshake socket to a worker thread strips that scheduler context for no perf benefit (the Async-loop cost is already paid) and defeats fiber-cooperative I/O on TLS. Operators no longer need to pair `--tls-cert/--tls-key` with `--async-io` to get `hyperion-async-pg` working on TLS — it just works.
- **`async_io` config is now three-way** — was Boolean (`true` / `false`, default `false`). Now `nil` (default, "auto" — pool on plain HTTP/1.1, inline on TLS h1), `true` (force inline-on-fiber everywhere — required for `hyperion-async-pg` on plain HTTP/1.1), `false` (force pool hop everywhere — explicit opt-out for the rare operator who wants TLS+threadpool, e.g. CPU-bound synchronous handlers competing for OS threads).
- **Server / Worker constructor defaults** — `Hyperion::Server#initialize` and `Hyperion::Worker#initialize` now default `async_io: nil`. `Hyperion::Config::DEFAULTS[:async_io]` is `nil`.

### Migration
- **Most users want the new default and should do nothing.** Wait-bound TLS workloads paired with fiber-cooperative I/O libraries (async-pg, async-redis) are now strictly faster on TLS — no flag flip required.
- **CPU-bound TLS handlers that want true OS-thread parallelism** (synchronous Rack handlers holding a global mutex, no Async-aware libraries in the stack) should set `async_io false` in their `config/hyperion.rb` (or pass `async_io: false` to `Server.new`). This restores the 1.3.x pool-hop behaviour for TLS h1.
- The plain HTTP/1.1 default path is unchanged: still pool dispatch, still the raw-loop perf-bypass; `--async-io` / `async_io: true` semantics for plain HTTP/1.1 are unchanged.

### Added
- **`spec/hyperion/server_tls_dispatch_spec.rb`** — three new examples covering the matrix (nil + TLS → inline; false + TLS → pool; true + TLS → inline). Behavioural assertions verify `Fiber.scheduler` presence and which OS thread ran the handler (accept-loop vs pool worker).
- **README** — TLS + async-pg note rewritten for 1.4.0; config-DSL example block now documents the three-way `async_io` setting.

### Fixed
- N/A — pure default-behaviour change with explicit opt-out.

## [1.3.1] - 2026-04-27

Documentation + observability follow-ups for the 1.3.0 `--async-io` feature. No behaviour changes to existing code paths.

### Added
- **Dispatch-path metrics** — `Hyperion::Server` now bumps two new counters so operators can verify which path served their requests:
  - `:requests_threadpool_dispatched` — HTTP/1.1 connection handed to the worker pool (or served inline in `start_raw_loop` when `thread_count: 0`).
  - `:requests_async_dispatched` — HTTP/1.1 connection served inline on the accept-loop fiber under `--async-io`.
  HTTP/2 streams are not bucketed (per-stream counters cover them); the rare TLS+`thread_count: 0` config is also un-counted to avoid misclassification.
- **`docs/MIGRATING_FROM_PUMA.md`** — new "Fiber-cooperative I/O for PG-bound apps" section near the top, with the Linux 50 ms `pg_sleep` bench summary and the three-prerequisite checklist (`async_io: true` + `hyperion-async-pg` + fiber-aware pool).
- **README** — `async_io` documented in the config-DSL example block; the new dispatch-path counters listed in the Metrics table.
- **Specs** — two new examples in `spec/hyperion/server_async_io_spec.rb`:
  - `async_io: true` + `thread_count: 0` boots cleanly and serves a request under a scheduler.
  - Thread-decoupling proof: 5 concurrent requests against a 200 ms fiber-yielding handler complete in <600 ms wall (vs. ~1.0 s if serialized), locking in the architectural promise from the README.

### Changed
- N/A — no behavioural changes; metrics are additive, docs are additive.

### Fixed
- N/A.

## [1.3.0] - 2026-04-27

Adds the structural moat for fiber-cooperative I/O. No breaking changes.

### Added
- **`async_io: true` config flag** (also `--async-io` CLI flag) — when enabled, the plain HTTP/1.1 accept loop runs each connection on a fiber under `Async::Scheduler` instead of handing it to a worker thread. This is what makes [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg) (and other Async-aware libraries) actually cooperate: each fiber yields the OS thread on socket waits, so one thread can serve N concurrent in-flight DB queries instead of 1. **Default off** to keep the 1.2.0 raw-loop perf for fiber-unaware apps. Trade-off: ~5% throughput hit on hello-world; 5–10× throughput on PG-bound workloads when paired with hyperion-async-pg + a fiber-aware connection pool.
- **Bench validation (macOS, 50ms PG round-trip, 200 concurrent wrk conns):**

  | | r/s | p99 |
  |---|---:|---:|
  | Puma 7.2 `-t 5` + plain pg (pool=5) | 88.9 | 2.31 s |
  | **Hyperion 1.3.0 `--async-io -t 5` + hyperion-async-pg (FiberPool=64)** | **1,103.7** | **237 ms** |

  **12.4× throughput, 9.7× lower p99.** Theoretical ceiling at pool=64 + 50ms query is ~1280 r/s; achieved 86% of it. Linux numbers will land in a follow-up bench section.

### Changed
- TLS / HTTP/2 paths still always use the Async accept loop (unchanged); they ignore the `async_io` flag because they need the scheduler for ALPN handshake yields and per-stream fiber dispatch anyway.
- When `async_io: true`, plain HTTP/1.1 dispatch bypasses the thread pool and serves the connection inline on the calling fiber. The pool stays in use for the TLS path's `app.call` hops on each h2 stream.

## [1.2.0] - 2026-04-27

Production hardening + perf round 2. No breaking changes.

### Added
- **Zero-copy sendfile path** — when a Rack body responds to `#to_path` (e.g. `Rack::Files`, asset uploads), `ResponseWriter` uses `IO.copy_stream(file, socket)` which triggers `sendfile(2)` on Linux for plain TCP. Eliminates the ~MB-sized String allocation per static-asset response. Falls back to userspace copy on TLS / non-Linux but still avoids the userspace String build. New metrics: `:sendfile_responses`, `:tls_zerobuf_responses`.
- **Hot fork warmup (`Hyperion.warmup!`)** — master pre-allocates the Rack env Hash pool, primes the C extension's lazy state, and touches commonly-resolved constants before `before_fork`. Workers inherit the warm pools via Copy-on-Write. Removes first-N-requests-after-fork allocation tax.
- **Backpressure (`max_pending`)** — when the thread pool's inbox queue exceeds the configured depth, new accepts get HTTP 503 + `Retry-After: 1` and the socket is closed immediately (no Rack dispatch, no access-log line). Default off (nil); opt in by setting an Integer. New metric: `:rejected_connections`.
- **Prometheus exporter** — `AdminMiddleware` now serves `GET /-/metrics` in addition to `POST /-/quit` (same token). Renders `Hyperion.stats` as Prometheus text exposition v0.0.4. Counter names follow the `hyperion_<key>_total` convention; `:responses_<code>` keys are grouped under `hyperion_responses_status_total{status="<code>"}`.
- **Slow-client total-deadline (`max_request_read_seconds`)** — per-request wallclock cap on the request-line + headers read phase (default 60s). Defense-in-depth against slowloris: a malicious client can no longer dribble 1 byte per `read_timeout` window indefinitely. On overrun, Hyperion writes 408 + closes. Resets per request on keep-alive sessions. New metric: `:slow_request_aborts`.
- **HTTP/2 SETTINGS tuning** — Falcon-class defaults shipped: `MAX_CONCURRENT_STREAMS=128`, `INITIAL_WINDOW_SIZE=1MiB`, `MAX_FRAME_SIZE=1MiB`, `MAX_HEADER_LIST_SIZE=64KiB`. All four overridable via Config DSL (`h2_max_concurrent_streams` etc). Out-of-spec values are clamped + warned, not crashed.
- **`docs/REVERSE_PROXY.md`** — nginx + AWS ALB samples, X-Forwarded-* semantics, admin-endpoint hardening at the edge. Includes the documented gotcha that ALB-to-target HTTP/2 strips WebSocket upgrade headers (use HTTP/1.1 upstream).

### Changed
- **`ResponseWriter` Date header now uses `cached_date`** — the per-thread, per-second cache landed in 1.1.0 was never wired into the hot path. It is now. Eliminates ~3 String allocations per response (`Time.now.httpdate` → cached String reuse).
- **`AdminMiddleware`** refactored: shared `authorize` helper between `/-/quit` and `/-/metrics`; `PATH` constant split into `PATH_QUIT` + `PATH_METRICS`.
- **`Hyperion::Logger` per-thread access buffer key** is now namespaced per Logger instance (already shipped as a 1.1.0 follow-up fix; documented here for completeness).

### Fixed
- N/A — no regressions discovered between 1.1.0 and 1.2.0.

## [1.1.0] - 2026-04-27

First minor release after 1.0.0. Production hardening + perf wins, no breaking changes.

### Added
- **HTTP/2 §8.1.2 semantic validation** — Hyperion now rejects malformed `:method` / `:path` / `:scheme` pseudo-headers, connection-specific headers (`connection`, `te`, `transfer-encoding`, `keep-alive`, `upgrade`, `proxy-connection`), and inconsistent `content-length` framing with `RST_STREAM PROTOCOL_ERROR`. h2spec conformance pass rate is now 100% on the §8.1.2 suite (was 76.7% in 1.0.x).
- **Worker recycling (`worker_max_rss_mb`)** — master polls each child's RSS via `/proc/<pid>/statm` (Linux) or `ps -o rss=` (macOS/BSD) every `worker_check_interval` seconds (default 30s). Workers exceeding the configured RSS ceiling are gracefully cycled (SIGTERM, drain, respawn). Disabled when `worker_max_rss_mb` is nil.
- **Admin drain endpoint (`POST /-/quit`)** — token-protected Rack middleware that triggers the same SIGTERM-driven graceful shutdown as the signal path. Disabled by default; mount by setting `admin_token` in the Hyperion config DSL. Auth via `X-Hyperion-Admin-Token` header (constant-time comparison). Returns 202 + `{"status":"draining"}` on success, 401 on missing/wrong token.
- **YJIT auto-enable** — Hyperion enables YJIT automatically in production/staging environments (`RAILS_ENV` / `RACK_ENV` / `HYPERION_ENV`). Override with the `yjit` config setting (true/false) or `--[no-]yjit` CLI flag. No-op on Rubies built without YJIT.
- **C-extension access-log line builder** (`Hyperion::CParser.build_access_line`) — single-allocation line construction in C, ~10× faster than the Ruby interpolation path. Auto-selected on non-TTY destinations (production); colored TTY runs keep the Ruby fallback.
- **Date-header cache** — per-thread, per-second cache of `Time.now.httpdate` in `ResponseWriter`. Eliminates ~3 String allocations per response.
- **`bytes_read` / `bytes_written` metrics** — counters exposed via `Hyperion.stats` for connection-level bandwidth monitoring.
- **`Hyperion.c_parser_available?`** module accessor + boot-time warn line if the llhttp C extension didn't load (so operators running production with the slower pure-Ruby fallback notice immediately).
- **`MIGRATING_FROM_PUMA.md`** — operator guide covering config translation, lifecycle hook mapping, signal differences, and observability gaps.
- **Concurrency-at-scale benchmarks** — README now documents 10 000-connection keep-alive throughput and h2 multiplexing numbers vs Puma/Falcon.

### Changed
- **Plain HTTP/1.1 accept loop bypasses Async** — when no TLS is configured, Hyperion uses a raw `IO.select` + `accept_nonblock` loop instead of wrapping the loop in an Async task. Worker-owns-connection semantics are unchanged. Removes ~2 µs of fiber-scheduler overhead from the hot accept path.

### Fixed
- **Lost shutdown log lines under SIGTERM** — `Master#shutdown_children` and `CLI.run_single` now call `Logger#flush_all`, which walks every per-thread access-log buffer registered through the Logger and `IO#flush`es both stdout and stderr before the process exits. Operators no longer have to chase missing `master draining` / `master exiting` lines after a graceful shutdown.
- **Cross-instance Logger buffer leak** — per-thread access-log buffers are now namespaced per Logger instance (`:"__hyperion_access_buf_<oid>__"`). Previously a globally-shared key meant a buffer registered against an early Logger could be written to by a later Logger whose `flush_all` couldn't see it. The hot path remains a single `Thread.current` read.

## [1.0.1] - 2026-04-26

### Fixed
- Bumped `required_ruby_version` floor from `>= 3.2.0` to `>= 3.3.0` to match actual transitive dependency reality (`protocol-http2 ~> 0.26` requires Ruby >= 3.3). Previously, installing on Ruby 3.2 produced an opaque dep-resolution error mentioning protocol-http2 instead of a clean Ruby-version mismatch.
- CI matrix dropped `3.2.x` for the same reason.

## [1.0.0] - 2026-04-26

First stable release. Same code as rc18; promoted from prerelease after smoke
install + memory profile + cross-platform CI verification.

## [1.0.0.rc18] - 2026-04-26

### Fixed
- **Silent stdout when redirected** — `Logger#initialize` now sets `@out.sync = @err.sync = true` on real `IO` destinations so log lines reach the consumer immediately even when stdout is piped (Docker, systemd, kubectl logs). Without this, Ruby/glibc 4-KiB block-buffered short writes and operators saw nothing until the buffer filled.
- **Bundler auto-require footgun** — added `lib/hyperion-rb.rb` 1-line shim so `gem 'hyperion-rb'` in a Gemfile (with implicit auto-require) works without `require: 'hyperion'`. The canonical `require 'hyperion'` continues to work.

### Added
- **TLS chain support** — `--tls-cert PATH` now parses a multi-cert PEM (leaf + intermediate). The leaf is presented as the server cert; subsequent certs become `extra_chain_cert` so production deployments with intermediate CAs work without manual config gymnastics. New spec covers the 2-cert chain handshake.

## [1.0.0.rc17] - 2026-04-26

### Performance
- **C-extension response head builder** (`Hyperion::CParser.build_response_head`).
  Per-response status-line, normalized hash, and per-header String#<< allocations now happen in C — same wire output, ~44% faster on the synthetic head-build microbench (430 k vs 298 k writes/sec on macOS).
- `ResponseWriter` keeps a pure-Ruby `build_head_ruby` fallback for JRuby / TruffleRuby / build failures; behaviour is identical.
- Ships alongside the frozen `HTTP_KEY_CACHE` Rack-adapter optimisation already on the rc16 tip.

## [1.0.0.rc16] - 2026-04-26

### Changed
- **Logger split (12-factor)**: `info` / `debug` route to stdout; `warn` / `error` / `fatal` route to stderr. Previously everything went to stderr.
- `Logger.new` accepts `out:` and `err:` kwargs (default `$stdout` / `$stderr`); `io:` kwarg still works as a back-compat alias for tests.
- Per-request access logs go to **stdout** (info level).

All notable changes to Hyperion are documented here.

## [1.0.0.rc15] - 2026-04-26

### Added
- **Per-OS worker model**: master auto-detects host OS and picks the right multi-worker strategy.
  - **macOS / BSD**: master binds the listening socket once, forks workers that inherit the FD (Puma's pattern). Single accept queue, race-fair across workers.
  - **Linux**: each worker independently binds with `SO_REUSEPORT` (kernel-fair distribution, no thundering herd).
  - Override via `HYPERION_WORKER_MODEL=share|reuseport`.
- macOS `-w 4` now scales correctly: hello-world bench at `-w 4 -t 10` serves 44 k r/s vs Puma's 38 k r/s (1.17× throughput, 15× lower p99).

### Fixed
- macOS `SO_REUSEPORT` distribution issue (Darwin's kernel funnels connections to one socket, never load-balancing siblings). The share-model fix sidesteps it entirely.

## [1.0.0.rc14] - 2026-04-26

### Added
- **Ruby DSL config file** (`config/hyperion.rb`) with the same shape as Puma's `config/puma.rb`. Auto-loaded if present in cwd; explicit path via `-C / --config PATH`.
- **Lifecycle hooks**: `before_fork`, `on_worker_boot`, `on_worker_shutdown`. Same API as Puma's hooks.
- DSL settings: `bind`, `port`, `workers`, `thread_count`, `tls_cert_path`, `tls_key_path`, `read_timeout`, `idle_keepalive`, `graceful_timeout`, `max_header_bytes`, `max_body_bytes`, `log_level`, `log_format`, `log_requests`, `fiber_local_shim`.
- `config/hyperion.example.rb` with documented sample config.
- Strict DSL: unknown methods raise `NoMethodError` at boot — typos surface immediately.

### Changed
- Precedence: explicit CLI flag > env var > config file > built-in default.

## [1.0.0.rc13] - 2026-04-26

### Changed
- **Per-request access logs default ON** (matches Puma + Rails operator expectations). Disable with `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
- Logger emit is now lock-free: dropped the per-write mutex (POSIX `write(2)` is atomic for writes ≤ PIPE_BUF).
- Access-log hot path: per-thread cached iso8601 timestamp, hand-rolled single-interpolation line builder, per-thread 4 KiB write buffer flushed in Connection's `ensure`.

### Performance
- Default-ON Hyperion still beats Puma: hello-world at `-t 16` serves 20 k r/s vs Puma's 19 k r/s, with 24× lower p99 — and Hyperion emits 200 k+ access lines that Puma doesn't.

## [1.0.0.rc12] - 2026-04-26

### Added
- `--log-requests` flag (initially default OFF) emitting one structured INFO line per response.

## [1.0.0.rc11] - 2026-04-26

### Added
- Smart log format auto-detect: `--log-format auto` (default).
  - `RAILS_ENV` / `RACK_ENV` / `HYPERION_ENV` ∈ `{production, staging}` → JSON.
  - Stderr is a TTY → colored text (ANSI level colors).
  - Otherwise (piped output, no env hint) → JSON.

## [1.0.0.rc10] - 2026-04-26

### Changed
- **Lock-free per-thread metrics counters**, no global mutex. Hot-path cost: one TLS lookup + one Hash op per increment.
- Connection caches `Hyperion.logger` and `Hyperion.metrics` once at init so the request loop skips method dispatch.

## [1.0.0.rc9] - 2026-04-26

### Added
- `Hyperion::Logger` — structured logger with levels (`debug`, `info`, `warn`, `error`, `fatal`), text + JSON formats. Hash-based payload: `logger.info { { message: 'foo', key: val } }`.
- `Hyperion::Metrics` — `Hyperion.stats` returns a hash of counters: `connections_accepted`, `connections_active`, `requests_total`, `requests_in_flight`, `responses_<code>`, `parse_errors`, `app_errors`, `read_timeouts`.

## [1.0.0.rc8] - 2026-04-26

### Changed
- **Worker thread owns the HTTP/1.1 connection** (Puma's model). The `app.call(env)` per-request hop through a cross-thread Queue is gone.
- `ThreadPool#submit_connection(socket, app)` hands the entire connection to a worker thread; workers run `Connection#serve` directly with no pool indirection.
- HTTP/2 path keeps fiber-per-stream (correct because h2 multiplexes streams onto one socket).

### Performance
- Microbench: per-connection serve goes from 12 k r/s (rc7 hop-per-request) to 29 k r/s (rc8 worker-owns).
- Hello-world `-t 16`: 1.27× Puma throughput, 30× lower p99.

## [1.0.0.rc7] - 2026-04-26

### Performance
- Pooled the per-call reply `Queue` in `ThreadPool` (was `Queue.new` on every dispatch).
- Inlined `Connection#read_chunk`'s hot path.

## [1.0.0.rc6] - 2026-04-26

### Added
- Production-mode Rails benchmark suite. At Puma's default 3-thread config Hyperion `-t 16` serves 3.18× Puma's throughput with 2.10× lower p99.

## [1.0.0.rc5] - 2026-04-26

### Added
- **Hybrid async/thread-pool architecture**: accept/parse/write stays on fibers; `app.call(env)` dispatched to OS-thread pool (default 5, `-t/--threads N`).

## [1.0.0.rc4] - 2026-04-26

### Fixed
- Adapter sets `REMOTE_ADDR` from socket peer (was missing — broke Rack::Attack and any IP-based middleware).
- Pinned `openssl < 4.0` so apps mutating `OpenSSL::SSL::SSLContext::DEFAULT_PARAMS` (e.g. AWS SDK initializers) don't crash on boot.

## [1.0.0.rc3] - 2026-04-26

### Added
- HTTP/2 dispatch via `protocol-http2` with per-stream fiber multiplexing and WINDOW_UPDATE-aware flow control.
- rake-compiler integration: `bundle exec rake compile` builds the C ext.

## [1.0.0.rc1] - 2026-04-26

### Added
- TLS + ALPN (HTTPS over HTTP/1.1; HTTP/2 via ALPN handshake).
- FiberLocal compatibility shim (`Hyperion::FiberLocal.install!`) for Rails apps using `Thread.current.thread_variable_*`.
- Object pooling for Rack `env` Hash and `rack.input` StringIO.
- Vendored llhttp 9.3.0 C parser (`Hyperion::CParser`); falls back to pure-Ruby `Hyperion::Parser`.
- Pre-fork cluster (`-w N`); graceful shutdown with 30 s drain.
- `Async::Scheduler` integration; fiber per connection.
- HTTP/1.1 keep-alive, pipelining, chunked Transfer-Encoding.
- Smuggling defenses: `Content-Length` + `Transfer-Encoding` together → 400; non-chunked TE → 501.

## v0.0.1 - 2026-04-26

### Added
- Phase 1 skeleton: pure-Ruby HTTP/1.1 parser, Rack 3 adapter, Connection state machine, Server accept loop, CLI.
