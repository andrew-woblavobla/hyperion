/* ----------------------------------------------------------------------
 * io_uring_loop.c — 2.12-D — io_uring-driven C accept loop.
 *
 * Sibling translation unit to page_cache.c's 2.12-C `accept4` loop.
 * Same wire contract (handle_static-only routes, plain TCP, lifecycle
 * + handoff Ruby callbacks); the only difference is *how* the kernel
 * I/O is driven.
 *
 * Design
 * ------
 * Single ring per `run_static_io_uring_loop` invocation. Operator
 * boots one worker per CPU; each worker calls into this loop and gets
 * its own ring. No ring is shared across threads or across fork — fits
 * the same model `Hyperion::IOUring` already established for the
 * Rust-cdylib path.
 *
 * On entry we:
 *   1. Probe `liburing` at runtime (`io_uring_queue_init`). On failure
 *      we return `:unavailable` so the Ruby caller falls through to
 *      the 2.12-C `accept4` path. Probe failure is the dominant path
 *      on locked-down containers (seccomp blocks `io_uring_setup`),
 *      old kernels, and the like.
 *   2. Submit a multishot ACCEPT SQE on the listener fd. Multishot
 *      delivers one CQE per accepted connection without re-arming.
 *   3. Drain CQEs in a loop. For each completion we advance the
 *      connection's state machine: ACCEPT -> RECV -> WRITE -> CLOSE.
 *   4. After draining, submit any newly-armed SQEs and park on
 *      `io_uring_submit_and_wait(1)`. The kernel batches I/O the
 *      worker thread does **one** `io_uring_enter` per N CQEs in
 *      steady state instead of N×3 syscalls (accept + recv + write).
 *
 * Per-connection state lives in a `hyp_iu_conn_t` allocated on the
 * heap. `user_data` on each SQE is `(uintptr_t)conn | tag` where
 * `tag` is one of the OP_TYPE_* low-bit markers. The arena is
 * intentionally simple: we don't pool — `malloc`/`free` per connection
 * is far cheaper than the 3 syscalls we're saving (and the kernel's
 * own SQE pool is the real win).
 *
 * GVL
 * ---
 * The loop runs INSIDE `rb_thread_call_without_gvl` for `submit_and_wait`,
 * but we re-acquire the GVL whenever we need to call into Ruby
 * (lifecycle callback, handoff callback, and `pc_internal_*` helpers
 * that touch Ruby objects — actually the snapshot helper takes the
 * pthread mutex but no Ruby state, so it's safe to call without the
 * GVL). The hot path (no hooks, no handoffs) stays without the GVL
 * for the entire `submit_and_wait` cycle.
 *
 * Build gating
 * ------------
 * The whole io_uring code path lives behind `#ifdef HAVE_LIBURING`.
 * On macOS / hosts without `liburing-dev` the file compiles down to
 * the stub init that registers `run_static_io_uring_loop` returning
 * `:unavailable`. The stub keeps the Ruby surface stable across
 * platforms — specs that check for the method's existence pass on
 * Darwin too; only the body is gated.
 *
 * 2.12-D — initial drop.
 * ---------------------------------------------------------------------- */

#include <ruby.h>
#include <ruby/thread.h>

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>

#include "page_cache_internal.h"

/* Ruby identifiers we cache at init time. */
static VALUE hyp_iu_sym_unavailable = Qnil;
static VALUE hyp_iu_sym_crashed     = Qnil;

#if defined(__linux__) && defined(HAVE_LIBURING)

#include <liburing.h>

/* Per-worker ring state. Single instance per `run_static_io_uring_loop`
 * invocation — the ring is freed on return. */
typedef struct hyp_iu_loop_s {
    struct io_uring ring;
    int             listen_fd;
    long            served;
    /* Counters operators don't see directly but specs use to confirm
     * we walked the io_uring code path (vs. a fall-through). */
    long            accepts;
    long            handoffs;
    long            closes;
    /* Set when the loop should drain remaining CQEs and exit. The
     * shared `pc_internal_stop_requested()` flag flips this on
     * `PageCache.stop_accept_loop`. */
    int             stopping;
    /* Bound on outstanding connections — avoids unbounded heap growth
     * under a SYN flood. The kernel will keep accepting onto its own
     * accept queue; we just stop pulling them off until headroom
     * frees up. */
    int             inflight;
    int             max_inflight;
} hyp_iu_loop_t;

/* Connection-level state. One alloc per accepted fd; freed on close
 * completion. */
typedef enum {
    HYP_IU_OP_ACCEPT = 0x1,
    HYP_IU_OP_RECV   = 0x2,
    HYP_IU_OP_WRITE  = 0x3,
    HYP_IU_OP_CLOSE  = 0x4
} hyp_iu_op_t;

#define HYP_IU_OP_MASK   0x7u
#define HYP_IU_OP_SHIFT  0u

typedef struct hyp_iu_conn_s {
    int      fd;
    /* Read buffer. Header section is bounded by PC_INTERNAL_MAX_HEADER_BYTES;
     * we allocate a single 8 KiB chunk eagerly (matches the 2.12-C
     * loop's HYP_CL_READ_CHUNK + the typical request shape) and grow
     * up to the cap on header straddle. */
    char    *rbuf;
    size_t   rcap;
    size_t   roff;
    /* Response snapshot. Owned by the conn; freed in CLOSE handler
     * after the WRITE completes. */
    char    *wbuf;
    size_t   wlen;
    size_t   wsent;
    /* Method/path offsets within rbuf — kept across stages so the
     * lifecycle callback fires with the right strings even after the
     * write completes. */
    size_t   method_off, method_len;
    size_t   path_off, path_len;
    /* Whether the request asked for `Connection: close`. We honour
     * keep-alive in steady state; close-request shortens the
     * connection lifetime. */
    int      keep_alive;
    int      handed_off;
} hyp_iu_conn_t;

#define HYP_IU_RBUF_INITIAL  8192
#define HYP_IU_DEFAULT_DEPTH 256
#define HYP_IU_DEFAULT_MAX_INFLIGHT 4096

/* Pack/unpack `(conn_ptr, op_tag)` into `user_data`. `conn` pointers are
 * malloc'd, so the low 3 bits are zero — we steal them for the op tag.
 * On exotic allocators where this isn't safe, swap to a dedicated tag
 * field on the conn struct + per-op tag table; for glibc / musl /
 * jemalloc this packing is sound (alignof(max_align_t) >= 8). */
static inline uint64_t hyp_iu_pack_ud(hyp_iu_conn_t *c, hyp_iu_op_t op) {
    return ((uint64_t)(uintptr_t)c) | ((uint64_t)op & HYP_IU_OP_MASK);
}
static inline hyp_iu_conn_t *hyp_iu_unpack_conn(uint64_t ud) {
    return (hyp_iu_conn_t *)(uintptr_t)(ud & ~(uint64_t)HYP_IU_OP_MASK);
}
static inline hyp_iu_op_t hyp_iu_unpack_op(uint64_t ud) {
    return (hyp_iu_op_t)(ud & HYP_IU_OP_MASK);
}

/* Allocate a connection-state struct. NULL on OOM. */
static hyp_iu_conn_t *hyp_iu_conn_new(int fd) {
    hyp_iu_conn_t *c = (hyp_iu_conn_t *)calloc(1, sizeof(*c));
    if (c == NULL) {
        return NULL;
    }
    c->fd   = fd;
    c->rbuf = (char *)malloc(HYP_IU_RBUF_INITIAL);
    if (c->rbuf == NULL) {
        free(c);
        return NULL;
    }
    c->rcap = HYP_IU_RBUF_INITIAL;
    c->keep_alive = 1;
    return c;
}

static void hyp_iu_conn_free(hyp_iu_conn_t *c) {
    if (c == NULL) return;
    free(c->rbuf);
    free(c->wbuf);
    free(c);
}

/* Submit a CLOSE op for a fd. The fd is closed via io_uring rather than
 * a direct close(2) so we collapse one more syscall into the ring's
 * `submit_and_wait` cycle. The CLOSE completion's only responsibility
 * is to free the conn struct. */
static void hyp_iu_submit_close(hyp_iu_loop_t *L, hyp_iu_conn_t *c) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&L->ring);
    if (sqe == NULL) {
        /* SQ full — fall back to direct close + free here. The conn
         * struct is freed inline; we DO NOT touch the ring so the
         * caller's submit cycle stays clean. */
        if (c->fd >= 0) close(c->fd);
        hyp_iu_conn_free(c);
        L->inflight--;
        L->closes++;
        return;
    }
    io_uring_prep_close(sqe, c->fd);
    io_uring_sqe_set_data64(sqe, hyp_iu_pack_ud(c, HYP_IU_OP_CLOSE));
}

/* Submit a RECV onto the conn's read buffer. Reads into the tail of
 * the buffer (rbuf + roff), up to rcap - roff bytes. */
static int hyp_iu_submit_recv(hyp_iu_loop_t *L, hyp_iu_conn_t *c) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&L->ring);
    if (sqe == NULL) {
        return -1;
    }
    io_uring_prep_recv(sqe, c->fd, c->rbuf + c->roff, c->rcap - c->roff, 0);
    io_uring_sqe_set_data64(sqe, hyp_iu_pack_ud(c, HYP_IU_OP_RECV));
    return 0;
}

/* Submit a WRITE for the prepared response snapshot. */
static int hyp_iu_submit_write(hyp_iu_loop_t *L, hyp_iu_conn_t *c) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&L->ring);
    if (sqe == NULL) {
        return -1;
    }
    io_uring_prep_send(sqe, c->fd, c->wbuf + c->wsent, c->wlen - c->wsent, 0);
    io_uring_sqe_set_data64(sqe, hyp_iu_pack_ud(c, HYP_IU_OP_WRITE));
    return 0;
}

/* Submit the multishot ACCEPT on the listener. Multishot continues
 * delivering CQEs until the kernel returns -ENOBUFS or the SQE is
 * cancelled; we re-arm only on -ENOBUFS. */
static int hyp_iu_submit_accept(hyp_iu_loop_t *L) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&L->ring);
    if (sqe == NULL) {
        return -1;
    }
    io_uring_prep_multishot_accept(sqe, L->listen_fd, NULL, NULL, 0);
    /* user_data: special tag (no conn pointer) — accept ops have no
     * conn-state until the completion delivers the new fd. We use a
     * dedicated tag-only encoding: zero conn pointer + ACCEPT tag. */
    io_uring_sqe_set_data64(sqe, hyp_iu_pack_ud(NULL, HYP_IU_OP_ACCEPT));
    return 0;
}

/* Process the request currently buffered in `c->rbuf[0..c->roff]`. On
 * a static-cache hit, snapshots the response into `c->wbuf` + arms a
 * WRITE. On any miss, hands the connection off to Ruby (CLOSE the fd
 * locally is NOT correct — Ruby owns it from that point on).
 *
 * Returns 1 if we armed a WRITE on the conn (the loop will see a
 * WRITE completion next), 0 if the conn was handed off / closed
 * (caller should NOT touch it further — `c` is invalid). */
static int hyp_iu_dispatch_request(hyp_iu_loop_t *L, hyp_iu_conn_t *c) {
    long eoh = pc_internal_find_eoh(c->rbuf, c->roff);
    if (eoh < 0) {
        /* Need more bytes. Re-arm RECV (the buffer might need to grow
         * — handled by the caller before re-submission via roff/rcap). */
        if (c->roff >= c->rcap) {
            if (c->rcap >= PC_INTERNAL_MAX_HEADER_BYTES) {
                /* Header section exceeds cap — hand off to Ruby. */
                pc_internal_handoff(c->fd, c->rbuf, c->roff);
                c->handed_off = 1;
                hyp_iu_conn_free(c);
                L->handoffs++;
                L->inflight--;
                return 0;
            }
            size_t new_cap = c->rcap * 2;
            if (new_cap > PC_INTERNAL_MAX_HEADER_BYTES) {
                new_cap = PC_INTERNAL_MAX_HEADER_BYTES;
            }
            char *grown = (char *)realloc(c->rbuf, new_cap);
            if (grown == NULL) {
                /* OOM — close the connection (best we can do). */
                hyp_iu_submit_close(L, c);
                return 0;
            }
            c->rbuf = grown;
            c->rcap = new_cap;
        }
        if (hyp_iu_submit_recv(L, c) < 0) {
            /* SQ full — close. The kernel will retry on next cycle
             * after we drain. */
            hyp_iu_submit_close(L, c);
            return 0;
        }
        return 1; /* technically RECV not WRITE, but caller treats
                   * the same: conn still owned by us. */
    }

    long req_line_end = pc_internal_parse_request_line(
        c->rbuf, (size_t)eoh,
        &c->method_off, &c->method_len,
        &c->path_off,   &c->path_len);
    if (req_line_end < 0) {
        pc_internal_handoff(c->fd, c->rbuf, c->roff);
        c->handed_off = 1;
        hyp_iu_conn_free(c);
        L->handoffs++;
        L->inflight--;
        return 0;
    }

    int connection_close = 0;
    int has_body = 0;
    int upgrade_seen = 0;
    int hdr_ok = pc_internal_scan_headers(c->rbuf, (size_t)req_line_end,
                                          (size_t)eoh, &connection_close,
                                          &has_body, &upgrade_seen);
    if (hdr_ok != 0 || has_body || upgrade_seen) {
        pc_internal_handoff(c->fd, c->rbuf, c->roff);
        c->handed_off = 1;
        hyp_iu_conn_free(c);
        L->handoffs++;
        L->inflight--;
        return 0;
    }

    pc_internal_method_t kind = pc_internal_classify_method(
        c->rbuf + c->method_off, c->method_len);
    if (kind == PC_INTERNAL_METHOD_OTHER) {
        pc_internal_handoff(c->fd, c->rbuf, c->roff);
        c->handed_off = 1;
        hyp_iu_conn_free(c);
        L->handoffs++;
        L->inflight--;
        return 0;
    }

    size_t snap_len = 0;
    char *snap = pc_internal_snapshot_response(
        c->rbuf + c->path_off, c->path_len, kind, &snap_len);
    if (snap == NULL) {
        pc_internal_handoff(c->fd, c->rbuf, c->roff);
        c->handed_off = 1;
        hyp_iu_conn_free(c);
        L->handoffs++;
        L->inflight--;
        return 0;
    }

    c->wbuf       = snap;
    c->wlen       = snap_len;
    c->wsent      = 0;
    c->keep_alive = connection_close ? 0 : 1;
    /* Stash the request boundary so RECV completions for the NEXT
     * pipelined request can shift the buffer. We don't carry pipelining
     * across the CQE boundary today — the typical wrk shape closes per
     * connection or pipelines one or two requests. Left as a 2.13
     * follow-up: shift `rbuf` by `eoh` post-write so a queued
     * pipelined request can be parsed without an extra RECV. */
    (void)eoh; /* silence unused-warning when assertion stripped */

    if (hyp_iu_submit_write(L, c) < 0) {
        free(c->wbuf); c->wbuf = NULL;
        hyp_iu_submit_close(L, c);
        return 0;
    }
    return 1;
}

/* Lifecycle hook firing: needs the GVL because the registered Ruby
 * callback runs on it. Wrap with `rb_thread_call_with_gvl` only when
 * the gate is on; the no-hook hot path skips the round-trip entirely. */
typedef struct {
    const char *method;
    size_t      mlen;
    const char *path;
    size_t      plen;
} hyp_iu_hook_args_t;

static void *hyp_iu_fire_lifecycle_with_gvl(void *raw) {
    hyp_iu_hook_args_t *a = (hyp_iu_hook_args_t *)raw;
    pc_internal_fire_lifecycle(a->method, a->mlen, a->path, a->plen);
    return NULL;
}

/* Drain ready CQEs. Called inside the without-GVL region — but the
 * inner Ruby-callback firing wraps GVL re-acquisition for the
 * milliseconds the hook runs. Returns 1 if the listener was closed
 * (graceful exit signal), 0 otherwise. */
static int hyp_iu_drain_cqes(hyp_iu_loop_t *L) {
    struct io_uring_cqe *cqe;
    unsigned head;
    int      processed = 0;
    int      listener_closed = 0;

    io_uring_for_each_cqe(&L->ring, head, cqe) {
        processed++;
        uint64_t ud = cqe->user_data;
        hyp_iu_op_t op = hyp_iu_unpack_op(ud);
        hyp_iu_conn_t *c = hyp_iu_unpack_conn(ud);
        int res = cqe->res;

        switch (op) {
        case HYP_IU_OP_ACCEPT: {
            if (res < 0) {
                if (res == -ENOBUFS || res == -EAGAIN) {
                    /* Multishot was disarmed by the kernel — re-arm. */
                    (void)hyp_iu_submit_accept(L);
                    break;
                }
                if (res == -ECANCELED || res == -EBADF || res == -EINVAL) {
                    /* Listener closed — graceful exit. */
                    listener_closed = 1;
                    break;
                }
                /* Other accept errors — re-arm and keep going. The
                 * 2.12-C path treated ECONNABORTED, EINTR, etc. as
                 * transient too. */
                (void)hyp_iu_submit_accept(L);
                break;
            }
            /* Successful accept: res is the new fd. */
            int cfd = res;
            if (L->inflight >= L->max_inflight) {
                /* Backpressure: shed the connection rather than
                 * unbounded heap growth. The kernel keeps queueing
                 * incoming SYNs in its accept queue; we'll resume
                 * draining once headroom frees up. */
                close(cfd);
                break;
            }
            pc_internal_apply_tcp_nodelay(cfd);
            hyp_iu_conn_t *nc = hyp_iu_conn_new(cfd);
            if (nc == NULL) {
                close(cfd);
                break;
            }
            L->inflight++;
            L->accepts++;
            if (hyp_iu_submit_recv(L, nc) < 0) {
                /* SQ full — close. */
                hyp_iu_submit_close(L, nc);
            }
            /* Multishot ACCEPT: kernel keeps it armed unless
             * IORING_CQE_F_MORE clears. If MORE is missing, re-arm. */
            if (!(cqe->flags & IORING_CQE_F_MORE)) {
                (void)hyp_iu_submit_accept(L);
            }
            break;
        }

        case HYP_IU_OP_RECV: {
            if (c == NULL) break;
            if (res <= 0) {
                /* res == 0 -> peer closed cleanly. res < 0 -> error
                 * (-ECONNRESET, -EPIPE, etc.). Either way we close. */
                hyp_iu_submit_close(L, c);
                break;
            }
            c->roff += (size_t)res;
            (void)hyp_iu_dispatch_request(L, c);
            break;
        }

        case HYP_IU_OP_WRITE: {
            if (c == NULL) break;
            if (res <= 0) {
                /* Write failed (peer gone, EPIPE). Close. */
                free(c->wbuf); c->wbuf = NULL;
                hyp_iu_submit_close(L, c);
                break;
            }
            c->wsent += (size_t)res;
            if (c->wsent < c->wlen) {
                /* Short write — re-arm. Rare on loopback, common on
                 * congested links. */
                if (hyp_iu_submit_write(L, c) < 0) {
                    free(c->wbuf); c->wbuf = NULL;
                    hyp_iu_submit_close(L, c);
                }
                break;
            }
            /* Full response written. Lifecycle hook fires here so
             * observers see a finished request. */
            L->served++;
            if (pc_internal_lifecycle_active()) {
                hyp_iu_hook_args_t args = {
                    .method = c->rbuf + c->method_off, .mlen = c->method_len,
                    .path   = c->rbuf + c->path_off,   .plen = c->path_len
                };
                rb_thread_call_with_gvl(hyp_iu_fire_lifecycle_with_gvl, &args);
            }
            free(c->wbuf); c->wbuf = NULL;
            c->wlen = 0; c->wsent = 0;

            if (!c->keep_alive || L->stopping) {
                hyp_iu_submit_close(L, c);
                break;
            }
            /* Keep-alive: reset for the next request on this fd.
             * The previous request occupied bytes [0..eoh) in rbuf;
             * any pipelined bytes after that boundary aren't carried
             * across today (we re-RECV from offset 0). Clearing is
             * cheap and correct — pipelining is a 2.13 follow-up. */
            c->roff = 0;
            c->method_off = c->method_len = 0;
            c->path_off = c->path_len = 0;
            if (hyp_iu_submit_recv(L, c) < 0) {
                hyp_iu_submit_close(L, c);
            }
            break;
        }

        case HYP_IU_OP_CLOSE: {
            (void)res; /* close errors are advisory; nothing to do */
            if (c != NULL) {
                hyp_iu_conn_free(c);
            }
            L->inflight--;
            L->closes++;
            break;
        }

        default:
            /* Should not happen — defensive no-op. */
            break;
        }
    }
    if (processed > 0) {
        io_uring_cq_advance(&L->ring, processed);
    }
    return listener_closed;
}

/* No-GVL inner loop. Runs until the listener closes, the stop flag
 * fires, or an unrecoverable error happens. */
typedef struct {
    hyp_iu_loop_t *L;
    int            err;
    /* 1 if the listener closed gracefully; 0 if an error tore us out. */
    int            graceful;
} hyp_iu_run_args_t;

static void *hyp_iu_run_blocking(void *raw) {
    hyp_iu_run_args_t *a = (hyp_iu_run_args_t *)raw;
    hyp_iu_loop_t *L = a->L;
    a->err = 0;
    a->graceful = 0;

    /* Initial ACCEPT submission. */
    if (hyp_iu_submit_accept(L) < 0) {
        a->err = ENOMEM;
        return NULL;
    }

    for (;;) {
        if (pc_internal_stop_requested()) {
            L->stopping = 1;
        }

        int ret = io_uring_submit_and_wait(&L->ring, 1);
        if (ret < 0) {
            if (ret == -EINTR) {
                continue;
            }
            if (L->stopping && L->inflight == 0) {
                a->graceful = 1;
                return NULL;
            }
            a->err = -ret;
            return NULL;
        }

        int listener_closed = hyp_iu_drain_cqes(L);
        if (listener_closed) {
            L->stopping = 1;
        }
        if (L->stopping && L->inflight == 0) {
            a->graceful = 1;
            return NULL;
        }
    }
}

/* Public Ruby surface: PageCache.run_static_io_uring_loop(listen_fd) -> Integer | :crashed | :unavailable */
static VALUE rb_pc_run_static_io_uring_loop(VALUE self, VALUE rb_listen_fd) {
    (void)self;
    int listen_fd = NUM2INT(rb_listen_fd);
    if (listen_fd < 0) {
        rb_raise(rb_eArgError, "listen_fd must be >= 0");
    }

    /* Clear O_NONBLOCK on the listener — io_uring drives accept itself
     * and we want the kernel to park us in the ring rather than spin
     * on EAGAIN. The 2.12-C path does the same trick on its accept(2)
     * fd. */
    int flags = fcntl(listen_fd, F_GETFL, 0);
    if (flags >= 0 && (flags & O_NONBLOCK)) {
        (void)fcntl(listen_fd, F_SETFL, flags & ~O_NONBLOCK);
    }

    hyp_iu_loop_t L;
    memset(&L, 0, sizeof(L));
    L.listen_fd    = listen_fd;
    L.max_inflight = HYP_IU_DEFAULT_MAX_INFLIGHT;

    /* Probe at boot: io_uring_queue_init returns 0 on success or a
     * negative errno on failure (seccomp / kernel-too-old / out-of-mem).
     * The Ruby caller treats `:unavailable` as "fall through to the
     * 2.12-C accept4 path"; the operator sees nothing scary in the
     * boot log unless they explicitly set HYPERION_IO_URING_ACCEPT=1
     * AND the probe failed (caller is responsible for warning then). */
    int rc = io_uring_queue_init(HYP_IU_DEFAULT_DEPTH, &L.ring, 0);
    if (rc < 0) {
        return hyp_iu_sym_unavailable;
    }

    hyp_iu_run_args_t a;
    a.L = &L;
    a.err = 0;
    a.graceful = 0;
    rb_thread_call_without_gvl(hyp_iu_run_blocking, &a, RUBY_UBF_IO, NULL);

    /* Best-effort drain: any conn structs we still hold need their
     * fds closed and memory freed. The CLOSE submissions normally
     * handle this, but a torn-down ring (graceful or not) means
     * pending SQEs never completed. We don't have a per-conn list,
     * so we lean on the kernel — io_uring_queue_exit will cancel
     * pending SQEs. Memory leak surface here is bounded by
     * `L.inflight`; in practice graceful shutdown drains it to 0
     * before exit. The non-graceful path leaks at most
     * `max_inflight * sizeof(hyp_iu_conn_t + rbuf)` once per worker
     * lifetime — acceptable for an emergency-tear-down path. */
    io_uring_queue_exit(&L.ring);

    if (!a.graceful && a.err != 0) {
        return hyp_iu_sym_crashed;
    }
    return LONG2NUM(L.served);
}

#else  /* not __linux__ or no HAVE_LIBURING */

static VALUE rb_pc_run_static_io_uring_loop(VALUE self, VALUE rb_listen_fd) {
    (void)self;
    (void)rb_listen_fd;
    return hyp_iu_sym_unavailable;
}

#endif /* __linux__ && HAVE_LIBURING */

/* Whether the C ext was built WITH liburing support. The Ruby side
 * uses this in `ConnectionLoop#io_uring_eligible?` to short-circuit
 * the env-var check — no point reading HYPERION_IO_URING_ACCEPT on a
 * build that can't honour it. */
static VALUE rb_pc_io_uring_loop_compiled_p(VALUE self) {
    (void)self;
#if defined(__linux__) && defined(HAVE_LIBURING)
    return Qtrue;
#else
    return Qfalse;
#endif
}

void Init_hyperion_io_uring_loop(VALUE mPageCache) {
    hyp_iu_sym_unavailable = ID2SYM(rb_intern("unavailable"));
    hyp_iu_sym_crashed     = ID2SYM(rb_intern("crashed"));
    rb_gc_register_mark_object(hyp_iu_sym_unavailable);
    rb_gc_register_mark_object(hyp_iu_sym_crashed);

    rb_define_singleton_method(mPageCache, "run_static_io_uring_loop",
                               rb_pc_run_static_io_uring_loop, 1);
    rb_define_singleton_method(mPageCache, "io_uring_loop_compiled?",
                               rb_pc_io_uring_loop_compiled_p, 0);
}
