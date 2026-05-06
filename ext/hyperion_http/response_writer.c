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
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <dlfcn.h>

#include "response_writer.h"

/* macOS lacks MSG_NOSIGNAL; fall back to 0 (no flag). Safe in a Ruby
 * process: MRI installs a custom SIGPIPE handler that converts the
 * signal into a soft event and the next IO call returns EPIPE — the
 * process is not killed. Our C sendmsg/writev calls run under the
 * GVL, so the same handler intercepts SIGPIPE for them. */
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static VALUE rb_mHyperion;
static VALUE rb_mHttp;
static VALUE rb_mResponseWriter;

/* IDs cached at init time — avoids rb_intern on the hot path. */
static ID id_fileno;
static ID id_each;
static ID id_hyp_flush; /* :__hyperion_flush__ chunked-drain sentinel */

/* Plan #2 seam: function-pointer for hyperion_io_uring's send-SQE
 * submission. Resolved lazily on the first call to c_write_buffered_via_ring
 * via dlsym(RTLD_DEFAULT, ...). NULL when the io_uring crate isn't loaded
 * yet — the via-ring path short-circuits to direct write in that case.
 *
 * Order-of-loading note: Init_hyperion_response_writer runs when
 * hyperion_http.bundle is required (early boot, before io_uring.rb loads
 * the io_uring cdylib). Doing the dlsym here would always return NULL.
 * Instead we re-try on the first call so the symbol is found AFTER
 * lib/hyperion/io_uring.rb has called Fiddle.dlopen on the cdylib. */
static int (*hyp_submit_send_fn)(void *, int, const void *, unsigned int) = NULL;

/* Pre-baked frozen Ruby Strings for the 23 common reason phrases.
 * Built once at init; looked up by status code in c_write_buffered.
 * Eliminates the per-request rb_str_new_cstr allocation that would
 * otherwise fire on every response. Statuses outside the table fall
 * back to a per-call rb_str_new_cstr("Unknown"). */
#define HYP_REASON_TABLE_SIZE 23
static int   k_reason_statuses[HYP_REASON_TABLE_SIZE] = {
    200, 201, 204, 301, 302, 304, 400, 401, 403, 404, 405, 408,
    409, 410, 413, 414, 422, 429, 500, 501, 502, 503, 504
};
static VALUE k_reason_strings[HYP_REASON_TABLE_SIZE];
static VALUE k_reason_unknown;

static VALUE c_response_writer_available_p(VALUE self) {
    (void)self;
    return Qtrue;
}

/* Sentinel returned to Ruby on EAGAIN — the dispatcher sees this and
 * falls back to io.write (which yields under Async / blocks under
 * threadpool correctly). We don't reimplement scheduler-aware parking
 * in C. */
#define HYP_C_WRITE_WOULDBLOCK -2

/* Maximum iov entries we build on the stack: 1 (head) + up to
 * HYP_C_IOV_MAX-1 body chunks. Cap at 8 so a pathological 100-element
 * Array body coalesces into one buffer rather than blowing the stack.
 * Normal Rack apps emit Array[1] bodies; Array[2..7] is the uncommon
 * multi-part case; Array[8+] coalesces. */
#define HYP_C_IOV_MAX 8

/* Look up the cached reason String for `status`. Returns a frozen
 * Ruby String for the 23 common statuses (zero allocation), or
 * k_reason_unknown ("Unknown") for anything else. */
static inline VALUE hyp_lookup_reason(int status) {
    for (int i = 0; i < HYP_REASON_TABLE_SIZE; i++) {
        if (k_reason_statuses[i] == status) return k_reason_strings[i];
    }
    return k_reason_unknown;
}

/* Issue one sendmsg/writev with `iov_count` iovecs. Returns total
 * bytes written, HYP_C_WRITE_WOULDBLOCK on EAGAIN/EWOULDBLOCK, or
 * raises on hard errors. Handles short writes (rare on a non-blocking
 * socket with room in the kernel send buffer) by advancing the iov
 * and looping. EINTR retried up to 3 times. */
static ssize_t hyp_writev_all(int fd, struct iovec *iov, int iov_count) {
    ssize_t total = 0;
    int retries = 0;

    for (;;) {
#ifdef HAVE_SENDMSG
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov    = iov;
        msg.msg_iovlen = (int)iov_count;
        ssize_t n = sendmsg(fd, &msg, MSG_NOSIGNAL);
#else
        ssize_t n = writev(fd, iov, iov_count);
#endif
        if (n >= 0) {
            total += n;
            /* Compute remaining bytes across all iov slots. */
            ssize_t remaining = 0;
            for (int i = 0; i < iov_count; i++)
                remaining += (ssize_t)iov[i].iov_len;
            if (n == remaining) return total;

            /* Short write — advance iov past the bytes already sent. */
            ssize_t skipped = 0;
            int i = 0;
            while (i < iov_count &&
                   skipped + (ssize_t)iov[i].iov_len <= n) {
                skipped += (ssize_t)iov[i].iov_len;
                i++;
            }
            if (i < iov_count) {
                iov[i].iov_base =
                    (char *)iov[i].iov_base + (n - skipped);
                iov[i].iov_len -= (size_t)(n - skipped);
            }
            iov       += i;
            iov_count -= i;
            continue;
        }

        if (errno == EINTR) {
            if (++retries > 3)
                rb_sys_fail("sendmsg/writev: EINTR retries exhausted");
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
 * Writes a complete HTTP/1.1 response (head + body) to the kernel fd
 * underlying `io` in a single sendmsg/writev call. Validates header
 * values for CR/LF injection and body chunks for type safety before
 * issuing the syscall.
 *
 * Returns total bytes written on success.
 * Returns HYP_C_WRITE_WOULDBLOCK (-2) on EAGAIN — caller falls back
 * to io.write (which parks the fiber / blocks the thread correctly).
 * Raises rb_eArgError on CR/LF in header values.
 * Raises rb_eTypeError on non-String body chunks.
 * Raises SystemCallError on hard write failures. */
static VALUE c_write_buffered(VALUE self, VALUE io, VALUE rb_status,
                              VALUE rb_headers, VALUE rb_body,
                              VALUE rb_keep_alive, VALUE rb_date) {
    (void)self;

    /* 1. Type checks up front — fail fast on bad shapes before any
     *    syscall. Header CR/LF validation and value coercion happen
     *    inside cbuild_response_head (build_head_each), so we don't
     *    duplicate them here. */
    Check_Type(rb_headers, T_HASH);
    Check_Type(rb_body, T_ARRAY);

    /* 2. Resolve fd from the Ruby IO object. rb_funcall can GC; do it
     *    before we take any raw C pointers into Ruby objects. */
    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));

    /* 3. Body type check and byte-size sum.
     *    RARRAY_AREF is safe while rb_body is live on the C stack. */
    long body_size = 0;
    long body_len  = RARRAY_LEN(rb_body);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        Check_Type(chunk, T_STRING);
        body_size += RSTRING_LEN(chunk);
    }

    /* 4. Build the response head.
     *    hyperion_build_response_head lives in parser.c and is exported
     *    via response_writer.h. The reason String comes from a pre-baked
     *    frozen-String table — zero allocation for the 23 common statuses;
     *    only unknown statuses fall back to k_reason_unknown.
     *    cbuild_response_head's build_head_each performs the CR/LF guard
     *    and rb_obj_as_string coercion on header values, matching the
     *    Ruby fallback's semantics exactly. */
    int status = NUM2INT(rb_status);
    VALUE rb_reason = hyp_lookup_reason(status);
    VALUE head = hyperion_build_response_head(
        rb_status, rb_reason, rb_headers,
        LL2NUM(body_size), rb_keep_alive, rb_date
    );

    /* 5. Assemble iovec: slot 0 = response head; slots 1..N = body chunks
     *    (capped at HYP_C_IOV_MAX-1). Bodies longer than HYP_C_IOV_MAX-1
     *    chunks are coalesced into a single buffer allocated here. */
    struct iovec iov[HYP_C_IOV_MAX];
    iov[0].iov_base = RSTRING_PTR(head);
    iov[0].iov_len  = (size_t)RSTRING_LEN(head);
    int iov_count = 1;

    /* Hold a reference so GC can't reap the coalesced buffer before
     * the syscall completes. Qnil means "not used". */
    VALUE coalesced = Qnil;

    if (body_len <= (long)(HYP_C_IOV_MAX - 1)) {
        /* Fast path: each chunk gets its own iov slot. The Array `rb_body`
         * is a GC root that pins all its elements for our call duration. */
        for (long i = 0; i < body_len; i++) {
            VALUE chunk = RARRAY_AREF(rb_body, i);
            iov[iov_count].iov_base = RSTRING_PTR(chunk);
            iov[iov_count].iov_len  = (size_t)RSTRING_LEN(chunk);
            iov_count++;
        }
    } else {
        /* Slow path: coalesce into one buffer to keep iov_count bounded.
         * This branch fires only for Array bodies with >= 8 chunks — rare
         * in practice. We accept the one-time allocation. */
        coalesced = rb_str_buf_new(body_size);
        for (long i = 0; i < body_len; i++)
            rb_str_buf_append(coalesced, RARRAY_AREF(rb_body, i));
        iov[1].iov_base = RSTRING_PTR(coalesced);
        iov[1].iov_len  = (size_t)RSTRING_LEN(coalesced);
        iov_count = 2;
    }

    ssize_t n = hyp_writev_all(fd, iov, iov_count);

    /* GC-safety: keep `head` and `coalesced` (when used) alive across
     * the syscall. -O2 can elide local Ruby Strings whose only use is
     * the RSTRING_PTR at iov assembly; MRI's conservative GC stack
     * scan would then miss them. RB_GC_GUARD is the project-standard
     * idiom (parser.c uses it 9 times for the same pattern). */
    RB_GC_GUARD(head);
    RB_GC_GUARD(coalesced);

    if (n == HYP_C_WRITE_WOULDBLOCK) return INT2NUM(HYP_C_WRITE_WOULDBLOCK);
    return SSIZET2NUM(n);
}

/* -----------------------------------------------------------------------
 * c_write_chunked — chunked Transfer-Encoding response writer
 * ----------------------------------------------------------------------- */

/* Per-call chunked state passed through rb_block_call. */
struct hyp_chunked_state {
    int fd;
    unsigned char buf[4096];     /* coalesce buffer; 4 KiB matches
                                  * ResponseWriter::COALESCE_FLUSH_BYTES
                                  * (response_writer.rb:19). */
    size_t buf_used;
    size_t bytes_written;
};

static const char HYP_HEX[16] = {
    '0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'
};

/* Format `n` as lowercase hex (no 0x prefix). Returns bytes written.
 * Handwritten so we don't pay snprintf cost per chunk; mirrors the
 * u64_to_dec helper in c_access_line.c. */
static size_t hyp_u64_to_hex(unsigned char *dst, uint64_t n) {
    if (n == 0) { dst[0] = '0'; return 1; }
    unsigned char tmp[16];
    int i = 0;
    while (n > 0) { tmp[i++] = (unsigned char)HYP_HEX[n & 0xf]; n >>= 4; }
    for (int j = 0; j < i; j++) dst[j] = tmp[i - 1 - j];
    return (size_t)i;
}

/* Drain the coalesce buffer to the wire as a single syscall.
 * Updates bytes_written and resets buf_used. Raises Errno::EAGAIN on
 * mid-body backpressure: once any chunked bytes are on the wire, a
 * partial flush would corrupt the chunked encoding for the peer
 * (the next coalesce-and-drain would inject framing in the wrong
 * place). The dispatcher (Task 6) catches the exception and tears
 * the connection down — this matches "WOULDBLOCK is degenerate
 * mid-body" from the spec. The pre-body WOULDBLOCK case is handled
 * separately by the head-emit path in c_write_chunked. */
static void hyp_chunked_drain(struct hyp_chunked_state *st) {
    if (st->buf_used == 0) return;
    struct iovec iov[1];
    iov[0].iov_base = st->buf;
    iov[0].iov_len  = st->buf_used;
    ssize_t n = hyp_writev_all(st->fd, iov, 1);
    if (n == HYP_C_WRITE_WOULDBLOCK) {
        errno = EAGAIN;
        rb_sys_fail("chunked-encoding mid-body backpressure (WOULDBLOCK)");
    }
    st->bytes_written += st->buf_used;
    st->buf_used = 0;
}

/* Append `framed_len` bytes to the coalesce buffer. If they overflow
 * the buffer, drain first; if the bytes themselves exceed 4 KiB,
 * drain and write directly bypassing the coalesce. Mid-body
 * WOULDBLOCK propagates as Errno::EAGAIN via hyp_chunked_drain
 * and rb_sys_fail (see hyp_chunked_drain comment). */
static void hyp_chunked_append(struct hyp_chunked_state *st,
                               const unsigned char *framed,
                               size_t framed_len) {
    if (framed_len >= sizeof(st->buf)) {
        /* Big frame: drain anything we've buffered so order is preserved,
         * then write the framed bytes directly with one syscall. */
        hyp_chunked_drain(st);
        struct iovec iov[1] = {{ (void *)framed, framed_len }};
        ssize_t n = hyp_writev_all(st->fd, iov, 1);
        if (n == HYP_C_WRITE_WOULDBLOCK) {
            errno = EAGAIN;
            rb_sys_fail("chunked-encoding mid-body backpressure (WOULDBLOCK)");
        }
        st->bytes_written += framed_len;
        return;
    }
    if (st->buf_used + framed_len > sizeof(st->buf)) hyp_chunked_drain(st);
    memcpy(st->buf + st->buf_used, framed, framed_len);
    st->buf_used += framed_len;
}

/* rb_block_call callback invoked once per `body.each` yield. */
static VALUE hyp_chunked_callback(RB_BLOCK_CALL_FUNC_ARGLIST(yielded, callback_arg)) {
    struct hyp_chunked_state *st = (struct hyp_chunked_state *)callback_arg;
    VALUE chunk = yielded;
    if (NIL_P(chunk)) return Qnil;

    /* Flush sentinel: literal symbol :__hyperion_flush__ from
     * response_writer.rb (used by SSE servers to push events past the
     * coalescing latency). id_hyp_flush cached at init. */
    if (SYMBOL_P(chunk) && rb_sym2id(chunk) == id_hyp_flush) {
        hyp_chunked_drain(st);
        return Qnil;
    }

    Check_Type(chunk, T_STRING);
    size_t payload_len = (size_t)RSTRING_LEN(chunk);
    if (payload_len == 0) return Qnil;

    /* Frame: <hex-size>\r\n<payload>\r\n. We allocate the framed
     * bytes on the C stack for small chunks. For large chunks the
     * framing wrapping bytes are stack-built; the payload itself
     * lives in the Ruby String and we writev with three iovs. */
    if (payload_len < (sizeof(st->buf) - 32)) {
        /* Stack-frame the chunk so it lands in the coalesce buffer
         * (or drains directly via hyp_chunked_append if oversized). */
        unsigned char framed[4096 + 32];
        size_t hex_n = hyp_u64_to_hex(framed, (uint64_t)payload_len);
        framed[hex_n++] = '\r'; framed[hex_n++] = '\n';
        memcpy(framed + hex_n, RSTRING_PTR(chunk), payload_len);
        hex_n += payload_len;
        framed[hex_n++] = '\r'; framed[hex_n++] = '\n';
        hyp_chunked_append(st, framed, hex_n);
    } else {
        /* Large chunk: drain coalesce, write the size-line + payload +
         * CRLF in one writev (3 iovs). */
        hyp_chunked_drain(st);
        unsigned char hex_buf[18];
        size_t hex_n = hyp_u64_to_hex(hex_buf, (uint64_t)payload_len);
        hex_buf[hex_n++] = '\r'; hex_buf[hex_n++] = '\n';
        unsigned char crlf[2] = { '\r', '\n' };
        struct iovec iov[3];
        iov[0].iov_base = hex_buf;
        iov[0].iov_len  = hex_n;
        iov[1].iov_base = (void *)RSTRING_PTR(chunk);
        iov[1].iov_len  = payload_len;
        iov[2].iov_base = crlf;
        iov[2].iov_len  = 2;
        ssize_t n = hyp_writev_all(st->fd, iov, 3);
        if (n == HYP_C_WRITE_WOULDBLOCK) {
            errno = EAGAIN;
            rb_sys_fail("chunked-encoding mid-body backpressure (WOULDBLOCK)");
        }
        st->bytes_written += hex_n + payload_len + 2;
        RB_GC_GUARD(chunk);
    }
    return Qnil;
}

/* Hyperion::Http::ResponseWriter.c_write_chunked(io, status, headers,
 *                                                 body, keep_alive,
 *                                                 date_str) -> Integer */
static VALUE c_write_chunked(VALUE self, VALUE io, VALUE rb_status,
                             VALUE rb_headers, VALUE rb_body,
                             VALUE rb_keep_alive, VALUE rb_date) {
    (void)self;
    Check_Type(rb_headers, T_HASH);

    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));
    int status = NUM2INT(rb_status);
    VALUE rb_reason = hyp_lookup_reason(status);

    /* Build chunked head: emits transfer-encoding: chunked instead of
     * content-length; drops caller-supplied content-length and TE. */
    VALUE head = hyperion_build_response_head_chunked(
        rb_status, rb_reason, rb_headers, rb_keep_alive, rb_date
    );

    struct hyp_chunked_state st;
    memset(&st, 0, sizeof(st));
    st.fd = fd;

    /* Emit the head as a single syscall. */
    struct iovec head_iov[1];
    head_iov[0].iov_base = (void *)RSTRING_PTR(head);
    head_iov[0].iov_len  = (size_t)RSTRING_LEN(head);
    ssize_t n = hyp_writev_all(fd, head_iov, 1);
    if (n == HYP_C_WRITE_WOULDBLOCK) {
        RB_GC_GUARD(head);
        return INT2NUM(HYP_C_WRITE_WOULDBLOCK);
    }
    st.bytes_written += (size_t)RSTRING_LEN(head);

    /* Iterate body via rb_block_call. Ruby exceptions propagate
     * (the dispatcher's Connection#serve rescue handles teardown).
     * id_each cached at init. */
    rb_block_call(rb_body, id_each, 0, NULL,
                  hyp_chunked_callback, (VALUE)&st);

    /* Drain coalesce + emit terminator atomically when possible:
     * coalesce buffer has room → memcpy the terminator and drain
     * (single syscall ends the response). Otherwise drain first
     * then write the terminator separately. */
    static const unsigned char term[] = { '0','\r','\n','\r','\n' };
    if (st.buf_used + sizeof(term) <= sizeof(st.buf)) {
        memcpy(st.buf + st.buf_used, term, sizeof(term));
        st.buf_used += sizeof(term);
        hyp_chunked_drain(&st);
    } else {
        hyp_chunked_drain(&st);
        struct iovec t_iov[1] = {{ (void *)term, sizeof(term) }};
        ssize_t tn = hyp_writev_all(fd, t_iov, 1);
        if (tn >= 0) st.bytes_written += sizeof(term);
    }

    RB_GC_GUARD(head);
    return SIZET2NUM(st.bytes_written);
}

/* Hyperion::Http::ResponseWriter.c_write_buffered_via_ring(io, status,
 *                                                           headers, body,
 *                                                           keep_alive,
 *                                                           date_str,
 *                                                           ring_ptr)
 *                                                          -> Integer
 *
 * Plan #2 — io_uring-owned variant of c_write_buffered. Submits a send
 * SQE via the Rust hyperion_io_uring crate instead of issuing write/writev
 * directly.  `ring_ptr` is the HotpathRing raw pointer cast to an Integer
 * by the Ruby caller (Connection layer).
 *
 * Falls back to direct write (c_write_buffered) when the io_uring crate
 * isn't loaded (hyp_submit_send_fn == NULL after lazy-resolve attempt).
 *
 * iov lifetime caveat: the kernel reads iov data AFTER submit_send returns.
 * The iov array is allocated via xmalloc and intentionally NOT freed here —
 * the Ruby head + body Strings stay alive via GC roots; the iov array itself
 * leaks one entry per response under sustained load.
 *
 * TODO(plan #2 task 2.5): replace xmalloc-leak with a per-conn iov arena
 * that frees on send-CQE completion. Current behavior leaks one iov array
 * per response under sustained load. */
static VALUE c_write_buffered_via_ring(VALUE self, VALUE io, VALUE rb_status,
                                        VALUE rb_headers, VALUE rb_body,
                                        VALUE rb_keep_alive, VALUE rb_date,
                                        VALUE rb_ring_ptr) {
    /* Lazy-resolve the io_uring submit_send symbol on first call. After the
     * first successful resolve, hyp_submit_send_fn is non-NULL and this
     * branch is skipped on every subsequent call (~50 ns dlsym cost paid
     * once per process, not per request). */
    if (!hyp_submit_send_fn) {
        hyp_submit_send_fn =
            (int (*)(void *, int, const void *, unsigned int))
            dlsym(RTLD_DEFAULT, "hyperion_io_uring_hotpath_submit_send");
    }
    if (!hyp_submit_send_fn) {
        /* io_uring crate not loaded — fall back to direct write path. */
        return c_write_buffered(self, io, rb_status, rb_headers, rb_body,
                                rb_keep_alive, rb_date);
    }

    /* Resolve fd before taking raw C pointers into Ruby objects (rb_funcall
     * may GC). */
    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));

    Check_Type(rb_headers, T_HASH);
    Check_Type(rb_body, T_ARRAY);

    /* Sum body bytes and type-check chunks. */
    long body_size = 0;
    long body_len  = RARRAY_LEN(rb_body);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        Check_Type(chunk, T_STRING);
        body_size += RSTRING_LEN(chunk);
    }

    int status = NUM2INT(rb_status);
    VALUE rb_reason = hyp_lookup_reason(status);
    VALUE head = hyperion_build_response_head(
        rb_status, rb_reason, rb_headers,
        LL2NUM(body_size), rb_keep_alive, rb_date
    );

    /* Allocate iov array via xmalloc (Ruby-tracked). The kernel reads from
     * the iov pointers AFTER submit_send returns; the iovs + their backing
     * memory (RSTRING_PTR into Ruby Strings) MUST stay alive until the send
     * CQE is processed by the accept fiber.
     *
     * TODO(plan #2 task 2.5): replace xmalloc-leak with a per-conn iov arena
     * that frees on send-CQE completion. Current behavior leaks one iov array
     * per response under sustained load. */
    long total_iov = 1 + body_len;
    struct iovec *iov = ALLOC_N(struct iovec, total_iov);
    iov[0].iov_base = RSTRING_PTR(head);
    iov[0].iov_len  = (size_t)RSTRING_LEN(head);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        iov[i + 1].iov_base = RSTRING_PTR(chunk);
        iov[i + 1].iov_len  = (size_t)RSTRING_LEN(chunk);
    }

    void *ring_ptr = (void *)NUM2SIZET(rb_ring_ptr);
    int rc = hyp_submit_send_fn(ring_ptr, fd, iov, (unsigned int)total_iov);
    if (rc < 0) {
        xfree(iov);
        rb_sys_fail("hotpath submit_send");
    }

    /* Keep head alive across the submit_send call so the GC does not reap
     * the Ruby String whose RSTRING_PTR is in iov[0]. rb_body (the Array)
     * is a GC root that pins all body chunks for us. */
    RB_GC_GUARD(head);

    /* Return bytes-to-be-written (speculative; the actual byte count is
     * confirmed by the send CQE in the accept fiber — Task 2.5 wires
     * CQE feedback for metrics reconciliation). */
    return SIZET2NUM((size_t)RSTRING_LEN(head) + (size_t)body_size);
}

void Init_hyperion_response_writer(void) {
    rb_mHyperion = rb_const_get(rb_cObject, rb_intern("Hyperion"));
    /* Hyperion::Http may already exist (created by Init_hyperion_sendfile
     * earlier in Init_hyperion_http) or may not (init-order changes,
     * or a Ruby file opened the module first). Use the same guard
     * pattern as sendfile.c / page_cache.c so we never raise a
     * TypeError if a future caller defines Http as a class. */
    if (rb_const_defined(rb_mHyperion, rb_intern("Http"))) {
        rb_mHttp = rb_const_get(rb_mHyperion, rb_intern("Http"));
    } else {
        rb_mHttp = rb_define_module_under(rb_mHyperion, "Http");
    }
    rb_mResponseWriter = rb_define_module_under(rb_mHttp, "ResponseWriter");

    /* Cache rb_intern lookups at init time — never on the hot path. */
    id_fileno    = rb_intern("fileno");
    id_each      = rb_intern("each");
    id_hyp_flush = rb_intern("__hyperion_flush__");

    /* Pre-bake the 23 common reason phrases as frozen, never-GC'd Ruby
     * Strings so c_write_buffered can hand them to cbuild_response_head
     * without an allocation. rb_global_variable pins them as GC roots. */
    static const char *k_reason_phrases[HYP_REASON_TABLE_SIZE] = {
        "OK", "Created", "No Content", "Moved Permanently", "Found",
        "Not Modified", "Bad Request", "Unauthorized", "Forbidden",
        "Not Found", "Method Not Allowed", "Request Timeout", "Conflict",
        "Gone", "Payload Too Large", "URI Too Long", "Unprocessable Entity",
        "Too Many Requests", "Internal Server Error", "Not Implemented",
        "Bad Gateway", "Service Unavailable", "Gateway Timeout"
    };
    for (int i = 0; i < HYP_REASON_TABLE_SIZE; i++) {
        k_reason_strings[i] = rb_obj_freeze(rb_str_new_cstr(k_reason_phrases[i]));
        rb_global_variable(&k_reason_strings[i]);
    }
    k_reason_unknown = rb_obj_freeze(rb_str_new_cstr("Unknown"));
    rb_global_variable(&k_reason_unknown);

    rb_define_singleton_method(rb_mResponseWriter, "available?",
                               c_response_writer_available_p, 0);
    rb_define_singleton_method(rb_mResponseWriter, "c_write_buffered",
                               c_write_buffered, 6);
    rb_define_singleton_method(rb_mResponseWriter, "c_write_chunked",
                               c_write_chunked, 6);
    /* Plan #2 seam: io_uring send-SQE submission variant (7 args: the 6
     * from c_write_buffered plus ring_ptr). Falls back to c_write_buffered
     * when the io_uring crate is not loaded. */
    rb_define_singleton_method(rb_mResponseWriter, "c_write_buffered_via_ring",
                               c_write_buffered_via_ring, 7);

    /* WOULDBLOCK sentinel: Ruby caller checks for this value and falls
     * back to io.write when the kernel send buffer is full (EAGAIN). */
    rb_define_const(rb_mResponseWriter, "WOULDBLOCK",
                    INT2NUM(HYP_C_WRITE_WOULDBLOCK));
}
