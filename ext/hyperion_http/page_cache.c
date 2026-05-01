/* ----------------------------------------------------------------------
 * Hyperion::Http::PageCache — pre-built static-response cache.
 *
 * Borrowed from agoo's `agooPage` design (ext/agoo/page.c). For each
 * cached static asset we hold ONE contiguous heap buffer that already
 * contains the entire HTTP/1.1 response: status line + Content-Type +
 * Content-Length + CRLF + body bytes.
 *
 * On the hot path (`PageCache.write_to(socket, path)`):
 *   1. Hash-lookup the path in an open-addressed bucket table
 *      (PAGE_BUCKET_SIZE = 1024, max key length MAX_KEY_LEN = 1024 —
 *      mirrors agoo).
 *   2. If `last_check` is older than `recheck_seconds` AND the page is
 *      not marked immutable, stat() the file. If mtime changed, rebuild
 *      the response buffer; otherwise update `last_check` only.
 *   3. write(socket_fd, response_buf, response_len) — ONE syscall.
 *
 * Per-request cost on a hit:
 *   * 0 file reads.
 *   * 0 mime lookups (mime is baked into response_buf).
 *   * 0 header building (status + Content-Type + Content-Length pre-built).
 *   * 0 Rack env construction (caller bypasses the Rack call entirely).
 *   * 0 Ruby allocations on the C path itself (we accept Integer fds via
 *     extract_fd, so no Ruby Strings are allocated; the return value is a
 *     small Integer or interned Symbol).
 *   * 1 socket write syscall in the common case (buffer fits in TCP send
 *     buffer; for the 1 KB row this always holds).
 *
 * Public Ruby surface (singleton methods on Hyperion::Http::PageCache):
 *
 *   PageCache.fetch(path) -> :ok | :stale | :missing
 *     Returns whether `path` is currently in the cache (after honoring the
 *     mtime recheck). `:ok` — cached and fresh. `:stale` — was cached but
 *     re-stat showed mtime change and we rebuilt. `:missing` — not in cache
 *     (caller should call `cache_file` first).
 *
 *   PageCache.cache_file(path) -> Integer | :missing
 *     Read `path` from disk, build the HTTP response buffer, store it under
 *     the canonical path key. Returns the body bytes count, or `:missing`
 *     when the file doesn't exist / can't be read.
 *
 *   PageCache.preload(dir) -> Integer
 *     Walks `dir` recursively, calls cache_file for every regular file.
 *     Returns the count of files added.
 *
 *   PageCache.write_to(socket_io, path) -> Integer | :missing
 *     Hot path. Looks up `path`, honours the mtime recheck (or skips it
 *     when the page is immutable), and writes the pre-built response to
 *     the socket. Returns bytes written, or `:missing` when not cached.
 *
 *   PageCache.set_immutable(path, bool) -> bool
 *     Mark a specific path as immutable: subsequent `write_to` calls skip
 *     the mtime stat entirely. Use for assets fingerprinted by hash.
 *
 *   PageCache.size -> Integer
 *     Number of pages currently cached.
 *
 *   PageCache.clear -> nil
 *     Drop every entry. Used by specs and on graceful reload.
 *
 *   PageCache.recheck_seconds -> Float
 *   PageCache.recheck_seconds=(seconds)
 *     Per-process tunable, default 5.0s, mirrors agoo's PAGE_RECHECK_TIME.
 *
 *   PageCache.response_bytes(path) -> String | nil
 *     Specs-only helper: returns a frozen copy of the pre-built response
 *     buffer so tests can assert exact wire bytes.
 *
 * Concurrency
 * -----------
 * The cache is per-process. Hyperion's worker model gives each worker its
 * own page cache — there is no IPC / shared memory cost.  The hash table
 * itself is guarded by a single Mutex (rb_mutex_*) on the structural ops
 * (insert, evict, clear); the hot read path takes the Mutex briefly to
 * fetch the page pointer, then runs the kernel `write()` *outside* any
 * Ruby lock (under rb_thread_call_without_gvl) so other fibers / threads
 * can run while the socket buffer drains.
 *
 * The C lock is a plain pthread mutex because Ruby's rb_mutex_lock can't
 * be acquired from inside `rb_thread_call_without_gvl` (no GVL, no Ruby
 * VM access).  We acquire the pthread mutex briefly to read the slot,
 * make a stack-local snapshot of the response_buf pointer + len, release
 * the mutex, then issue the write.  Eviction grabs the same pthread
 * mutex; readers see a consistent snapshot or a `:missing` result if
 * eviction won the race.
 *
 * 2.10-C — initial drop.
 * ---------------------------------------------------------------------- */

#include <ruby.h>
#include <ruby/thread.h>
#include <ruby/io.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <dirent.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

/* Internal sharing surface — extern wrappers around the static helpers
 * below, exposed to the 2.12-D io_uring sibling translation unit
 * (`io_uring_loop.c`). The wrappers are defined in this file (next to
 * the static helpers they wrap) and declared in `page_cache_internal.h`. */
#include "page_cache_internal.h"

/* Shared identifiers / refs.  parser.c and sendfile.c each register their
 * own copies of Hyperion / Hyperion::Http (lazy-define if missing); we
 * follow the same pattern so init order doesn't matter. */
static VALUE rb_mHyperion_pc;
static VALUE rb_mHyperionHttp_pc;
static VALUE rb_mHyperionHttpPageCache;

static ID id_fileno_pc;
static ID id_to_io_pc;

static VALUE sym_ok_pc;
static VALUE sym_stale_pc;
static VALUE sym_missing_pc;
/* 2.10-F — sentinel returned by `serve_request` when the path/method
 * tuple isn't a hit. Distinct from `:missing` so the Ruby caller can
 * tell "not in cache" (Rack-fallback) apart from "in cache but not
 * cached for this method" (also Rack-fallback, same outcome — but the
 * symbol is `:miss` so logs / metrics can tell them apart). */
static VALUE sym_miss_pc;

#define HYP_PC_BUCKET_SIZE 1024u
#define HYP_PC_BUCKET_MASK (HYP_PC_BUCKET_SIZE - 1u)
#define HYP_PC_MAX_KEY_LEN 1024
#define HYP_PC_DEFAULT_RECHECK_SECONDS 5.0
/* Auto-engage threshold from Adapter::Rack (mirrored on the Ruby side as
 * well, but exposed here so specs can read the C constant). */
#define HYP_PC_AUTO_THRESHOLD (64 * 1024)

typedef struct hyp_page_s {
    char    *path;          /* canonical filesystem path; heap-owned */
    size_t   path_len;
    char    *response_buf;  /* pre-built HTTP/1.1 response, heap-owned */
    size_t   response_len;
    size_t   body_len;      /* informational; body bytes only */
    size_t   headers_len;   /* headers-only span (for HEAD writes) =
                             * response_len - body_len for cache_file
                             * entries; explicit for register_prebuilt
                             * entries that may carry a chunked body. */
    time_t   mtime;         /* last-known file mtime; 0 for register_prebuilt */
    double   last_check;    /* dtime() of last stat */
    int      immutable;     /* non-zero → never re-stat */
    int      prebuilt;      /* 1 = registered via register_prebuilt
                             * (no on-disk file backing — never re-stat,
                             * never invalidate on missing file). */
    char    *content_type;  /* heap-owned, picked at insert time */
} hyp_page_t;

typedef struct hyp_page_slot_s {
    struct hyp_page_slot_s *next;
    uint64_t                hash;
    hyp_page_t             *page;
} hyp_page_slot_t;

static hyp_page_slot_t *hyp_pc_buckets[HYP_PC_BUCKET_SIZE];
static size_t           hyp_pc_count;
static double           hyp_pc_recheck_seconds = HYP_PC_DEFAULT_RECHECK_SECONDS;
static pthread_mutex_t  hyp_pc_lock = PTHREAD_MUTEX_INITIALIZER;

/* ============================================================
 * Mime suffix → Content-Type. Borrowed wholesale from agoo's
 * mime_map[] in ext/agoo/page.c.
 * ============================================================ */
typedef struct {
    const char *suffix;
    const char *type;
} hyp_pc_mime_t;

static const hyp_pc_mime_t hyp_pc_mime_map[] = {
    { "asc",  "text/plain" },
    { "avi",  "video/x-msvideo" },
    { "bin",  "application/octet-stream" },
    { "bmp",  "image/bmp" },
    { "css",  "text/css" },
    { "csv",  "text/csv" },
    { "eot",  "application/vnd.ms-fontobject" },
    { "gif",  "image/gif" },
    { "gz",   "application/gzip" },
    { "htm",  "text/html" },
    { "html", "text/html" },
    { "ico",  "image/x-icon" },
    { "jpeg", "image/jpeg" },
    { "jpg",  "image/jpeg" },
    { "js",   "application/javascript" },
    { "json", "application/json" },
    { "map",  "application/json" },
    { "mp3",  "audio/mpeg" },
    { "mp4",  "video/mp4" },
    { "ogg",  "audio/ogg" },
    { "pdf",  "application/pdf" },
    { "png",  "image/png" },
    { "rss",  "application/rss+xml" },
    { "svg",  "image/svg+xml" },
    { "tif",  "image/tiff" },
    { "tiff", "image/tiff" },
    { "ttf",  "application/font-sfnt" },
    { "txt",  "text/plain; charset=utf-8" },
    { "wasm", "application/wasm" },
    { "webm", "video/webm" },
    { "webp", "image/webp" },
    { "woff", "application/font-woff" },
    { "woff2", "font/woff2" },
    { "xml",  "application/xml" },
    { "yml",  "application/yaml" },
    { "yaml", "application/yaml" },
    { "zip",  "application/zip" },
    { NULL, NULL }
};

static const char hyp_pc_default_ct[] = "application/octet-stream";

/* Pick a content-type by file extension. Returns a pointer into the
 * static mime map; never frees. */
static const char *hyp_pc_lookup_mime(const char *path) {
    if (path == NULL) {
        return hyp_pc_default_ct;
    }
    const char *dot = strrchr(path, '.');
    if (dot == NULL || dot[1] == '\0') {
        return hyp_pc_default_ct;
    }
    /* Skip past the '.' to the suffix proper. */
    const char *suffix = dot + 1;
    for (const hyp_pc_mime_t *m = hyp_pc_mime_map; m->suffix != NULL; m++) {
        if (strcasecmp(suffix, m->suffix) == 0) {
            return m->type;
        }
    }
    return hyp_pc_default_ct;
}

/* Wall-clock seconds with sub-second precision. Mirrors agoo's dtime(). */
static double hyp_pc_now(void) {
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        return 0.0;
    }
    return (double)tv.tv_sec + (double)tv.tv_usec / 1.0e6;
}

/* FNV-1a 64-bit. Stable, cheap, branchless on the hot path; not a
 * cryptographic hash but the cache only stores trusted operator paths. */
static uint64_t hyp_pc_hash(const char *key, size_t len) {
    uint64_t h = 1469598103934665603ULL; /* FNV offset basis */
    for (size_t i = 0; i < len; i++) {
        h ^= (uint64_t)(unsigned char)key[i];
        h *= 1099511628211ULL; /* FNV prime */
    }
    return h;
}

static void hyp_page_destroy(hyp_page_t *p) {
    if (p == NULL) {
        return;
    }
    free(p->path);
    free(p->response_buf);
    free(p->content_type);
    free(p);
}

/* Build the pre-baked HTTP response buffer for `body` of `body_len` bytes
 * with the given content-type. Allocates via malloc; caller owns the
 * buffer (free() on eviction).
 *
 * Wire format:
 *   HTTP/1.1 200 OK\r\n
 *   Content-Type: <content_type>\r\n
 *   Content-Length: <body_len>\r\n
 *   \r\n
 *   <body bytes>
 */
static char *hyp_pc_build_response(const char *body, size_t body_len,
                                   const char *content_type,
                                   size_t *out_response_len) {
    /* Worst-case header span: status (17) + CT prefix (14) + CT value
     * (≤256) + CRLF (2) + CL prefix (16) + CL value (≤21 for 64-bit) +
     * CRLF (2) + blank line (2). Round to 512 + body_len for the malloc
     * call. */
    size_t header_max = 512 + strlen(content_type);
    size_t buf_cap    = header_max + body_len;
    char  *buf        = (char *)malloc(buf_cap);
    if (buf == NULL) {
        return NULL;
    }

    int header_len = snprintf(
        buf, header_max,
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "\r\n",
        content_type, body_len);

    if (header_len < 0 || (size_t)header_len >= header_max) {
        free(buf);
        return NULL;
    }

    if (body_len > 0 && body != NULL) {
        memcpy(buf + header_len, body, body_len);
    }
    *out_response_len = (size_t)header_len + body_len;
    return buf;
}

/* Read `path` into a newly-allocated body buffer. *out_len receives the
 * size; *out_mtime receives the file mtime. Returns the buffer pointer
 * (caller frees) or NULL on error. */
static char *hyp_pc_read_file(const char *path, size_t *out_len, time_t *out_mtime) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return NULL;
    }
    size_t len = (size_t)st.st_size;
    char  *buf = NULL;
    if (len == 0) {
        /* Allocate a 1-byte sentinel so callers that expect non-NULL
         * for "successfully read" still get a valid pointer. We never
         * read into it. */
        buf = (char *)malloc(1);
        if (buf == NULL) {
            close(fd);
            return NULL;
        }
    } else {
        buf = (char *)malloc(len);
        if (buf == NULL) {
            close(fd);
            return NULL;
        }
        size_t total = 0;
        while (total < len) {
            ssize_t n = read(fd, buf + total, len - total);
            if (n > 0) {
                total += (size_t)n;
                continue;
            }
            if (n < 0 && errno == EINTR) {
                continue;
            }
            free(buf);
            close(fd);
            return NULL;
        }
    }
    close(fd);
    *out_len   = len;
    *out_mtime = st.st_mtime;
    return buf;
}

/* Find an existing slot for `path`; returns NULL when not present.
 * Caller must hold hyp_pc_lock. */
static hyp_page_slot_t *hyp_pc_find_slot(const char *path, size_t path_len, uint64_t h) {
    hyp_page_slot_t *slot = hyp_pc_buckets[h & HYP_PC_BUCKET_MASK];
    while (slot != NULL) {
        if (slot->hash == h
            && slot->page->path_len == path_len
            && memcmp(slot->page->path, path, path_len) == 0) {
            return slot;
        }
        slot = slot->next;
    }
    return NULL;
}

/* Insert a page under `path`. Replaces any existing entry (which is
 * destroyed in place). Caller must hold hyp_pc_lock. */
static void hyp_pc_insert_locked(hyp_page_t *page, uint64_t h) {
    size_t bucket_idx = (size_t)(h & HYP_PC_BUCKET_MASK);
    hyp_page_slot_t *slot = hyp_pc_buckets[bucket_idx];
    while (slot != NULL) {
        if (slot->hash == h
            && slot->page->path_len == page->path_len
            && memcmp(slot->page->path, page->path, page->path_len) == 0) {
            /* Overwrite — destroy old body, swap in new. Counter is
             * unchanged because we replaced an existing entry. */
            hyp_page_destroy(slot->page);
            slot->page = page;
            return;
        }
        slot = slot->next;
    }
    slot = (hyp_page_slot_t *)malloc(sizeof(*slot));
    if (slot == NULL) {
        hyp_page_destroy(page);
        return;
    }
    slot->next = hyp_pc_buckets[bucket_idx];
    slot->hash = h;
    slot->page = page;
    hyp_pc_buckets[bucket_idx] = slot;
    hyp_pc_count++;
}

/* Build a hyp_page_t struct from raw inputs. Returns NULL on alloc fail. */
static hyp_page_t *hyp_pc_alloc_page(const char *path, size_t path_len,
                                     const char *body, size_t body_len,
                                     time_t mtime) {
    hyp_page_t *p = (hyp_page_t *)calloc(1, sizeof(*p));
    if (p == NULL) {
        return NULL;
    }
    p->path = (char *)malloc(path_len + 1);
    if (p->path == NULL) {
        free(p);
        return NULL;
    }
    memcpy(p->path, path, path_len);
    p->path[path_len] = '\0';
    p->path_len = path_len;

    const char *ct = hyp_pc_lookup_mime(path);
    p->content_type = strdup(ct);
    if (p->content_type == NULL) {
        free(p->path);
        free(p);
        return NULL;
    }
    size_t resp_len = 0;
    p->response_buf = hyp_pc_build_response(body, body_len, ct, &resp_len);
    if (p->response_buf == NULL) {
        free(p->content_type);
        free(p->path);
        free(p);
        return NULL;
    }
    p->response_len = resp_len;
    p->body_len     = body_len;
    p->headers_len  = (resp_len >= body_len) ? (resp_len - body_len) : resp_len;
    p->mtime        = mtime;
    p->last_check   = hyp_pc_now();
    p->immutable    = 0;
    p->prebuilt     = 0;
    return p;
}

/* PageCache.cache_file(path) — read the file, build the response, insert.
 * Returns the body byte count on success, or :missing on read failure. */
static VALUE rb_pc_cache_file(VALUE self, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return sym_missing_pc;
    }

    size_t body_len = 0;
    time_t mtime    = 0;
    char  *body     = hyp_pc_read_file(path, &body_len, &mtime);
    if (body == NULL) {
        return sym_missing_pc;
    }

    hyp_page_t *page = hyp_pc_alloc_page(path, path_len, body, body_len, mtime);
    free(body);
    if (page == NULL) {
        return sym_missing_pc;
    }

    uint64_t h = hyp_pc_hash(path, path_len);
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_pc_insert_locked(page, h);
    pthread_mutex_unlock(&hyp_pc_lock);

    return SIZET2NUM(body_len);
}

/* Internal: find page + honor mtime recheck. Returns the slot pointer
 * (still under the lock) or NULL when missing or rebuild failed. The
 * caller is responsible for releasing the lock and snapshotting whatever
 * fields it needs.
 *
 * Sets *was_stale to 1 if the file's mtime changed and we rebuilt the
 * response; 0 otherwise. */
static hyp_page_slot_t *hyp_pc_lookup_locked(const char *path, size_t path_len,
                                             int *was_stale) {
    uint64_t h = hyp_pc_hash(path, path_len);
    hyp_page_slot_t *slot = hyp_pc_find_slot(path, path_len, h);
    if (slot == NULL) {
        return NULL;
    }
    hyp_page_t *p = slot->page;
    if (p->immutable || p->prebuilt) {
        if (was_stale) *was_stale = 0;
        return slot;
    }
    double now = hyp_pc_now();
    if (now - p->last_check < hyp_pc_recheck_seconds) {
        if (was_stale) *was_stale = 0;
        return slot;
    }
    /* Time to re-stat. */
    struct stat st;
    if (stat(p->path, &st) != 0 || !S_ISREG(st.st_mode)) {
        /* File vanished underneath us — drop the entry. */
        hyp_page_slot_t **head = &hyp_pc_buckets[h & HYP_PC_BUCKET_MASK];
        while (*head != NULL) {
            if (*head == slot) {
                *head = slot->next;
                hyp_page_destroy(slot->page);
                free(slot);
                hyp_pc_count--;
                break;
            }
            head = &(*head)->next;
        }
        return NULL;
    }
    if (st.st_mtime == p->mtime) {
        p->last_check = now;
        if (was_stale) *was_stale = 0;
        return slot;
    }
    /* mtime changed — rebuild. */
    size_t new_body_len = 0;
    time_t new_mtime    = 0;
    char  *new_body     = hyp_pc_read_file(p->path, &new_body_len, &new_mtime);
    if (new_body == NULL) {
        return NULL;
    }
    size_t new_resp_len = 0;
    char  *new_resp = hyp_pc_build_response(new_body, new_body_len,
                                            p->content_type, &new_resp_len);
    free(new_body);
    if (new_resp == NULL) {
        return NULL;
    }
    free(p->response_buf);
    p->response_buf = new_resp;
    p->response_len = new_resp_len;
    p->body_len     = new_body_len;
    p->headers_len  = (new_resp_len >= new_body_len) ? (new_resp_len - new_body_len) : new_resp_len;
    p->mtime        = new_mtime;
    p->last_check   = now;
    if (was_stale) *was_stale = 1;
    return slot;
}

/* PageCache.fetch(path) -> :ok | :stale | :missing */
static VALUE rb_pc_fetch(VALUE self, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return sym_missing_pc;
    }

    int was_stale = 0;
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_page_slot_t *slot = hyp_pc_lookup_locked(path, path_len, &was_stale);
    pthread_mutex_unlock(&hyp_pc_lock);

    if (slot == NULL) {
        return sym_missing_pc;
    }
    return was_stale ? sym_stale_pc : sym_ok_pc;
}

/* Extract a kernel fd from a Ruby IO-ish object. Same contract as the
 * helper in sendfile.c, copy-pasted intentionally so this translation
 * unit doesn't depend on sendfile.c's internals. */
static int hyp_pc_extract_fd(VALUE obj, const char *role) {
    if (RB_TYPE_P(obj, T_FIXNUM) || RB_TYPE_P(obj, T_BIGNUM)) {
        return NUM2INT(obj);
    }
    if (RB_TYPE_P(obj, T_FILE)) {
        return rb_io_descriptor(obj);
    }
    if (rb_respond_to(obj, id_to_io_pc)) {
        VALUE io = rb_funcall(obj, id_to_io_pc, 0);
        if (RB_TYPE_P(io, T_FILE)) {
            return rb_io_descriptor(io);
        }
        if (RB_TYPE_P(io, T_FIXNUM) || RB_TYPE_P(io, T_BIGNUM)) {
            return NUM2INT(io);
        }
    }
    if (rb_respond_to(obj, id_fileno_pc)) {
        VALUE fd = rb_funcall(obj, id_fileno_pc, 0);
        if (RB_TYPE_P(fd, T_FIXNUM) || RB_TYPE_P(fd, T_BIGNUM)) {
            return NUM2INT(fd);
        }
    }
    rb_raise(rb_eTypeError,
             "Hyperion::Http::PageCache.write_to: %s argument must be an IO, "
             "an Integer fd, or respond to #to_io / #fileno",
             role);
    return -1;
}

typedef struct {
    int      fd;
    const char *buf;
    size_t   len;
    ssize_t  total;
    int      err;
} hyp_pc_write_args_t;

/* Drains the entire response_buf to the socket. Runs without the GVL
 * (rb_thread_call_without_gvl). EAGAIN is handled inline with a bounded
 * select() poll; for the 1 KB / 8 KB row this almost never fires. */
static void *hyp_pc_write_blocking(void *raw) {
    hyp_pc_write_args_t *a = (hyp_pc_write_args_t *)raw;
    a->total = 0;
    a->err   = 0;

    int eagain_retries = 5;
    while ((size_t)a->total < a->len) {
        ssize_t w = write(a->fd, a->buf + a->total, a->len - (size_t)a->total);
        if (w > 0) {
            a->total += w;
            continue;
        }
        if (w < 0 && errno == EINTR) {
            continue;
        }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (eagain_retries-- <= 0) {
                a->err = EAGAIN;
                return NULL;
            }
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(a->fd, &wfds);
            struct timeval tv;
            tv.tv_sec  = 0;
            tv.tv_usec = 10000;
            (void)select(a->fd + 1, NULL, &wfds, NULL, &tv);
            continue;
        }
        if (w < 0) {
            a->err = errno;
            return NULL;
        }
        /* w == 0 — peer side gone. */
        a->err = EIO;
        return NULL;
    }
    return NULL;
}

/* PageCache.write_to(socket_io, path) -> Integer | :missing
 *
 * Lookup, then write the pre-built response.  Lookup grabs the C lock
 * briefly to snapshot (response_buf, response_len) onto the stack; the
 * actual write runs without the GVL and without any Ruby-level lock,
 * so other fibers / threads can run while the socket buffer drains. */
static VALUE rb_pc_write_to(VALUE self, VALUE socket_io, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return sym_missing_pc;
    }

    int fd = hyp_pc_extract_fd(socket_io, "socket_io");

    /* Snapshot the response under the lock, then release before we do
     * the kernel write — readers MUST NOT hold the C mutex across a
     * blocking syscall. We malloc a transient buffer rather than
     * referencing the slot's response_buf directly because eviction
     * could free that memory mid-write otherwise. */
    pthread_mutex_lock(&hyp_pc_lock);
    int was_stale = 0;
    hyp_page_slot_t *slot = hyp_pc_lookup_locked(path, path_len, &was_stale);
    if (slot == NULL) {
        pthread_mutex_unlock(&hyp_pc_lock);
        return sym_missing_pc;
    }
    size_t resp_len = slot->page->response_len;
    char  *snapshot = (char *)malloc(resp_len);
    if (snapshot == NULL) {
        pthread_mutex_unlock(&hyp_pc_lock);
        rb_raise(rb_eNoMemError, "Hyperion::Http::PageCache.write_to: "
                 "failed to snapshot response (%zu bytes)", resp_len);
    }
    memcpy(snapshot, slot->page->response_buf, resp_len);
    pthread_mutex_unlock(&hyp_pc_lock);

    hyp_pc_write_args_t args;
    args.fd    = fd;
    args.buf   = snapshot;
    args.len   = resp_len;
    args.total = 0;
    args.err   = 0;

    rb_thread_call_without_gvl(hyp_pc_write_blocking, &args, RUBY_UBF_IO, NULL);

    free(snapshot);

    if (args.err != 0 && args.total == 0) {
        errno = args.err;
        rb_sys_fail("Hyperion::Http::PageCache.write_to");
    }
    return SSIZET2NUM(args.total);
}

/* PageCache.register_prebuilt(path, response_bytes, body_len) -> Integer
 *
 * 2.10-F — register a fully prebuilt HTTP response under a route path
 * (e.g. `/health`).  Unlike `cache_file`, the entry has NO on-disk
 * backing — `serve_request` looks it up directly and writes the
 * stored bytes.  `body_len` tells `serve_request` where the body
 * starts inside `response_bytes` so HEAD requests can write the
 * headers-only prefix.
 *
 * `response_bytes.bytesize` MUST be >= `body_len`.  Returns the
 * stored response byte count on success.
 *
 * Used by `Hyperion::Server.handle_static` to fold the prebuilt
 * static-route response into the C fast path so the request hot
 * path is one hash lookup + one `write()` syscall, fully outside
 * Ruby method dispatch. */
static VALUE rb_pc_register_prebuilt(VALUE self, VALUE rb_path,
                                     VALUE rb_response, VALUE rb_body_len) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    Check_Type(rb_response, T_STRING);

    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        rb_raise(rb_eArgError, "Hyperion::Http::PageCache.register_prebuilt: "
                 "path empty or > %d bytes", HYP_PC_MAX_KEY_LEN);
    }
    const char *resp_buf = RSTRING_PTR(rb_response);
    size_t      resp_len = (size_t)RSTRING_LEN(rb_response);
    long        body_len_signed = NUM2LONG(rb_body_len);
    if (body_len_signed < 0) {
        rb_raise(rb_eArgError, "body_len must be >= 0");
    }
    size_t      body_len = (size_t)body_len_signed;
    if (body_len > resp_len) {
        rb_raise(rb_eArgError,
                 "body_len (%zu) must be <= response_bytes.bytesize (%zu)",
                 body_len, resp_len);
    }

    hyp_page_t *page = (hyp_page_t *)calloc(1, sizeof(*page));
    if (page == NULL) {
        rb_raise(rb_eNoMemError, "register_prebuilt: page alloc");
    }
    page->path = (char *)malloc(path_len + 1);
    if (page->path == NULL) {
        free(page);
        rb_raise(rb_eNoMemError, "register_prebuilt: path alloc");
    }
    memcpy(page->path, path, path_len);
    page->path[path_len] = '\0';
    page->path_len = path_len;

    /* For prebuilt entries we don't attempt mime sniffing — the
     * caller already baked Content-Type into the response.  Stash a
     * placeholder so response_bytes() / content_type() helpers stay
     * functional. */
    page->content_type = strdup("__prebuilt__");
    if (page->content_type == NULL) {
        free(page->path);
        free(page);
        rb_raise(rb_eNoMemError, "register_prebuilt: content_type alloc");
    }

    page->response_buf = (char *)malloc(resp_len);
    if (page->response_buf == NULL) {
        free(page->content_type);
        free(page->path);
        free(page);
        rb_raise(rb_eNoMemError, "register_prebuilt: response alloc (%zu bytes)",
                 resp_len);
    }
    memcpy(page->response_buf, resp_buf, resp_len);
    page->response_len = resp_len;
    page->body_len     = body_len;
    page->headers_len  = resp_len - body_len;
    page->mtime        = 0;
    page->last_check   = hyp_pc_now();
    page->immutable    = 1;
    page->prebuilt     = 1;

    uint64_t h = hyp_pc_hash(path, path_len);
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_pc_insert_locked(page, h);
    pthread_mutex_unlock(&hyp_pc_lock);

    return SIZET2NUM(resp_len);
}

/* 2.10-F — fast-path lookup-and-write.
 *
 * Method gate: only GET and HEAD are eligible.  Anything else returns
 * `:miss` so the Ruby caller falls through to its non-cache path.
 * Comparison is case-insensitive against ASCII bytes (the request
 * line method is parsed verbatim, so callers that already canonical-
 * cased their method gain a single fast path).
 *
 * Returns:
 *   * `[:ok, bytes_written]` — hit, response (or headers-only on HEAD)
 *     was written in full.
 *   * `:miss` — no match (path absent, method not GET/HEAD, or
 *     boundary-case empty/oversized path).
 *
 * Concurrency: the C lock is held just long enough to snapshot the
 * response bytes onto the heap; the actual `write()` runs without the
 * GVL via `rb_thread_call_without_gvl`. */
typedef enum {
    HYP_PC_METHOD_OTHER = 0,
    HYP_PC_METHOD_GET   = 1,
    HYP_PC_METHOD_HEAD  = 2
} hyp_pc_method_t;

static hyp_pc_method_t hyp_pc_classify_method(const char *m, size_t len) {
    if (len == 3 &&
        (m[0] == 'G' || m[0] == 'g') &&
        (m[1] == 'E' || m[1] == 'e') &&
        (m[2] == 'T' || m[2] == 't')) {
        return HYP_PC_METHOD_GET;
    }
    if (len == 4 &&
        (m[0] == 'H' || m[0] == 'h') &&
        (m[1] == 'E' || m[1] == 'e') &&
        (m[2] == 'A' || m[2] == 'a') &&
        (m[3] == 'D' || m[3] == 'd')) {
        return HYP_PC_METHOD_HEAD;
    }
    return HYP_PC_METHOD_OTHER;
}

static VALUE rb_pc_serve_request(VALUE self, VALUE socket_io,
                                 VALUE rb_method, VALUE rb_path) {
    (void)self;
    Check_Type(rb_method, T_STRING);
    Check_Type(rb_path,   T_STRING);

    const char *method   = RSTRING_PTR(rb_method);
    size_t      mlen     = (size_t)RSTRING_LEN(rb_method);
    hyp_pc_method_t kind = hyp_pc_classify_method(method, mlen);
    if (kind == HYP_PC_METHOD_OTHER) {
        return sym_miss_pc;
    }

    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return sym_miss_pc;
    }

    /* Resolve the fd up front — extract_fd may raise, and we want
     * the raise to happen BEFORE we acquire the C lock or allocate. */
    int fd = hyp_pc_extract_fd(socket_io, "socket_io");

    pthread_mutex_lock(&hyp_pc_lock);
    int was_stale = 0;
    hyp_page_slot_t *slot = hyp_pc_lookup_locked(path, path_len, &was_stale);
    if (slot == NULL) {
        pthread_mutex_unlock(&hyp_pc_lock);
        return sym_miss_pc;
    }
    /* HEAD writes only the headers prefix; GET writes the full
     * response.  Snapshot under the lock so a concurrent eviction
     * can't free the source buffer mid-write. */
    size_t write_len = (kind == HYP_PC_METHOD_HEAD)
                           ? slot->page->headers_len
                           : slot->page->response_len;
    char  *snapshot  = (char *)malloc(write_len);
    if (snapshot == NULL) {
        pthread_mutex_unlock(&hyp_pc_lock);
        rb_raise(rb_eNoMemError, "Hyperion::Http::PageCache.serve_request: "
                 "snapshot alloc (%zu bytes)", write_len);
    }
    memcpy(snapshot, slot->page->response_buf, write_len);
    pthread_mutex_unlock(&hyp_pc_lock);

    hyp_pc_write_args_t args;
    args.fd    = fd;
    args.buf   = snapshot;
    args.len   = write_len;
    args.total = 0;
    args.err   = 0;

    rb_thread_call_without_gvl(hyp_pc_write_blocking, &args, RUBY_UBF_IO, NULL);

    free(snapshot);

    if (args.err != 0 && args.total == 0) {
        errno = args.err;
        rb_sys_fail("Hyperion::Http::PageCache.serve_request");
    }

    /* Build the [:ok, bytes_written] return tuple.  Two-element
     * Array allocation is the only Ruby-level allocation on this
     * path (the integer auto-fixnums for any reasonable response
     * size). */
    VALUE result = rb_ary_new_capa(2);
    rb_ary_push(result, sym_ok_pc);
    rb_ary_push(result, SSIZET2NUM(args.total));
    return result;
}

/* PageCache.set_immutable(path, bool) -> bool */
static VALUE rb_pc_set_immutable(VALUE self, VALUE rb_path, VALUE rb_flag) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    int flag = RTEST(rb_flag) ? 1 : 0;
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return Qfalse;
    }
    uint64_t h = hyp_pc_hash(path, path_len);
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_page_slot_t *slot = hyp_pc_find_slot(path, path_len, h);
    if (slot != NULL) {
        slot->page->immutable = flag;
    }
    pthread_mutex_unlock(&hyp_pc_lock);
    return slot != NULL ? Qtrue : Qfalse;
}

/* PageCache.size -> Integer */
static VALUE rb_pc_size(VALUE self) {
    (void)self;
    pthread_mutex_lock(&hyp_pc_lock);
    size_t n = hyp_pc_count;
    pthread_mutex_unlock(&hyp_pc_lock);
    return SIZET2NUM(n);
}

/* PageCache.clear -> nil */
static VALUE rb_pc_clear(VALUE self) {
    (void)self;
    pthread_mutex_lock(&hyp_pc_lock);
    for (size_t i = 0; i < HYP_PC_BUCKET_SIZE; i++) {
        hyp_page_slot_t *slot = hyp_pc_buckets[i];
        while (slot != NULL) {
            hyp_page_slot_t *next = slot->next;
            hyp_page_destroy(slot->page);
            free(slot);
            slot = next;
        }
        hyp_pc_buckets[i] = NULL;
    }
    hyp_pc_count = 0;
    pthread_mutex_unlock(&hyp_pc_lock);
    return Qnil;
}

/* PageCache.recheck_seconds -> Float */
static VALUE rb_pc_get_recheck(VALUE self) {
    (void)self;
    pthread_mutex_lock(&hyp_pc_lock);
    double s = hyp_pc_recheck_seconds;
    pthread_mutex_unlock(&hyp_pc_lock);
    return rb_float_new(s);
}

/* PageCache.recheck_seconds=(seconds) */
static VALUE rb_pc_set_recheck(VALUE self, VALUE rb_seconds) {
    (void)self;
    double s = NUM2DBL(rb_seconds);
    if (s < 0.0) {
        rb_raise(rb_eArgError, "recheck_seconds must be >= 0 (got %f)", s);
    }
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_pc_recheck_seconds = s;
    pthread_mutex_unlock(&hyp_pc_lock);
    return rb_float_new(s);
}

/* PageCache.response_bytes(path) -> String | nil
 *
 * Specs-only helper. Returns a frozen copy of the pre-built response
 * buffer so tests can assert exact wire bytes without running a real
 * socket pair. Always re-reads under the lock. */
static VALUE rb_pc_response_bytes(VALUE self, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return Qnil;
    }
    uint64_t h = hyp_pc_hash(path, path_len);
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_page_slot_t *slot = hyp_pc_find_slot(path, path_len, h);
    VALUE result = Qnil;
    if (slot != NULL) {
        result = rb_str_new(slot->page->response_buf,
                            (long)slot->page->response_len);
    }
    pthread_mutex_unlock(&hyp_pc_lock);
    if (!NIL_P(result)) {
        rb_obj_freeze(result);
    }
    return result;
}

/* PageCache.body_bytes(path) -> Integer | nil
 *
 * Specs-only helper: returns the body byte count without re-reading the
 * file. Useful for asserting the cached size matches expectations. */
static VALUE rb_pc_body_bytes(VALUE self, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return Qnil;
    }
    uint64_t h = hyp_pc_hash(path, path_len);
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_page_slot_t *slot = hyp_pc_find_slot(path, path_len, h);
    VALUE result = Qnil;
    if (slot != NULL) {
        result = SIZET2NUM(slot->page->body_len);
    }
    pthread_mutex_unlock(&hyp_pc_lock);
    return result;
}

/* PageCache.content_type(path) -> String | nil — specs/operator helper. */
static VALUE rb_pc_content_type(VALUE self, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);
    const char *path     = RSTRING_PTR(rb_path);
    size_t      path_len = (size_t)RSTRING_LEN(rb_path);
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return Qnil;
    }
    uint64_t h = hyp_pc_hash(path, path_len);
    pthread_mutex_lock(&hyp_pc_lock);
    hyp_page_slot_t *slot = hyp_pc_find_slot(path, path_len, h);
    VALUE result = Qnil;
    if (slot != NULL) {
        result = rb_str_new_cstr(slot->page->content_type);
    }
    pthread_mutex_unlock(&hyp_pc_lock);
    if (!NIL_P(result)) {
        rb_obj_freeze(result);
    }
    return result;
}

/* PageCache.auto_threshold -> Integer */
static VALUE rb_pc_auto_threshold(VALUE self) {
    (void)self;
    return INT2NUM(HYP_PC_AUTO_THRESHOLD);
}

/* ============================================================
 * 2.12-C — Connection lifecycle in C.
 *
 * `run_static_accept_loop(listen_fd, idle_max_ms)` runs an accept ->
 * read-headers -> route-lookup -> write loop ENTIRELY in C for a
 * designated listening socket. Ruby is re-entered ONLY for:
 *
 *   1. Lifecycle hooks (when `lifecycle_hooks_active?` is true; gated
 *      by a single `int` test so the no-hook hot path stays branch-
 *      free) — one `rb_funcall` per request via the registered
 *      `lifecycle_callback`.
 *
 *   2. Handoff: when the accepted connection's first request doesn't
 *      match a `StaticEntry` (or the request is malformed / has a
 *      body / is HTTP/1.0 close / requests an upgrade), the C loop
 *      invokes the registered `handoff_callback` with `(fd_int,
 *      partial_buffer_or_nil)` and continues to the next accept.
 *      Ruby owns the fd from that point on.
 *
 *   3. Stop: when the listening fd returns EBADF / ECONNABORTED in a
 *      way that suggests `Server#stop` closed it, the loop returns
 *      the served-request count cleanly.
 *
 * Per-connection cost on a hit:
 *   * 1 `accept` syscall (GVL released).
 *   * 1 `setsockopt(TCP_NODELAY)` (mirrors 2.10-G; Nagle off so small
 *     responses aren't waiting on the peer's delayed-ACK timer).
 *   * 1 `recv` syscall to read the request headers (GVL released).
 *   * 1 `write` syscall for the prebuilt response (GVL released).
 *   * 0 Ruby allocations on the hot path past the served-count
 *     accumulator (a Fixnum in the Ruby-visible return value).
 *
 * Wire format expectations:
 *   * The request must be HTTP/1.1 (HTTP/1.0 is handed back to Ruby —
 *     keep-alive defaulting differs and the existing connection.rb
 *     already implements this correctly).
 *   * No request body (`Content-Length` / `Transfer-Encoding` headers
 *     trigger handoff). The whole point of `handle_static` is GETs/
 *     HEADs without a body; anything else is operator misuse and the
 *     Ruby path can produce a more diagnostic error.
 *   * Method must be GET or HEAD (matches `serve_request`'s gate).
 *
 * Concurrency: this function MUST be called on a Ruby thread that
 * owns the GVL. The loop releases the GVL during the blocking
 * syscalls and re-acquires it for the lifecycle / handoff
 * callbacks; the C-side PageCache lock (`hyp_pc_lock`) is taken
 * only for the lookup snapshot and released before the write
 * (the same pattern `serve_request` already uses).
 * ============================================================ */

/* Per-process state for the lifecycle / handoff callbacks. The
 * callbacks themselves are mark-protected via `rb_gc_register_mark_object`
 * so they survive across the GC even though they're stored in
 * static globals. */
static VALUE  hyp_cl_lifecycle_callback = Qnil;
static VALUE  hyp_cl_handoff_callback   = Qnil;
static int    hyp_cl_lifecycle_active   = 0;

/* Stop flag — flipped from Ruby via `stop_accept_loop` when the
 * listener should drop out of the loop voluntarily (graceful
 * shutdown). The accept syscall is still blocking; the operator's
 * `Server#stop` close()s the listener, which races us out via
 * `accept` returning EBADF / EINVAL. The flag is the secondary
 * signal: between two requests on a keep-alive connection we
 * check it before the next read. */
static volatile sig_atomic_t hyp_cl_stop = 0;

/* 2.12-E — per-process served-request counter, ticked once per request
 * served by `hyp_cl_serve_connection` (2.12-C accept4 loop) AND by the
 * 2.12-D io_uring loop (via the `pc_internal_*` shim). Read by Ruby at
 * scrape time via `Hyperion::Http::PageCache.c_loop_requests_total` —
 * the PrometheusExporter folds it into the
 * `hyperion_requests_dispatch_total{worker_id=PID}` series for the
 * current worker, so operators see one consistent per-worker number
 * regardless of which dispatch shape served the request.
 *
 * Atomicity: accessed via `__atomic_*` builtins (gcc/clang both
 * support these on every target this gem builds for). The hot-path
 * cost is one `lock add`-style instruction per request, well below
 * the ~10μs per-request budget at 134k r/s.
 *
 * Reset semantics: zeroed on `run_static_accept_loop` /
 * `run_static_io_uring_loop` entry so a previous loop's count from a
 * test-suite respawn doesn't leak into the new loop's snapshot.
 * Specs use `reset_c_loop_requests_total!` to assert from-zero
 * behaviour without driving a full loop.
 *
 * Type: `unsigned long long` to match the Integer marshalling
 * (`ULL2NUM`) on Ruby's side; signed wraparound is undefined behaviour
 * and we want defined unsigned-rollover semantics for the audit
 * counter (which would only matter at ~10^19 total requests).
 */
static volatile unsigned long long hyp_cl_requests_served_total = 0;

static inline void hyp_cl_tick_request(void) {
    __atomic_add_fetch(&hyp_cl_requests_served_total, 1ULL, __ATOMIC_RELAXED);
}

static inline unsigned long long hyp_cl_load_requests_served(void) {
    return __atomic_load_n(&hyp_cl_requests_served_total, __ATOMIC_RELAXED);
}

static inline void hyp_cl_reset_requests_served(void) {
    __atomic_store_n(&hyp_cl_requests_served_total, 0ULL, __ATOMIC_RELAXED);
}

/* Header-section size cap. Anything bigger is rejected: the request
 * is malformed or hostile, and either way Ruby's full parser is
 * the right place to produce an error response. Mirrors
 * `Connection::MAX_HEADER_BYTES` (64 KiB). */
#define HYP_CL_MAX_HEADER_BYTES 65536
/* Read chunk for header accumulation. 8 KiB matches the Ruby-side
 * `INBUF_INITIAL_CAPACITY` so a typical request fits in one recv. */
#define HYP_CL_READ_CHUNK 8192

/* ---- accept ---- */
typedef struct {
    int listen_fd;
    int client_fd;
    int err;
} hyp_cl_accept_args_t;

static void *hyp_cl_accept_blocking(void *raw) {
    hyp_cl_accept_args_t *a = (hyp_cl_accept_args_t *)raw;
    a->client_fd = -1;
    a->err = 0;
    for (;;) {
        struct sockaddr_storage ss;
        socklen_t slen = (socklen_t)sizeof(ss);
        int fd = accept(a->listen_fd, (struct sockaddr *)&ss, &slen);
        if (fd >= 0) {
            a->client_fd = fd;
            return NULL;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            /* Listener fd was non-blocking despite our F_SETFL clear
             * (or someone else flipped it back). Park on select() so
             * we don't busy-loop. The stop flag is checked by the
             * outer Ruby caller between accepts. */
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(a->listen_fd, &rfds);
            struct timeval tv;
            tv.tv_sec  = 1;
            tv.tv_usec = 0;
            int s = select(a->listen_fd + 1, &rfds, NULL, NULL, &tv);
            if (s < 0 && errno == EINTR) {
                continue;
            }
            /* On timeout, return so the caller can check the stop
             * flag and re-enter. */
            if (s == 0) {
                a->err = EAGAIN;
                return NULL;
            }
            continue;
        }
        a->err = errno;
        return NULL;
    }
}

/* ---- recv ---- */
typedef struct {
    int    fd;
    char  *buf;
    size_t cap;
    size_t off;
    int    err;
    /* Set by the caller; signals that we should bail out of recv on
     * the first EAGAIN/EWOULDBLOCK rather than retrying. Used between
     * keep-alive requests so an idle conn doesn't stall the worker. */
    int    nonblock_first;
} hyp_cl_recv_args_t;

static void *hyp_cl_recv_blocking(void *raw) {
    hyp_cl_recv_args_t *a = (hyp_cl_recv_args_t *)raw;
    a->err = 0;
    for (;;) {
        if (a->off >= a->cap) {
            a->err = E2BIG;
            return NULL;
        }
        ssize_t n = recv(a->fd, a->buf + a->off, a->cap - a->off, 0);
        if (n > 0) {
            a->off += (size_t)n;
            /* Look for end-of-headers (\r\n\r\n). Bounded scan over
             * what we've buffered so far. */
            if (a->off >= 4) {
                /* Fast scan of the just-read window first; fall back to
                 * a full scan if a CRLFCRLF straddled a recv boundary. */
                const char *base = a->buf;
                size_t scan_end = a->off;
                size_t i = (a->off - (size_t)n >= 3) ? a->off - (size_t)n - 3 : 0;
                while (i + 3 < scan_end) {
                    if (base[i]   == '\r' && base[i+1] == '\n' &&
                        base[i+2] == '\r' && base[i+3] == '\n') {
                        return NULL;
                    }
                    i++;
                }
            }
            continue;
        }
        if (n == 0) {
            /* Peer closed cleanly. */
            a->err = ECONNRESET;
            return NULL;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            /* The fd was unexpectedly non-blocking (Darwin's accept(2)
             * doesn't propagate O_NONBLOCK from the listener, but the
             * defensive branch keeps us correct on hosts where it
             * does — or where someone flipped the flag on the
             * accepted socket via setsockopt). Park on select(). */
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(a->fd, &rfds);
            struct timeval tv;
            tv.tv_sec  = 30; /* generous; matches Connection's read timeout */
            tv.tv_usec = 0;
            int s = select(a->fd + 1, &rfds, NULL, NULL, &tv);
            if (s < 0 && errno == EINTR) {
                continue;
            }
            if (s == 0) {
                a->err = ETIMEDOUT;
                return NULL;
            }
            continue;
        }
        a->err = errno;
        return NULL;
    }
}

/* Find end-of-headers in `buf` of length `len`. Returns the byte
 * offset PAST the trailing CRLFCRLF (i.e. where the body, if any,
 * would start), or -1 if not found. */
static long hyp_cl_find_eoh(const char *buf, size_t len) {
    if (len < 4) {
        return -1;
    }
    for (size_t i = 0; i + 3 < len; i++) {
        if (buf[i]   == '\r' && buf[i+1] == '\n' &&
            buf[i+2] == '\r' && buf[i+3] == '\n') {
            return (long)(i + 4);
        }
    }
    return -1;
}

/* Parse the request line out of the headers section. On success,
 * fills *m_off, *m_len, *p_off, *p_len with the offsets/lengths of
 * METHOD and PATH inside `buf`, and returns the length of the
 * request line including the trailing CRLF. On malformed input
 * returns -1. The version (HTTP/1.1) is checked here too — anything
 * other than HTTP/1.1 returns -1 so the caller hands off to Ruby. */
static long hyp_cl_parse_request_line(const char *buf, size_t len,
                                      size_t *m_off, size_t *m_len,
                                      size_t *p_off, size_t *p_len) {
    /* Find first SP — separates METHOD from PATH. */
    size_t i = 0;
    while (i < len && buf[i] != ' ' && buf[i] != '\r' && buf[i] != '\n') {
        i++;
    }
    if (i == 0 || i >= len || buf[i] != ' ') {
        return -1;
    }
    *m_off = 0;
    *m_len = i;
    i++;
    size_t p_start = i;
    while (i < len && buf[i] != ' ' && buf[i] != '\r' && buf[i] != '\n') {
        i++;
    }
    if (i >= len || buf[i] != ' ' || i == p_start) {
        return -1;
    }
    *p_off = p_start;
    *p_len = i - p_start;
    i++;
    /* Version: must be exactly "HTTP/1.1" followed by CRLF for the
     * C path. HTTP/1.0 has different keep-alive defaults; let Ruby
     * handle it. */
    if (i + 10 > len) {
        return -1;
    }
    if (memcmp(buf + i, "HTTP/1.1\r\n", 10) != 0) {
        return -1;
    }
    return (long)(i + 10);
}

/* Case-insensitive byte compare for header names. */
static int hyp_cl_iequals(const char *a, size_t alen, const char *b, size_t blen) {
    if (alen != blen) {
        return 0;
    }
    for (size_t i = 0; i < alen; i++) {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return 0;
    }
    return 1;
}

/* Inspect the header block (between request-line end and CRLFCRLF)
 * and report:
 *   *connection_close: 1 if Connection: close was seen, 0 otherwise.
 *   *has_body:         1 if Content-Length>0 or Transfer-Encoding
 *                      was seen (anything but CL:0).
 *   *upgrade_seen:     1 if Upgrade or h2 settings header was seen.
 *
 * Returns 0 on success, -1 on malformed framing. */
static int hyp_cl_scan_headers(const char *buf, size_t start, size_t end,
                               int *connection_close, int *has_body,
                               int *upgrade_seen) {
    *connection_close = 0;
    *has_body = 0;
    *upgrade_seen = 0;
    /* `end` points just past the closing CRLFCRLF; the last meaningful
     * header byte is at `end - 5` (the CR of the final header's CRLF
     * followed by the empty CRLF). The terminator we look for is
     * `\r\n` at positions [end-4, end-3]. */
    size_t i = start;
    while (i + 2 <= end) {
        if (i + 1 < end && buf[i] == '\r' && buf[i+1] == '\n') {
            /* Empty line — end of headers reached. */
            return 0;
        }
        size_t name_start = i;
        while (i < end && buf[i] != ':' && buf[i] != '\r') {
            i++;
        }
        if (i >= end || buf[i] != ':') {
            return -1;
        }
        size_t name_end = i;
        i++; /* past ':' */
        while (i < end && (buf[i] == ' ' || buf[i] == '\t')) {
            i++;
        }
        size_t val_start = i;
        while (i < end && buf[i] != '\r') {
            i++;
        }
        if (i + 1 >= end || buf[i+1] != '\n') {
            return -1;
        }
        size_t val_end = i;
        i += 2; /* past CRLF */

        size_t nlen = name_end - name_start;
        size_t vlen = val_end - val_start;
        const char *nptr = buf + name_start;
        const char *vptr = buf + val_start;

        if (hyp_cl_iequals(nptr, nlen, "connection", 10)) {
            /* Trim trailing whitespace. */
            while (vlen > 0 && (vptr[vlen - 1] == ' ' || vptr[vlen - 1] == '\t')) {
                vlen--;
            }
            if (hyp_cl_iequals(vptr, vlen, "close", 5)) {
                *connection_close = 1;
            } else if (hyp_cl_iequals(vptr, vlen, "upgrade", 7)) {
                *upgrade_seen = 1;
            }
        } else if (hyp_cl_iequals(nptr, nlen, "content-length", 14)) {
            /* Trim leading/trailing whitespace then parse. */
            while (vlen > 0 && (vptr[0] == ' ' || vptr[0] == '\t')) {
                vptr++; vlen--;
            }
            while (vlen > 0 && (vptr[vlen - 1] == ' ' || vptr[vlen - 1] == '\t')) {
                vlen--;
            }
            int cl_zero = (vlen == 1 && vptr[0] == '0');
            if (!cl_zero) {
                *has_body = 1;
            }
        } else if (hyp_cl_iequals(nptr, nlen, "transfer-encoding", 17)) {
            *has_body = 1;
        } else if (hyp_cl_iequals(nptr, nlen, "upgrade", 7)) {
            *upgrade_seen = 1;
        } else if (hyp_cl_iequals(nptr, nlen, "http2-settings", 14)) {
            *upgrade_seen = 1;
        }
    }
    return -1;
}

/* Lifecycle fire helper: rb_funcall into the registered callback
 * with (method_str, path_str). Wrapped in rb_protect so a misbehaving
 * Ruby hook can't take down the C loop. */
typedef struct {
    VALUE callback;
    VALUE method_str;
    VALUE path_str;
} hyp_cl_hook_args_t;

static VALUE hyp_cl_hook_invoke(VALUE raw) {
    hyp_cl_hook_args_t *a = (hyp_cl_hook_args_t *)raw;
    return rb_funcall(a->callback, rb_intern("call"), 2,
                      a->method_str, a->path_str);
}

static void hyp_cl_fire_lifecycle(const char *method, size_t mlen,
                                  const char *path, size_t plen) {
    if (!hyp_cl_lifecycle_active || NIL_P(hyp_cl_lifecycle_callback)) {
        return;
    }
    hyp_cl_hook_args_t a;
    a.callback   = hyp_cl_lifecycle_callback;
    a.method_str = rb_str_new(method, (long)mlen);
    a.path_str   = rb_str_new(path, (long)plen);
    int state = 0;
    rb_protect(hyp_cl_hook_invoke, (VALUE)&a, &state);
    /* Swallow the exception state — same contract as `Runtime#fire_*`:
     * a misbehaving observer must not break dispatch. The Ruby-side
     * callback already wraps individual hooks in their own rescues
     * and logs failures; this protect is belt-and-suspenders so the
     * C loop can't crash on a hook error either. */
    if (state) {
        rb_set_errinfo(Qnil);
    }
}

/* Handoff: invoke the Ruby callback with (fd, partial_buffer_str_or_nil).
 * Ruby owns the fd from that point on — C must not close it. */
typedef struct {
    VALUE callback;
    VALUE fd_int;
    VALUE buffer_str;
} hyp_cl_handoff_args_t;

static VALUE hyp_cl_handoff_invoke(VALUE raw) {
    hyp_cl_handoff_args_t *a = (hyp_cl_handoff_args_t *)raw;
    return rb_funcall(a->callback, rb_intern("call"), 2,
                      a->fd_int, a->buffer_str);
}

static void hyp_cl_handoff(int client_fd, const char *partial, size_t partial_len) {
    if (NIL_P(hyp_cl_handoff_callback)) {
        /* No callback registered — close the fd ourselves rather than
         * leaking it. This branch is paranoia; the Ruby side always
         * registers a handoff callback before starting the loop. */
        close(client_fd);
        return;
    }
    hyp_cl_handoff_args_t a;
    a.callback   = hyp_cl_handoff_callback;
    a.fd_int     = INT2NUM(client_fd);
    a.buffer_str = (partial_len > 0) ? rb_str_new(partial, (long)partial_len) : Qnil;
    int state = 0;
    rb_protect(hyp_cl_handoff_invoke, (VALUE)&a, &state);
    if (state) {
        /* Handoff failed — swallow and close the fd; better to drop
         * one connection than crash the whole loop. */
        rb_set_errinfo(Qnil);
        close(client_fd);
    }
}

/* Apply TCP_NODELAY to the accepted connection. Mirrors 2.10-G — Nagle
 * off so small responses aren't held by the peer's delayed-ACK timer.
 * Best-effort; failures are swallowed (some socket types don't honour
 * the option, or it was already set). */
static void hyp_cl_apply_tcp_nodelay(int fd) {
    int one = 1;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

/* Pre-built `404 Not Found` response, written to the socket when the
 * C loop sees a method/path it can answer with a definite negative
 * BUT can't hand off to Ruby (because the rest of the request looks
 * like a normal static request — peer expects an HTTP response, not
 * a TCP RST). Used only when handoff_callback is nil; otherwise we
 * always prefer to hand off to let Ruby produce the response.
 *
 * Currently unused — kept for future "C-only mode" where Ruby is
 * never re-entered. */
/* static const char hyp_cl_404[] =
 *     "HTTP/1.1 404 Not Found\r\n"
 *     "content-type: text/plain\r\n"
 *     "content-length: 9\r\n"
 *     "connection: close\r\n"
 *     "\r\n"
 *     "not found"; */

/* Serve one connection on `client_fd`. Returns the count of requests
 * served on this connection; -1 if the connection ended in a way
 * that should not increment the served counter (handoff, peer
 * disconnect mid-request). The `*handed_off` flag distinguishes
 * "Ruby took ownership of this fd" (we must NOT close it) from
 * "peer closed and we should close" (we close locally).
 *
 * The full headers buffer is kept stack-local — at 8 KiB it fits
 * comfortably and we avoid per-connection malloc traffic. */
static long hyp_cl_serve_connection(int client_fd, int *handed_off) {
    *handed_off = 0;
    long served = 0;
    char buf[HYP_CL_MAX_HEADER_BYTES];
    size_t buf_len = 0;

    /* Apply TCP_NODELAY once per connection — it sticks for the
     * lifetime of the fd. */
    hyp_cl_apply_tcp_nodelay(client_fd);

    for (;;) {
        if (hyp_cl_stop) {
            close(client_fd);
            return served;
        }

        /* If we have leftover bytes from the previous request (pipelined
         * input), they're already at the start of `buf`. Read more
         * until we have a full header section. */
        long eoh = hyp_cl_find_eoh(buf, buf_len);
        while (eoh < 0) {
            hyp_cl_recv_args_t r;
            r.fd  = client_fd;
            r.buf = buf;
            r.cap = sizeof(buf);
            r.off = buf_len;
            r.err = 0;
            r.nonblock_first = 0;
            rb_thread_call_without_gvl(hyp_cl_recv_blocking, &r,
                                       RUBY_UBF_IO, NULL);
            buf_len = r.off;
            if (r.err == ECONNRESET || r.err == ECONNABORTED) {
                /* Peer hung up. Close locally; not a request. */
                close(client_fd);
                return served;
            }
            if (r.err != 0 && r.err != EINTR) {
                /* Unexpected read error — close locally. */
                close(client_fd);
                return served;
            }
            eoh = hyp_cl_find_eoh(buf, buf_len);
            if (eoh < 0 && buf_len >= sizeof(buf)) {
                /* Header section exceeds our cap — hand off to Ruby
                 * (its parser produces a 400 with the right shape). */
                hyp_cl_handoff(client_fd, buf, buf_len);
                *handed_off = 1;
                return served;
            }
        }

        size_t method_off, method_len, path_off, path_len;
        long req_line_end = hyp_cl_parse_request_line(
            buf, (size_t)eoh, &method_off, &method_len, &path_off, &path_len);
        if (req_line_end < 0) {
            /* Malformed or HTTP/1.0 — let Ruby handle the response. */
            hyp_cl_handoff(client_fd, buf, buf_len);
            *handed_off = 1;
            return served;
        }

        int connection_close = 0;
        int has_body         = 0;
        int upgrade_seen     = 0;
        int hdr_ok = hyp_cl_scan_headers(buf, (size_t)req_line_end, (size_t)eoh,
                                         &connection_close, &has_body, &upgrade_seen);
        if (hdr_ok != 0 || has_body || upgrade_seen) {
            hyp_cl_handoff(client_fd, buf, buf_len);
            *handed_off = 1;
            return served;
        }

        /* Method + path lookup against the page cache. Reuse the
         * existing classify + lookup helpers so the C-side cache state
         * is the single source of truth — `Server.handle_static`
         * registers entries via `register_prebuilt`, this loop reads
         * them via `lookup_locked`. */
        hyp_pc_method_t kind = hyp_pc_classify_method(buf + method_off, method_len);
        if (kind == HYP_PC_METHOD_OTHER) {
            hyp_cl_handoff(client_fd, buf, buf_len);
            *handed_off = 1;
            return served;
        }

        pthread_mutex_lock(&hyp_pc_lock);
        int was_stale = 0;
        hyp_page_slot_t *slot = hyp_pc_lookup_locked(buf + path_off, path_len, &was_stale);
        if (slot == NULL) {
            pthread_mutex_unlock(&hyp_pc_lock);
            hyp_cl_handoff(client_fd, buf, buf_len);
            *handed_off = 1;
            return served;
        }
        size_t write_len = (kind == HYP_PC_METHOD_HEAD)
                               ? slot->page->headers_len
                               : slot->page->response_len;
        char *snapshot = (char *)malloc(write_len);
        if (snapshot == NULL) {
            pthread_mutex_unlock(&hyp_pc_lock);
            /* OOM mid-loop — hand off so Ruby can return 500. */
            hyp_cl_handoff(client_fd, buf, buf_len);
            *handed_off = 1;
            return served;
        }
        memcpy(snapshot, slot->page->response_buf, write_len);
        pthread_mutex_unlock(&hyp_pc_lock);

        hyp_pc_write_args_t wargs;
        wargs.fd    = client_fd;
        wargs.buf   = snapshot;
        wargs.len   = write_len;
        wargs.total = 0;
        wargs.err   = 0;
        rb_thread_call_without_gvl(hyp_pc_write_blocking, &wargs,
                                   RUBY_UBF_IO, NULL);
        free(snapshot);

        if (wargs.err != 0 && wargs.total == 0) {
            /* Write failed — peer most likely gone. Close and exit. */
            close(client_fd);
            return served;
        }

        served++;
        /* 2.12-E — per-process tick. Lock-free atomic so the SO_REUSEPORT
         * audit harness can scrape `c_loop_requests_total` mid-bench
         * without serialising on a Ruby-side mutex. */
        hyp_cl_tick_request();

        /* Lifecycle hooks fire AFTER the wire write so observers see a
         * completed request. Keep this off the no-hook hot path via
         * the integer flag. */
        if (hyp_cl_lifecycle_active) {
            hyp_cl_fire_lifecycle(buf + method_off, method_len,
                                  buf + path_off, path_len);
        }

        /* Carry pipelined bytes forward into the same buffer. */
        size_t consumed = (size_t)eoh;
        if (consumed < buf_len) {
            memmove(buf, buf + consumed, buf_len - consumed);
            buf_len -= consumed;
        } else {
            buf_len = 0;
        }

        if (connection_close) {
            /* Half-close, then briefly drain any inbound bytes so the
             * close() doesn't trigger an RST. Some platforms (notably
             * macOS) deliver RST when close() is called on a socket
             * with unread bytes in the receive queue — even the peer's
             * normal FIN-empty packet can race the close and surface
             * as ECONNRESET to the peer's last read(2). The drain is
             * bounded to a small absolute deadline so a misbehaving
             * peer can't stall us. */
            shutdown(client_fd, SHUT_WR);
            char drain[1024];
            for (int i = 0; i < 4; i++) {
                ssize_t n = recv(client_fd, drain, sizeof(drain), MSG_DONTWAIT);
                if (n <= 0) break;
            }
            close(client_fd);
            return served;
        }
        /* Keep-alive: loop back and read the next request. */
    }
}

/* Args passed into the no-GVL blocking accept wrapper. */
typedef struct {
    int listen_fd;
    /* On return: the served-request count for this loop invocation,
     * or -1 if the listener returned EBADF (graceful close). */
    long served_count;
} hyp_cl_loop_args_t;

/* PageCache.run_static_accept_loop(listen_fd) -> Integer | :crashed
 *
 * Drives the accept-and-serve loop. Returns the count of requests
 * served when the loop exits cleanly (listener closed, stop flag
 * raised) or `:crashed` if an unrecoverable accept error happened. */
static VALUE rb_pc_run_static_accept_loop(VALUE self, VALUE rb_listen_fd) {
    (void)self;
    int listen_fd = NUM2INT(rb_listen_fd);
    if (listen_fd < 0) {
        rb_raise(rb_eArgError, "listen_fd must be >= 0");
    }
    hyp_cl_stop = 0;
    /* 2.12-E — reset the per-process served-request counter on entry
     * so the audit metric reflects THIS loop's served count (not
     * leftovers from a prior loop in the same process — primarily a
     * test-suite concern; production has at most one loop per process
     * lifetime). */
    hyp_cl_reset_requests_served();

    /* Ruby's `TCPServer.new` sets O_NONBLOCK on the listening fd so
     * `IO.select` + `accept_nonblock` works naturally on the Ruby
     * side. Our C accept loop wants a BLOCKING fd: we release the
     * GVL during the accept syscall and want the kernel to park us
     * there rather than burning CPU on EAGAIN. Clear O_NONBLOCK
     * unconditionally — the operator's existing accept-loop code
     * paths don't share this fd with us (we own it for the lifetime
     * of `run_static_accept_loop`). */
    int flags = fcntl(listen_fd, F_GETFL, 0);
    if (flags >= 0 && (flags & O_NONBLOCK)) {
        (void)fcntl(listen_fd, F_SETFL, flags & ~O_NONBLOCK);
    }

    long served = 0;
    for (;;) {
        if (hyp_cl_stop) {
            break;
        }
        hyp_cl_accept_args_t a;
        a.listen_fd = listen_fd;
        a.client_fd = -1;
        a.err = 0;
        rb_thread_call_without_gvl(hyp_cl_accept_blocking, &a,
                                   RUBY_UBF_IO, NULL);
        if (a.client_fd < 0) {
            if (a.err == EBADF || a.err == EINVAL) {
                /* Listener was closed — graceful exit. */
                break;
            }
            if (a.err == ECONNABORTED || a.err == EAGAIN ||
                a.err == EWOULDBLOCK || a.err == EINTR) {
                /* Transient — re-check stop flag and re-enter accept. */
                continue;
            }
            /* Unexpected accept error; surface as :crashed so Ruby can
             * fall back to its own accept loop. */
            return ID2SYM(rb_intern("crashed"));
        }

        int handed_off = 0;
        long n = hyp_cl_serve_connection(a.client_fd, &handed_off);
        if (n > 0) {
            served += n;
        }
        /* hyp_cl_serve_connection closes the fd itself unless it handed
         * off to Ruby. Either way our work for this connection is
         * done. */
    }
    return LONG2NUM(served);
}

/* PageCache.set_lifecycle_callback(callable_or_nil) -> callable_or_nil
 *
 * Registers (or clears) the per-request lifecycle callback. Called
 * once at server boot from `Hyperion::Server`'s accept-loop set-up.
 * The callback receives (method_str, path_str) once per request the
 * C loop served; the Ruby implementation builds a Request and fires
 * `Runtime#fire_request_start` + `fire_request_end`. */
static VALUE rb_pc_set_lifecycle_callback(VALUE self, VALUE callback) {
    (void)self;
    if (!NIL_P(callback) && !rb_respond_to(callback, rb_intern("call"))) {
        rb_raise(rb_eArgError, "callback must respond to #call");
    }
    hyp_cl_lifecycle_callback = callback;
    return callback;
}

/* PageCache.set_lifecycle_active(bool) -> bool
 *
 * Toggles the integer flag the C loop reads on every request to
 * decide whether to invoke the lifecycle callback. Decoupled from
 * the callback registration so Ruby can flip it cheaply when hooks
 * are added/removed at runtime, without re-registering the
 * callback object itself. */
static VALUE rb_pc_set_lifecycle_active(VALUE self, VALUE flag) {
    (void)self;
    hyp_cl_lifecycle_active = RTEST(flag) ? 1 : 0;
    return flag;
}

/* PageCache.lifecycle_active? -> bool
 *
 * Spec/operator helper. */
static VALUE rb_pc_lifecycle_active_p(VALUE self) {
    (void)self;
    return hyp_cl_lifecycle_active ? Qtrue : Qfalse;
}

/* PageCache.set_handoff_callback(callable) -> callable
 *
 * Registers the callback the C loop invokes when a request can't
 * be served from the static cache. Receives (fd_int, partial_buffer_str_or_nil)
 * — Ruby owns the fd from that point on. The accept loop continues
 * to the next connection; a handoff is per-connection, not per-
 * accept-loop. */
static VALUE rb_pc_set_handoff_callback(VALUE self, VALUE callback) {
    (void)self;
    if (!NIL_P(callback) && !rb_respond_to(callback, rb_intern("call"))) {
        rb_raise(rb_eArgError, "callback must respond to #call");
    }
    hyp_cl_handoff_callback = callback;
    return callback;
}

/* PageCache.stop_accept_loop -> nil
 *
 * Flips the stop flag. The accept loop checks it between accepts and
 * (more importantly) between keep-alive requests on the same
 * connection; the `Server#stop` close()-on-listener is the primary
 * signal (it races us out via accept returning EBADF). */
static VALUE rb_pc_stop_accept_loop(VALUE self) {
    (void)self;
    hyp_cl_stop = 1;
    return Qnil;
}

/* PageCache.c_loop_requests_total -> Integer
 *
 * 2.12-E — the running per-process count of requests served by either
 * the 2.12-C accept4 loop or the 2.12-D io_uring loop since the
 * loop-entry reset. Read at /-/metrics scrape time so the
 * `hyperion_requests_dispatch_total{worker_id=PID}` family reflects
 * C-loop-served requests in addition to Ruby-side ones. Lock-free
 * via the same atomic the loop bumps on each request. */
static VALUE rb_pc_c_loop_requests_total(VALUE self) {
    (void)self;
    return ULL2NUM(hyp_cl_load_requests_served());
}

/* PageCache.reset_c_loop_requests_total! -> 0
 *
 * 2.12-E — spec/operator escape hatch for clearing the per-process
 * counter between bench runs without restarting the worker. Production
 * has no need for this; the loop-entry path resets implicitly. */
static VALUE rb_pc_reset_c_loop_requests_total_bang(VALUE self) {
    (void)self;
    hyp_cl_reset_requests_served();
    return INT2NUM(0);
}

/* PageCache.bump_c_loop_requests_total_for_test!(n) -> Integer
 *
 * 2.12-E — spec-only counter primer. Lets the PrometheusExporter
 * fold-in test assert the merge logic without needing a live C loop
 * (which would tie the spec to listener bind + accept timing).
 * NOT documented as public surface; the name's `_for_test!` suffix
 * is the contract. */
static VALUE rb_pc_bump_c_loop_requests_total_for_test_bang(VALUE self, VALUE rb_n) {
    (void)self;
    long n = NUM2LONG(rb_n);
    if (n < 0) {
        rb_raise(rb_eArgError, "n must be >= 0");
    }
    for (long i = 0; i < n; i++) {
        hyp_cl_tick_request();
    }
    return ULL2NUM(hyp_cl_load_requests_served());
}

/* PageCache.handoff_to_ruby(client_fd, _partial_buffer, _partial_len) -> Integer
 *
 * Echo helper — exposed for spec parity with the bench-time API
 * shape called out in the 2.12-C plan. The actual handoff happens
 * inside the C loop via the registered callback; this method exists
 * so callers can introspect the contract without engaging the
 * accept loop. */
static VALUE rb_pc_handoff_to_ruby(VALUE self, VALUE rb_fd, VALUE rb_buf,
                                   VALUE rb_len) {
    (void)self; (void)rb_buf; (void)rb_len;
    return rb_fd;
}

/* PageCache.max_key_len -> Integer */
static VALUE rb_pc_max_key_len(VALUE self) {
    (void)self;
    return INT2NUM(HYP_PC_MAX_KEY_LEN);
}

/* ============================================================
 * 2.12-D — sharing surface for io_uring_loop.c.
 *
 * Thin extern wrappers around the static helpers above. The io_uring
 * loop calls these once per request; the indirection cost is one
 * direct-call jump and is dominated by the syscall savings. Defined
 * here (rather than promoted-static) so the helpers' signatures stay
 * file-local and we don't accidentally widen the public surface of
 * the C ext. */

long pc_internal_find_eoh(const char *buf, size_t len) {
    return hyp_cl_find_eoh(buf, len);
}

long pc_internal_parse_request_line(const char *buf, size_t len,
                                    size_t *m_off, size_t *m_len,
                                    size_t *p_off, size_t *p_len) {
    return hyp_cl_parse_request_line(buf, len, m_off, m_len, p_off, p_len);
}

int pc_internal_scan_headers(const char *buf, size_t start, size_t end,
                             int *connection_close, int *has_body,
                             int *upgrade_seen) {
    return hyp_cl_scan_headers(buf, start, end, connection_close, has_body,
                               upgrade_seen);
}

pc_internal_method_t pc_internal_classify_method(const char *m, size_t len) {
    hyp_pc_method_t k = hyp_pc_classify_method(m, len);
    switch (k) {
    case HYP_PC_METHOD_GET:  return PC_INTERNAL_METHOD_GET;
    case HYP_PC_METHOD_HEAD: return PC_INTERNAL_METHOD_HEAD;
    default:                 return PC_INTERNAL_METHOD_OTHER;
    }
}

char *pc_internal_snapshot_response(const char *path, size_t path_len,
                                    pc_internal_method_t kind,
                                    size_t *out_len) {
    *out_len = 0;
    if (path_len == 0 || path_len > HYP_PC_MAX_KEY_LEN) {
        return NULL;
    }
    pthread_mutex_lock(&hyp_pc_lock);
    int was_stale = 0;
    hyp_page_slot_t *slot = hyp_pc_lookup_locked(path, path_len, &was_stale);
    if (slot == NULL) {
        pthread_mutex_unlock(&hyp_pc_lock);
        return NULL;
    }
    size_t write_len = (kind == PC_INTERNAL_METHOD_HEAD)
                           ? slot->page->headers_len
                           : slot->page->response_len;
    char *snapshot = (char *)malloc(write_len);
    if (snapshot == NULL) {
        pthread_mutex_unlock(&hyp_pc_lock);
        return NULL;
    }
    memcpy(snapshot, slot->page->response_buf, write_len);
    pthread_mutex_unlock(&hyp_pc_lock);
    *out_len = write_len;
    return snapshot;
}

void pc_internal_apply_tcp_nodelay(int fd) {
    hyp_cl_apply_tcp_nodelay(fd);
}

void pc_internal_fire_lifecycle(const char *method, size_t mlen,
                                const char *path, size_t plen) {
    hyp_cl_fire_lifecycle(method, mlen, path, plen);
}

int pc_internal_lifecycle_active(void) {
    return hyp_cl_lifecycle_active;
}

void pc_internal_handoff(int client_fd, const char *partial, size_t partial_len) {
    hyp_cl_handoff(client_fd, partial, partial_len);
}

int pc_internal_stop_requested(void) {
    return hyp_cl_stop ? 1 : 0;
}

void pc_internal_reset_stop(void) {
    hyp_cl_stop = 0;
}

/* 2.12-E — io_uring loop sibling tick / reset entry points. Forward to
 * the file-local helpers so the atomic stays a single-source-of-truth
 * for both loop variants. */
void pc_internal_tick_request(void) {
    hyp_cl_tick_request();
}

void pc_internal_reset_requests_served(void) {
    hyp_cl_reset_requests_served();
}

/* Belt-and-suspenders: keep the io_uring sibling's view of the header
 * cap in sync with this file's. Compile-time check via array sizing
 * (we deliberately avoid C11 `_Static_assert` for portability with the
 * older toolchains some linux distros still ship). */
typedef int pc_internal_header_cap_check_t
    [(HYP_CL_MAX_HEADER_BYTES == PC_INTERNAL_MAX_HEADER_BYTES) ? 1 : -1];

void Init_hyperion_page_cache(void) {
    rb_mHyperion_pc = rb_const_get(rb_cObject, rb_intern("Hyperion"));

    if (rb_const_defined(rb_mHyperion_pc, rb_intern("Http"))) {
        rb_mHyperionHttp_pc = rb_const_get(rb_mHyperion_pc, rb_intern("Http"));
    } else {
        rb_mHyperionHttp_pc = rb_define_module_under(rb_mHyperion_pc, "Http");
    }

    rb_mHyperionHttpPageCache = rb_define_module_under(rb_mHyperionHttp_pc,
                                                       "PageCache");

    rb_define_singleton_method(rb_mHyperionHttpPageCache, "fetch",
                               rb_pc_fetch, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "cache_file",
                               rb_pc_cache_file, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "write_to",
                               rb_pc_write_to, 2);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "set_immutable",
                               rb_pc_set_immutable, 2);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "size",
                               rb_pc_size, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "clear",
                               rb_pc_clear, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "recheck_seconds",
                               rb_pc_get_recheck, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "recheck_seconds=",
                               rb_pc_set_recheck, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "response_bytes",
                               rb_pc_response_bytes, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "body_bytes",
                               rb_pc_body_bytes, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "content_type",
                               rb_pc_content_type, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "auto_threshold",
                               rb_pc_auto_threshold, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "max_key_len",
                               rb_pc_max_key_len, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "register_prebuilt",
                               rb_pc_register_prebuilt, 3);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "serve_request",
                               rb_pc_serve_request, 3);
    /* 2.12-C — connection lifecycle in C. */
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "run_static_accept_loop",
                               rb_pc_run_static_accept_loop, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "stop_accept_loop",
                               rb_pc_stop_accept_loop, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "set_lifecycle_callback",
                               rb_pc_set_lifecycle_callback, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "set_lifecycle_active",
                               rb_pc_set_lifecycle_active, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "lifecycle_active?",
                               rb_pc_lifecycle_active_p, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "set_handoff_callback",
                               rb_pc_set_handoff_callback, 1);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "handoff_to_ruby",
                               rb_pc_handoff_to_ruby, 3);

    /* 2.12-E — per-process served-request counter for the SO_REUSEPORT
     * load-balancing audit. Read at /-/metrics scrape time and folded
     * into `hyperion_requests_dispatch_total{worker_id=PID}` so
     * operators see a single per-worker number across every dispatch
     * shape (Rack via Connection, h2, the C loops). */
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "c_loop_requests_total",
                               rb_pc_c_loop_requests_total, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "reset_c_loop_requests_total!",
                               rb_pc_reset_c_loop_requests_total_bang, 0);
    rb_define_singleton_method(rb_mHyperionHttpPageCache, "bump_c_loop_requests_total_for_test!",
                               rb_pc_bump_c_loop_requests_total_for_test_bang, 1);

    /* Mark-protect the lifecycle / handoff callback slots so the GC
     * doesn't collect them while the C loop is running. */
    rb_gc_register_address(&hyp_cl_lifecycle_callback);
    rb_gc_register_address(&hyp_cl_handoff_callback);

    id_fileno_pc = rb_intern("fileno");
    id_to_io_pc  = rb_intern("to_io");

    sym_ok_pc      = ID2SYM(rb_intern("ok"));
    sym_stale_pc   = ID2SYM(rb_intern("stale"));
    sym_missing_pc = ID2SYM(rb_intern("missing"));
    sym_miss_pc    = ID2SYM(rb_intern("miss"));

    rb_gc_register_mark_object(sym_ok_pc);
    rb_gc_register_mark_object(sym_stale_pc);
    rb_gc_register_mark_object(sym_missing_pc);
    rb_gc_register_mark_object(sym_miss_pc);

    /* 2.12-D — register the io_uring sibling. The init defines the
     * `run_static_io_uring_loop` Ruby method on the same module
     * (`Hyperion::Http::PageCache`) and lazy-initialises any per-process
     * io_uring state. On non-Linux / no-liburing builds the registered
     * method returns the `:unavailable` symbol so the Ruby caller can
     * fall through to the 2.12-C accept4 path. */
    extern void Init_hyperion_io_uring_loop(VALUE mPageCache);
    Init_hyperion_io_uring_loop(rb_mHyperionHttpPageCache);
}
