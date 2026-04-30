/* ----------------------------------------------------------------------
 * Hyperion::H2Codec::CGlue — direct C → Rust bridge for HPACK encode/decode.
 *
 * 2.4-A (RFC §3 2.4.0) — round-2 FFI marshalling. The 2.0.0 path used
 * Fiddle::Pointer per call (`Fiddle::Pointer[bytes]` allocates a Ruby
 * object for each pointer wrapper). The 2.2.x fix-B path collapsed
 * argv encoding into a single `pack('Q*', buffer:)` and reused scratch
 * buffers, which trimmed per-call alloc from ~12 strings to ~7.5.
 *
 * The remaining ~7.5 strings/call sat in the Fiddle layer:
 *
 *   1. `pack('Q*', buffer: scratch_argv)`     — ~1 alloc
 *   2. `Fiddle::Pointer[scratch_blob/argv/out]` — 3 wrappers/call
 *   3. Per-header `name.b` / `value.b` (when source isn't ASCII-8BIT)
 *
 * 2.4-A bypasses Fiddle entirely on the per-call hot path. Ruby calls
 * `Hyperion::H2Codec::CGlue.encoder_encode_v3(handle_long, headers, scratch_out)`
 * which:
 *
 *   * walks `headers` in-place, building a packed argv buffer
 *     (4×u64 per header) on the C stack (or a heap-allocated growable
 *     buffer if there are >256 headers);
 *   * concatenates name+value bytes into the C-side blob buffer (also
 *     stack-resident with heap fallback);
 *   * directly invokes the cached `hyperion_h2_codec_encoder_encode_v2`
 *     function pointer (resolved at install time via `dlsym`);
 *   * truncates `scratch_out` to the bytes-written count via
 *     `rb_str_set_len`, returning the count to Ruby. Ruby's wrapper
 *     does the single unavoidable allocation: `byteslice(0, n)` to
 *     hand back the encoded frame as an owned String.
 *
 * Per-call allocations (steady state, no header table growth):
 *   * 1 String for the byteslice return.
 *   * That's it. argv/blob are stack-resident.
 *
 * Fiddle still owns the build-time loader path: `H2Codec.load!` opens
 * the cdylib via `Fiddle.dlopen` exactly as before, then calls
 * `CGlue.install(path_string)` to hand the cdylib path off to this
 * C unit. We re-`dlopen` it with `RTLD_NOLOAD | RTLD_NOW` (or just
 * `RTLD_NOW` on macOS where NOLOAD isn't honoured the same way) so
 * we get a `void *handle` we can `dlsym` on. The encoder/decoder
 * `_new`/`_free` Rust funcs are still called via Fiddle on the
 * one-time ctor/dtor — only encode/decode is on the hot path.
 *
 * If `dlopen`/`dlsym` fail (or the .so isn't present), `Init_hyperion_h2_codec_glue`
 * leaves `CGlue.available?` returning `false` and Ruby falls back to
 * the v2 (Fiddle) path automatically.
 *
 * Why a separate `_v3` Ruby method instead of replacing v2?
 *   * Lets the v2 Fiddle path remain as a drop-in fallback when CGlue
 *     fails to load (older glibc, hardened sandbox blocking dlopen).
 *   * Spec parity check ("v3 and v2 produce identical decoded
 *     headers") catches any C-side argv-packing regression before it
 *     hits production traffic.
 * ---------------------------------------------------------------------- */

#include <ruby.h>
#include <ruby/encoding.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

/* ------------------------------------------------------------------ */
/* Cached Rust function pointers + module/class globals.              */
/* ------------------------------------------------------------------ */

static VALUE rb_mHyperion;
static VALUE rb_mH2Codec;
static VALUE rb_mCGlue;
static VALUE rb_eOutputOverflow;

/* Match the Rust ABI from ext/hyperion_h2_codec/src/lib.rs. */
typedef long long (*rust_encode_v2_fn)(
    void *handle,
    const unsigned char *blob_ptr, size_t blob_len,
    const uint64_t *argv_ptr, size_t argv_count,
    unsigned char *out_ptr, size_t out_capacity);

typedef int (*rust_decode_fn)(
    void *handle,
    const unsigned char *in_ptr, unsigned int in_len,
    unsigned char *out_ptr, unsigned int out_capacity);

typedef unsigned int (*rust_abi_version_fn)(void);

static void               *rust_dl_handle    = NULL;
static rust_encode_v2_fn   rust_encode_v2    = NULL;
static rust_decode_fn      rust_decode       = NULL;
static rust_abi_version_fn rust_abi_version  = NULL;
static int                 cglue_available   = 0;

/* Stack-resident argv/blob caps. 99% of HEADERS frames have <= 32
 * pairs and total name+value bytes < 4 KiB, so these defaults handle
 * the steady state without touching the heap. Above this we malloc
 * a one-shot growable buffer (still cheaper than a Ruby allocation
 * because no GC pressure). */
#define HYP_GLUE_STACK_ARGV_CAP   64    /* 64 headers × 4×u64 = 2 KiB */
#define HYP_GLUE_STACK_BLOB_CAP   8192  /* 8 KiB total name+value bytes */

/* ------------------------------------------------------------------ */
/* CGlue.install(path)  -> true on success, false otherwise            */
/*                                                                     */
/* Called once from `Hyperion::H2Codec.load!` after Fiddle has         */
/* probed the candidate paths and confirmed the cdylib loads. We       */
/* dlopen the same path independently so we get our own handle to      */
/* dlsym against — re-dlopen with the same path is a no-op refcount    */
/* bump per POSIX semantics, so this doesn't double-load the .so.      */
/* ------------------------------------------------------------------ */
static VALUE rb_cglue_install(VALUE self, VALUE rb_path) {
    (void)self;
    Check_Type(rb_path, T_STRING);

    if (cglue_available) {
        /* Idempotent — second call is a no-op. */
        return Qtrue;
    }

    const char *path = StringValueCStr(rb_path);
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        return Qfalse;
    }

    rust_abi_version_fn abi_fn =
        (rust_abi_version_fn)dlsym(h, "hyperion_h2_codec_abi_version");
    rust_encode_v2_fn enc_fn =
        (rust_encode_v2_fn)dlsym(h, "hyperion_h2_codec_encoder_encode_v2");
    rust_decode_fn dec_fn =
        (rust_decode_fn)dlsym(h, "hyperion_h2_codec_decoder_decode");

    if (!abi_fn || !enc_fn || !dec_fn) {
        dlclose(h);
        return Qfalse;
    }

    /* ABI 1 is the only version currently shipped. If a future Rust
     * crate bumps the ABI, this guard prevents the v3 path from
     * silently dispatching to a mismatched layout. The v2 (Fiddle)
     * path has its own ABI check. */
    if (abi_fn() != 1) {
        dlclose(h);
        return Qfalse;
    }

    rust_dl_handle   = h;
    rust_abi_version = abi_fn;
    rust_encode_v2   = enc_fn;
    rust_decode      = dec_fn;
    cglue_available  = 1;
    return Qtrue;
}

static VALUE rb_cglue_available_p(VALUE self) {
    (void)self;
    return cglue_available ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------ */
/* CGlue.encoder_encode_v3(handle_addr, headers_array, scratch_out)    */
/*                                                                     */
/* Per-call allocations: ZERO from C; ONE String alloc happens in       */
/* Ruby for the byteslice return at the call site.                     */
/*                                                                     */
/* Returns: Integer bytes_written. Raises on overflow / bad args.      */
/* ------------------------------------------------------------------ */
static VALUE rb_cglue_encoder_encode_v3(VALUE self,
                                        VALUE rb_handle_addr,
                                        VALUE rb_headers,
                                        VALUE rb_scratch_out) {
    (void)self;

    if (!cglue_available || !rust_encode_v2) {
        rb_raise(rb_eRuntimeError,
                 "Hyperion::H2Codec::CGlue not installed (call .install(path) first)");
    }

    Check_Type(rb_headers, T_ARRAY);
    Check_Type(rb_scratch_out, T_STRING);

    void *handle = (void *)(intptr_t)NUM2LL(rb_handle_addr);
    long count = RARRAY_LEN(rb_headers);
    if (count == 0) {
        return INT2FIX(0);
    }

    /* Stack buffers — heap fallback for unusually large header sets. */
    uint64_t  stack_argv[HYP_GLUE_STACK_ARGV_CAP * 4];
    uint8_t   stack_blob[HYP_GLUE_STACK_BLOB_CAP];

    uint64_t *argv = stack_argv;
    uint8_t  *blob = stack_blob;
    int       argv_on_heap = 0;
    int       blob_on_heap = 0;
    size_t    argv_cap     = HYP_GLUE_STACK_ARGV_CAP;
    size_t    blob_cap     = HYP_GLUE_STACK_BLOB_CAP;

    if ((size_t)count > argv_cap) {
        argv = (uint64_t *)malloc((size_t)count * 4 * sizeof(uint64_t));
        if (!argv) {
            rb_raise(rb_eNoMemError, "H2Codec::CGlue argv malloc failed");
        }
        argv_cap = (size_t)count;
        argv_on_heap = 1;
    }

    /* First pass: compute total blob size to decide stack vs heap. */
    size_t total_blob = 0;
    for (long i = 0; i < count; i++) {
        VALUE pair = rb_ary_entry(rb_headers, i);
        if (TYPE(pair) != T_ARRAY || RARRAY_LEN(pair) < 2) {
            if (argv_on_heap) free(argv);
            rb_raise(rb_eArgError,
                     "H2Codec::CGlue.encode_v3: each header must be a [name, value] array");
        }
        VALUE name  = rb_ary_entry(pair, 0);
        VALUE value = rb_ary_entry(pair, 1);
        if (TYPE(name) != T_STRING || TYPE(value) != T_STRING) {
            if (argv_on_heap) free(argv);
            rb_raise(rb_eTypeError,
                     "H2Codec::CGlue.encode_v3: header name and value must be Strings");
        }
        total_blob += (size_t)RSTRING_LEN(name);
        total_blob += (size_t)RSTRING_LEN(value);
    }

    if (total_blob > blob_cap) {
        blob = (uint8_t *)malloc(total_blob);
        if (!blob) {
            if (argv_on_heap) free(argv);
            rb_raise(rb_eNoMemError, "H2Codec::CGlue blob malloc failed");
        }
        blob_cap = total_blob;
        blob_on_heap = 1;
    }

    /* Second pass: pack argv quads + concatenate blob. We *do not*
     * call `name.b` / `value.b` here even when the source encoding
     * isn't ASCII_8BIT — HPACK only cares about the byte sequence.
     * `RSTRING_PTR` + `RSTRING_LEN` give us the raw byte view
     * regardless of the Ruby encoding tag, which avoids a per-header
     * String allocation that the v2 Ruby path could not avoid for
     * non-binary inputs. */
    size_t blob_off = 0;
    for (long i = 0; i < count; i++) {
        VALUE pair  = rb_ary_entry(rb_headers, i);
        VALUE name  = rb_ary_entry(pair, 0);
        VALUE value = rb_ary_entry(pair, 1);

        size_t nl = (size_t)RSTRING_LEN(name);
        size_t vl = (size_t)RSTRING_LEN(value);

        size_t base = (size_t)i * 4;
        argv[base + 0] = (uint64_t)blob_off;
        argv[base + 1] = (uint64_t)nl;
        argv[base + 2] = (uint64_t)(blob_off + nl);
        argv[base + 3] = (uint64_t)vl;

        if (nl > 0) {
            memcpy(blob + blob_off, RSTRING_PTR(name), nl);
        }
        blob_off += nl;
        if (vl > 0) {
            memcpy(blob + blob_off, RSTRING_PTR(value), vl);
        }
        blob_off += vl;
    }

    /* Make sure scratch_out has at least `out_capacity` bytes of
     * usable buffer space. Ruby pre-sized it via `String.new(capacity:)`
     * + `<<` to set the length, so RSTRING_LEN reflects the full
     * usable region (we'll truncate to `written` after the FFI call).
     */
    size_t out_capacity = (size_t)RSTRING_LEN(rb_scratch_out);
    /* rb_str_modify ensures the scratch String is mutable, has its own
     * (unshared) backing buffer, and that RSTRING_PTR is valid for
     * out_capacity bytes of writes. Required before we hand its raw
     * pointer to Rust. */
    rb_str_modify(rb_scratch_out);
    unsigned char *out_ptr = (unsigned char *)RSTRING_PTR(rb_scratch_out);

    long long written = rust_encode_v2(handle,
                                       blob, blob_off,
                                       argv, (size_t)count,
                                       out_ptr, out_capacity);

    if (argv_on_heap) free(argv);
    if (blob_on_heap) free(blob);

    /* Keep the headers array alive across the FFI call — RSTRING_PTR
     * pointers we read from `name`/`value` are only valid while their
     * VALUEs are live and unmoved. */
    RB_GC_GUARD(rb_headers);
    RB_GC_GUARD(rb_scratch_out);

    if (written == -1) {
        rb_raise(rb_eOutputOverflow,
                 "Hyperion::H2Codec::CGlue.encode_v3 output buffer overflow "
                 "(capacity=%zu)", out_capacity);
    }
    if (written < 0) {
        rb_raise(rb_eRuntimeError,
                 "Hyperion::H2Codec::CGlue.encode_v3 failed (rc=%lld)", written);
    }

    /* Truncate the scratch String to the bytes-written count. The
     * caller's Ruby wrapper then `byteslice(0, written)`s it — that
     * single byteslice is the only String alloc per encode call. */
    rb_str_set_len(rb_scratch_out, (long)written);
    return LL2NUM(written);
}

/* ------------------------------------------------------------------ */
/* CGlue.decoder_decode_v3(handle_addr, bytes_str, scratch_out)         */
/*                                                                     */
/* The decoder side is less hot than encode (responses are encode-     */
/* heavy), but the same Fiddle-layer overhead applies on h2 request    */
/* dispatch. Same direct C → Rust path.                                */
/* ------------------------------------------------------------------ */
static VALUE rb_cglue_decoder_decode_v3(VALUE self,
                                        VALUE rb_handle_addr,
                                        VALUE rb_bytes,
                                        VALUE rb_scratch_out) {
    (void)self;

    if (!cglue_available || !rust_decode) {
        rb_raise(rb_eRuntimeError,
                 "Hyperion::H2Codec::CGlue not installed (call .install(path) first)");
    }

    Check_Type(rb_bytes, T_STRING);
    Check_Type(rb_scratch_out, T_STRING);

    void *handle = (void *)(intptr_t)NUM2LL(rb_handle_addr);

    long in_len = RSTRING_LEN(rb_bytes);
    if (in_len == 0) {
        rb_str_set_len(rb_scratch_out, 0);
        return INT2FIX(0);
    }

    rb_str_modify(rb_scratch_out);
    long out_capacity = RSTRING_LEN(rb_scratch_out);

    int written = rust_decode(handle,
                              (const unsigned char *)RSTRING_PTR(rb_bytes),
                              (unsigned int)in_len,
                              (unsigned char *)RSTRING_PTR(rb_scratch_out),
                              (unsigned int)out_capacity);

    RB_GC_GUARD(rb_bytes);
    RB_GC_GUARD(rb_scratch_out);

    if (written == -1) {
        rb_raise(rb_eOutputOverflow,
                 "Hyperion::H2Codec::CGlue.decode_v3 output buffer overflow "
                 "(capacity=%ld)", out_capacity);
    }
    if (written < 0) {
        rb_raise(rb_eRuntimeError,
                 "Hyperion::H2Codec::CGlue.decode_v3 failed (rc=%d)", written);
    }

    rb_str_set_len(rb_scratch_out, (long)written);
    return INT2NUM(written);
}

/* ------------------------------------------------------------------ */
/* Init                                                                */
/* ------------------------------------------------------------------ */

void Init_hyperion_h2_codec_glue(void) {
    rb_mHyperion = rb_const_get(rb_cObject, rb_intern("Hyperion"));

    /* `Hyperion::H2Codec` may not be defined yet at C-init time — its
     * Ruby file is loaded lazily by the gem entry point. Define it
     * here as an empty module placeholder if needed; the Ruby file
     * will reopen it. */
    if (rb_const_defined(rb_mHyperion, rb_intern("H2Codec"))) {
        rb_mH2Codec = rb_const_get(rb_mHyperion, rb_intern("H2Codec"));
    } else {
        rb_mH2Codec = rb_define_module_under(rb_mHyperion, "H2Codec");
    }

    rb_mCGlue = rb_define_module_under(rb_mH2Codec, "CGlue");

    /* OutputOverflow is defined in lib/hyperion/h2_codec.rb (Ruby
     * side). If the Ruby file loaded first we reuse it; otherwise we
     * define a placeholder that the Ruby file's class definition
     * re-opens (it's a `class OutputOverflow < StandardError; end`
     * so re-opening is safe). */
    if (rb_const_defined(rb_mH2Codec, rb_intern("OutputOverflow"))) {
        rb_eOutputOverflow = rb_const_get(rb_mH2Codec, rb_intern("OutputOverflow"));
    } else {
        rb_eOutputOverflow = rb_define_class_under(rb_mH2Codec,
                                                   "OutputOverflow",
                                                   rb_eStandardError);
    }
    rb_global_variable(&rb_eOutputOverflow);

    rb_define_singleton_method(rb_mCGlue, "install",       rb_cglue_install,           1);
    rb_define_singleton_method(rb_mCGlue, "available?",    rb_cglue_available_p,       0);
    rb_define_singleton_method(rb_mCGlue, "encoder_encode_v3",
                               rb_cglue_encoder_encode_v3, 3);
    rb_define_singleton_method(rb_mCGlue, "decoder_decode_v3",
                               rb_cglue_decoder_decode_v3, 3);
}
