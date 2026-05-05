# Hyperion performance roadmap — design

**Date:** 2026-05-05
**Status:** Design — pending implementation plan(s)
**Source:** `docs/BENCH_HYPERION_RAILS.md` post-tuning analysis ("Bar d" 0/6 → 1/6 after PR1+3; 5 still-failing pairs cluster into three structural problem-classes).

## Goals

Address the three structural causes of the remaining "Bar d" failures in
the Rails matrix on `openclaw-vm`:

1. Direct-syscall ResponseWriter in C (eliminate Ruby IO machinery between
   the per-response coalesced buffer and the kernel `write(2)`).
2. io_uring on the request hot path (multishot accept + multishot recv +
   send SQEs; not just accept as today).
3. AR-CRUD bench row → Postgres (the SQLite-mem-shared path measures the
   wrong axis for Hyperion's `--async-io` + `hyperion-async-pg` story).

These ship sequentially. Each lands behind its own gate and can be
reverted independently. The three intersect at one seam — when both #1
and #2 are active, #1's C writer submits a send SQE via #2's Rust
entrypoint instead of calling `write(2)` directly.

## Non-goals

- HTTP/2 hot-path changes (`HYPERION_H2_NATIVE_HPACK` story is separate).
- WebSocket frame I/O (`ext/hyperion_http/websocket.c` has its own perf
  story).
- macOS `kqueue`-based equivalent of #2 (io_uring is Linux-only by design;
  macOS keeps `accept4` + `read_nonblock`).
- Cross-worker shared rings (per-worker rings remain the model from 2.3-A).
- Default-flip of `HYPERION_IO_URING_HOTPATH` (documented intent only —
  not committed in this spec).

---

## Architecture overview

```
                        ┌────────────────────────────────────────┐
                        │  bench/run_all.sh  (Rails matrix)      │
                        └────────────┬───────────────────────────┘
                                     │  rows 19-22 / 27-28
              ┌──────────────────────┴──────────────────────┐
              │  #3:  RAILS_DB=pg variant                    │
              │       hyperion-async-pg + --async-io         │
              │       (config / Gemfile / bench script only) │
              └──────────────────────┬──────────────────────┘
                                     │  measures:
                                     ▼
                ┌──────────────────────────────────┐
                │  Hyperion::Server  →  Connection  │
                └──────────────┬───────────────────┘
                               │
     ┌─────────────────────────┴──────────────────────────┐
     │                                                    │
     ▼                                                    ▼
┌──────────────────────────┐               ┌────────────────────────────┐
│  Read path               │               │  Write path                │
│                          │               │                            │
│  Today: read_nonblock    │               │  Today: io.write(head+body)│
│  + IO.select retry       │               │  (Ruby ResponseWriter)     │
│                          │               │                            │
│  #2: io_uring multishot  │   #1+#2 seam  │  #1: C ResponseWriter      │
│  RECV with buffer rings  │ ◄─────────────►  c_write_buffered          │
│  → fills Ruby's existing │               │  c_write_chunked           │
│  per-conn parser buffer  │               │  → write(2) on Linux       │
│  → CParser stays the     │               │     (or send SQE under #2) │
│  authority on parsed     │               │  → fall through to Ruby    │
│  request shape           │               │     on TLS / non-fd / no C │
│                          │               │                            │
│  Gated: io_uring_hotpath │               │  Always-on when ext loaded │
│  (independent of accept  │               │                            │
│  gate; default off)      │               │                            │
└──────────────────────────┘               └────────────────────────────┘
```

### Invariants preserved

1. Pure-Ruby fallback paths stay intact for every C/Rust addition. No
   regression in the JRuby / TruffleRuby / cargo-missing /
   gem-install-without-toolchain story.
2. Connection state stays in Ruby. Rust submits/reaps; Ruby parses and
   dispatches.
3. Dispatch model unchanged. Thread-pool / fiber-inline / async-io
   selection is a function of `Adapter::Rack` + `dispatch_mode`,
   untouched by either #1 or #2.
4. TLS + sendfile + page-cache paths untouched — they opt out of the C
   writer at the existing seams (`real_fd_io?`, `to_path`,
   `page_cache_write`).
5. Independent gates: `HYPERION_IO_URING_ACCEPT` (existing 2.3-A,
   accept-only) and `HYPERION_IO_URING_HOTPATH` (new, read+write+accept)
   are independent. No coupling.

---

## #3 — AR-CRUD bench → Postgres

### Files

| Path | Change |
|---|---|
| `bench/rails_app/Gemfile` | Add `gem 'pg', '~> 1.5'` and `gem 'hyperion-async-pg'`. |
| `bench/rails_app/Gemfile.lock` | Regenerated. |
| `bench/rails_app/config/database.yml` | ERB branch on `ENV['RAILS_DB']`. `RAILS_DB=sqlite` (or unset) keeps existing in-memory SQLite. `RAILS_DB=pg` → PG adapter on `ENV['DATABASE_URL'] \|\| 'postgres://localhost/hyperion_bench'`, `pool: 5`, `prepared_statements: true`. |
| `bench/rails_app/db/seeds.rb` | Minimal seed for `/users.json`. |
| `bench/run_all.sh` | New `setup_pg_bench_db()` (runs `pg_isready` and conditionally `RAILS_DB=pg bin/rails db:create db:migrate db:seed`). Exports `RAILS_DB=pg`, `DATABASE_URL=...` for AR-CRUD rows. Boots Hyperion AR-CRUD rows with `--async-io`. Comparison rows use the same DB but each server's native concurrency model. |
| `bench/boot_hyperion` | Pass `--async-io` only for AR rows. |
| `docs/BENCH_HYPERION_RAILS.md` | New "DB choice" section. Matrix headers say "AR-CRUD (PG)". "Why we switched" paragraph. Note SQLite path retained for hosts without PG. |
| `docs/BENCH_HOST_SETUP.md` | New "Postgres" subsection (install `postgresql-15+`, `createuser`, port 5432, trust-on-localhost). |

### Data flow

Unchanged from today on Hyperion side. The Rails endpoint moves DB; the
fiber parks on the PG socket via `Fiber.scheduler.io_wait`, where SQLite
in-memory had no socket to yield on.

### Error matrix

| Failure | Action |
|---|---|
| `pg_isready` fails | Bench rows 19-22 / 27-28 abort with `BOOT-FAIL,no-pg`; other rows continue. |
| `db:create` race | `ActiveRecord::DatabaseAlreadyExists` caught; idempotent. |
| `pg` gem missing | `bundle install` in `--rails` setup aborts the bench. |
| `hyperion-async-pg` missing under `--async-io` | Existing `validate_async_io_loaded_libs!` raises at boot (RFC A9 path). |
| PG pool exhausted under load | App returns 500; documented `pool: 5` matches `-t 5`; raise pool size in bench config if observed. |

### Acceptance

`./bench/run_all.sh --rails` on `openclaw-vm` produces a fresh
post-tuning markdown table with new "Bar d" status for AR-CRUD rows on
PG. If PG closes the gap entirely, #3 retires the AR class. If it
narrows but does not close, #1 + #2 still do work on those rows.

### Rollback

Revert the bench commits. SQLite path was preserved; no app-side change
to undo.

### Outcome (filled in after bench re-run)

- Date: 2026-05-05
- Host: openclaw-vm (Linux 6.8); PG: pg.wobla.space (PG 17.2)
- AR-CRUD 1w (Hyperion vs Agoo): 569.63 r/s vs 488.90 r/s → **pass (+16.5%)**
- AR-CRUD 4w (Hyperion vs Agoo): 2098.73 r/s vs 509.25 r/s → **pass (4.1x)**
- Decision: **(a) PG closes the AR-CRUD gap.** Class #3 retired. Plans #1 and #2 proceed with one fewer success criterion.

CSV: `docs/BENCH_HYPERION_2_17_AR_results.csv`.

---

## #1 — C-side ResponseWriter (full path, plain TCP only)

### Decisions locked in

- **Scope:** Full C-side write path (head-build + framing + syscall).
- **TLS posture:** Plain TCP only. TLS / `OpenSSL::SSL::SSLSocket` falls
  through to the existing Ruby path. The page-cache path's
  `real_fd_io?` predicate (`response_writer.rb:367`) is the eligibility
  guard.

### Files

| Path | Change |
|---|---|
| `ext/hyperion_http/response_writer.c` | New file (~600 LoC). Module `Hyperion::Http::ResponseWriter`. Methods `c_write_buffered(io, status, headers, body, keep_alive, date_str) → Integer (bytes)` and `c_write_chunked(io, status, headers, body, keep_alive, date_str) → Integer`. Extracts fd via `rb_funcall(io, id_fileno, 0)`. Reuses `c_build_response_head` from `parser.c`. |
| `ext/hyperion_http/parser.c` | Lift `c_build_response_head` helpers into a small shared header so `response_writer.c` can include them. No behavior change. |
| `ext/hyperion_http/extconf.rb` | Add `response_writer.c`. Probe for `MSG_NOSIGNAL` and `writev` (POSIX, expected present); probe for `TCP_CORK` (Linux) — fall through to coalesced `writev` when missing. |
| `lib/hyperion/response_writer.rb` | `#write` becomes a dispatcher. New `c_path_eligible?(io)` true when (a) C ext loaded, (b) `real_fd_io?(io)` true, (c) not an `SSLSocket`. When eligible → C path; else → existing Ruby paths (renamed `write_buffered_ruby` / `write_chunked_ruby`). `to_path` / sendfile / page-cache branches keep priority. |
| `lib/hyperion/http.rb` | Auto-require `Hyperion::Http::ResponseWriter` after C ext loads (mirrors `PageCache` / `Sendfile`). |
| `spec/hyperion/c_response_writer_spec.rb` | Wire-byte parity + one-syscall-per-response assertion. |
| `spec/hyperion/c_response_writer_chunked_spec.rb` | Chunked SSE-shape parity, flush sentinel, drain-then-emit ordering, terminator atomicity. |
| `spec/hyperion/c_response_writer_fallback_spec.rb` | Stub C ext absent → Ruby path runs with same wire bytes. |
| `spec/hyperion/c_response_writer_errno_spec.rb` | EPIPE / EBADF / EINTR / EAGAIN paths surface as documented. |
| `spec/hyperion/parser_alloc_audit_spec.rb` | Lower per-request alloc budget; the Ruby `+''` head buffer + body `<<` chain go away on the C path. |
| `spec/hyperion/yjit_alloc_audit_spec.rb` | Updated to reflect the same alloc reduction on the buffered hot path. |

### Public surface added

- `Hyperion::Http::ResponseWriter.c_write_buffered`
- `Hyperion::Http::ResponseWriter.c_write_chunked`
- `Hyperion::Http::ResponseWriter.available?` (probe)
- `Hyperion::Http::ResponseWriter.c_writer_available = false` (rollback
  test seam, mirrors `Hyperion::ResponseWriter.page_cache_available =`).

### Data flow (response lifecycle, plain TCP, C path eligible)

```
Adapter::Rack#call returns [status, headers, body]
       │
       ▼
ResponseWriter#write(io, status, headers, body, keep_alive:, dispatch_mode:)
       │
       ├── body.respond_to?(:to_path)? ─── yes ──► write_sendfile (untouched)
       │                                                │
       │                                                └─► page_cache_write / sendfile
       │
       ├── chunked_transfer?(headers)? ── yes ──► [c_path_eligible? ─ yes ─► c_write_chunked]
       │                                                │                           │
       │                                                └── no ──► write_chunked_ruby
       │
       └── (default buffered path)
              │
              ├── c_path_eligible?(io)? ── no ──► write_buffered_ruby
              │
              └── yes ──► Hyperion::Http::ResponseWriter.c_write_buffered(io, ...)
                            │
                            ▼
   ┌────────────────────────────────────────────────────────────────────┐
   │  C-side flow (response_writer.c)                                    │
   │                                                                     │
   │  1. fd = NUM2INT(rb_funcall(io, id_fileno, 0))                      │
   │  2. Reuse c_build_response_head() into a stack-or-arena buffer.    │
   │  3. Body extraction:                                                │
   │      a. Array[1] of String  → iov[0]=head, iov[1]=body              │
   │      b. Array[N] of String  → iov[0]=head, iov[1..N]=chunks         │
   │      c. body.each (rare)    → fall back to rb_funcall body.each    │
   │                               into a coalesce buffer; iov[0]=head, │
   │                               iov[1]=coalesced body.                │
   │  4. write/writev:                                                   │
   │      - Linux: sendmsg(fd, msghdr{iov, MSG_NOSIGNAL}, 0)             │
   │      - macOS: writev(fd, iov, iov_count)                            │
   │  5. EINTR → bounded retry; then surface errno.                     │
   │  6. EAGAIN → return HYP_C_WRITE_WOULDBLOCK; Ruby caller falls back │
   │     to io.write (which yields under Async / blocks under threadpool│
   │     correctly — we don't reimplement scheduler-aware parking in C).│
   │  7. Return total bytes written.                                    │
   │                                                                     │
   │  GVL: held throughout. Hot-path syscalls on a non-blocking TCP     │
   │  socket complete in microseconds — GVL release/acquire would cost  │
   │  more than the syscall itself. EAGAIN is the only case where       │
   │  parking is needed; we hand back to Ruby for that.                 │
   └────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
                ResponseWriter#write returns
                (caller increments :bytes_written from Ruby)
```

#### Chunked-path flow

```
c_write_chunked(io, status, headers, body, keep_alive, date_str)
   │
   ├─► c_build_response_head_chunked → head bytes
   ├─► write(fd, head, head_len)            (1 syscall)
   ├─► coalesce_buf = stack 4 KiB buffer    (per-call, no malloc)
   │
   └─► rb_block_call(body, id_each, 0, NULL, chunk_callback, &state)
          ↓ for each chunk Ruby yields:
          chunk_callback(chunk, state):
            if chunk == :__hyperion_flush__ → drain coalesce_buf
            framed = bytesize.to_hex_lo + "\r\n" + payload + "\r\n"
            if payload.size < 512 and coalesce_buf has room:
                memcpy framed into coalesce_buf
                if coalesce_buf >= 4 KiB → write + reset
            else:
                drain coalesce_buf if non-empty
                write(fd, framed)
   │
   └─► drain coalesce_buf + "0\r\n\r\n"     (writev: 1 syscall)
```

The coalesce buffer lives on the C stack — no per-response heap
allocation. The hex size-line uses a hand-rolled C helper (mirrors
`u64_to_dec` in `c_access_line.c`). For each chunk yield, `rb_block_call`
calls back the C callback under the GVL; no GVL release in the chunked
path because Rack body iterators are themselves Ruby code.

### Invariants

- One syscall per response on the buffered path (`sendmsg`/`writev` with
  `iov_count=2`).
- Wire bytes match the existing Ruby path byte-for-byte. The change is
  the syscall shape, not the framing.
- EAGAIN fall-back is non-degenerate: re-enters Ruby only on real
  backpressure; under `wrk` the path is never taken.
- Metrics accounting stays in Ruby. C function returns the byte count;
  `Hyperion.metrics.increment(:bytes_written, n)` is called from
  `response_writer.rb` after the C call.

### Error matrix

| Failure | Action |
|---|---|
| `io.fileno` raises (closed mid-call) | `IOError` propagates; `Connection#serve` already catches. |
| EINTR | Bounded retry (max 3) in C, then `rb_sys_fail`. |
| EAGAIN | Return `HYP_C_WRITE_WOULDBLOCK = -2`; Ruby caller calls `io.write(head)` (yields under Async / blocks under threadpool). |
| EPIPE / ECONNRESET | `Errno::EPIPE` via `rb_sys_fail`. `Connection#serve` tears the conn down. |
| EFAULT / EBADF | Surface as the corresponding `SystemCallError`. Indicates a bug — abort the connection, don't paper over. |
| Body iter raises mid-`body.each` | C unwinds via `rb_protect`. State variable tracks "head shipped y/n" — drain coalesce + terminator only if status+headers already on wire. |
| Header value with CR/LF | Raise `ArgumentError` (matches `response_writer.rb:608`). |
| Non-String chunk yielded | `Check_Type(chunk, T_STRING)`; raise `TypeError`. |
| C ext loaded but symbol missing (build skew) | Init warns + flips `c_writer_available?` to false; Ruby fallback for the process lifetime. |

### Tests

| Spec | Asserts |
|---|---|
| `c_response_writer_spec.rb` | Wire-byte parity for: Array[1] body, Array[N] body, Enumerator, empty body, with/without keep-alive, with/without explicit Content-Length, with/without pre-set date header. One-syscall-per-response assertion. |
| `c_response_writer_chunked_spec.rb` | SSE-shape with `:__hyperion_flush__`, body that responds to `:flush`, big-then-small-then-big chunks (drain-then-emit ordering), terminator atomicity (parse wire output as chunked-encoded). |
| `c_response_writer_fallback_spec.rb` | C ext stubbed undefined → Ruby path runs; same wire bytes. `c_path_eligible?` false (predicate fails) → Ruby path runs. |
| `c_response_writer_errno_spec.rb` | EPIPE / EBADF / EINTR / EAGAIN forced via socket fixtures (close peer, dup-then-close, signal-based EINTR, full-write-buffer trick). Each surfaces as the documented exception or fall-back path. |
| `parser_alloc_audit_spec.rb` | Lowered per-request alloc budget; future regressions fail loudly. |
| `yjit_alloc_audit_spec.rb` | Same direction — fewer YJIT-tracked allocs on the buffered hot path. |
| `build_response_head_spec.rb` | Existing — must still pass. C head builder bytes unchanged. |

### Acceptance

- `bin/check --full` green on macOS and Linux.
- New specs pass on both.
- `./bench/run_all.sh --row 4` on `openclaw-vm`, three trials, median
  r/s ≥ +20% vs the post-2.16.3 baseline.
- `parser_alloc_audit_spec.rb` shows the targeted alloc reduction.
- PR body includes the bench numbers.

### Rollback

- Operator: `HYPERION_C_RESPONSE_WRITER=off` env var (test seam) flips
  `c_writer_available?` false; Ruby fallback engages without a redeploy.
- Hard: revert the PR; Ruby fallback is the default code path.

---

## #2 — io_uring on the request hot path

### Decisions locked in

- **Depth:** Multishot accept + multishot recv on the accept fiber.
  Dispatch model preserved (Ruby parses + dispatches; Rust only submits
  and reaps). Paired io_uring writes integrate with #1's C writer.
- **Gate:** New `HYPERION_IO_URING_HOTPATH` env / `io_uring_hotpath:`
  DSL key, independent of `HYPERION_IO_URING_ACCEPT`. Default off.
- **Implementation:** Rust crate owns submission/completion + buffer
  rings (`IORING_REGISTER_PBUF_RING`); Ruby `connection.rb` keeps
  parser+dispatch state and consumes kernel-managed buffers via a
  zero-copy view.
- **Kernel gates:** 5.6 (basic io_uring) + 5.19 (buffer rings). Both
  must hold for hotpath to engage.

### ABI bump

`hyperion_io_uring` Rust crate: `EXPECTED_ABI` 1 → 2. Existing
mismatch-warn path (`io_uring.rb:232`) handles stale `.dylib`/`.so`
cleanly — operator runs `gem pristine hyperion-rb` to refresh.

### Files

| Path | Change |
|---|---|
| `ext/hyperion_io_uring/Cargo.toml` | Bump version. |
| `ext/hyperion_io_uring/src/lib.rs` | `ABI_VERSION = 2`. New module `hotpath_impl` (Linux-only): `Ring::submit_recv_multishot(fd, buf_group_id)`, `Ring::submit_send(fd, iov_ptr, iov_count)`, `Ring::wait_completions(min_complete, timeout_ms) → CompletionBatch`. New extern "C" entrypoints with `hyperion_io_uring_hotpath_*` prefix; existing accept entrypoints unchanged. New probe `hyperion_io_uring_hotpath_supported() → c_int` (0 on 5.19+, `-ENOSYS` otherwise). |
| `ext/hyperion_io_uring/src/buffer_ring.rs` | New file. Owns the `IORING_REGISTER_PBUF_RING` mmap, buffer-id → buffer-slice translation, `release_buffer(buf_id)` to recycle. |
| `lib/hyperion/io_uring.rb` | New `IOUring::HotpathRing` class. New `IOUring.hotpath_supported?` (5.19 + lib loaded + new probe green). New `IOUring.resolve_hotpath_policy!`. Existing accept-only `Ring` unchanged. |
| `lib/hyperion/connection.rb` | Conditional read path: when `conn.io_uring_owned`, reads come from `hotpath_ring.next_recv_completion(fd) → bytes_or_eof`. Bytes are a borrowed view into the kernel buffer (Fiddle pointer); copied into the existing Ruby parse buffer (one allocation, same shape as today). After parse consumes, `hotpath_ring.release_buffer(buf_id)` recycles. Writes (when paired) go through `hotpath_ring.submit_send` from #1's C writer. Otherwise the existing `read_nonblock` + `write(2)` paths are untouched. |
| `lib/hyperion/server.rb` | At boot: if `io_uring_hotpath` resolves truthy, instantiate `HotpathRing` per accept fiber; the accept fiber processes accept-CQEs and recv-CQEs uniformly. |
| `lib/hyperion/cli.rb` | `--io-uring-hotpath={off,auto,on}`. Env `HYPERION_IO_URING_HOTPATH={0,1,off,auto,on}`. CLI > env > config > default `:off`. |
| `lib/hyperion/config.rb` | `io_uring_hotpath` setting; document in `config/hyperion.example.rb`. |
| `docs/IO_URING_HOTPATH.md` | New doc (mirrors `docs/CLUSTER_AND_SO_REUSEPORT.md` style). |
| `docs/CONFIGURATION.md` | New row for `HYPERION_IO_URING_HOTPATH`. |
| `spec/hyperion/io_uring_hotpath_spec.rb` | Linux 5.19+. Round-trip recv with multiple buffers, kernel-buffer-recycle, EAGAIN/EBADF/ECANCELED handling. |
| `spec/hyperion/io_uring_hotpath_send_spec.rb` | Linux 5.19+. Send SQEs end-to-end; short-write follow-up via shrunk `SO_SNDBUF`. |
| `spec/hyperion/io_uring_hotpath_fallback_spec.rb` | Cross-platform. `hotpath_supported?` false on macOS, Linux <5.19, `HYPERION_IO_URING_HOTPATH=off`. |
| `spec/hyperion/connection_io_uring_hotpath_spec.rb` | Linux 5.19+. End-to-end via `TCPSocket`; wire bytes match non-hotpath path byte-for-byte. |
| `spec/hyperion/io_uring_hotpath_buffer_exhaustion_spec.rb` | Linux 5.19+. Set `HYPERION_IO_URING_HOTPATH_BUFS=4`, drive enough slow concurrent clients to exhaust; assert `:io_uring_recv_enobufs` increments + server stays up. |
| `spec/hyperion/io_uring_hotpath_fallback_engaged_spec.rb` | Linux 5.19+. Inject synthetic ring failure; assert `:io_uring_hotpath_fallback_engaged` increments and subsequent conns succeed via accept4. |
| `spec/hyperion/io_uring_hotpath_abi_spec.rb` | Cross-platform. ABI v1 `.so` against v2 expectations → `hotpath_supported?` false + warn. |
| `spec/hyperion/io_uring_soak_smoke_spec.rb` | Existing — extend with hotpath-on variant; `:perf` tag. |

### Public surface added

- `Hyperion::IOUring::HotpathRing` (Ruby).
- `Hyperion::IOUring.hotpath_supported?`.
- `Hyperion::IOUring.resolve_hotpath_policy!`.
- CLI `--io-uring-hotpath`.
- Env `HYPERION_IO_URING_HOTPATH`, `HYPERION_IO_URING_HOTPATH_BUFS`,
  `HYPERION_IO_URING_HOTPATH_BUF_SIZE`.
- DSL `io_uring_hotpath :auto`.

All additive — no removals or renames.

### Data flow (request hotpath)

```
Worker boots
   │
   ├─► IOUring.resolve_hotpath_policy! → :on
   ├─► HotpathRing.new(queue_depth: 1024)
   │      ├─► IORING_SETUP (5.6+)
   │      └─► IORING_REGISTER_PBUF_RING(group=0, n_bufs=512, buf_size=8 KiB)
   ├─► Server#run binds listener fd
   ├─► Accept fiber starts
   │      ├─► hotpath_ring.submit_accept_multishot(listener_fd)  (1 SQE, persistent)
   │      └─► loop:
   │            cqes = hotpath_ring.wait_completions(min=1, timeout=ACCEPT_LOOP_TIMEOUT)
   │            for cqe in cqes:
   │              op_kind:
   │                accept_ms → got new client_fd c.
   │                            conn = Connection.new(c, ...)
   │                            conn.io_uring_owned = true
   │                            connections[c] = conn
   │                            hotpath_ring.submit_recv_multishot(c, group=0)
   │
   │                recv_ms  → bytes flow in:
   │                            fd = cqe.fd
   │                            buf_id = cqe.buf_id
   │                            n = cqe.result
   │                            buf_view = buffer_ring.borrow(buf_id, n)
   │                            conn = connections[fd]
   │                            conn.feed_read_bytes(buf_view)
   │                              ├─► CParser.parse_chunk(buf_view, n) (existing)
   │                              ├─► on full request → dispatch
   │                              └─► returns "still-need-more" / "complete"
   │                            buffer_ring.release(buf_id)
   │                            # multishot stays armed unless cqe.flags has IORING_CQE_F_MORE=0
   │
   │                send_ms  → write completion:
   │                            fd = cqe.fd
   │                            n = cqe.result
   │                            if n < expected → submit follow-up send SQE
   │                            connections[fd].on_send_complete(n)
   │
   │                close_ms → fd closed:
   │                            connections.delete(fd)
   │
   │            (no syscall per CQE; one io_uring_enter per wait_completions loop)
```

### #1 ↔ #2 seam

```
Connection#dispatch finishes app call, has [status, headers, body]
   │
   ├─► if conn.io_uring_owned and ResponseWriter.c_writer_available?:
   │      Hyperion::Http::ResponseWriter.c_write_buffered_via_ring(
   │          fd, status, headers, body, keep_alive, date_str, hotpath_ring_ptr
   │      )
   │      ├─► builds head + iov in C (same as #1)
   │      ├─► submits send SQE via FFI back to Rust:
   │      │      hyperion_io_uring_hotpath_submit_send(ring_ptr, fd, iov_ptr, iov_count)
   │      ├─► returns immediately — completion handled async by accept fiber loop
   │      └─► response is "in flight"; conn awaits send_ms cqe before close
   │
   └─► else (TLS / non-fd / no C ext / hotpath off):
          existing #1 c_write_buffered (direct write/writev) OR Ruby fallback
```

```c
// ext/hyperion_http/response_writer.c
static VALUE c_write_buffered_via_ring(VALUE self, ..., VALUE ring_ptr_v) {
    int fd = ...;
    struct iovec iov[2];
    size_t head_len = build_head(iov[0]);
    size_t body_len = extract_body_iov(iov[1], body);

    // Resolved at Init_hyperion_http() via dlsym(RTLD_DEFAULT, "...")
    if (hyperion_io_uring_hotpath_submit_send) {
        return INT2NUM(
            hyperion_io_uring_hotpath_submit_send(
                NUM2VOIDP(ring_ptr_v), fd, iov, 2
            )
        );
    }
    // Fall back to direct write if the io_uring ext isn't loaded
    return c_write_buffered_direct(self, ...);
}
```

The two C extensions live in different `.so`/`.bundle` files. The
io_uring symbol is resolved at `Init_hyperion_http()` time via
`dlsym(RTLD_DEFAULT, "hyperion_io_uring_hotpath_submit_send")`. If the
io_uring crate isn't loaded, the symbol is NULL and we never take the
via-ring branch. No hard build-time dependency from `hyperion_http` on
`hyperion_io_uring`.

### Invariants

- One ring per worker. Cross-worker isolation comes from `SO_REUSEPORT`
  (existing).
- Buffer-ring lifecycle bounded: 512 × 8 KiB = 4 MiB pinned per worker
  by default. Configurable via `HYPERION_IO_URING_HOTPATH_BUFS=N` and
  `HYPERION_IO_URING_HOTPATH_BUF_SIZE=K`.
- Backpressure real: `ENOBUFS` on recv signals exhaustion. Counter
  `:io_uring_recv_enobufs`. Re-submit; kernel retries once a buffer is
  released.
- Hotpath fallback is **per-worker**, not per-process. Worker A's
  broken ring doesn't disable hotpath on B/C/D; A degrades to accept4
  + read_nonblock; master stays oblivious.
- Send SQEs don't park the accept fiber. Sends are fire-and-forget
  from the dispatch fiber's perspective.

### Error matrix

| Failure | CQE shape | Action |
|---|---|---|
| Listener fd closed during shutdown | `result < 0`, `errno = EBADF` | Accept fiber catches, logs once, exits cleanly. |
| ECONNABORTED between submit and accept | `result < 0`, `errno = ECONNABORTED` | Drop; multishot stays armed (unless `IORING_CQE_F_MORE = 0`). Counter `:accept_aborts`. |
| Multishot re-arm | `cqe.flags & IORING_CQE_F_MORE == 0` | Re-submit accept/recv SQE. |
| `recv` returned 0 | `result == 0` | Peer closed; tear conn down. |
| `recv` returned ENOBUFS | `result < 0`, `errno = ENOBUFS` | Counter `:io_uring_recv_enobufs`. Re-submit; sustained → one-shot warning. |
| `recv` returned ECANCELED | `result < 0`, `errno = ECANCELED` | Tear conn down quietly (operator close / shutdown). |
| `send` short | `result < expected` | Submit follow-up send SQE. iov held in per-conn arena (not stack). Counter `:io_uring_send_short`. |
| `send` returned EAGAIN | `result < 0`, `errno = EAGAIN` | Re-submit (rare on TCP send). |
| `send` returned EPIPE | `result < 0`, `errno = EPIPE` | Tear conn down. |
| `submit_and_wait` EINTR | Rust returns Err(EINTR) | Loop and retry once; sustained → engage hotpath fallback. |
| `release` for already-released buf_id | Programmer error | Rust `debug_assert`s; release no-op + counter `:io_uring_release_double`. |
| EBADR / EBADF in CQE for live fd | Programmer error / kernel bug | Tear conn; counter `:io_uring_unexpected_errno`. Log once. |
| Sustained ring failure | Repeat EBADR or submit failures | `HotpathRing#disable!` per-worker fallback engaged. Existing accepted conns drain on the failed ring. New conns use accept4 + read_nonblock + write(2). Worker stays alive. Counter `:io_uring_hotpath_fallback_engaged`. |
| Linux 5.6 but pre-5.19 | `hotpath_supported?` false at boot | Hotpath off entirely; accept-only ring still available. Boot warning if `HYPERION_IO_URING_HOTPATH=on`. |
| ABI v1 `.so` vs v2 expectations | Existing `io_uring.rb:232` mismatch warn | Falls back to non-hotpath. `gem pristine hyperion-rb`. |
| Cross-worker fd leak | Should be impossible (per-worker ring) | Counter `:io_uring_cross_worker_fd` + log + close. Defensive. |

**Panic safety:** every Rust extern "C" entrypoint wraps its body in
`std::panic::catch_unwind` (project convention from
`rust-performance.md`). On panic, returns negative-i64 sentinel; Ruby
surfaces as `RuntimeError`. No UB across FFI.

### Tests

| Spec | Asserts |
|---|---|
| `io_uring_hotpath_spec.rb` (Linux 5.19+) | Round-trip recv with multiple buffers; kernel-buffer-recycle; ECONNABORTED/ECANCELED/EBADF errno paths. |
| `io_uring_hotpath_send_spec.rb` (Linux 5.19+) | Send SQEs end-to-end; short-write follow-up via shrunk `SO_SNDBUF`. |
| `io_uring_hotpath_fallback_spec.rb` (cross-platform) | `hotpath_supported?` false on macOS, Linux <5.19, `HYPERION_IO_URING_HOTPATH=off`. `resolve_hotpath_policy!(:on)` raises on unsupported hosts. |
| `connection_io_uring_hotpath_spec.rb` (Linux 5.19+) | E2E via `TCPSocket`; bytes match non-hotpath baseline byte-for-byte. With #1 + #2 simultaneously enabled, same bytes. |
| `io_uring_hotpath_buffer_exhaustion_spec.rb` (Linux 5.19+) | `HYPERION_IO_URING_HOTPATH_BUFS=4` + concurrent slow clients; assert `:io_uring_recv_enobufs` increments + no client dropped. |
| `io_uring_hotpath_fallback_engaged_spec.rb` (Linux 5.19+) | Inject synthetic ring failure (test seam: `HotpathRing#force_unhealthy!`); assert `:io_uring_hotpath_fallback_engaged` increments + subsequent conns succeed via accept4. |
| `io_uring_hotpath_abi_spec.rb` (cross-platform) | ABI v1 `.so` against v2 expectations → `hotpath_supported?` false + warn. |
| `io_uring_soak_smoke_spec.rb` (existing, `:perf`) | Extend with hotpath-on variant. |

### Acceptance

- `bin/check --full` green on macOS (fallback) and Linux 5.19+
  (hotpath active).
- New specs pass on both.
- `HYPERION_IO_URING_HOTPATH=1 ./bench/run_all.sh --row 1 --row 4` on
  `openclaw-vm`, three trials, median r/s ≥ +15% vs the post-#1
  baseline. Row 4 is the gate (read-path syscalls dominate); row 1
  may not move much (handle_static is already C-loop direct route).
- `parser_alloc_audit_spec.rb` shows the read-side String allocation
  eliminated when hotpath is active.
- Wire output byte-for-byte identical (paired with #1).

### Rollback

- Operator: unset `HYPERION_IO_URING_HOTPATH`. Default off was the
  design.
- Hard: revert the PR(s); existing `HYPERION_IO_URING_ACCEPT`
  accept-only path is unaffected.

---

## Sequencing

**Order: #3 → #1 → #2.**

Rationale: bench-only change is cheapest and most informative — it
answers "is the AR-CRUD gap a server bug or a workload mismatch?"
before we spend C-extension and Rust-extension scope on chasing it.
If PG closes AR rows, problem-class #3 is retired with a one-line
config win. If it doesn't, we learn something the original analysis
didn't predict, before sequencing #1/#2.

#1 ships before #2 because #2's send-SQE path calls into #1's C writer
at the seam; #1 standalone is a self-contained win on its own bench
gate.

### #3 PR set

1. Bench config + Gemfile + database.yml + bench script change.
2. PG setup added to `docs/BENCH_HOST_SETUP.md`.
3. Re-run `--rails` on openclaw, capture new table, commit
   `BENCH_HYPERION_RAILS.md` update.
4. Decision: did PG close the AR-CRUD gap? Update this spec doc with
   the answer.

### #1 PR set

1. `ext/hyperion_http/response_writer.c` + `extconf.rb` + `parser.c`
   shared-header lift.
2. `lib/hyperion/response_writer.rb` dispatcher; `lib/hyperion/http.rb`
   auto-require.
3. New specs (parity, fallback, errno, chunked).
4. Updated alloc-audit specs.
5. Bench numbers in PR body (rows 1, 4 minimum).

### #2 PR set (sub-PRs to keep review tractable)

1. **2.1** — Rust crate ABI v2 + new `hotpath_*` extern "C" entrypoints
   + buffer-ring impl. No Ruby integration yet.
2. **2.2** — `lib/hyperion/io_uring.rb` `HotpathRing` class + supported
   probe + policy resolver. Cross-platform fallback specs pass; new
   doc.
3. **2.3** — `lib/hyperion/connection.rb` integration +
   `lib/hyperion/server.rb` ring instantiation + CLI/config plumbing.
   E2E specs pass.
4. **2.4** — #1 ↔ #2 seam: `c_write_buffered_via_ring` in
   `response_writer.c` + dlsym wiring at `Init_hyperion_http()`.
5. **2.5** — Soak test extension + `IO_URING_HOTPATH.md` doc + bench
   gate. Default off in 2.18.0 minor cut.

**Default-flip schedule** is **not** committed in this spec. Documented
non-binding intent: `:auto` in 2.19, `:on` in 2.20 — revisit after one
minor's worth of soak. Same posture as the existing
`HYPERION_IO_URING_ACCEPT` 2.3-A → 2.15 default-flip.

## Acceptance gates per class (summary)

A class merges only when **all** are green:

- `bin/check --full` green on macOS and on Linux.
- New specs pass on every platform where they're not explicitly
  skipped. Linux-5.19-only specs skip cleanly on macOS / Linux <5.19;
  cross-platform specs (fallback, ABI, errno) pass everywhere.
- Wire-output parity specs pass byte-for-byte.
- For #1 and #2: bench gate hit on `openclaw-vm` with three-trial
  median.
- For #1 and #2: `parser_alloc_audit_spec.rb` shows the targeted
  alloc reduction.
- PR description includes `bench/run_all.sh` numbers from at least the
  targeted row (per project per-language perf rules).
- `docs/BENCH_HYPERION_RAILS.md` (#3) / `docs/IO_URING_HOTPATH.md`
  (#2) / inline doc comments in `response_writer.rb` (#1) updated.
- No new public surface change without a corresponding entry in
  `docs/CONFIGURATION.md` and the relevant feature doc.
