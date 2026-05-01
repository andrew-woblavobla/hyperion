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
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>

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
    time_t   mtime;         /* last-known file mtime */
    double   last_check;    /* dtime() of last stat */
    int      immutable;     /* non-zero → never re-stat */
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
    p->mtime        = mtime;
    p->last_check   = hyp_pc_now();
    p->immutable    = 0;
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
    if (p->immutable) {
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

/* PageCache.max_key_len -> Integer */
static VALUE rb_pc_max_key_len(VALUE self) {
    (void)self;
    return INT2NUM(HYP_PC_MAX_KEY_LEN);
}

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

    id_fileno_pc = rb_intern("fileno");
    id_to_io_pc  = rb_intern("to_io");

    sym_ok_pc      = ID2SYM(rb_intern("ok"));
    sym_stale_pc   = ID2SYM(rb_intern("stale"));
    sym_missing_pc = ID2SYM(rb_intern("missing"));

    rb_gc_register_mark_object(sym_ok_pc);
    rb_gc_register_mark_object(sym_stale_pc);
    rb_gc_register_mark_object(sym_missing_pc);
}
