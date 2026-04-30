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
 *   Sendfile.copy_splice(out_io, in_io, offset, len) -> [bytes_written, status]
 *     2.0.1 Phase 8b primitive; 2.2.0 lifecycle — opens a fresh
 *     pipe2(O_CLOEXEC | O_NONBLOCK) pair on every call and closes
 *     both fds on every exit path (success, EAGAIN, error, EOF).
 *     Two extra syscalls per call vs the old TLS-cached layout, but
 *     correctness is restored: a partial transfer interrupted by
 *     EPIPE cannot leak residual bytes onto the next request's
 *     socket.  Kept as a self-contained one-shot primitive for
 *     small payloads or out-of-band callers that don't want to
 *     manage the pipe lifecycle.
 *
 *   Sendfile.copy_splice_into_pipe(out_io, in_io, offset, len, pipe_r, pipe_w)
 *       -> [bytes_written, status]
 *     2.2.x fix-A primitive — splice ladder for ONE chunk against a
 *     CALLER-PROVIDED pipe pair.  Does NOT open or close the pipe;
 *     the Ruby caller (`native_copy_loop` in lib/hyperion/http/sendfile.rb)
 *     opens one pipe2(O_CLOEXEC | O_NONBLOCK) per RESPONSE, hands the
 *     fds in for every chunk of the response, and closes them in an
 *     ensure block when the loop unwinds.  For a 1 MiB asset at 64 KiB
 *     chunks that's 16 splice-rounds + 1 pipe2 + 2 closes = 19 syscalls
 *     versus the old per-chunk `copy_splice` shape's 16 splice-rounds +
 *     16 pipe2 + 32 closes = 64 syscalls; a 3.4× syscall-count reduction
 *     per 1 MiB request, which restores the splice-vs-sendfile win the
 *     bench sweep on 2026-04-30 lost (see CHANGELOG 2.2.x fix-A).
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
 *     pipe pair (file_fd -> pipe_w -> sock_fd) with
 *     SPLICE_F_MOVE | SPLICE_F_MORE for an extra ~5-15% over plain
 *     sendfile on the 1 MiB asset.  2.0.1 cached one pipe per OS
 *     thread; 2.2.0 opens a fresh pipe per call and closes it on
 *     every exit path (success, EAGAIN, error, EOF).  The two
 *     extra syscalls per call (pipe2 + 2× close) are amortized
 *     against the kernel-side zero-copy splice transfer; correctness
 *     is unconditional: a pipe never carries bytes for more than
 *     one transfer, so EPIPE mid-transfer cannot leak residual
 *     bytes onto the next request's socket.
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

/* 2.6-B — posix_fadvise(SEQUENTIAL) hint threshold.
 *
 * For files larger than 256 KiB we tell the kernel "I'm reading this
 * file sequentially from `offset` for `len` bytes" so it can pre-read
 * the page cache aggressively and subsequent sendfile / splice rounds
 * don't wait on disk I/O.  Cold-cache scenarios benefit the most:
 * deploys serving large assets, the first request after a restart,
 * page-cache eviction under memory pressure.  Warm-cache is neutral
 * (the pages are already resident; the hint is a no-op).
 *
 * The threshold avoids paying the syscall cost on small files where
 * the win is not worth it.  After 2.6-A's chunking the streaming
 * loops cap each kernel call at `USERSPACE_CHUNK` (256 KiB), so a
 * file of exactly 256 KiB rides the path in one chunk with `len ==
 * 256 KiB` and any larger file rides it in chunks of `len == 256
 * KiB` (plus a remainder).  We therefore gate on `len >= 256 KiB`
 * rather than strictly greater than: that fires the hint on every
 * chunk of any file ≥ 256 KiB.  Per-chunk advising is what the
 * kernel's read-ahead heuristic was designed for — repeated calls
 * over the same fd at sequential offsets reinforce the sequential-
 * access tag without per-call cost (the kernel coalesces).
 *
 * Linux-only; the call is gated by `#if defined(__linux__) &&
 * defined(POSIX_FADV_SEQUENTIAL)`.  macOS / BSD compile without it.
 *
 * The return value is informational: some kernels return -EINVAL on
 * certain fd types (e.g. tmpfs-backed files in older kernels).  We
 * intentionally ignore it — sendfile / splice still works, the hint
 * was just optional.
 */
#define HYP_FADVISE_SEQUENTIAL_THRESHOLD (256 * 1024)

/* Best-effort sequential-read hint for the page cache.  Linux-only;
 * the no-op on every other platform keeps the call sites uncluttered.
 * Return value deliberately discarded — fadvise failures are not
 * fatal. */
static inline void hyp_advise_sequential(int file_fd, off_t offset, size_t len) {
#if defined(__linux__) && defined(POSIX_FADV_SEQUENTIAL)
    if (len >= HYP_FADVISE_SEQUENTIAL_THRESHOLD) {
        (void)posix_fadvise(file_fd, offset, (off_t)len, POSIX_FADV_SEQUENTIAL);
    }
#else
    (void)file_fd;
    (void)offset;
    (void)len;
#endif
}

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
 * Phase 8b / 2.2.0 — Linux splice(2) through a fresh per-request pipe.
 * ============================================================
 *
 * 2.0.1 originally cached one pipe pair per OS thread in pthread TLS.
 * That layout leaked residual bytes between requests on EPIPE: if
 * splice(file -> pipe) succeeded but splice(pipe -> sock) failed
 * mid-transfer (peer closed), the unread bytes stayed in the pipe
 * and were sent on the NEXT connection's socket.  The 2.0.1 release
 * disabled the splice path entirely from copy_to_socket and routed
 * production traffic back through plain sendfile.
 *
 * 2.2.0 fix — fresh pipe pair per call.  pipe2(O_CLOEXEC) at entry,
 * close both fds on every exit path (success, EAGAIN, error, EOF).
 * Two extra syscalls per call, but the splice copies remain
 * kernel-side zero-copy (file -> pipe -> socket, page cache bytes
 * never enter userspace) and the correctness window is gone: a pipe
 * pair only ever carries bytes for one transfer.  No persistent
 * state, no fd leak across thousands of requests, no cross-connection
 * byte leak. */

#ifdef HYP_SF_LINUX

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

/* Open a fresh pipe pair for a single splice call.  Returns 0 on
 * success and writes the [read, write] fds into out_fds; returns
 * -errno on failure (caller surfaces :unsupported / :eagain to
 * Ruby).  Always pairs with hyp_close_pipe_pair on every exit
 * path. */
static int hyp_open_pipe_pair(int out_fds[2]) {
    out_fds[0] = out_fds[1] = -1;

    int rc;
#  ifdef O_CLOEXEC
    rc = pipe2(out_fds, O_CLOEXEC | O_NONBLOCK);
    if (rc != 0 && errno == ENOSYS) {
        rc = pipe(out_fds);
        if (rc == 0) {
            fcntl(out_fds[0], F_SETFD, FD_CLOEXEC);
            fcntl(out_fds[1], F_SETFD, FD_CLOEXEC);
            int fl0 = fcntl(out_fds[0], F_GETFL);
            int fl1 = fcntl(out_fds[1], F_GETFL);
            if (fl0 >= 0) fcntl(out_fds[0], F_SETFL, fl0 | O_NONBLOCK);
            if (fl1 >= 0) fcntl(out_fds[1], F_SETFL, fl1 | O_NONBLOCK);
        }
    }
#  else
    rc = pipe(out_fds);
#  endif
    if (rc != 0) {
        return -errno;
    }
#  ifdef HYP_HAVE_F_SETPIPE_SZ
    /* Best-effort: ask the kernel to size this pipe at 1 MiB so the
     * splice loop can move a 1 MiB file in a small number of
     * round-trips.  Cap at /proc/sys/fs/pipe-max-size; we ignore
     * failure and iterate more often on a smaller pipe. */
    (void)fcntl(out_fds[1], F_SETPIPE_SZ, 1024 * 1024);
#  endif
    return 0;
}

static void hyp_close_pipe_pair(int fds[2]) {
    if (fds[0] >= 0) {
        close(fds[0]);
        fds[0] = -1;
    }
    if (fds[1] >= 0) {
        close(fds[1]);
        fds[1] = -1;
    }
}

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

    /* Step 2: pipe -> socket. May short-write; loop until the pipe
     * is fully drained or the socket signals EAGAIN/error.  We
     * surface the count of bytes actually delivered to the socket
     * (`written`), NOT the count we read from the file (`in_n`).
     * Any (in_n - written) bytes still queued in the pipe will be
     * dropped when the caller closes the pipe pair on its way out.
     * This is safe because the file offset we passed in by pointer
     * is local (a->offset) and the Ruby caller tracks its own
     * absolute cursor — on retry it passes a fresh offset of
     * old_cursor + written, so the file is re-read from the right
     * place and no bytes are duplicated or skipped on the wire. */
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
            /* Socket buffer full.  Surface what we got; pipe will
             * be closed by the caller (drops the in_n-written bytes
             * still queued in it — caller's offset arithmetic
             * compensates). */
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

    /* 2.6-B — page-cache pre-read hint for files > 256 KiB.  See
     * hyp_advise_sequential for the rationale. */
    hyp_advise_sequential(args.in_fd, args.offset, args.len);

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
 * Linux-only.  2.2.0 layout: opens a fresh pipe pair via
 * pipe2(O_CLOEXEC | O_NONBLOCK) on every call and closes it on every
 * exit path.  No persistent state, no cross-request byte leak.
 * Returns :unsupported on non-Linux hosts so the Ruby caller can fall
 * back to copy(). */
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

    /* Fresh pipe pair for THIS call only.  Opened here, closed on
     * every exit path below.  pipe2 is one syscall; the close pair
     * is two more.  The 3-syscall overhead is amortized against the
     * splice copies (which stay zero-copy across file -> pipe ->
     * socket) for files >= 64 KiB; the Ruby caller gates on size. */
    int pipe_fds[2];
    int prc = hyp_open_pipe_pair(pipe_fds);
    if (prc != 0) {
        /* pipe2 / pipe failed.  ENOSYS / EMFILE / ENFILE — all map
         * to "splice path can't run right now"; let the caller fall
         * back to plain sendfile. */
        return rb_ary_new3(2, INT2FIX(0), sym_unsupported);
    }

    splice_args_t args;
    args.in_fd   = extract_fd(in_io, "in_io");
    args.out_fd  = extract_fd(out_io, "out_io");
    args.pipe_r  = pipe_fds[0];
    args.pipe_w  = pipe_fds[1];
    args.offset  = (off_t)offset_l;
    args.len     = (size_t)len_l;
    args.rc      = 0;
    args.err     = 0;

    /* 2.6-B — page-cache pre-read hint for files > 256 KiB. */
    hyp_advise_sequential(args.in_fd, args.offset, args.len);

    rb_thread_call_without_gvl(splice_blocking_call, &args, RUBY_UBF_IO, NULL);

    /* Close the pipe pair before we either return a value or
     * raise.  This is the whole point of the 2.2.0 fix: the pipe
     * never outlives this call, so residual bytes from a partial
     * transfer cannot leak onto the next request's socket. */
    hyp_close_pipe_pair(pipe_fds);

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

/* Sendfile.copy_splice_into_pipe(out_io, in_io, offset, len, pipe_r, pipe_w)
 *   -> [bytes_written, status]
 *
 * 2.2.x fix-A — pipe-hoisted splice primitive.
 *
 * Splices file_fd → pipe_w → sock_fd for ONE chunk of a response.  The
 * pipe pair is supplied by the caller and is reused across every chunk
 * of a single response; this function does NOT open or close the pipe.
 * The Ruby façade (`native_copy_loop`) is responsible for the
 * pipe lifecycle (`open_splice_pipe!` at entry, `close` in an ensure
 * block at exit).  Same return shape as `copy_splice` — :done /
 * :partial / :eagain / :unsupported.
 *
 * Linux-only.  Returns [0, :unsupported] on non-Linux hosts so the
 * Ruby caller can fall back to plain sendfile.  pipe_r / pipe_w may
 * be Integer fds or IO objects (`IO.pipe` returns the latter); we
 * extract via the same helper used for in_io/out_io. */
static VALUE rb_sendfile_copy_splice_into_pipe(VALUE self, VALUE out_io, VALUE in_io,
                                               VALUE rb_offset, VALUE rb_len,
                                               VALUE rb_pipe_r, VALUE rb_pipe_w) {
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

    splice_args_t args;
    args.in_fd   = extract_fd(in_io, "in_io");
    args.out_fd  = extract_fd(out_io, "out_io");
    args.pipe_r  = extract_fd(rb_pipe_r, "pipe_r");
    args.pipe_w  = extract_fd(rb_pipe_w, "pipe_w");
    args.offset  = (off_t)offset_l;
    args.len     = (size_t)len_l;
    args.rc      = 0;
    args.err     = 0;

    /* 2.6-B — page-cache pre-read hint for files > 256 KiB.  Called
     * per chunk; if the same file is being streamed across multiple
     * chunks the kernel coalesces redundant hints, so the per-chunk
     * cost is negligible.  We pass the chunk's local offset/len so
     * the hint stays scoped to "the bytes we're about to splice". */
    hyp_advise_sequential(args.in_fd, args.offset, args.len);

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
    (void)rb_pipe_r; (void)rb_pipe_w;
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
    rb_define_singleton_method(rb_mHyperionHttpSendfile, "copy_splice_into_pipe",
                               rb_sendfile_copy_splice_into_pipe, 6);
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

    /* 2.2.0 — the splice path no longer carries persistent state.
     * Each copy_splice() call opens its own pipe2(O_CLOEXEC) pair
     * and closes both fds before returning.  No TLS key, no
     * destructor, no cross-request residual-bytes window. */
}
