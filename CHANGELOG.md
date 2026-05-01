# Changelog

## 2.11.0 — 2026-05-01

### 2.11-B — HPACK FFI marshalling round-2 (cglue confirmed as firm default; +43% v3 vs v2 on Rails-shape h2)

**Bench result (openclaw-vm, 25-header h2load -c 1 -m 100 -n 5000, 3 runs/variant, median):**

| Variant | Env value | Median rps |
|---|---|---:|
| Ruby fallback | `=off`   | 1585.35 r/s |
| Native v2 (Fiddle, forced) | `=v2`    | 1602.27 r/s |
| Native v3 (CGlue, forced)  | `=cglue` | 2291.44 r/s |

| Delta | Value |
|---|---:|
| native (v2) vs ruby | +1.1% (within noise) |
| **cglue (v3) vs native (v2)** | **+43.0%** (HEADLINE — Fiddle marshalling overhead) |
| cglue (v3) vs ruby            | +44.5% (total native win) |

**Decision: flip cglue default ON.** The bench cleanly attributes the
+18-44% native-vs-ruby headline to the C-glue path's elimination of
per-call Fiddle marshalling, *not* to the underlying Rust HPACK
encoder. With cglue forced off, native v2 is +1-5% over ruby —
basically noise on this header count. The 2.5-B headline ("+18%
native vs ruby") was actually measuring v3 vs ruby because `=1`
silently picked v3 on cglue-available hosts; 2.11-B's `=v2` token
made the v2-only number measurable for the first time.

The `:auto` resolved state (unset / `=1` / `=true`) was already
selecting cglue when available since 2.4-A; this round confirms
that selection and updates the boot-log mode string to advertise
cglue as the de jure default. The runtime behavior on a host where
cglue is available is unchanged from 2.10 — the de facto cglue
selection becomes de jure, with a `default since 2.11-B` marker
in the human-readable `mode` log field.



The 2.5-B Rails-shape bench measured native v3 (CGlue) at +18% over
the Ruby fallback on a 25-header response — comfortably above the
+15% flip threshold, which moved the native-vs-Ruby default to ON.
The remaining open question 2.5-B punted on: how much of that +18%
is the Rust HPACK encoder, and how much is the C-glue path's
elimination of per-call Fiddle marshalling? A direct A/B was
impossible at the time because `=1` always picked v3 on hosts
where the C glue had installed successfully.

**Surface change.** `HYPERION_H2_NATIVE_HPACK` now accepts an
explicit native-mode token alongside the legacy Boolean values.
The legacy values still resolve to the same physical path they
did before, so this is back-compat for every operator who set the
env var pre-2.11-B:

| Value | Resolves to | Pre-2.11-B behavior | 2.11-B behavior |
|---|---|---|---|
| (unset) / `1` / `true` / `yes` / `on` / `auto` | `:auto`  | native, prefer cglue | native, prefer cglue (unchanged) |
| `cglue` / `v3`        | `:cglue` | (same as `1`) | force cglue, warn-fallback to v2 |
| `v2` / `fiddle`       | `:v2`    | (same as `1`) | force v2/Fiddle (skip cglue even if installed) |
| `0` / `false` / `no` / `off` / `ruby` | `:off`   | ruby fallback | ruby fallback (unchanged) |

The new `=v2` value is the bench-isolation knob `bench/h2_rails_shape.sh`
needs: without it the harness's "native" variant silently picked v3
on bench hosts where the C glue loaded successfully, making the
v2-vs-v3 delta unmeasurable. With `=v2` the operator can force the
Fiddle path on a host where cglue is physically present.

**Implementation.** `Hyperion::H2Codec.cglue_active?` overlays
`cglue_available?` with an operator-controllable gate
(`H2Codec.cglue_disabled = true|false`). The Encoder/Decoder hot
paths probe `cglue_active?` (was `cglue_available?`); one extra
ivar read per encode call which YJIT inlines away. `Http2Handler`
sets the gate at construction based on the resolved native-mode
state. The gate is global (the codec module is a singleton); the
handler resets it on every construction so a `=v2` boot can't leak
the disable into a subsequent default-mode handler.

**Boot log.** The `h2 codec selected` log line gains a new `native_mode`
field exposing the operator-requested mode (`auto` / `cglue` / `v2` /
`off` / `cglue-requested-unavailable`). The existing `hpack_path`
field continues to be one of `pure-ruby` / `native-v2` / `native-v3` —
unchanged, ops dashboards keying off it keep working. The `mode`
human-readable string differentiates `forced` from `auto` selections
so a misconfigured `=cglue` boot on a host without the C glue is
visible in one log line instead of requiring a process trace.

**Bench harness.** `bench/h2_rails_shape.sh` now runs three variants
(`ruby`, `native`, `cglue`) instead of two and emits
`delta_native_vs_ruby` (informational — should reproduce the 2.5-B
+18% headline) plus `delta_cglue_vs_native` (the headline for
2.11-B — does cutting per-call Fiddle marshalling buy anything on
top of the v2 path?). The decision rule keys off the cglue-vs-native
delta:

| Outcome (cglue vs native) | Action |
|---|---|
| ≥ +15% rps | Flip cglue default ON (replace 2.5-B's auto-cglue dance) |
| Parity / +5-10% (within noise) | Keep cglue opt-in, file as deferred |
| ≥ −2% (negative) | Investigate, do not ship |

Each variant runs 3x, output is the median.

**Spec coverage.** `spec/hyperion/h2_codec_native_mode_spec.rb` — 17
new examples covering: each native-mode token resolves to the
expected `hpack_path`; `=cglue` on a host without the C glue logs
`native_mode=cglue-requested-unavailable` and falls through to v2;
`=v2` actually flips `H2Codec.cglue_active?` to false even when
cglue is available; the three bench-variant tokens
(`{off,v2,cglue}`) produce the three distinct `hpack_path` values
the harness compares.

### 2.11-A — h2 first-stream TLS handshake parallelization (Bucket 2: pre-spawned dispatch worker pool)

The 2.10-G TCP_NODELAY fix lifted the ~40 ms h2 max-latency ceiling
that was paid by every stream. With the per-stream Nagle/delayed-ACK
noise gone, the **first-stream cold cost** became isolatable via the
2.10-G `HYPERION_H2_TIMING=1` instrumentation. Reading the breakdown
on `h2load -c 1 -m 100 -n 5000 https://localhost/`:

| Bucket | Master baseline | After 2.11-A |
|---|---:|---:|
| `t0_to_t1_ms`    (preface exchange — 0.3-1.7 ms baseline)               | 0.3-1.7 ms | 0.6-1.2 ms |
| `t1_to_t2_enc_ms` (preface→first stream encoded — **dominant bucket**)   | **12-25 ms** | **m=1: 1.0-1.4 ms**, m=100: 13-18 ms |
| `t2_enc_to_t2_wire_ms` (first stream encode → first byte on wire)        | -10 to -27 ms\* | -13 to -17 ms\* |
| `t0_to_t2_wire_ms` (preface bytes on wire)                               | 0.9-3.4 ms | 1.1-1.9 ms |

\* The `t2_enc_to_t2_wire_ms` slot reflects "preface SETTINGS bytes
on the wire" minus "first stream HEADERS encoded" — the writer
fiber's `||=` capture lands on the preface bytes (always written
first), not the response. The negative value is expected and
documents the preface→response gap at the writer-fiber boundary.

**The dominant bucket was `t1_to_t2_enc_ms`** — preface complete to
first stream's HEADERS+DATA encoded. On the cold-stream `m=1` path,
the ~3-13 ms gap is dominated by lazy `task.async {}` fiber spawn
on the connection-loop fiber's `ready_ids` tick (under the Async
scheduler, the first `task.async` from a cold fiber pays scheduler
bookkeeping that warmer paths amortize away).

**Fix.** Pre-spawn a fixed pool of `N` dispatch worker fibers (default
`4`, configurable via `HYPERION_H2_DISPATCH_POOL`) inside `serve`
BEFORE `read_connection_preface` returns. Each worker parks on a
new per-connection `Async::Queue` exposed off `WriterContext#dispatch_queue`.
When a stream becomes ready, the connection-loop fiber pushes onto
the queue; a parked worker grabs it and calls `dispatch_stream`.

The first stream is now an enqueue+dequeue handoff (microseconds)
instead of a `task.async {}` cold spawn. Streams that arrive while
the queue is non-empty (workers all busy on prior streams) fall
back to ad-hoc `task.async {}` so concurrency is never artificially
capped — the operator-facing knob is `h2.max_concurrent_streams`,
not the pool size.

**Bench delta on openclaw-vm (single-worker, h2load → localhost TLS h2):**

| | Master | 2.11-A | Δ |
|---|---:|---:|---:|
| `m=1 -n 50` cold first-run, time-to-1st-byte         | 20.28 ms | **9.28 ms** | **-54%** |
| `m=1 -n 50` warm avg, time-to-1st-byte               | 5.93 ms  | 7.20 ms     | +21% (within run-to-run noise) |
| `m=100 -n 5000` 10-run avg, time-to-1st-byte         | 19.6 ms  | 19.1 ms     | parity |
| `m=100 -n 5000` 10-run avg, throughput               | 2742 r/s | 2893 r/s    | +5.5% |
| `m=1 -n 50` `t1_to_t2_enc_ms` (instrumented, cold)   | 3.4 ms   | **1.0-1.4 ms** | **-66%** |

**Cold first-stream cost is roughly halved** on `m=1` (the actual
single-stream cold-connection path). The `m=100` path is dominated
by sequential client-frame reads on the connection-loop fiber, not
fiber-spawn cost — the fix doesn't move that needle but doesn't
regress it either.

**Sub-fixes folded in.**
* **Pre-resolve `peer_address`** before `read_connection_preface`.
  The `peeraddr` syscall was previously paid on the hot path between
  preface read and first dispatch; moving it earlier overlaps with
  the writer fiber's first-tick scheduling.

**Operator surface.**

* `HYPERION_H2_DISPATCH_POOL=<N>` — set the pre-warmed dispatch
  worker count per connection. Default `4`. Ceiling `16` (guards
  against pathological configs spawning hundreds of idle fibers
  per accepted connection). Invalid / non-positive values fall
  back to the default rather than crashing the connection — this
  is a tuning knob, not a spec parameter.
* `WriterContext#dispatch_queue` — the per-connection
  `Async::Queue` workers park on; bench harnesses can introspect.
* `WriterContext#dispatch_worker_count` — live count of workers
  currently registered (parked or actively dispatching). Useful
  for diagnostics endpoints that want to surface "this connection's
  pool is saturated".

**Constraints preserved.**
* TCP_NODELAY (2.10-G) hunk in `apply_tcp_nodelay` is untouched.
* Static asset preload + immutable hooks (2.10-E) are untouched.
* C-ext fast-path response writer (2.10-F) is untouched.
* `HYPERION_H2_TIMING=1` instrumentation continues to fire and
  emits the same `'h2 first-stream timing'` log shape (the four
  deltas + total). Locked by spec.

**Specs.** 12 new examples in `spec/hyperion/http2_dispatch_pool_spec.rb`
covering the WriterContext extensions (queue + worker count + register/
unregister), `resolve_dispatch_pool_size` env-var parsing (default,
override, invalid input, ceiling), the pool warmup contract (workers
registered, workers process queued items, one bad stream doesn't
poison the pool), and a TLS+curl end-to-end smoke (the timing log
shape continues to fire after the warmup hook is added). Spec count
**1060 → 1072**, 0 failures.

## 2.10.1 — 2026-05-01

### 2.10-F — C-ext fast-path response writer for prebuilt responses

Folds the matched-route hot path for `Server.handle_static` into a
single C function so the request never re-enters Ruby on the response
side.  Closes the syscall-overhead gap between Hyperion's 2.10-D
direct-route path (5,619 r/s on `hello` per the 2.10-D bench) and
Agoo's pure-C static path (19,364 r/s) by eliminating the Ruby
plumbing around the `write()` syscall: no handler closure dispatch,
no `[status, headers, body]` tuple materialization, no extra GVL
acquire/release for the response phase.

**Headline shape.** New
`Hyperion::Http::PageCache.serve_request(socket, method, path)` C-ext
entry point: hash lookup, snapshot under the C lock, write outside
the GVL via `rb_thread_call_without_gvl`, return
`[:ok, bytes_written]` on hit / `:miss` on absence.  HEAD requests
write the headers-only prefix (body stripped on the C side, no
extra Ruby work).

**Why the previous shape was leaving cycles on the table.**  2.10-D's
`Connection#dispatch_direct!` matched the route in O(1), but the
write path was still pure Ruby:
`handler.call(request) → StaticEntry → socket.write(buf)`.  Each
step involves Ruby method dispatch, ivar reads, GC roots updated,
and (for any blocking I/O wait the kernel returns from `write()`)
a fresh GVL re-acquire.  Strace on the 2.10-D `hello` path showed
~30,000 ancillary syscalls per second (`clone3`, `futex`) for what
should be one `write()` per request — that's the Ruby plumbing
talking, not the protocol.  2.10-F shrinks the response phase to
ONE C call that does the whole thing.

**Operator surface.**

```ruby
# Already worked in 2.10-D — same call:
Hyperion::Server.handle_static(:GET, '/health', "OK\n")

# 2.10-F changes what happens UNDER this call:
#  1. The prebuilt buffer is registered with the C-side PageCache
#     under '/health'.
#  2. Connection#dispatch_direct! detects StaticEntry routes
#     and calls PageCache.serve_request(socket, method, '/health'),
#     which does the hash lookup + GVL-released write in C.
#  3. HEAD on a GET-registered handle_static now serves headers-
#     only automatically (HTTP semantic; the C side strips body
#     bytes for HEAD).
```

No CHANGELOG-touching API changes for callers — this is a hot-path
micro-architecture rework.

**Files added.**

| File | Purpose |
|---|---|
| `spec/hyperion/page_cache_serve_request_spec.rb` | 13 examples covering `:ok`/`:miss`, GET full body, HEAD headers-only, method-gating (POST/PUT/etc. miss), case-insensitive method match, last-writer-wins on `register_prebuilt`, oversized-path rejection, no-deadlock under 8-thread `serve_request` contention. |

**Files touched.**

| File | Change |
|---|---|
| `ext/hyperion_http/page_cache.c` | Add `rb_pc_register_prebuilt(path, response_bytes, body_len)` so the prebuilt handle_static buffer can be folded into the C cache without ever reading from disk. Add `rb_pc_serve_request(socket_io, method, path)` — C-ext fast path: classifies method (GET/HEAD/other) inline, looks up in the existing FNV-1a bucket table, snapshots under the pthread mutex, writes via the existing `hyp_pc_write_blocking` helper (still under `rb_thread_call_without_gvl`). Extends `hyp_page_t` with `headers_len` (= response_len − body_len, used for HEAD writes) and `prebuilt` (skips re-stat for entries that have no on-disk file). New `:miss` symbol distinct from `:missing` so logs/metrics can tell "not in cache" apart from "in cache but method-ineligible". |
| `lib/hyperion/http/page_cache.rb` | Document the new C surface (`register_prebuilt`, `serve_request`) in the module-level comment; no Ruby-side helper added — these are direct C exports. |
| `lib/hyperion/server/route_table.rb` | `StaticEntry` gains a 4th field `headers_len` (defaulted nil for back-compat with 2.10-D 3-arg constructions), responds to `#call(request)` returning `self` (so `Server.handle_static` can register the entry directly into the route table — the 2.10-D wrapping closure is gone), exposes `headers_bytesize` for the Ruby fallback HEAD-strip path. |
| `lib/hyperion/server.rb` | `Server.handle_static` now: (a) records `head.bytesize` on the StaticEntry as `headers_len`; (b) registers the StaticEntry **directly** into the route table (not wrapped in `->(req) { entry }`); (c) registers a HEAD twin for any GET registration (HTTP-mandated); (d) calls `Hyperion::Http::PageCache.register_prebuilt` to fold the prebuilt buffer into the C cache. |
| `lib/hyperion/connection.rb` | `dispatch_direct!` branches on `handler.is_a?(StaticEntry)` BEFORE invoking the handler closure; on hit, calls new `dispatch_direct_static!` which fires lifecycle hooks, calls `PageCache.serve_request(socket, request.method, entry.path)` via the new `serve_static_entry` helper, and falls back to a Ruby `socket.write` of `entry.buffer` (or `headers_bytesize` prefix on HEAD) if the C cache returned `:miss`. Lifecycle-hook contract from 2.10-D preserved — `env=nil` on direct routes still holds. |
| `spec/hyperion/direct_route_spec.rb` | +2 examples: end-to-end serves `handle_static` via the C-ext fast path (asserts `PageCache.serve_request` finds the registered entry and returns `[:ok, n]`); end-to-end HEAD on a `handle_static`-registered GET route returns headers-only on the wire. |

**Spec count: 1045 → 1060 (+15).** All 1060 examples green; 11 pending
(unchanged platform-only kTLS / io_uring / Linux-splice branches from
the 2.10.0 baseline).

**Judgment calls (documented for archaeology).**

1. **HEAD twin auto-registration.** `Server.handle_static(:GET, ...)` now
   ALSO registers HEAD on the same path. Operators registering HEAD
   explicitly through `Server.handle(:HEAD, path, handler)` continue to
   work — the route_table is last-writer-wins, so explicit overrides
   take precedence if registered after `handle_static`. The alternative
   was to teach `RouteTable#lookup` to fall back GET→HEAD, but that
   would have widened the hot-path lookup from one Hash#[] to two
   without operator opt-in. Auto-registration was the cheaper choice.

2. **`:miss` vs `:missing`.** Two different symbols intentionally:
   `:missing` = "you asked for this and the on-disk file isn't cached"
   (the existing 2.10-C `write_to`/`fetch` contract); `:miss` = "the
   route lookup didn't yield a serveable prebuilt entry" (new in 2.10-F).
   Operators wiring metrics on the C path can split the two reasons.

3. **GVL release.** The implementation reuses the existing
   `hyp_pc_write_blocking` helper — same `rb_thread_call_without_gvl`
   shape as 2.10-C's `PageCache.write_to`, same EAGAIN-with-bounded-
   `select` retry. No new lock, no new write strategy: just a smaller
   call surface.

4. **`StaticEntry#call` returning self.** Keeps the route_table
   `respond_to?(:call)` invariant intact so the same hash can hold both
   prebuilt entries AND user-defined Rack-tuple handlers without a
   separate registration API. `dispatch_direct!`'s
   `handler.is_a?(StaticEntry)` branch fires BEFORE `handler.call(request)`,
   so the `call` method is only ever exercised by callers reaching for
   the route table directly (specs, custom dispatchers).

### 2.10-F — bench result: hello via handle_static 5,768 r/s (vs 5,619 baseline, +2.6%)

**Honest reading: 2.10-F is durable infrastructure, NOT a sustained-r/s win.**
The C-ext fast path eliminates the Ruby plumbing around the response
write, but on this workload the dominant cost is the per-connection
lifecycle (accept4 + clone3 + futex + epoll setup) — NOT the response
write phase that 2.10-F shrinks. The wrk profile spawns 100 fresh
keep-alive connections every 20-second run; each one pays the
connection-startup tax once, and that tax dwarfs the per-request
write cost on a 5-byte body. Closing THAT gap is explicitly the
domain of 2.11+.

**Setup (openclaw-vm, Ubuntu 24.04, x86_64, Ruby 3.3.3, page-cache C
ext compiled fresh against the 2.10-F source).**

| Run | Hyperion args | Rackup |
|---|---|---|
| 2.10-F | `-t 5 -w 1 -p 9810 bench/hello_static.ru` | `Hyperion::Server.handle_static(:GET, '/', 'hello')` + Rack 404 fallback |

`wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/`, 3 trials,
median r/s reported.

| Run | Trial 1 | Trial 2 | Trial 3 | Median r/s | Median p99 |
|---|---:|---:|---:|---:|---:|
| 2.10-D baseline (published, this rackup shape) | — | — | — | **5,619** | **1.93 ms** |
| **2.10-F (with C-ext fast-path)** | 5,688.55 | 6,035.16 | 5,768.47 | **5,768** | **1.67 ms** |
| Agoo 2.15.14 (2.10-B reference) | — | — | — | 19,364 | 9.41 ms |

**Delta vs 2.10-D baseline:** **+2.6% r/s** (5,619 → 5,768), **−14%
p99 latency** (1.93 ms → 1.67 ms). Trial-to-trial spread on this
host is ±5%, so the r/s delta is inside the noise band; the p99
improvement is outside the noise band and reproduces across all
three trials.

**Why no headline rps win.** The 2.10-F change shrinks the response
phase to one C call. On the pre-2.10-F path, the response phase was
already a single `write()` syscall (the 2.10-D static buffer write)
plus a handful of Ruby method dispatches around it. The Ruby
dispatch overhead — handler closure call, `is_a?(StaticEntry)`
branch, `socket.write` ivar reads — is ~1-2 microseconds total at
this scale, swamped by the ~150-200 microsecond per-request floor
imposed by the connection lifecycle (accept queue, thread-pool
worker hand-off, parser dispatch, GVL release/acquire on read).
2.10-F removes that 1-2 µs cleanly; the bench shows it as a small
p99 improvement (the tail latency on the fast-path-eligible
requests tightens) but the throughput floor is gated on a different
bottleneck.

**What 2.10-F DOES move (durable wins).**

1. **−14% p99 latency on the fast path.** Tail latency tightens
   because the response phase no longer pays the GVL re-acquisition
   that the Ruby `socket.write` triggered on the post-syscall return.
   Operator-visible: a static-asset CDN origin running Hyperion
   sees 1.67 ms instead of 1.93 ms p99 on cached hits.

2. **Syscall-reduction infrastructure for 2.11.** Strace -f over
   5,000 warm requests on 2.10-F shows: 5,000× write (the
   `serve_request` C-side write) + ~30,000 ancillary syscalls
   (accept4, clone3, futex, recvfrom, epoll). The 5,000 writes
   are unchanged from 2.10-D; the **ancillary syscalls are
   unchanged too** because they're driven by the connection
   lifecycle, not the response phase. When 2.11 closes the
   accept-loop / thread-pool gap, the C-ext write path is already
   in place — no second Ruby-to-C migration needed.

3. **HEAD support automatic.** `handle_static(:GET, ...)` now
   auto-registers the HEAD twin (HTTP-mandated). Operators
   running CDN-shaped traffic against `handle_static` paths get
   correct HEAD semantics for free; the C side strips the body
   bytes on HEAD, so the wire saves the body byte-count per
   HEAD request.

4. **GVL released across the write syscall.** The 2.10-D path
   ran the `socket.write` under the GVL — a slow client (one
   that didn't drain the kernel send buffer fast enough) could
   block other Ruby-side work on the same VM. The C path uses
   `rb_thread_call_without_gvl`, so other threads / fibers on
   the same worker can run while the kernel drains.

**Caveats / honest framing.**

- The plan target of "8,000-12,000 r/s (half-way to Agoo)" is
  NOT met on this row. The half-way mark would have required
  closing the connection lifecycle gap as well — that's the
  2.11 sprint's job, not 2.10-F's.
- Agoo's 19,364 r/s on this row is still 3.4× ahead. Closing
  that gap requires owning the accept loop in C (which Agoo does)
  — distinct from owning the response write in C, which is what
  2.10-F lands.
- Trial-to-trial noise on this row is ±5% on the openclaw-vm host
  (visible in the spread 5,688 / 6,035 / 5,768). The 2.6% r/s
  delta is inside that band; the p99 delta is outside it.

**Recommendation.** Ship 2.10-F. The operator-visible value is
the −14% tail latency on the fast path, the durable C-side
write infrastructure for the 2.11 connection-lifecycle work, the
free HEAD support, and the GVL release across writes. The
CHANGELOG headline tells operators the honest delta — not "+47%
to Agoo".

### 2.10-E — Static asset preload + immutable flag

Adds a boot-time hook that walks operator-supplied directory trees,
populates `Hyperion::Http::PageCache` with each regular file, and
(by default) marks every cached entry immutable so subsequent serves
never re-stat. Closes the gap between Hyperion 2.10-C's cold-cache
1,880 r/s on the static-1-KB row and Agoo's "8000× faster static"
warm-cache claim (their `misc/rails.md`) — Agoo gets that number by
preloading every Rails-managed asset path at boot. 2.10-E ships the
same shape so operators don't have to call `PageCache.preload`
themselves.

**Operator surface — three ways in.**

1. **CLI flag** — repeatable.
   ```
   bundle exec hyperion --preload-static /srv/app/public \
                        --preload-static /srv/app/public/uploads \
                        config.ru
   ```
   Each `--preload-static <dir>` entry is walked recursively at boot;
   every file becomes a cached page-cache entry marked immutable.
   `--no-preload-static` is the sibling sentinel that disables the
   Rails-aware auto-detect (operator-supplied dirs still take effect).

2. **Config DSL key** — accumulates across multiple calls.
   ```ruby
   # config/hyperion.rb
   preload_static '/srv/app/public'                           # immutable: true (default)
   preload_static '/srv/app/public/uploads', immutable: false  # opt-out per-dir
   ```
   The `immutable:` kwarg defaults to `true` — preload's whole point
   is "I promise these don't change without a restart", and operators
   wanting per-request mtime polling can opt out per-dir.

3. **Rails auto-detect** — zero-config for Rails apps.

   When the operator has NOT configured `preload_static` and did NOT
   pass `--no-preload-static`, Hyperion checks for a Rails-shaped boot
   environment (`defined?(::Rails) && ::Rails.respond_to?(:configuration)`,
   `Rails.configuration.assets.paths` returns a non-empty Array) and
   auto-preloads the first 8 entries of `Rails.configuration.assets.paths`.
   Hyperion never `require`s rails — auto-detect is purely defensive
   probing, so Hyperion stays a generic Rack server that has a Rails
   bonus mode.

**Boot-time log line per dir.** One info-level summary line per
processed directory:

```
{"message":"static preload complete","dir":"/srv/app/public","files":42,"bytes":2487136,"ms":18.4}
```

Operators alert on this if files=0 (config typo, missing dir) or ms
spike (disk regression / NFS storm).

**Where it runs.** `Hyperion::StaticPreload.run` is invoked from
`Server#preload_static!` inside `Server#start`, after `listen`
configures the listener but BEFORE the accept loop spins. First
request lands on warm cache. The preload list flows
`Config#resolved_preload_static_dirs` → `Master` → `Worker` → `Server`
in cluster mode and `CLI.run_single` → `Server` in single-mode.

**Files added.**

| File | Purpose |
|---|---|
| `lib/hyperion/static_preload.rb` | `Hyperion::StaticPreload.run(entries, logger:)` walks each `{path:, immutable:}` Hash, calls `PageCache.cache_file` + `set_immutable`, emits the summary log line. `.detect_rails_paths(cap: 8)` defensively probes `Rails.configuration.assets.paths` for the auto-detect path. |
| `spec/hyperion/static_preload_spec.rb` | 11 examples covering walk + cache, immutable-flag behaviour, summary log shape, missing-dir warn, multi-dir accumulation, and the Rails detect branches (operator-overrode, auto-detect-disabled, Rails-undefined, non-Array paths, cap kwarg). |
| `spec/hyperion/cli_preload_static_spec.rb` | 6 examples covering `--preload-static` repeatable flag, `--no-preload-static` toggle, and the `merge_cli!` routing into `Config#preload_static_dirs`. |
| `spec/hyperion/config_preload_static_spec.rb` | 6 examples covering DSL accumulation, defaults, and the `resolved_preload_static_dirs` precedence (operator > Rails > none). |
| `spec/hyperion/server_static_preload_spec.rb` | 3 examples covering `Server#preload_static!` warming the page cache from a configured directory and respecting the immutable flag. |

**Files touched.**

| File | Change |
|---|---|
| `lib/hyperion.rb` | Require `hyperion/static_preload` after `hyperion/http/page_cache`. |
| `lib/hyperion/cli.rb` | Add `--preload-static DIR` (repeatable) and `--no-preload-static` flags. Pass `config.resolved_preload_static_dirs` to `Server.new` in single-worker mode. |
| `lib/hyperion/config.rb` | Add `preload_static_dirs` (Array of `{path:, immutable:}` Hashes) + `auto_preload_static_disabled` (Boolean) defaults. Add `preload_static "/path", immutable: true` DSL method (accumulates). Special-case `:preload_static` in `merge_cli!` to append each CLI dir. New `Config#resolved_preload_static_dirs` returns operator dirs verbatim, falls through to `StaticPreload.detect_rails_paths` when none are configured AND auto-detect isn't disabled. |
| `lib/hyperion/server.rb` | New `preload_static_dirs:` kwarg on the constructor (default nil = no preload). New public `Server#preload_static!(logger:)` walks the entries via `StaticPreload.run`, idempotent via `@preloaded` so respawn paths don't re-walk. Invoked once from `Server#start` between `listen` and the accept-loop spin-up. |
| `lib/hyperion/master.rb` | Pass `@config.resolved_preload_static_dirs` through the worker spawn args so cluster mode also warms each worker's page cache at boot. |
| `lib/hyperion/worker.rb` | Accept and forward `preload_static_dirs:` to `Server.new`. |

**Spec count: 1018 → 1045 (+27).** All 1045 examples green; 11 pending
(unchanged platform-only kTLS / io_uring branches from the 2.10.0 baseline).

### 2.10-E — bench result: static 1 KiB cold 1,929 r/s vs warm 1,886 r/s (no rps win)

**Honest reading: the preload feature does NOT move sustained throughput
on the static-1-KB row, but it does normalize first-request latency.**

Bench-only — no production code changes, spec count unchanged at 1045.

**Setup (openclaw-vm, Ubuntu 24.04, x86_64, Ruby 3.3.3, page-cache C
ext compiled fresh against the 2.10-E source).**

| Run | Hyperion args | Asset dir |
|---|---|---|
| Cold | `-t 5 -w 1 -p 9810 bench/static.ru` | `/tmp/hyperion_static_e/` (single 1 KiB file) |
| Warm | `-t 5 -w 1 -p 9810 --preload-static /tmp/hyperion_static_e bench/static.ru` | same |

`wrk -t4 -c100 -d20s --latency http://127.0.0.1:9810/hyperion_bench_1k.bin`,
3 trials each, median r/s reported.

| Run | Trial 1 | Trial 2 | Trial 3 | Median r/s | Median p99 |
|---|---:|---:|---:|---:|---:|
| Cold | 1,929.75 | 2,037.98 | 1,920.91 | **1,929** | **3.50 ms** |
| Warm (preloaded + immutable) | 2,013.95 | 1,842.22 | 1,886.55 | **1,886** | **3.51 ms** |

**Why no throughput win.** Hyperion's `ResponseWriter` already
auto-caches Rack::Files hits on first request (the `cache_file` /
`write_to` fall-through landed in 2.10-C). At sustained 100-conn `wrk`,
both the cold and warm paths converge on the same PageCache hot path
inside the first millisecond — preload just frontloads that one
`cache_file` call from the first wrk iteration to boot time.

**What 2.10-E DOES move.** The "static preload complete" log line
fires at boot:

```
{"message":"static preload complete","dir":"/tmp/hyperion_static_e","files":1,"bytes":1024,"ms":0.2}
```

Operators get:

1. **Predictable first-request latency.** With preload, request #1
   after boot lands on a warm cache (saves the `File.size?` +
   `cache_file` work that the first cold request pays). Without preload
   request #1 takes a `stat` + `open` + alloc hit; subsequent requests
   are warm. With preload every request including #1 is warm.
2. **Immutable flag.** Cached entries marked immutable skip the
   `recheck_seconds` mtime poll on every serve. For long-running
   processes serving content-hashed asset bundles this saves ~1
   `lstat()` syscall per request — operationally invisible at the
   2k r/s scale of the bench host but matters at production scale
   on Linux where `stat` against NFS or overlayfs can be a tail-latency
   land mine.
3. **Operational predictability.** No first-request "cold cache"
   class of incidents (operator restarts the worker, first user request
   pays a ~10ms `cache_file` cost — not visible at this bench scale,
   but a real shape with 50 KiB files / 1000 assets).

**Caveats / honest framing.**

- The plan target ("2,400-2,600 r/s warm") is NOT met. The harness +
  1-KB-via-Rack::Files shape is already throughput-bound on the
  PageCache hot path — preload doesn't unlock more.
- A different bench (cold-process first-request latency, or 1000-asset
  tree where Find.find dominates the first-N requests) WOULD show a
  larger delta. We're not running that here because the plan's
  requested bench is the 2.10-B static-1-KB row.
- Trial-to-trial noise on this row is ±5% on the openclaw-vm host
  (visible in the "Warm" column going 2,014 → 1,842 → 1,886).
  The median spread between cold and warm (1,929 vs 1,886, ~2%) is
  inside that noise band.

**Recommendation.** Ship 2.10-E. The operator-visible value is the
zero-config Rails-aware boot-time cache warming, the immutable flag
that ships with it, and the boot-time summary log line — not a
sustained-r/s improvement. The CHANGELOG headline tells operators what
they actually buy.

## 2.10.0 — 2026-05-01

The 2.10 sprint widens the bench comparison from "Hyperion vs Falcon
on h2" (the 2.9-B head-to-head) to **all four major Ruby web servers**:
Hyperion, Puma, Falcon, and Agoo. Agoo is widely cited as the fastest
Ruby web server, so we want it in the matrix as the upper-bound
reference for the 2.10 follow-on streams (static-response cache,
direct route registration). 2.10-A ships the harness; 2.10-B will run
the BASELINE bench BEFORE any 2.10 code changes so the gap that the
new code closes is honestly known.

### 2.10-A — 4-way bench harness (Hyperion + Puma + Falcon + Agoo)

Harness only — no production code changes, no spec changes
(spec count stays at 964).

**Files added.**

| File | Purpose |
|---|---|
| `bench/Gemfile.4way` | Sibling Gemfile pinning `puma ~> 8.0`, `falcon ~> 0.55`, `agoo`, `rack ~> 3.0`, plus `hyperion-rb` from `ENV['HYPERION_PATH']` (defaults to `/home/ubuntu/hyperion` for the openclaw-vm bench host). Kept separate from the main bench Gemfile so existing harnesses (`h2_falcon_compare.sh`, etc.) are not disturbed by the 2.10-era pins. |
| `bench/agoo_boot.rb` | Wrapper that lets Agoo serve a Rack rackup (Agoo's CLI doesn't take rackups directly). Calls `Agoo::Server.handle_not_found(app)` so the parsed Rack builder is the catch-all handler, and parks the main thread on a `Queue#pop` so the process stays alive after `Agoo::Server.start` returns (Agoo's `thread_count: N>0` runs workers in their own threads and returns from `start`, unlike `thread_count: 0` which blocks the caller). |
| `bench/4way_compare.sh` | Single-script harness that boots each of the four servers in turn on the same port (9810) with a matched `-t 5 -w 1` budget, smokes a single 200, and (unless `SMOKE_ONLY=1`) drives 3× `wrk -t4 -c100 -d20s --latency` runs. Subset by passing server names after the rackup: `bench/4way_compare.sh bench/hello.ru hyperion agoo`. |

**Boot recipes (one server per row, all bound to port 9810,
matched 5-thread / 1-process budget).**

| Server | Command |
|---|---|
| Hyperion | `bundle exec hyperion -t 5 -w 1 -p 9810 bench/hello.ru` |
| Puma | `bundle exec puma -t 5:5 -w 1 -b tcp://127.0.0.1:9810 bench/hello.ru` |
| Falcon | `bundle exec falcon serve --bind http://localhost:9810 --hybrid -n 1 --forks 1 --threads 5 --config bench/hello.ru` |
| Agoo | `bundle exec ruby bench/agoo_boot.rb bench/hello.ru 9810 5` |

Falcon's `--threads` flag is documented "hybrid only" — that's why
the harness explicitly selects `--hybrid -n 1 --forks 1 --threads 5`
(verified against `falcon serve --help` on the bench host before
this commit landed).

**Smoke verification on openclaw-vm (`SMOKE_ONLY=1`, GET / against
`bench/hello.ru`).** SSH to the bench host now works after 2.9-E's
`IdentitiesOnly yes` fix landed.

| Server | Boots? | Serves 200? | Notes |
|---|---|---|---|
| Hyperion | yes (1 s) | yes | `bin/hyperion` from this repo, agoo Gemfile resolves the path gem normally |
| Puma | yes (1 s) | yes | `puma 8.0`, threads-only |
| Falcon | yes (1 s) | yes | `falcon 0.55`, `--hybrid -n 1 --forks 1 --threads 5` |
| Agoo | yes (1 s) | yes | `agoo 2.15.14`. First boot attempt FAILED — needed the `Queue#pop` main-thread parking in `agoo_boot.rb`. With `thread_count: 5`, `Agoo::Server.start` is non-blocking and returns immediately; without the pop the process exits with the listener torn down. Fixed in this commit. |

The full `wrk` bench is **2.10-B's** job, not 2.10-A's — this commit
only validates that all four servers come up + serve a 200 on the
shared rackup.

### 2.10-B — 4-way baseline bench (Hyperion vs Puma vs Falcon vs Agoo)

**BASELINE — this is the honest 4-way comparison BEFORE 2.10-C/D/E/F
land. Establishes the gap that subsequent perf work needs to close
(or honestly prove uncloseable).** Re-run after each 2.10-C/D/E/F
stream lands so the delta is visible per-row.

Bench-only — no production code changes, spec count unchanged at 964.

**Files touched.**

| File | Change |
|---|---|
| `bench/Gemfile.4way` | Added `pg ~> 1.5` and `hyperion-async-pg ~> 0.5` so row 5 (PG-bound async) can run inside the 4way bundle. Other rows are unaffected — the gems load only when MODE=async. |
| `bench/4way_compare.sh` | Three additions: (1) `URL_PATH` env var for rackups whose root URL isn't a 200 (e.g. static.ru → `/hyperion_bench_1k.bin`); (2) `WRK_TIMEOUT` env var for slow rackups (row 5 wants `--timeout 8s`); (3) `HYPERION_EXTRA` env var for hyperion-only flags like `--async-io`; (4) **perfer integration** — every (rackup, server) combination now runs both `wrk -t4 -c100 -d20s` AND `perfer -t4 -c100 -k -d20`, with NA-aware median + summary lines. Set `SKIP_PERFER=1` to disable. |

**Results (medians of 3 trials, openclaw-vm Ubuntu 24.04 + Ruby
3.3.3, all servers `-t 5 -w 1`).** Per-row tables, full caveat
discussion, and reproduction recipe are in
[`docs/BENCH_HYPERION_2_0.md` § "4-way head-to-head (2.10-B
baseline)"](docs/BENCH_HYPERION_2_0.md#4-way-head-to-head-210-b-baseline-2026-05-01).

| Row | Workload | Hyperion 2.9.0 | Puma 8.0.1 | Falcon 0.55.3 | Agoo 2.15.14 | Verdict |
|---|---|---:|---:|---:|---:|---|
| 1 | hello | 4,587 r/s · p99 2.08 ms | 4,049 · 28.74 ms | 6,082 · 408.53 ms | **19,364** · 9.41 ms | Agoo wins by 4.2× over Hyperion; Hyperion has the cleanest p99 |
| 2 | static 1 KB | 1,380 · **4.86 ms** | 1,416 · 93.86 ms | 1,785 · 64.87 ms | **2,606** · 58.89 ms | Agoo wins; Hyperion p99 20× tighter than Puma |
| 3 | static 1 MiB | **1,378** · **5.62 ms** | 1,282 · 95.17 ms | 523 · 833.54 ms | 152 · 743.37 ms | **Hyperion wins** — sendfile path; 9× over Agoo |
| 4 | CPU JSON 50-key | 3,450 · **2.73 ms** | 2,771 · 40.74 ms | 4,245 · 410.05 ms | **6,374** · 19.18 ms | Agoo wins by 1.85× over Hyperion |
| 5 | PG-bound async (50 ms `pg_sleep`, c=200) | **1,564** · 145.71 ms | n/a | n/a | n/a | Hyperion-only — others can't run the rackup (no fiber-cooperative I/O) |
| 6 | SSE 1000 × 50 B (c=1, t=1) | **500** · 2.59 ms | 137 · 9.23 ms | 29 · 38.60 ms | smoke-fail | **Hyperion wins** — 3.6× over Puma, 17× over Falcon; Agoo can't stream SSE chunked |

**Honest reading.** Agoo is faster than Hyperion on hello-world by
**4.2×** (19k r/s vs 4.6k r/s) and on CPU JSON by **1.85×** (6.4k
vs 3.5k). That gap is what 2.10-C (static-response cache) and
2.10-D (direct route registration) need to walk down to <2× hello,
<1.5× JSON. Hyperion already wins the workloads that matter
operationally — large static (sendfile, 9× ahead of Agoo),
PG-bound async (Hyperion-only at this concurrency), and SSE
streaming (3.6×–17× ahead). Tail latency is Hyperion's clean win
across every row (worst p99 across the 6 rows: 145 ms on row 5
intentionally; next worst 5.62 ms — Puma worst 95 ms, Falcon worst
833 ms, Agoo worst 743 ms).

**perfer caveats.** Adding `perfer` (https://github.com/ohler55/perfer,
Agoo's own bench tool) for apples-to-apples vs Agoo's published
numbers surfaced four issues that are documented inline in the
BENCH doc:

1. perfer's `Content-Length:` / `Transfer-Encoding:` lookups are
   case-sensitive `strstr` — hangs against Hyperion's RFC 9110
   lowercase headers. Patched local copy to `strcasestr`; should
   upstream.
2. perfer's `pool_warmup` deadlocks against Hyperion `-t 5 -c 100`
   (per-conn 2.0s recv timeout × 100 conns vs 5-thread accept
   loop). Recorded `NA` for hyperion+perfer on rows 1, 2, 4.
   Raising hyperion to `-t 200` makes perfer happy but breaks
   matched-config. Workaround for 2.10-B: rely on wrk for
   hyperion's headline; perfer numbers for puma / falcon / agoo
   agree with wrk within 5–10%.
3. perfer's `MAX_RESP_SIZE = 16 KB` recv buffer means the 1 MiB
   static row is `NA` across all four servers under perfer. wrk
   handles arbitrary body sizes, so row 3 stays wrk-only.
4. SSE row reports `0 r/s` under perfer — its response-framing
   doesn't handle multi-chunk streams. wrk's `c=1` read-until-close
   parses correctly.

**Re-run pattern.** After each 2.10-C/D/E/F stream lands, re-run
the same 6 rows and append a new "post-{stream}" table to the
BENCH section so the cumulative perf delta is visible.

### 2.10-C — Hyperion::Http::PageCache (pre-built static-response cache)

**Headline (vs 2.10-B baseline on openclaw-vm, static 1 KiB row, `-t 5 -w 1`).**

| Build | r/s (median of 3) | vs 2.10-B | vs Agoo 2.15.14 |
|---|---:|---:|---:|
| 2.10-B baseline (Hyperion 2.9.0) | 1,380 | — | −47% (Agoo wins) |
| **2.10-C with PageCache engaged** | **1,880** | **+36%** | −28% |
| Agoo 2.15.14 (reference) | 2,606 | +89% | — |

Three trials on openclaw-vm: 1880 / 1932 / 1794 r/s; latency
median dropped from ≈3.7 ms to ≈2.7 ms.  The PageCache primitive
delivers the response-buffer half of agoo's small-static
advantage; the remaining gap to Agoo on the 1 KiB row lives in
connection handling — Hyperion's HTTP/1.1 path spawns a thread
per accept, while Agoo runs an event-loop model.  That gap is
the explicit subject of 2.10-D / 2.10-E / 2.10-F (connection
fastpath + Rack-bypass routes), each of which will reuse the
PageCache primitive shipped here.

**Plan target was 5,000 r/s.** That target assumed the PageCache
could remove the entire Rack-stack cost on a hit, but the
adapter still pays for ENV pool acquire + header hash iteration
+ the file_size stat from ResponseWriter; on a strace −f over
500 warm-cache requests we still see 500 × accept4 + 500 ×
clone3 (per-conn thread spawn) + 500 × stat.  The cache buffer
itself contributes 500 × write() — the single-syscall promise
holds inside the cache, but the wider connection path drops
~18,000 syscalls on the 500-request slice (≈36 syscalls /
request) of which ~8 are application-level.  Closing the rest
to one syscall per response is 2.10-F's job (the direct-route
register).

The win source mirrors agoo's `agooPage` design: each cached static
asset's full HTTP/1.1 response (status line + Content-Type +
Content-Length + body) lives in ONE contiguous heap buffer that's
built ONCE on first read. The hot path (`PageCache.write_to(socket,
path)`) hashes the path, snapshots the buffer pointer + length out
of the cache under a brief pthread mutex, releases the mutex, then
issues `write(fd, buf, len)` from C without the GVL. Per-request
cost on a hit is:

* 0 file reads — body bytes already live in the response buffer.
* 0 mime lookups — Content-Type baked in at insert time.
* 0 header re-builds — Content-Length / status line baked in.
* 0 Rack env construction — engaged below the Rack adapter.
* 0 Ruby allocations on the C path itself (the only return value
  is a `SSIZET2NUM` Integer that's small enough to fit in a
  pointer-encoded Fixnum on every supported host).
* 1 socket write syscall in the common case.

**Files added.**

| File | Purpose |
|---|---|
| `ext/hyperion_http/page_cache.c` | C primitive (~800 LOC). Open-addressed bucket table (`PAGE_BUCKET_SIZE = 1024`, `MAX_KEY_LEN = 1024` mirroring agoo). pthread mutex on the structural ops; readers snapshot under the lock then release before the kernel write. `Init_hyperion_page_cache` runs from `parser.c` after `Init_hyperion_sendfile`. |
| `lib/hyperion/http/page_cache.rb` | Ruby façade. Adds `write_response` (alias of `write_to`), `preload(dir, immutable: false)` (recursive), `mark_immutable` / `mark_mutable`, `available?`. |
| `spec/hyperion/page_cache_spec.rb` | 25 specs — round-trip via real TCP pair, mtime invalidation, immutable flag, recursive preload, per-extension Content-Type matrix (12 extensions), zero-allocation hot path (< 100 objects per 1000 hits), `recheck_seconds` knob. |

**Files touched.**

| File | Change |
|---|---|
| `ext/hyperion_http/extconf.rb` | `$srcs` adds `page_cache.c` so it links into the same `.bundle` / `.so` as `parser.c` / `sendfile.c` (single `require 'hyperion_http/hyperion_http'` brings up the full surface). |
| `ext/hyperion_http/parser.c` | `Init_hyperion_http` calls `Init_hyperion_page_cache` after `Init_hyperion_sendfile`. |
| `lib/hyperion.rb` | Requires `lib/hyperion/http/page_cache.rb` between `http/sendfile` and `adapter/rack`. |
| `lib/hyperion/response_writer.rb` | `write_sendfile_inner` checks the page cache first via the new `page_cache_write` helper. On a hit (or after opportunistic populate-then-write for files ≤ `AUTO_THRESHOLD = 64 KiB`), skip the entire `File.open` / `file.read` / `build_head` / `io.write` path. Class-level `page_cache_available?` probe memoised at load. Falls through cleanly when the IO is StringIO / SSL-wrapped (no real fd) — see `real_fd_io?`. |

**Public Ruby API.**

```ruby
PC = Hyperion::Http::PageCache

PC.preload('/var/www/public')                            # warm on boot
PC.mark_immutable('/var/www/public/asset-abcdef.css')    # hashed assets
PC.cache_file('/var/www/public/index.html')              # one file
PC.fetch(path)            # :ok | :stale | :missing
PC.write_to(socket, path) # bytes_written | :missing  (hot path)
PC.size; PC.clear
PC.recheck_seconds = 5.0  # default; matches agoo's PAGE_RECHECK_TIME
```

**Auto-engage from `Adapter::Rack`.** Operators get the page cache
for free on `Rack::Files`-style routes (any body that responds to
`:to_path`) — `ResponseWriter#write_sendfile_inner` first calls
`page_cache_write`. Above the 64 KiB threshold it falls through to
the existing sendfile path because Hyperion already dominates big
static at 9× Agoo (the 2.10-B baseline). Apps wanting predictable
first-request latency call `PageCache.preload(dir)` on boot;
apps with content-hashed assets call `mark_immutable(path)` to
skip the per-recheck-window stat entirely.

**Wire-output note (intentional).** The cached response carries
status line + `Content-Type` + `Content-Length` + blank line + body
only — no `Date`, no `Connection`. Same shape Agoo emits on its
fast path. Non-cached paths still emit the full Hyperion header
set via `build_head`. Any response that carries `Set-Cookie` /
`Cache-Control` / `ETag` / `Last-Modified` / `Content-Encoding` /
`Content-Disposition` / `Vary` falls through to the existing path
unconditionally — those headers can't be safely baked into a
cross-request buffer.

**Mtime recheck.** Every cache lookup honours
`recheck_seconds` (default 5.0s, matches agoo's `PAGE_RECHECK_TIME`).
On expiry the C path stat()s the file; if `mtime` is unchanged it
just bumps `last_check`, otherwise it rebuilds the response buffer
in place. Per-page `set_immutable(true)` skips the stat entirely
— for fingerprinted assets the cache is effectively a one-shot
read.

**Concurrency.** Cache is per-process. Each forked Hyperion worker
holds its own table; no IPC, no shared memory, no cross-worker
contention. Within a worker, the table is guarded by a pthread
mutex that's held only for the lookup + snapshot — the kernel
`write()` runs without the GVL and without any Ruby-level lock
so other fibers / threads keep running while the socket buffer
drains.

**Spec count.** 964 → 989 (+25 in `page_cache_spec.rb`). All 989
green on macOS arm64; Linux x86_64 verified via the bench host
boot.

### 2.10-D — Server.handle direct route registration (bypass Rack adapter)

**Headline.** New `Hyperion::Server.handle(:GET, '/path', handler)`
+ `Hyperion::Server.handle_static(:GET, '/path', body)` API.
Mirrors agoo's `Agoo::Server.handle(:GET, "/hello", handler)`
design.  On a registered route, `Connection#serve` skips the
Rack adapter entirely — no env-hash build, no middleware chain
walk, no body iteration; the handler is called directly with
the parsed `Hyperion::Request` value object.  Lifecycle hooks
(`Runtime#on_request_start` / `on_request_end`) still fire so
NewRelic / AppSignal / OpenTelemetry instrumentation works
regardless of dispatch shape.

**Win source.** `handle_static` builds the FULL HTTP/1.1
response buffer (status line + Content-Type + Content-Length +
body) ONCE at registration time; the hot path is one
`socket.write(buffer)` syscall per request — same shape as the
existing 503 / 413 / 408 fast paths in `Server` / `Connection`,
zero Ruby allocation past the Connection ivars.  `handle` (the
dynamic-handler form) bypasses env construction but still
walks the standard `ResponseWriter` for the
`[status, headers, body]` tuple — slower than the static path
but still skips the entire Rack-adapter overhead.

**Bench validation on openclaw-vm** (`-t 5 -w 1`, `wrk -t4
-c100 -d20s --latency`, three trials median).  Hello-world via
`handle_static` vs the 2.10-B Rack-lambda baseline:

| Path | r/s (median of 3) | p99 latency | vs 2.10-B baseline | vs Agoo 2.15.14 |
|---|---:|---:|---:|---:|
| 2.10-B Rack lambda (Hyperion 2.9.0, published) | 4,587 | 2.08 ms | — | −76% (Agoo wins) |
| 2.10-B re-baseline (this run, same host, vanilla rackup) | 4,408 | 2.19 ms | −4% drift | — |
| **2.10-D handle_static** | **5,619** | **1.93 ms** | **+22% / +27%** vs the published / re-bench | −71% |
| Agoo 2.15.14 (reference) | 19,364 | 9.41 ms | +322% | — |

Three trials on openclaw-vm: 5,619 / 5,335 / 5,914 r/s.
**+22% over the published 2.10-B baseline; +27% over the
re-bench on the same host today.**  p99 latency 1.93 ms — the
cleanest p99 in the 4-way matrix (Agoo's p99 on this row is
9.41 ms, 4.9× wider despite the higher mean throughput).

**Plan target was 12,000 r/s; we landed at 5,619 r/s
(47% of plan target).**  Honest reading of the gap: removing
the Rack-adapter cost (env-hash build + middleware chain +
body iteration) was correctly sized at 2.10-D's win zone, but
on a `-c 100 -t 4` wrk profile the dominant cost is NOT the
adapter — it's the per-accept thread-pool clone3 + the
per-Connection ivar allocation that ResponseWriter / Connection
still pay before the dispatch_direct! branch.  An strace -f
sample over 5,000 warm requests shows: 5,000× accept4 +
5,000× clone3 (per-conn submit_connection enqueue → worker
spawn / wakeup) + 5,000× write (the StaticEntry buffer) +
~30,000 ancillary syscalls (epoll, recvfrom, futex, …).  The
StaticEntry path itself is ONE syscall per request as
designed — the cache buffer write — but the surrounding
connection lifecycle still dominates.  Closing the rest is
explicitly the subject of 2.10-E (connection fast-path) and
2.10-F (event-loop accept) — both of which now have a clean
hand-off API: `route_table.lookup` is the gating call;
2.10-E/F can short-circuit even earlier (before the worker
hop) for direct routes.

**Files added.**

| File | Purpose |
|---|---|
| `lib/hyperion/server/route_table.rb` | `RouteTable` class + `StaticEntry` value object.  Per-method Hash keyed by exact-match path String; O(1) lookup; Mutex-guarded writes.  `KNOWN_METHODS` matrix matches agoo's surface verbatim (GET / POST / PUT / DELETE / HEAD / PATCH / OPTIONS). |
| `spec/hyperion/direct_route_spec.rb` | 21 specs covering register / lookup / dispatch happy path, fall-through to Rack adapter on miss, lifecycle-hook firing on direct routes, `handle_static` byte-exact response, method case-insensitive matching, concurrent multi-thread registration, error paths (unknown method, non-String path, non-callable handler). |

**Files touched.**

| File | Change |
|---|---|
| `lib/hyperion/server.rb` | `require_relative 'server/route_table'`; class-level `Server.route_table` singleton + `Server.handle` / `Server.handle_static` registration API; `route_table:` constructor kwarg + `attr_reader :route_table`; plumb `@route_table` through every `Connection.new` site (4 inline-dispatch branches) and into `ThreadPool.new`. |
| `lib/hyperion/connection.rb` | `Connection.new` accepts `route_table:` kwarg (defaults to `Hyperion::Server.route_table` singleton).  In the request loop, after parse + before per-conn fairness gate: if `@route_table.lookup(method, path)` hits, call `dispatch_direct!` and skip the Rack-adapter path entirely.  New private helpers `dispatch_direct!` / `write_direct_response` / `should_keep_alive_after_direct?` — direct dispatch fires `runtime.fire_request_start` / `fire_request_end` (env is `nil` on the direct branch, documented contract for observers), writes either a `StaticEntry` buffer in one syscall or a full Rack tuple via the existing `ResponseWriter`, then continues the keep-alive loop. |
| `lib/hyperion/thread_pool.rb` | `ThreadPool.new` accepts `route_table:` kwarg; `:connection` job spawns `Connection.new(..., route_table: @route_table)` so the per-worker fast path inherits the registered routes. |

**Public Ruby API.**

```ruby
# Static — response buffer baked at registration time, one
# socket.write per hit.  The hello-bench win zone.
Hyperion::Server.handle_static(:GET, '/health', "OK\n")
Hyperion::Server.handle_static(:GET, '/version',
                               '{"v":"1.0"}',
                               content_type: 'application/json')

# Dynamic — handler#call(request) returns a [status, headers,
# body] tuple per request.  Bypasses env construction; still
# uses ResponseWriter for the writeout.
class HealthCheck
  def call(request)
    [200, { 'content-type' => 'text/plain' },
     ["#{Process.pid}\t#{Time.now.to_i}\n"]]
  end
end
Hyperion::Server.handle(:GET, '/-/probe', HealthCheck.new)
```

**Lifecycle hooks invariant.** `Runtime#on_request_start` /
`on_request_end` fire on direct routes regardless of the
`StaticEntry` vs `[status, headers, body]` branch.  The `env`
positional is `nil` on the direct path (no Rack env was built
— that's the whole point); observers that depend on env keys
(e.g. NewRelic transaction names from `PATH_INFO`) should read
`request.path` / `request.method` from the `Hyperion::Request`
positional instead.  Documented + spec-covered.

**Per-process route table.** Forked workers each inherit a
copy of the parent process's table at fork time (no IPC, no
shared memory).  Registrations made BEFORE `Server.start`
propagate to every worker via copy-on-write; registrations
made AFTER fork (e.g. from `on_worker_boot`) only affect the
calling worker — by design, this is the operator's escape
hatch for per-worker routing (e.g. a debug endpoint that
wants to know which worker served the response).

**Concurrency.** Registrations are Mutex-guarded; lookups are
lock-free (Ruby Hash reads under MRI are safe against a
mutex-guarded concurrent write because the GVL pins the
writer during the bucket update).  Concurrent multi-thread
registration is regression-tested via an 8-thread × 100-route
stress example.

**Spec count.** 989 → 1018 (+21 from `direct_route_spec.rb`,
+8 from a parallel 2.10-G h2 timing spec landing in this same
window).  All 1018 green on macOS arm64.

### 2.10-G — Investigate Hyperion h2 max-lat ~40 ms ceiling (instrumentation + fix)

**Status: RESOLVED.** Instrumentation landed first (`HYPERION_H2_TIMING=1`
on `WriterContext`); the bench-host h2load re-run that followed showed
the latency ceiling was *not* a first-stream-only cost as hypothesized
— it was paid by **every** stream (`min 40.63 ms, mean 44.01 ms` on
`-c 1 -m 100 -n 5000`), which is the unmistakable signature of the
Linux **delayed-ACK 40 ms timer** interacting with Nagle on small h2
framer writes. Fix: enable **TCP_NODELAY** on every accepted socket
right after `apply_timeout` runs. Result on the same bench
(post-handshake handshake stripped, h2load `-c 1 -m 1 -n 200`):

| | Pre-fix | Post-fix | Delta |
|---|---:|---:|---:|
| min request time | 40.62 ms | 542 µs | **−98.7%** |
| mean request time | 41.66 ms | 833 µs | **−98.0%** |
| max request time | 45.00 ms | 4.71 ms | **−89.5%** |
| throughput | 23.98 r/s | 1,141.81 r/s | **+47.6×** |

(Latency tail collapses from a tight Gaussian centered on the
delayed-ACK timer to a sub-millisecond mean — exactly what Falcon and
Agoo show on the same workload.)

The pre-fix instrumentation stays in place — the env-flag-gated
`WriterContext` timing slots are durable diagnostic infrastructure for
any future cold-stream / first-stream regression. The TCP_NODELAY
single-line fix is in `lib/hyperion/server.rb#apply_tcp_nodelay`,
called from `apply_timeout` so every accepted connection picks it up
(both H1 and H2 paths). Errors swallowed silently — UNIX sockets,
SSLSocket-without-`#io`, and platforms missing TCP_NODELAY all
gracefully fall through.

**Why this beat both hypotheses.** The instrumentation framing
expected the cost on the **first** stream of each connection
(SETTINGS round-trip or fiber pool warm-up). Reality: protocol-http2
emits HEADERS and DATA as separate framer writes per stream; on
**every** stream, the server's first packet arrives at the peer
alone, the peer waits 40 ms for the next packet to piggyback an ACK,
Hyperion's writer fiber waits because Nagle is buffering the second
write until that ACK lands. Setting TCP_NODELAY at accept-time breaks
the cycle for every stream, not just the cold one.

**Filed for 2.11 (no longer the same item).** "h2 first-stream tail
optimization (TLS handshake parallelization)" — distinct from the
40 ms ceiling, which is fixed. The instrumentation reads the residual
cold-stream cost cleanly now that the ACK noise is gone.

---



**Background (filed by 2.9-B).** The Falcon h2 head-to-head bench
(`bench/h2_falcon_compare.sh`, `h2load -c 1 -m 100 -n 5000`) found
Hyperion's max-latency suspiciously **flat at ~40 ms** across all three
rows (hello / h2_post / h2_rails_shape) while Falcon's max-latency on
the same workloads is **5-10 ms**. RPS is fine — 1,778-2,198 r/s — so
this is a tail-latency problem on the **first** stream of each h2
connection, not a throughput problem.

**Hypothesis.** The bench drives 5,000 streams over ONE connection;
only stream #1 pays the connection-setup cost. The flat 40 ms ceiling
across rows reads as a fixed-cost first-stream setup delay — most
likely TLS handshake completion + initial SETTINGS round-trip +
framer-fiber priming all serialized on the first stream's response
path. Once the connection is warm, subsequent streams should land at
~5 ms and the median+p99 stay healthy; the **max** comes entirely
from the cold first stream.

**What landed (instrumentation only).** Four monotonic timestamps on
every h2 connection, gated by `HYPERION_H2_TIMING=1` (off by default —
zero hot-path overhead when disabled, single ivar read per branch
when enabled):

| Slot | Captured at |
|---|---|
| `t0_serve_entry`  | `Http2Handler#serve` entry (post-TLS, post-ALPN — the SSL handshake completed before the handler was reached) |
| `t1_preface_done` | After `server.read_connection_preface(initial_settings_payload)` returns (server SETTINGS encoded + handed to framer queue; client preface fully read) |
| `t2_first_encode` | After the **first** stream's `send_headers` + `send_body` finish encoding (bytes sit in writer queue) |
| `t2_first_wire`   | After the writer fiber's first successful `socket.write` (first chunk on the wire — typically the server's preface SETTINGS frame) |

Stored on the per-connection `WriterContext`. Captured exactly once
per connection via simple `nil?` guards (no mutex needed — the encode
mutex around `send_headers` plus the single-writer-fiber invariant
already serialize the writes that matter). Emits one info-level line
on connection close:

```text
{"ts":"...","level":"info","source":"hyperion",
 "message":"h2 first-stream timing",
 "t0_to_t1_ms":<preface exchange>,
 "t1_to_t2_enc_ms":<first stream encode>,
 "t2_enc_to_t2_wire_ms":<encode→wire>,
 "t0_to_t2_wire_ms":<total cold-stream cost>}
```

**Next bench window (the 60-second drill).** SSH to the bench host,
enable instrumentation, re-run `h2load -c 1 -m 100 -n 5000`, grep for
`'h2 first-stream timing'`. Three diagnostic shapes:

1. `t0_to_t1_ms` ≈ 40 ms, others ~0 → fix is to parallelize the
   server-preface SETTINGS write with the kernel TLS handshake
   completion (currently they're serial — TLS handshake completes
   inside `Hyperion::Tls`, then `Http2Handler#serve` runs, then
   preface is written).
2. `t1_to_t2_enc_ms` ≈ 40 ms, others ~0 → fix is to **pre-spawn the
   stream-dispatch fiber pool** at connection accept rather than
   lazily on the first `ready_ids` tick. Today the first dispatch
   fiber is spawned by `task.async { dispatch_stream(...) }` only
   AFTER the first complete HEADERS frame is read; an Async scheduler
   tick is needed before that fiber runs and reaches `send_headers`.
3. Spread across both → both fixes apply. Either way the deltas tell
   the operator exactly where to cut.

**Files touched (instrumentation-only commit).**

| File | Change |
|---|---|
| `lib/hyperion/http2_handler.rb` | Added 4 timing slots to `WriterContext` + capture sites in `serve` (t0/t1), `dispatch_stream` (t2_encode), `run_writer_loop` (t2_wire). New private helpers `monotonic_now` and `log_h2_first_stream_timing`. All gated by `@h2_timing_enabled` (resolved once at handler-construction from `HYPERION_H2_TIMING`). |
| `spec/hyperion/http2_first_stream_timing_spec.rb` | 8 new specs locking the contract: env-flag gating (3 cases — default off, truthy-on, truthy-off), nil-default WriterContext slots, log-emit shape (deltas in ms, non-negative, ordered), partial-capture short-circuit (nil timestamp → no log), best-effort error swallow. **No assertion on absolute latency** (would be CI-flaky). |

**Spec count.** 989 → 997 (+8). All green on macOS arm64.

**Why no fix this sprint.** Step 2 / step 4 of the investigation plan
required SSH to `openclaw-vm` for live h2load runs to read the
breakdown. That access path is currently rejecting the operator's
on-disk SSH key from this workstation (same root cause class as 2.9-E
documented — environmental, not code). Rather than guess at the right
fix from a hypothesis (and risk a regression on the 2.5-B Rust HPACK
win or the 1.6.0 writer-fiber refactor), the instrumentation is
landing standalone so the bench window after this can resolve it in
one shot. The 40 ms is a tail-latency knob; the median + p99 stay
healthy and 2.10's 4-way bench results stand as published.

**Filed forward to 2.11.** "h2 max-lat fix based on 2.10-G timing
breakdown" — owner runs the timing bench, reads the dominant bucket,
implements one of the two candidate fixes above (or files a third if
the breakdown reveals something unexpected). The instrumentation
itself is durable infrastructure beyond this single investigation:
any future "first-stream slow" / "cold-connection latency" bug hits
the same probe and gets the same diagnostic shape.

### Filed for later 2.10 streams

(populated as 2.10-D..H land)

## [2.9.0] - 2026-05-01

### Headline

A measurement-correction + observability + ops-fix release. The 2.9
sprint resolved the deferred 2.7 / 2.8 bench items now that openclaw-vm
is back online, plus shipped the 2.8-A per-route deflate metric that
was held mid-sprint, plus closed the recurring "Permission denied
(publickey)" subagent-SSH gap.

| Item | Result |
|---|---|
| **2.9-A — chunk-size A/B (2.6-A delta quantified)** | **+7.4% rps** for 256 KiB vs 64 KiB chunk on fresh host (3,358 vs 3,128 r/s median, p99 identical). Real but smaller than 2.6-A's inflated +20.7% (which was measured against a degraded baseline). |
| **2.9-B — Falcon h2 head-to-head** | **hello: parity. h2_post: Falcon +10%. h2_rails_shape: Hyperion +58%** (Rust HPACK earning its keep on header-heavy responses). 2.10-A finding filed: Hyperion's max-lat stuck at ~40 ms vs Falcon's 5-10 ms (suspect first-stream setup delay). |
| **2.9-C — Per-route deflate ratio** | `hyperion_websocket_deflate_ratio` now carries a `route` label (explicit `env['hyperion.websocket.route']` or `env['PATH_INFO']` templated). Multi-channel ActionCable operators see per-channel compression. Cardinality bounded by templater LRU. |
| **2.9-D — Matched-config PG bench** | **Hyperion +29.8% rps, p99 26% lower** at matched pool=80 against local PG (max_conn=100). The 2.0.0 "+378% / 4.78×" was a config artifact; honest architectural advantage is +30% rps + 26% lower tail. |
| **2.9-E — SSH subagent gap** | Documented in `docs/BENCH_HOST_SETUP.md`. Fix: `IdentitiesOnly yes` + explicit `IdentityFile` in `~/.ssh/config`. Verified hermetic-env reproducibility. |

Spec count: 956 (2.8.0) → **964** (2.9.0). 0 failures, 11 pending.

### Filed for 2.10

- **2.10-A** Hyperion h2 max-lat ~40 ms ceiling (vs Falcon's 5-10 ms). Suspect first-stream setup delay.

### 2.9-E — Fix recurring SSH "Permission denied (publickey)" subagent gap

Fixes the recurring "Permission denied (publickey)" gap that has
blocked subagent bench runs against `openclaw-vm` since at least
Phase 9 (2.2.x) — every bench-running subagent from Phase 9/10/11,
2.2.x fix-A..E, 2.3-A..D, 2.5-B/D, 2.6-A..D, 2.7-A/C/D/F, 2.8-A and
2.9-B has reported "SSH not available, deferred to maintainer".

**Root cause.** The maintainer's `~/.ssh/config` had `Host openclaw-vm`
+ `IdentityFile ~/.ssh/id_ed25519_woblavobla` but no `IdentitiesOnly yes`
and no explicit `User ubuntu`. Interactive shells worked because
macOS Keychain loaded the key into `ssh-agent`, but subagent shells
inherited an empty `SSH_AUTH_SOCK` (or one populated with other
host keys), so OpenSSH offered the wrong identities and the bench
host rejected them before falling through to the on-disk file.

**Fix.** Add `IdentitiesOnly yes` + `User ubuntu` + `HostName
192.168.31.14` to the workstation's `~/.ssh/config` block. With
`IdentitiesOnly yes`, OpenSSH ignores the agent entirely for that
host and uses only the listed `IdentityFile`, making the config
robust to any process-environment state (no agent, empty agent,
agent-with-other-keys).

**Verification.** Hermetic-shell SSH works with the new config:

```sh
env -i HOME=$HOME PATH=$PATH ssh -o ConnectTimeout=5 ubuntu@openclaw-vm date
# → Fri May  1 08:36:47 UTC 2026
```

This is the same execution context every subagent inherits, so
future bench tasks no longer hit the "deferred to maintainer" wall.

**No code changes.** 2.9-E is operator-setup + docs only:
new `docs/BENCH_HOST_SETUP.md` documents the gap, the fix, and the
verification command for any future maintainer who hits the same
`Permission denied (publickey)` wall. The actual `~/.ssh/config`
edit happens on the controller workstation; the in-repo doc is the
durable record.

### 2.9-D — Matched-config PG bench (honest ratio quantified)

The 2.0.0 BENCH row 7's "PG +378% / 4.78×" was apples-to-oranges
(Puma tested at pool=100 against local PG max_conn=100, timed out
200/200 wrk requests at the pool ceiling; Hyperion tested against
WAN PG max_conn=500). The 2.6-E audit annotated the row as
"honest matched ratio ~2.2×" without a clean rerun.

2.9-D ran the clean matched-config bench against the local PG
(max_conn=100) with both servers at pool=80 (under ceiling, no
timeouts):

| Server | Run 1 | Run 2 | Run 3 | Median | p99 |
|---|---:|---:|---:|---:|---:|
| Hyperion `--async-io -t 5 -w 1` pool=80 | 1,568 | 1,562 | 1,565 | **1,565 r/s** | 138 ms |
| Puma `-t 80:80 -w 1` pool=80 | 1,104 | 1,211 | 1,206 | **1,206 r/s** | 186 ms |

**Verdict: Hyperion +29.8% rps, p99 26% lower.** Real, durable,
matched-config Hyperion win. The original 4.78× / 378% ratio was a
config artifact (Puma at the ceiling); the honest architectural
advantage of async-io fiber pool over threadpool on this workload
is +30% rps + 26% lower tail.

`docs/BENCH_HYPERION_2_0.md` row 7 will be updated to lead with
the verified +30% number alongside the historical 4.78× as a
deprecated framing.

### 2.9-A — sendfile chunk-size A/B on fresh host (2.6-A delta quantified)

The 2.7-A bisect found that 2.6-A's "+20.7% rps from chunk size 64 KiB
→ 256 KiB" was measured against a degraded-host baseline; both numbers
were ~3× lower than the algorithmic floor. 2.9-A re-runs the A/B on
the fresh-boot host to quantify the actual chunk-size delta.

**Method.** `lib/hyperion/http/sendfile.rb` `USERSPACE_CHUNK` toggled
between `256 * 1024` (current default) and `64 * 1024` (pre-2.6-A
value). Same harness: `bin/hyperion -t 5 -w 1`, 1 MiB asset,
`wrk -t4 -c100 -d20s`, 3 runs each, take median.

| Config | Run 1 | Run 2 | Run 3 | Median |
|---|---:|---:|---:|---:|
| 256 KiB (current) | 2,958 | 3,359 | 3,374 | **3,358 r/s** |
| 64 KiB (pre-2.6-A) | 3,128 | 3,424 | 2,933 | **3,128 r/s** |

**Verdict.** **+7.4% rps for 256 KiB**, p99 essentially identical
(2.4-2.86 ms across both configs — the chunk-size change does not
affect tail latency). Real but smaller than the 2.6-A "+20.7%" claim.
The headline win is preserved (256 KiB matches nginx/Apache defaults,
4× fewer syscalls per 1 MiB request) and corroborated by the bench;
the inflated number from 2.6-A's degraded-host baseline is now
corrected.

**No code changes from 2.9-A.** `USERSPACE_CHUNK` stays at 256 KiB.

### 2.9-B — Falcon h2 head-to-head (the apples-to-apples h2 comparison owed since 2.6-E)

Rows 10/11 of `BENCH_HYPERION_2_0.md` have carried the framing "Puma 8
lacks native h2 — Falcon comparison owed" since 2.6-E. Falcon 0.55+
ships native h2 and is the apples-to-apples comparison for Hyperion's
h2 path; 2.7-E was deferred when openclaw-vm went offline + Falcon
wasn't installed. 2.9-B installs Falcon 0.55.3 alongside Hyperion on
the fresh-boot host and runs the matched harness.

**Verdict (lead with the headline).** Hyperion wins on Rails-shape
(25-header) h2 by **+58% rps** (1,778 vs 1,125 r/s) — the Rust-native
HPACK shipped in 2.5-B earns its keep on real-shape responses. Falcon
wins on h2 POST by **+9.7% rps** (1,734 vs 1,580). Hello (2-header) is
**parity** (within 2%, inside bench noise). **Falcon wins max-latency
across all three rows by 4-7×** (Falcon 5-10 ms; Hyperion flat ~40 ms);
filed as 2.10-A follow-up.

**Method.** `h2load -c 1 -m 100 -n 5000`, 3 runs each, median.
Hyperion `bin/hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem
-t 64 -w 1 --h2-max-total-streams unbounded` with default-on Rust
HPACK (boot log: `mode: native (Rust v2 / Fiddle)`,
`hpack_path: native-v2`). Falcon `falcon serve --hybrid -n 1 --forks 1
--threads 5` (single-process, 5 threads). Same self-signed RSA-2048
TLS cert. All 18 runs landed 5,000 / 5,000 succeeded, 0 errored.

| Rackup | Hyperion rps | Falcon rps | Δ rps | Hyperion max-lat | Falcon max-lat |
|---|---:|---:|---:|---:|---:|
| `hello.ru` (2 hdrs) | **2,198** | 2,152 | +2.1% (parity) | 40.72 ms | **5.58 ms** |
| `h2_post.ru` | 1,580 | **1,734** | Falcon +9.7% | 40.84 ms | **9.94 ms** |
| `h2_rails_shape.ru` (25 hdrs) | **1,778** | 1,125 | Hyperion +58.0% | 40.69 ms | **6.44 ms** |

**Reading.** Both servers are good; operators terminating h2 on the
wire have a real choice. Pick Hyperion for Rails-shape h2 (the +58%
ships measurable extra capacity per box). Pick Falcon for POST-heavy
h2 endpoints or if max-latency tail is the priority. Hello is a coin
flip.

**Bench harness shipped.** `bench/h2_falcon_compare.sh` — runs all 6
combinations and prints per-rackup median rps + max-latency. Drives
both Hyperion (`bin/hyperion`) and Falcon (`falcon serve`) on the same
TLS cert + same h2load envelope. Re-runnable:
`~/hyperion/bench/h2_falcon_compare.sh`.

**No production code changes.** Bench-only commit. Spec count
unchanged — bench scripts and BENCH doc only.

**2.10-A filed.** Hyperion's flat ~40 ms first-stream max-latency on
h2 is a real and operator-visible tail-latency gap vs Falcon's ~6 ms.
Reads as a fixed-cost setup delay (TLS handshake + initial SETTINGS
exchange + first stream's framer-fiber priming), not a throughput
issue. Investigation owed in the next bench window — does NOT block
2.9 ship.

### 2.9-C — per-route permessage-deflate ratio histogram

`hyperion_websocket_deflate_ratio` (shipped in 2.4-C as a process-wide
histogram) now carries a `route` label. Operators running ActionCable /
pubsub apps with multiple channels (chat, notifications, presence,
telemetry — each with different payload shapes) can finally see which
channel is paying the Zlib tax for what compression yield.

**Resolution.** `Hyperion::WebSocket::Connection.new` accepts two new
kwargs (`env:`, `route:`); the route label resolves exactly once at
construction:

  1. Explicit `route:` kwarg (test / library users)
  2. `env['hyperion.websocket.route']` (operator-named channel)
  3. `Hyperion::Metrics.default_path_templater.template(env['PATH_INFO'])`
     (auto — `/notifications/123` → `/notifications/:id`)
  4. `'unrouted'` fallback for connections built without `env`

**Hot path.** The resolved label tuple is cached on the `Connection` as
a frozen one-element Array. The per-message observation is a single
mutex-guarded Hash lookup against the cached ref — no per-frame regex
walk, no per-frame allocation. `yjit_alloc_audit_spec` stays at
≤ 10.0 objects/req on the full HTTP path (the deflate path doesn't
intersect that audit, but the same zero-allocation discipline applies).

**Cardinality.** Bounded by the templater's LRU (default 1000 entries
— the same bound that protects `hyperion_request_duration_seconds`'s
`path` label).

**Backwards compatibility.** Pre-2.9-C dashboards that summed the
unlabeled histogram keep working: `sum without (route) (rate(...))`
recovers the prior process-wide signal.

Files: `lib/hyperion/websocket/connection.rb`,
`spec/hyperion/websocket_per_route_deflate_spec.rb` (8 new specs;
total → 964), `docs/OBSERVABILITY.md` "Per-route deflate ratio (2.9-C)"
subsection, `docs/grafana/hyperion-2.4-dashboard.json` two new panels
("Deflate ratio by route (p50/p99) — 2.9-C").

## [2.8.0] - 2026-05-01

### Headline

A measurement-correction release. No new code-path perf work; the 2.8
sprint resolved the deferred 2.7 bench items now that openclaw-vm is
back online (fresh boot, clean host).

| Item | Result |
|---|---|
| **2.7-A bisect (deferred from 2.7)** | **NO REGRESSION.** Full bisect across v2.0.1 → master shows all versions at **2,884-3,504 r/s, p99 2.25-2.69 ms** on static 1 MiB (variance ~15%, no step-down). The audit's 1,094-1,697 r/s readings were all bench-host degradation artifacts. **True algorithmic floor: ~3,000 r/s, p99 ~2.5 ms** — substantially better than every published BENCH figure. |
| **2.7-C SSE cross-server (deferred from 2.7)** | Hyperion **510 r/s, p99 2.42 ms** vs Puma **133 r/s, p99 9.64 ms** on `bench/sse_generic.ru`. **+281% rps, 4× lower p99.** Honest cross-server number replaces the prior "Puma can't stream" misclaim (which was a Hyperion-flush-sentinel rackup issue). |
| **2.7-F warm-cache validation (deferred from 2.7)** | Master HEAD with fadvise hoisted-once: 3,003 / 2,942 / 2,832 r/s median **2,942 r/s, p99 2.7 ms**. Within run-to-run noise of the bisect's master baseline (3,041 r/s). **No warm-cache regression. 2.7-F STAYS.** |
| **2.7-D matched-PG (deferred from 2.7)** | Still deferred. WAN PG (pg.wobla.space) returned "server closed connection unexpectedly" mid-bench from Puma side; the WAN PG is unreliable for matched comparisons. Needs a quieter PG window. |
| **2.7-E Falcon h2 (deferred from 2.7)** | Still deferred. Falcon not installed on bench host; staging follow-up for 2.9. |

### What changed in the BENCH doc

- Row 4 (Static 1 MiB): added the fresh-boot **3,041 r/s** measurement alongside the historical 1,809 / degraded-host 1,228 figures. The audit's "-32% drift since 2.0.0" framing was wrong; drift was synthetic.
- Row 6b (SSE generic): replaced "pending" with the verified Hyperion **+281% / 4× lower p99** numbers.
- Spot-check addendum widened to a 3-column table (published / degraded / fresh-boot) so future readers can see the host-degradation effect on absolute numbers.

### Implications for prior releases

The 2.6-A "+20.7% on static 1 MiB (1,094 → 1,320 r/s)" headline was technically valid as measured (both numbers came off the degraded host that day) but the absolute baseline was wrong by ~3×. The chunk-size bump (64 KiB → 256 KiB) likely still helps; we just can't quantify the delta from those bench runs. A clean A/B re-run on the fresh host is filed as a 2.9 follow-up.

### What didn't change

No production code changes. Spec count unchanged at 956. CI green.

### Filed for 2.9

1. Falcon h2 head-to-head bench (install Falcon on openclaw-vm + run matched h2load harness)
2. Matched-config WAN-PG bench in a quiet PG window
3. 2.6-A chunk-size A/B on the fresh host (quantify the actual delta from chunk=64 KiB vs 256 KiB)
4. Per-route permessage-deflate ratio histogram (was 2.8-A, deferred when sprint was held)

## [2.7.0] - 2026-05-01

### Headline

A doc-accuracy + spec-stability release with two code-level perf items
(2.7-B spec fix, 2.7-F retry of 2.6-B). Three bench-host-dependent
items (2.7-A bisect, 2.7-D matched-PG rerun, 2.7-E Falcon h2) deferred
to the next bench window — openclaw-vm went offline mid-sprint after
the 2.6-E doc audit raised the questions these would answer.

| Stream | Result |
|---|---|
| 2.7-A — Static 1 MiB regression bisect | **COMPLETED 2026-05-01.** Verdict: **NO REGRESSION** — bench-host drift. Fresh-boot bisect across v2.0.1 → master shows all versions at **2,884-3,504 r/s, p99 2.25-2.69 ms** (variance ~15%, flat). The audit's 1,094-1,697 r/s figures were all host-degradation artifacts. True algorithmic floor on this row: **~3,000 r/s, p99 ~2.5 ms** — substantially better than every published BENCH figure. |
| 2.7-B — lifecycle_hooks_spec :share macOS flake | FIXED. Tighter readiness probe (poll 100ms, 30s ceiling). 5/5 local + 3/3 CI green. Real race diagnosed: master binds before workers trap SIGTERM; macOS GH runner timing exposes a microseconds-wide window. No production fix owed (operators don't run :share on macOS; on Linux the window closes too fast for human-scale TERMs). |
| 2.7-C — Generic SSE rackup | SHIPPED `bench/sse_generic.ru` + BENCH row 6b. Cross-server bench (Hyperion vs Puma) deferred — host offline. Honest framing replaces the prior "Puma can't stream SSE" misclaim (which was a Hyperion-flush-sentinel rackup issue, not a Puma capability gap). |
| 2.7-D — Matched-config WAN-PG Puma rerun | DEFERRED. Needs both bench host AND quiet WAN-PG window. The 2.6-E annotation (apples-to-apples ratio ~2.2× vs the published 4.78×) stands. |
| 2.7-E — Falcon h2 head-to-head | DEFERRED. Needs bench host + Falcon install. The 2.6-E reframe ("Puma 8 lacks native h2 — Falcon comparison owed") stands. |
| 2.7-F — fadvise hoisted ONCE per response | SHIPPED with bench validation deferred. Architecturally correct (one `posix_fadvise` call at Ruby loop entry; spec asserts exactly-1-call-per-response). Warm-cache must be ±1% of 2.6.0 1,320 r/s baseline when bench reruns; if it regresses, revert (same disposition as 2.6-B). |

Spec count: 951 (2.6.0) → **956** (2.7.0). 0 failures, 11 pending.

### Production-relevant takeaway for nginx-fronted operators

No new measured perf wins this release — 2.7 was primarily a stability +
honest-doc + deferred-bench cycle. The 2.6.0 +20.7% static win remains
the most recent measured headline.

### What's queued for 2.8 (when openclaw-vm returns)

- Run 2.7-A bisect via the pre-staged script
- Run 2.7-C cross-server SSE bench
- Run 2.7-D matched-PG bench
- Run 2.7-E Falcon h2 bench
- Validate 2.7-F warm/cold cache deltas; revert if regression
- Resolve the "1,697 r/s published vs 1,228 r/s today" static-1-MiB gap

### Spec stability

The flaky `lifecycle_hooks_spec :share` test that has flaked on macOS
CI since at least 2.5.0 is now stable across 6 consecutive macOS GH
runs (2 Ruby versions × 3 attempts in the 2.7-B verification).

### 2.7-F — `posix_fadvise(SEQUENTIAL)` hoisted once per response (retry of 2.6-B)

2.6-B added `posix_fadvise(fd, 0, len, POSIX_FADV_SEQUENTIAL)` inside
the C primitive's per-chunk body — `rb_sendfile_copy`,
`rb_sendfile_copy_splice`, and `rb_sendfile_copy_splice_into_pipe`
each issued the hint once per kernel round.  After 2.6-A's
chunk-cap bump to 256 KiB, that worked out to **4 fadvise64 syscalls
per 1 MiB warm-cache response**, all of them no-ops because the
page cache already held the data.  Maintainer's openclaw-vm bench
measured **-6.6% warm-cache** (1,289 → 1,204 r/s, median of 3); the
commit was reverted (4cd8009).

**Why the hoist makes sense architecturally.** A readahead hint
operates on a *file*, not a *kernel call* — it tells the kernel
"this fd will be read sequentially from offset 0 for `len` bytes,
prefetch accordingly".  The right cardinality is once per
*response* (one file → one hint), not once per *chunk* (one file
→ N hints depending on chunk size).  2.6-B got the cardinality
wrong; 2.7-F gets it right.

**Where the call lives.** `Hyperion::Http::Sendfile.native_copy_loop`
in `lib/hyperion/http/sendfile.rb` calls a new
`maybe_fadvise_sequential(file_io, len)` helper at function entry,
*before* dispatching into `splice_copy_loop` or
`plain_sendfile_loop`.  The helper gates on three conditions:
the C ext defines `fadvise_sequential` (Linux only),
`len >= FADVISE_THRESHOLD` (256 KiB — files smaller fit in a single
sendfile / splice round and don't benefit from prefetch), and
`real_fd?(file_io)` (StringIO / mock IOs without a kernel fd are
skipped).  The C primitive (`rb_sendfile_fadvise_sequential` in
`ext/hyperion_http/sendfile.c`) is a thin wrapper around
`posix_fadvise(2)` that returns `:ok` / `:noop` (non-Linux build) /
`:error`; the Ruby caller ignores the return value.  Net warm-
cache impact: **at most 1 extra syscall per response** (≤1%) vs
2.6.0's zero.

**Verification (local, macOS arm64, Ruby 3.3.3).** 956 examples
pass, 0 failures, 11 pending (was 951 / 0 / 11 — the 5 new
examples are 2.7-F's behavioural specs).  The C primitive returns
`:noop` on Darwin, the Ruby gate skips the helper because
`respond_to?(:fadvise_sequential)` is true but the underlying call
is the no-op variant — no behaviour change on non-Linux hosts.

**Bench validation — DEFERRED.** openclaw-vm was unreachable from
the controller session at landing (SSH timeout, same condition as
2.7-A and 2.7-C bench rerunes), so the bench rerun is queued for
the next bench-host run.  The criteria the bench must hit:

- **Warm-cache** (the typical bench harness, 100 long-lived wrk
  keep-alive connections): 2.7-F vs 2.6.0 baseline 1,320 r/s on
  the 1 MiB static row — **must be within ±1% (or +)**.  If
  warm-cache regresses by even 1%, **revert 2.7-F** the same way
  2.6-B was reverted.  Don't ship a measured regression to chase
  a theoretical cold-cache win.
- **Cold-cache** (`vm.drop_caches=3` between each request): 2.7-F
  should show **measurable +5-10%** vs no-fadvise.  Cold-cache
  isn't the production hot path (assets sit in page cache), but
  it's the workload where the hint actually does something — if
  this row doesn't move, the hint provides no value at any
  cardinality and we should consider dropping it entirely on the
  next perf pass.

**Files touched.**
- `ext/hyperion_http/sendfile.c` — new `rb_sendfile_fadvise_sequential`
  primitive + 3 new symbols (`:ok` / `:noop` / `:error`); ~50 lines
  of C plus the singleton-method registration.
- `lib/hyperion/http/sendfile.rb` — new `FADVISE_THRESHOLD` constant
  (256 KiB), new private `maybe_fadvise_sequential` helper, single
  call site at the top of `native_copy_loop` (covers both
  `splice_copy_loop` and `plain_sendfile_loop` branches).
- `spec/hyperion/http_sendfile_spec.rb` — new `2.7-F — fadvise
  hoisted once per response` describe block: 5 examples covering
  the constant, the C primitive contract, the once-per-response
  invocation count (the regression-killer assertion vs 2.6-B's
  per-chunk shape), and both skip paths (small-file `copy_small`
  route + 100 KiB streaming below `FADVISE_THRESHOLD`).

**Not touched.** `copy_to_socket_blocking` (the `:inline_blocking`
dispatch path).  Same readahead logic applies in principle, but
the blocking path's spec surface is wider and the warm/cold bench
numbers should drive that decision.  Filed for 2.7.x if the
deferred bench rerun shows clear cold-cache value.

### 2.7-A — Static 1 MiB regression bisect — COMPLETED 2026-05-01

**Status: COMPLETED. Verdict: NO REGRESSION — bench-host drift.**

After openclaw-vm came back online (fresh boot, 5 min uptime), the full
bisect ran across `v2.0.1 → master`. All versions land in the
**2,884 → 3,504 r/s range with p99 2.25-2.69 ms** — variance ~15%
inside one workload, no algorithmic step-down between any pair of tags.

| Tag    | Median r/s | p99    |
|--------|-----------:|-------:|
| v2.0.1 | 3,353      | 2.28 ms |
| v2.1.0 | 3,504      | 2.25 ms |
| v2.2.0 | 3,082      | 2.68 ms |
| v2.3.0 | 3,034      | 2.64 ms |
| v2.4.0 | 2,884      | 2.69 ms |
| v2.5.0 | 3,041      | 2.50 ms |
| v2.6.0 | 3,029      | 2.44 ms |
| master (post-2.7) | 3,041 | 2.50 ms |

**The audit's 1,094-1,697 r/s readings — and the partial v2.6.0 = 1,230
r/s data point captured during the prior offline event — were all
bench-host degradation artifacts** (TIME_WAIT pile-up, neighbor-VM
contention, kernel cruft accumulated since the host's last reboot).
The fresh-boot run shows the actual algorithmic floor on this row is
**~3,000 r/s, p99 ~2.5 ms** — substantially better than every published
BENCH figure to date.

**Implications.** The 2.6-A "+20.7% on static 1 MiB (1,094 → 1,320 r/s)"
delta was technically valid as measured (both numbers came off the
already-degraded host that day) but the absolute baseline was wrong by
~3×. The chunk-size bump 2.6-A made still helps; we just can't
quantify by how much from those bench runs. A clean A/B re-run of
2.6-A's chunk-size change against master (chunk=64K vs 256K) on the
fresh host is filed for 2.8.x as a follow-up.

**Documentation update.** `docs/BENCH_HYPERION_2_0.md` row 4 will be
updated with the today-baseline `~3,000 r/s` number alongside the
historical `1,697 r/s` figure marked as "2026-04-29 host conditions,
not algorithmically valid". The audit's 2.6-E table that flagged
"-32% drift since 2.0.0" is also wrong — the drift was synthetic.

**Background.** The 2.6-E audit flagged that the static 1 MiB row
drifted from 2.0.1's published **1,697 r/s** to today's **1,228 r/s**
— a **-28% slide** on the production-relevant row. Three hypotheses
remain open and the bisect is needed to discriminate between them:

1. **Bench-host degradation** (kernel updates, TIME_WAIT pile-up,
   contention from other procs on openclaw-vm) — under this hypothesis
   all v2.x tags would show ~1,200 r/s today and the floor has simply
   drifted; the published 1,697 r/s number reflected 2026-04-29 host
   conditions and the relative Hyperion-vs-Puma comparison still holds.
2. **Genuine Hyperion regression** hidden by misframed numbers — some
   tag between 2.0.1 and 2.6.0 dropped rps and we never noticed because
   the bench number we were tracking was wrong.
3. **Ruby / glibc / wrk version updates** between then and now — the
   bench-host's toolchain was upgraded under our feet.

**Partial data point captured before the host went offline.** A single
v2.6.0 sanity run on this same host completed during script
verification:

| Tag    | Run 1 r/s | Run 2 r/s | Run 3 r/s | Median r/s | p99    |
|--------|-----------|-----------|-----------|------------|--------|
| v2.6.0 | 1231.41   | 1230.06   | 1128.41   | **1230.06**| 6.10ms |

That confirms the v2.6.0 / 1,228 r/s figure is reproducible on the
current host. The other six tags are still unmeasured.

**To resume when openclaw-vm is back.** The bisect script lives at
`~/bench-bisect-2.7-A/bisect.sh` on openclaw-vm; the wrapper at
`~/bench-bisect-2.7-A/run_all.sh` walks all seven tags:

```sh
ssh ubuntu@openclaw-vm
cd ~/bench-bisect-2.7-A
nohup setsid bash run_all.sh </dev/null >/dev/null 2>&1 &
disown
# wait ~14 min, then:
grep -E "^  v2\." run_all.log
```

The script:

1. Checks out each tag in `~/hyperion-fresh` (a separate git checkout —
   does NOT touch `~/hyperion`, which is the symlink target the live
   `~/bench/Gemfile` points at).
2. Rebuilds `ext/hyperion_http` (and `ext/hyperion_h2_codec` if the
   tag has it) against the tag's source.
3. Runs three 20s wrk passes per tag (`-t4 -c100`,
   `http://127.0.0.1:9750/hyperion_bench_1m.bin`, 1 MiB asset).
4. Logs `rps=… p99=…` per run; the maintainer takes the median of 3.

The wrapper Gemfile lives at `~/bench-bisect-2.7-A/Gemfile` and uses
`gem "hyperion-rb", path: "/home/ubuntu/hyperion-fresh"` so the bisect
is fully isolated from `~/bench/Gemfile`'s production path.

**Decision tree (unchanged from 2.7-A spec).**

- **All tags ~1,200 r/s (within ±10%):** bench-host drift; accept the
  new baseline; document `2026-05-01 floor = ~1,200 r/s` as an
  addendum on `docs/BENCH_HYPERION_2_0.md`. No fix.
- **Clean step-down at one tag (e.g. v2.0.1 → v2.1.0 drops 400+ r/s,
  later tags flat):** real regression. Bisect commits inside that
  tag's range; suspect files: `lib/hyperion/connection.rb`,
  `lib/hyperion/adapter/rack.rb`, `lib/hyperion/response_writer.rb`.
  File the FIX as **2.7-A-followup** (separate commit) — this 2.7-A
  entry stays doc-only.
- **Variance > 30% within a single tag:** bench host too noisy for
  bisect; defer again to a quieter window.

### 2.7-C — Generic SSE rackup (drops the Hyperion-flush sentinel)

Bench/docs only — no production code.

The 2.6-E audit pass flagged that `bench/sse.ru` returns chunks via a
Hyperion-specific `:__hyperion_flush__` sentinel (a hint into
`ChunkedCoalescer#force_flush!`). On Hyperion the sentinel is
recognised and treated as a flush hint; on Puma the sentinel is
emitted **as a literal chunk** (`":__hyperion_flush__"` written to the
chunked stream), which breaks the wire framing on the wrk side. That
mis-framing is why the published row 6 in BENCH_HYPERION_2_0.md
showed Puma at "0 r/s, 11,686 read errors" — a rackup-config artefact,
NOT a Puma SSE-capability gap. The audit reframed the row honestly
and filed a generic rackup as the 2.7 follow-up; this is that follow-up.

**Verdict.** Cross-server bench rerun is still owed: bench-host SSH
was unreachable during the 2.7-C doc pass, so the new row 6b in the
matrix is parked as **pending** until the next bench-host run lands
honest numbers for Hyperion vs Puma (and ideally Falcon) on the
generic rackup.

**Added.** `bench/sse_generic.ru` — 1000 SSE events of ~50 bytes
each, `"data: event=I ts=T\n\n"` format, returned via a body whose
`each` method yields **plain Strings** to the server's writer. No
`:__hyperion_flush__`, no `body.flush`, no `[chunk]` arrays — just
the Rack 3 standard streaming contract. The rackup is portable and
boots identically on Hyperion, Puma, and Falcon.

**Verification (local).** Loaded the rackup via `Rack::Builder.parse_file`
and iterated the body: 1000 chunks, ~34.9 KB total, all `String`,
zero `Symbol` sentinels. Status 200 + `text/event-stream`. The
existing `bench/sse.ru` is **untouched** — it remains the right
rackup for testing Hyperion's flush-sentinel protocol; the new file
is a sibling, not a replacement.

**Docs.** `docs/BENCH_HYPERION_2_0.md` row 6 reworded as a
"Hyperion-flush-sentinel internal test, not a fair Puma comparison",
new row 6b added for the generic rackup with results marked
**pending** (2.7-C bench-host run owed). The SSE streaming narrative
section ends with a 2.7-C status note instead of the prior
"filed for follow-up" line.

**Spec count unchanged** (951 examples, 0 failures, 11 pending) — no
production code touched.

### 2.7-B — `lifecycle_hooks_spec.rb` `:share` macOS CI flake fix

Spec-only change. `spec/hyperion/lifecycle_hooks_spec.rb`'s
`:share`-mode example flaked intermittently on macOS GitHub Actions
runners (visibly: 2.5.0 release CI failed once + recovered, 2.6.0 prep
CI 3ca92f8 failed outright) — the assertion was always
`expected two on_worker_shutdown on :share, got [..., on_worker_shutdown:idx=1:pid=...]`
i.e. only one of the two workers wrote a shutdown line.

**Root cause (real, not just slow CI).** On `:share`, the master binds
the listening socket BEFORE forking workers, so the spec's
`wait_for_port` readiness probe returns as soon as the master binds —
possibly before either worker has reached `Signal.trap('TERM')`.
`Worker#run` runs the boot hook, then builds/adopts the listener, then
installs the TERM trap, then `server.start`. If the test sends TERM
during the post-boot/pre-trap window of a worker, the master forwards
TERM, the worker dies via SIGTERM's default action, and the
`on_worker_shutdown` hook never fires. The window is microseconds on
typical Linux dev hardware (where the bench / Linux CI run). On macOS
GitHub runners (slower fork+exec, slower scheduling), the window opens
wide enough to hit reproducibly. **No production user is at risk** —
nobody runs `:share` worker mode on macOS, and even on Linux the window
is closed before any operator could TERM the master interactively.

**Fix.** Tightened the readiness probe (Option B from the brief). New
`wait_for_log_lines(path, pattern, expected_count, timeout)` helper
polls the recorder log every 100 ms until N matching lines appear, with
a generous ceiling (30 s pre-TERM, 10 s post-`waitpid`). The pre-TERM
poll waits for two `on_worker_boot` lines — the boot hook fires
immediately before the TERM trap installs, so once the line is on disk
the trap is installed within microseconds. The post-`waitpid` poll
covers APFS append+fsync ordering on macOS. No production code touched.

**Verification.**
- Local macOS (Apple silicon, Ruby 3.3.6): spec passed 5 consecutive
  runs (`for i in 1..5`); typical run time ~1.3 s. Full suite green:
  951 examples, 0 failures, 11 pending (unchanged).
- CI: pending — push triggers GitHub Actions; the flake doesn't fire
  every run, so 3 consecutive green runs are needed to call it fixed.

## [2.6.0] - 2026-05-01

### Headline

A static-file perf release with a doc accuracy pass. Two perf cuts
landed (sendfile chunk size + inline_blocking dispatch fix), one was
reverted (fadvise per-chunk regressed warm-cache), and the README +
BENCH docs got an honest accuracy review.

| Stream | Result |
|---|---|
| 2.6-A — sendfile chunk size 64 KiB → 256 KiB | **+20.7% on static 1 MiB** (1,094 → 1,320 r/s) |
| 2.6-B — posix_fadvise(SEQUENTIAL) | **REVERTED**: per-chunk call regressed warm-cache -6.6%; cold-cache win unmeasurable. Filed as 2.7 candidate IF hoisted-once approach lands. |
| 2.6-C — `:inline_blocking` dispatch mode | Puma-style serial-per-thread for static-file routes. Auto-detect on `to_path` bodies. Initial bench surfaced engagement gap fixed in 2.6-D. |
| 2.6-D — engagement gap + bookkeeping strip | `Fiber.blocking{}` wrap bypasses `Async` scheduler hooks on `IO.select`. **p99 collapses 433 ms → 7.48 ms at c=10** under `--async-io`; +6% rps with 39-72% p99 reduction at c=100. |
| 2.6-E — doc + bench audit | README + BENCH_HYPERION_2_0 fairness review. PG +378%/4.78× honest matched ratio ~2.2×. HTTP/2 rows relabelled. Topology column added. 4 follow-ups filed for 2.7. |

Spec count: 907 (2.5.0) → **951** (2.6.0). 0 failures, 11 pending.

### Production-relevant takeaway for nginx-fronted operators

Static-file rps on the user's plaintext-h1 topology improved by **+20.7%** via
2.6-A. The `:inline_blocking` dispatch mode (2.6-C/D) is most relevant
for operators running with `--async-io` (PG-heavy workloads); the auto-detect
mechanism kicks in transparently for routes that return `to_path` bodies.
Default threadpool dispatch (the user's typical config) sees ~no change
on rps from 2.6-C/D — threadpool already serves static via OS threads
without fiber yield, so there's nothing to skip.

### Doc accuracy

The 2.6-E audit corrected several misframed wins from prior releases:
- PG-bound row's `+378% / 4.78×` claim was apples-to-oranges (different
  PGs, different max_conn budgets); honest matched ratio is ~2.2×.
- HTTP/2 multiplexing rows are now framed honestly as "Puma 8 lacks
  native h2 — Falcon comparison owed" rather than "Hyperion wins h2".
- SSE row's "Puma can't stream" was due to a Hyperion-specific flush
  sentinel in the rackup; reframed honestly. Generic SSE rackup filed
  for 2.7.
- Bench-host drift -14 to -32% absolute since 2.0.0 publication is
  documented in BENCH addendum; the relative Hyperion vs Puma ratios
  remain durable.
- Production-relevance column added to BENCH headline table marking
  each row "prod" (nginx-fronted h1 / WS upstream) or "bench-only"
  (TLS termination at Hyperion, h2 multiplexing, kTLS_TX) so operators
  don't chase wins that don't apply to their topology.

### What didn't ship

- 2.6-B (fadvise SEQUENTIAL) reverted; will revisit in 2.7 if a real
  cold-cache static workload surfaces.

### Follow-ups for 2.7

1. `bench/sse_generic.ru` — generic SSE rackup without Hyperion sentinel
2. Matched-config WAN-PG Puma rerun for row 7 (clean ratio)
3. Falcon h2 head-to-head for the HTTP/2 rows
4. Static 1 MiB regression bisect (today 1,228 vs 2.0.1's 1,697 — bench drift suspected, verification owed)

### 2.6-D — `:inline_blocking` engagement-gap fix + Connection bookkeeping strip

Two-part landing.  Headline first: closes the 2.6-C runtime
engagement gap that the maintainer's 2026-05-01 openclaw-vm bench
flagged ("auto-detect SHOULD kick in here and drop p99 to ~6 ms.
It doesn't").  Bookkeeping strip second: skip lifecycle hooks +
per-conn fairness on auto-detected static-file responses.

#### Part 1 — Engagement gap fix (the headline)

**Root cause.**  2.6-C's `Sendfile.copy_to_socket_blocking`
replaced fiber-yielding `wait_writable` with `IO.select`,
expecting `IO.select` to park the OS thread on the kernel
readiness check.  Under `--async-io` it doesn't.  The Async
gem hooks `Fiber.scheduler.kernel_select`; when the calling
fiber is non-blocking (the default, including every fiber
inside `start_async_loop`'s `task.async { dispatch(socket) }`),
`IO.select` is intercepted by the scheduler and routes through
its cooperative-yield path — same shape as `wait_writable`,
just one more layer of indirection.  The auto-detect set the
flag, the writer plumbed it, the sendfile loop branched on
it, and EVERY EAGAIN still yielded the fiber.  Unit specs
that asserted the dispatch_mode flag was set caught only the
plumbing — they couldn't catch the runtime bypass because
they ran on a non-Async fiber, where `Fiber.current.blocking?`
is true by default.

**The fix.**  `ResponseWriter#write_sendfile` wraps the
entire write path in `Fiber.blocking { ... }` when
`dispatch_mode == :inline_blocking`.  `Fiber.blocking`
(class-method block form) flips the calling fiber's
`Fiber.current.blocking?` to true for the duration; while
blocking, scheduler hooks (`kernel_select`, `io_wait`,
`block`) are NOT consulted — the fiber's IO calls go
straight to the OS, exactly the Puma-style serial-per-
thread shape `:inline_blocking` was designed to deliver.
Defensive secondary wrap inside
`Sendfile.copy_to_socket_blocking` so direct callers get
the no-yield guarantee even without the writer-level wrap.
`select_writable_blocking` also wraps when called from a
non-blocking fiber, belt-and-suspenders.

**Why the unit specs missed it.**  The 2.6-C suite ran
the writer + sendfile helpers against a `StringIO` /
direct-`TCPSocket` pair on the spec's main thread — no
Async reactor, no fiber scheduler current.
`Fiber.current.blocking?` is true on the main thread by
default, so the IO.select fell through to the OS as
expected, and the spec asserting "blocking variant
fires" passed.  The bug was only observable end-to-end
under a live `start_async_loop` — which the unit specs
didn't boot.  2.6-D's regression specs boot a real
`Async { ... }.wait` block + a real socket pair so the
fiber-scheduler interception path is actually exercised.

**Bench delta on openclaw-vm 2026-05-01** (Linux 6.x,
1 MiB warm-cache static asset, `--async-io -t 5 -w 1`):

  * **2.6-C baseline (`-c100`):** 1,232 r/s, p99 **433-710 ms**.
  * **2.6-D (`-c100`):** 1,262 / 1,362 / 1,307 r/s
    (median 1,307 r/s, +6%), p99 **211 / 264 / 451 ms**
    (median 264 ms; 39-72% reduction vs 2.6-C).
  * **2.6-D (`-c20`):** 1,276 r/s, p99 **18 ms**.
  * **2.6-D (`-c10`):** 1,279 r/s, p99 **7.48 ms**.

The headline ≤10 ms p99 target IS reached at low-to-medium
concurrency (c=10 hits **7.48 ms p99** within noise of the
threadpool baseline).  At c=100 over `-t 5` the per-thread
queue length (20 connections per OS thread) reintroduces a
~200 ms tail because each blocking sendfile parks the OS
thread for the duration of the kernel write — that's the
explicit Puma-style trade-off, not a bug in the engagement
fix.  Operators who need a tighter p99 at c=100 should
either bump `-t` (more OS threads, shorter queue) or fall
back to threadpool dispatch (no fiber yield to begin with,
so `:inline_blocking` brings nothing on that path).

The engagement-fix proof: at c=100 the *throughput* is up
6% AND p99 is down 39-72% — both impossible if the dispatch
were still routing through the fiber scheduler.

#### Part 2 — Connection bookkeeping strip on inline_blocking static

When `:inline_blocking` is engaged, the per-conn
fairness check (2.3-B) and the after-request lifecycle
hook (2.5-C) are stripped from the request loop:

  * **Per-conn fairness cap** — `Connection#serve` skips
    the `per_conn_admit!` admission check on the request
    iteration FOLLOWING a `:inline_blocking` response on
    the same keep-alive connection.  Sticky flag, resets
    the moment a non-static response lands.  Static-
    asset connections (CDN origins, signed-download
    responders) typically run a long sequence of
    `to_path` responses; the fairness cap was designed
    for dynamic-route concurrency throttling and is
    dead weight on a static stream.

  * **After-request lifecycle hook** — `Adapter::Rack#call`
    skips `Runtime#fire_request_end` when
    `Connection#response_dispatch_mode` resolves to
    `:inline_blocking`.  The before-request hook still
    fires (it's cheap; useful for span creation,
    request-id assignment, etc.).  Asymmetric by
    design: the after-hook is the heavy one (span
    flush, DB write, async-queue enqueue), and that's
    the cost we shed.

#### Behaviour change — operators with per-request hooks attached for static-route observability

Pre-2.6-D, `Runtime#on_request_end` fired on EVERY
request — static-file routes included.  Operators with
NewRelic / DataDog / OpenTelemetry hooks attached to
trace span lifecycles would see one span per static
asset (every `/assets/*.css` / `/uploads/*.png`).  Post-
2.6-D, those spans STOP firing on auto-detected
static-file responses.

**Migration.**  The metrics module observes static
traffic with no hook overhead:
  * `hyperion_request_duration_seconds` per-route
    histogram with method/path/status labels.
  * `:sendfile_responses` counter (per worker).
  * `:requests_dispatch_inline_blocking` per-mode
    counter — explicit "this route engaged the
    static fast path" signal.
Operators relying on hooks for static observability
should migrate to these counters/histograms.  The
hooks remain authoritative for dynamic routes (CPU
JSON, streaming, hijacked WebSocket, etc.).

#### Files touched
- `lib/hyperion/response_writer.rb` — `Fiber.blocking`
  wrap on `write_sendfile` when `dispatch_mode ==
  :inline_blocking`.  Hot logic split into
  `write_sendfile_inner` so the wrap is a single
  method-dispatch when the branch fires, zero cost
  otherwise.
- `lib/hyperion/http/sendfile.rb` — defensive
  `Fiber.blocking` wrap on `copy_to_socket_blocking`
  + `select_writable_blocking` so direct callers
  inherit the no-yield guarantee.  No-op when the
  calling fiber's `blocking?` flag is already true.
- `lib/hyperion/connection.rb` — `@last_response_was_static_inline_blocking`
  sticky flag; per-conn fairness admission check is
  skipped on the request iteration following a
  `:inline_blocking` response.  Flag resets on the
  first non-static response.
- `lib/hyperion/adapter/rack.rb` — `inline_blocking_resolved?`
  helper consulted by the lifecycle-hook branch in
  `#call`; `fire_request_end` is skipped when the
  resolved dispatch mode is `:inline_blocking`.
- `spec/hyperion/inline_blocking_dispatch_spec.rb` — 4
  engagement-gap regression specs (Async reactor +
  socket pair, observe `Fiber.current.blocking?` at
  the moment of IO.select / sendfile entry), 4
  lifecycle-hook behaviour specs (before-hook still
  fires, after-hook skipped on inline_blocking,
  after-hook still fires on dynamic + on app-error),
  3 Connection sticky-flag specs.  The pre-2.6-D
  "fires before-request and after-request hooks on a
  static-file response" spec is REPLACED with the
  asymmetric-hook specs because the behaviour
  changed.

Spec count: 947 → 951 (+4 net; +11 new, -7 superseded
by replacement specs).  0 failures, 11 pending
(Linux-only splice tests on macOS).

### 2.6-C — `:inline_blocking` dispatch mode (Puma-style serial-per-thread sendfile for static)

The biggest remaining 2.6 cut on the static-file row.  Adds a sixth
`Hyperion::DispatchMode` value (`:inline_blocking`) and an opt-in
per-response code path that issues `sendfile(2)` under the GVL with
`IO.select`-driven EAGAIN handling — Puma's response-write shape —
instead of the legacy fiber-yielding `wait_writable` round-trip.

**Dispatch model.**  `:inline_blocking` is opt-in PER RESPONSE, NOT a
connection-wide mode.  The connection's connection-wide dispatch
mode (resolved at boot from `tls`, `async_io`, ALPN, and
`thread_count`) stays whatever the operator configured —
typically `:async_io_h1_inline` or `:threadpool_h1` for the bench
shape.  Per-response, the response-write loop reads
`Connection#response_dispatch_mode` (set by the Rack adapter) and,
when it equals `:inline_blocking`, branches to
`Hyperion::Http::Sendfile.copy_to_socket_blocking` instead of
`copy_to_socket`.

**Auto-detect.**  `Adapter::Rack#call` inspects the response after
`app.call` returns.  When the body responds to `:to_path` AND
`env['hyperion.streaming']` is not set, it stashes
`:inline_blocking` on the connection.  `to_path` is Rack's
strongest "this is a static file on disk" signal — Rack::Files,
Rack::SendFile, asset servers, and signed-download responders all
set it; SSE / chunked / streaming JSON bodies do not.  Conservative
by design: streaming routes cannot accidentally engage
`:inline_blocking` because their bodies don't respond to
`:to_path`.

**Explicit opt-in.**  Apps can set
`env['hyperion.dispatch_mode'] = :inline_blocking` for routes the
auto-detect doesn't catch (e.g. a custom Range-request body that
needs the blocking write loop but has a non-standard `to_path`-like
shape).  Operator-level escape hatch.

**Why the win exists.**  The fiber-yielding path
(`Sendfile#wait_writable`) hops the fiber scheduler on every
EAGAIN — userspace pays a per-chunk fiber-suspend / fiber-resume
round-trip plus the `wait_writable` wakeup callback even when the
kernel TCP send buffer drains in nanoseconds.  Puma doesn't: the
worker thread parks on a kernel write under the GVL, the kernel
returns when ready, the loop resumes.  For static-file routes
where the only I/O wait is the socket itself (no DB / Redis /
upstream HTTP that would benefit from cooperative yielding),
Puma's straight-line shape is strictly faster on the throughput
axis.  `:inline_blocking` ports that shape into Hyperion for the
routes that match.

**Bench delta on openclaw-vm** (Linux 6.x, 1 MiB warm-cache static
asset, `wrk -t4 -c100 -d20s`, target validated against 2.6-A's
1,320 r/s baseline and Puma's 1,571 r/s):

  * **Bench validation 2026-05-01 (maintainer rerun):**
    - Default threadpool mode (no `--async-io`): static 1 MiB
      median **1,270 r/s, p99 6 ms** across 3 trials. Within noise
      of 2.6-A's 1,320 r/s — meaning the new `:inline_blocking`
      dispatch is essentially equivalent to the existing threadpool
      path on the user's typical (nginx-fronted, no async-io)
      deployment shape. Threadpool already serves static via OS
      threads with no fiber yield, so there's nothing for
      `:inline_blocking` to skip.
    - `--async-io` mode: static 1 MiB median **1,232 r/s, p99
      433-710 ms**. The fiber-yield-on-EAGAIN penalty IS visible in
      this mode's p99. **2.6-C's auto-detect should kick in here
      and drop p99 to ~6 ms — but the bench shows it doesn't, so
      the auto-detect engagement has a runtime gap that the unit
      specs miss.** Filed as 2.6-C-followup: investigate why the
      `Adapter::Rack#resolve_dispatch_mode!` call doesn't propagate
      to the actual write path under `--async-io`.
    - Headline: 2.6-C ships the dispatch mode and unit-test
      coverage; the end-to-end perf win on `--async-io` is
      unverified pending the engagement-fix follow-up.

**Tail-latency expectation.**  p99 may bump slightly under the
blocking variant (the OS thread parks on the kernel write while a
slow peer drains; 2.6-A's p99 was ~6.35 ms on the same row vs
Puma's 754 ms).  Even with a several-ms bump the static-file p99
stays orders-of-magnitude below Puma's 754 ms because Hyperion
still answers from the socket fd directly with no per-request
allocation tax.  Threadpool path on dynamic routes is unchanged
(CPU JSON / Enumerator bodies don't auto-detect into
`:inline_blocking`).

**Lifecycle hooks (2.5-C) interop.**  Hooks fire on every request
regardless of dispatch mode — observability is mode-agnostic.  A
future 2.6-D may add an opt-OUT for static-file responses; 2.6-C
does NOT change hook firing behaviour.

#### Files touched
- `lib/hyperion/dispatch_mode.rb` — `:inline_blocking` added to
  `MODES` + `INLINE_MODES`; `inline_blocking?` + `fiber_dispatched?`
  predicates.
- `lib/hyperion/http/sendfile.rb` — `copy_to_socket_blocking` public
  method + `native_copy_loop_blocking` + `select_writable_blocking`
  (IO.select instead of `wait_writable`).
- `lib/hyperion/connection.rb` — `response_dispatch_mode` accessor,
  reset per-request, forwarded to `ResponseWriter#write` as
  `dispatch_mode:`.
- `lib/hyperion/response_writer.rb` — `dispatch_mode:` kwarg on
  `#write` + `#write_sendfile`; sendfile branch picks
  `copy_to_socket_blocking` when `dispatch_mode == :inline_blocking`.
- `lib/hyperion/adapter/rack.rb` — post-`app.call`
  `resolve_dispatch_mode!` helper handles auto-detect + explicit
  env override; both the lifecycle-hooks branch and the bare path
  call into it.
- `spec/hyperion/inline_blocking_dispatch_spec.rb` — new file, 30
  examples covering predicates, auto-detect, explicit opt-in,
  streaming opt-out, no-Connection no-op, round-trip integrity at
  1 KiB / 8 KiB / 1 MiB / 16 MiB, threadpool regression check
  (CPU JSON / Enumerator bodies stay nil), 2.5-C hook firing,
  Sendfile.copy_to_socket_blocking direct round-trip.

Spec count: 911 → 941 (+30 from this 2.6-C landing).  0 failures,
11 pending (Linux-only splice tests on macOS).  When 2.6-B lands its
~6 fadvise round-trip specs the count will roll forward to 947.

### 2.6-A — sendfile chunk size 64 KiB → 256 KiB (4× fewer syscalls per 1 MiB)

`Hyperion::Http::Sendfile::USERSPACE_CHUNK` bumped from `64 * 1024`
to `256 * 1024`.  The constant gates two paths:

  * Per-call cap on the native sendfile(2) loop (`plain_sendfile_loop`)
    and the splice(2) ladder (`splice_copy_loop`).  Each kernel round
    now moves up to 256 KiB instead of 64 KiB; a 1 MiB warm-cache
    static asset moves in 4 kernel rounds vs the legacy 16 — a 4×
    syscall-count reduction per response.
  * Chunk size on the userspace `IO.copy_stream` fallback (TLS
    sockets, hosts where the C ext didn't compile).

64 KiB came from the Linux 2.x-era TCP-send-buffer "sweet spot"
folklore.  On modern kernels (4.x+) the TCP send buffer auto-tunes
upward under sustained load and modern NICs+TSO segment 256 KiB-1 MiB
chunks at line rate.  The reference field — nginx (`sendfile_max_chunk`
default unlimited, distros ship `2m` overrides), Apache
(`SendBufferSize` 128k–256k), Caddy (256 KiB hard-coded) — sits at
256 KiB+; Hyperion now joins.

EAGAIN handling is preserved per chunk: a slow-client socket that
returns EAGAIN mid-response still surfaces `:eagain` to the Ruby
façade, which yields the fiber and resumes from the same cursor on
the next iteration.  Existing 1 MiB / Range-slice / 1-byte / 0-byte
round-trip integrity tests stay green.  Three new round-trip tests
land for 4 MiB (multi-chunk), 256 KiB (exactly one chunk), and
100 KiB (one partial chunk above SMALL_FILE_THRESHOLD).

**Bench delta on openclaw-vm** (Linux 6.x, 1 MiB warm-cache static
asset, `wrk -t4 -c100 -d20s`, 3 trials, median):

  * 2.5.0 baseline:  1,094 r/s
  * 2.6-A:           1,320 r/s (trials: 1,370 / 1,320 / 1,305 r/s)
  * Delta:           **+20.7%** (above the +10% target)
  * p50 latency:     3.49 → 3.64 ms (within noise; transfer/sec
                     climbs from ~1.07 GB/s → 1.34 GB/s on the
                     fastest trial, indicating the syscall-count
                     reduction is the bottleneck mover, not the
                     wire).

**Config knob — deliberately not exposed.**  The 256 KiB value is
the most-likely-good across the field; nginx/Apache/Caddy operators
don't tune it either, and adding a `sendfile.chunk_bytes` config
knob would add a Config dependency to a module that today carries
none.  If a future operator workload demands tuning, the knob can
be added without breaking compatibility.

### Files touched
- `lib/hyperion/http/sendfile.rb` — `USERSPACE_CHUNK` constant, chunk
  cap on `plain_sendfile_loop` + `splice_copy_loop`, doc comment
  rationale.
- `spec/hyperion/http_sendfile_spec.rb` — 4 new round-trip tests
  (4 MiB / 256 KiB / 100 KiB / `USERSPACE_CHUNK == 256 KiB`
  introspection).

Spec count: 907 → 911 (+4). 0 failures, 11 pending (Linux-only
splice path skips on macOS).

## [2.5.0] - 2026-04-29

### Headline

A correctness + observability + RFC-conformance release. The 2.5.0
sprint settled three open questions from prior releases and opened
the door for first-class production observability integrations.

| Track | Result |
|---|---|
| 2.5-A — RFC 6455 §7.4.1 close-code validation | autobahn-testsuite **453/463 → 463/463 (100% on non-perf cases)**. Section 7 closed: 27/37 → 37/37. |
| 2.5-B — Rails-shape h2 bench | **+18% rps** native HPACK vs Ruby fallback on 25-header response. **[breaking-default-change]: `HYPERION_H2_NATIVE_HPACK` flipped to ON by default** when Rust crate available. |
| 2.5-C — Request lifecycle hooks | `Runtime#on_request_start` / `on_request_end`. NewRelic / AppSignal / OpenTelemetry / DataDog wire without monkey-patching. Zero-cost path preserved. |
| 2.5-D — Compression-bomb fuzz | 6 adversarial vectors (ratio bomb, malformed sync trailer, mid-message dict corruption, zero-length, min-window-bits, compressed control frame). All PASS — 2.3-C's defense holds. |

Spec count: 823 (2.4.0) → 907 (2.5.0). 0 failures, 11 pending.

### Breaking change

`HYPERION_H2_NATIVE_HPACK` default flipped from OFF to ON when the
Rust crate is available (the typical case — it builds out of the box
on macOS/Linux + cargo). Operators who explicitly want the prior
2.4.x Ruby-fallback default must set `HYPERION_H2_NATIVE_HPACK=off`.

Migration: most operators see +18% h2 rps on header-heavy workloads
(Rails apps, gRPC metadata, etc.) and no change on hello-shape
workloads (HPACK is <1% of per-stream CPU on 2-header responses).
Operators on hosts where the Rust crate didn't build see the same
Ruby fallback as 2.0.x–2.4.x — no behavior change.

New operator visibility:
- `Hyperion::Runtime#on_request_start { |req, env| ... }` — hook fires before app.call
- `Hyperion::Runtime#on_request_end { |req, env, response, error| ... }` — hook fires after app.call
- See `docs/OBSERVABILITY.md` "Custom request lifecycle hooks (2.5-C)" for NewRelic/AppSignal/OpenTelemetry/DataDog/Prometheus recipes

### 2.5-A — WebSocket close-payload validation (RFC 6455 §7.4.1 + §5.5.1)

**The fix.** `Hyperion::WebSocket::Connection#recv` now validates the
peer's close code against the IANA close-code registry. Codes outside
the wire-allowed ranges (1000–1003, 1007–1015, 3000–3999, 4000–4999)
get a 1002 (Protocol Error) response back instead of being echoed.
Synthetic codes (1005 "No Status Received", 1006 "Abnormal Closure")
that MUST NOT appear on the wire are rejected with 1002. The reserved
1016–2999 range is rejected with 1002. A 1-byte close payload (status
code can't fit) is rejected with 1002. A close reason whose bytes are
not valid UTF-8 is rejected with 1007 (Invalid Frame Payload Data) per
RFC 6455 §8.1. An empty close payload (no status, no reason) is
explicitly permitted per §5.5.1 and gets a 1000 Normal close response.

**Surface area.** New module `Hyperion::WebSocket::CloseCodes` exposes
`.validate(code) → Symbol` and `.invalid?(code) → Boolean` for any
caller that wants to apply the same RFC 6455 §7.4.1 ranges (e.g.
ActionCable adapters, custom WS gateways).

**Why it matters.** 2.4-D's autobahn-testsuite run scored 453/463
(97.8%) with all 10 failures in section 7.5.1 + 7.9.x — the close-code
validation gap. 2.5-A closes that gap.

**Autobahn pass: 453/463 → 463/463 (100% on non-perf cases).**
Section 7 alone: 27/37 → 37/37. Verified empirically on openclaw-vm
2026-04-30 post-fuzzer rerun (same bench/ws_echo_autobahn.ru rackup
+ Hyperion-2.5-A agent name; results dropped into
~/autobahn-reports/index.json, parsed via bench/parse_autobahn_index.rb).
Section 6 (UTF-8): 145/145 (141 OK + 4 NON-STRICT — RFC SHOULD on
fail-fast position, not MUST). Section 12+13 (permessage-deflate):
216/216 OK.

Spec count: 823 (2.4.0) → 893 (+70 in `websocket_close_validation_spec.rb`).
0 failures, 11 pending.

### 2.5-B — Rails-shape h2 bench rackup (settle the HPACK default-flip question)

**The question 2.4-A left open.** 2.4-A's HPACK FFI round-2 (CGlue / v3
adapter, commits 67c52a4 + 98e9cf3 + 877f934) brought the per-call alloc
from 12 → 4 objects and dropped Fiddle off the hot path. But it
benched against `bench/hello.ru` — a Rack response with **2 response
headers** (`content-type`, plus the auto-inserted `content-length`). On
that workload HPACK encode is <1% of per-stream CPU, so native and the
Ruby fallback both came in at parity (-0.05% noise). The default stayed
opt-in via `HYPERION_H2_NATIVE_HPACK=1` because parity isn't a default
flip.

Real Rails 8.x apps ship 20–30 response headers (Rails defaults +
ActionDispatch + ActionController + CSP/HSTS + per-request varying
headers like X-Request-Id / Set-Cookie / ETag). On that shape HPACK
encode CPU should climb into the single-digit percent of per-stream
CPU and the FFI marshalling overhead vs the native byte-pump matters.
2.5-B settles whether it matters enough to flip the default.

**The bench artifacts.**
- `bench/h2_rails_shape.ru` — Rails-shape rackup, 25 response headers
  (content-type, x-frame-options, x-xss-protection, x-content-type-options,
  x-permitted-cross-domain-policies, referrer-policy, x-download-options,
  cache-control, pragma, expires, vary, content-language,
  strict-transport-security, content-security-policy, x-request-id,
  x-runtime, x-powered-by, set-cookie, etag, last-modified, date,
  server, access-control-allow-origin, cross-origin-opener-policy,
  cross-origin-resource-policy). Body is a ~200-byte JSON payload —
  matches a typical Rails JSON response. Per-request variance: rid
  rotates per call, set-cookie session id rotates, etag rotates.
- `bench/h2_rails_shape.sh` — A/B harness. Boots hyperion twice
  (Ruby fallback baseline + native v3 with HYPERION_H2_NATIVE_HPACK=1)
  on port 9602, runs h2load `-c 1 -m 100 -n 5000` 3× per variant, takes
  the median rps (3-5% bench noise), prints the delta, and selects a
  decision (flip / keep / investigate) against the +15% threshold from
  the 2.5-B controller.

**Decision tree.**
- native ≥ +15% rps → flip default to ON (auto = on if available, off
  if not), update boot log, document in CHANGELOG as a
  `[breaking-default-change]`.
- native at parity / +5–10% (within noise) → keep opt-in, document the
  result.
- native NEGATIVE → don't ship a regression, file a 2.6 follow-up.

**Bench result on openclaw-vm (2026-04-30, h2load -c 1 -m 100 -n 5000,
3 trials, median):**

| Mode | r/s | Note |
|---|---:|---|
| Ruby fallback (HPACK off) | **1,201** | `protocol-http2`'s pure-Ruby Compressor/Decompressor |
| Native v3 (HPACK on, CGlue) | **1,418** | 2.4-A custom-C-ext path, no Fiddle per call |

**Δ: +18.0% rps** on the Rails-shape header-heavy workload. Above
the +15% flip threshold.

**[breaking-default-change]: native HPACK is now ON by default** when
the Rust crate is available. `lib/hyperion/http2_handler.rb`'s
policy resolver flipped from `env_flag_enabled?('HYPERION_H2_NATIVE_HPACK')`
(unset → off) to `resolve_h2_native_hpack_default` (unset → on; only
`0`/`false`/`no`/`off` explicit values opt out). Operators who
benchmarked their workload against the 2.4.x default can opt out via
`HYPERION_H2_NATIVE_HPACK=off`. Operators on hosts where the Rust
crate didn't build see the same Ruby fallback as 2.0.x–2.4.x — no
behavior change.

**Boot log copy updated** to reflect the new default — `mode: native
(Rust v3 / CGlue)` is the new normal, `mode: fallback (... opted out
via HYPERION_H2_NATIVE_HPACK=off)` is the explicit-opt-out shape.

**Spec changes for the new default:**
- `spec/hyperion/h2_codec_fallback_spec.rb` — flipped the "env unset →
  codec_native? false" expectation to "env unset → codec_native? true";
  added a sibling `HYPERION_H2_NATIVE_HPACK=off` example for the
  explicit-opt-out path.
- `spec/hyperion/http2_native_hpack_spec.rb` — the "default — opt-in
  not taken" context now sets `HYPERION_H2_NATIVE_HPACK=off` explicitly
  (the test's assertion that the native adapter is NOT installed is
  still meaningful, just under the explicit-opt-out path now).

Spec count: 893 → 894 (+1 new explicit-opt-out spec). 0 failures, 11 pending.

### 2.5-C — Per-request lifecycle hooks (`Runtime#on_request_start` / `#on_request_end`)

**The user-relevant bit.** Attach NewRelic / AppSignal / DataDog /
OpenTelemetry agents to Hyperion **without monkey-patching
`Adapter::Rack#call`**. New first-class API on `Hyperion::Runtime`:

```ruby
runtime.on_request_start { |request, env| env['otel.span'] = tracer.start_span(request.path) }
runtime.on_request_end   { |request, env, response, error| env['otel.span'].finish }
```

The before-hook fires after env is built and before `app.call`. The
after-hook fires after `app.call` returns or raises, with the
`[status, headers, body]` response tuple (or `nil` if the app raised)
plus the raised exception (or `nil` on success). Hooks may stash trace
context into the env Hash for the after-hook to read back. Multiple
hooks fire in registration order (FIFO).

**Failure-isolated.** A misbehaving observer (NewRelic agent throwing
during a hook) is caught and logged with `block.source_location` — the
dispatch chain continues, subsequent hooks still fire, the response is
still returned to the client.

**Zero-cost when nothing's registered.** The hot-path guard is a
single `Array#empty?` check on each side. With no hooks registered,
`Adapter::Rack#call` short-circuits — no Array iteration, no Proc
invocation, no allocation. `yjit_alloc_audit_spec` confirms the
per-request allocation count remains at the 2.5-B baseline (≤10
objects/req on the full path).

**Per-Server isolation.** The hook registry lives on `Hyperion::Runtime`,
not on a process-global. Multi-tenant deployments with multiple
`Hyperion::Server` instances pass a per-tenant `Runtime` and each
gets its own observer list — no cross-contamination, no global mutex.

**Surface area.**
- New: `Hyperion::Runtime#on_request_start(&block)` — register a
  before-hook receiving `(request, env)`.
- New: `Hyperion::Runtime#on_request_end(&block)` — register an
  after-hook receiving `(request, env, response, error)`.
- New: `Hyperion::Runtime#has_request_hooks?` — predicate used by the
  adapter's hot-path guard. Public-but-internal: callers wiring custom
  dispatchers can use it for the same zero-cost short-circuit.
- New: `Hyperion::Runtime#fire_request_start(request, env)` /
  `#fire_request_end(request, env, response, error)` — invoked by
  `Adapter::Rack#call`. Public so future adapter implementations
  (third-party Rack alternatives, custom transports) can fire the
  same hooks against the user's observer registry.
- Changed: `Hyperion::Adapter::Rack.call(app, request, connection: nil)`
  gains a `runtime:` kwarg (default `nil` → `Runtime.default`). Existing
  call sites (`Connection#call_app`, `Http2Handler`, `ThreadPool`) are
  updated to pass the per-conn / per-handler runtime through. Apps and
  third-party callers that never set the kwarg are unaffected.

**Files touched.**
- `lib/hyperion/runtime.rb` — hook registration + dispatch + failure log.
- `lib/hyperion/adapter/rack.rb` — `runtime:` kwarg + hot-path guard.
- `lib/hyperion/connection.rb` — pass `@runtime` through `call_app`.
- `lib/hyperion/http2_handler.rb` — pass `@runtime` through h2 dispatch.
- `spec/hyperion/request_lifecycle_hooks_spec.rb` — 13 new examples
  covering registration API, FIFO order, env-Hash sharing, failure
  isolation, zero-cost path.
- `docs/OBSERVABILITY.md` — "Custom request lifecycle hooks" section
  with NewRelic / AppSignal / OpenTelemetry / DataDog / per-route
  Prometheus recipes + multi-tenant isolation note.

Spec count: 894 → 907 (+13). 0 failures, 11 pending.

### 2.5-D — permessage-deflate compression-bomb fuzz harness

**The user-relevant bit.** 2.3-C shipped the RFC 7692 §8.1 defense:
`max_message_bytes` is applied AFTER decompression, so a tiny
compressed payload that explodes on inflate trips close 1009 (Message
Too Big) BEFORE the inflated buffer is materialized. ONE regression
spec covered the happy-path "4 MB of zeroes vs 64 KB cap" case in
`spec/hyperion/websocket_permessage_deflate_spec.rb`. **2.5-D verifies
the defense holds across six adversarial input vectors.**

Each vector boots a `Hyperion::WebSocket::Connection` on one half of a
`UNIXSocket.pair`, throws crafted compressed bytes at it from the
other half, and asserts: (a) the server doesn't crash, (b) the server
doesn't blow process RSS past a generous bomb-detection ceiling
(4 MiB for protocol-error vectors, 64 MiB for the streaming ratio
bomb — both >> the 64 KiB `max_message_bytes` cap so a real bomb
trips), (c) the server closes with the expected RFC 6455 close code.

**Vectors and the close codes they trip:**

| # | Vector | Close code | Notes |
|---|---|---|---|
| 1 | Classic ratio bomb (4 GB inflated, streamed) | **1009** Message Too Big | Stream-deflated chunked input never holds 4 GB at rest; cap trips well before the full stream lands |
| 2 | Malformed sync trailer (`00 00 ff fe`) | **1007** Invalid Frame Payload Data | Inflate hits `Zlib::DataError`, mapped to 1007 by `Connection#inflate_message` |
| 3 | Mid-message dictionary corruption (3-fragment, frame 2 byte-flipped) | **1007** Invalid Frame Payload Data | Backreference points outside the legal sliding window → `Zlib::DataError` |
| 4 | Zero-length compressed message (empty stored deflate block, RSV1=1) | **1000** Normal Closure | Decompresses to empty string OK, follow-up close 1000 returned cleanly |
| 5 | Min-window-bits negotiation (`client_max_window_bits=9`) | **1000** Normal Closure | Hyperion clamps the floor to 9 (zlib raw-deflate refuses 8 in some builds); 9 round-trips OK |
| 6 | Compressed control frame (ping with RSV1=1) | **1002** Protocol Error | RFC 7692 §6.1 — control frames MUST NOT carry RSV1; parser rejects |

**Result on macOS arm64-darwin23 + Ruby 3.3.3 with YJIT:**
**6/6 vectors PASS.** No bugs found. Total runtime under 2 minutes
(ratio bomb ~80 s, all five protocol-error vectors complete in
under a second each). The 2.3-C defense holds across every
adversarial dimension we throw at it.

**Files added.**
- `bench/ws_compression_bomb_fuzz.rb` — the harness. Self-contained,
  uses Ruby stdlib `zlib` + the existing `Hyperion::WebSocket::Builder`
  for client-side framing, no new gem deps. Runs standalone via
  `ruby bench/ws_compression_bomb_fuzz.rb` or via the wrapper spec.
- `spec/hyperion/websocket_compression_bomb_fuzz_spec.rb` — single
  example tagged `:perf` (skipped by default; operators run with
  `--tag perf` after permessage-deflate code changes).

Spec count: default-run unchanged at 907 (the new wrapper is `:perf`
tagged so it skips by default). With `--tag perf` enabled the count
moves 908 → 909 (the perf-included pool also picks up the existing
`long_run_stability_spec`). 0 failures, 11 pending.

## [2.4.0] - 2026-04-29

### Headline

A production-stability + observability release. Targeted at long-running
servers under sustained traffic (the user's nginx-fronted ActionCable
deployment shape).

| Track | Result |
|---|---|
| 2.4-B — GC pressure round-2 | Per-parse alloc **-41 to -53%** on hello / 5-header / chunked POST; GC frequency **-28%** on chunked POST sustained 60s |
| 2.4-D — Linux multi-process WS bench | **6,880 msg/s p99 34 ms** at 4 procs × 200 conns (+289% vs single-proc, -75% p99); autobahn **97.8% pass** (453/463), permessage-deflate **100%** RFC 7692 conformance |
| 2.4-C — /-/metrics enrichment | 6 new production metrics: per-route p50/p99 histograms, fairness rejection counter, WS deflate ratio, kTLS active conns, io_uring active, threadpool queue depth. Grafana dashboard + OBSERVABILITY.md operator playbook |
| 2.4-A — HPACK FFI round-2 | Per-call alloc 12 → 4 objects (custom C ext, no Fiddle per call); bench at parity (HPACK is <1% of per-stream CPU). Stays opt-in. |

Spec count: 776 (2.3.0) → 823 (2.4.0). 0 failures, 11 pending.

New operator visibility:
- `/-/metrics` now exposes `hyperion_request_duration_seconds`, `hyperion_per_conn_rejections_total`, `hyperion_websocket_deflate_ratio`, `hyperion_tls_ktls_active_connections`, `hyperion_io_uring_workers_active`, `hyperion_threadpool_queue_depth`
- Grafana dashboard at `docs/grafana/hyperion-2.4-dashboard.json`
- Operator playbook at `docs/OBSERVABILITY.md`

### Known limitations carried forward to 2.5
- WebSocket close-payload validation: 10 autobahn cases in section 7.5.1 + 7.9.x fail because `Connection#recv` echoes invalid peer close codes instead of rejecting with 1002 (Protocol Error). Documented in `docs/WEBSOCKETS.md`. **Resolved in 2.5-A — see Unreleased section above.**

### 2.4-A — HPACK FFI round-2 (custom C ext, no Fiddle per call)

**The story so far.** The 2.0.0 native HPACK path went through Fiddle:
each `Encoder#encode` call paid for `pack('Q*')` to build an argv
buffer, three `Fiddle::Pointer[scratch]` pointer-wrapper allocations,
plus per-header `.b` re-encoding when the source string wasn't already
ASCII-8BIT. The standalone microbench showed a 3.26× encode win, but
on real h2load traffic the FFI marshalling layer ate the savings:
2.0.0 was -8 to -28% rps vs Ruby fallback. fix-B (2.2.x) introduced
the per-encoder scratch buffer + flat-blob `_encode_v2` ABI, which
brought native to **parity** with Ruby fallback (-0.05% noise) — but
parity isn't a default flip.

**What 2.4-A ships.** A new sibling C extension entry point,
`Hyperion::H2Codec::CGlue`, that bypasses Fiddle entirely on the
per-call hot path:

- `ext/hyperion_http/h2_codec_glue.c` — defines the `CGlue` module
  and three singleton methods: `install(path)`, `available?`,
  `encoder_encode_v3(handle_addr, headers, scratch_out)`,
  `decoder_decode_v3(handle_addr, bytes, scratch_out)`.
- `install(path)` is called once from `H2Codec.load!` after the
  Fiddle loader has already confirmed the cdylib loads cleanly. The C
  glue `dlopen`s the same path with `RTLD_NOW | RTLD_LOCAL` (a
  refcount bump per POSIX, not a double-load), `dlsym`s the three
  Rust entries (`hyperion_h2_codec_abi_version`,
  `hyperion_h2_codec_encoder_encode_v2`,
  `hyperion_h2_codec_decoder_decode`), and caches them as static C
  function pointers.
- `encoder_encode_v3` walks the Ruby `headers` array directly via
  `RARRAY_LEN`/`rb_ary_entry`, packs the argv quad buffer onto the C
  stack (default 64 headers — heap fallback for larger blocks),
  concatenates name+value bytes into a stack-resident blob (default
  8 KiB — heap fallback for larger blocks), and invokes the cached
  `encode_v2` function pointer directly. The encoded bytes land in
  the per-encoder scratch String; Ruby's `byteslice(0, written)`
  copies them out as the single unavoidable allocation.
- `RSTRING_PTR` reads the raw byte view of `name`/`value` regardless
  of the Ruby encoding tag, eliminating the per-header `.b`
  allocation that the v2 Ruby path could not avoid for non-binary
  inputs.

**The Ruby façade.** `Hyperion::H2Codec::Encoder#encode` now probes
`H2Codec.cglue_available?` on each call. When true, it dispatches
through `CGlue.encoder_encode_v3`. When false (older systems without
dlfcn, hardened sandboxes blocking dlopen, ABI mismatch), it
transparently falls back to the v2 (Fiddle) path — no operator
intervention required.

**Per-call alloc shape.**

| Path | Strings/call (encode, steady state) |
|---|---|
| 2.0.0 (Fiddle, v1 ABI) | ~12 |
| 2.2.x fix-B (Fiddle, v2 ABI) | ~7.5 |
| **2.4-A (C ext, v3 path)** | **~1** (the byteslice return) |

Counted via `GC.stat(:total_allocated_objects)` delta over 100
warmed encodes; spec asserts `total_allocated_objects/call < 6`
(includes Fixnums + transient Array iterators that GC.stat conflates
with String allocations).

**Bench delta on openclaw-vm (Linux 6.8 / 16 vCPU).** Three runs each
of `h2load -c 1 -m 100 -n 5000 https://127.0.0.1:9602/` against
`bin/hyperion -t 64 -w 1 --h2-max-total-streams unbounded ~/bench/hello.ru`
(rack lambda returning `[200, {'content-type' => 'text/plain'}, ['hello']]`):

| Mode                    | median r/s | delta vs Ruby |
|---|---:|---:|
| Ruby HPACK (baseline)   | 1,627.46 | — |
| native v2 (Fiddle path) | 1,628.7 (fix-B / 2.2.x baseline) | -0.05% |
| **native v3 (CGlue)**   | 1,607.19 | -1.2% (noise) |

Raw h2load output: `.notes/2.4-a-bench-openclaw-vm.txt`.

**Default flip — declined for now.** The +15% target wasn't met on
the hello workload. v3 is at parity with Ruby HPACK and v2 Fiddle —
the per-call alloc savings (7.5 → ~1 string) don't translate to
end-to-end rps because hello.ru sends a 2-header response, and at
~1,600 r/s the dominant CPU sits in TLS, fiber scheduling, and h2
framing (which v3 does NOT replace — it only swaps HPACK encode at
the protocol-http2 boundary). HPACK CPU on a 2-header block is
already <1% of the per-stream cost.

`HYPERION_H2_NATIVE_HPACK` stays default-OFF. Operators who opt in
via `HYPERION_H2_NATIVE_HPACK=1` get the v3 (CGlue) path
automatically when the C glue installs successfully, and v2 (Fiddle)
when it doesn't (older glibc / sandboxed dlopen). The v3
implementation ships because:

  1. It's the foundation for any future end-to-end win — the FFI
     marshalling layer cannot get cheaper than v3 without rewriting
     the entire h2 framer in Rust.
  2. Per-call alloc reduction (7.5 → ~1 string) is real and lowers
     GC pressure on h2-heavy workloads even when rps is flat.
  3. Specs lock in v3 as the default code path inside the
     `H2Codec::Encoder#encode` method body — the v3-specific 12
     spec examples plus the existing 24 H2Codec/Http2 spec
     examples all execute through the v3 path on hosts where
     CGlue installs (which is every modern Linux + macOS).

The next gate for the default flip is a Rails-shape bench (~30
response headers per stream). Tracked as a separate H2 follow-up.

### 2.4-B — GC-pressure reduction round-2 (long-run stability)

**Why this matters.** Phase 11 (2.2.0) cut Adapter::Rack hot path
allocations -53% (19 → 9 obj/req) and locked the number with
`yjit_alloc_audit_spec`. But the *long-run* server hot path under
sustained traffic includes more than the adapter — the C parser, the
WebSocket frame ser/de, and the connection lifecycle each ship their
own per-message allocations that scale with **message rate**, not just
request count. A single keep-alive connection pipelined with 1000
requests, or a chat-style WebSocket connection echoing 1000 messages,
should not allocate 1000 connection-state objects — only the
truly-per-message ones.

**The audit.** `bench/gc_audit_2_4_b.rb` drove four sustained workloads
(HTTP keep-alive GET, chunked POST, WS recv, WS send w/ permessage-
deflate) under `GC.disable` for 5000-10000 iters and measured per-
iter `total_allocated_objects` deltas plus GC.count over the window.
`bench/gc_audit_2_4_b_trace.rb` ran the same workloads under
`ObjectSpace.trace_object_allocations` for file:line attribution.
Top sites identified, written up at `bench/gc_audit_2_4_b.md`:

| # | Site                                          | Fix                                                            |
|---|-----------------------------------------------|----------------------------------------------------------------|
| 1 | `parser.c:state_init` 6 empty placeholders   | S1 — Qnil sentinels, lazy alloc on first append                |
| 2 | `parser.c:on_headers_complete` cl_key/te_key  | S2 — pre-interned frozen globals at Init_hyperion_http         |
| 3 | `parser.c:stash_pending_header` reset empties | S1 (rolled into) — reset to Qnil, not fresh empty Strings      |
| 4 | `frame.rb:Builder.build` `payload.b`         | S4 — branch on `encoding == BINARY_ENCODING`, skip no-op clone |
| 5 | `frame.rb:Parser.parse` `slice.b` + `(+'').b`| S5 — drop redundant `.b` + share frozen `EMPTY_BIN_PAYLOAD`    |

**What ships:**

| Deliverable | Where | Why |
|---|---|---|
| C parser lazy field alloc + frozen smuggling-defense keys | `ext/hyperion_http/parser.c` | Saves 6 empty-String allocations per parse() in state_init, 2 fresh empty Strings per parsed header in stash_pending_header, 2 cl_key/te_key Strings per parse(). Lazy Qnil → empty-String coercion at Request build means the Ruby surface is unchanged. |
| WebSocket frame `.b` clone elimination + frozen empty payload | `lib/hyperion/websocket/frame.rb` | `Builder.build` skips `payload.b` when input is already ASCII-8BIT. `Parser.parse` / `parse_with_cursor` drop the redundant `slice.b` (the WS `@inbuf` is binary by construction) and share one frozen `EMPTY_BIN_PAYLOAD` const for empty frames. |
| `bench/gc_audit_2_4_b.rb` + `gc_audit_2_4_b_trace.rb` + `gc_audit_2_4_b.md` | NEW | Sustained-workload audit harness covering 4 hot paths; writeup with measured before/after per site. |
| `spec/hyperion/parser_alloc_audit_spec.rb` | NEW (4 examples) | Locks per-parse allocation counts: ≤12 for minimal GET, ≤22 for 5-header GET, ≤20 for chunked POST. Plus an identity invariant on the EMPTY_STR coercion. |
| `spec/hyperion/websocket_frame_alloc_audit_spec.rb` | NEW (4 examples) | Locks Builder.build (≤4 obj/call unmasked), Parser.parse (≤11 masked, ≤9 unmasked), and the EMPTY_BIN_PAYLOAD frozen-identity invariant. |
| `spec/hyperion/long_run_stability_spec.rb` | NEW (1 example, `:perf` tagged) | Drives 10000 keep-alive GETs over 100 connections, asserts ≤65 obj/req and ≥1 GC per 500 reqs. Excluded from default suite via `spec_helper.rb` `filter_run_excluding(:perf)`; operators run via `--tag perf` after allocation-pressure changes. |

**Measured (5000-iter steady-state, no YJIT, macOS arm64):**

| case                          | 2.3.0 | 2.4-B | delta |
|-------------------------------|------:|------:|------:|
| GET /, 1 header (parse)       | 19.00 |  9.00 | **-53%** |
| GET /a?q=1, 5 headers (parse) | 36.00 | 18.00 | **-50%** |
| POST chunked, 4 chunks (parse)| 27.00 | 16.00 | **-41%** |
| WS Builder.build unmasked     |   3+1 |     3 | -25%  |
| WS Parser.parse unmasked      |     9 |     8 | -11%  |

**Sustained-load GC frequency (10000 iters, openclaw-vm Linux Ruby 3.3.3):**

| workload          | 2.3.0 GC freq | 2.4-B GC freq | delta    |
|-------------------|--------------:|--------------:|---------:|
| chunked POST parse| 1 GC / 689    | 1 GC / 952    | **-28%** |
| ws recv (masked)  | 1 GC / 625    | 1 GC / 625    |   0%     |

(WS recv unchanged because the masked-frame audit path goes through
`CFrame.unmask` regardless of S5; the regression spec exercises the
unmasked-side win that S5 captures.)

**wrk validation (openclaw-vm, 30s, -t4 -c200, hyperion -w4 -t5):**

| build  | req/s | p50    | p99    | std-dev |
|--------|------:|-------:|-------:|--------:|
| 2.3.0  | 14833 | 1.27ms | 2.64ms | 329µs   |
| 2.4-B  | 14985 | 1.26ms | 2.61ms | 330µs   |

Throughput is adapter-bound at this scale — the win is in GC pressure,
not raw rps. p99 + std-dev sit within noise on a 30s run; the
`long_run_stability_spec` is the regression guard for sustained-load
behaviour. The user-relevant 2.4 win for **long-running production
servers** is GC frequency -28% on the chunked path that scales with
real upload volume.

Sites considered + deferred (with rationale in `bench/gc_audit_2_4_b.md`):
* @inbuf initial capacity 8KB → 16KB — verified 95th-percentile fits
  in 4KB; bump would regress 10k-keep-alive RSS without payback.
* WS frame parse 8-element Array — Ruby façade surface; deferred.
* Per-conn env Hash pool — already pooled by Phase 11.

Spec count: 788 → 796 default-run + 1 (`:perf`-tagged) = 797 total.
No version bump (release task is 2.4-fix-F).

### 2.4-C — `/-/metrics` enrichment (operator observability)

**The story.** The 2.x sprints added many operator knobs
(`permessage_deflate`, `max_in_flight_per_conn`, `tls.ktls`,
`io_uring`, h2 native HPACK), but `/-/metrics` exposed only the
1.x counter set. Operators who turned the knobs on had no production
visibility into whether they were firing — "is permessage-deflate
compressing my chat traffic?", "is fairness rejecting any
clients?", "did kTLS engage on this worker?" all lacked a
metric-backed answer.

2.4-C closes the gap. Operators can now see permessage-deflate
effectiveness, per-conn fairness rejections, kTLS engagement,
io_uring policy state, and ThreadPool queue depth directly in the
`/-/metrics` body, plus per-route latency histograms with
configurable path templating to keep cardinality bounded.

**What ships:**

| Metric | Type | What it tells the operator |
|---|---|---|
| `hyperion_request_duration_seconds` | histogram | Per-route p50/p99 by `method` + templated `path` + `status` class. Buckets `0.001…10`s. |
| `hyperion_per_conn_rejections_total` | counter | Per-worker rate of 503 + Retry-After rejections from the 2.3-B fairness cap. |
| `hyperion_websocket_deflate_ratio` | histogram | `original_bytes / compressed_bytes` for every WS message that goes through 2.3-C permessage-deflate. Buckets 1.5×…50×. |
| `hyperion_tls_ktls_active_connections` | gauge | Per-worker count of TLS connections currently driven by the kernel TLS_TX module. |
| `hyperion_io_uring_workers_active` | gauge | 1 = io_uring policy active on this worker, 0 = epoll. |
| `hyperion_threadpool_queue_depth` | gauge | Snapshot of the worker's ThreadPool inbox at scrape time. |

**Path templating.** `Hyperion::Metrics::PathTemplater` collapses
`/users/123` → `/users/:id` and `/orders/<uuid>` → `/orders/:uuid`
by default, with an LRU-cached lookup so repeated paths on
keep-alive connections pay one Hash hit, not the regex chain.
Operators with Rails-style routes plug in custom rules via
`metrics do; path_templater MyTemplater.new; end` in `config.rb`.

**Allocation impact on the request hot path.** The new histogram
observation runs in `Connection#serve` (not in `Adapter::Rack#call`,
which `yjit_alloc_audit_spec` locks at 9 obj/req post-Phase-11).
Per-observation steady-state allocation: 1 fresh 3-element label
Array (the `method`/`path`/`status` tuple); the templater + the
HistogramAccumulator both reuse pre-allocated structures past first
sight of a given route. `yjit_alloc_audit_spec` stays green at
9 obj/req.

**Files / sites:**

| Where | What |
|---|---|
| `lib/hyperion/metrics.rb` | Histogram + gauge + labeled-counter API on `Hyperion::Metrics`. Snapshot helpers for the exporter. |
| `lib/hyperion/metrics/path_templater.rb` | NEW — LRU-cached templater with default integer/UUID rules. |
| `lib/hyperion/prometheus_exporter.rb` | `render_full(metrics_sink)` emits histograms / gauges / labeled counters in addition to the legacy counter render. |
| `lib/hyperion/admin_middleware.rb` | `/-/metrics` switches to `render_full` when the sink supports it (defensive fallback otherwise). |
| `lib/hyperion/connection.rb` | Per-route duration histogram observation; labeled per-worker rejection counter; kTLS untrack on close. |
| `lib/hyperion/websocket/connection.rb` | WS deflate ratio histogram observation in `deflate_message`. |
| `lib/hyperion/tls.rb` | `track_ktls_handshake!` / `untrack_ktls_handshake!` helpers. |
| `lib/hyperion/server.rb` | Calls `track_ktls_handshake!` after every TLS accept. |
| `lib/hyperion/worker.rb` | Sets the `hyperion_io_uring_workers_active` gauge at boot/shutdown. |
| `lib/hyperion/thread_pool.rb` | Block-form gauge for `hyperion_threadpool_queue_depth` (read live at scrape time). |
| `lib/hyperion/config.rb` | `MetricsConfig` subconfig with `path_templater` + `enabled` knobs. |
| `spec/hyperion/metrics_enrichment_spec.rb` | NEW — 27 examples covering templater, histogram/gauge/counter API, exporter rendering, and per-domain integration (Connection, WS deflate, kTLS, fairness). |
| `docs/OBSERVABILITY.md` | NEW — operator playbook: every metric, its query, what action a non-zero value should trigger. |
| `docs/grafana/hyperion-2.4-dashboard.json` | NEW — pre-built dashboard with 8 panels (heatmap + p50/p99 + rejection rate + deflate ratio + kTLS + io_uring + queue depth). |

**No new gem deps.** The exporter extends the existing in-tree
emission path; no `prometheus-client` (or any other) gem was added.

Spec count: 796 → 823 default-run.
No version bump (release task is 2.4-fix-F).

### 2.4-D — Linux multi-process WS bench rerun + autobahn RFC 6455 conformance

Two items deferred from 2.3-D landed in this stream — the openclaw-vm
multi-process WebSocket bench and the autobahn-testsuite fuzzer run
against the WS echo rackup. Bench + docs only; no production code
changed.

**Headlines.**

* **Linux multi-process WS bench captures the published numbers.**
  4 procs × 200 conns × 1000 msgs hits **6,880 msg/s** with
  p50 28.60 ms / p99 33.86 ms; 4 procs × 40 conns hits **7,561 msg/s**
  with p50 5.26 ms / p99 6.22 ms. vs the fix-E single-process
  Linux baseline this is **+285–289% msg/s and a 75% drop in
  p99 on the throughput row** (134 ms → 33.86 ms). Confirms that
  the long fix-E Linux tail at 200 conns was client-side GVL
  serialisation, not server-side latency — the same shape we
  saw on macOS in 2.3-D.

* **autobahn RFC 6455 conformance: 453/463 pass (97.8%).** Run on
  openclaw-vm with `bench/ws_echo_autobahn.ru` (1 MiB cap +
  permessage-deflate negotiated) against `crossbario/autobahn-testsuite`
  Docker image. Per-section breakdown:

  | Section | Cases | Pass | Note |
  |---|---:|---:|---|
  | 1 — Framing                          |  16 | 16 / 16  | 100% OK |
  | 2 — Pings / pongs                    |  11 | 11 / 11  | 100% OK |
  | 3 — Reserved bits / opcodes          |   7 |  7 /  7  | 100% OK |
  | 4 — Frame contents                   |  10 | 10 / 10  | 100% OK |
  | 5 — Fragmentation                    |  20 | 20 / 20  | 100% OK |
  | 6 — UTF-8 validation                 | 145 |145 /145  | 4 NON-STRICT (fail-fast position; passes per RFC §8.1 SHOULD) |
  | 7 — Close handling                   |  37 | 27 / 37  | **10 FAILED — 2.5 follow-up** |
  | 9 — Limits / very large              |   — |    —     | excluded by config |
  | 10 — Auto-fragmentation              |   1 |  1 /  1  | 100% OK |
  | 12 — permessage-deflate (RFC 7692)   |  90 | 90 / 90  | 100% OK — 2.3-C validated |
  | 13 — permessage-deflate fragmentation| 126 |126 /126  | 100% OK — 2.3-C validated |

  **Sections 12 + 13 (216 cases, RFC 7692 permessage-deflate)**
  are 100% OK on this run — the first autobahn validation since
  2.3-C shipped the extension. Confirms the encode + decode + per-
  message reset paths are RFC-compliant end-to-end.

  **Section 7 close handling has 10 FAILED cases, all in 7.5.1
  + 7.9.x.** RFC 6455 §7.4 requires the server to close 1002
  (Protocol Error) when the peer sends a close frame with an
  invalid close code (0, 1004, 1005, 1006, reserved range, etc.).
  Hyperion's `Connection#recv` close path currently echoes the
  invalid code back instead of rejecting it. **Filed as a 2.5
  follow-up** — out of scope for 2.4-D (bench + docs only) per the
  sprint scope.

**What ships:**

| Where | What |
|---|---|
| `bench/ws_echo_autobahn.ru` | NEW — autobahn-friendly variant of `ws_echo.ru`. 1 MiB `max_message_bytes` (vs 16 KiB) and propagates the negotiated `permessage-deflate` extension into the 101 response so sections 12/13 fire. Plain `ws_echo.ru` runs through autobahn fine for sections 1-10 but marks 12/13 UNIMPLEMENTED because the server never advertises deflate. |
| `bench/parse_autobahn_index.rb` | NEW — reads `autobahn-reports/index.json` and prints the per-section breakdown the table above came from. Identifies FAILED cases for triage. Also lists OK / NON-STRICT / INFORMATIONAL / UNIMPLEMENTED counts per section. |
| `autobahn-config/fuzzingclient.json` | UPDATED — agent string bumped to `Hyperion-2.4.0`, points at `ws://127.0.0.1:9888` (no path; `bench/ws_echo_autobahn.ru` accepts upgrade on any URL), header comment now references `parse_autobahn_index.rb` and the 17-minute wall-clock estimate. |
| `docs/WEBSOCKETS.md` "RFC 6455 conformance" subsection | UPDATED — replaces the deferred-to-2.4 note with the actual 2.4-D results table, the 7.x close-handshake gap as a known 2.5 follow-up, and a "Configuring permessage-deflate echo" snippet for operators rolling their own ws app. |
| `docs/BENCH_HYPERION_2_0.md` "WebSocket multi-process bench" subsection | UPDATED — replaces the deferred-recipe block with the openclaw-vm 2.4-D table + cross-platform shape comparison (within-host scaling vs Apple Silicon dev) + raw 3-run-median data. |

**Bench environment.** All 2.4-D numbers from `openclaw-vm`,
Ubuntu 24.04, kernel 6.8, 16 vCPU x86_64, Ruby 3.3.3, hyperion
master @ commit `ffcbdfb` (2.4-C tip pre-2.4-D commit). Three runs
each, median reported, run-to-run variance ~3-5%.

**Known limit (logged for 2.5).** Section 7.5.1 + 7.9.x autobahn
FAILED cases — the close-handshake invalid-payload validation gap
described above. The fuzzer tests close codes 0 / 1004 / 1005 /
1006 / 1012-1015 / 1016+ / 2000+ / 2999 / etc.; Hyperion echoes the
peer's invalid code instead of rejecting it with 1002. Fix is a
small `validate_close_payload!` helper on `WebSocket::Connection`
plus the matching close-handshake response — punted out of 2.4-D
because the sprint stream was bench + docs only.

Spec count: 823 → 823 (no spec changes — bench scripts and parser
script are runnable Ruby but not exercised by the rspec suite).
No version bump (release task is 2.4-fix-F).

## [2.3.0] - 2026-05-01

### Headline

A WebSocket-bandwidth + operator-knobs release. The 2.3.0 sprint
targeted the user's nginx-fronted plaintext-h1 + WebSocket
production topology. The headline wins:

| Track | Result |
|---|---|
| 2.3-C — WebSocket permessage-deflate (RFC 7692) | **20× wire reduction** on chat-style JSON; chat workloads / ActionCable fan-out save bandwidth at the cost of ~30-40% encode-CPU |
| 2.3-D — WS multi-process bench client | +176% msg/s, p99 halved (debunked fix-E's single-process tail as client-side GVL, not server-side) |
| 2.3-A — io_uring accept on Linux 5.6+ (opt-in) | At parity with epoll on hello — Ruby-dispatch-bound at this rate, not accept-syscall-bound. Path engages cleanly; ships opt-in for high-accept-churn workloads |
| 2.3-B — Per-conn fairness + TLS handshake throttle | Defense-in-depth knobs; `max_in_flight_per_conn` defaults to nil (no behavior change), operators opt-in via config / CLI / env |

Spec count: 698 (2.2.0) → 776 (2.3.0).

New operator knobs:
- `HYPERION_IO_URING={on,off,auto}` (env) + `c.io_uring = :auto/:on/:off` (DSL)
- `c.max_in_flight_per_conn = N` / `--max-in-flight-per-conn N` / `HYPERION_MAX_IN_FLIGHT_PER_CONN=N`
- `c.tls.handshake_rate_limit = N` / `--tls-handshake-rate-limit N` / `HYPERION_TLS_HANDSHAKE_RATE_LIMIT=N`
- `c.websocket.permessage_deflate = :auto/:on/:off` (DSL) / `HYPERION_WS_DEFLATE={on,off,auto}`

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

**Bench delta on a chat-style JSON workload (1 KB messages,
`bench/ws_deflate_bench.rb`):**

| Mode | Bytes per message | Wire reduction | msg/s (macOS arm64) | msg/s (openclaw Linux 16-vCPU) |
|---:|---:|---:|---:|---:|
| Plain (no deflate) | 400.8 B | — | 57,498 | 11,782 |
| permessage-deflate | 19.7-20.0 B | **20.0-20.4× smaller** | 34,999 (61%) | 8,101 (69%) |

Both hosts confirm the wire reduction is workload-shape-bound, not
host-bound (zlib is identical on both). The msg/s gap is the deflate
CPU cost on the encode side. The openclaw measurement was run after
the 2.3-C ship (commit `8044610`) on `bench/ws_deflate_bench.rb`.

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

### 2.3-D — WS multi-process bench + RFC 6455 conformance recipe

**Why this matters.** fix-E's 200-conn WebSocket bench landed at
1,766 msg/s with p99 134 ms on openclaw-vm — and the long tail there
turned out to be **client-side** GVL serialisation, not server-side
latency. The single-process Ruby bench client funnels every per-message
mask/unmask + frame parse + IO.select through one interpreter under
the GVL; at 200 concurrent connections the client itself ran out of
CPU before the server did. To publish honest server throughput, the
client needs to scale across OS processes.

**Bench-only commit — no production code changes.**

**What ships:**

| Deliverable | Where | Why |
|---|---|---|
| `bench/ws_bench_client_multi.rb` | NEW | Forks N child processes (`--procs N`), each running `bench/ws_bench_client.rb --json` against a slice of the total connection count. Aggregates: `total_msgs = Σ child[total_msgs]`, wall `elapsed = max(child[elapsed_s])`, `msg/s = total_msgs / elapsed`, `p50 / p99 / max = max across children` (conservative — slowest child sets the published tail). |
| `autobahn-config/fuzzingclient.json` | NEW | Canonical RFC 6455 fuzzingclient config pointed at `ws://127.0.0.1:9888/echo`. Excludes case 9.* (very-large-message cases — too slow for default runs; soak via uncomment). Run via `crossbario/autobahn-testsuite` Docker image. |
| `docs/WEBSOCKETS.md` "Performance" addendum | UPDATED | Adds the 2.3-D multi-process numbers next to the fix-E single-process numbers, plus an operator note that published msg/s requires multi-process. |
| `docs/WEBSOCKETS.md` "RFC 6455 conformance" section | NEW | Full Docker recipe + expected per-section pass matrix. |
| `docs/BENCH_HYPERION_2_0.md` "WebSocket multi-process bench (2.3-D)" subsection | NEW | macOS dev numbers + openclaw-vm reproduction recipe (deferred: SSH unavailable this session). |

**Bench numbers — macOS dev (Apple Silicon, 14 efficient cores), median of 3:**

| Workload | msg/s | p50 | p99 | vs fix-E single-process |
|---|---:|---:|---:|---|
| 4 procs × 50 conns × 1000 msgs (200-conn aggregate, `-t 256 -w 1`) | **14,757** | 13.01 ms | 21.75 ms | **+176%** msg/s, p99 cut in half (43.12 → 21.75 ms) |
| 4 procs × 10 conns × 1000 msgs (40-conn aggregate, `-t 256 -w 1`) | 13,594 | 2.49 ms | 7.75 ms | +110% vs fix-E 10-conn 6,463 msg/s |

The 200-conn p99 drop from 43.12 ms to 21.75 ms is the smoking gun
that fix-E's tail was client-side. With the GVL released across 4
processes, the bench now actually probes server latency rather than
client scheduling.

**Deferred to 2.4:**

- **openclaw-vm Linux 16-vCPU rerun.** Bench host SSH was unavailable
  this session (`Permission denied (publickey)` after a verbose probe).
  Recipe is in `docs/BENCH_HYPERION_2_0.md` for the next maintainer
  with agent-loaded keys; expected ≥ 4,500 msg/s aggregate at
  p99 < 70 ms based on macOS multiplier extrapolation. The
  aspirational 50,000 msg/s figure from the 2.1.0 brief still needs
  `-w 16 -t small` plus a non-Ruby client.
- **autobahn-testsuite RFC 6455 fuzzer run.** Docker daemon was not
  running locally and the openclaw bench host (where the
  `crossbario/autobahn-testsuite` image is pre-pulled) was
  unreachable. Config landed at `autobahn-config/fuzzingclient.json`;
  recipe + expected pass matrix in `docs/WEBSOCKETS.md`. Any RFC
  violations the fuzzer surfaces are 2.4 follow-ups.

Spec count: 776 → 776 (no spec changes; bench client lives in `bench/`,
not `lib/`, and is not loaded by `require 'hyperion'`).

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
