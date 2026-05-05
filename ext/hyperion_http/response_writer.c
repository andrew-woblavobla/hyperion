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
static ID id_keys_resp;

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

/* Reason phrase lookup — mirrors Hyperion::ResponseWriter::REASONS in
 * lib/hyperion/response_writer.rb and the k_status_lines table in
 * parser.c (the three must stay in sync). Returns a literal C string
 * for common statuses; "Unknown" as the catch-all (matching the Ruby
 * REASONS.fetch fallback). Called once per c_write_buffered call to
 * build the rb_reason VALUE passed to hyperion_build_response_head. */
static const char *hyp_status_reason(int status) {
    switch (status) {
        case 200: return "OK";
        case 201: return "Created";
        case 204: return "No Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 304: return "Not Modified";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 413: return "Payload Too Large";
        case 414: return "URI Too Long";
        case 422: return "Unprocessable Entity";
        case 429: return "Too Many Requests";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        default:  return "Unknown";
    }
}

/* Validate a single header value: no CR/LF allowed (header injection
 * defense — matches response_writer.rb's `raise ArgumentError` guard
 * for CRLF_HEADER_VALUE). Declared static inline: small body, called
 * per-header, compiler can inline at each call site. */
static inline void hyp_check_header_value(VALUE value) {
    Check_Type(value, T_STRING);
    const char *p = RSTRING_PTR(value);
    long n = RSTRING_LEN(value);
    for (long i = 0; i < n; i++) {
        if (p[i] == '\r' || p[i] == '\n') {
            rb_raise(rb_eArgError,
                     "header value contains CR/LF (response-splitting guard)");
        }
    }
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

    /* 1. Resolve fd from the Ruby IO object. rb_funcall can GC; do it
     *    before we hold any raw C pointers into Ruby objects. */
    int fd = NUM2INT(rb_funcall(io, id_fileno, 0));

    /* 2. Body type check and byte-size sum.
     *    RARRAY_AREF is safe while rb_body is live on the C stack. */
    Check_Type(rb_body, T_ARRAY);
    long body_size = 0;
    long body_len  = RARRAY_LEN(rb_body);
    for (long i = 0; i < body_len; i++) {
        VALUE chunk = RARRAY_AREF(rb_body, i);
        Check_Type(chunk, T_STRING);
        body_size += RSTRING_LEN(chunk);
    }

    /* 3. Header CR/LF validation. rb_hash_foreach would be slightly
     *    faster but rb_funcall(keys) + iteration is cleaner given that
     *    the hot path (n_headers ≤ 6) makes the difference negligible.
     *    We iterate the keys Array returned by Hash#keys so we get both
     *    key and value without a second lookup per pair. */
    if (TYPE(rb_headers) == T_HASH) {
        VALUE keys = rb_funcall(rb_headers, id_keys_resp, 0);
        long klen  = RARRAY_LEN(keys);
        for (long i = 0; i < klen; i++) {
            VALUE k = RARRAY_AREF(keys, i);
            VALUE v = rb_hash_aref(rb_headers, k);
            hyp_check_header_value(v);
        }
    }

    /* 4. Build the response head.
     *    hyperion_build_response_head lives in parser.c and is exported
     *    via response_writer.h. It requires a non-empty reason string —
     *    an empty "" passes Check_Type but prints "HTTP/1.1 200 \r\n"
     *    (blank reason) on the snprintf fallback path. We supply the
     *    canonical reason from hyp_status_reason() so the pre-baked
     *    status-line table in parser.c produces a single memcpy hit. */
    int status = NUM2INT(rb_status);
    VALUE rb_reason = rb_str_new_cstr(hyp_status_reason(status));
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

    /* Touch coalesced after the syscall so the optimizer can't reap it
     * before sendmsg/writev finishes scanning its iov_base pointer.
     * Project-standard GC-safety idiom (matches other ext files). */
    if (!NIL_P(coalesced)) (void)RSTRING_PTR(coalesced);

    if (n == HYP_C_WRITE_WOULDBLOCK) return INT2NUM(HYP_C_WRITE_WOULDBLOCK);
    return SSIZET2NUM(n);
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
    id_keys_resp = rb_intern("keys");

    rb_define_singleton_method(rb_mResponseWriter, "available?",
                               c_response_writer_available_p, 0);
    rb_define_singleton_method(rb_mResponseWriter, "c_write_buffered",
                               c_write_buffered, 6);

    /* WOULDBLOCK sentinel: Ruby caller checks for this value and falls
     * back to io.write when the kernel send buffer is full (EAGAIN). */
    rb_define_const(rb_mResponseWriter, "WOULDBLOCK",
                    INT2NUM(HYP_C_WRITE_WOULDBLOCK));
}
