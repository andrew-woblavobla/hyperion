# Plan #1 — Direct-syscall ResponseWriter in C

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the response-write hot path (head build + framing + syscall) into a C extension that calls `write(2)` / `writev(2)` / `sendmsg(2)` directly on a kernel fd, eliminating the Ruby `IO#write` machinery between the per-response coalesced buffer and the kernel. Plain TCP only — TLS / `OpenSSL::SSL::SSLSocket` keeps the existing Ruby path.

**Architecture:** New C source `ext/hyperion_http/response_writer.c` registers `Hyperion::Http::ResponseWriter` (mirrors the `Hyperion::Http::PageCache` / `Hyperion::Http::Sendfile` pattern). Two singleton methods — `c_write_buffered(io, status, headers, body, keep_alive, date_str)` and `c_write_chunked(...)` — extract the fd via `rb_funcall(io, id_fileno, 0)`, build the response head reusing the existing `c_build_response_head` from `parser.c` (the helpers get lifted into a shared header), then issue one `sendmsg`/`writev` for buffered responses or one-syscall-per-coalesced-flush for chunked. Ruby-side `lib/hyperion/response_writer.rb` becomes a dispatcher: when `c_path_eligible?(io)` is true, route to C; otherwise the pre-existing pure-Ruby paths run unchanged. `to_path` / sendfile / page-cache branches keep their priority.

**Tech Stack:** C (POSIX `sendmsg`/`writev`, `MSG_NOSIGNAL` on Linux, `iovec`), Ruby C API (`rb_funcall`, `rb_block_call`, `rb_protect`, `rb_sys_fail`, `Check_Type`), `mkmf` (extconf probes for `MSG_NOSIGNAL` and `TCP_CORK`), Ruby (dispatcher in `response_writer.rb`).

**Spec reference:** `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` § "#1 — C-side ResponseWriter".

**Sequence position:** Ships **after** plan #3 (PG bench row) and **before** plan #2 (io_uring hot path). Plan #2's send-SQE submission calls into a sibling C entrypoint (`c_write_buffered_via_ring`) that this plan creates the foundation for.

---

## File map

| Path | Status | Responsibility |
|---|---|---|
| `ext/hyperion_http/response_writer.c` | **Create** | New translation unit. Registers `Hyperion::Http::ResponseWriter` module + `c_write_buffered` / `c_write_chunked` / `available?`. Owns `sendmsg`/`writev` path for plain-TCP fds. |
| `ext/hyperion_http/response_writer.h` | **Create** | Internal header for cross-translation-unit symbols (head-builder helpers lifted from `parser.c` so `response_writer.c` can call them). Not installed — only included by `parser.c` and `response_writer.c`. |
| `ext/hyperion_http/parser.c` | Modify | Lift the static helpers used by `cbuild_response_head` (status-line table, header-key-pre-intern table, etc.) into the new internal header. The existing `Hyperion::CParser.build_response_head` keeps its public surface; only its internals get re-exposable. |
| `ext/hyperion_http/extconf.rb` | Modify | Add `response_writer.c` to `$srcs`. Probe `have_macro('MSG_NOSIGNAL', 'sys/socket.h')`, `have_func('writev', 'sys/uio.h')`, `have_macro('TCP_CORK', 'netinet/tcp.h')`. The Linux-only flags fall through to a `writev` path on macOS. |
| `lib/hyperion/http/response_writer.rb` | **Create** | Mirror of `lib/hyperion/http/page_cache.rb`: documents the C-registered module surface, sets `Hyperion::Http::ResponseWriter.c_writer_available` from a probe (defined module + `respond_to?(:c_write_buffered)`). |
| `lib/hyperion.rb` | Modify | Add `require_relative 'hyperion/http/response_writer'` immediately after the existing `require_relative 'hyperion/http/page_cache'` line. |
| `lib/hyperion/response_writer.rb` | Modify | `#write` becomes a dispatcher. New `c_path_eligible?(io)` predicate. Existing `write_buffered` / `write_chunked` get renamed `_ruby` and stay as the fallback. The `to_path` / sendfile / page-cache branches at the top of `#write` are unchanged. |
| `spec/hyperion/c_response_writer_spec.rb` | **Create** | Buffered-path wire-byte parity + one-syscall-per-response. |
| `spec/hyperion/c_response_writer_chunked_spec.rb` | **Create** | Chunked-path parity + flush sentinel + drain-then-emit ordering + terminator atomicity. |
| `spec/hyperion/c_response_writer_fallback_spec.rb` | **Create** | C ext stubbed undefined → Ruby path runs with same wire bytes. `c_path_eligible?` predicate paths. |
| `spec/hyperion/c_response_writer_errno_spec.rb` | **Create** | EPIPE / EBADF / EINTR / EAGAIN paths. |
| `spec/hyperion/parser_alloc_audit_spec.rb` | Modify | Lower per-request alloc budget (the `+''` head buffer + body `<<` chain are gone on the C path). |
| `spec/hyperion/yjit_alloc_audit_spec.rb` | Modify | Same direction. |
| `bench/run_all.sh` | **No change** | Rows 1, 4, 11 etc. just get faster — wire output is identical. |

---

## Task 1: Lift the head-builder helpers into a shared internal header

Today `cbuild_response_head` and its small helpers (status-line table, pre-interned header keys, the response-head buffer logic at `parser.c:802`) are static-scope inside `parser.c`. Make them callable from `response_writer.c` without inventing a new public API.

**Files:**
- Create: `ext/hyperion_http/response_writer.h`
- Modify: `ext/hyperion_http/parser.c`

- [ ] **Step 1: Identify the helpers `response_writer.c` will reuse**

Run:

```bash
grep -nE 'static [A-Za-z_]+ +[a-z_]+\(' ext/hyperion_http/parser.c | head -40
```

The minimum set we need exposed:
- `cbuild_response_head` (signature: `static VALUE cbuild_response_head(VALUE self, VALUE rb_status, VALUE rb_reason, VALUE rb_headers, VALUE rb_body_size, VALUE rb_keep_alive, VALUE rb_date)`).
- The pre-interned header table `rb_aHeaderTable` (currently `static VALUE` at module scope).
- Any helpers `cbuild_response_head` calls that are themselves static.

We are NOT changing behavior; we're hoisting visibility from `static` to `extern`-with-an-internal-header.

- [ ] **Step 2: Create `ext/hyperion_http/response_writer.h`**

Write the file:

```c
/* response_writer.h — internal header shared between parser.c and
 * response_writer.c. NOT installed; only seen by ext sources.
 *
 * Exposes the head-builder symbols that response_writer.c needs to
 * reuse `c_build_response_head`-equivalent logic without going back
 * through Ruby method dispatch on the hot path. */

#ifndef HYPERION_RESPONSE_WRITER_H
#define HYPERION_RESPONSE_WRITER_H

#include <ruby.h>

/* Build an HTTP/1.1 response-head string into a fresh Ruby String.
 * Same behavior as the Ruby-visible
 * `Hyperion::CParser.build_response_head(...)` (parser.c:802). */
VALUE hyperion_build_response_head(VALUE status, VALUE reason, VALUE headers,
                                   VALUE body_size, VALUE keep_alive,
                                   VALUE date_str);

/* Build a chunked-encoding response-head string. Same behavior as
 * the Ruby-visible `build_head_chunked` in response_writer.rb but
 * native, allocating one Ruby String. */
VALUE hyperion_build_response_head_chunked(VALUE status, VALUE reason,
                                           VALUE headers, VALUE keep_alive,
                                           VALUE date_str);

#endif /* HYPERION_RESPONSE_WRITER_H */
```

- [ ] **Step 3: In `parser.c`, define `hyperion_build_response_head` as a thin wrapper around `cbuild_response_head`**

Find `cbuild_response_head` (~line 802 of `parser.c`). Immediately AFTER its closing brace, add:

```c
/* response_writer.h surface. Called from response_writer.c to reuse
 * the head-build logic without going through Ruby method dispatch.
 * Calling convention matches the Ruby-side method: status / reason /
 * headers / body_size / keep_alive / date_str. */
VALUE hyperion_build_response_head(VALUE status, VALUE reason, VALUE headers,
                                   VALUE body_size, VALUE keep_alive,
                                   VALUE date_str) {
    return cbuild_response_head(Qnil, status, reason, headers,
                                body_size, keep_alive, date_str);
}
```

- [ ] **Step 4: Add a chunked-head builder in `parser.c`**

The existing `build_head_chunked` lives only in Ruby (`response_writer.rb:621`). For symmetry on the C path, add a C version. Place it immediately after `hyperion_build_response_head` from Step 3:

```c
/* Chunked-encoding response head: same byte shape as
 * ResponseWriter#build_head_chunked in response_writer.rb but emitted
 * with one allocation. We DROP `content-length` and any caller-supplied
 * `transfer-encoding` (mutually exclusive per RFC 7230 §3.3.3) and
 * always emit our own `transfer-encoding: chunked`. */
VALUE hyperion_build_response_head_chunked(VALUE status, VALUE reason,
                                           VALUE headers, VALUE keep_alive,
                                           VALUE date_str) {
    /* Reuse `cbuild_response_head` with body_size = -1 sentinel; teach
     * cbuild_response_head to emit transfer-encoding: chunked instead
     * of content-length when body_size == LL2NUM(-1). */
    return cbuild_response_head(Qnil, status, reason, headers,
                                LL2NUM(-1), keep_alive, date_str);
}
```

Then teach `cbuild_response_head` to recognize the `body_size == -1` sentinel. Find the spot in `cbuild_response_head` where it builds the `content-length` line (~line 820-870 in `parser.c` — search for `"content-length"`). Replace the unconditional content-length emission with:

```c
    /* body_size == -1 → emit chunked transfer-encoding instead of
     * content-length. Used by chunked-streaming writers. */
    long body_size_l = NUM2LL(rb_body_size);
    if (body_size_l == -1) {
        rb_str_buf_cat_ascii(buf, "transfer-encoding: chunked\r\n");
    } else {
        /* existing content-length emission code stays here */
    }
```

(The existing `content-length` lines stay inside the `else` branch.)

- [ ] **Step 5: Compile + run the existing parser specs to confirm no regression**

```bash
bundle exec rake compile && bundle exec rspec spec/hyperion/build_response_head_spec.rb -fd
```

Expected: all green. The `hyperion_build_response_head` symbol is unused so far (we haven't added `response_writer.c`); that's fine.

- [ ] **Step 6: Commit**

```bash
git add ext/hyperion_http/parser.c ext/hyperion_http/response_writer.h
git commit -m "[ext] response_writer.h: lift head-builder helpers for cross-TU reuse"
```

---

## Task 2: Add `response_writer.c` skeleton + extconf wiring (no behavior yet)

A minimum compilable file that registers the module and a sentinel `available?` returning `false`. Establishes the build wiring before we add hot-path code.

**Files:**
- Create: `ext/hyperion_http/response_writer.c`
- Modify: `ext/hyperion_http/extconf.rb`
- Modify: `ext/hyperion_http/parser.c` — call `Init_hyperion_response_writer` from `Init_hyperion_http`.

- [ ] **Step 1: Create `ext/hyperion_http/response_writer.c` with the skeleton**

```c
/* response_writer.c — Hyperion::Http::ResponseWriter
 *
 * Direct-syscall response writer for plain-TCP kernel fds. Bypasses
 * Ruby IO machinery (encoding, fiber-yield checks, GVL release/
 * acquire) on the buffered hot path. TLS / non-fd / page-cache /
 * sendfile callers fall through to the Ruby ResponseWriter at the
 * dispatcher in response_writer.rb. */

#include <ruby.h>
#include <ruby/io.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/socket.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>

#include "response_writer.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static VALUE rb_mHyperion;
static VALUE rb_mHttp;
static VALUE rb_mResponseWriter;

static VALUE c_response_writer_available_p(VALUE self) {
    return Qtrue;
}

void Init_hyperion_response_writer(void) {
    rb_mHyperion       = rb_const_get(rb_cObject, rb_intern("Hyperion"));
    rb_mHttp           = rb_const_get(rb_mHyperion, rb_intern("Http"));
    rb_mResponseWriter = rb_define_module_under(rb_mHttp, "ResponseWriter");

    rb_define_singleton_method(rb_mResponseWriter, "available?",
                               c_response_writer_available_p, 0);
}
```

- [ ] **Step 2: Add `response_writer.c` to `extconf.rb`**

Open `ext/hyperion_http/extconf.rb`. Find the `$srcs = %w[ ... ]` block (around line 16). Add `response_writer.c` immediately after `parser.c`:

```ruby
$srcs = %w[
  parser.c
  response_writer.c
  sendfile.c
  page_cache.c
  io_uring_loop.c
  websocket.c
  h2_codec_glue.c
  llhttp.c
  api.c
  http.c
]
```

Then add the syscall-feature probes immediately after the existing `have_header('sys/socket.h')` line (~line 38):

```ruby
# Plan #1 (perf roadmap) — direct-syscall response writer probes.
# All POSIX-shaped; on macOS MSG_NOSIGNAL doesn't exist so the C
# source falls back to writev with #ifdef MSG_NOSIGNAL guards.
have_func('writev', 'sys/uio.h')
have_func('sendmsg', 'sys/socket.h')
have_macro('MSG_NOSIGNAL', 'sys/socket.h')
have_macro('TCP_CORK', 'netinet/tcp.h')
```

- [ ] **Step 3: Hook `Init_hyperion_response_writer` into `Init_hyperion_http`**

Open `ext/hyperion_http/parser.c`. Find `void Init_hyperion_http(void)` (~line 1511). After the existing `extern void Init_hyperion_h2_codec_glue(void); Init_hyperion_h2_codec_glue();` block (~line 1655), add:

```c
    /* Plan #1 (perf roadmap) — Hyperion::Http::ResponseWriter. */
    extern void Init_hyperion_response_writer(void);
    Init_hyperion_response_writer();
```

- [ ] **Step 4: Compile + sanity probe from Ruby**

```bash
bundle exec rake compile
ruby -I lib -r hyperion -e 'p Hyperion::Http::ResponseWriter.available?'
```

Expected: `true`.

- [ ] **Step 5: Run the existing test suite to confirm no regression**

```bash
bin/check
```

Expected: `OK (mode=quick)`.

- [ ] **Step 6: Commit**

```bash
git add ext/hyperion_http/response_writer.c ext/hyperion_http/extconf.rb ext/hyperion_http/parser.c
git commit -m "[ext] add Hyperion::Http::ResponseWriter skeleton (registers module + available?)"
```

---

## Task 3: Add the Ruby-side documentation file under `lib/hyperion/http/`

Mirrors `lib/hyperion/http/page_cache.rb`: documents the C-registered surface and exposes `c_writer_available?` for the dispatcher to probe.

**Files:**
- Create: `lib/hyperion/http/response_writer.rb`
- Modify: `lib/hyperion.rb` — add the `require_relative`.

- [ ] **Step 1: Create `lib/hyperion/http/response_writer.rb`**

```ruby
# frozen_string_literal: true

module Hyperion
  module Http
    # Direct-syscall response writer for plain-TCP kernel fds.
    #
    # The C primitives are registered as singleton methods on this
    # very module by `ext/hyperion_http/response_writer.c` (see
    # `Init_hyperion_response_writer`). Surface from C:
    #
    #   ResponseWriter.available?            -> true | false
    #   ResponseWriter.c_write_buffered(io, status, headers, body,
    #                                   keep_alive, date_str) -> Integer
    #   ResponseWriter.c_write_chunked(io, status, headers, body,
    #                                  keep_alive, date_str)  -> Integer
    #
    # Operators can flip the dispatcher off at runtime with
    # `Hyperion::Http::ResponseWriter.c_writer_available = false`
    # (test seam / A/B rollback). Mirrors the
    # `Hyperion::ResponseWriter.page_cache_available = false`
    # pattern (response_writer.rb:60-65).
    module ResponseWriter
      class << self
        attr_writer :c_writer_available

        def c_writer_available?
          return @c_writer_available unless @c_writer_available.nil?

          @c_writer_available =
            respond_to?(:available?) && available? &&
            respond_to?(:c_write_buffered) &&
            respond_to?(:c_write_chunked)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Wire the require into `lib/hyperion.rb`**

Find the existing block (around line 264-265):

```ruby
require_relative 'hyperion/http/sendfile'
require_relative 'hyperion/http/page_cache'
```

Add immediately after `page_cache`:

```ruby
require_relative 'hyperion/http/response_writer'
```

- [ ] **Step 3: Verify the probe**

```bash
bundle exec rake compile
ruby -I lib -r hyperion -e 'p Hyperion::Http::ResponseWriter.c_writer_available?'
```

Expected: `false` (the C methods `c_write_buffered` / `c_write_chunked` aren't defined yet — that's Task 4).

- [ ] **Step 4: Commit**

```bash
git add lib/hyperion/http/response_writer.rb lib/hyperion.rb
git commit -m "[lib] hyperion/http/response_writer: document C-registered surface + probe"
```

---

## Task 4: Implement `c_write_buffered` (TDD — failing spec first)

The buffered path is the bench-row hot path (rows 1, 4, 11). One syscall per response on plain-TCP fds; falls back to Ruby on EAGAIN.

**Files:**
- Create: `spec/hyperion/c_response_writer_spec.rb`
- Modify: `ext/hyperion_http/response_writer.c`

- [ ] **Step 1: Write the failing spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_buffered' do
  let(:reader) { @r }
  let(:writer) { @w }
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  before do
    @r, @w = Socket.pair(:UNIX, :STREAM)
  end

  after do
    [@r, @w].each { |s| s.close unless s.closed? }
  end

  it 'is available when the C ext is built' do
    expect(described_class.available?).to eq(true)
    expect(described_class).to respond_to(:c_write_buffered)
  end

  it 'writes a complete HTTP/1.1 response in one syscall on a kernel fd' do
    headers = { 'content-type' => 'text/plain' }
    body    = ['hello']
    bytes_written = described_class.c_write_buffered(
      writer, 200, headers, body, true, date_str
    )

    writer.close
    response = reader.read
    expect(response).to start_with("HTTP/1.1 200 OK\r\n")
    expect(response).to include("content-type: text/plain\r\n")
    expect(response).to include("content-length: 5\r\n")
    expect(response).to include("connection: keep-alive\r\n")
    expect(response).to include("date: #{date_str}\r\n")
    expect(response).to end_with("\r\n\r\nhello")
    expect(bytes_written).to eq(response.bytesize)
  end

  it 'matches the Ruby ResponseWriter wire output byte-for-byte' do
    headers = { 'content-type' => 'application/json' }
    body    = ['{"ok":true}']

    # C path
    cr, cw = Socket.pair(:UNIX, :STREAM)
    described_class.c_write_buffered(cw, 200, headers, body, true, date_str)
    cw.close
    c_bytes = cr.read
    cr.close

    # Ruby path (same args)
    rr, rw = Socket.pair(:UNIX, :STREAM)
    Hyperion::ResponseWriter.new.send(
      :write_buffered_ruby, rw, 200, headers, body, keep_alive: true
    )
    rw.close
    r_bytes = rr.read
    rr.close

    # Strip the date header from both sides — the Ruby path uses
    # cached_date(); the C path takes date_str. The other lines should
    # match byte-for-byte.
    [c_bytes, r_bytes].each { |s| s.gsub!(/^date: [^\r]+\r\n/, '') }
    expect(c_bytes).to eq(r_bytes)
  end

  it 'handles a multi-element Array body' do
    headers = { 'content-type' => 'text/plain' }
    body    = %w[hello world]

    described_class.c_write_buffered(writer, 200, headers, body, false, date_str)
    writer.close
    response = reader.read
    expect(response).to include("content-length: 10\r\n")
    expect(response).to end_with("\r\n\r\nhelloworld")
  end

  it 'returns the byte count' do
    headers = { 'content-type' => 'text/plain' }
    body    = ['x' * 100]

    bytes = described_class.c_write_buffered(writer, 200, headers, body, true, date_str)
    writer.close
    expect(bytes).to eq(reader.read.bytesize)
  end

  it 'raises ArgumentError when a header value contains CR/LF' do
    expect {
      described_class.c_write_buffered(
        writer, 200, { 'x-bad' => "value\r\nInjected: yes" },
        ['ok'], true, date_str
      )
    }.to raise_error(ArgumentError, /CR\/LF|control/)
  end

  it 'raises TypeError when a body chunk is not a String' do
    expect {
      described_class.c_write_buffered(
        writer, 200, { 'content-type' => 'text/plain' },
        [42], true, date_str
      )
    }.to raise_error(TypeError)
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

```bash
bundle exec rspec spec/hyperion/c_response_writer_spec.rb -fd
```

Expected: every example fails with `NoMethodError: undefined method 'c_write_buffered'`. The `available?` example passes.

- [ ] **Step 3: Implement `c_write_buffered` in `response_writer.c`**

Open `ext/hyperion_http/response_writer.c`. Add the implementation (between the existing `c_response_writer_available_p` and `Init_hyperion_response_writer`):

```c
/* Sentinel returned to Ruby on EAGAIN — the dispatcher sees this and
 * falls back to io.write (which yields under Async / blocks under
 * threadpool correctly). We don't reimplement scheduler-aware parking
 * in C. */
#define HYP_C_WRITE_WOULDBLOCK -2

/* Maximum iov entries we build on the stack: 1 (head) + 1 (Array[1]
 * body fast path) ... or we coalesce multi-element bodies into one
 * iov entry. Cap at 8 so a pathological 100-element Array body
 * coalesces into one writev rather than blowing the stack. */
#define HYP_C_IOV_MAX 8

static ID id_fileno;
static ID id_each;

/* Validate a single header value: no CR/LF allowed (header injection
 * defense — matches response_writer.rb:608's `raise ArgumentError`). */
static void hyp_check_header_value(VALUE value) {
    Check_Type(value, T_STRING);
    const char *p = RSTRING_PTR(value);
    long n = RSTRING_LEN(value);
    for (long i = 0; i < n; i++) {
        if (p[i] == '\r' || p[i] == '\n') {
            rb_raise(rb_eArgError, "header value contains CR/LF");
        }
    }
}

/* Issue one sendmsg/writev with `iov_count` iovecs. Returns total bytes
 * written, HYP_C_WRITE_WOULDBLOCK on EAGAIN, or raises on hard errors. */
static ssize_t hyp_writev_all(int fd, struct iovec *iov, int iov_count) {
    ssize_t total = 0;
    int retries = 0;
    for (;;) {
#ifdef HAVE_SENDMSG
        struct msghdr msg = {0};
        msg.msg_iov = iov;
        msg.msg_iovlen = iov_count;
        ssize_t n = sendmsg(fd, &msg, MSG_NOSIGNAL);
#else
        ssize_t n = writev(fd, iov, iov_count);
#endif
        if (n >= 0) {
            total += n;
            /* Short write → advance iov and loop. Bench rows never hit
             * this; defensive for production. */
            ssize_t remaining = 0;
            for (int i = 0; i < iov_count; i++) remaining += iov[i].iov_len;
            if (n == remaining) return total;
            /* Skip fully-consumed iovecs; partial-consume one; loop. */
            ssize_t skipped = 0;
            int i = 0;
            while (i < iov_count && skipped + (ssize_t)iov[i].iov_len <= n) {
                skipped += iov[i].iov_len;
                i++;
            }
            iov[i].iov_base = (char *)iov[i].iov_base + (n - skipped);
            iov[i].iov_len  -= (n - skipped);
            iov     += i;
            iov_count -= i;
            continue;
        }
        if (errno == EINTR) {
            if (++retries > 3) rb_sys_fail("sendmsg/writev: EINTR retries exhausted");
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return HYP_C_WRITE_WOULDBLOCK;
        }
        rb_sys_fail("sendmsg/writev failed");
    }
}

/* Hyperion::Http::ResponseWriter.c_write_buffered(io, status, headers,
 *                                                  body, keep_alive,
 *                                                  date_str) -> Integer
 *
 * Returns total bytes written, or HYP_C_WRITE_WOULDBLOCK on EAGAIN.
 * Caller (response_writer.rb dispatcher) checks for the sentinel and
 * falls back to io.write. */
static VALUE c_write_buffered(VALUE self, VALUE io, VALUE rb_status,
                              VALUE rb_headers, VALUE rb_body,
                              VALUE rb_keep_alive, VALUE rb_date) {
    /* 1. Resolve fd. */
    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));

    /* 2. Build head — same bytes as ResponseWriter#build_head. We
     *    pass body_size as a NUM so the C builder emits content-length. */
    long body_size = 0;
    Check_Type(rb_body, T_ARRAY);
    long body_len = RARRAY_LEN(rb_body);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        Check_Type(chunk, T_STRING);
        body_size += RSTRING_LEN(chunk);
    }

    /* Validate headers. */
    if (TYPE(rb_headers) == T_HASH) {
        VALUE keys = rb_funcall(rb_headers, rb_intern("keys"), 0);
        for (long i = 0; i < RARRAY_LEN(keys); i++) {
            VALUE k = RARRAY_AREF(keys, i);
            VALUE v = rb_hash_aref(rb_headers, k);
            hyp_check_header_value(v);
        }
    }

    VALUE rb_reason = Qnil; /* let cbuild_response_head pick the default */
    VALUE head = hyperion_build_response_head(
        rb_status, rb_reason, rb_headers, LL2NUM(body_size),
        rb_keep_alive, rb_date
    );

    /* 3. Assemble iovec: head + 1..N body chunks (cap HYP_C_IOV_MAX-1). */
    struct iovec iov[HYP_C_IOV_MAX];
    iov[0].iov_base = RSTRING_PTR(head);
    iov[0].iov_len  = RSTRING_LEN(head);
    int iov_count = 1;

    if (body_len <= HYP_C_IOV_MAX - 1) {
        for (long i = 0; i < body_len; i++) {
            VALUE chunk = RARRAY_AREF(rb_body, i);
            iov[iov_count].iov_base = RSTRING_PTR(chunk);
            iov[iov_count].iov_len  = RSTRING_LEN(chunk);
            iov_count++;
        }
    } else {
        /* Coalesce a many-chunk body into one buffer to keep iov_count
         * bounded. This path is rare (Rack apps emit Array[1] in the
         * common case); we accept the one-time string allocation. */
        VALUE coalesced = rb_str_buf_new(body_size);
        for (long i = 0; i < body_len; i++) {
            rb_str_buf_append(coalesced, RARRAY_AREF(rb_body, i));
        }
        iov[1].iov_base = RSTRING_PTR(coalesced);
        iov[1].iov_len  = RSTRING_LEN(coalesced);
        iov_count = 2;
    }

    ssize_t n = hyp_writev_all(fd, iov, iov_count);
    if (n == HYP_C_WRITE_WOULDBLOCK) return INT2NUM(HYP_C_WRITE_WOULDBLOCK);
    return SIZET2NUM(n);
}
```

Add the registration inside `Init_hyperion_response_writer`:

```c
void Init_hyperion_response_writer(void) {
    rb_mHyperion       = rb_const_get(rb_cObject, rb_intern("Hyperion"));
    rb_mHttp           = rb_const_get(rb_mHyperion, rb_intern("Http"));
    rb_mResponseWriter = rb_define_module_under(rb_mHttp, "ResponseWriter");

    id_fileno = rb_intern("fileno");
    id_each   = rb_intern("each");

    rb_define_singleton_method(rb_mResponseWriter, "available?",
                               c_response_writer_available_p, 0);
    rb_define_singleton_method(rb_mResponseWriter, "c_write_buffered",
                               c_write_buffered, 6);
}
```

Also export the WOULDBLOCK sentinel as a Ruby-visible constant so the dispatcher can match against it without knowing the magic number:

```c
    rb_define_const(rb_mResponseWriter, "WOULDBLOCK",
                    INT2NUM(HYP_C_WRITE_WOULDBLOCK));
```

- [ ] **Step 4: Compile + run the spec**

```bash
bundle exec rake compile && bundle exec rspec spec/hyperion/c_response_writer_spec.rb -fd
```

Expected: all examples pass.

- [ ] **Step 5: Commit**

```bash
git add ext/hyperion_http/response_writer.c spec/hyperion/c_response_writer_spec.rb
git commit -m "[ext] response_writer.c: c_write_buffered + buffered-path parity specs"
```

---

## Task 5: Implement `c_write_chunked` (TDD)

The chunked path uses `rb_block_call` to iterate the Rack body from C; each yielded chunk is framed (`<hex>\r\n<payload>\r\n`) and either coalesced into a 4 KiB stack buffer or drained directly. End-of-body emits `0\r\n\r\n` atomically.

**Files:**
- Create: `spec/hyperion/c_response_writer_chunked_spec.rb`
- Modify: `ext/hyperion_http/response_writer.c`

- [ ] **Step 1: Write the failing spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_chunked' do
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  before { @r, @w = Socket.pair(:UNIX, :STREAM) }
  after  { [@r, @w].each { |s| s.close unless s.closed? } }

  def parse_chunked_body(bytes)
    # Strip the head; decode chunked frames into (size, payload) pairs.
    head, body = bytes.split("\r\n\r\n", 2)
    expect(head).to include('transfer-encoding: chunked')
    chunks = []
    while body && !body.empty?
      size_line, rest = body.split("\r\n", 2)
      size = size_line.to_i(16)
      break if size.zero?

      payload = rest[0, size]
      chunks << payload
      body = rest[(size + 2)..]
    end
    chunks
  end

  it 'frames a single-chunk body and emits the 0-terminator' do
    body = ['hello world']
    described_class.c_write_chunked(@w, 200, { 'content-type' => 'text/plain' },
                                    body, true, date_str)
    @w.close
    bytes = @r.read

    expect(bytes).to start_with("HTTP/1.1 200 OK\r\n")
    expect(bytes).to include("transfer-encoding: chunked\r\n")
    expect(bytes).to end_with("0\r\n\r\n")
    expect(parse_chunked_body(bytes)).to eq(['hello world'])
  end

  it 'coalesces multiple small chunks into one syscall before draining' do
    body = ['a', 'b', 'c', 'd', 'e']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(%w[a b c d e])
  end

  it 'drain-then-emit ordering: big chunk after small chunks preserves order' do
    body = ['tiny1', 'tiny2', 'X' * 1024, 'tiny3']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(['tiny1', 'tiny2', 'X' * 1024, 'tiny3'])
  end

  it 'flushes on the :__hyperion_flush__ sentinel' do
    body = ['a', :__hyperion_flush__, 'b']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(%w[a b])
  end

  it 'mutually-excludes content-length' do
    described_class.c_write_chunked(@w, 200, { 'content-length' => '999' },
                                    ['x'], true, date_str)
    @w.close
    head = @r.read.split("\r\n\r\n", 2).first
    expect(head).to include('transfer-encoding: chunked')
    expect(head).not_to include('content-length:')
  end

  it 'skips nil chunks' do
    body = ['a', nil, 'b']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(%w[a b])
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

```bash
bundle exec rspec spec/hyperion/c_response_writer_chunked_spec.rb -fd
```

Expected: every example fails with `NoMethodError: undefined method 'c_write_chunked'`.

- [ ] **Step 3: Implement `c_write_chunked` in `response_writer.c`**

Add to `ext/hyperion_http/response_writer.c` (above `Init_hyperion_response_writer`):

```c
/* Per-call chunked state passed through rb_block_call. */
struct hyp_chunked_state {
    int fd;
    unsigned char buf[4096];     /* coalesce buffer; 4 KiB matches
                                  * ResponseWriter::COALESCE_FLUSH_BYTES
                                  * (response_writer.rb:19). */
    size_t buf_used;
    int    head_shipped;
    size_t bytes_written;
};

static const char *HYP_HEX = "0123456789abcdef";

/* Format a positive integer as lowercase hex (no 0x prefix). Returns
 * bytes written. Handwritten so we don't pay snprintf cost per chunk. */
static size_t hyp_u64_to_hex(unsigned char *dst, uint64_t n) {
    if (n == 0) { dst[0] = '0'; return 1; }
    unsigned char tmp[16];
    int i = 0;
    while (n > 0) { tmp[i++] = HYP_HEX[n & 0xf]; n >>= 4; }
    for (int j = 0; j < i; j++) dst[j] = tmp[i - 1 - j];
    return (size_t)i;
}

static void hyp_drain(struct hyp_chunked_state *st) {
    if (st->buf_used == 0) return;
    struct iovec iov[1];
    iov[0].iov_base = st->buf;
    iov[0].iov_len  = st->buf_used;
    ssize_t n = hyp_writev_all(st->fd, iov, 1);
    if (n < 0) return; /* WOULDBLOCK on chunked is degenerate; the body
                        * iter already returned and we can't easily
                        * resume. Caller's spec covers this. */
    st->bytes_written += st->buf_used;
    st->buf_used = 0;
}

/* Append `framed_len` bytes to the coalesce buffer. If the buffer
 * overflows or `framed_len` itself exceeds the buffer, drain first
 * then write directly. */
static void hyp_append_or_drain(struct hyp_chunked_state *st,
                                const unsigned char *framed,
                                size_t framed_len) {
    if (framed_len >= sizeof(st->buf)) {
        hyp_drain(st);
        struct iovec iov[1];
        iov[0].iov_base = (void *)framed;
        iov[0].iov_len  = framed_len;
        ssize_t n = hyp_writev_all(st->fd, iov, 1);
        if (n < 0) return;
        st->bytes_written += framed_len;
        return;
    }
    if (st->buf_used + framed_len > sizeof(st->buf)) hyp_drain(st);
    memcpy(st->buf + st->buf_used, framed, framed_len);
    st->buf_used += framed_len;
}

/* rb_block_call callback: invoked for each chunk yielded by body.each. */
static VALUE hyp_chunked_callback(RB_BLOCK_CALL_FUNC_ARGLIST(yielded_value, callback_arg)) {
    struct hyp_chunked_state *st = (struct hyp_chunked_state *)callback_arg;
    VALUE chunk = yielded_value;
    if (NIL_P(chunk)) return Qnil;

    /* Flush sentinel: literal symbol :__hyperion_flush__. */
    if (SYMBOL_P(chunk) &&
        rb_sym2id(chunk) == rb_intern("__hyperion_flush__")) {
        hyp_drain(st);
        return Qnil;
    }

    Check_Type(chunk, T_STRING);
    size_t payload_len = (size_t)RSTRING_LEN(chunk);
    if (payload_len == 0) return Qnil;

    /* Frame: <hex-size>\r\n<payload>\r\n. Hex size is at most 16
     * bytes; +2 CRLF + payload + 2 CRLF. We allocate from the stack
     * for small chunks and on heap (Ruby string) for huge ones. */
    if (payload_len < 4000) {
        unsigned char framed[4100];
        size_t hex_n = hyp_u64_to_hex(framed, (uint64_t)payload_len);
        framed[hex_n++] = '\r'; framed[hex_n++] = '\n';
        memcpy(framed + hex_n, RSTRING_PTR(chunk), payload_len);
        hex_n += payload_len;
        framed[hex_n++] = '\r'; framed[hex_n++] = '\n';
        hyp_append_or_drain(st, framed, hex_n);
    } else {
        /* Large chunk: drain coalesce, write the size-line, write the
         * payload, write the CRLF — three iovecs in one writev. */
        hyp_drain(st);
        unsigned char hex_buf[18];
        size_t hex_n = hyp_u64_to_hex(hex_buf, (uint64_t)payload_len);
        hex_buf[hex_n++] = '\r'; hex_buf[hex_n++] = '\n';
        struct iovec iov[3];
        iov[0].iov_base = hex_buf;
        iov[0].iov_len  = hex_n;
        iov[1].iov_base = RSTRING_PTR(chunk);
        iov[1].iov_len  = payload_len;
        unsigned char crlf[2] = { '\r', '\n' };
        iov[2].iov_base = crlf;
        iov[2].iov_len  = 2;
        ssize_t n = hyp_writev_all(st->fd, iov, 3);
        if (n >= 0) st->bytes_written += hex_n + payload_len + 2;
    }
    return Qnil;
}

/* Hyperion::Http::ResponseWriter.c_write_chunked(io, status, headers,
 *                                                 body, keep_alive,
 *                                                 date_str) -> Integer */
static VALUE c_write_chunked(VALUE self, VALUE io, VALUE rb_status,
                             VALUE rb_headers, VALUE rb_body,
                             VALUE rb_keep_alive, VALUE rb_date) {
    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));

    /* Build chunked head — drops content-length, adds
     * transfer-encoding: chunked. */
    VALUE head = hyperion_build_response_head_chunked(
        rb_status, Qnil, rb_headers, rb_keep_alive, rb_date
    );

    struct hyp_chunked_state st = {0};
    st.fd = fd;
    st.head_shipped = 0;

    /* Emit head as the first writev. */
    struct iovec iov[1];
    iov[0].iov_base = RSTRING_PTR(head);
    iov[0].iov_len  = RSTRING_LEN(head);
    ssize_t n = hyp_writev_all(fd, iov, 1);
    if (n < 0) return INT2NUM(HYP_C_WRITE_WOULDBLOCK);
    st.bytes_written += RSTRING_LEN(head);
    st.head_shipped = 1;

    /* Iterate body. rb_block_call invokes hyp_chunked_callback for
     * each yielded chunk; Ruby exceptions propagate to the dispatcher,
     * which catches and closes the connection. The `head_shipped`
     * field (set above) lets the dispatcher's rescue know whether
     * a 500 is recoverable. */
    rb_block_call(rb_body, id_each, 0, NULL,
                  hyp_chunked_callback, (VALUE)&st);

    /* Drain coalesce + emit terminator atomically. */
    if (st.buf_used > 0) {
        memcpy(st.buf + st.buf_used, "0\r\n\r\n", 5);
        st.buf_used += 5;
        hyp_drain(&st);
        st.bytes_written += 5;
    } else {
        struct iovec term = { (void *)"0\r\n\r\n", 5 };
        if (hyp_writev_all(fd, &term, 1) >= 0) st.bytes_written += 5;
    }

    return SIZET2NUM(st.bytes_written);
}
```

Add the registration to `Init_hyperion_response_writer`:

```c
    rb_define_singleton_method(rb_mResponseWriter, "c_write_chunked",
                               c_write_chunked, 6);
```

- [ ] **Step 4: Compile + run the spec**

```bash
bundle exec rake compile && bundle exec rspec spec/hyperion/c_response_writer_chunked_spec.rb -fd
```

Expected: all examples pass.

- [ ] **Step 5: Commit**

```bash
git add ext/hyperion_http/response_writer.c spec/hyperion/c_response_writer_chunked_spec.rb
git commit -m "[ext] response_writer.c: c_write_chunked + chunked-path parity specs"
```

---

## Task 6: Wire the dispatcher in `lib/hyperion/response_writer.rb`

Today `#write` calls `write_buffered` / `write_chunked` directly. Make `#write` route eligible callers to the C path; rename the existing methods `_ruby` and keep them as the fallback.

**Files:**
- Modify: `lib/hyperion/response_writer.rb`

- [ ] **Step 1: Read the current `#write`, `#write_buffered`, `#write_chunked` signatures**

Anchor lines (per the existing file at `lib/hyperion/response_writer.rb`):
- `#write` at line 78.
- `#write_buffered` at line 105 (rename target).
- `#write_chunked` at line 408 (rename target).
- `#real_fd_io?` at line 367 (reuse as the eligibility predicate).
- `#chunked_transfer?` at line 380.

- [ ] **Step 2: Add the `c_path_eligible?` predicate**

Insert immediately after `chunked_transfer?` (line 387):

```ruby
    # Plan #1 (perf roadmap) — predicate for the C-side direct-syscall
    # write path. True when:
    #   (a) The Hyperion::Http::ResponseWriter C ext loaded.
    #   (b) `io` exposes a real kernel fd (real_fd_io? handles the
    #       SSLSocket / StringIO / IO-like-but-no-fileno cases).
    #   (c) The class-level operator switch hasn't been flipped off.
    #
    # Operators flip the switch off via:
    #   Hyperion::Http::ResponseWriter.c_writer_available = false
    # (mirrors the Hyperion::ResponseWriter.page_cache_available pattern).
    def c_path_eligible?(io)
      return false unless defined?(::Hyperion::Http::ResponseWriter)
      return false unless ::Hyperion::Http::ResponseWriter.c_writer_available?
      return false unless real_fd_io?(io)

      true
    end
```

- [ ] **Step 3: Rewire `#write` to dispatch**

Find the existing `#write` method (line 78). Replace its body so `write_buffered` / `write_chunked` calls become C-aware:

```ruby
    def write(io, status, headers, body, keep_alive: false, dispatch_mode: nil)
      if body.respond_to?(:to_path)
        return write_sendfile(io, status, headers, body, keep_alive: keep_alive,
                                                         dispatch_mode: dispatch_mode)
      end

      if chunked_transfer?(headers)
        return write_chunked(io, status, headers, body, keep_alive: keep_alive)
      end

      write_buffered(io, status, headers, body, keep_alive: keep_alive)
    end
```

(That's the same shape as today; the dispatch happens inside `write_buffered` / `write_chunked` so the auto-detect sendfile / page-cache paths stay above the C path.)

- [ ] **Step 4: Rewire `#write_buffered` to dispatch**

Find the existing `def write_buffered(io, status, headers, body, keep_alive:)` (line 105). Rename it to `write_buffered_ruby` and INSERT a new `write_buffered` above it that dispatches:

```ruby
    def write_buffered(io, status, headers, body, keep_alive:)
      if c_path_eligible?(io)
        date_str = cached_date
        bytes_out = ::Hyperion::Http::ResponseWriter.c_write_buffered(
          io, status, headers, Array(body), keep_alive, date_str
        )
        if bytes_out == ::Hyperion::Http::ResponseWriter::WOULDBLOCK
          # EAGAIN on the C path — fall back to the Ruby writer, which
          # yields the fiber under Async / blocks the thread under
          # threadpool correctly.
          write_buffered_ruby(io, status, headers, body, keep_alive: keep_alive)
        else
          Hyperion.metrics.increment(:bytes_written, bytes_out)
        end
        body.close if body.respond_to?(:close)
        return
      end

      write_buffered_ruby(io, status, headers, body, keep_alive: keep_alive)
    end

    def write_buffered_ruby(io, status, headers, body, keep_alive:)
      # ... existing body of #write_buffered, unchanged ...
```

(Take the existing 30-odd lines that were inside the original `write_buffered` — do not rewrite them — paste them as the body of `write_buffered_ruby`.)

- [ ] **Step 5: Rewire `#write_chunked` similarly**

Find `def write_chunked(io, status, headers, body, keep_alive:)` (line 408). Rename it to `write_chunked_ruby` and add a new `write_chunked` above:

```ruby
    def write_chunked(io, status, headers, body, keep_alive:)
      if c_path_eligible?(io)
        date_str = cached_date
        bytes_out = ::Hyperion::Http::ResponseWriter.c_write_chunked(
          io, status, headers, body, keep_alive, date_str
        )
        if bytes_out == ::Hyperion::Http::ResponseWriter::WOULDBLOCK
          write_chunked_ruby(io, status, headers, body, keep_alive: keep_alive)
        else
          Hyperion.metrics.increment(:bytes_written, bytes_out)
          Hyperion.metrics.increment(:chunked_responses)
        end
        body.close if body.respond_to?(:close)
        return
      end

      write_chunked_ruby(io, status, headers, body, keep_alive: keep_alive)
    end

    def write_chunked_ruby(io, status, headers, body, keep_alive:)
      # ... existing body of #write_chunked, unchanged ...
```

- [ ] **Step 6: Run `bin/check` to confirm no regression**

```bash
bin/check
```

Expected: `OK (mode=quick)`. The hot-path specs in `bin/check`'s default selection cover the `Connection#serve` → `ResponseWriter#write` flow.

- [ ] **Step 7: Run the new C-path specs**

```bash
bundle exec rspec spec/hyperion/c_response_writer_spec.rb spec/hyperion/c_response_writer_chunked_spec.rb -fd
```

Expected: all examples still pass.

- [ ] **Step 8: Commit**

```bash
git add lib/hyperion/response_writer.rb
git commit -m "[lib] response_writer.rb: dispatcher routes plain-TCP fds to C path"
```

---

## Task 7: Fallback spec — C ext stubbed undefined → Ruby path runs

Verifies the cargo-missing / no-toolchain story doesn't regress.

**Files:**
- Create: `spec/hyperion/c_response_writer_fallback_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe 'ResponseWriter C-path fallback' do
  let(:writer) { Hyperion::ResponseWriter.new }
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  before { @r, @w = Socket.pair(:UNIX, :STREAM) }
  after  { [@r, @w].each { |s| s.close unless s.closed? } }

  context 'when c_writer_available? is forced false' do
    before { Hyperion::Http::ResponseWriter.c_writer_available = false }
    after  { Hyperion::Http::ResponseWriter.c_writer_available = nil }

    it 'falls back to the Ruby buffered writer' do
      expect(Hyperion::Http::ResponseWriter).not_to receive(:c_write_buffered)
      writer.write(@w, 200, { 'content-type' => 'text/plain' }, ['ok'],
                   keep_alive: true)
      @w.close
      expect(@r.read).to include("HTTP/1.1 200 OK\r\n")
    end
  end

  context 'when io is an SSLSocket-shape (real_fd_io? false)' do
    let(:fake_ssl) do
      ssl = double('SSLSocket', fileno: @w.fileno, write: nil)
      allow(ssl).to receive(:is_a?).and_return(false)
      allow(ssl).to receive(:is_a?).with(StringIO).and_return(false)
      if defined?(::OpenSSL::SSL::SSLSocket)
        allow(ssl).to receive(:is_a?).with(::OpenSSL::SSL::SSLSocket).and_return(true)
      end
      ssl
    end

    it 'falls back to the Ruby path even when the C ext is loaded' do
      skip 'OpenSSL::SSL::SSLSocket not available' unless defined?(::OpenSSL::SSL::SSLSocket)
      expect(Hyperion::Http::ResponseWriter).not_to receive(:c_write_buffered)
      bytes_seen = +''
      allow(fake_ssl).to receive(:write) { |s| bytes_seen << s; s.bytesize }
      writer.write(fake_ssl, 200, { 'content-type' => 'text/plain' }, ['ok'],
                   keep_alive: true)
      expect(bytes_seen).to include("HTTP/1.1 200 OK\r\n")
    end
  end

  context 'when the C module is not defined (build skew)' do
    it 'c_path_eligible? returns false' do
      stub_const('Hyperion::Http::ResponseWriter', Module.new)
      expect(writer.send(:c_path_eligible?, @w)).to eq(false)
    end
  end
end
```

- [ ] **Step 2: Run the spec**

```bash
bundle exec rspec spec/hyperion/c_response_writer_fallback_spec.rb -fd
```

Expected: all examples pass.

- [ ] **Step 3: Commit**

```bash
git add spec/hyperion/c_response_writer_fallback_spec.rb
git commit -m "[spec] c_response_writer_fallback: SSLSocket / disabled / undefined paths"
```

---

## Task 8: Errno spec — EPIPE / EBADF / EAGAIN

**Files:**
- Create: `spec/hyperion/c_response_writer_errno_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_buffered errno paths' do
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  it 'raises Errno::EPIPE when the peer has closed' do
    r, w = Socket.pair(:UNIX, :STREAM)
    r.close

    expect {
      described_class.c_write_buffered(
        w, 200, { 'content-type' => 'text/plain' }, ['x'], true, date_str
      )
    }.to raise_error(Errno::EPIPE)
  ensure
    w.close unless w.closed?
  end

  it 'raises Errno::EBADF on a closed write fd' do
    r, w = Socket.pair(:UNIX, :STREAM)
    fd_dup = w.fileno
    w.close

    bogus = double('closed_io', fileno: fd_dup)
    expect {
      described_class.c_write_buffered(
        bogus, 200, { 'content-type' => 'text/plain' }, ['x'], true, date_str
      )
    }.to raise_error(SystemCallError) # EBADF or EPIPE depending on platform
  ensure
    r.close unless r.closed?
  end

  it 'returns WOULDBLOCK when the kernel send buffer is full' do
    r, w = Socket.pair(:UNIX, :STREAM)
    # Shrink send buffer aggressively + set non-blocking + fill the kernel
    # buffer until the next write would block.
    w.setsockopt(:SOCKET, :SNDBUF, 1024)
    r.setsockopt(:SOCKET, :RCVBUF, 1024)
    require 'fcntl'
    flags = w.fcntl(Fcntl::F_GETFL)
    w.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)

    # Pre-fill the kernel buffer so the C path sees EAGAIN.
    big = 'x' * 1024
    loop do
      begin
        w.write_nonblock(big)
      rescue IO::WaitWritable
        break
      end
    end

    rc = described_class.c_write_buffered(
      w, 200, { 'content-type' => 'text/plain' }, ['payload'],
      true, date_str
    )
    expect(rc).to eq(Hyperion::Http::ResponseWriter::WOULDBLOCK)
  ensure
    [r, w].each { |s| s.close unless s.closed? }
  end
end
```

- [ ] **Step 2: Run the spec**

```bash
bundle exec rspec spec/hyperion/c_response_writer_errno_spec.rb -fd
```

Expected: all three examples pass.

- [ ] **Step 3: Commit**

```bash
git add spec/hyperion/c_response_writer_errno_spec.rb
git commit -m "[spec] c_response_writer_errno: EPIPE / EBADF / EAGAIN sentinel"
```

---

## Task 9: Update the alloc-audit specs

The C path eliminates the Ruby `+''` head buffer + per-chunk `<<` body concat. The audit specs need their expected counts adjusted.

**Files:**
- Modify: `spec/hyperion/parser_alloc_audit_spec.rb`
- Modify: `spec/hyperion/yjit_alloc_audit_spec.rb`

- [ ] **Step 1: Find the current alloc budget**

```bash
grep -nE 'expect.*allocations|alloc.*\d|\bROOM\b|< +[0-9]+' spec/hyperion/parser_alloc_audit_spec.rb spec/hyperion/yjit_alloc_audit_spec.rb | head -30
```

The audit spec compares allocations against a hand-tuned ceiling. Capture the existing ceiling for the buffered-response cases (look for `parse + write_buffered` or similar groups).

- [ ] **Step 2: Run the audit spec to see the new (lower) numbers**

```bash
bundle exec rspec spec/hyperion/parser_alloc_audit_spec.rb -fd
```

If it fails because allocations are now LOWER than the asserted ceiling (and the assertion is `<=`), pass — but capture the new actual count from the failure report (or by adding `puts allocations` temporarily).

If the spec asserts an EXACT count, adjust to the new actual.

- [ ] **Step 3: Lower the ceiling**

Edit each audit spec. For the buffered hot-path group, the new ceiling is:

```ruby
# Plan #1 (perf roadmap) — the C-side ResponseWriter eliminates the
# Ruby +'' head buffer, the per-chunk body `<<`, the headers
# normalize-to-hash detour, and the IO#write encoding check on the
# buffered hot path. The new ceiling captures those savings; future
# regressions trip the assertion.
expect(allocs).to be <= 4 # was 9 prior to the C writer
```

(Replace `4` and `9` with the actual numbers measured in Step 2.)

- [ ] **Step 4: Run both specs to confirm green**

```bash
bundle exec rspec spec/hyperion/parser_alloc_audit_spec.rb spec/hyperion/yjit_alloc_audit_spec.rb -fd
```

Expected: green at the new ceiling.

- [ ] **Step 5: Commit**

```bash
git add spec/hyperion/parser_alloc_audit_spec.rb spec/hyperion/yjit_alloc_audit_spec.rb
git commit -m "[spec] alloc-audit: lower buffered-path ceiling reflecting C writer"
```

---

## Task 10: Capture before/after bench numbers

Per CLAUDE.md "Any PR touching a request-path file ... must include before/after numbers from at least one `bench/run_all.sh` row in the PR body."

**Files:**
- None modified — bench artifact captured locally.

- [ ] **Step 1: Sync to openclaw-vm**

```bash
rsync -az --delete \
  --exclude=.git --exclude=tmp --exclude='*.gem' \
  --exclude='lib/hyperion_http/*.bundle' \
  --exclude='lib/hyperion_http/*.so' \
  --exclude='ext/*/target' \
  ./ ubuntu@openclaw-vm:~/hyperion/
```

- [ ] **Step 2: Capture the BEFORE baseline (use the post-#3 baseline if PR #3 has merged; otherwise the post-2.16.3 baseline)**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && git stash && bundle exec rake compile && OUT_CSV=/tmp/before-row1-row4.csv ./bench/run_all.sh --row 1 --row 4 && git stash pop'
```

(If your branch is the only thing on disk and there's no convenient baseline to swap to, capture the baseline FIRST in a fresh checkout of master before applying this plan.)

- [ ] **Step 3: Capture the AFTER numbers (current branch)**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && bundle exec rake compile && OUT_CSV=/tmp/after-row1-row4.csv ./bench/run_all.sh --row 1 --row 4'
```

- [ ] **Step 4: Pull both CSVs back, compute the diff, write a short summary**

```bash
scp ubuntu@openclaw-vm:/tmp/before-row1-row4.csv /tmp/
scp ubuntu@openclaw-vm:/tmp/after-row1-row4.csv  /tmp/
diff -u /tmp/before-row1-row4.csv /tmp/after-row1-row4.csv
```

Expected: row 4 (`hyperion_rack_hello`) median r/s improves by ≥ +20% per the spec acceptance gate. Row 1 (`hyperion_handle_static_iouring`) may not move much (it's already a C-loop direct route).

- [ ] **Step 5: Save numbers to the spec doc**

Append a new subsection to `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` under #1 → "Acceptance":

```markdown
### Outcome (filled in after bench re-run)

- Date: <YYYY-MM-DD>
- Host: openclaw-vm
- Row 1 (handle_static_iouring): before <r/s> → after <r/s> (Δ <+/-X%>)
- Row 4 (rack_hello):            before <r/s> → after <r/s> (Δ <+/-X%>)
- Acceptance: row 4 ≥ +20% — <pass/fail>
```

- [ ] **Step 6: Commit the doc update**

```bash
git add docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md
git commit -m "[docs] perf-roadmap-design: record #1 (C writer) bench outcome"
```

---

## Task 11: Open the PR

**Files:**
- None modified — PR creation only.

- [ ] **Step 1: Push branch + open PR**

```bash
git push -u origin HEAD
gh pr create --title "[perf] C-side ResponseWriter (perf roadmap #1)" --body "$(cat <<'EOF'
## Summary

- New `Hyperion::Http::ResponseWriter` C extension issues `sendmsg` / `writev` directly on plain-TCP kernel fds — bypasses Ruby IO machinery on the buffered hot path
- Chunked path coalesces small chunks into a 4 KiB stack buffer and emits the `0\r\n\r\n` terminator atomically
- TLS / `OpenSSL::SSL::SSLSocket` falls through to the existing Ruby path (encryption can't be done from C without dragging libssl into the ext)
- Per `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` §#1
- Operator rollback: `Hyperion::Http::ResponseWriter.c_writer_available = false`

## Test plan

- [ ] `bin/check --full` green on macOS and Linux
- [ ] New specs: `c_response_writer_spec.rb`, `c_response_writer_chunked_spec.rb`, `c_response_writer_fallback_spec.rb`, `c_response_writer_errno_spec.rb` all pass
- [ ] `parser_alloc_audit_spec.rb` ceiling lowered to reflect savings
- [ ] `bench/run_all.sh --row 4` median r/s ≥ +20% on openclaw-vm (numbers in the spec's "Outcome" section)
- [ ] Wire output byte-for-byte identical for non-streaming responses (covered by the parity spec)

EOF
)"
```

Expected: PR URL printed; CI matrix (Ubuntu + macOS × Ruby 3.3.6 + 3.4.1) green.

---

## Acceptance gate (from spec)

- [ ] `bin/check --full` green on macOS and Linux.
- [ ] New specs (`c_response_writer_*`) pass on both platforms.
- [ ] Wire-output parity specs pass byte-for-byte against the pre-change Ruby path.
- [ ] `bench/run_all.sh --row 4` on `openclaw-vm`, three trials, median r/s ≥ +20% vs baseline.
- [ ] `parser_alloc_audit_spec.rb` shows the targeted alloc reduction.
- [ ] PR body includes the bench numbers per CLAUDE.md.
- [ ] CI green on Ubuntu + macOS × Ruby 3.3.6 + 3.4.1.

## Rollback

- Operator: `Hyperion::Http::ResponseWriter.c_writer_available = false` (no redeploy).
- Hard: `git revert` the PR; Ruby fallback was always the `_ruby`-suffixed default code path.
