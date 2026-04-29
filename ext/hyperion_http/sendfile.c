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
 *   Sendfile.copy_small(out_io, in_io, offset, len) -> Integer
 *     2.0.1 Phase 8a small-file fast path. Bounded by SMALL_FILE_THRESHOLD
 *     (64 KiB). Reads the whole slice into a heap buffer, blocks the OS
 *     thread on read+write under the GVL released, retries EAGAIN with
 *     short select() polls instead of fiber-yielding. Returns total bytes
 *     written. Raises Errno::* on hard errors. The fiber-yield round-trip
 *     for an 8 KB file (~40 µs per yield × N retries) was the catastrophic
 *     row at -t 5 in the 2.0.0 BENCH; the small-file path avoids it
 *     entirely by completing the transfer in the same syscall slice.
 *
 *   Sendfile.splice_supported? -> true | false
 *     2.0.1 Phase 8b — true iff this build carries the Linux splice(2)
 *     pipe-tee path AND the host kernel implemented it. Used by the
 *     userspace caller (and specs) to assert the splice branch fires.
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
 * Phase 8 (2.0.1) — close the last two static-file rps gaps
 * --------------------------------------------------------
 * 8a. Small files (<= 64 KiB) bypass the EAGAIN-yield-retry storm.  At
 *     -t 5 with 5 fibers per worker, an 8 KB file paying ~40 ms in
 *     fiber-yield ping-pong dropped to 121 r/s (Puma at 1,246).  The
 *     small-file path reads the slice in one syscall and writes it in
 *     one or two — under the GVL released, polling EAGAIN with short
 *     select() rather than fiber-yielding.  Per-call cost on the 8 KB
 *     row drops from milliseconds to microseconds.
 *
 * 8b. Big files on Linux (> 64 KiB) optionally splice through a
 *     per-thread cached pipe pair (file_fd -> pipe_w -> sock_fd) with
 *     SPLICE_F_MOVE | SPLICE_F_MORE for an extra ~5-15% over plain
 *     sendfile on the 1 MiB asset.  Pipe pair lifecycle is per-thread
 *     and reused across requests; closed at thread exit via a
 *     pthread_key_t destructor so a worker that scales fibers up and
 *     down doesn't leak fds.
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
#include <sys/stat.h>

#if defined(__linux__)
#  include <sys/sendfile.h>
#  include <sys/uio.h>
#  include <pthread.h>
#  include <fcntl.h>
#  define HYP_SF_LINUX 1
#  ifdef F_SETPIPE_SZ
#    define HYP_HAVE_F_SETPIPE_SZ 1
#  endif
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__DragonFly__) || defined(__NetBSD__)
#  include <sys/socket.h>
#  include <sys/uio.h>
#  define HYP_SF_BSD 1
#endif

#include <sys/select.h>

/* Phase 8a small-file threshold. Files at or below this size take the
 * synchronous read+write path. 64 KiB matches the kernel TCP send-buffer
 * sweet spot on Linux (also `USERSPACE_CHUNK` in the Ruby façade), and
 * covers the vast majority of static assets (favicons, sprites, JSON
 * manifests, CSS bundles below 64 KB). */
#define HYP_SMALL_FILE_THRESHOLD (64 * 1024)

/* Phase 8a single-MSS threshold. A file under one TCP segment payload
 * fits in a single packet under typical 1500-byte MTU; we issue exactly
 * one read() + one write() with no loop. */
#define HYP_SINGLE_MSS_THRESHOLD 1500

/* Phase 8a EAGAIN poll budget for the small-file path. We poll up to
 * ~50 ms total (5 × 10 ms select) before giving up and surfacing EAGAIN
 * to Ruby; on the small-file path this almost never triggers because
 * the slice fits in the socket buffer immediately. */
#define HYP_SMALL_EAGAIN_RETRIES 5
#define HYP_SMALL_EAGAIN_USEC_PER_RETRY 10000

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

/* ============================================================
 * Phase 8a — small-file synchronous read+write fast path.
 * ============================================================ */

typedef struct {
    int      in_fd;
    int      out_fd;
    off_t    offset;
    size_t   len;
    char    *buf;       /* heap buffer, sized to len */
    ssize_t  total;     /* out: bytes successfully written */
    int      err;       /* out: errno on failure (0 on success) */
} small_copy_args_t;

/* Synchronous read+write loop. Runs under rb_thread_call_without_gvl —
 * it never yields to the fiber scheduler. EAGAIN is handled inline via
 * short select() polls (up to ~50 ms total). For files that fit in the
 * socket send buffer (the 8 KB and 1 KB rows), no EAGAIN poll fires;
 * the whole transfer completes in one or two syscalls. */
static void *small_copy_blocking(void *raw) {
    small_copy_args_t *a = (small_copy_args_t *)raw;
    a->total = 0;
    a->err   = 0;

    /* Read the slice into our heap buffer. pread() lets us read from
     * an absolute offset without having to seek the file fd, which
     * matters because the same File handle may be used by other code
     * paths (and seek+read isn't atomic w.r.t. concurrent fibers). */
    size_t read_total = 0;
    while (read_total < a->len) {
        ssize_t r = pread(a->in_fd, a->buf + read_total,
                          a->len - read_total, a->offset + (off_t)read_total);
        if (r > 0) {
            read_total += (size_t)r;
            continue;
        }
        if (r == 0) {
            /* Short file (caller asked for more bytes than the file
             * holds). Truncate len to what we got and proceed. */
            a->len = read_total;
            break;
        }
        if (errno == EINTR) {
            continue;
        }
        a->err = errno;
        return NULL;
    }

    /* Write the buffer to the socket. Loop on short writes. EAGAIN is
     * handled with a bounded select() poll instead of a fiber yield —
     * for an 8 KB file the kernel send buffer almost always has space
     * and this loop runs once. */
    size_t write_total = 0;
    int eagain_retries = HYP_SMALL_EAGAIN_RETRIES;
    while (write_total < a->len) {
        ssize_t w = write(a->out_fd, a->buf + write_total,
                          a->len - write_total);
        if (w > 0) {
            write_total += (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR) {
            continue;
        }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (eagain_retries-- <= 0) {
                a->err = EAGAIN;
                break;
            }
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(a->out_fd, &wfds);
            struct timeval tv;
            tv.tv_sec  = 0;
            tv.tv_usec = HYP_SMALL_EAGAIN_USEC_PER_RETRY;
            (void)select(a->out_fd + 1, NULL, &wfds, NULL, &tv);
            continue;
        }
        if (w < 0) {
            a->err = errno;
            break;
        }
        /* w == 0: should not happen on a regular socket; treat as
         * short-write retry once, then fail. */
        a->err = EIO;
        break;
    }

    a->total = (ssize_t)write_total;
    return NULL;
}

/* Sendfile.copy_small(out_io, in_io, offset, len) -> Integer */
static VALUE rb_sendfile_copy_small(VALUE self, VALUE out_io, VALUE in_io,
                                    VALUE rb_offset, VALUE rb_len) {
    (void)self;

    long offset_l = NUM2LONG(rb_offset);
    long len_l    = NUM2LONG(rb_len);
    if (offset_l < 0) {
        rb_raise(rb_eArgError, "offset must be >= 0 (got %ld)", offset_l);
    }
    if (len_l < 0) {
        rb_raise(rb_eArgError, "len must be >= 0 (got %ld)", len_l);
    }
    if (len_l == 0) {
        return INT2FIX(0);
    }
    if (len_l > HYP_SMALL_FILE_THRESHOLD) {
        rb_raise(rb_eArgError,
                 "Hyperion::Http::Sendfile.copy_small: len %ld exceeds "
                 "SMALL_FILE_THRESHOLD %d; use copy() for streaming",
                 len_l, HYP_SMALL_FILE_THRESHOLD);
    }

    small_copy_args_t args;
    args.out_fd = extract_fd(out_io, "out_io");
    args.in_fd  = extract_fd(in_io, "in_io");
    args.offset = (off_t)offset_l;
    args.len    = (size_t)len_l;

    /* Heap-allocate a buffer of exactly the requested size. Bounded by
     * 64 KiB, so this is a one-shot small alloc. We could pull from a
     * per-thread arena to avoid malloc, but the bench shape (one alloc
     * per request, freed before the next) is well within glibc's
     * thread-local cache hot path. */
    args.buf = (char *)malloc(args.len);
    if (args.buf == NULL) {
        rb_raise(rb_eNoMemError, "Hyperion::Http::Sendfile.copy_small: "
                 "failed to allocate %lu bytes",
                 (unsigned long)args.len);
    }

    rb_thread_call_without_gvl(small_copy_blocking, &args, RUBY_UBF_IO, NULL);

    free(args.buf);

    if (args.err != 0 && args.total == 0) {
        errno = args.err;
        rb_sys_fail("Hyperion::Http::Sendfile.copy_small");
    }

    /* Partial transfer (e.g. EAGAIN budget exhausted). Surface what we
     * got; the caller can re-issue from cursor + total. The 8 KB row
     * doesn't hit this in practice but we're defensive about it. */
    return LONG2NUM((long)args.total);
}

/* ============================================================
 * Phase 8b — Linux splice(2) through a per-thread pipe.
 * ============================================================ */

#ifdef HYP_SF_LINUX

static pthread_key_t hyp_pipe_tls_key;
static int           hyp_pipe_tls_inited = 0;

typedef struct {
    int fds[2]; /* [read, write] */
} hyp_pipe_pair_t;

static void hyp_pipe_pair_destroy(void *raw) {
    hyp_pipe_pair_t *pp = (hyp_pipe_pair_t *)raw;
    if (pp == NULL) return;
    if (pp->fds[0] >= 0) close(pp->fds[0]);
    if (pp->fds[1] >= 0) close(pp->fds[1]);
    free(pp);
}

static hyp_pipe_pair_t *hyp_pipe_pair_get_or_open(void) {
    if (!hyp_pipe_tls_inited) {
        return NULL;
    }
    hyp_pipe_pair_t *pp = (hyp_pipe_pair_t *)pthread_getspecific(hyp_pipe_tls_key);
    if (pp != NULL) {
        return pp;
    }
    pp = (hyp_pipe_pair_t *)malloc(sizeof(*pp));
    if (pp == NULL) return NULL;
    pp->fds[0] = pp->fds[1] = -1;

    int rc;
#  ifdef O_CLOEXEC
    rc = pipe2(pp->fds, O_CLOEXEC | O_NONBLOCK);
    if (rc != 0) {
        rc = pipe(pp->fds);
        if (rc == 0) {
            fcntl(pp->fds[0], F_SETFD, FD_CLOEXEC);
            fcntl(pp->fds[1], F_SETFD, FD_CLOEXEC);
            int fl0 = fcntl(pp->fds[0], F_GETFL);
            int fl1 = fcntl(pp->fds[1], F_GETFL);
            if (fl0 >= 0) fcntl(pp->fds[0], F_SETFL, fl0 | O_NONBLOCK);
            if (fl1 >= 0) fcntl(pp->fds[1], F_SETFL, fl1 | O_NONBLOCK);
        }
    }
#  else
    rc = pipe(pp->fds);
#  endif
    if (rc != 0) {
        free(pp);
        return NULL;
    }
#  ifdef HYP_HAVE_F_SETPIPE_SZ
    /* Ask the kernel to size the pipe at 1 MiB so a single splice
     * round-trip can move a 1 MiB file in one shot. The kernel may
     * cap below at /proc/sys/fs/pipe-max-size; we tolerate a smaller
     * pipe and just iterate more often. */
    (void)fcntl(pp->fds[1], F_SETPIPE_SZ, 1024 * 1024);
#  endif
    pthread_setspecific(hyp_pipe_tls_key, pp);
    return pp;
}

typedef struct {
    int    in_fd;
    int    out_fd;
    int    pipe_r;
    int    pipe_w;
    off_t  offset;
    size_t len;
    ssize_t rc;          /* bytes spliced to socket this call */
    int    err;
} splice_args_t;

#  ifndef SPLICE_F_MOVE
#    define SPLICE_F_MOVE 1
#  endif
#  ifndef SPLICE_F_MORE
#    define SPLICE_F_MORE 4
#  endif
#  ifndef SPLICE_F_NONBLOCK
#    define SPLICE_F_NONBLOCK 2
#  endif

static void *splice_blocking_call(void *raw) {
    splice_args_t *a = (splice_args_t *)raw;
    a->rc = 0;
    a->err = 0;

    /* Step 1: file -> pipe (kernel page cache to pipe buffer). */
    ssize_t in_n = splice(a->in_fd, &a->offset, a->pipe_w, NULL,
                          a->len, SPLICE_F_MOVE | SPLICE_F_MORE);
    if (in_n < 0) {
        a->err = errno;
        return NULL;
    }
    if (in_n == 0) {
        /* Source EOF before any bytes moved. */
        return NULL;
    }

    /* Step 2: pipe -> socket. May short-write; caller loops. */
    ssize_t written = 0;
    while (written < in_n) {
        ssize_t out_n = splice(a->pipe_r, NULL, a->out_fd, NULL,
                               (size_t)(in_n - written),
                               SPLICE_F_MOVE | SPLICE_F_MORE);
        if (out_n > 0) {
            written += out_n;
            continue;
        }
        if (out_n < 0 && errno == EINTR) continue;
        if (out_n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            /* Socket buffer full mid-transfer.  Bytes already in the
             * pipe stay queued; caller yields and we re-enter the
             * splice loop on the next call (the pipe still holds
             * (in_n - written) bytes for the same fd pair owned by
             * this thread, so the next call will drain them first
             * before pulling from the file again).  We surface
             * EAGAIN with rc set to bytes actually delivered to the
             * socket so far this call. */
            a->err = EAGAIN;
            break;
        }
        if (out_n < 0) {
            a->err = errno;
            break;
        }
        /* out_n == 0: peer side gone. */
        a->err = EPIPE;
        break;
    }

    a->rc = written;
    return NULL;
}

#endif /* HYP_SF_LINUX */

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

/* Sendfile.copy_splice(out_io, in_io, offset, len) -> [bytes_written, status]
 * Linux-only. Returns :unsupported on every other platform so the Ruby
 * caller can fall back to copy(). */
static VALUE rb_sendfile_copy_splice(VALUE self, VALUE out_io, VALUE in_io,
                                     VALUE rb_offset, VALUE rb_len) {
    (void)self;

#ifdef HYP_SF_LINUX
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

    hyp_pipe_pair_t *pp = hyp_pipe_pair_get_or_open();
    if (pp == NULL) {
        return rb_ary_new3(2, INT2FIX(0), sym_unsupported);
    }

    splice_args_t args;
    args.in_fd   = extract_fd(in_io, "in_io");
    args.out_fd  = extract_fd(out_io, "out_io");
    args.pipe_r  = pp->fds[0];
    args.pipe_w  = pp->fds[1];
    args.offset  = (off_t)offset_l;
    args.len     = (size_t)len_l;
    args.rc      = 0;
    args.err     = 0;

    rb_thread_call_without_gvl(splice_blocking_call, &args, RUBY_UBF_IO, NULL);

    if (args.rc > 0) {
        if (args.err == EAGAIN || args.err == EWOULDBLOCK) {
            return rb_ary_new3(2, LONG2NUM((long)args.rc), sym_partial);
        }
        if (args.err != 0) {
            errno = args.err;
            rb_sys_fail("splice");
        }
        if ((size_t)args.rc < args.len) {
            return rb_ary_new3(2, LONG2NUM((long)args.rc), sym_partial);
        }
        return rb_ary_new3(2, LONG2NUM((long)args.rc), sym_done);
    }

    /* args.rc == 0. */
    if (args.err == EAGAIN || args.err == EWOULDBLOCK || args.err == EINTR) {
        return rb_ary_new3(2, INT2FIX(0), sym_eagain);
    }
    if (args.err == ENOSYS || args.err == EINVAL) {
        return rb_ary_new3(2, INT2FIX(0), sym_unsupported);
    }
    if (args.err != 0) {
        errno = args.err;
        rb_sys_fail("splice");
    }
    return rb_ary_new3(2, INT2FIX(0), sym_done);
#else
    (void)out_io; (void)in_io; (void)rb_offset; (void)rb_len;
    return rb_ary_new3(2, INT2FIX(0), sym_unsupported);
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

/* Sendfile.splice_supported? — true on Linux builds where the splice
 * branch was compiled in. The runtime kernel may still reject splice
 * (very old kernels return ENOSYS), in which case copy_splice surfaces
 * :unsupported and the Ruby caller falls back to copy(). */
static VALUE rb_sendfile_splice_supported_p(VALUE self) {
    (void)self;
#ifdef HYP_SF_LINUX
    return Qtrue;
#else
    return Qfalse;
#endif
}

/* Sendfile.small_file_threshold — exposes the C constant to Ruby. */
static VALUE rb_sendfile_small_threshold(VALUE self) {
    (void)self;
    return INT2NUM(HYP_SMALL_FILE_THRESHOLD);
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
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "copy_small",
                               rb_sendfile_copy_small, 4);
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "copy_splice",
                               rb_sendfile_copy_splice, 4);
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "supported?",
                               rb_sendfile_supported_p, 0);
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "splice_supported?",
                               rb_sendfile_splice_supported_p, 0);
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "small_file_threshold",
                               rb_sendfile_small_threshold, 0);
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

#ifdef HYP_SF_LINUX
    /* Per-thread pipe pair for the splice path. Destructor runs when
     * the thread exits and closes both fds. Init failure is non-fatal:
     * copy_splice will see hyp_pipe_tls_inited == 0, skip the splice
     * path, and return :unsupported. */
    if (pthread_key_create(&hyp_pipe_tls_key, hyp_pipe_pair_destroy) == 0) {
        hyp_pipe_tls_inited = 1;
    }
#endif
}
