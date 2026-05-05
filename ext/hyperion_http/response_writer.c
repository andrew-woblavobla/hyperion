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
    id_fileno = rb_intern("fileno");

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

    /* WOULDBLOCK sentinel: Ruby caller checks for this value and falls
     * back to io.write when the kernel send buffer is full (EAGAIN). */
    rb_define_const(rb_mResponseWriter, "WOULDBLOCK",
                    INT2NUM(HYP_C_WRITE_WOULDBLOCK));
}
