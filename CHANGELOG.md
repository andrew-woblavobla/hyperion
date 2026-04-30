# Changelog

## [Unreleased] — 2.1.0

### Rack 3 hijack support (WS-1)

`env['rack.hijack?']` now returns `true`; `env['rack.hijack']` returns a
callable that detaches the underlying socket from Hyperion's request
lifecycle. After the app calls `env['rack.hijack'].call`:

* Hyperion does NOT write a response on the wire — the Rack tuple
  returned from `app.call(env)` is ignored, per the Rack 3 spec.
* The socket is removed from Hyperion's read/write rotation. The accept
  loop / writer fiber will not touch it again.
* Hyperion does NOT close the socket on connection cleanup or worker
  shutdown — the application owns it. `Connection#close` becomes a
  no-op for the close branch on the hijack path.
* The connection is removed from keep-alive accounting; the next
  request from this client is a fresh connection.

Both dispatch modes are covered: the inline (per-fiber) path and the
thread-pool path. The hijack proc captures the `Hyperion::Connection`
(not the socket directly) so the `@hijacked` flag is observed by the
connection fiber the moment the app evaluates the proc, regardless of
which thread the proc runs on.

Hyperion-specific extension: `env['hyperion.hijack_buffered']` exposes
any bytes the connection had buffered past the parsed request boundary
(pipelined keep-alive carry, or — for an Upgrade — bytes the client
sent immediately after the request headers). The application is
responsible for consuming these before reading from the hijacked socket.

Foundation for native WebSocket support (WS-2 through WS-5).

#### Scope notes

* HTTP/1.1 only. Rack 3 hijack over HTTP/2 requires Extended CONNECT
  (RFC 8441 / RFC 9220) and is intentionally NOT plumbed in this
  release. h2 streams continue to see `env['rack.hijack?'] == false`.
* Partial hijack (response-headers `'rack.hijack'` callback that
  receives the writer-side IO) is not yet implemented. Apps that need
  streaming should keep using the existing chunked transfer-encoding
  path; a follow-up will add partial hijack once full hijack lands.

## [2.0.1] - 2026-04-30

Phase 8 — close the last two static-file rps gaps. Hyperion 2.0.0 still
lost Puma 8.0.1 on rps for two workloads on the 2026-04-29 sweep:
8 KB static at default `-t 5 -w 1` (121 r/s vs Puma 1,246 — 10× loss)
and 1 MiB static at the same shape (1,809 r/s vs 2,139 — -15%). 2.0.1
fixes both.

### Headline bench (openclaw-vm 16 vCPU, kernel 6.8.0)

Side-by-side `-t 5 -w 1` against Puma 8.0.1, `wrk -t4 -c100 -d20s`:

| Workload | Hyperion 2.0.0 | Hyperion 2.0.1 | Puma 8.0.1 | 2.0.1 vs Puma |
|---|---:|---:|---:|---:|
| Static 8 KB r/s | 121 | **1,483** | 1,366 | **+8.6% rps** |
| Static 8 KB p99 | 43.85 ms | **4.81 ms** | 84.38 ms | **17.5× lower** |
| Static 1 MiB r/s | 1,809 | **1,697** | 1,330 | **+27.6% rps** |
| Static 1 MiB p99 | 4.37 ms | **5.14 ms** | 92.86 ms | **18× lower** |

Hyperion now wins **both** rows on rps and p99. The 2.0.0 caveat
section documenting the static-8 KB regression is retired.

### Phase 8a — small-file fast path (response_writer.rb)

The 2.0.0 8 KB row's diagnosis turned out to be **Nagle/delayed-ACK
stall**, not the EAGAIN-yield-retry storm hypothesised in the BENCH
report. With kernel-default Nagle on, `io.write(head)` (~150 B
status line + headers) followed by a separate `write(body)` for the
8 KB asset stalled ~40 ms per response on the client's delayed-ACK
waiting for the next packet to fill the next MSS. Hence ~25
responses per second per keep-alive connection — exactly the 121 r/s
floor across 5 wrk threads.

Fix: in `ResponseWriter#write_sendfile`, when `file_size <= 64 KiB`
read the body bytes inline and concatenate onto the head buffer,
emitting head + body as one `io.write` call. The response goes out
as one TCP segment train, the client ACKs the whole response, and
the second-write delayed-ACK stall disappears entirely. **No
TCP_NODELAY setsockopt churn required** — large-file streaming
still benefits from Nagle's coalescing across sendfile chunks.

### Phase 8b — Linux splice(2) primitive (kept, but not in production path)

The C ext now ships a `Sendfile.copy_splice` primitive for callers
that need explicit pipe-tee semantics: file_fd → per-thread pipe →
sock_fd with `SPLICE_F_MOVE | SPLICE_F_MORE`, fully kernel-side
zero-copy. Per-thread pipe pair cached in a `pthread_key_t` with a
destructor closing both fds at thread exit (no fd leak across
worker fiber lifecycles). Pipe sized to 1 MiB via `F_SETPIPE_SZ`
where supported.

**Disabled on the production hot path.** A correctness window was
discovered during 1 MiB bench: if `splice(file → pipe)` succeeds
but `splice(pipe → sock)` fails mid-transfer with EPIPE (peer
closed), unread bytes stay in the pipe and would be sent on the
NEXT connection's socket. The persistent per-thread pipe is the
hazard. `copy_to_socket` now stays on plain `sendfile(2)` for files
> 64 KiB — well-tested, no residual-bytes window, and thanks to
fiber-per-connection scheduling the 1 MiB row beats Puma by +27%
without the splice path. The primitive remains exposed for future
use behind explicit per-request pipe-pair management.

### New small-file C primitive (Sendfile.copy_small)

For callers driving the sendfile module directly (bypassing the
ResponseWriter coalescer), `Sendfile.copy_small(out_io, in_io,
offset, len)` reads `len <= 64 KiB` into a heap buffer with `pread`
and writes it under the GVL released. EAGAIN polled with a short
`select()` (5 × 10 ms) instead of fiber-yielding — appropriate for
small slices where the kernel send buffer is empty and the transfer
finishes in microseconds. Used by the Ruby façade as a backup
fast-path when ResponseWriter coalescing isn't applicable.

### Specs

- 530 examples (was 521) — +9 specs covering small-file routing,
  threshold boundaries, and the splice primitive.
- 0 failures, 2 pending (host-gated: macOS skips Linux-splice spec,
  Linux skips macOS-only fallback assertion).

### Files changed

- `ext/hyperion_http/sendfile.c` — `copy_small`, `copy_splice`,
  `splice_supported?`, `small_file_threshold` C primitives;
  per-thread pipe pair via `pthread_key_t`. Linux-splice gated by
  `#ifdef __linux__`; rest unchanged. Compiles cleanly on macOS
  arm64 and Linux x86_64.
- `lib/hyperion/http/sendfile.rb` — façade routes `<= 64 KiB` to
  `copy_small`; streaming branch stays on plain `copy` (sendfile).
- `lib/hyperion/response_writer.rb` — `write_sendfile` coalesces
  head + body into one write for `file_size <= 64 KiB`.
- `spec/hyperion/http_sendfile_spec.rb` — new specs for small-file
  routing, threshold boundary, splice primitive byte-integrity.

## [2.0.0] - 2026-04-29

RFC §3 2.0.0 — the breaking-removal release that closes the deprecation
cycle opened in 1.8.0, plus Phase 6 of the perf overhaul: a Rust
HPACK encoder/decoder shipped as `ext/hyperion_h2_codec` with
graceful fallback to `protocol-http2` when Rust isn't available at
install time.

This is the largest API-surface change since 1.0. Operators on the
1.8 line who paid attention to the deprecation warns have no further
action to take; operators jumping from 1.6.x straight to 2.0 should
read the migration table in [docs/RFC_2_0_DESIGN.md §4](docs/RFC_2_0_DESIGN.md).

### Breaking changes (removals from 1.8 deprecations)

- **Flat-name DSL keys removed.** All 13 flat keys
  (`h2_max_concurrent_streams`, `h2_initial_window_size`,
  `h2_max_frame_size`, `h2_max_header_list_size`, `h2_max_total_streams`,
  `admin_token`, `admin_listener_port`, `admin_listener_host`,
  `worker_max_rss_mb`, `worker_check_interval`, `log_level`,
  `log_format`, `log_requests`) no longer parse on the Ruby DSL.
  `Hyperion::Config.load` raises `NoMethodError` from the DSL
  evaluator if a config file uses them. Migration: wrap in the nested
  block (`h2 do; max_concurrent_streams 256; end`, `admin do; token
  ENV['T']; end`, etc — see the migration table in the RFC).

  CLI flags keep their flat operator-facing spellings unchanged
  (`--admin-token`, `--worker-max-rss-mb`, `--log-level`, …); only
  the in-Ruby DSL surface lost the flat names.

- **`Hyperion.metrics =` / `Hyperion.logger =` setters removed.** The
  module-level writers no longer exist (the readers stay as
  `Runtime.default` delegators for REPL convenience).

  Migration recipes:
  ```ruby
  # before
  Hyperion.metrics = MyMetricsAdapter.new

  # after — option A: mutate the default Runtime in-place
  Hyperion::Runtime.default.metrics = MyMetricsAdapter.new

  # after — option B: per-Server isolation (preferred for new code)
  runtime = Hyperion::Runtime.new(metrics: MyMetricsAdapter.new)
  Hyperion::Server.new(app: my_app, runtime: runtime).start
  ```

- **Dual-emit Prometheus keys retired.** 1.7.0 introduced per-mode
  dispatch counters (`:requests_dispatch_threadpool_h1`,
  `:requests_dispatch_tls_h2`, etc.) and dual-emitted the legacy
  `:requests_async_dispatched` / `:requests_threadpool_dispatched`
  alongside them. 2.0 keeps only the per-mode keys. Operators on
  Grafana dashboards from the 1.x line had two minor releases
  (1.7→1.8) to migrate; the legacy keys are simply gone now.

- **Default flip on `h2.max_total_streams`.** The 1.7→1.8 default
  was nil (admission control disabled). 2.0 defaults to
  `max_concurrent_streams × workers × 4`, computed at config-finalize
  time once the worker count is known. The headroom factor (4×) is
  large enough that no realistic legitimate workload trips the cap;
  the abuse path (5,000 conns × 128 streams = 640k fibers → OOM)
  closes by default.

  Per-worker example caps:
  - 1 worker:  cap = 128 × 1 × 4 =   512
  - 4 workers: cap = 128 × 4 × 4 =  2,048
  - 32 workers: cap = 128 × 32 × 4 = 16,384

  Operator override:
  ```ruby
  h2 do
    max_total_streams :unbounded   # restore pre-2.0 unbounded
    # or:
    max_total_streams 8192         # explicit fixed cap
  end
  ```

### Phase 6 — Rust HPACK + h2 frame codec

New native extension at `ext/hyperion_h2_codec`:

- Self-contained, zero-dependency Rust crate (RFC 7541 HPACK
  encoder/decoder + RFC 7541 Appendix B static Huffman decoder +
  RFC 7540 §6 frame primitives).
- Exposed to Ruby via `extern "C"` + Fiddle (`lib/hyperion/h2_codec.rb`).
  No magnus, no transitive crate fetching at install time.
- ABI version guard — Ruby refuses to load a binary that disagrees
  with `EXPECTED_ABI`, so a stale on-disk codec from a prior install
  can't crash the process.
- `Hyperion::H2Codec.available?` reports load state. `Encoder` /
  `Decoder` are instance-per-connection, hold owned Rust pointers,
  finalize via `ObjectSpace.define_finalizer`.

Microbench (50,000 iterations, M2 Pro, opt-level=3 LTO):

| Operation     | Rust (us/op) | protocol-hpack (us/op) | speedup |
|---------------|--------------|------------------------|---------|
| HPACK encode  | 9.0          | 29.2                   | 3.26×   |
| HPACK decode  | 6.3          | 12.5                   | 1.98×   |

The h2load wire-level bench (`bench/h2_post.ru` + `h2load -c 1 -m 100
-n 5000`) was not run on the Mac dev host (h2load isn't installed
locally) — operators on Linux should re-run to confirm the 4,000+
r/s target.

#### Fallback path

The codec is opt-in at runtime. When `cargo` is missing or the build
fails (`gem install` on a host without Rust), `extconf.rb` writes a
no-op Makefile and gem install completes — Hyperion boots with
`H2Codec.available? == false` and serves h2 traffic via
`protocol-http2`'s Ruby HPACK exactly as it did in 1.x.

`Http2Handler#codec_native?` reports the per-handler view; the boot
log carries a one-shot info line per process:

```json
{"message":"h2 codec selected","mode":"native (Rust)","native_available":true}
```

Two new metrics counters bump on first construction:
`:h2_codec_native_selected` or `:h2_codec_fallback_selected`.

### Phase 6c (deferred to 2.x)

The connection state machine + framer continue to be driven by
`protocol-http2` for now. Splicing the native codec directly into
the framer's encode/decode hot paths requires unifying the framer
abstraction layer; that work lands in a 2.x point release once the
production rollout shows the boot probe is green and the encoder/
decoder paths haven't surfaced any RFC edge case the static-table-
+-Huffman-only encoder doesn't cover.

### Spec count

499 (1.8.0) → 521 (2.0.0). +22 examples covering: removed-API
smoke checks, default flip arithmetic + sentinel handling, RFC 7541
C.2.1 + C.4.1 vectors, 100-iter random round-trip, native/fallback
gating, Http2Handler codec_native? readback, one-shot boot log.

### Migration checklist (1.x → 2.0)

1. Search your `config/hyperion.rb` for any of the 13 flat DSL keys.
   Wrap each in its nested block. The 1.8.0 deprecation log already
   listed the rewrite per key.
2. Search your application for `Hyperion.metrics =` /
   `Hyperion.logger =`. Replace with `Hyperion::Runtime.default.metrics =`
   (in-place mutation) or pass a custom `Runtime` to
   `Hyperion::Server.new`.
3. If your Grafana boards still query `requests_async_dispatched` /
   `requests_threadpool_dispatched`, migrate the queries to
   `requests_dispatch_<mode>` (5 mode keys; see
   `lib/hyperion/dispatch_mode.rb` for the canonical list).
4. If you have an h2-heavy multi-tenant edge with extreme stream
   fan-out (>`max_concurrent_streams × workers × 4` simultaneous
   streams across the process), set
   `h2 do; max_total_streams :unbounded; end` to restore the
   pre-2.0 unbounded behaviour.
5. (Optional) If `cargo` is on your build hosts, `gem install
   hyperion-rb` will produce the native HPACK codec automatically
   and the boot log will report `mode: native (Rust)`. Otherwise
   you stay on the protocol-http2 fallback with no action needed.

---

## [1.8.0] - 2026-04-29

RFC §3 1.8.0 deprecation wave + Phase 4 TLS session resumption. Two
work streams in one minor: every API the RFC marks for removal in 2.0
now emits a one-shot deprecation warn through the runtime logger, and
the TLS context turns on server-side session caching + RFC 5077 ticket
resumption with operator-driven SIGUSR2 key rotation. Behaviour of the
deprecated APIs is unchanged — the warn is purely advisory.

### Deprecations (1.8.0 emits, 2.0.0 removes)

- **Flat-name DSL keys.** All 13 flat config keys
  (`h2_max_concurrent_streams`, `h2_initial_window_size`,
  `h2_max_frame_size`, `h2_max_header_list_size`, `h2_max_total_streams`,
  `admin_token`, `admin_listener_port`, `admin_listener_host`,
  `worker_max_rss_mb`, `worker_check_interval`, `log_level`,
  `log_format`, `log_requests`) now emit a deprecation warn at boot
  identifying the nested-DSL replacement. The CLI flag surface
  (`--admin-token`, `--worker-max-rss-mb`, etc.) is unchanged — only the
  Ruby DSL form warns. `merge_cli!` does NOT trigger the warn so
  `--log-level info` from a launcher script stays quiet.
- **`Hyperion.metrics =` / `Hyperion.logger =` setters.** Both
  module-level setters now emit a deprecation warn pointing at the
  Runtime injection path (`Hyperion::Runtime.new(metrics: …)` +
  `Hyperion::Server.new(runtime:)`). In-tree CLI bootstrap was
  rerouted to write `Hyperion::Runtime.default.logger = …` directly so
  the canonical CLI path doesn't deprecation-warn itself.
- **`Hyperion::AsyncPg.install!(activerecord: true)`** — N/A in this
  repo. Lives in the `hyperion-async-pg` companion gem; deprecation
  ships there.

Each warn fires once per process via `Hyperion::Deprecations.warn_once`
with a per-key dedup table. Tests can suppress via
`Hyperion::Deprecations.silence!` (the spec-suite default) and assert
on warn output via `unsilence!` + a sink-logger swap on
`Hyperion::Runtime.default`.

### Phase 4 — TLS session resumption ticket cache + SIGUSR2 rotation

- **`Hyperion::TLS.context` enables `SESSION_CACHE_SERVER`** with a
  20_480-entry LRU cap (≈16 MiB at 800 B/session) and a stable
  per-process `session_id_context` so cache lookups cross worker
  boundaries when the master inherits a single listener fd
  (`:share` model).
- **RFC 5077 session tickets are explicitly enabled** by clearing
  `OP_NO_TICKET` on the SSLContext; OpenSSL's auto-rolled ticket key
  handles short-circuited handshakes for returning clients with no
  server-side state.
- **`Hyperion::TLS.rotate!`** flushes the in-process session cache;
  used by the SIGUSR2 handler.
- **SIGUSR2-driven key rotation.** The master traps the configured
  rotation signal (default `:USR2`) and re-broadcasts to every live
  child; each worker calls `Hyperion::TLS.rotate!` on its per-context
  SSLContext. Operators set `tls.ticket_key_rotation_signal = :NONE`
  to disable rotation entirely.
- **New `tls` config subconfig** with `session_cache_size` (default
  20_480) and `ticket_key_rotation_signal` (default `:USR2`). Wired
  through both the nested DSL and Worker / Server constructors.
- **Cross-worker ticket-key sharing trade-off.** Ruby's stdlib OpenSSL
  bindings (3.3.x) do not expose `SSL_CTX_set_tlsext_ticket_keys`, so
  each worker still owns its own auto-generated ticket key. On Linux
  `:reuseport` workers the kernel pins client → worker by tuple hash
  so a returning client lands on the same worker's cache; on `:share`
  model the cache is shared via the inherited fd. We'll thread a
  master-generated key through to children when a Ruby binding lands
  (probably 3.4+).

### New specs (+24 examples)

- `spec/hyperion/deprecation_warns_spec.rb` (12) — flat DSL warns,
  per-key dedup, `Hyperion.metrics =` / `Hyperion.logger =` warns,
  Runtime-direct write does NOT warn, suite-default silence path.
- `spec/hyperion/tls_session_resumption_spec.rb` (12) — context
  defaults (`SESSION_CACHE_SERVER`, stable `session_id_context`,
  ticket-enabled), live resumption via OpenSSL session reuse,
  `Hyperion::TLS.rotate!` flush, `session_cache_size = 1` eviction,
  Config TLS subconfig defaults + nested-DSL wiring.

### Test-suite changes

- `spec_helper.rb` flips `Hyperion::Deprecations.silence!` in
  `before(:suite)` so the legacy 475 specs (which intentionally
  exercise deprecated APIs as their canonical 1.x test seams) stay
  quiet without per-spec ceremony.
- `spec/hyperion/nested_dsl_spec.rb` — the "does NOT emit a deprecation
  warn on flat keys (warns land in 1.8)" example was the canary for
  this release; replaced with a behaviour-parity assertion. Per-file
  `before/after` silences the warns so the parity assertions still hold.
- `spec/hyperion/tls_spec.rb` baseline ALPN tests untouched — the new
  resumption knobs are additive on the same constructor.

## [1.7.1] - 2026-04-29

Perf-only point release approaching Falcon parity on CPU-bound JSON.
Phase 2 pools the per-request Lint wrapper, reuses one parser inbuf per
connection, and widens the pre-interned header table 16 → 30; Phase 3
moves the env-construction loop and the cookie split-parse out of pure
Ruby and into the C extension. No behavioural changes, no deprecation
warns, no new public DSL surface.

### Phase 2 — per-worker Lint pool + reused inbuf + 30-header intern table

- **`Hyperion::LintWrapperPool` per worker.** When `RACK_ENV=development`
  Hyperion wraps the app in `Rack::Lint`. The wrapper used to be a
  per-request allocation; the pool now hands one out per worker so the
  hot path is allocation-free in dev too.
- **Reused inbuf on `Connection`.** The connection-level read buffer is
  a single mutable `String` carried across requests on the same socket
  (with explicit reset on framing-error / oversized-body / close). Cuts
  per-request `String#new` traffic on keep-alive workloads.
- **30-entry pre-interned header table in `CParser`.** Phase 2c —
  widened from the rc16 16-entry table to cover the full production-
  traffic top-30 (Sec-Fetch-*, X-Forwarded-Host, X-Real-IP, etc.). The
  table doubles as the source of truth for `Adapter::Rack::HTTP_KEY_CACHE`
  so parser, adapter, and downstream env consumers all share string
  identity (`#equal?` is true) for the common keys.
  `CParser::PREINTERNED_HEADERS` is the public exposure.

### Phase 3a — env-construction loop moved into C extension

The Ruby-side env build in `Hyperion::Adapter::Rack#build_env` looped
over `request.headers` setting `env["HTTP_*"] = value` per pair, plus
the request-line keys (`REQUEST_METHOD`, `PATH_INFO`, `QUERY_STRING`,
`HTTP_VERSION`, `SERVER_PROTOCOL`) and the two RFC-mandated non-`HTTP_`
promotions (`CONTENT_LENGTH`, `CONTENT_TYPE`). Every uncached header
went through `HTTP_KEY_CACHE[name] || CParser.upcase_underscore(name)`,
which still meant a Ruby Hash lookup + a method dispatch per header.

- **New `Hyperion::CParser.build_env(env, request) -> env`.** Single
  FFI hop per request that:
  - Reads the Request's `@method`, `@path`, `@query_string`,
    `@http_version`, `@headers` ivars directly via `rb_ivar_get` (zero
    method dispatch — Request is a frozen value object).
  - Sets `REQUEST_METHOD` / `PATH_INFO` / `QUERY_STRING` /
    `HTTP_VERSION` / `SERVER_PROTOCOL` using seven pre-frozen,
    GVAR-anchored String VALUEs (allocated once at extension load).
  - Walks the headers hash via `rb_hash_foreach`. For each `(name,
    value)` pair, looks up the Rack key via:
    1. Pointer compare against `header_table_lc_v[]` (when the name
       came from the parser, this is a one-instruction hit on the 30
       pre-interned entries).
    2. Case-insensitive scan against the same table (covers Request
       objects constructed in specs without going through the parser).
    3. Single-allocation `HTTP_<UPCASED_UNDERSCORED>` build (mirrors
       `cupcase_underscore` byte-for-byte; US-ASCII encoded).
  - Promotes `content-length` → `CONTENT_LENGTH` and `content-type` →
    `CONTENT_TYPE` in the same pass (no second walk over env).
- **`Adapter::Rack#build_env` rewired.** When `c_build_env_available?`
  is true (memoised probe), the Ruby loop is replaced with a single
  `::Hyperion::CParser.build_env(env, request)` call. The pre-Phase-3
  Ruby loop stays in place behind the `else` branch and gets exercised
  by the parity spec, so a hypothetical missing-extension build still
  produces byte-identical env hashes.
- **Bench (macOS arm64, `bench/headers_heavy.ru` + `headers_heavy_wrk.lua`,
  `-t 5 -w 1`, `wrk -t4 -c100 -d10s`, 3 warmup runs):**

  | | r/s (median of 3) |
  |---|---:|
  | Phase 3 OFF (Ruby loop) | 17,555 |
  | Phase 3 ON (C build_env) | **20,390 (+16%)** |

  Above the 3–5% target — the FFI savings stack with Phase 2c's
  pointer-compare hit on the pre-interned header keys, since
  `build_env` now reuses the same identity throughout.

### Phase 3b — cookie split-parse in C extension

Cookie header split (`name1=val1; name2=val2; …` → `{ "name1" => "val1",
… }`) used to live in Ruby, hit on every session-using endpoint. Pulled
into C with the same RFC 6265 §5.2 semantics: opaque values (no URL
decoding), empty values valid, missing-`=` pairs skipped, last-wins on
repeated names. Whitespace trimmed around each pair and around each
key, as Ruby's `.strip` would.

- **New `Hyperion::CParser.parse_cookie_header(str) -> Hash`.** Single
  byte loop in C; returns a fresh (mutable, unfrozen) Ruby Hash so
  middlewares can extend it. Long values (> 4 KiB session payloads,
  signed JWT cookies) are passed through unmolested.

### New specs (+27 examples)

- `spec/hyperion/parser_build_env_spec.rb` (11) — request-line keys,
  HTTP_* mapping, CONTENT_TYPE/CONTENT_LENGTH promotion, identity
  preservation across all 30 pre-interned header keys, off-table
  fallback, no-headers tolerance, byte-for-byte parity with the Ruby
  fallback, last-wins on duplicate names, return-value identity.
- `spec/hyperion/parser_cookie_split_spec.rb` (16) — single + multi
  cookies, whitespace tolerance, trailing semicolon, empty value,
  last-wins, missing-`=` skip, empty input, "=" inside value, no URL
  decoding, mutable return Hash, 4 KiB long-value, malformed-pair
  isolation.

### Notes

- `Hyperion::Parser` (pure-Ruby fallback) is unchanged. The
  `Adapter::Rack#build_env` Ruby branch still reads from
  `request.headers` and builds env exactly as in 1.7.0; the C path is
  opt-in via the lazy `c_build_env_available?` probe.
- Spec count 432 → 475 (+43 across Phase 2 and Phase 3). 432 1.7.0
  specs unchanged.

## [1.7.0] - 2026-04-29

**Spec count 325 → 432 (+107)** across three parallel streams: +86 RFC additive items, +8 Phase 1 (sendfile fast path), +13 Phase 5 (chunked-write coalescing).

First wave of additive ships from `docs/RFC_2_0_DESIGN.md` plus Phase 1 (sendfile fast path) and Phase 5 (chunked-write coalescing) of the perf roadmap. All changes are backwards-compatible: every 1.6.3 spec passes without modification, every flat DSL form still works without warns (deprecation lands in 1.8.0), every 1.6.x test stub seam (`allow(Hyperion).to receive(:metrics)`, `Hyperion.instance_variable_set(:@metrics, …)`) keeps working.

**Headline numbers:**
- **Phase 1 sendfile** — closes Puma static-file rps gap on 1 MiB asset: 2,392 r/s vs Puma 2,074 (**+15% rps over Puma, ~20× lower p99**).
- **Phase 5 chunked coalescing** — 1000×50 B SSE workload: 1001 → 11 syscalls (**~91× syscall reduction**).

### Phase 1 — sendfile fast path (close Puma rps gap on static files)

Per `docs/BENCH_2026_04_27.md` the static 1 MiB row left ~8% rps on the
table vs Puma (Hyperion `-t 5 -w 1` 1,919 r/s vs Puma `-t 5:5` 2,074 r/s)
even though Hyperion already won the p99 race 13× over. Root cause: the
Phase-0 static path went through `IO.copy_stream`, which on macOS / non-
Linux hosts and on TLS sockets falls back to a per-chunk userspace
read+write loop — each chunk takes the connection's writer mutex and a
fiber yield. We close that gap with a native zero-copy primitive that
bypasses the chunk-fiber pipeline entirely.

- **New C unit `ext/hyperion_http/sendfile.c`.** Defines
  `Hyperion::Http::Sendfile.copy(out_io, in_io, offset, len) -> [bytes, status]`
  alongside `Sendfile.supported?` / `Sendfile.platform_tag`. Picks the
  best kernel call at compile time:
  - **Linux:** `sendfile(2)` with `off_t*` for in-place cursor advance.
    `splice(2)`-through-pipe support is wired behind the same surface for
    a follow-up if a host's `sendfile` returns `:unsupported`.
  - **Darwin / FreeBSD / NetBSD / DragonFly:** native `sendfile(2)` with
    the BSD signature (offset by value, sent-bytes by `*len` on Darwin
    and `*sbytes` on the BSDs).
  - **Other:** raises `NotImplementedError`; Ruby caller drops to the
    userspace fallback automatically.

  GVL discipline: every kernel call runs under
  `rb_thread_call_without_gvl` so siblings can run while the socket
  drains. `EAGAIN` / `EWOULDBLOCK` / `EINTR` return `:eagain` (no busy-
  spin in C); the Ruby caller yields to the fiber scheduler before
  retrying. `ENOSYS` / `EINVAL` / `EOPNOTSUPP` return `:unsupported` so
  the userspace fallback kicks in mid-stream without losing the
  position cursor.

- **`Hyperion::Http::Sendfile` Ruby façade
  (`lib/hyperion/http/sendfile.rb`).** Wraps the C primitive with the
  three behaviours that don't belong in C:
  - Loops on `:partial` short writes.
  - Yields on `:eagain` via `IO#wait_writable` (Async-aware) or
    `IO.select` when no scheduler is active.
  - Detects TLS sockets (`OpenSSL::SSL::SSLSocket`) and routes them to
    a 64 KiB `IO.copy_stream` userspace loop — kernel TLS is rarely
    available, but bypassing the per-chunk WriterContext-style mutex
    hop still wins a measurable margin over Phase 0. Same fallback fires
    on hosts where the C ext didn't compile (`Sendfile.supported?` is
    false), so the contract is portable.

- **`ResponseWriter#write_sendfile` rewired.** Same trigger condition
  (body responds to `#to_path`) and same metrics (`:sendfile_responses` /
  `:tls_zerobuf_responses`); the actual byte-pump now goes through
  `Hyperion::Http::Sendfile.copy_to_socket` so the fast path is
  available on Darwin (was previously falling back to a userspace copy
  inside `IO.copy_stream`) and on hosts where Ruby's stdlib `IO.copy_stream`
  picks a slower path.

- **Specs (`spec/hyperion/http_sendfile_spec.rb`).** Round-trips
  through a real `TCPSocket` pair — 1 MiB byte-perfect, 1-byte boundary,
  0-byte short-circuit, mid-file Range slice, simulated `EAGAIN` that
  asserts the loop yields exactly once and resumes from the right
  cursor, and a connection-closed-mid-transfer scenario that surfaces
  `Errno::*` rather than crashing. The existing
  `spec/hyperion/response_writer_sendfile_spec.rb` keeps passing —
  `ResponseWriter#write_sendfile`'s public surface is unchanged.

- **Bench result (macOS arm64, `-t 5 -w 1`, `wrk -t4 -c100 -d20s`,
  bench/static.ru on a 1 MiB asset):**

  | | r/s | p99 |
  |---|---:|---:|
  | Puma 7.2 `-t 5:5` (Phase 0 reference) | 2,074 | 55 ms |
  | Hyperion 1.7.0-pre Phase 0 (`IO.copy_stream` only) | 1,919 | 4.22 ms |
  | **Hyperion 1.7.0 Phase 1 (Sendfile.copy)** | **2,203 – 2,392** | **2.76 – 2.90 ms** |

  **+15-25% rps over Phase 0, +6-15% rps over Puma, ~20× lower p99 than
  Puma.** Closes (and reverses) the 8% rps gap. Linux numbers will land
  in the pre-tag bench sweep (task #112) — Linux's `sendfile(64)` on
  plain TCP is the same syscall `IO.copy_stream` already picks under
  the hood, so the Linux delta should be smaller than the Darwin delta;
  the win there comes from skipping the Ruby-level chunk loop and the
  ResponseWriter mutex hop (the WriterContext analogue) rather than from
  trading userspace for kernel zero-copy.

- **Forward-compat note for Phase 5 (chunked-write coalescing).**
  `Sendfile.copy_to_socket` shares no state with the upcoming
  `WriterContext` chunk batcher — the static-file path bypasses it
  entirely, so Phase 5's per-chunk coalescing still composes cleanly:
  small chunked / Transfer-Encoding bodies get the new io_buffer
  batching, large `to_path` bodies keep the kernel zero-copy. h2
  sendfile is deliberately out of scope (writer-fiber single-writer
  invariant + per-stream window updates make it a 2.0 RFC item).

### Phase 5 — chunked-write coalescing (cut SSE / streaming-JSON syscalls 90×+)

Streaming workloads (SSE event feeds, streaming JSON, log-tail
responses) push tiny payloads — a typical SSE event is ~50 B. Pre-
Phase-5 the only multi-write path was `body.each` inside the
buffered `Content-Length` writer, which accumulated everything in
userspace before emitting one syscall: real streams couldn't push
bytes downstream until the body finished, so SSE was structurally
broken. Phase 5 adds an opt-in `Transfer-Encoding: chunked`
streaming path with per-response coalescing so each tiny `body.each`
chunk doesn't translate to its own syscall.

- **`ResponseWriter#write` opt-in branch.** App sets
  `Transfer-Encoding: chunked` on the response → ResponseWriter
  takes the streaming path: emit head, iterate `body.each`, frame
  each chunk per RFC 7230 §4.1, drain into the socket through a
  per-response coalescing buffer, append `0\r\n\r\n` terminator
  on close. Apps that don't opt in keep the 1.6.x single-syscall
  Content-Length path verbatim (one new spec locks this — 100×50 B
  non-chunked body still emits exactly 1 syscall).

- **`ResponseWriter::ChunkedCoalescer` per-response buffer.**
  - Chunks `< 512 B` accumulate in a 4 KiB-capacity ASCII-8BIT
    `String.new(capacity: 4096)` (matches the existing build-head
    buffer style).
  - Buffer drains on `>= 4096 B` filled (mid-stream flush) or on
    end-of-body (`0\r\n\r\n` terminator concatenated into the
    buffer's final drain so peers never see a half-flushed
    response between drain + terminator syscalls).
  - Chunks `>= 512 B` drain the buffer first (preserves byte order
    on the wire) then write directly — no point coalescing a
    payload already past the threshold.
  - Best-effort 1 ms tick: `Process.clock_gettime` check on each
    chunk arrival; if the buffer has been sitting >= 1 ms since
    the last drain, flush. Under Async this gives natural
    flushes between sparse chunks; not a real timer fiber per
    response (the bookkeeping would cost more than the syscall
    savings on a short-lived coalescer).
  - `body.flush` / `:__hyperion_flush__` sentinel honoured —
    SSE servers use this to push events past the coalescing
    latency on demand.

- **`build_head_chunked`.** Mirrors `build_head_ruby` but emits
  `transfer-encoding: chunked` and explicitly drops any
  app-supplied `content-length` (mutually exclusive per RFC 7230
  §3.3.3). Pure Ruby — the C builder still always emits
  content-length and isn't on this branch (low-volume opt-in
  path; no measurable win from a C builder here).

- **h2 path deliberately untouched.** `Http2Handler::WriterContext`
  already coalesces at the kernel send-buffer boundary: every
  encoder fiber enqueues onto the per-connection `Thread::Queue`
  and a single writer fiber drains it onto the socket. Multiple
  small DATA frames buffered onto the queue between writer-fiber
  resumptions get drained back-to-back — TCP's Nagle-style send
  coalescing (default ON without `TCP_NODELAY`) folds them into
  the same on-wire packet. Adding a userspace coalescer on top
  of the queue would interact awkwardly with per-stream window
  updates and the writer-fiber single-writer invariant; deferred
  to 2.0 (Rust h2 codec rewrite, RFC §6).

- **Sendfile path (Phase 1) bypasses the coalescer entirely.**
  Bodies that respond to `#to_path` still take the
  `IO.copy_stream` / native-sendfile branch. The file IS the
  body buffer — there are no userspace chunks to coalesce. Phase 1
  spec sweep (`response_writer_sendfile_spec.rb`,
  `http_sendfile_spec.rb`) still green.

- **New metrics.** `:chunked_responses` (count of streamed
  responses), `:chunked_total_writes` (total `socket.write` calls
  on the chunked path), `:chunked_coalesced_writes` (subset that
  drained the coalescing buffer rather than passing a large chunk
  straight through). Operators get
  `chunked_total_writes / chunked_responses` as the syscall-per-
  response gauge.

- **Specs (`spec/hyperion/chunked_coalescing_spec.rb`, +13
  examples).** Lock the syscall-count properties: 100×50 B
  yields 1 head + 2 body writes (was 1 + 100 = 101 without
  coalescing — **~33× reduction**); 1000×50 B SSE bench yields 1
  head + 10 body writes (vs 1 + 1000 = 1001 without coalescing —
  **~91× reduction**); 10 KiB single chunk = 1 head + 1 body + 1
  terminator = 3 syscalls; mixed 50/600/50 = 4 syscalls (head +
  buffer drain + 600 direct + final drain); body.close edge
  asserts the terminator + buffered payload land in the same
  syscall; flush sentinel forces an extra mid-stream drain;
  Async-driven 5 ms quiet period asserts the 1 ms tick fires
  before chunk #2 arrives; non-chunked Content-Length path stays
  at exactly 1 syscall (no regression).

- **Bench (`bench/sse.ru`).** New Rack app: streams 1000 SSE
  events of ~50 B each over a single keep-alive connection,
  yielding the flush sentinel every 50 events. `wrk -t1 -c1
  -d10s` measures sustained event throughput; pair with `strace
  -c -e write` (Linux) or `dtruss -c -t write` (macOS) for the
  syscall headline. Bench-host numbers land in the pre-tag bench
  sweep (task #112).

- **Spec sweep delta:** 419 → 432 (+13). All 1.6.x and
  Phase 1 specs untouched.

### Added
- **`Hyperion::Runtime` constructor injection (RFC A3).** New `Hyperion::Runtime` class holds `metrics`, `logger`, `clock`. `Runtime.default` is the process-wide singleton (lazy, mutable, NOT frozen — RFC §5 Q4). Module-level `Hyperion.metrics` / `Hyperion.logger` (and their `=` setters) keep working — they delegate to `Runtime.default`. New `runtime:` kwarg on `Hyperion::Server`, `Hyperion::Connection`, `Hyperion::Http2Handler` (default nil → fall through to module accessors so 1.6.x specs pass; non-nil → that runtime is used exclusively, no implicit fallback to module overrides). Multi-tenant deployments can now give each `Server` its own metrics sink.
- **`Hyperion::DispatchMode` value object (RFC A2).** Internal value object replacing the 4-flag / 5-output `if/elsif` matrix in `Server#dispatch`. 5 modes: `:tls_h2`, `:tls_h1_inline`, `:async_io_h1_inline`, `:threadpool_h1`, `:inline_h1_no_pool`. Frozen, equality-by-name, predicates `#inline?` / `#threadpool?` / `#h2?` / `#async?` / `#pooled?`. Resolved per dispatch via `DispatchMode.resolve(tls:, async_io:, thread_count:, alpn:)`.
- **Per-mode dispatch counters (RFC A2 + §3 1.7.0 dual-emit).** New keys: `:requests_dispatch_tls_h2`, `:requests_dispatch_tls_h1_inline`, `:requests_dispatch_async_io_h1_inline`, `:requests_dispatch_threadpool_h1`, `:requests_dispatch_inline_h1_no_pool`. **Operators on Grafana dashboards from the 1.x line: the legacy `:requests_async_dispatched` and `:requests_threadpool_dispatched` keys keep emitting in 1.7 + 1.8 (dual-emit) and are removed in 2.0. Migrate dashboards to the per-mode keys before 2.0.**
- **Nested DSL blocks (RFC A4).** `h2 do |h| ... end`, `admin do ... end`, `worker_health do ... end`, `logging do ... end` — both bareword (`max_concurrent_streams 256`) and explicit-arg (`|h| h.max_concurrent_streams 256`) forms supported. New `Config::H2Settings`, `AdminConfig`, `WorkerHealthConfig`, `LoggingConfig` subclasses; `Config#h2`, `#admin`, `#worker_health`, `#logging` readers. Flat 1.6.x setters (`h2_max_concurrent_streams 256`, `admin_token "x"`, `worker_max_rss_mb 1024`, `log_level :info`, `log_format :json`, `log_requests false`) remain functional with no warns in 1.7. Deprecation warns land in 1.8.0; removal in 2.0. `BlockProxy` inherits from `BasicObject` so `format :json` inside a `logging do` block doesn't collide with `Kernel#format`.
- **`accept_fibers_per_worker` config (RFC A6).** Default 1. When > 1 and the accept loop is async-wrapped, spawn N accept fibers that each `IO.select` on the same listening fd. Linear scaling on `:reuseport` (Linux); on Darwin (`:share` mode) the knob is honoured silently with no scaling benefit (RFC §5 Q5). Documented in the README "Operator guidance" section.
- **`h2.max_total_streams` admission gate (RFC A7).** New `Hyperion::H2Admission` value object — process-wide stream cap shared across all `Http2Handler` instances within a worker. Default `nil` (no cap, current behaviour). When set, streams beyond the cap get `RST_STREAM REFUSED_STREAM` (RFC 7540 §11) and bump `:h2_streams_refused`. Default flips to `h2.max_concurrent_streams × workers × 4` in 2.0 (RFC §3 1.x-vs-2.0 split).
- **`admin.listener_port` sibling listener (RFC A8).** New `Hyperion::AdminListener` — single-thread TCP server that handles only `/-/quit` and `/-/metrics` on a separate port. Default `nil` keeps admin mounted in-app via `AdminMiddleware`. When set, the sibling listener spawns alongside the application listener regardless of `:share` vs `:reuseport` worker model. Defence-in-depth for the bearer-token leak vector documented in RFC A8 (logging middlewares that dump request headers); runs alongside, not instead of, the in-app middleware.
- **`async_io` strict validation (RFC A9).** `Server#initialize` raises `ArgumentError` on non-tri-state values (`1`, `:yes`, `'true'`, etc.) — pre-1.7 they silently landed in the wrong matrix cell. New `Hyperion.validate_async_io_loaded_libs!` is wired into the CLI bootstrap: `async_io: true` raises if no fiber-cooperative library (`hyperion-async-pg` / `async-redis` / `async-http`) is loaded; `async_io: false` warns (does not raise) if a fiber-IO library is loaded but unused; `async_io: nil` keeps the 1.6.1 soft-warn shape.

### New specs (86 examples)
- `spec/hyperion/runtime_spec.rb` — singleton lifecycle, mutable default, default? predicate, custom-runtime isolation, legacy override seam.
- `spec/hyperion/dispatch_mode_spec.rb` — resolve matrix, predicate semantics, frozen value-object equality, `metric_key` shape.
- `spec/hyperion/h2_admission_spec.rb` — admit/release/cap exhaustion + concurrent-thread safety.
- `spec/hyperion/nested_dsl_spec.rb` — h2 / admin / worker_health / logging block forms (bareword + explicit-arg), flat-name forwarders, no-warn assertion, BlockProxy bareword behaviour.
- `spec/hyperion/runtime_kwarg_spec.rb` — `runtime:` kwarg plumbing on Connection / Server / Http2Handler, isolation from module-level overrides when explicit.
- `spec/hyperion/accept_fibers_spec.rb` — default 1, clamp on zero/negative, N-fiber spawn count under start_async_loop, Darwin no-error path.
- `spec/hyperion/admin_listener_spec.rb` — live HTTP integration (token, /-/metrics, 404), Server's `maybe_start_admin_listener` gating on port + token presence.
- `spec/hyperion/async_io_strict_spec.rb` — Server constructor raise paths, validate_async_io_loaded_libs! tri-state.
- `spec/hyperion/per_mode_counters_spec.rb` — dual-emit assertions per mode, end-to-end live HTTP request that bumps both new and legacy keys.

### Changed
- `Hyperion::Master.build_h2_settings` reads from the nested `Config#h2` object directly (flat-name forwarders still work via `Config#h2_max_concurrent_streams`).
- `Hyperion.metrics` / `Hyperion.logger` are now thin delegators to `Hyperion::Runtime.default` — preserves the public 1.6.x surface, new code path goes through Runtime.

### Deprecation roadmap
- **1.7.0 (this release):** all of the above ship as additive opt-ins. No deprecation warns. Old metric keys keep emitting alongside the new per-mode keys.
- **1.8.0:** boot-time deprecation warns on flat DSL setters, `Hyperion.metrics=` / `Hyperion.logger=` setters, and per-call `Hyperion.metrics` reads from internal code paths.
- **2.0.0:** flat DSL setters removed; `Hyperion.metrics=` / `Hyperion.logger=` setters removed; legacy `:requests_async_dispatched` / `:requests_threadpool_dispatched` keys retired; `h2.max_total_streams` default flips to `h2.max_concurrent_streams × workers × 4`.

## [1.6.3] - 2026-04-29

5 audit-driven hotfixes flagged by the post-1.6.0 audits; spec count 290 → 325 (+35 across the wave). No RFC items here — those land in 1.7.0+. See [RFC_2_0_DESIGN.md](docs/RFC_2_0_DESIGN.md) for the larger architectural roadmap.

### Fixed
- **C1 — FiberLocal shim compat with the 1.4.x `thread_variable_*` fixes.** Audit flagged the shim re-introduces a regression we already fixed in 1.4.x. `lib/hyperion/fiber_local.rb` now uses the correct `Fiber[k]=` write API and falls back to `Thread.current.thread_variable_*` when no fiber scheduler is active; `lib/hyperion/cli.rb` gates the FiberLocal path on `async_io`.
- **A1 — Lifecycle hooks fire in correct order on `:share` worker model.** `before_fork` / `on_worker_boot` / `on_worker_shutdown` ran post-bind on `:share` and out-of-order vs `:reuseport`. Hooks now fire pre-bind on both worker models — `lib/hyperion/master.rb` (pre-bind sequencing) + `lib/hyperion/worker.rb` (boot/shutdown ordering) + `lib/hyperion/cli.rb` (hook plumbing).
- **S1 — `AdminMiddleware#signal_target` ppid mistarget under PID 1 / containerd.** When Hyperion ran as PID 1 in a container, signals were sent to the container init instead of the Hyperion master. New `HYPERION_MASTER_PID` env var + `Hyperion.master_pid` ivar set in `lib/hyperion.rb` and exported from `lib/hyperion/master.rb` / `lib/hyperion/cli.rb`; `lib/hyperion/admin_middleware.rb` consults it before falling back to `Process.ppid`.
- **S2 — Cap `Content-Length` parsing at `max_body_bytes + 1`.** Parser previously accepted any non-negative integer. `lib/hyperion/connection.rb` now rejects abusive `Content-Length` values with 413 BEFORE reading any body — the cap is enforced at header parse time, not after the read.
- **C2 — `WriterContext` short-circuit on empty-body responses (204/304/HEAD).** `lib/hyperion/http2_handler.rb` skips the `encode_mutex` hop and the writer-fiber enqueue when there is nothing to write, eliminating per-response mutex acquisitions on empty-body status codes.

## [1.6.2] - 2026-04-27

Doc release. No code changes.

### Added
- **README "Production tuning (real Rails apps)" section** — distilled from a real-app bench against the Exodus platform (Rails 8.1, on-LAN PG + Redis at ~0.3 ms RTT, `-w 4 -t 10`, `wrk -t8 -c200 -d30s`). Headline: the simplest drop-in (`hyperion -t N -w M` matching Puma's existing `-t/-w`) is the right answer; `+9%` rps and `28×` lower p99 on health endpoints over the same Puma config, no other knobs needed. Documents which synthetic-bench knobs (`-t 30`, `--yjit`, larger `RAILS_POOL`, `--async-io`) DON'T help on real Rails and why (GVL contention past `-t 10`, dev-mode YJIT instability, pool rarely the bottleneck, sync Redis blocking ahead of async-pg yields). Saves operators from the trap of "tune harder = faster" — the simple drop-in IS the answer on real workloads.

## [1.6.1] - 2026-04-27

Audit follow-up from the [BENCH_2026_04_27.md](docs/BENCH_2026_04_27.md) sweep. No code-path changes; doc surface and operator-UX polish.

### Added
- **`## Operator guidance` README section** — concrete "when do I pick which config?" tables. Translates the bench numbers into decisions: `-w 1 + larger pool` vs `-w N + smaller pool` for I/O-bound (multi-worker is 2.6× memory for 0.77× rps if you pick wrong on PG-wait); the `--async-io` decision tree (default OFF unless you're paired with a fiber-cooperative library); how to read p50 vs p99 (tail wins are 5-200× larger than the rps story suggests — size capacity by p99).
- **Boot-time advisory warn for orphan `--async-io`** — if `async_io: true` is set but no fiber-cooperative library is loaded (`hyperion-async-pg`, `async-redis`, `async-http`), Hyperion logs a single advisory warn at boot pointing at the operator-guidance docs. The setting is still honoured; the warn just helps operators who flipped the flag expecting a free perf bump (bench showed `--async-io` on hello-world = 47% rps regression + 3.65 s p99 spike).
- **4 new specs in `spec/hyperion/cli_async_io_warn_spec.rb`** covering all four warn-fire cases (true + no library, false, nil, true + library detected via stub_const).

## [1.6.0] - 2026-04-27

Two parallel improvements landing in 1.6.0:
1. Three small C-extension additions on the request hot path (sibling commit — see "Performance" below).
2. Architectural rewrite of the HTTP/2 outbound write path — per-stream send queue + dedicated writer fiber replace the global `@send_mutex` (see "HTTP/2 writer architecture" below).

These are independent and can be reviewed / reverted separately. The CHANGELOG sub-sections will be merged before tag.

### HTTP/2 writer architecture (Changed)
- **`Hyperion::Http2Handler` now uses a per-connection writer fiber instead of a single send Mutex.** Pre-1.6.0 every framer write — HEADERS, DATA, RST_STREAM, GOAWAY — ran inside one `@send_mutex.synchronize { socket.write(...) }`. That capped per-connection h2 throughput at "one socket-write at a time" regardless of how many streams were concurrently in flight: a slow socket (kernel send buffer full, peer reading slowly) blocked every other stream's writes too. 1.6.0 splits the path:
  - **Encode + frame format** (HPACK encoding, frame layout) is fast (microseconds, in-memory) and stays serialized on the calling fiber via `WriterContext#encode_mutex`. HPACK state is connection-scoped and stateful across HEADERS frames; per-stream wire order (HEADERS → DATA → END_STREAM) must also be preserved. Holding the encode mutex across a `stream.send_*` call satisfies both.
  - **Bytes-to-socket** is owned by a dedicated `run_writer_loop` fiber spawned per connection. Encoder fibers hand bytes off via `WriterContext#enqueue` (non-blocking, signals an `Async::Notification`); the writer pops chunks from the queue and writes them. Only this fiber ever calls `socket.write`, satisfying SSLSocket's "no concurrent writes from different fibers" constraint.
  - **Net effect**: a stream that has bytes ready can encode and enqueue while the writer is mid-flush of an earlier chunk — the slow-socket case no longer serializes encode work across streams. Mutex hold time drops from "until the kernel accepts the write" to "until the bytes are appended to the in-memory queue."
- **Per-connection backpressure cap** (`MAX_PER_CONN_PENDING_BYTES = 16 MiB`). Pathological clients that read very slowly could otherwise let the queue grow without bound. `WriterContext#enqueue` parks the encoder on `@drained_notify` once `@pending_bytes` exceeds the cap; the writer signals `@drained_notify` after each drain pass.
- **Coordinated shutdown**: when `Http2Handler#serve` exits (clean close, peer disconnect, or protocol error), the `ensure` block sets `WriterContext#shutdown!` and `writer_task.wait`s for the final drain BEFORE closing the socket. Order matters — closing the socket first would discard final RST_STREAM / GOAWAY / END_STREAM frames sitting in the queue.

### HTTP/2 writer architecture (Added)
- **`Hyperion::Http2Handler::SendQueueIO`** — IO-shaped wrapper passed to `Protocol::HTTP2::Framer` in place of the raw socket. `read` is a passthrough (single-reader on the connection fiber); `write` enqueues onto the connection-wide queue. Reports `closed?` from the underlying socket so framer EOF detection still works.
- **`Hyperion::Http2Handler::WriterContext`** — holds the per-connection queue, the encode mutex, the send/drained notifications, and the byte-budget counters. One instance per connection; lives for the lifetime of `Http2Handler#serve`.
- **9 new specs in `spec/hyperion/http2_writer_loop_spec.rb`**:
  - `SendQueueIO#write` returns bytesize, enqueues without writing the socket, no-ops on empty/nil, reports the underlying socket's `closed?` state (4).
  - Writer loop drains a single encoder's frames in enqueue order (1).
  - Two encoder fibers pushing concurrently — bytes for both streams reach the wire and per-stream order (HEADERS → DATA → END) is preserved (1).
  - Backpressure parks the encoder when `@pending_bytes` exceeds `max_pending_bytes`; encoder resumes after the writer drains (1).
  - Shutdown drains all queued frames before the writer fiber exits; shutdown with an empty queue exits cleanly (2).
- **`bench/h2_streams.sh`** — `h2load`-driven recipe (`-c 1 -m 100 -n 5000`) for measuring per-connection multi-stream rps. Skips with a clear message if `h2load` isn't on PATH; emits a one-line JSON summary so cross-version diffs are easy.

### HTTP/2 writer architecture (Migration)
- No public-API changes. Operators do not need to touch config or restart with new flags. The architectural change is internal to `Http2Handler`.

### HTTP/2 writer architecture (Notes)
- HPACK's dynamic-table state is shared across all streams on a connection (per RFC 7541 §2.3.2.1). That is why we still serialize encode work — two fibers calling `stream.send_headers` concurrently would corrupt the encoder's table state. The mutex is now microseconds-of-CPU rather than "however long the socket takes to drain N MB."
- `Async::Notification#signal` is a no-op when there are no waiters (signals are not buffered). The writer loop accordingly re-checks `writer_done? && queue_empty?` before parking, so a `shutdown!` call that races a `wait_for_signal` doesn't deadlock.

### Performance
- **`Hyperion::CParser.upcase_underscore(name)` — C-level Rack header-name normalizer.** Replaces the per-uncached-header `"HTTP_#{name.upcase.tr('-', '_')}"` allocation in `Adapter::Rack#build_env`. Single allocation (5 prefix bytes + N source bytes), single byte loop, no Ruby intermediates. Microbench (5 typical X-* names per call): 460k i/s Ruby → 2.21M i/s C, **4.80×** faster (2.17 μs → 452 ns/iter). On a header-heavy hello-world rackup with 8 X-Custom-* request headers + 9 response headers, headline throughput went from ~16.6k r/s to ~18.0k r/s wrk-driven (~+8.5%, averaged across 3 trials). The 16-name `HTTP_KEY_CACHE` still short-circuits the common headers; this only fires on uncached customs.
- **`Hyperion::CParser.chunked_body_complete?(buffer, body_start)` — chunked-transfer body completion check in C.** Replaces the pure-Ruby walker in `Connection#chunked_body_complete?` with a C-level loop that scans CRLF boundaries, decodes hex sizes, and advances the cursor without per-iteration `String#index` / `byteslice` / `split` allocations. Returns `[complete?, last_safe_offset]` so the caller can persist parse progress across read boundaries (handy for pipelined / streaming buffers, even though Connection currently only consults the boolean). Microbench (3 mixed buffers per iter): 283k i/s Ruby → 3.73M i/s C, **13.19×** faster (3.54 μs → 268 ns/iter). Profit is small in production because chunked uploads are rare, but the path now matches the rest of the parser in cost shape.
- **`Hyperion::CParser.build_access_line_colored(...)` — TTY-coloured access-log builder in C.** Mirrors `build_access_line` with the green ANSI escape pair `\e[32mINFO \e[0m` baked into the level label. Ten extra bytes per line, single allocation. The pre-1.6.0 `Logger#access` path fell back to the slower Ruby builder whenever `@colorize` was on (i.e. local TTY / dev runs); now the C builder fires there too. Microbench: 1.78M i/s Ruby → 2.90M i/s C, **1.63×** faster (561 ns → 345 ns per line). Smaller win than the others — the Ruby builder was already a single interpolation — but closes the parity gap so dev-loop `tail -f` doesn't pay an avoidable Ruby tax.

### Added
- **9 new specs in `spec/hyperion/c_upcase_underscore_spec.rb`** plus a fallback-parity assertion that flips `Hyperion::Adapter::Rack.@c_upcase_available` to walk both the C and Ruby branches in one process. Covers lowercase / uppercase / multi-dash / empty / single-byte / non-ASCII byte-pass-through / digit-preservation / Ruby-equivalence on a panel of canonical custom names / encoding (US-ASCII).
- **13 new specs in `spec/hyperion/c_chunked_body_complete_spec.rb`** including a fallback-parity assertion against the original Ruby walker. Covers single chunk, multi-chunk, trailers, partial CRLF, partial size token, partial chunk data, chunk extensions, body_start offset, last-safe-cursor reporting on partial buffers, ArgumentError on out-of-range body_start, and a panel of mixed inputs that must agree byte-for-byte with the Ruby walker.
- **9 new specs in `spec/hyperion/c_access_line_colored_spec.rb`** plus a Logger#access integration test that constructs a TTY-faking IO and asserts the green INFO label appears in the emitted line. Covers text + json formats, query nil/empty/quote-trigger, remote_addr nil, ANSI absence in JSON, and byte-for-byte parity against a hand-rolled Ruby colored builder.

## [1.5.0] - 2026-04-27

Audit-driven CLI + adapter polish. No breaking changes; pure additions to the operator surface and a hardening of the host-header parser.

### Added
- **CLI flag coverage for 8 Config DSL settings.** Pre-1.5.0 these settings could only be reached by writing a `config/hyperion.rb` file; operators who don't keep one in their repo had no way to flip them without authoring one. They now flow through the same CLI > config-file > default precedence as the rest of the flags:
  - `--max-body-bytes BYTES` (Integer, default 16 MiB)
  - `--max-header-bytes BYTES` (Integer, default 64 KiB)
  - `--max-pending COUNT` (Integer, default unbounded)
  - `--max-request-read-seconds SECONDS` (Float, default 60)
  - `--admin-token TOKEN` (String, default unset) — gates `POST /-/quit` and `GET /-/metrics`
  - `--admin-token-file PATH` — sibling that reads the token from disk; refuses to load if the file is missing, unreadable, world-readable (perms must mask `0o007`), or empty. Production deployments should prefer this over `--admin-token` because argv is visible via `ps`.
  - `--worker-max-rss-mb MB` (Integer, default unset) — RSS-based worker recycling
  - `--idle-keepalive SECONDS` (Float, default 5)
  - `--graceful-timeout SECONDS` (Integer, default 30)
- **`Hyperion::CLI.parse_argv!` extracted as a public class method** so the flag-to-`cli_opts` mapping is unit-testable without booting a server. `CLI.run` is now a thin wrapper around it.
- **README CLI flags table** extended with the 8 new flags plus `--[no-]yjit` / `--[no-]async-io` (already wired but previously undocumented in the table).
- **17 new specs**:
  - 14 in `spec/hyperion/cli_flags_spec.rb` cover per-flag parsing, the `merge_cli!` handoff for all 8 new flags, the CLI-wins precedence rule, and the four `--admin-token-file` abort paths (missing / unreadable / world-readable / empty).
  - 3 in `spec/hyperion/adapter/rack_spec.rb` cover plain IPv4-with-port, bare hostname (no port), and the malformed-bracket regression below.

### Fixed
- **`Hyperion::Adapter::Rack#split_host` accepted malformed bracketed IPv6.** Pre-1.5.0 a `Host: [::1` header (no closing bracket) was returned as-is in `SERVER_NAME`, leaking attacker-controlled bytes into Rack env where downstream URL generators / SSRF allow-lists / audit logs would trust them. The adapter now fails closed to `localhost:80` and bumps a `:malformed_host_header` counter so operators can alert on attack-pattern volume. No raise — Rack apps don't expect a server adapter to throw on header-parse failures, so we degrade gracefully instead.

### Security
- `--admin-token` help text warns that argv is visible via `ps` and points operators at `--admin-token-file` for production. The token value is never echoed back in any log line.

## [1.4.2] - 2026-04-27

Audit-driven cleanup. No behaviour changes; fiber-correctness + docs polish.

### Fixed
- **`Hyperion::Logger` access buffer was fiber-local, not thread-local** — pre-1.4.2 the access-log write buffer was stored via `Thread.current[@buffer_key]`. Under an `Async::Scheduler` (TLS / h2 / `--async-io` plain HTTP/1.1) every handler fiber got its own private buffer, so the 4 KiB `ACCESS_FLUSH_BYTES` batching never fired — each fiber's buffer accumulated 1-3 lines before its connection closed and `flush_access_buffer` wrote them. At 24k r/s this meant ~12-24k `write(2)` syscalls/sec instead of the designed ~750/sec. Switched to `Thread#thread_variable_*` so all fibers on the same OS thread share one buffer and the batching actually fires. Same root cause as the 1.4.1 Metrics fix; surfaced by a code-audit grep for residual `Thread.current[:key]` patterns.
- **`Logger#cached_timestamp` and `ResponseWriter#cached_date`** — same fix. Pre-1.4.2 the per-second / per-millisecond Time-formatting caches were per-fiber, so under Async every fiber rebuilt the iso8601 / httpdate String on its first call after a tick. Now per-OS-thread, shared across fibers; one allocation per second per thread total.

### Added
- **Prometheus exporter example output** in the README's Metrics section — shows what `curl -H 'X-Hyperion-Admin-Token: ...' /-/metrics` actually returns (HELP/TYPE lines, status-code labels, auto-export of unknown counters), plus the Prometheus scraper config sketch.
- **Regression spec** for the access-buffer cross-fiber bug — two fibers on the same OS thread write through one logger; verifies a single buffer is registered (not one per fiber) and both lines land via `flush_all`.
- **4 new Metrics specs** (already shipped in 1.4.1; called out here for coverage tracking) — cross-fiber on same thread, cross-thread, cross-fiber-on-different-thread, many-fibers-on-same-thread.

### Changed
- **README benchmark section** version-stamped: clarifies that the headline numbers were measured against the noted Hyperion version (most are 1.2.0 hello-world / 1.3.0 PG-bound) and that 1.3.0+ `--async-io` + 1.4.0+ TLS-inline + 1.4.1+ Metrics fix preserve or improve these numbers. We re-run the headline configs each release.

## [1.4.1] - 2026-04-27

### Fixed
- **`Hyperion::Metrics` fiber-key bug** — pre-1.4.1 the metrics module stored counters via `Thread.current[:key]`, which is FIBER-local in Ruby 1.9+. Under an `Async::Scheduler` (TLS / h2 / `--async-io` plain HTTP/1.1) every handler fiber got its own private counters Hash that `Hyperion.stats` could never see — increments were stranded, the dispatch counters and `:bytes_written` etc. read as zero from any non-handler-fiber observer (including the Prometheus `/-/metrics` exporter when scraped from a different fiber). Switched to `Thread#thread_variable_*` (truly thread-local across fibers) plus direct counter-Hash list storage so snapshots also survive thread death. Verified via 4 new specs: cross-fiber on same thread, cross-thread, cross-fiber-on-different-thread, many-fibers-on-same-thread (210 increments aggregated correctly). Surfaced by hyperion-async-pg 0.4.0's bench round, which couldn't read `:requests_async_dispatched` from spec assertions even though the increments were firing.

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
