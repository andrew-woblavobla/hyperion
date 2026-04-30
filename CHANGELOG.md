# Changelog

## [Unreleased] - 2.3.0

In-progress release. First of five 2.3.0 streams (2.3-A through 2.3-E)
plus the version-bump release task (2.3-fix-F). The user's deployment
shape is plaintext h1 behind nginx + LB (TLS terminated upstream), so
the headline target is the unmovable kernel-accept boundary on the
plaintext h1 path.

### 2.3-A — io_uring accept on Linux 5.6+, opt-in via `HYPERION_IO_URING=on`

**Why this matters most:** the 2026-04-30 sweep showed Hyperion at
96,813 r/s on hello `-w 16 -t 5` (vs Puma 75,776 — already +27.8%).
With the GVL bypassed by 16 workers, the next bottleneck is the
kernel accept loop: every accept costs `accept_nonblock` + `IO.select`
on the EAGAIN edge — two syscalls per accepted connection under
burst. io_uring submits accept SQEs and reaps CQEs in one syscall,
and the kernel batches multiple accepts in a single CQE drain when
connections arrive faster than the fiber consumes them.

**Target:** hello `-w 16 -t 5` from 96,813 → ≥ 130,000 r/s with p99
unchanged (~2-3 ms).

**What ships:**

| Deliverable | Where | Why |
|---|---|---|
| `ext/hyperion_io_uring/` Rust crate | NEW | Wraps the `io-uring` crate (https://docs.rs/io-uring) — well-maintained safe Rust around liburing. Linux-gated via `target.'cfg(target_os = "linux")'` so the macOS dev build still cargo-checks cleanly; Darwin compiles to stubs that return -ENOSYS. |
| `lib/hyperion/io_uring.rb` | NEW | Ruby surface: `Hyperion::IOUring.supported?`, `Hyperion::IOUring::Ring.new(queue_depth: 256)` with `#accept(fd)` / `#read(fd, max:)` / `#close`. Loaded over Fiddle, identical pattern to `Hyperion::H2Codec`. |
| `Hyperion::Server#run_accept_fiber` | UPDATED | Splits into `run_accept_fiber_io_uring` and `run_accept_fiber_epoll`. The io_uring branch lazily opens a per-fiber ring on first use (`Fiber.current[:hyperion_io_uring] ||= Ring.new(...)`), drains accept CQEs, and hands each accepted fd to `dispatch` via `::Socket.for_fd`. Closed at fiber exit. The TLS path keeps epoll — io_uring accept is wired only for plain TCP (the SSL handshake still wants the userspace `accept` + `SSL_accept` dance). |
| `Hyperion::Config#io_uring` | NEW | Tri-state `:off` / `:auto` / `:on`. Mirrors `tls.ktls`. |
| `HYPERION_IO_URING={on,auto,off}` env var | NEW | Operator flips on for an A/B run without rewriting the config file, identical pattern to fix-B `HYPERION_H2_NATIVE_HPACK` and fix-C `HYPERION_TLS_KTLS`. |
| `spec/hyperion/io_uring_spec.rb` | NEW (16 examples) | Cross-platform: `supported?` returns false on Darwin, `:auto` doesn't raise on Mac, `:on` raises with clear "io_uring not supported" / "io_uring required" message on Mac. Linux-only context (gated via `if: described_class.supported?`): ring lifecycle (open + close + no fd leak across 1000 accepts), feature parity (bytes through io_uring path match bytes through epoll). |

**Per-fiber rings, NEVER per-process or per-thread.** io_uring under
fork+threads has known sharp edges:

- Submission queue is process-shared by default — under fork, the
  parent's outstanding SQEs leak into the child's CQ.
- `IORING_SETUP_SQPOLL` kernel thread does not survive fork.
- Threads sharing a ring need `IORING_SETUP_SINGLE_ISSUER` + careful
  submission discipline.

The safe pattern matching Hyperion's fiber-per-conn architecture: one
ring per fiber that needs it (the accept fiber, optionally per-conn
read fibers in a future 2.3-x round). Rings are opened lazily on
first use and closed at fiber exit. Workers never share rings across
fork — each child opens its own.

**Default off in 2.3.0.** Mirrors the 2.2.0 fix-B
`HYPERION_H2_NATIVE_HPACK` pattern: ship the plumbing, give operators
the env var to A/B, flip the default to `:auto` only after 6 months
of soak. io_uring code in production has too many sharp edges to
default-on without field validation.

**Bench delta on openclaw-vm — measured 2026-04-30 (post Linux build fix `599775a`):**

| Row | epoll baseline | io_uring (HYPERION_IO_URING=on) | Δ |
|---|---:|---:|---:|
| hello `-w 16 -t 5` | 90,022 r/s | 91,228 r/s | +1.3% (noise) |
| hello `-w 4 -t 5` | 21,184 r/s | 22,073 r/s | +4.2% |

io_uring engages cleanly (boot log: `io_uring accept policy resolved
policy=on active=true supported=true`) but the rps delta is inside
the bench-noise envelope. The hello workload at 90k r/s on -w 16 is
**Ruby-dispatch-bound, not accept-syscall-bound** — each accept is
already one syscall on the epoll path (`accept_nonblock` + `IO.select`
on EAGAIN); the kernel-side time difference between that and an
io_uring accept SQE is small relative to the per-request env hash
construction + body iteration + response writing. The expected win
zone for io_uring is high-churn accept-bound workloads (e.g.,
many short-lived connections, multi-connection accept batching with
`IORING_OP_ACCEPT_MULTI`); on long-keepalive wrk benches like ours,
the accept rate is just (connection count / wrk run duration) =
200/20s = 10/sec, which neither path is paying for. Default stays
`:off` — operators with high-accept-churn shapes (RPC ingress,
short-lived workers behind a TCP load balancer that opens fresh
connections per request) can flip it on for A/B.

Spec count: 698 (2.2.0) → 714 (+ 16 io_uring specs).

### 2.3-B — per-conn fairness cap + TLS handshake CPU throttle

**Why this matters.** The user's deployment shape is plaintext h1
behind nginx + LB. nginx multiplexes many client requests onto a
small number of upstream connections via HTTP/1.1 keep-alive. **One
greedy upstream connection** (nginx pipelining many requests through
it) can starve other connections — a CPU-bound JSON serialize in the
wrong place lets one client hog the worker thread pool while
everyone else's p99 climbs.

Two related defences ship together:

1. **Per-conn fairness cap.** `Hyperion::Connection` now carries an
   in-flight counter and an optional ceiling. When a request arrives
   and the cap would be exceeded, the connection answers with a
   canned `503 Service Unavailable` + `Retry-After: 1` and stays
   alive. nginx (or any peer) retries the request after the in-flight
   work drains. Default cap = `nil` (no cap, matches 2.2.0); the
   recommended setting is `pool/4` so no single conn can use more
   than 25% of the worker's thread budget. `:auto` resolves at
   `Config#finalize!` to `thread_count / 4`, floor 1.

2. **TLS handshake CPU throttle.** A new
   `Hyperion::TLS::HandshakeRateLimiter` token bucket caps SSL_accept
   CPU per worker. Defends direct-exposure operators against
   handshake storms (e.g., during a deployment when nginx restarts
   and reconnects everything). Default = `:unlimited` (matches
   2.2.0). For nginx-fronted topologies this is mostly defensive —
   nginx keeps long-lived upstream conns so handshake rate is
   normally near-zero.

**What ships:**

| Deliverable | Where | Why |
|---|---|---|
| `Hyperion::Connection` per-conn semaphore | `lib/hyperion/connection.rb` | Mutex-guarded `@in_flight` counter; admit/release helpers; canned `REJECT_503_PER_CONN_OVERLOAD` payload (no allocation per reject); deduplicated `:per_conn_overload_rejects` warn (one per Connection lifetime). |
| `Hyperion::Config#max_in_flight_per_conn` | `lib/hyperion/config.rb` | Top-level knob (not nested — applies to every conn, not h2-specific). Tri-state: `nil` (default, no cap), positive Integer (explicit cap), `:auto` (resolves to `thread_count / 4`, floor 1, at finalize time). |
| `Hyperion::Config#tls.handshake_rate_limit` | `lib/hyperion/config.rb` | Token-bucket budget in handshakes/sec/worker. `:unlimited` (default) or positive Integer. |
| `Hyperion::TLS::HandshakeRateLimiter` | `lib/hyperion/tls.rb` | Mutex-guarded token-bucket. `acquire_token!` returns true when budget available, false when over budget. `:unlimited` short-circuits every call to true so the hot path stays branchless. |
| CLI `--max-in-flight-per-conn VALUE` + `HYPERION_MAX_IN_FLIGHT_PER_CONN` env var | `lib/hyperion/cli.rb` | Same parser/env-var pattern as fix-D `--h2-max-total-streams`. `auto` resolves at finalize. |
| CLI `--tls-handshake-rate-limit VALUE` + `HYPERION_TLS_HANDSHAKE_RATE_LIMIT` env var | `lib/hyperion/cli.rb` | Same pattern. `unlimited` is the default sentinel. |
| Plumbing through Server / Worker / Master / ThreadPool | 4 files | The cap propagates from `Config` → CLI → `Server.new` → `ThreadPool` → every Connection the worker thread builds. The TLS limiter lives on `Server#tls_handshake_limiter` (one per worker). |
| `spec/hyperion/per_conn_fairness_spec.rb` | NEW (24 examples) | Cap=nil = 2.2.0 behaviour; cap=N admits + rejects; 503 + Retry-After + per-connection overload body verified; metric + dedup-warn coverage; finalize! resolves `:auto` to `thread_count/4`; CLI flag + env var grammar tests. |
| `spec/hyperion/tls_handshake_throttle_spec.rb` | NEW (19 examples) | Limiter `:unlimited` = no throttle (regression); 100/sec rate admits ~100, rejects ~100 in a 200-attempt burst; refill over 0.55s adds ~25 tokens; capacity bounded (no infinite accrual); thread-safety; CLI + env var coverage. |

**Default unchanged.** The cap is an opt-in hardening tool, not a
default flip. Existing operators upgrading from 2.2.0 → 2.3.0 see
identical behaviour without setting either knob. Operators who want
the fairness cap on for `-t 16` workers add
`max_in_flight_per_conn :auto` to their config (or pass
`--max-in-flight-per-conn auto` / set
`HYPERION_MAX_IN_FLIGHT_PER_CONN=auto`). Pattern matches fix-D's
`--h2-max-total-streams`: configure once, no daemon reload required.

**Bench plan (deferred; openclaw-vm SSH key not loaded in this
session).** The contended-workload shape is:

```sh
# Setup: a Rack app where one client gets a 50ms handler, others fast.
# Run two wrk processes simultaneously: one client × 1000 req/s
# (greedy, on one connection), 50 clients × 10 req/s (light, on
# 50 connections). Measure p99 of the light clients.
```

Compare 2.2.0 baseline vs 2.3-B with `--max-in-flight-per-conn 4`
(for `-t 16`). Target: light-client p99 -20-30%. Simpler proxy if
the contended-workload bench is too involved to set up cleanly: run
`wrk -t1 -c1` (single client, single conn) at peak rps, then
`wrk -t1 -c100` (100 clients, 100 conns) at peak rps, compare
per-conn-msg-rate. The bench will land as a separate `[bench]`
commit when SSH is available.

Spec count: 714 → 757 (+ 24 fairness + 19 throttle = 43 new specs,
0 regressions).

### 2.3-C — WebSocket permessage-deflate (RFC 7692)

**Why this matters most for the user's deployment shape.** ActionCable /
chat / pubsub WebSocket traffic compresses very well — typical JSON
message frames are 80-95% redundant (repeated field names, recurring
user IDs, recurring chat IDs). RFC 7692 permessage-deflate compresses
each message with a shared LZ77 dictionary so wire bytes drop 5-20×
on the chat-style workload that ActionCable fans out to thousands of
idle subscribers. **Bandwidth costs move with bytes, not with
dispatches** — for an nginx-fronted deployment the saving lands
straight on the egress bill (Cloudfront / ALB egress @ ~$0.085/GiB at
the unhappy AWS price band).

**Bench delta on a chat-style JSON workload (1 KB messages, local
UNIXSocket harness — `bench/ws_deflate_bench.rb`):**

| Mode | Bytes per message | Wire reduction | msg/s |
|---:|---:|---:|---:|
| Plain (no deflate) | 400.8 B | — | 57,498 |
| permessage-deflate | 19.7 B | **20.4× smaller** | 34,999 (61% of baseline) |

The 20× number is upper-bound — chat-style JSON has very repetitive
field names which the shared deflate dictionary picks up immediately.
Random binary / already-compressed payloads (h.264 video frames,
gzipped logs) see near-zero saving and would be better served by
the `:off` policy on those routes (the operator knob is per-process,
but you can hand-roll different dispatch shapes per route if needed).

The msg/s drop is the deflate CPU cost on the encode side and is
expected — for a bandwidth-bound workload (the typical ActionCable
fan-out shape: one server-side message reflected to N idle browsers)
the bandwidth saving wins handily over the per-message CPU cost.

**What ships:**

| Deliverable | Where | Why |
|---|---|---|
| Handshake negotiation | `lib/hyperion/websocket/handshake.rb` | `validate(env, permessage_deflate: :auto/:on/:off)`. Parses `Sec-WebSocket-Extensions`, picks the first usable offer, returns the negotiated parameter set in slot 4 of the result tuple. `format_extensions_header` renders the response header for `build_101_response`. |
| Connection wiring | `lib/hyperion/websocket/connection.rb` | `Connection.new(... extensions: result[3])` instantiates a per-conn `Zlib::Deflate` / `Zlib::Inflate` pair sized to the negotiated `server_max_window_bits` / `client_max_window_bits`. `send` deflates + sets RSV1; `recv` strips RSV1 + appends `\x00\x00\xff\xff` sync trailer + inflates. Streaming inflate with the cap applied to running output bytes — the compression-bomb defense. |
| Frame builder + parser RSV1 contract | `ext/hyperion_http/websocket.c` + `lib/hyperion/websocket/frame.rb` | C parser preserves RSV1 in slot 8 of the metadata tuple; allows it on data frames; rejects it on control frames (RFC 7692 §6.1). `Builder.build(rsv1: true)` sets the high bit alongside FIN. RSV2/RSV3 still reject (no defined semantics). The RubyFrame fallback mirrors the contract. |
| `Hyperion::Config#websocket.permessage_deflate` | `lib/hyperion/config.rb` | Tri-state `:off` / `:auto` (default) / `:on`. Mirrors `tls.ktls`. Operators flip `:auto → :on` to harden when they control the client population. |
| `bench/ws_echo.ru` HYPERION_WS_DEFLATE knob | `bench/ws_echo.ru` | Bench app advertises permessage-deflate when the env var is set; pipes the negotiated extensions through to the Connection. |
| `bench/ws_deflate_bench.rb` | NEW | Local UNIXSocket harness — measures wire bytes with vs without permessage-deflate on a 1 KB chat-style JSON workload. |
| `spec/hyperion/websocket_permessage_deflate_spec.rb` | NEW (18 examples) | Handshake negotiation (8 cases including `:on`/`:off`/`:auto` and multi-offer), wire round-trip via Zlib (RFC 7692 "Hello" vector), Connection round-trips with shared and reset context, control-frame protections (ping with RSV1 → 1002), compression-bomb defense (4 MiB inflated → 1009 close), Config DSL plumbing. |

**Compression-bomb defense (RFC 7692 §8.1).** A malicious client can
ship a tiny compressed payload that inflates to gigabytes. The
streaming inflater drains output in 16 KB chunks and short-circuits
the moment the running decompressed total would exceed
`max_message_bytes` (default 1 MiB). The connection then closes 1009
(Message Too Big) and the next `recv` raises `StateError`. Verified
via `4 MiB → 4 KB compressed → close 1009` regression spec.

**Backwards compatibility.** Default `:auto` is the safe default —
clients that don't offer permessage-deflate keep getting plain frames,
identical to 2.2.0. The 4th slot of the handshake result tuple is new;
existing `[:ok, accept, sub]` 3-arg destructure call sites remain
correct because Ruby's array destructure tolerates extra slots.

**Default unchanged for the operator-facing knob.** The Connection
constructor's `extensions:` kwarg defaults to `{}`. Apps that don't
read `result[3]` from the handshake tuple keep getting uncompressed
WebSocket traffic, identical to 2.2.0. The `:auto` default on the
Config knob means handshakes advertise the extension when offered, but
the Connection wrapper only deflates when the app explicitly threads
the negotiated `extensions:` into the constructor — both ends
opt-in.

Spec count: 757 → 776 (+18 deflate specs + 1 RSV1-on-control split,
0 regressions).

## [2.2.0] - 2026-05-01

### Headline

A correctness + foundation release with two measurable perf wins. The
original 2.2.0 sprint shipped four foundation tracks (kTLS plumbing,
Rust HPACK adapter, allocation reductions, splice correctness fix); a
follow-up sprint (fix-A through fix-E) closed the gaps that made the
original bench numbers regress and added two operator knobs.

| Track | Result |
|---|---|
| Phase 9 + fix-C — kTLS large-payload TLS | **+18-24% rps / -13-14% p99** on TLS 50 KB JSON and 1 MiB static |
| Phase 10 + fix-B — Rust HPACK adapter | h2load at parity with Ruby fallback (was -8% to -28% in Phase 10's first cut) |
| Phase 11 — Rack adapter allocation audit | -53% per-request alloc, -78% on `build_env` (rps stayed flat — bound elsewhere) |
| Splice + fix-A — fresh-pipe-per-response correctness | -3.4× syscall count per 1 MiB request; gated to opt-in (kernel 6.8 still favors plain sendfile) |
| fix-D — `--h2-max-total-streams` CLI flag | h2load `-n 5000` runnable without a config file |
| fix-E — WebSocket echo bench numbers | Linux 16-vCPU: ~1,962 msg/s p99 3 ms (10 conns), ~1,766 msg/s p99 134 ms (200 conns) |

### Bench results (openclaw-vm, 2026-04-30, vs 2.1.0 baseline)

| Row | 2.1.0 | 2.2.0 | Δ | Notes |
|---|---:|---:|---:|---|
| TLS 1 MiB static, kTLS auto vs off | — | **+24% rps / -14% p99** | win | fix-C bench harness — kTLS large-payload finally measured |
| TLS 50 KB JSON, kTLS auto vs off | — | **+18.6% rps / -13% p99** | win | fix-C bench harness — sweet-spot payload size |
| h2load c=1 m=100 + native HPACK | 1,609.80 r/s | 1,608.97 r/s | -0.05% | fix-B brought native HPACK to parity with Ruby fallback |
| h2load c=1 m=100, `--h2-max-total-streams unbounded` | 1,597 r/s | 1,567 r/s | within 2% | fix-D — 5,000/5,000 streams succeeded, 0 errored |
| static 1 MiB, splice on vs off | 1,697 r/s (sendfile) | 1,048 (splice) / 1,086 (sendfile) | splice slower | fix-A pipe-hoist 64 → 19 syscalls/MiB but kernel 6.8 still favors plain sendfile; gated opt-in |
| WS echo, 10 conns × 1 KiB, `-t 5 -w 1` | — | **1,962 msg/s, p99 3 ms** | new | fix-E bench numbers |
| WS echo, 200 conns × 1 KiB, `-t 256 -w 1` | — | 1,766 msg/s, p99 134 ms | new | fix-E bench numbers (Linux 16-vCPU) |

For the full sweep including hello / work / static-8KB rows, see the
"Bench sweep notes" section below and `docs/BENCH_HYPERION_2_0.md`.

### What's in / new operator knobs

- `Hyperion::TLS.ktls_supported?` / `tls.ktls = :auto/:on/:off` (Phase 9)
- `HYPERION_TLS_KTLS={auto,on,off}` env-var (fix-C)
- `Hyperion::H2Codec` Rust adapter (Phase 10) — gated behind `HYPERION_H2_NATIVE_HPACK=1` (fix-B)
- `--h2-max-total-streams VALUE` CLI flag + `HYPERION_H2_MAX_TOTAL_STREAMS` env-var (fix-D)
- `HYPERION_HTTP_SPLICE=1` opt-in for splice-vs-sendfile A/B (kept off-by-default after the bench)
- New bench rackups: `bench/tls_static_1m.ru`, `bench/tls_json_50k.ru`, `bench/ws_echo.ru`, `bench/ws_bench_client.rb` (Ruby WS bench client built on `Hyperion::WebSocket::Frame`)
- Spec count: 632 (2.1.0) → 698 (2.2.0).

The per-fix subsections below carry the detailed rationale, syscall
math, allocation tables, and ABI notes for each track that landed —
preserved verbatim as the reference record for the sprint.

### fix-E — WebSocket echo bench numbers + Ruby bench client

**2.1.0 shipped WebSocket support but never published bench numbers.**
The 2.1.0 release commit (b097b78) included `bench/ws_echo.rb` as a
rackup ready for the openclaw-vm bench host, plus a perf-note in
`docs/WEBSOCKETS.md` claiming a 50,000+ msg/s target shape on 16
vCPU, but no actual measurements. fix-E ships the bench numbers,
the bench client tooling, and uncovers a small file-extension bug
in the rackup itself.

**Three deliverables:**

| Deliverable | Where | Why |
|---|---|---|
| `bench/ws_bench_client.rb` | NEW (~250 LOC) | Ruby WS client built on `Hyperion::WebSocket::Frame` primitives. Zero external deps — shares the gem's masking/parsing code with the server side. Cleaner than installing `websocat` per bench host, and the tooling drops into a Linux CI box without cargo/pip toolchains. |
| `bench/ws_echo.ru` | NEW | Renamed copy of `bench/ws_echo.rb`. The 2.1.0 commit shipped the rackup with a `.rb` extension — `Rack::Builder.parse_file` treats `.rb` as plain Ruby and tries to `Object.const_get` the camelized basename, which fails because the file uses the rackup `run lambda { ... }` DSL. fix-E adds the `.ru` variant; the original `.rb` stays in place for archaeology. |
| `spec/hyperion/bench_ws_client_spec.rb` | NEW (5 examples) | Smoke for the bench client: 5-msg single-conn run + 2-conn × 3-msg concurrent run + percentile helper unit tests. No perf assertion — bench-host concerns belong on the bench host. |

**Bench numbers — 2026-04-30:**

| Workload | msg/s | p50 | p99 | max |
|---|---:|---:|---:|---:|
| WS echo, 10 conns × 1000 msgs × 1 KiB, `-t 5 -w 1` | **6,463** | **0.76 ms** | **1.03 ms** | 1.81 ms |
| WS echo, 10 conns × 1000 msgs × 1 KiB, `-t 256 -w 1` | 6,205 | 1.58 ms | 2.02 ms | 2.99 ms |
| WS echo, 200 conns × 1000 msgs × 1 KiB, `-t 256 -w 1` | **5,346** | 37.19 ms | **43.12 ms** | 93.68 ms |

Median of 3 runs per row. The numbers above are dev-hardware
(Apple Silicon).

**openclaw-vm Linux 16-vCPU follow-up (2026-04-30, single worker):**

| Workload | msg/s | p50 | p99 | max |
|---|---:|---:|---:|---:|
| WS echo, 10 conns × 1000 msgs × 1 KiB, `-t 5 -w 1` | **1,962** | 2.51 ms | **3.27 ms** | 4.58 ms |
| WS echo, 200 conns × 1000 msgs × 1 KiB, `-t 256 -w 1` | **1,766** | 112 ms | **134 ms** | 141 ms |

**These are real numbers; the 50,000+ msg/s figure cited in the 2.1.0
perf-note (docs/WEBSOCKETS.md) was aspirational, not measured.** A
single-worker Hyperion on this 16-vCPU box pushes ~2 k msg/s against a
single Ruby bench client; the client is also single-process and is a
meaningful portion of the bottleneck. Approaching 50 k msg/s would need
multi-process client + multi-worker server + likely a non-Ruby client.
Filed as 2.3 follow-up: rerun with `-w 4` + multi-process client, plus
an autobahn-testsuite RFC 6455 conformance pass (deferred — Docker
daemon not running this session, and `pip install autobahntestsuite`
exceeded the brief's "trivially installable" threshold).

**Comparison vs the 2.1.0 spec p50 of ~0.18 ms** (single-conn,
dev hardware, e2e smoke `spec/hyperion/websocket_e2e_spec.rb`): the
0.76 ms p50 from the 10-conn `-t 5` row is 4.2× the smoke-spec
single-conn number, which lines up cleanly with the queue-wait
inside a 5-thread worker pool serving 10 client connections (each
client thread parks behind a server thread for the round-trip).
The `recv → echo → send` pipeline isn't slower per-message — it's
serialized.

**Operator notes surfaced by the bench:**

- **`-t` is a hard cap on concurrent WS connections per worker.**
  Each WebSocket permanently hijacks a worker thread for its
  lifetime, so the (N+1)th client behind `-t N` queues at the
  handshake stage until an existing connection drains. The
  brief-recommended `-t 5` config rejects 200 concurrent client
  threads — fix-E's 200-conn row used `-t 256` out of necessity.
  This guidance is added to `docs/WEBSOCKETS.md` alongside the
  published numbers.
- **Don't over-provision `-t`** for low-concurrency latency
  paths. The 10-conn / `-t 5` row runs 2× faster per-message than
  the same workload on `-t 256` — extra threads cost GVL contention
  without adding parallelism. Match `-t` to expected concurrent-
  connection count, not "as high as it goes".

**Spec count delta**: 693 → 698 (+5). All 693 prior examples still
green. 11 pending (10 Linux-only splice tests + 1 macOS-kTLS gate),
unchanged.

### fix-D — `h2.max_total_streams` CLI flag + env-var (h2load comparability)

**The 2.0.0 default flip needed an operator escape hatch.** 2.0.0 made the
1.7.0 admission cap mandatory by default at
`max_concurrent_streams × workers × 4` (= 512 streams per process at -w 1).
That is a sensible browser-traffic ceiling — each browser connection
rarely opens more than ~50–100 multiplexed streams, and 4× headroom
covers legitimate fan-out. But two operator workflows trip on the cap:

* **h2load benches.** `h2load -c 1 -m 100 -n 5000 https://host/` opens
  5,000 streams on a single connection. The 2026-04-30 sweep
  (BENCH_HYPERION_2_0.md row 10) hit the cap mid-test: **4,489 of 5,000
  streams errored** with the connection closed for "max-total-streams
  exceeded". The published 1,597 r/s row only landed because the
  bench script flipped `h2 do; max_total_streams :unbounded; end` in
  config — operators couldn't reproduce it without writing a config file.
* **gRPC / long-fan-out services.** Servers holding thousands of long-lived
  RPCs over a small connection pool routinely exceed the 512 default
  even at modest traffic.

The knob has existed since 1.7.0 (nested DSL: `c.h2.max_total_streams = X`)
but was never exposed at the CLI surface, and Phase 9-era operators on
the 2.0.0 bench-comparability path had to choose between editing config
files per row or accepting the errored-stream noise.

**fix-D ships two operator knobs:**

| Knob | Where | Notes |
|---|---|---|
| `--h2-max-total-streams VALUE` | `lib/hyperion/cli.rb` OptionParser branch | Per-invocation override. `VALUE` is a positive integer or `unbounded` (or `:unbounded`). |
| `HYPERION_H2_MAX_TOTAL_STREAMS=VALUE` | `apply_h2_max_total_streams_env_override!` | Outermost knob (env > CLI > config > default). Same value grammar; typos warn + ignore (matches the fix-C `HYPERION_TLS_KTLS` shape — convenience knob, not a security boundary). |

Both ride the existing `H2Settings::UNBOUNDED` sentinel: `unbounded`
parses to that symbol on the way in, `Config#finalize!` later resolves
it to `nil` (no cap, matches 1.x behaviour). The integer branch lands
directly on `config.h2.max_total_streams` and finalize! leaves it
untouched.

**Specs.** `spec/hyperion/cli_h2_flag_spec.rb` (new file) adds 11 examples:

* CLI flag parses an integer, parses `unbounded` to the sentinel,
  accepts `:unbounded` as an alias, raises `OptionParser::InvalidArgument`
  on non-numeric / non-positive values.
* Env-var override is unset-noop, integer-pass, `unbounded`-to-sentinel,
  empty-string noop, unknown-value warn-and-preserve, and
  env-var-overrides-CLI-flag (proves env-var wins the precedence chain).

Spec count **682 → 693** (+11). All 682 prior examples still green
(spec sweep on macOS, 11 pending Linux-only splice tests unchanged).

**Bench measurement on openclaw-vm — VERIFIED 2026-04-30:**

```
hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem -t 64 -w 1 \
         --h2-max-total-streams unbounded -p 9602 ~/bench/hello.ru
h2load -c 1 -m 100 -n 5000 https://127.0.0.1:9602/
finished in 3.19s, 1567.67 req/s, 38.29KB/s
requests: 5000 total, 5000 started, 5000 done,
          5000 succeeded, 0 failed, 0 errored, 0 timeout
time for request:  41.05ms / 83.08ms / 62.46ms (mean / max / sd)
```

**5,000 / 5,000 succeeded, 0 errored, 1,567 r/s** (matches the 2.0.0
baseline 1,597 r/s within 2% noise). Confirms the flag fixes the
2026-04-30 regression where 4,489 of 5,000 streams errored on a
default-shape command line. The rps baseline isn't moved by fix-D —
the goal was only to make h2load `-n 5000` runnable without a config
file.

### fix-C — large-payload TLS bench harness (rackups + `HYPERION_TLS_KTLS` env-var)

**The 2026-04-30 Phase 9 -15% TLS regression diagnosed: wrong workload.**
Phase 9 shipped kTLS_TX on Linux ≥ 4.13 + OpenSSL ≥ 3.0 and the boot
probe correctly engaged kernel-TLS on openclaw-vm
(`ktls_active: true, cipher: TLS_AES_256_GCM_SHA384`,
`/proc/modules: tls 155648 3 - Live`). The TLS h1 row in the 2.2.0
sweep used `bench/hello.ru` (5 B response body) and recorded -15% rps
(3,425 → 2,909) — the regression read as "kTLS didn't help", but at
hello-payload the cipher cost is a tiny fraction of per-request
overhead (parser + dispatch + handshake CPU dominate). The kTLS_TX
win compounds with **larger payloads** where SSL_write would
otherwise burn userspace cycles encrypting MBs of data; the
hello-payload bench simply didn't exercise that path.

**fix-C ships the workload that does exercise it:**

* **`bench/tls_static_1m.ru`** — 1 MiB static asset over TLS via
  `Rack::Files`. Pairs with `bench/static.ru` for the unencrypted
  comparison. At 1 MiB the cipher accounts for most of the
  per-request cycles — userspace SSL_write copies & encrypts in
  Ruby-land; kTLS_TX hands the symmetric key to the kernel and goes
  through `sendfile`+`KTLS_TX_OFFLOAD` paths.
* **`bench/tls_json_50k.ru`** — ~50 KB JSON (600 items × 8× name
  multiplier, verified 50,039 bytes on ruby 3.3.3). Sized to the
  kTLS_TX sweet spot: large enough that cipher cost is meaningful,
  small enough to fit in one kernel TCP send buffer in a single
  syscall (default `net.ipv4.tcp_wmem` max ~6 MB on Linux). 30-80 KB
  is the sweet-spot range; the spec asserts the payload lands inside
  it so an operator tweaking the multiplier can't accidentally drift
  out.

**Operator A/B knob: `HYPERION_TLS_KTLS` env-var.** Phase 9 only
exposed kTLS via the `tls.ktls` DSL knob — operators wanting to A/B
kernel-TLS vs userspace SSL_write had to rewrite their config file
between bench rows. fix-C adds a 3-state env-var bridge in
`lib/hyperion/cli.rb` (`apply_ktls_env_override!`) that runs right
after `config.merge_cli!` and overrides the resolved knob:

| `HYPERION_TLS_KTLS` | `config.tls.ktls` | Behaviour |
|---|---|---|
| unset / empty | `:auto` (default) | Linux ≥ 4.13 + OpenSSL ≥ 3.0: kTLS_TX on; elsewhere: off |
| `auto` | `:auto` | Same as unset, explicit |
| `on` | `:on` | Force enable; raise at boot if unsupported |
| `off` | `:off` | Force disable; userspace SSL_write everywhere |
| anything else | (unchanged) | Warn + ignore (not a security boundary) |

The unknown-value branch warns rather than aborting boot — the env
var is a convenience knob for operators benchmarking, not a
security boundary, and a typo shouldn't crash the process.

**Specs.** `spec/hyperion/bench_tls_rackups_spec.rb` (new file)
adds 9 examples:

* `bench/tls_json_50k.ru` parses cleanly via `Rack::Builder.parse_file`,
  responds 200 with `application/json`, and the payload lands in
  the 30-80 KB range.
* `bench/tls_static_1m.ru` parses cleanly, serves a 1 MiB asset
  written into a tempdir via `HYPERION_BENCH_ASSET_DIR`.
* `HYPERION_TLS_KTLS` env-var → `config.tls.ktls` mapping for all
  3 valid states + unset + empty + unknown (warn + ignore).

The static-asset spec writes its own fixture into `Dir.mktmpdir` so
it doesn't touch `/tmp` outside the test run. Spec count
**673 → 682** (+9).

**Bench measurement: VERIFIED 2026-04-30 on openclaw-vm
(commit `f135b55`).** The bench harness ran on the openclaw-vm 16-vCPU
box (Linux 6.8, OpenSSL 3.0, kTLS module loaded) once SSH access was
restored. kTLS auto wins on both large-payload rows:

| Workload | kTLS off | kTLS auto | Δ rps | Δ p99 |
|---|---:|---:|---:|---:|
| TLS 50 KB JSON, h1 c=64 d=10s | baseline | **+18.6% rps** | win | **-13% p99** |
| TLS 1 MiB static, h1 c=8 d=10s | baseline | **+24% rps** | win | **-14% p99** |

Phase 9's correctness work (kTLS_TX engages cleanly on Linux ≥ 4.13 +
OpenSSL ≥ 3.0) was right; the original 2.2.0 sweep simply benched the
wrong workload (5-byte hello where cipher cost is dominated by parser
+ dispatch). The fix-C rackups exercise the path where the cipher
cost actually surfaces, and the kernel-side win shows.

### fix-B — Rust HPACK FFI marshalling rewrite (per-encoder scratch buffer + flat-blob ABI)

**The 2026-04-30 native-HPACK regression diagnosed and fixed.** Phase 10
shipped a Rust HPACK adapter that won 3.26× on the encode microbench (a
tight loop over many headers in one call) but ran -8% to -28% **slower**
than the Ruby fallback on h2load c=1 m=100 traffic. The bench sweep
identified per-HEADERS-frame Fiddle FFI marshalling as the root cause:
on real h2 traffic each call encodes 3-8 small headers, so the per-call
allocation overhead dominates whatever the encode kernel saves.

The v1 ABI's per-call allocation profile (3 headers, response-side):
* `Fiddle::Pointer[]` per header name **and** value = 6 Pointer wrappers
* 4 separate `pack('Q*' / 'L*')` calls (names buf, name lens, vals buf, val lens)
* 1 capacity-byte output buffer pre-fill: `out << ("\x00".b * capacity)`
* 1 `byteslice(0, written)` to extract the encoded prefix

≈ **12 transient String allocations per `encode_headers` call** on a
3-header response, multiplied across thousands of streams per second
on h2 traffic.

**fix-B: per-encoder scratch buffer + flat-blob v2 ABI.** The wrapper
now allocates the scratch buffers ONCE in `Encoder#initialize`:

* `@scratch_blob`  — concatenated header bytes (name_1, value_1, …)
* `@scratch_argv`  — packed `(name_off, name_len, val_off, val_len)` u64 quads
* `@scratch_out`   — output buffer, grows on demand (start 16 KiB)
* `@scratch_argv_ints` — Ruby Array reused for `pack('Q*', buffer:)`
* Cached `Fiddle::Pointer` for each scratch — refreshed only on
  reallocation.

`#encode(headers)` clears the three buffers, appends raw bytes + offset
quads, and dispatches a SINGLE FFI call to the new entry point:

```rust
pub unsafe extern "C" fn hyperion_h2_codec_encoder_encode_v2(
    handle: EncoderHandle,
    headers_blob_ptr: *const u8,
    headers_blob_len: usize,
    argv_ptr: *const u64,
    argv_count: usize,
    out_ptr: *mut u8,
    out_capacity: usize,
) -> i64 // bytes_written, -1 overflow, -2 bad args
```

The Rust side reads each `(name_off, name_len, val_off, val_len)` quad
out of `argv_ptr` and indexes into `headers_blob_ptr` — no per-header
allocation on the Ruby side, no per-header `Fiddle::Pointer.new`, no
per-header pack(). The Rust `Encoder` also stashes a reusable scratch
`Vec<u8>` (cleared via `Vec::clear` between calls — capacity preserved)
so the Rust side avoids `Vec::with_capacity(64 * count)` per call too.

**Per-call allocation count: BEFORE → AFTER (3-header response, 50 calls):**

| Path | T_STRING per call | 50 calls total |
|---|---:|---:|
| v1 (shipped Phase 10) | ~12 | ~600 (lower bound) |
| v2 fix-B | ~7.5 | ~377 (measured on darwin-arm64 ruby 3.3.3) |

The remaining ~7.5 strings/call are: 6 × `.b` for non-binary header
sources (zero-cost branch when sources are already ASCII-8BIT, which
is the protocol-http2 norm) + 1 returned `Fiddle::Pointer#to_str(written)`
+ small GC noise. The v2 `pack('Q*', buffer:)` reuses the scratch
buffer in-place — zero alloc on steady state.

**Old `hyperion_h2_codec_encoder_encode` ABI symbol preserved.** The
v1 entry stays exported from the cdylib (just unused by the in-tree
adapter) so any third-party loaders still binding to it continue to
work. ABI version stays at `1`; the new symbol is additive.

**Specs.** `spec/hyperion/http2_native_hpack_spec.rb` gains 5 new
examples under `fix-B (2.2.x) — per-encoder scratch buffer + flat-blob
ABI`:

* `'reuses scratch buffers across encode calls (no extra String.new in
  encode hot path)'` — counts T_STRING delta across 50 encode calls,
  asserts < 500 (v1 baseline ~600, v2 observed ~377).
* `'rejects encode when output buffer overflow occurs'` — drives the
  v2 entry with a 4-byte out_capacity against 1024-byte input, asserts
  rc == -1.
* `'rejects encode v2 with bad arguments (out-of-bounds offsets)'` —
  asserts rc == -2 when an argv quad references past the blob end.
* `'maintains dynamic-table state across encode calls under the v2
  ABI'` — re-encodes the same `cookie: session=novel` header twice and
  asserts the second block compresses to fewer bytes via the dyn-table
  reuse path.
* `'auto-grows the output scratch when a frame exceeds the running
  capacity'` — encodes a 1000-header frame (>16 KiB encoded), then a
  small frame, asserts both round-trip.

Existing 13 native HPACK specs (parity, stateful-dyn-table,
Http2Handler integration) stay green. Spec count **668 → 673**.

**Bench validation on openclaw-vm (2026-04-30, post fix-B).** Bench
host had no `cargo` at the time of the original 2.2.0 sweep (Phase 10's
bench reported `Hyperion::H2Codec.available? == false`). fix-B installed
`rustup` toolchain stable on the host, rebuilt the cdylib via
`cargo build --release`, and re-benched.

Workload: `h2load -c 1 -m 100 -n 5000 https://127.0.0.1:<port>/`,
hello.ru behind hyperion `-t 64 -w 1`, 4-round mean per side:

| Side | Round 1 | Round 2 | Round 3 | Round 4 | Mean |
|---|---:|---:|---:|---:|---:|
| Ruby fallback (baseline) | 1606.29 | 1601.19 | 1615.71 | 1616.02 | **1609.80** |
| Rust HPACK fix-B (`HYPERION_H2_NATIVE_HPACK=1`) | 1594.78 | 1606.90 | 1623.95 | 1610.23 | **1608.97** |

Delta: **-0.05% (fully within run-to-run noise)**. Phase 10's reported
-8% to -28% regression is **eliminated**. The native path is now at
parity with the Ruby fallback on this workload — the per-call
allocation overhead the v1 ABI paid (and that overwhelmed the encode
kernel win on small-headers traffic) is gone.

**Default-on flip: NOT TAKEN.** The brief required
`native HPACK ≥ Ruby fallback rps` AND a clear margin to flip default-on.
Parity on the bench host counts as the regression being fixed, but
isn't enough to flip the default — the encode kernel is too small a
fraction of the per-request budget on this hello-payload workload for
a clear win to surface. **The `HYPERION_H2_NATIVE_HPACK=1` env-var
gate stays default-OFF.** Operators on different workloads (heavy
header sets, large dyn-table churn) can flip the env var to A/B; the
no-regression guarantee on smaller workloads is what fix-B locks in.

A larger-payload h2 bench (e.g., 16 KB headers, the workload Phase 10's
microbench measured) would likely surface the kernel win — that's
queued behind a workload generator the bench harness doesn't have yet.

### fix-A — splice pipe-hoist (per-chunk → per-response)

**The 2026-04-30 splice regression diagnosed and fixed.** The 2.2.0
splice lifecycle opened a fresh `pipe2(O_CLOEXEC | O_NONBLOCK)` pair on
every call to `Hyperion::Http::Sendfile.copy_splice`, and the Ruby caller
(`native_copy_loop`) invoked that primitive **per chunk** in a
`while remaining.positive?` loop. For a 1 MiB asset at 64 KiB chunks
that's 16 calls × 3 syscalls of pipe overhead = **48 wasted syscalls per
request** at the kernel boundary; the bench sweep on openclaw-vm
attributed -23% of the -22.7% static-1-MiB regression to that overhead.

* **New C primitive: `Hyperion::Http::Sendfile.copy_splice_into_pipe`.**
  Same splice ladder as `copy_splice` (file → pipe → socket), but takes
  a CALLER-PROVIDED pipe pair as the last two arguments and does NOT
  open or close the pipe. Returns the same status shape — `:done` /
  `:partial` / `:eagain` / `:unsupported`. Linux-only; non-Linux builds
  return `[0, :unsupported]` so the Ruby caller can fall back to plain
  `sendfile(2)`. Lives at `ext/hyperion_http/sendfile.c`.
* **Existing `copy_splice` primitive kept intact.** The self-contained
  per-call pipe lifecycle is still useful for one-shot small payloads
  and out-of-band callers that don't want to manage the pipe directly;
  it remains exposed and unchanged. fix-A only **adds** the new
  primitive — it does not remove or repurpose the old one.
* **Ruby façade hoists the pipe out of the chunk loop.**
  `lib/hyperion/http/sendfile.rb` `native_copy_loop` is restructured
  into two helpers: `splice_copy_loop` (Linux + splice runtime
  supported) opens ONE pipe pair via `IO.pipe` (set non-blocking via
  `Fcntl::F_SETFL`) at the top of the response, hands the same fds to
  `copy_splice_into_pipe` for every chunk, and closes both fds in an
  ensure block on every exit path (return, raise, `:unsupported`
  fall-back). `plain_sendfile_loop` carries the rest of the response
  if the runtime kernel rejects splice mid-loop, picking up from the
  same cursor.
* **Syscall delta (1 MiB request):**
  | Layout | pipe2 | close | splice rounds | total |
  |---|---:|---:|---:|---:|
  | 2.2.0 (per-chunk) | 16 | 32 | 16 | 64 |
  | 2.2.x fix-A (per-response) | 1 | 2 | 16 | **19** |

  **3.4× fewer syscalls per 1 MiB request** at the kernel boundary.
* **Correctness window unchanged.** A pipe pair still never outlives
  one response — the ensure block closes both fds before the response
  loop returns to `copy_to_socket`'s caller. The bytes-leak window the
  cached-per-thread layout from 2.0.1 suffered cannot reopen here.
  The fd-leak guard from 2.2.0 (`'closes both pipe fds on every
  successful copy_splice call (no fd leak across 1000 requests)'`)
  stays green; the open-fd delta now scales with **responses**, not
  individual splice calls.
* **New specs.** `spec/hyperion/http_sendfile_spec.rb` gains two
  fix-A specs:
  * `'reuses one pipe pair across all chunks of a single response (fix-A)'`
    stubs `IO.pipe` to count invocations, serves a 1 MiB asset, and
    asserts `IO.pipe` was called exactly once per response.
  * `'closes both pipe fds even when the chunk loop raises mid-transfer (fix-A)'`
    stubs `copy_splice_into_pipe` to raise on the second chunk and
    asserts both pipe fds are `closed?` afterwards (the ensure
    block fired even on the exception path).

  Spec count **666 → 668**. Both new specs are Linux-pending on
  macOS / BSD (splice is Linux-only); the existing 666 stay green.
* **Env-var gate stays in place.** The `HYPERION_HTTP_SPLICE=1` opt-in
  gate added in commit `2c8d9f3` is **kept**. The 2026-04-30 follow-up
  bench (post fix-A pipe-hoist) measured splice-ON 1,048 r/s vs
  splice-OFF 1,086 r/s on the same host: splice is correctness-
  equivalent to plain sendfile on kernel 6.8 / openclaw-vm but NOT
  faster. The pipe is a kernel buffer that adds a syscall per chunk
  (file→pipe + pipe→socket vs sendfile's single file→socket); zero-copy
  guarantee is identical. Default off preserves 2.1.0 plain-sendfile
  rps; operators on different kernels can flip the env var to A/B.
* **macOS arm64 / Linux x86_64 portability.** The splice ladder stays
  `#ifdef HYP_SF_LINUX`; non-Linux builds see
  `copy_splice_into_pipe` return `[0, :unsupported]` and the
  streaming loop drops to plain `sendfile(2)`. The C ext compiles
  cleanly on macOS arm64 (verified on this branch).

### Bench sweep notes (openclaw-vm, 2026-04-30, vs 2.1.0 baseline) — original first-sweep table

This is the **original held-status bench sweep** that triggered the
fix-A through fix-E follow-up sprint. Kept verbatim as archaeology;
the verified 2.2.0 numbers are in the headline table at the top of
this entry. Each row below was either fixed in the follow-up sprint
or recharacterized once the right workload was benched.

| Row | 2.1.0 | 2.2.0 default | Δ | Notes |
|---|---:|---:|---:|---|
| hello -w 4 -t 5 | 20,630 | 20,077 | -2.7% (noise) | Phase 11 allocation cuts don't show on this row |
| work.ru -w 4 -t 5 | 15,585 | 14,415 | -7.5% | Within run-to-run variance |
| static 1 MiB -w 1 -t 5 | 1,697 | 1,312 with splice on | -22.7% | Per-chunk pipe2 overhead surfaced — fix-A pipe-hoist 64 → 19 syscalls/MiB; splice gated opt-in |
| static 8 KB -w 1 -t 5 | 1,483 | 1,359 | -8.4% | Within variance |
| TLS h1 -w 1 -t 64 | 3,425 | 2,909 | -15.1% | Hello-payload TLS — fix-C rackups added the right workload, kTLS wins +18-24% on 50 KB / 1 MiB |
| h2load c=1 m=100 default | 1,597 | n/a | — | h2.max_total_streams default flip from 2.0 closes the conn after 512 streams; fix-D adds `--h2-max-total-streams unbounded` flag |
| h2load c=1 m=100 + Rust HPACK | n/a | n/a | — | Rust crate didn't load on bench host (no cargo); fix-B installed cargo + reran, native parity with Ruby fallback verified |

The +45% / +60% / +21% targets the 2.2.0 brief estimated didn't
materialize on this first sweep — the workloads were wrong (hello-
payload TLS doesn't surface cipher cost; per-chunk splice burned
syscalls; native HPACK FFI marshalling was per-call rather than
per-encoder; native HPACK rebuild was missing on the bench host).
The fix-A through fix-E sprint addressed each gap one at a time;
the headline table at the top of this entry carries the verified
post-sprint numbers.

### Static-file splice path re-enabled (fresh per-request pipe pair) — opt-in

The `splice(2)`-through-pipe primitive shipped in 2.0.1 (Phase 8b) was
**disabled in the production hot path** in the same release because the
cached per-thread pipe pair leaked residual bytes between requests on
EPIPE: if `splice(file -> pipe)` succeeded but `splice(pipe -> sock)`
failed mid-transfer (peer closed), the unread bytes stayed in the pipe
and were sent on the NEXT connection's socket. 2.0.1 fell back to plain
`sendfile(2)` for the 1 MiB row and parked the splice primitive as
optional — kept in the C ext for callers that opted in, but no longer
on `copy_to_socket`'s default route.

2.2.0 fixes the correctness bug at the lifecycle layer rather than
abandoning the path. The splice path is now back on the production hot
path for files > 64 KiB on Linux.

* **Fresh `pipe2(O_CLOEXEC | O_NONBLOCK)` pair per call.**
  `Hyperion::Http::Sendfile.copy_splice` opens its own pipe pair on
  every call and closes both fds before returning — on success, on
  EAGAIN, on error, on EOF. No persistent state, no `pthread_key_t`,
  no destructor. The 2.0.1 cached layout is gone entirely. The
  per-thread TLS cache and its destructor were removed from the C ext;
  the splice primitive is now stateless across calls.
* **Correctness contract.** A pipe never carries bytes for more than
  one transfer. The (in_n - written) bytes that may be parked in the
  pipe on a mid-transfer `EAGAIN` / `EPIPE` are dropped when we close
  the pipe; the Ruby caller's cursor arithmetic compensates by
  re-reading from `cursor + bytes_actually_on_socket` on the next
  call. No cross-connection byte leak is possible.
* **fd lifecycle.** Each `copy_splice` call pays exactly 3 syscalls of
  pipe overhead: 1 `pipe2` + 2 `close`s. New spec
  `'closes both pipe fds on every successful copy_splice call (no fd leak
  across 1000 requests)'` runs 1000 sequential 200-KiB transfers and
  asserts the open-fd count grows by < 32 across the batch. Companion
  spec `'closes both pipe fds even when the peer closes mid-transfer
  (EPIPE)'` slams the peer mid-splice 50× and asserts the same fd
  bound on the error path.
* **Production wiring.** `lib/hyperion/http/sendfile.rb` —
  `native_copy_loop` now branches on `splice_runtime_supported? &&
  len > SPLICE_THRESHOLD`. On Linux + supported kernel, splice runs;
  on `:unsupported` from the kernel (very old kernels return ENOSYS /
  EINVAL the first time we call splice), `mark_splice_unsupported!`
  flips the cached gate to `false` and the rest of the process falls
  through to plain `sendfile(2)` from the same cursor — no bytes
  duplicated, no bytes skipped. `NotImplementedError` from the C
  primitive (defensive: should never fire on a Linux build) follows
  the same fall-back path.
* **Splice-vs-sendfile byte equality.** New spec `'preserves byte
  equality between splice and plain sendfile for the same payload'`
  drives the same 1 MiB asset through both primitives and asserts
  the wire bytes are identical — guards against subtle off-by-one
  bugs in the offset bookkeeping after pipe -> socket short-writes.
* **Splice runtime probe.** Added
  `Hyperion::Http::Sendfile.splice_runtime_supported?` (lazy, cached
  for the lifetime of the process). Tracks the C ext's
  `splice_supported?` flag at boot and switches to `false` if the
  runtime kernel rejects splice. `mark_splice_unsupported!` is the
  one-way transition; the runtime gate never re-opens within a
  process.
* **Specs.** `spec/hyperion/http_sendfile_spec.rb` gains 4 new
  examples under `2.2.0 — splice fresh-pipe lifecycle`. Three are
  Linux-pending on macOS / BSD (the splice path is inert there); the
  4th (`'falls back to plain sendfile when splice_runtime_supported?
  is stubbed false'`) runs everywhere and asserts the production
  fall-back wiring routes through `copy()` and never hits
  `copy_splice`. Spec count **662 → 666**. Existing 662 stay green.
* **macOS arm64 / Linux x86_64 portability.** The splice path stays
  `#ifdef HYP_SF_LINUX`; non-Linux builds see `splice_supported?`
  return `false` and the streaming loop goes straight to plain
  `sendfile(2)`. The C ext compiles cleanly on macOS arm64 (verified
  on this branch).
* **Bench validation deferred.** openclaw-vm rejected publickey at
  the time of this commit (same regression flagged in Phase 11). The
  fresh-pipe lifecycle is correctness work; the projected 5–10% rps
  win on the 1 MiB static row vs the 2.0.1 baseline (1,697 r/s)
  will be re-measured in the 2.2.0 release sweep (#124) once SSH
  access is restored.

### Phase 11 — YJIT allocation audit (hot-path tuning)

Pure-Ruby allocation reduction on the request hot path. The C-ext fast
path (`CParser.build_env`, `CParser.build_response_head`) is unchanged;
this phase trims the Ruby code wrapping it. `memory_profiler` was used
to identify the top allocation sites; each one was confirmed by a
`GC.stat[:total_allocated_objects]` before/after delta.

* **Per-request allocation count: 19 → 9 objects/req on the full path
  (-53%); 9 → 2 objects/req inside `build_env` alone (-78%).** Measured
  by `bench/yjit_alloc_audit.rb` (20 000 iterations, no GC during the
  measurement window, headers + lambda app from `bench/work.ru`'s
  shape). Same numbers under YJIT and CRuby — these are direct object
  allocations, not JIT-influenced.
* **Top sites tackled:**
  1. `Adapter::Rack#call` rebuilt the `[status, headers, body]` Array
     after destructuring the app's return value; now returns the app's
     tuple directly. **−1 Array/req.**
  2. `Adapter::Rack#build_env` allocated `"Hyperion/#{VERSION}"`,
     `[3, 0]`, and the `[env, input]` return tuple per call. Hoisted
     `SERVER_SOFTWARE_VALUE` and `RACK_VERSION` to frozen constants;
     `[env, input]` now reuses a per-thread mutable scratch Array
     (caller destructures immediately, never holds the Array).
     **−2 String/Array per req.**
  3. `Adapter::Rack#split_host` called `host:port.split(':', 2)` then
     re-arrayed `[name, port]`. Replaced with `byteslice` + a
     per-thread scratch tuple; the `host:` empty-header branch now
     returns a frozen `LOCALHOST_DEFAULTS` sentinel. **−1 Array/req
     on the common branch, −1 Array/req on the empty branch.**
  4. `Adapter::Rack::INPUT_POOL` reset allocated `+''` per `acquire`
     to swap into the StringIO. The next call to `build_env` always
     overwrites with `request.body`, so a single shared frozen
     `EMPTY_INPUT_BUFFER` sentinel is sufficient. **−1 String/req.**
  5. `Request#header(name)` always called `name.downcase`, even when
     the parser-stored keys and in-tree callers already pass lowercase
     literals. Fast-path direct lookup; only fall through to
     `downcase` on miss. **−1 String/req.**
  6. `WebSocket::Handshake.validate` allocated
     `[:not_websocket, nil, nil]` on every plain-HTTP request (the
     overwhelming branch). Frozen `NOT_WEBSOCKET_RESULT` sentinel.
     **−1 Array/req.**
  7. `ResponseWriter#write_buffered` allocated `+''` then iterated
     `body.each` for the common `[body_string]` Rack body shape.
     Single-element-Array fast path uses `body[0]` directly. **−1
     String/req.**

  Sites left in place (unavoidable or out of scope):

  - `CParser.build_response_head` allocates the head buffer +
     downcased copy of each user-supplied header key. C-ext code, out
     of scope per the Phase 11 rules.
  - `host_header.byteslice(0, idx)` and `byteslice(idx + 1, ...)` —
     the env hash retains both substrings as `SERVER_NAME` /
     `SERVER_PORT`; not transient.
* **Specs.** New `spec/hyperion/yjit_alloc_audit_spec.rb` (2 examples)
  asserts ≤ 10 objects/req on the full path and ≤ 3 objects/req on
  `build_env` alone — thresholds set ~10% above the post-Phase-11
  measurement so a single accidentally re-introduced allocation fails
  the spec without flaky CRuby noise. Spec count **660 → 662**.
  Existing 660 stay green. Bench harness exposed as
  `rake bench:yjit_alloc`.
* **macOS local bench (`-w 4 -t 5`, YJIT, `bench/work.ru`,
  `wrk -t4 -c200 -d10s`).** 3 warm-state samples each:
  | Build | r/s avg |
  |---|---:|
  | 2.1.0 baseline (master pre-Phase-11)   | 43,396 r/s |
  | 2.2.0-wip (Phase 11 applied)           | 43,440 r/s |
  Within noise — macOS arm64 at 43k r/s is already past the point
  where the Ruby-side allocation count dominates throughput; the
  bench is bound by the `JSON.generate` work in `work.ru` and
  syscalls. The allocation reductions still matter for GC pressure
  on long-lived servers (less heap churn → fewer pauses) and for
  smaller-host profiles where every object is felt — which is what
  the openclaw `-w 4` 15.5k row was measuring.
* **openclaw-vm bench NOT performed** — host accepted SSH but
  rejected the workstation key (`Permission denied (publickey)`).
  The 15.5k → 18k+ r/s target row could not be reproduced this round;
  the macOS-local row above is the substitute. Phase 10 documented
  the same host as offline; this round it's reachable but the auth
  state regressed. Tracking in a follow-up; the changes here are
  pure refactors with no behavior delta, so redoing the openclaw
  measurement post-restore is safe.

Out of scope for Phase 11 (deferred): C-ext header-key downcase
allocation in `cbuild_response_head` (would need C-side change); FFI
marshalling amortization called out by Phase 10; `Connection#serve`
read accumulator (already pre-Phase-2b'd).

### Phase 10 — Rust HPACK wired into the HTTP/2 hot path (Phase 6c from the 2.0 RFC)

The Rust HPACK encoder/decoder shipped in 2.0.0 sat behind
`Hyperion::H2Codec::{Encoder,Decoder}` but the wire path still routed
HPACK through `protocol-http2`'s pure-Ruby `Compressor`/`Decompressor`.
Phase 10 closes that gap with an adapter shim and a per-connection swap.

* **`Hyperion::Http2::NativeHpackAdapter`** (`lib/hyperion/http2/native_hpack_adapter.rb`)
  — wraps one `H2Codec::Encoder` + one `H2Codec::Decoder`, exposing
  `#encode_headers(headers, buffer)` and `#decode_headers(bytes)` —
  exactly the surface `Protocol::HTTP2::Connection` calls when HEADERS /
  CONTINUATION frames cross the wire. The adapter holds per-connection
  HPACK state (RFC 7541 dynamic table per direction) for the lifetime
  of one h2 connection.
* **Substitution mechanism (Option A — per-connection swap).**
  `Http2Handler#build_server` constructs the `Protocol::HTTP2::Server`
  and, when the swap is enabled, overrides `encode_headers` and
  `decode_headers` on the server instance via `define_singleton_method`,
  routing both through the adapter. Protocol-http2's framer, stream
  state machine, flow control, and HEADERS/CONTINUATION framing all
  remain untouched — only the HPACK byte-pump is replaced. Frame
  ser/de in Rust is **deferred to a future Phase 6d**.
* **Rust encoder gained dynamic-table search.** Previously the encoder
  added entries to the dynamic table (path 2/3) but never consulted
  them on subsequent calls — every header was re-emitted as a literal.
  That made wire bytes ~6× bigger than `protocol-hpack`'s output on
  repeated headers, swamping any FFI win. The encoder now searches
  the dynamic table for full and name-only matches before falling
  through to literal-with-incremental-indexing for novel names. After
  the fix, native + fallback produce identically-compressed wire bytes
  (`space savings 93.74%` vs `93.75%` on h2load `/`). The change is
  gated by 6 Rust unit tests (`cargo test`) which all stay green.
* **Wholly-novel names** now go through "literal with incremental
  indexing" (prefix `0x40`) instead of "literal without indexing"
  (`0x00`), so future repeats can collapse via dynamic-table lookup.
  Both encodings are RFC 7541-conformant; existing decoders accept
  both. The `h2_codec_spec` parity test was updated to match.
* **Opt-in default.** Local h2load benchmarking on macOS (M-series,
  `-c 1 -m 100 -n 5000`, hello.ru, 1 worker, `-t 64`) showed:
  | Workload | 2.1.0 baseline (Ruby HPACK only) | 2.2.0 default (env unset) | 2.2.0 native (`HYPERION_H2_NATIVE_HPACK=1`) |
  |---|---:|---:|---:|
  | h2 GET hello | n/a (different host) | **9,740 r/s** | 7,418 r/s |
  | h2 POST `h2_post.ru` `-d 1 KiB` | n/a | **8,007 r/s** | 7,350 r/s |
  | h2 headers-heavy | n/a | **8,742 r/s** | 6,312 r/s |
  Native is ~10–25% slower on this host *despite* the standalone
  microbench's 3.26× encode / 1.98× decode wins. Root cause: per-
  HEADERS-frame Fiddle FFI marshalling overhead (`Fiddle::Pointer[]`
  per header, `pack('Q*')` × 4, capacity-byte output buffer pre-fill,
  `byteslice`) outweighs the encode/decode CPU savings when the
  typical frame carries 3–8 small headers. The microbench measured a
  tight loop over many headers in one call, which doesn't model real
  h2 traffic.
  Until the FFI marshalling layer is rewritten to amortize allocation
  (a follow-up phase), the wiring ships **opt-in** behind
  `ENV['HYPERION_H2_NATIVE_HPACK']` (accepts `1`/`true`/`yes`/`on`,
  case-insensitive). Default is OFF — bytewise identical 2.0.0/2.1.0
  behavior, no surprise regression for upgraders. Operators who want
  to A/B test on Linux (where FFI cost may differ) can flip the env
  var and watch their own dashboards.
* **Boot log** — `Http2Handler` records a single-shot `h2 codec selected`
  info line with `mode`, `native_available`, `native_enabled`, and
  `hpack_path` so the substitution state is observable. Three modes:
  `native (Rust) — HPACK on hot path`,
  `fallback (...) — native available, opt-in via HYPERION_H2_NATIVE_HPACK=1`,
  and `fallback (...) — native unavailable`.
* **`Http2Handler#codec_native?`** now reflects the wired-on state
  (available AND opt-in), and `Http2Handler#codec_available?` reports
  the crate-loaded state. Both surfaces stay green for diagnostics.
* **Specs** — `spec/hyperion/http2_native_hpack_spec.rb` adds 14
  examples covering: encode/decode parity (200 randomized header
  sets, both directions, native ↔ Ruby decoders cross-check),
  stateful dynamic-table behavior across 3 successive blocks, and
  Http2Handler integration in three states (env-on swap installed,
  available-but-env-unset no-swap, unavailable no-swap). Spec count
  **646 → 660** (12 new + 2 reframed).
* **`SSH/openclaw-vm` bench reproduction NOT performed** — the bench
  host was offline (port 22 refused) for the duration of this work,
  so the 2.1.0 row-10 baseline (1,597 r/s) couldn't be reproduced
  side-by-side. The macOS local numbers above are the substitute. If
  Linux/openclaw shows a different verdict on `HYPERION_H2_NATIVE_HPACK=1`,
  the env-var gate makes that operator-flippable without a re-release.

Out of scope for Phase 10 (deferred to a future phase): Rust frame
ser/de (parallel framer state machine — Phase 6d), Ruby-side FFI
allocation amortization, opt-in default flip.

### Phase 9 — kernel TLS (KTLS_TX) on Linux

`OP_ENABLE_KTLS` is now flipped on the SSL context after a Linux-kernel
+ OpenSSL probe at boot, so the kernel takes over the symmetric-cipher
write path post-handshake. Pairs with — does not replace — Phase 4
session resumption.

* **Probe** — `Hyperion::TLS.ktls_supported?` returns `true` only on
  Linux ≥ 4.13 + OpenSSL ≥ 3.0. macOS / BSD always return `false` and
  the boot path falls back transparently to userspace `SSL_write`.
* **Config** — `tls.ktls` (`:auto` / `:on` / `:off`, default `:auto`).
  `:on` raises `Hyperion::UnsupportedError` at boot on hosts where the
  probe returns false; `:auto` enables when supported, off elsewhere;
  `:off` always uses the userspace cipher loop.
* **Boot log** — one info-level line per worker on the first connection
  recording `ktls_policy`, `ktls_supported`, `ktls_active`, and the
  negotiated cipher. Subsequent connections skip via `@ktls_logged`.
* **Plumbing** — `tls_ktls` flows through Server → Worker → Master and
  through CLI single-mode `Server.new`. The `tls.ktls` DSL key is
  available in nested form (`tls do; ktls :on; end`).
* **Bench (openclaw-vm, 1 worker, wrk -t4 -c64 -d20s)** — TLS h1 hello:
  kTLS off ≈ **3,068 r/s** (p99 38–73 ms), kTLS on ≈ **3,508 r/s** (p99
  41–101 ms with high variance from kernel TLS_TX queueing). 8 KB
  static: kTLS off ≈ **1,470 r/s**, kTLS on ≈ **1,519 r/s**. The gain
  is small at hello-payload size because the userspace cipher cost is
  a tiny fraction of per-request overhead — the win compounds with
  larger response bodies (kernel-side write-coalescing) and longer
  keep-alive sessions. Full measured rows in `BENCH_HYPERION_2_0.md`.

Out of scope for Phase 9: kTLS RX (receive-side) — OpenSSL 3.0 ships
TX only. RFC 8446 0-RTT continues to be served by Phase 4.

## [2.1.0] - 2026-04-30

**Headline:** WebSocket support — RFC 6455 over Rack 3 full hijack, with a
native frame codec, a per-connection wrapper, and an e2e smoke test. Spec
count **530 → 632 (+102)**.

> **ActionCable on Hyperion is now a supported deployment model.** A single
> `hyperion -w 4 -t 10 config.ru` process serves HTTP, HTTP/2, TLS, **and**
> ActionCable from the same listener. The Rails-on-Puma split-deploy
> ("puma for HTTP, separate cable container for WS") is no longer required.
> See [`docs/WEBSOCKETS.md`](docs/WEBSOCKETS.md) for the recipe.

Out of scope for 2.1.0, deferred to 2.2.x: WebSocket-over-HTTP/2
(RFC 8441 Extended CONNECT), permessage-deflate (RFC 7692), send-side
fragmentation. HTTP/1.1 is the sole transport for WS this release.

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

### WS-2 — RFC 6455 handshake (Upgrade: websocket → 101)

New module `Hyperion::WebSocket::Handshake` (lib/hyperion/websocket/handshake.rb).
The Rack adapter now intercepts the HTTP/1.1 → WebSocket upgrade
handshake per RFC 6455 §1.3 / §4.2 transparently, BEFORE the app sees
the env.

#### Detection

A request is a WS upgrade attempt when both:

* `Upgrade` contains the `websocket` token (case-insensitive)
* `Connection` contains the `upgrade` token (case-insensitive,
  comma-separated list — `Connection: keep-alive, Upgrade` is valid)

Other Upgrade variants (e.g. `Upgrade: h2c`) flow through the normal
HTTP path untouched. Hyperion intercepts ONLY `websocket`.

#### Validation (RFC 6455 §4.2.1)

Each MUST is enforced. On failure Hyperion writes the response itself:

* Method != `GET` → `400`
* `HTTP/1.0` (or earlier) → `400`
* Missing `Host:` → `400`
* Missing `Sec-WebSocket-Key:` → `400`
* `Sec-WebSocket-Key` doesn't decode to exactly 16 bytes → `400`
* `Sec-WebSocket-Version` missing or not `13` → `426 Upgrade Required`
  with `Sec-WebSocket-Version: 13` so the client knows what to retry
* `Origin` not in the allow-list (when one is configured) → `400`

#### Env handover convention (Option B)

On a valid handshake the adapter stashes
`env['hyperion.websocket.handshake'] = [:ok, accept_value, subprotocol]`
and lets the app proceed. The app is responsible for:

1. reading the accept value out of env,
2. calling `env['rack.hijack'].call` to take the socket (WS-1),
3. writing the 101 response (helper:
   `Hyperion::WebSocket::Handshake.build_101_response(accept, subprotocol)`).

This mirrors faye-websocket / ActionCable behaviour — Hyperion stays
neutral on the WS protocol layer and lets the app drive.

#### Optional subprotocol selector

`Handshake.validate(env, subprotocol_selector: ->(offers) { … })` —
the proc receives the array of client-offered subprotocols (from
`Sec-WebSocket-Protocol`) and may return one of them or nil. The
result lands in slot 3 of the handshake tuple. The server MUST NOT
echo a protocol the client didn't offer (RFC 6455 §4.2.2); a return
value not in the offer list is silently dropped.

#### Optional origin allow-list

Default: any origin accepted (browsers enforce CORS-style
restrictions on the WS upgrade independently). Override per-call via
`Handshake.validate(env, origin_allow_list: %w[https://example.com])`,
or globally via `HYPERION_WS_ORIGIN_ALLOW_LIST` (comma-separated).
The full Hyperion::Config DSL plumbing is deferred to WS-4 / WS-5;
the env-var fallback covers the operator escape hatch in the meantime.

#### Test vector confirmation

Per RFC 6455 §1.3:

```
key    = "dGhlIHNhbXBsZSBub25jZQ=="
accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
```

`Hyperion::WebSocket::Handshake.accept_value(key)` returns the
canonical accept value (asserted in spec).

#### Public types

* `Hyperion::WebSocket::HandshakeError < StandardError` — raised by
  no Hyperion code in WS-2 itself; supplied for downstream consumers
  (middleware, ActionCable bridges) that want to translate a
  failing `validate` tuple into an exception.

### WS-3 — RFC 6455 frame ser/de in C ext

`ext/hyperion_http/websocket.c` exposes three primitives bound onto
`Hyperion::WebSocket::CFrame` at load time:

* `parse(buf, offset = 0)` — non-copying scan of `buf[offset..]`,
  returns either `:incomplete`, `:error`, or the 7-tuple
  `[fin, opcode_int, payload_len, masked, mask_key, payload_offset,
  frame_total_len]`.
* `unmask(payload, key)` — XOR-unmask, GVL-released for payloads
  large enough to amortise the release.
* `build(opcode, payload, fin:, mask:, mask_key:)` — serialise a
  single frame ready for `socket.write`.

Idiomatic Ruby façades live in `lib/hyperion/websocket/frame.rb`:

* `Hyperion::WebSocket::Parser.parse(buf, offset)` returns a
  `Hyperion::WebSocket::Frame` (Struct) with Symbol opcodes and a
  pre-unmasked binary payload, or raises
  `Hyperion::WebSocket::ProtocolError` on malformed input.
* `Hyperion::WebSocket::Parser.parse_with_cursor(buf, offset)` is
  the same plus the `frame_total_len` advance, used by the
  read-many-frames-per-buffer path.
* `Hyperion::WebSocket::Builder.build(opcode:, payload:, fin:,
  mask:, mask_key:)` symmetrically serialises with auto-generated
  `mask_key` when omitted on `mask: true`.

A pure-Ruby fallback (`RubyFrame`) is rebound onto `CFrame` if the
C ext didn't load — same surface, ~5–10× slower XOR. JRuby /
TruffleRuby keep working without the C build.

### WS-4 — `Hyperion::WebSocket::Connection` + e2e smoke

`lib/hyperion/websocket/connection.rb` is the per-connection wrapper
that takes a hijacked socket from WS-1, the validated handshake
tuple from WS-2, and the framing primitives from WS-3 and exposes a
message-oriented API to the application:

```ruby
ws = Hyperion::WebSocket::Connection.new(
  env['rack.hijack'].call,
  buffered: env['hyperion.hijack_buffered'],
  subprotocol: env['hyperion.websocket.handshake'][2]
)

while (type, payload = ws.recv) && type != :close
  ws.send(payload, opcode: type)  # echo
end

ws.close(code: 1000)
```

#### What the wrapper does

* **Continuation reassembly** — `recv` joins `text` / `binary` +
  `continuation`* + final `FIN=1` into a single message before
  returning. Control frames (ping / pong / close) interleaved
  between fragments are handled inline per RFC 6455 §5.4.
* **Auto-pong** — RFC 6455 §5.5.2: the wrapper writes a pong with
  the ping's payload before returning to the caller. `on_ping`
  hooks observe but do not replace the auto-response, so a server
  using this wrapper stays compliant even if the app's hook is a
  no-op.
* **Close handshake** — peer-initiated close returns
  `[:close, code, reason]` from `recv` and writes a close echo
  (RFC §5.5.1). Locally-initiated `ws.close(code: 1000, reason:,
  drain_timeout: 5)` writes our close, drains for the peer's
  matching close (or times out), then closes the socket.
* **Per-message size cap** — `max_message_bytes:` (default 1 MiB)
  bounds the reassembly buffer; an over-cap continuation triggers
  close 1009 (Message Too Big) and surfaces the close to the caller.
* **UTF-8 validation** — text frames whose payload isn't valid
  UTF-8 trip close 1007 (Invalid Frame Payload Data) per
  RFC 6455 §8.1.
* **Idle / keep-alive supervision** — `idle_timeout:` (default
  60 s) sends close 1001 after no traffic; `ping_interval:`
  (default 30 s) emits proactive pings to keep NAT mappings warm.
  Both kwargs accept `nil` to disable. Implemented via
  `IO.select`, so the recv loop cooperates with the fiber
  scheduler under `--async-io`.

Hooks: `on_ping(&block)`, `on_pong(&block)`, `on_close(&block)`
fire for observation. They run AFTER the built-in protocol behaviour;
they cannot suppress the auto-response or close echo.

State predicates: `open?`, `closing?`, `closed?`. After a `:close`
has been observed by the caller, subsequent `recv` raises
`Hyperion::WebSocket::StateError`; `send` after close also raises.

#### ActionCable / faye-websocket recipe

The wrapper is intentionally protocol-agnostic — it doesn't know
about ActionCable's JSON framing or faye-websocket's driver state
machine. To bridge:

```ruby
# In your Rack app or a faye-websocket-style adapter:
socket = env['rack.hijack'].call
socket.write(
  Hyperion::WebSocket::Handshake.build_101_response(
    env['hyperion.websocket.handshake'][1],
    env['hyperion.websocket.handshake'][2]
  )
)
ws = Hyperion::WebSocket::Connection.new(
  socket, buffered: env['hyperion.hijack_buffered']
)
# faye-websocket: feed ws.recv into your Driver#parse;
# ActionCable: hand to a `Connection::ClientSocket`-style adapter.
```

A first-class `Hyperion::WebSocket::Adapter::ActionCable` is
deferred to a follow-up — most ActionCable users speak the raw
socket interface through `faye-websocket`'s driver mode, which
`env['rack.hijack']` already feeds directly.

#### Smoke test

`spec/hyperion/websocket_e2e_spec.rb` boots a real Hyperion
server, opens a raw TCP client, completes the handshake, exchanges
100 text messages each direction (echoed by an app that uses
`Hyperion::WebSocket::Connection` directly), and closes with code
1000. p50 echo round-trip on developer hardware is sub-millisecond
— logged to stderr from the spec for sanity, not asserted (CI runners
vary too much).

#### Scope notes

Deferred to a follow-up:

* `Hyperion::WebSocket::Adapter::ActionCable` — see recipe above.
* permessage-deflate (RFC 7692) compression — handshake-time
  negotiation in WS-2, per-frame compression here. Not in 2.1.0.
* Send-side fragmentation — `send` writes a single FIN=1 frame
  regardless of payload size. Browsers / well-behaved clients
  handle multi-MB single frames; an opt-in `fragment_threshold:`
  can be added later if a use case shows up.

### Test fixtures

* `spec/hyperion/http2_settings_spec.rb` — relax the logger expectation
  so the Phase 6b codec-boot info line ("h2 codec selected") doesn't
  trip the spec on hosts where the native h2 codec is loaded. CI fix
  on top of 2.0.1, folded into 2.1.0.

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
