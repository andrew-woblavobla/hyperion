#include <ruby.h>
#include <ruby/encoding.h>
#include <string.h>
#include "llhttp.h"

/* ----------------------------------------------------------------------
 * Hyperion::CParser — C extension wrapping llhttp.
 *
 * Public surface matches Hyperion::Parser:
 *   parser.parse(buffer) -> [Request, end_offset]
 *
 * On parse error: raise Hyperion::ParseError.
 * On unsupported: raise Hyperion::UnsupportedError.
 * On success: returns [Request, end_offset] where end_offset is the
 *   number of bytes consumed from `buffer`.
 *
 * Implementation: each #parse call instantiates a fresh llhttp_t state
 * on the stack; pooling comes in Phase 5. Callbacks accumulate fields
 * into a parser_state_t struct. When llhttp signals message-complete,
 * we build the Ruby Request and return.
 * ---------------------------------------------------------------------- */

static VALUE rb_mHyperion;
static VALUE rb_cCParser;
static VALUE rb_cRequest;
static VALUE rb_eParseError;
static VALUE rb_eUnsupportedError;

static ID id_new;
static ID id_downcase;
static ID id_method_kw;
static ID id_path_kw;
static ID id_query_string_kw;
static ID id_http_version_kw;
static ID id_headers_kw;
static ID id_body_kw;

typedef struct {
    /* Request line + headers */
    VALUE method;
    VALUE path;
    VALUE query_string;
    VALUE http_version;
    VALUE headers;       /* Hash, lowercase keys */
    VALUE body;          /* String */

    /* Header parsing scratch */
    VALUE current_header_name;
    VALUE current_header_value;

    /* Flags */
    int message_complete;
    int has_content_length;
    int has_transfer_encoding;
    int chunked_transfer_encoding;
    int parse_error;     /* 1 = parse, 2 = unsupported */
    const char *error_message;
} parser_state_t;

static void state_init(parser_state_t *s) {
    s->method                    = Qnil;
    s->path                      = rb_str_new_cstr("");
    s->query_string              = rb_str_new_cstr("");
    s->http_version              = rb_str_new_cstr("HTTP/1.1");
    s->headers                   = rb_hash_new();
    s->body                      = rb_str_new_cstr("");
    s->current_header_name       = rb_str_new_cstr("");
    s->current_header_value      = rb_str_new_cstr("");
    s->message_complete          = 0;
    s->has_content_length        = 0;
    s->has_transfer_encoding     = 0;
    s->chunked_transfer_encoding = 0;
    s->parse_error               = 0;
    s->error_message             = NULL;
}

/* Cap each individual field so we don't OOM on adversarial input. */
#define MAX_FIELD_BYTES (64 * 1024)
#define MAX_BODY_BYTES  (16 * 1024 * 1024)

#define APPEND_OR_FAIL(dst, at, length, cap, who) do {     \
    if (RSTRING_LEN(dst) + (long)(length) > (long)(cap)) { \
        s->parse_error = 1;                                \
        s->error_message = (who " too large");             \
        return -1;                                         \
    }                                                      \
    rb_str_cat(dst, at, length);                           \
} while (0)

static void stash_pending_header(parser_state_t *s) {
    if (RSTRING_LEN(s->current_header_name) > 0) {
        VALUE downcased = rb_funcall(s->current_header_name, id_downcase, 0);
        rb_hash_aset(s->headers, downcased, s->current_header_value);
        s->current_header_name  = rb_str_new_cstr("");
        s->current_header_value = rb_str_new_cstr("");
    }
}

static int on_url(llhttp_t *p, const char *at, size_t length) {
    parser_state_t *s = (parser_state_t *)p->data;
    APPEND_OR_FAIL(s->path, at, length, MAX_FIELD_BYTES, "url");
    return 0;
}

static int on_url_complete(llhttp_t *p) {
    parser_state_t *s = (parser_state_t *)p->data;
    /* Split path?query. */
    char *full = RSTRING_PTR(s->path);
    long full_len = RSTRING_LEN(s->path);
    long q_idx = -1;
    for (long i = 0; i < full_len; i++) {
        if (full[i] == '?') { q_idx = i; break; }
    }
    if (q_idx >= 0) {
        s->query_string = rb_str_new(full + q_idx + 1, full_len - q_idx - 1);
        rb_str_set_len(s->path, q_idx);
    }
    return 0;
}

static int on_method(llhttp_t *p, const char *at, size_t length) {
    parser_state_t *s = (parser_state_t *)p->data;
    if (NIL_P(s->method)) {
        s->method = rb_str_new(at, length);
    } else {
        APPEND_OR_FAIL(s->method, at, length, 32, "method");
    }
    return 0;
}

static int on_version(llhttp_t *p, const char *at, size_t length) {
    /* llhttp gives us "1.1"; we prepend "HTTP/" ourselves. */
    parser_state_t *s = (parser_state_t *)p->data;
    s->http_version = rb_str_new_cstr("HTTP/");
    rb_str_cat(s->http_version, at, length);
    return 0;
}

static int on_header_field(llhttp_t *p, const char *at, size_t length) {
    parser_state_t *s = (parser_state_t *)p->data;
    /* If current_header_value is non-empty, we just finished a header. */
    if (RSTRING_LEN(s->current_header_value) > 0) {
        stash_pending_header(s);
    }
    if (RSTRING_LEN(s->current_header_name) == 0) {
        s->current_header_name = rb_str_new(at, length);
    } else {
        APPEND_OR_FAIL(s->current_header_name, at, length, MAX_FIELD_BYTES, "header name");
    }
    return 0;
}

static int on_header_value(llhttp_t *p, const char *at, size_t length) {
    parser_state_t *s = (parser_state_t *)p->data;
    if (RSTRING_LEN(s->current_header_value) == 0) {
        s->current_header_value = rb_str_new(at, length);
    } else {
        APPEND_OR_FAIL(s->current_header_value, at, length, MAX_FIELD_BYTES, "header value");
    }
    return 0;
}

static int on_headers_complete(llhttp_t *p) {
    parser_state_t *s = (parser_state_t *)p->data;
    stash_pending_header(s);

    /* Smuggling defense: both Content-Length and Transfer-Encoding present. */
    VALUE cl_key = rb_str_new_cstr("content-length");
    VALUE te_key = rb_str_new_cstr("transfer-encoding");
    VALUE cl = rb_hash_aref(s->headers, cl_key);
    VALUE te = rb_hash_aref(s->headers, te_key);
    s->has_content_length    = !NIL_P(cl);
    s->has_transfer_encoding = !NIL_P(te);
    if (s->has_content_length && s->has_transfer_encoding) {
        s->parse_error   = 1;
        s->error_message = "both Content-Length and Transfer-Encoding present (smuggling defense)";
        return -1;
    }

    /* Verify TE: only chunked (or comma-list ending in chunked) is supported. */
    if (s->has_transfer_encoding) {
        VALUE te_lower = rb_funcall(te, id_downcase, 0);
        const char *te_str = RSTRING_PTR(te_lower);
        long te_len = RSTRING_LEN(te_lower);
        /* Trim trailing whitespace. */
        while (te_len > 0 && (te_str[te_len - 1] == ' ' || te_str[te_len - 1] == '\t')) {
            te_len--;
        }
        if (te_len < 7 || strncmp(te_str + te_len - 7, "chunked", 7) != 0) {
            s->parse_error   = 2;
            s->error_message = "Transfer-Encoding not supported (only chunked)";
            return -1;
        }
        s->chunked_transfer_encoding = 1;
    }

    return 0;
}

static int on_body(llhttp_t *p, const char *at, size_t length) {
    parser_state_t *s = (parser_state_t *)p->data;
    APPEND_OR_FAIL(s->body, at, length, MAX_BODY_BYTES, "body");
    return 0;
}

static int on_message_complete(llhttp_t *p) {
    parser_state_t *s = (parser_state_t *)p->data;
    s->message_complete = 1;
    /* Returning HPE_PAUSED halts llhttp_execute immediately at the message
     * boundary; llhttp_get_error_pos then points to the next byte (start of
     * the next pipelined request, if any). Without this, llhttp continues
     * parsing the second message in-place, smearing method/path/etc. */
    (void)p;
    return HPE_PAUSED;
}

static llhttp_settings_t settings;

static void install_settings(void) {
    llhttp_settings_init(&settings);
    settings.on_url              = on_url;
    settings.on_url_complete     = on_url_complete;
    settings.on_method           = on_method;
    settings.on_version          = on_version;
    settings.on_header_field     = on_header_field;
    settings.on_header_value     = on_header_value;
    settings.on_headers_complete = on_headers_complete;
    settings.on_body             = on_body;
    settings.on_message_complete = on_message_complete;
}

/* parse(buffer) -> [Request, end_offset]
 *
 * Parse one complete HTTP/1.1 request from `buffer`. If buffer doesn't yet
 * contain a complete request, raise ParseError("incomplete"). For pipelined
 * input, end_offset is the byte boundary of the first request — Connection
 * carries the rest forward.
 */
static VALUE cparser_parse(VALUE self, VALUE buffer) {
    Check_Type(buffer, T_STRING);
    (void)self;

    parser_state_t s;
    state_init(&s);

    llhttp_t parser;
    llhttp_init(&parser, HTTP_REQUEST, &settings);
    parser.data = &s;

    const char *data = RSTRING_PTR(buffer);
    size_t len = (size_t)RSTRING_LEN(buffer);

    enum llhttp_errno err = llhttp_execute(&parser, data, len);

    /* Custom error flags (set inside callbacks) take precedence. */
    if (s.parse_error == 2) {
        rb_raise(rb_eUnsupportedError, "%s", s.error_message);
    }
    if (s.parse_error == 1) {
        rb_raise(rb_eParseError, "%s", s.error_message);
    }

    if (err == HPE_PAUSED_UPGRADE) {
        rb_raise(rb_eUnsupportedError, "Upgrade not supported");
    }
    if (err != HPE_OK && err != HPE_PAUSED) {
        const char *reason = llhttp_get_error_reason(&parser);
        rb_raise(rb_eParseError, "llhttp: %s",
                 (reason && *reason) ? reason : llhttp_errno_name(err));
    }

    if (!s.message_complete) {
        rb_raise(rb_eParseError, "incomplete request");
    }

    /* Compute end_offset. We pause inside on_message_complete, so
     * llhttp_get_error_pos returns the byte just after the message
     * boundary — exactly the carry-over offset we want. */
    size_t consumed;
    if (err == HPE_PAUSED) {
        const char *epos = llhttp_get_error_pos(&parser);
        consumed = epos ? (size_t)(epos - data) : len;
    } else {
        consumed = len;
    }

    /* Build the Request. */
    VALUE kwargs = rb_hash_new();
    rb_hash_aset(kwargs, ID2SYM(id_method_kw),       s.method);
    rb_hash_aset(kwargs, ID2SYM(id_path_kw),         s.path);
    rb_hash_aset(kwargs, ID2SYM(id_query_string_kw), s.query_string);
    rb_hash_aset(kwargs, ID2SYM(id_http_version_kw), s.http_version);
    rb_hash_aset(kwargs, ID2SYM(id_headers_kw),      s.headers);
    rb_hash_aset(kwargs, ID2SYM(id_body_kw),         s.body);

    VALUE args[1] = { kwargs };
    VALUE request = rb_funcallv_kw(rb_cRequest, id_new, 1, args, RB_PASS_KEYWORDS);

    return rb_ary_new_from_args(2, request, ULONG2NUM((unsigned long)consumed));
}

/* Hyperion::CParser.build_response_head(status, reason, headers, body_size,
 *                                        keep_alive, date_str) -> String
 *
 * Builds the HTTP/1.1 response head:
 *   "HTTP/1.1 <status> <reason>\r\n"
 *   "<lowercased-key>: <value>\r\n" for each user header (except
 *     content-length / connection — we always set these from the framing
 *     args below, mirroring the rc16 Ruby behaviour where the normalized
 *     hash is overridden in place).
 *   "content-length: <body_size>\r\n"
 *   "connection: <close|keep-alive>\r\n"
 *   "date: <date_str>\r\n"  (only if user headers didn't include 'date')
 *   "\r\n"
 *
 * Header values containing CR/LF raise ArgumentError (response-splitting
 * guard). Bypasses Ruby Hash#each + per-line String#<< allocation; the
 * status line, framing headers, and join slices live in C buffers.
 */
static VALUE cbuild_response_head(VALUE self, VALUE rb_status, VALUE rb_reason,
                                  VALUE rb_headers, VALUE rb_body_size,
                                  VALUE rb_keep_alive, VALUE rb_date) {
    (void)self;
    Check_Type(rb_headers, T_HASH);
    Check_Type(rb_reason, T_STRING);
    Check_Type(rb_date, T_STRING);

    int status     = NUM2INT(rb_status);
    long body_size = NUM2LONG(rb_body_size);
    int keep_alive = RTEST(rb_keep_alive);

    /* Most heads fit in 1 KiB; rb_str_cat grows on demand. */
    VALUE buf = rb_str_buf_new(1024);

    /* Status line: "HTTP/1.1 <status> <reason>\r\n" */
    char status_line[48];
    int n = snprintf(status_line, sizeof(status_line), "HTTP/1.1 %d ", status);
    rb_str_cat(buf, status_line, n);
    rb_str_cat(buf, RSTRING_PTR(rb_reason), RSTRING_LEN(rb_reason));
    rb_str_cat(buf, "\r\n", 2);

    /* Iterate user headers — lowercase key, validate value, skip framing. */
    int has_date = 0;

    VALUE keys = rb_funcall(rb_headers, rb_intern("keys"), 0);
    long n_keys = RARRAY_LEN(keys);
    for (long i = 0; i < n_keys; i++) {
        VALUE k = rb_ary_entry(keys, i);
        VALUE v = rb_hash_aref(rb_headers, k);

        VALUE k_s     = rb_obj_as_string(k);
        VALUE v_s     = rb_obj_as_string(v);
        VALUE k_lower = rb_funcall(k_s, id_downcase, 0);

        const char *k_ptr = RSTRING_PTR(k_lower);
        long k_len        = RSTRING_LEN(k_lower);
        const char *v_ptr = RSTRING_PTR(v_s);
        long v_len        = RSTRING_LEN(v_s);

        /* CRLF injection guard on value. */
        for (long j = 0; j < v_len; j++) {
            if (v_ptr[j] == '\r' || v_ptr[j] == '\n') {
                rb_raise(rb_eArgError, "header %s contains CR/LF",
                         RSTRING_PTR(rb_inspect(k_lower)));
            }
        }

        /* Drop user-supplied content-length / connection — we always set
         * these unconditionally below (matches rc16 Ruby behaviour where
         * the normalized hash overwrites in place). */
        if (k_len == 14 && memcmp(k_ptr, "content-length", 14) == 0) continue;
        if (k_len == 10 && memcmp(k_ptr, "connection", 10) == 0)     continue;

        if (k_len == 4 && memcmp(k_ptr, "date", 4) == 0) {
            has_date = 1;
        }

        rb_str_cat(buf, k_ptr, k_len);
        rb_str_cat(buf, ": ", 2);
        rb_str_cat(buf, v_ptr, v_len);
        rb_str_cat(buf, "\r\n", 2);
    }

    /* Framing headers — always emitted. */
    char cl_buf[48];
    n = snprintf(cl_buf, sizeof(cl_buf), "content-length: %ld\r\n", body_size);
    rb_str_cat(buf, cl_buf, n);

    if (keep_alive) {
        rb_str_cat(buf, "connection: keep-alive\r\n", 24);
    } else {
        rb_str_cat(buf, "connection: close\r\n", 19);
    }

    if (!has_date) {
        rb_str_cat(buf, "date: ", 6);
        rb_str_cat(buf, RSTRING_PTR(rb_date), RSTRING_LEN(rb_date));
        rb_str_cat(buf, "\r\n", 2);
    }

    /* End of head */
    rb_str_cat(buf, "\r\n", 2);

    return buf;
}

/* Hyperion::CParser.build_access_line(format, ts, method, path, query,
 *                                     status, duration_ms, remote_addr,
 *                                     http_version) -> String
 *
 * Hand-rolled access-log line builder used by Hyperion::Logger#access on the
 * hot path. The Ruby version allocates 1-2 throwaway Strings per line; this
 * builds the line into a stack scratch buffer (with rb_str_buf overflow for
 * extreme cases) and returns a single Ruby String. ~10× faster on the
 * common case, which closes the perf gap between log_requests on/off.
 *
 * `format` is :text or :json (Symbol). The format strings here mirror
 * Logger#build_access_text / #build_access_json byte-for-byte (no colour —
 * the C builder is only used when @colorize is false, i.e. non-TTY production
 * deployments where access logs are the highest-volume log line).
 *
 * String inputs are passed through verbatim. Access logs are best-effort
 * structured output, not a security boundary; CRLF in path/remote_addr would
 * be a log-injection nuisance but cannot escalate. Status (int) and
 * duration_ms (double/Numeric) go through snprintf, which is type-safe.
 */
static VALUE cbuild_access_line(VALUE self,
                                VALUE format_sym, VALUE rb_ts, VALUE rb_method,
                                VALUE rb_path, VALUE rb_query, VALUE rb_status,
                                VALUE rb_duration, VALUE rb_remote,
                                VALUE rb_http_version) {
    (void)self;
    Check_Type(rb_ts, T_STRING);
    Check_Type(rb_method, T_STRING);
    Check_Type(rb_path, T_STRING);
    Check_Type(rb_http_version, T_STRING);

    int is_json = (TYPE(format_sym) == T_SYMBOL) &&
                  (SYM2ID(format_sym) == rb_intern("json"));

    int status     = NUM2INT(rb_status);
    double dur_ms  = NUM2DBL(rb_duration);

    int has_query  = !NIL_P(rb_query) && RSTRING_LEN(rb_query) > 0;
    int has_remote = !NIL_P(rb_remote) && RSTRING_LEN(rb_remote) > 0;

    /* 1 KiB initial buffer covers the vast majority of access-log lines
     * (timestamp + level + path + status + addr ~= 200 bytes). rb_str_cat
     * grows on overflow.
     *
     * We use a CAT_LIT macro for literal-string appends so the compiler
     * computes length via sizeof — manual byte counts on hand-rolled
     * literal lengths are an off-by-one waiting to happen. */
#define CAT_LIT(b, s) rb_str_cat((b), (s), (long)(sizeof(s) - 1))

    VALUE buf = rb_str_buf_new(512);

    if (is_json) {
        /* Prefix: {"ts":"...","level":"info","source":"hyperion","message":"request", */
        CAT_LIT(buf, "{\"ts\":\"");
        rb_str_cat(buf, RSTRING_PTR(rb_ts), RSTRING_LEN(rb_ts));
        CAT_LIT(buf, "\",\"level\":\"info\",\"source\":\"hyperion\",\"message\":\"request\",");
        CAT_LIT(buf, "\"method\":\"");
        rb_str_cat(buf, RSTRING_PTR(rb_method), RSTRING_LEN(rb_method));
        CAT_LIT(buf, "\",\"path\":\"");
        rb_str_cat(buf, RSTRING_PTR(rb_path), RSTRING_LEN(rb_path));
        CAT_LIT(buf, "\"");

        if (has_query) {
            CAT_LIT(buf, ",\"query\":\"");
            rb_str_cat(buf, RSTRING_PTR(rb_query), RSTRING_LEN(rb_query));
            CAT_LIT(buf, "\"");
        }

        char num[64];
        int n = snprintf(num, sizeof(num), ",\"status\":%d,\"duration_ms\":%g,",
                         status, dur_ms);
        rb_str_cat(buf, num, n);

        if (has_remote) {
            CAT_LIT(buf, "\"remote_addr\":\"");
            rb_str_cat(buf, RSTRING_PTR(rb_remote), RSTRING_LEN(rb_remote));
            CAT_LIT(buf, "\",");
        } else {
            CAT_LIT(buf, "\"remote_addr\":null,");
        }

        CAT_LIT(buf, "\"http_version\":\"");
        rb_str_cat(buf, RSTRING_PTR(rb_http_version), RSTRING_LEN(rb_http_version));
        CAT_LIT(buf, "\"}\n");
    } else {
        /* text: "<ts> INFO  [hyperion] message=request method=... path=... [query=...] status=... duration_ms=... remote_addr=... http_version=...\n" */
        rb_str_cat(buf, RSTRING_PTR(rb_ts), RSTRING_LEN(rb_ts));
        CAT_LIT(buf, " INFO  [hyperion] message=request method=");
        rb_str_cat(buf, RSTRING_PTR(rb_method), RSTRING_LEN(rb_method));
        CAT_LIT(buf, " path=");
        rb_str_cat(buf, RSTRING_PTR(rb_path), RSTRING_LEN(rb_path));

        if (has_query) {
            /* Mirror Logger#quote_if_needed: quote if value contains
             * whitespace, '"', or '='. Hot path skips quoting. */
            const char *q_ptr = RSTRING_PTR(rb_query);
            long q_len = RSTRING_LEN(rb_query);
            int need_quote = 0;
            for (long j = 0; j < q_len; j++) {
                char c = q_ptr[j];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
                    c == '"' || c == '=') {
                    need_quote = 1;
                    break;
                }
            }
            if (need_quote) {
                /* Defer to Ruby's String#inspect for correct quoting. */
                VALUE quoted = rb_funcall(rb_query, rb_intern("inspect"), 0);
                CAT_LIT(buf, " query=");
                rb_str_cat(buf, RSTRING_PTR(quoted), RSTRING_LEN(quoted));
            } else {
                CAT_LIT(buf, " query=");
                rb_str_cat(buf, q_ptr, q_len);
            }
        }

        char num[80];
        /* Use %g to match the existing Ruby format which interpolates
         * Float#to_s (no fixed precision). Status is an int. */
        int n = snprintf(num, sizeof(num), " status=%d duration_ms=%g remote_addr=",
                         status, dur_ms);
        rb_str_cat(buf, num, n);

        if (has_remote) {
            rb_str_cat(buf, RSTRING_PTR(rb_remote), RSTRING_LEN(rb_remote));
        } else {
            CAT_LIT(buf, "nil");
        }

        CAT_LIT(buf, " http_version=");
        rb_str_cat(buf, RSTRING_PTR(rb_http_version), RSTRING_LEN(rb_http_version));
        CAT_LIT(buf, "\n");
    }

    return buf;
}
#undef CAT_LIT

/* Hyperion::CParser.upcase_underscore(name) -> "HTTP_<UPCASED_UNDERSCORED>"
 *
 * Single-allocation replacement for `"HTTP_#{name.upcase.tr('-', '_')}"`.
 * Hot path on the Rack adapter: every uncached request header (any
 * `X-*` custom header) hits this on every request, and the Ruby version
 * spawns three String allocations (the upcase result, the tr result, and the
 * "HTTP_..." interpolation) plus a per-byte loop in tr.
 *
 * We allocate one Ruby String of length 5 + name.bytesize, fill it in a
 * single byte loop, return it. ASCII letters get OR'd with 0x20 inverted
 * (i.e. cleared bit 5 to upcase 'a'..'z'); '-' becomes '_'; everything else
 * passes through (header names are ASCII per RFC 9110, but multi-byte UTF-8
 * bytes pass through bytewise unmolested rather than crashing).
 *
 * Encoding is set to US-ASCII because Ruby's String#upcase on an ASCII-only
 * input returns a US-ASCII string, and the env-key lookup downstream is
 * encoding-agnostic anyway.
 */
static VALUE cupcase_underscore(VALUE self, VALUE rb_name) {
    (void)self;
    Check_Type(rb_name, T_STRING);

    const char *src = RSTRING_PTR(rb_name);
    long src_len    = RSTRING_LEN(rb_name);

    /* Single allocation: 5 prefix bytes + N source bytes. */
    VALUE out = rb_str_new(NULL, 5 + src_len);
    char *dst = RSTRING_PTR(out);

    dst[0] = 'H';
    dst[1] = 'T';
    dst[2] = 'T';
    dst[3] = 'P';
    dst[4] = '_';

    for (long i = 0; i < src_len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c >= 'a' && c <= 'z') {
            dst[5 + i] = (char)(c - 32);
        } else if (c == '-') {
            dst[5 + i] = '_';
        } else {
            dst[5 + i] = (char)c;
        }
    }

    rb_enc_associate(out, rb_usascii_encoding());
    /* Keep rb_name live across the loop above. RSTRING_PTR returns an
     * interior pointer that becomes invalid if the GC moves the source
     * String — unlikely on this tight path, but cheap insurance. */
    RB_GC_GUARD(rb_name);
    return out;
}

void Init_hyperion_http(void) {
    install_settings();

    rb_mHyperion         = rb_const_get(rb_cObject, rb_intern("Hyperion"));
    rb_cRequest          = rb_const_get(rb_mHyperion, rb_intern("Request"));
    rb_eParseError       = rb_const_get(rb_mHyperion, rb_intern("ParseError"));
    rb_eUnsupportedError = rb_const_get(rb_mHyperion, rb_intern("UnsupportedError"));

    rb_cCParser = rb_define_class_under(rb_mHyperion, "CParser", rb_cObject);
    rb_define_method(rb_cCParser, "parse", cparser_parse, 1);
    rb_define_singleton_method(rb_cCParser, "build_response_head",
                               cbuild_response_head, 6);
    rb_define_singleton_method(rb_cCParser, "build_access_line",
                               cbuild_access_line, 9);
    rb_define_singleton_method(rb_cCParser, "upcase_underscore",
                               cupcase_underscore, 1);

    id_new             = rb_intern("new");
    id_downcase        = rb_intern("downcase");
    id_method_kw       = rb_intern("method");
    id_path_kw         = rb_intern("path");
    id_query_string_kw = rb_intern("query_string");
    id_http_version_kw = rb_intern("http_version");
    id_headers_kw      = rb_intern("headers");
    id_body_kw         = rb_intern("body");
}
