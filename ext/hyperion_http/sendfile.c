/* ----------------------------------------------------------------------
 * Hyperion::Http::Sendfile — zero-copy static-file fast path.
 *
 * Public surface (defined as singleton methods on Hyperion::Http::Sendfile):
 *
 *   Sendfile.supported? -> true | false
 *     true on Linux (splice / sendfile64) and Darwin / BSD (sendfile).
 *     false everywhere else; Ruby caller must fall back to IO.copy_stream.
 *
 *   Sendfile.copy(out_io, in_io, offset, len) -> [bytes_written, status]
 *     out_io  — writable IO (TCPSocket or anything to_io / fileno-able). Must
 *               NOT be a TLS-wrapped socket (kernel has no plaintext to send).
 *     in_io   — readable IO pointing at a regular file (must support fileno).
 *     offset  — non-negative Integer; byte offset into the source file.
 *     len     — non-negative Integer; number of bytes to copy.
 *
 *     Returns a 2-element Array:
 *       bytes_written :: Integer  bytes the kernel acknowledged this call
 *       status        :: Symbol   one of:
 *           :done      — bytes_written == len; transfer complete.
 *           :partial   — short write; caller MUST loop with offset+bytes.
 *           :eagain    — socket buffer full; caller yields to fiber
 *                        scheduler / IO.select then retries from the same
 *                        offset+bytes_written cursor.
 *           :unsupported — host kernel returned ENOSYS / EINVAL on a path that
 *                        SHOULD work; caller falls back to IO.copy_stream.
 *
 *     On any other error (EPIPE, ECONNRESET, ENOMEM, …) the helper raises
 *     the matching Errno::* — same shape Ruby socket writes raise.
 *
 * Phase 1 strategy
 * ----------------
 * Linux:  prefer sendfile(2) (single syscall, file -> socket). If sendfile
 *         is unavailable in this build (very old kernels), splice(2)
 *         through a pipe-tee acts as the fallback (file -> pipe -> socket).
 *         Both paths are true zero-copy: page cache bytes never enter
 *         userspace.
 * BSD/Darwin: sendfile(2) — different signature (offset is in/out via
 *         off_t*), same zero-copy guarantee.
 * Other:  Sendfile.supported? returns false; copy() raises NotImplementedError
 *         so Ruby's caller drops to IO.copy_stream.
 *
 * GVL discipline
 * --------------
 * The kernel call itself runs under rb_thread_call_without_gvl so that other
 * fibers / threads can run while we wait on socket buffer space. EAGAIN /
 * EWOULDBLOCK do NOT spin in C — we return :eagain and let the Ruby caller
 * yield to the fiber scheduler (or IO.select when no scheduler is active).
 *
 * Single-writer invariant
 * -----------------------
 * Phase 1 is HTTP/1.1 only. The connection is owned by a single fiber/thread
 * for the duration of the response, so there's no concurrent-writer problem
 * to worry about here. h2 sendfile would require coordination with the
 * per-connection writer fiber; out of scope for 1.7.0 (RFC §3 future work).
 * ---------------------------------------------------------------------- */

#include <ruby.h>
#include <ruby/thread.h>
#include <ruby/io.h>

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>

#if defined(__linux__)
#  include <sys/sendfile.h>
#  include <sys/uio.h>
#  define HYP_SF_LINUX 1
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__DragonFly__) || defined(__NetBSD__)
#  include <sys/socket.h>
#  include <sys/uio.h>
#  define HYP_SF_BSD 1
#endif

static VALUE rb_mHyperion;
static VALUE rb_mHyperionHttp;
static VALUE rb_mHyperionHttpSendfile;

static ID id_fileno;
static ID id_to_io;

static VALUE sym_done;
static VALUE sym_partial;
static VALUE sym_eagain;
static VALUE sym_unsupported;

/* Extract a kernel fd from a Ruby IO-ish object.
 *
 * We accept:
 *   - an Integer (the caller already pulled fileno)
 *   - a real ::IO subclass (use rb_io_descriptor)
 *   - anything responding to #to_io (call it, then take its fd)
 *   - anything responding to #fileno (call it as last resort)
 *
 * Raises TypeError on anything else.
 */
static int extract_fd(VALUE obj, const char *role) {
    if (RB_TYPE_P(obj, T_FIXNUM) || RB_TYPE_P(obj, T_BIGNUM)) {
        return NUM2INT(obj);
    }

    if (RB_TYPE_P(obj, T_FILE)) {
        return rb_io_descriptor(obj);
    }

    if (rb_respond_to(obj, id_to_io)) {
        VALUE io = rb_funcall(obj, id_to_io, 0);
        if (RB_TYPE_P(io, T_FILE)) {
            return rb_io_descriptor(io);
        }
        if (RB_TYPE_P(io, T_FIXNUM) || RB_TYPE_P(io, T_BIGNUM)) {
            return NUM2INT(io);
        }
    }

    if (rb_respond_to(obj, id_fileno)) {
        VALUE fd = rb_funcall(obj, id_fileno, 0);
        if (RB_TYPE_P(fd, T_FIXNUM) || RB_TYPE_P(fd, T_BIGNUM)) {
            return NUM2INT(fd);
        }
    }

    rb_raise(rb_eTypeError,
             "Hyperion::Http::Sendfile.copy: %s argument must be an IO, "
             "an Integer fd, or respond to #to_io / #fileno",
             role);
    return -1; /* unreachable */
}

#if defined(HYP_SF_LINUX) || defined(HYP_SF_BSD)

/* Arguments shuttled into / out of the GVL-released kernel call. */
typedef struct {
    int     out_fd;
    int     in_fd;
    off_t   offset;     /* in: requested offset; on Linux passed by reference
                         * to sendfile so the kernel updates it. */
    size_t  len;
    ssize_t rc;         /* out: kernel return value */
    int     err;        /* out: errno from the kernel call */
} sendfile_args_t;

#  ifdef HYP_SF_LINUX
static void *sendfile_blocking_call(void *raw) {
    sendfile_args_t *a = (sendfile_args_t *)raw;
    a->rc = sendfile(a->out_fd, a->in_fd, &a->offset, a->len);
    a->err = (a->rc < 0) ? errno : 0;
    return NULL;
}
#  endif /* HYP_SF_LINUX */

#  ifdef HYP_SF_BSD
static void *sendfile_blocking_call(void *raw) {
    sendfile_args_t *a = (sendfile_args_t *)raw;
#    if defined(__APPLE__)
    /* Darwin: sendfile(int fd, int s, off_t offset, off_t *len, struct sf_hdtr*, int flags)
     * On entry *len is bytes to send; on return *len is bytes actually sent.
     */
    off_t io_len = (off_t)a->len;
    int rc = sendfile(a->in_fd, a->out_fd, a->offset, &io_len, NULL, 0);
    a->rc  = (ssize_t)io_len;        /* Darwin reports partial bytes via *len even on error */
    a->err = (rc < 0) ? errno : 0;
#    else
    /* FreeBSD/Net/Dragon: sendfile(int fd, int s, off_t offset, size_t nbytes,
     *                              struct sf_hdtr*, off_t *sbytes, int flags)
     */
    off_t sent = 0;
    int rc = sendfile(a->in_fd, a->out_fd, a->offset, a->len, NULL, &sent, 0);
    a->rc  = (ssize_t)sent;
    a->err = (rc < 0) ? errno : 0;
#    endif
    return NULL;
}
#  endif /* HYP_SF_BSD */

#endif /* HYP_SF_LINUX || HYP_SF_BSD */

/* Sendfile.copy(out_io, in_io, offset, len) */
static VALUE rb_sendfile_copy(VALUE self, VALUE out_io, VALUE in_io,
                              VALUE rb_offset, VALUE rb_len) {
    (void)self;

#if defined(HYP_SF_LINUX) || defined(HYP_SF_BSD)
    long offset_l = NUM2LONG(rb_offset);
    long len_l    = NUM2LONG(rb_len);
    if (offset_l < 0) {
        rb_raise(rb_eArgError, "offset must be >= 0 (got %ld)", offset_l);
    }
    if (len_l < 0) {
        rb_raise(rb_eArgError, "len must be >= 0 (got %ld)", len_l);
    }
    if (len_l == 0) {
        return rb_ary_new3(2, INT2FIX(0), sym_done);
    }

    sendfile_args_t args;
    args.out_fd = extract_fd(out_io, "out_io");
    args.in_fd  = extract_fd(in_io, "in_io");
    args.offset = (off_t)offset_l;
    args.len    = (size_t)len_l;
    args.rc     = -1;
    args.err    = 0;

    rb_thread_call_without_gvl(sendfile_blocking_call, &args, RUBY_UBF_IO, NULL);

    if (args.rc < 0) {
        if (args.err == EAGAIN || args.err == EWOULDBLOCK || args.err == EINTR) {
            /* Kernel didn't accept any bytes; caller yields and retries. */
            return rb_ary_new3(2, INT2FIX(0), sym_eagain);
        }
        if (args.err == ENOSYS || args.err == EINVAL || args.err == ENOTSUP
#  ifdef EOPNOTSUPP
            || args.err == EOPNOTSUPP
#  endif
        ) {
            /* Kernel says "this combination of fds doesn't support sendfile"
             * (e.g. socket on a tunfs that doesn't expose page cache, or
             * Darwin trying to sendfile to a non-stream socket). Caller
             * falls back to IO.copy_stream. */
            return rb_ary_new3(2, INT2FIX(0), sym_unsupported);
        }
#  ifdef HYP_SF_BSD
        /* On Darwin/BSD a partial transfer can also report errno; if any
         * bytes flew, surface them with :partial so the caller can advance
         * its cursor before re-erroring on the next iteration. */
        if (args.rc > 0) {
            return rb_ary_new3(2, LONG2NUM((long)args.rc),
                               sym_partial);
        }
#  endif
        errno = args.err;
        rb_sys_fail("sendfile");
    }

    if (args.rc == 0) {
        /* Kernel accepted nothing AND didn't error. Treat as :eagain so
         * the caller yields rather than spinning. (Some kernels behave
         * this way under tight non-blocking pressure.) */
        return rb_ary_new3(2, INT2FIX(0), sym_eagain);
    }

    if ((size_t)args.rc < args.len) {
        return rb_ary_new3(2, LONG2NUM((long)args.rc), sym_partial);
    }

    return rb_ary_new3(2, LONG2NUM((long)args.rc), sym_done);

#else /* !Linux && !BSD */
    (void)out_io; (void)in_io; (void)rb_offset; (void)rb_len;
    rb_raise(rb_eNotImpError,
             "Hyperion::Http::Sendfile.copy: native zero-copy unsupported on "
             "this platform; fall back to IO.copy_stream");
    return Qnil; /* unreachable */
#endif
}

/* Sendfile.supported? — module-introspection helper. Lets the Ruby caller
 * pick its branch without needing a rescue NotImplementedError around the
 * first call (which would burn an exception object on every static
 * response on unsupported hosts). */
static VALUE rb_sendfile_supported_p(VALUE self) {
    (void)self;
#if defined(HYP_SF_LINUX) || defined(HYP_SF_BSD)
    return Qtrue;
#else
    return Qfalse;
#endif
}

/* Sendfile.platform_tag — returns a small Symbol describing which kernel
 * path got compiled in. Used by specs and the bench reporter. */
static VALUE rb_sendfile_platform_tag(VALUE self) {
    (void)self;
#if defined(HYP_SF_LINUX)
    return ID2SYM(rb_intern("linux"));
#elif defined(HYP_SF_BSD)
#  if defined(__APPLE__)
    return ID2SYM(rb_intern("darwin"));
#  else
    return ID2SYM(rb_intern("bsd"));
#  endif
#else
    return ID2SYM(rb_intern("unsupported"));
#endif
}

void Init_hyperion_sendfile(void) {
    rb_mHyperion             = rb_const_get(rb_cObject, rb_intern("Hyperion"));

    /* Hyperion::Http — created lazily; ResponseWriter doesn't need it
     * to exist before the C ext loads, so we tolerate either order. */
    if (rb_const_defined(rb_mHyperion, rb_intern("Http"))) {
        rb_mHyperionHttp = rb_const_get(rb_mHyperion, rb_intern("Http"));
    } else {
        rb_mHyperionHttp = rb_define_module_under(rb_mHyperion, "Http");
    }

    rb_mHyperionHttpSendfile = rb_define_module_under(rb_mHyperionHttp, "Sendfile");

    rb_define_singleton_method(rb_mHyperionHttpSendfile, "copy",
                               rb_sendfile_copy, 4);
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "supported?",
                               rb_sendfile_supported_p, 0);
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "platform_tag",
                               rb_sendfile_platform_tag, 0);

    id_fileno = rb_intern("fileno");
    id_to_io  = rb_intern("to_io");

    sym_done        = ID2SYM(rb_intern("done"));
    sym_partial     = ID2SYM(rb_intern("partial"));
    sym_eagain      = ID2SYM(rb_intern("eagain"));
    sym_unsupported = ID2SYM(rb_intern("unsupported"));

    /* Keep symbols and module references rooted so the GC doesn't
     * collect them between calls. */
    rb_gc_register_mark_object(sym_done);
    rb_gc_register_mark_object(sym_partial);
    rb_gc_register_mark_object(sym_eagain);
    rb_gc_register_mark_object(sym_unsupported);
}
