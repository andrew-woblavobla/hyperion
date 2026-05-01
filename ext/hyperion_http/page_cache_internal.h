/* ----------------------------------------------------------------------
 * page_cache_internal.h — internal C-ext sharing surface.
 *
 * 2.12-D — exposes the request-parsing + lookup + write helpers built by
 * `page_cache.c`'s C accept loop so the io_uring sibling
 * (`io_uring_loop.c`) can reuse them rather than copy-pasting. The
 * helpers stay `static` inside `page_cache.c` and the symbols below are
 * thin extern wrappers — one indirection per call, but the io_uring
 * loop calls them at most once per request, so the cost is negligible
 * (single-direct-call jump) compared to the syscall savings the loop
 * delivers.
 *
 * NOT public surface. NOT installed in any include path. The header
 * lives next to the .c files and is included only by the in-tree C
 * sources.
 * ---------------------------------------------------------------------- */
#ifndef HYP_PAGE_CACHE_INTERNAL_H
#define HYP_PAGE_CACHE_INTERNAL_H

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Method classification (mirrors `hyp_pc_method_t` in page_cache.c). The
 * io_uring loop uses this via `pc_internal_classify_method` to decide
 * how much of the cached response to write (HEAD = headers only, GET =
 * full response). */
typedef enum {
    PC_INTERNAL_METHOD_GET   = 0,
    PC_INTERNAL_METHOD_HEAD  = 1,
    PC_INTERNAL_METHOD_OTHER = 2
} pc_internal_method_t;

/* End-of-headers scanner. Returns the byte offset PAST the trailing
 * CRLFCRLF, or -1 if not found. */
long pc_internal_find_eoh(const char *buf, size_t len);

/* Request-line parser. On success fills *m_off, *m_len, *p_off, *p_len
 * with offsets/lengths of METHOD and PATH inside `buf`, and returns the
 * length of the request line including the trailing CRLF. Returns -1
 * on malformed input or non-HTTP/1.1 versions (HTTP/1.0 differs in
 * keep-alive defaults; the caller must hand it off to Ruby). */
long pc_internal_parse_request_line(const char *buf, size_t len,
                                    size_t *m_off, size_t *m_len,
                                    size_t *p_off, size_t *p_len);

/* Header-block scanner. `start` and `end` bracket the headers section
 * (between request-line end and the closing CRLFCRLF). Reports:
 *   *connection_close — Connection: close seen
 *   *has_body         — non-zero Content-Length OR Transfer-Encoding
 *   *upgrade_seen     — Upgrade or HTTP2-Settings seen
 * Returns 0 on success, -1 on malformed framing. */
int pc_internal_scan_headers(const char *buf, size_t start, size_t end,
                             int *connection_close, int *has_body,
                             int *upgrade_seen);

/* Method classifier. Returns GET / HEAD / OTHER. */
pc_internal_method_t pc_internal_classify_method(const char *m, size_t len);

/* Snapshot the response bytes for `(path, kind)` into a freshly malloc'd
 * buffer. On hit: returns the malloc'd buffer (caller must `free()` it)
 * and writes the byte length into *out_len. On miss: returns NULL and
 * sets *out_len = 0. The buffer is whatever the page cache's lookup
 * picks given the recheck/staleness rules; the io_uring loop writes it
 * verbatim. Takes the C-side cache lock briefly; releases it before
 * returning. Returns NULL on OOM as well — the caller treats both as
 * "couldn't serve from C, hand off to Ruby". */
char *pc_internal_snapshot_response(const char *path, size_t path_len,
                                    pc_internal_method_t kind,
                                    size_t *out_len);

/* Apply TCP_NODELAY to an accepted fd (best-effort; failures swallowed). */
void pc_internal_apply_tcp_nodelay(int fd);

/* Lifecycle hook fire wrapper. The io_uring loop calls this AFTER the
 * write completion arrives so observers see a finished request. The
 * C-side gate (`lifecycle_active`) is checked inside; the wrapper is
 * a no-op when no callback is registered or the gate is off. Must be
 * called under the GVL. */
void pc_internal_fire_lifecycle(const char *method, size_t mlen,
                                const char *path, size_t plen);

/* Whether the lifecycle gate is currently on. The io_uring loop reads
 * this BEFORE re-acquiring the GVL — when it's off, the loop skips
 * the rb_thread_call_with_gvl round-trip entirely. */
int pc_internal_lifecycle_active(void);

/* Handoff wrapper — invokes the registered Ruby callback with
 * (fd, partial_buffer_or_nil). Must be called under the GVL. Closes
 * the fd locally if no callback is registered or if the callback
 * raised. */
void pc_internal_handoff(int client_fd, const char *partial, size_t partial_len);

/* Read the stop flag flipped by `PageCache.stop_accept_loop`. Both the
 * 2.12-C accept4 loop AND the 2.12-D io_uring loop honour it as a
 * graceful-shutdown signal. */
int pc_internal_stop_requested(void);

/* Reset the stop flag to 0. Called by the loop entry points
 * (`run_static_accept_loop`, `run_static_io_uring_loop`) so a previous
 * invocation's `stop_accept_loop` doesn't immediately tear down a
 * fresh loop. Specs hammer this path between examples — the 2.12-C
 * loop resets inline; the io_uring sibling needs the same surface. */
void pc_internal_reset_stop(void);

/* The 64 KiB header-cap shared with `page_cache.c`. Re-declared here
 * so io_uring_loop.c doesn't need to mirror the magic number. */
#ifndef PC_INTERNAL_MAX_HEADER_BYTES
#define PC_INTERNAL_MAX_HEADER_BYTES 65536
#endif

#ifdef __cplusplus
}
#endif

#endif /* HYP_PAGE_CACHE_INTERNAL_H */
