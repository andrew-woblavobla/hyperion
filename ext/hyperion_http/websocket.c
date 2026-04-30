/* ----------------------------------------------------------------------
 * Hyperion::WebSocket::CFrame — RFC 6455 frame ser/de in C.
 *
 * Public surface (defined as singleton methods on Hyperion::WebSocket::CFrame):
 *
 *   CFrame.unmask(payload, mask_key) -> String
 *     Input:  binary String `payload`, 4-byte binary String `mask_key`.
 *     Output: a freshly-allocated binary String of `payload.bytesize` bytes,
 *             XOR-unmasked with `mask_key` per RFC 6455 §5.3.
 *     Implementation: word-at-a-time XOR with the 4-byte key smeared into a
 *     uint32_t, then a 0..3-byte tail. GVL is released for payloads larger
 *     than 64 KiB so other fibers / threads can run while we crunch.
 *
 *   CFrame.parse(buf, offset = 0) ->
 *       [fin, opcode, payload_len, masked, mask_key, payload_offset,
 *        frame_total_len, rsv1]
 *     OR :incomplete OR :error
 *     Non-copying parser. Returns metadata only; the caller still owns
 *     `buf` and uses `payload_offset` + `frame_total_len` to slice or to
 *     advance to the next frame. `mask_key` is `nil` when `masked == false`.
 *     Returns `:incomplete` if `buf[offset..]` does not yet hold a full
 *     header. Returns `:error` for malformed frames (RSV2/RSV3 bits set,
 *     unknown opcode, control frame > 125 bytes, fragmented control
 *     frame, 64-bit length with high bit set, or RSV1 set on a control
 *     frame). RSV1 is preserved as the 8th tuple slot; the Ruby façade
 *     decides whether to treat it as a permessage-deflate marker (when
 *     the extension was negotiated) or as a protocol error (when it was
 *     not).
 *
 *   CFrame.build(opcode, payload, fin: true, mask: false, mask_key: nil,
 *                rsv1: false)
 *       -> String
 *     Builds a serialized frame ready for `socket.write`. Server frames are
 *     unmasked (`mask: false`, the default) per §5.1. Client frames must
 *     pass `mask: true` and a 4-byte `mask_key`. Control frames (close 0x8,
 *     ping 0x9, pong 0xA) MUST have `payload.bytesize <= 125` and MUST have
 *     `fin: true` and `rsv1: false` — this helper raises ArgumentError
 *     otherwise. Pass `rsv1: true` only on a text/binary frame whose
 *     payload is permessage-deflate compressed.
 *
 * Why C?
 *   The dominant CPU cost on the receive path is XOR-unmasking the
 *   payload. A tight uint32 loop in C is ~5–10× faster than Ruby's
 *   `unpack1('N*')` + manual XOR for typical 1 KiB–1 MiB messages.
 *   RFC 6455 framing itself is ~200 lines of C with no dependencies, so
 *   we keep parser+builder+unmask in one translation unit.
 * ---------------------------------------------------------------------- */

#include <ruby.h>
#include <ruby/thread.h>
#include <ruby/encoding.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Threshold above which CFrame.unmask releases the GVL. Below this,
 * the GVL-release ceremony itself costs more than the XOR work. */
#define HYP_WS_GVL_RELEASE_THRESHOLD (64 * 1024)

/* Control-frame payload cap per RFC 6455 §5.5. */
#define HYP_WS_CONTROL_MAX_PAYLOAD 125

static VALUE rb_mHyperion;
static VALUE rb_mHyperionWebSocket;
static VALUE rb_cCFrame;

static VALUE sym_incomplete;
static VALUE sym_error;

/* ------------------------------------------------------------------ */
/* Unmask                                                              */
/* ------------------------------------------------------------------ */

typedef struct {
    const uint8_t *src;
    uint8_t       *dst;
    size_t         len;
    uint32_t       key32; /* host-order uint32 with the 4 mask bytes smeared */
    uint8_t        key[4];
} unmask_args_t;

/* Core XOR loop.  Word-at-a-time for the body, byte-by-byte for the
 * 0..3-byte tail.  We deliberately avoid SIMD intrinsics — they don't
 * portably outperform a unaligned uint32 read+xor on the codegen path
 * GCC/Clang produce for this inner loop, and they'd hurt portability. */
static void hyp_ws_xor_inplace(unmask_args_t *a) {
    size_t   len = a->len;
    size_t   words = len / 4;
    size_t   tail  = len & 0x3;

    /* Use memcpy() to avoid strict-aliasing UB on the unaligned uint32
     * read. -O2 collapses the memcpy into a single mov on x86_64 and
     * arm64. */
    for (size_t i = 0; i < words; i++) {
        uint32_t v;
        memcpy(&v, a->src + i * 4, 4);
        v ^= a->key32;
        memcpy(a->dst + i * 4, &v, 4);
    }

    /* Tail: index into the original 4-byte key by absolute byte offset
     * mod 4, per RFC 6455 §5.3. */
    size_t base = words * 4;
    for (size_t i = 0; i < tail; i++) {
        a->dst[base + i] = a->src[base + i] ^ a->key[(base + i) & 0x3];
    }
}

static void *hyp_ws_xor_blocking(void *raw) {
    hyp_ws_xor_inplace((unmask_args_t *)raw);
    return NULL;
}

static VALUE rb_cframe_unmask(VALUE self, VALUE rb_payload, VALUE rb_key) {
    (void)self;

    Check_Type(rb_payload, T_STRING);
    Check_Type(rb_key, T_STRING);

    long key_len = RSTRING_LEN(rb_key);
    if (key_len != 4) {
        rb_raise(rb_eArgError,
                 "Hyperion::WebSocket::CFrame.unmask: mask_key must be exactly "
                 "4 bytes (got %ld)", key_len);
    }

    long payload_len = RSTRING_LEN(rb_payload);
    /* Empty payload — return an empty binary String of the right encoding. */
    if (payload_len == 0) {
        VALUE empty = rb_str_new(NULL, 0);
        rb_enc_associate(empty, rb_ascii8bit_encoding());
        return empty;
    }

    VALUE out = rb_str_new(NULL, payload_len);
    rb_enc_associate(out, rb_ascii8bit_encoding());

    unmask_args_t args;
    args.src = (const uint8_t *)RSTRING_PTR(rb_payload);
    args.dst = (uint8_t *)RSTRING_PTR(out);
    args.len = (size_t)payload_len;
    memcpy(args.key, RSTRING_PTR(rb_key), 4);
    /* Smear the 4 mask bytes into a host-order uint32. memcpy() handles
     * platform endianness — we treat the key as a stream of 4 bytes that
     * we want to apply at offsets {0,1,2,3,4,5,...} ≡ {0,1,2,3,0,1,2,3,...},
     * and reading 4 bytes at a time with memcpy preserves that pattern
     * independent of endianness. */
    memcpy(&args.key32, args.key, 4);

    if ((size_t)payload_len > HYP_WS_GVL_RELEASE_THRESHOLD) {
        rb_thread_call_without_gvl(hyp_ws_xor_blocking, &args, RUBY_UBF_IO, NULL);
    } else {
        hyp_ws_xor_inplace(&args);
    }

    /* Keep `rb_payload` and `out` alive across the GVL release. */
    RB_GC_GUARD(rb_payload);
    RB_GC_GUARD(rb_key);

    return out;
}

/* ------------------------------------------------------------------ */
/* Parse                                                               */
/* ------------------------------------------------------------------ */

/* Returns 1 if opcode is a control frame (0x8 close, 0x9 ping, 0xA pong),
 * 0 otherwise. Per §5.5 control opcodes are 0x8..0xF; 0xB..0xF are
 * reserved and rejected by the unknown-opcode check. */
static inline int hyp_ws_is_control(uint8_t opcode) {
    return opcode >= 0x8;
}

static inline int hyp_ws_is_known_opcode(uint8_t opcode) {
    /* 0x0 continuation, 0x1 text, 0x2 binary, 0x8 close, 0x9 ping, 0xA pong. */
    return opcode == 0x0 || opcode == 0x1 || opcode == 0x2 ||
           opcode == 0x8 || opcode == 0x9 || opcode == 0xA;
}

static VALUE rb_cframe_parse(int argc, VALUE *argv, VALUE self) {
    (void)self;

    VALUE rb_buf, rb_offset;
    rb_scan_args(argc, argv, "11", &rb_buf, &rb_offset);

    Check_Type(rb_buf, T_STRING);
    long offset = NIL_P(rb_offset) ? 0 : NUM2LONG(rb_offset);
    if (offset < 0) {
        rb_raise(rb_eArgError, "offset must be >= 0 (got %ld)", offset);
    }

    long buf_len = RSTRING_LEN(rb_buf);
    if (offset > buf_len) {
        return sym_incomplete;
    }

    long avail = buf_len - offset;
    if (avail < 2) {
        return sym_incomplete;
    }

    const uint8_t *p = (const uint8_t *)RSTRING_PTR(rb_buf) + offset;
    uint8_t b0 = p[0];
    uint8_t b1 = p[1];

    int     fin       = (b0 & 0x80) != 0;
    int     rsv1      = (b0 & 0x40) != 0;
    int     rsv2      = (b0 & 0x20) != 0;
    int     rsv3      = (b0 & 0x10) != 0;
    uint8_t opcode    = b0 & 0x0F;
    int     masked    = (b1 & 0x80) != 0;
    uint8_t len7      = b1 & 0x7F;

    /* RSV2/RSV3 are still reserved with no negotiated semantics; reject.
     * RSV1 is the permessage-deflate marker (RFC 7692 §6) — allow it to
     * pass through here so the Ruby façade can decide what to do based
     * on whether the extension was negotiated for this connection. The
     * Connection wrapper closes 1002 if it sees RSV1 without a
     * negotiated extension. RSV1 on a control frame is always a
     * protocol error per RFC 7692 §6.1 ("control frames MUST NOT be
     * compressed"); we trap that one case below. */
    if (rsv2 || rsv3) {
        return sym_error;
    }

    if (!hyp_ws_is_known_opcode(opcode)) {
        return sym_error;
    }

    /* §5.5 — control frames MUST have FIN=1 and len <= 125. RFC 7692
     * §6.1 — control frames MUST NOT have RSV1 set. */
    if (hyp_ws_is_control(opcode)) {
        if (!fin) {
            return sym_error;
        }
        if (len7 > HYP_WS_CONTROL_MAX_PAYLOAD) {
            return sym_error;
        }
        if (rsv1) {
            return sym_error;
        }
    }

    long header_len = 2;
    uint64_t payload_len64 = 0;

    if (len7 < 126) {
        payload_len64 = len7;
    } else if (len7 == 126) {
        if (avail < header_len + 2) return sym_incomplete;
        payload_len64 = ((uint64_t)p[2] << 8) | (uint64_t)p[3];
        header_len += 2;
    } else { /* len7 == 127 */
        if (avail < header_len + 8) return sym_incomplete;
        /* Network byte order; high bit MUST be 0 per RFC 6455 §5.2. */
        if (p[2] & 0x80) {
            return sym_error;
        }
        payload_len64 =
            ((uint64_t)p[2]  << 56) | ((uint64_t)p[3]  << 48) |
            ((uint64_t)p[4]  << 40) | ((uint64_t)p[5]  << 32) |
            ((uint64_t)p[6]  << 24) | ((uint64_t)p[7]  << 16) |
            ((uint64_t)p[8]  << 8)  |  (uint64_t)p[9];
        header_len += 8;
    }

    VALUE rb_mask_key = Qnil;
    if (masked) {
        if (avail < header_len + 4) return sym_incomplete;
        rb_mask_key = rb_str_new((const char *)(p + header_len), 4);
        rb_enc_associate(rb_mask_key, rb_ascii8bit_encoding());
        header_len += 4;
    }

    /* Bound payload_len64: a frame_total_len that overflows a Ruby
     * Integer is fine (Bignum), but we still want to make sure the
     * header_len + payload_len arithmetic below doesn't overflow size_t
     * on 32-bit hosts.  On 64-bit Linux/Darwin this is academic; the
     * cap is 2^63-1 and Ruby Strings can't be larger than LONG_MAX
     * anyway. */
    if (payload_len64 > (uint64_t)LONG_MAX - (uint64_t)header_len) {
        return sym_error;
    }

    /* Incomplete payload — the caller should buffer more bytes. */
    long payload_offset_abs = offset + header_len;
    long frame_total_len    = header_len + (long)payload_len64;
    if (avail < frame_total_len) {
        return sym_incomplete;
    }

    VALUE result = rb_ary_new_capa(8);
    rb_ary_push(result, fin ? Qtrue : Qfalse);
    rb_ary_push(result, INT2FIX(opcode));
    rb_ary_push(result, ULL2NUM(payload_len64));
    rb_ary_push(result, masked ? Qtrue : Qfalse);
    rb_ary_push(result, rb_mask_key);
    rb_ary_push(result, LONG2NUM(payload_offset_abs));
    rb_ary_push(result, LONG2NUM(frame_total_len));
    rb_ary_push(result, rsv1 ? Qtrue : Qfalse);

    RB_GC_GUARD(rb_buf);
    return result;
}

/* ------------------------------------------------------------------ */
/* Build                                                               */
/* ------------------------------------------------------------------ */

static ID id_kw_fin;
static ID id_kw_mask;
static ID id_kw_mask_key;
static ID id_kw_rsv1;

static VALUE rb_cframe_build(int argc, VALUE *argv, VALUE self) {
    (void)self;

    VALUE rb_opcode, rb_payload, rb_kwargs;
    rb_scan_args(argc, argv, "20:", &rb_opcode, &rb_payload, &rb_kwargs);

    long opcode_l = NUM2LONG(rb_opcode);
    if (opcode_l < 0 || opcode_l > 0xF) {
        rb_raise(rb_eArgError, "opcode must be 0..15 (got %ld)", opcode_l);
    }
    uint8_t opcode = (uint8_t)opcode_l;
    if (!hyp_ws_is_known_opcode(opcode)) {
        rb_raise(rb_eArgError, "unknown opcode 0x%x", (unsigned)opcode);
    }

    Check_Type(rb_payload, T_STRING);
    long payload_len = RSTRING_LEN(rb_payload);

    int fin  = 1;
    int mask = 0;
    int rsv1 = 0;
    VALUE rb_mask_key = Qnil;

    if (!NIL_P(rb_kwargs)) {
        VALUE kw_vals[4] = { Qundef, Qundef, Qundef, Qundef };
        ID    kw_ids[4]  = { id_kw_fin, id_kw_mask, id_kw_mask_key, id_kw_rsv1 };
        rb_get_kwargs(rb_kwargs, kw_ids, 0, 4, kw_vals);
        if (kw_vals[0] != Qundef) {
            fin = RTEST(kw_vals[0]) ? 1 : 0;
        }
        if (kw_vals[1] != Qundef) {
            mask = RTEST(kw_vals[1]) ? 1 : 0;
        }
        if (kw_vals[2] != Qundef) {
            rb_mask_key = kw_vals[2];
        }
        if (kw_vals[3] != Qundef) {
            rsv1 = RTEST(kw_vals[3]) ? 1 : 0;
        }
    }

    /* §5.5 control-frame validation. RFC 7692 §6.1 — control frames
     * MUST NOT have RSV1 set. */
    if (hyp_ws_is_control(opcode)) {
        if (!fin) {
            rb_raise(rb_eArgError,
                     "control frame (opcode 0x%x) MUST have fin=true",
                     (unsigned)opcode);
        }
        if (payload_len > HYP_WS_CONTROL_MAX_PAYLOAD) {
            rb_raise(rb_eArgError,
                     "control frame (opcode 0x%x) payload %ld exceeds 125-byte cap",
                     (unsigned)opcode, payload_len);
        }
        if (rsv1) {
            rb_raise(rb_eArgError,
                     "control frame (opcode 0x%x) MUST NOT have rsv1=true",
                     (unsigned)opcode);
        }
    }

    if (mask) {
        if (NIL_P(rb_mask_key)) {
            rb_raise(rb_eArgError, "mask: true requires a 4-byte mask_key");
        }
        Check_Type(rb_mask_key, T_STRING);
        if (RSTRING_LEN(rb_mask_key) != 4) {
            rb_raise(rb_eArgError, "mask_key must be exactly 4 bytes (got %ld)",
                     RSTRING_LEN(rb_mask_key));
        }
    }

    /* Compute header length. */
    long header_len = 2;
    if (payload_len < 126) {
        /* 7-bit length encoded inline. */
    } else if (payload_len <= 0xFFFF) {
        header_len += 2;
    } else {
        header_len += 8;
    }
    if (mask) header_len += 4;

    long frame_len = header_len + payload_len;
    VALUE out = rb_str_new(NULL, frame_len);
    rb_enc_associate(out, rb_ascii8bit_encoding());
    uint8_t *q = (uint8_t *)RSTRING_PTR(out);

    q[0] = (uint8_t)((fin ? 0x80 : 0x00) | (rsv1 ? 0x40 : 0x00) | (opcode & 0x0F));
    uint8_t mask_bit = mask ? 0x80 : 0x00;

    long body_offset;
    if (payload_len < 126) {
        q[1] = mask_bit | (uint8_t)payload_len;
        body_offset = 2;
    } else if (payload_len <= 0xFFFF) {
        q[1] = mask_bit | 126;
        q[2] = (uint8_t)((payload_len >> 8) & 0xFF);
        q[3] = (uint8_t)(payload_len & 0xFF);
        body_offset = 4;
    } else {
        q[1] = mask_bit | 127;
        uint64_t pl = (uint64_t)payload_len;
        q[2] = (uint8_t)((pl >> 56) & 0xFF);
        q[3] = (uint8_t)((pl >> 48) & 0xFF);
        q[4] = (uint8_t)((pl >> 40) & 0xFF);
        q[5] = (uint8_t)((pl >> 32) & 0xFF);
        q[6] = (uint8_t)((pl >> 24) & 0xFF);
        q[7] = (uint8_t)((pl >> 16) & 0xFF);
        q[8] = (uint8_t)((pl >> 8)  & 0xFF);
        q[9] = (uint8_t)(pl & 0xFF);
        body_offset = 10;
    }

    if (mask) {
        memcpy(q + body_offset, RSTRING_PTR(rb_mask_key), 4);
        body_offset += 4;
    }

    if (payload_len > 0) {
        if (mask) {
            /* Reuse the unmask kernel — XOR is symmetric. */
            unmask_args_t args;
            args.src = (const uint8_t *)RSTRING_PTR(rb_payload);
            args.dst = q + body_offset;
            args.len = (size_t)payload_len;
            memcpy(args.key, RSTRING_PTR(rb_mask_key), 4);
            memcpy(&args.key32, args.key, 4);
            if ((size_t)payload_len > HYP_WS_GVL_RELEASE_THRESHOLD) {
                rb_thread_call_without_gvl(hyp_ws_xor_blocking, &args, RUBY_UBF_IO, NULL);
            } else {
                hyp_ws_xor_inplace(&args);
            }
        } else {
            memcpy(q + body_offset, RSTRING_PTR(rb_payload), (size_t)payload_len);
        }
    }

    RB_GC_GUARD(rb_payload);
    RB_GC_GUARD(rb_mask_key);
    return out;
}

/* ------------------------------------------------------------------ */
/* Init                                                                */
/* ------------------------------------------------------------------ */

void Init_hyperion_websocket(void) {
    rb_mHyperion = rb_const_get(rb_cObject, rb_intern("Hyperion"));

    if (rb_const_defined(rb_mHyperion, rb_intern("WebSocket"))) {
        rb_mHyperionWebSocket = rb_const_get(rb_mHyperion, rb_intern("WebSocket"));
    } else {
        rb_mHyperionWebSocket = rb_define_module_under(rb_mHyperion, "WebSocket");
    }

    rb_cCFrame = rb_define_module_under(rb_mHyperionWebSocket, "CFrame");

    rb_define_singleton_method(rb_cCFrame, "unmask", rb_cframe_unmask, 2);
    rb_define_singleton_method(rb_cCFrame, "parse",  rb_cframe_parse, -1);
    rb_define_singleton_method(rb_cCFrame, "build",  rb_cframe_build, -1);

    sym_incomplete = ID2SYM(rb_intern("incomplete"));
    sym_error      = ID2SYM(rb_intern("error"));
    rb_gc_register_mark_object(sym_incomplete);
    rb_gc_register_mark_object(sym_error);

    id_kw_fin      = rb_intern("fin");
    id_kw_mask     = rb_intern("mask");
    id_kw_mask_key = rb_intern("mask_key");
    id_kw_rsv1     = rb_intern("rsv1");

    /* Expose constants for the Ruby façade & specs. */
    rb_define_const(rb_cCFrame, "GVL_RELEASE_THRESHOLD",
                    INT2NUM(HYP_WS_GVL_RELEASE_THRESHOLD));
    rb_define_const(rb_cCFrame, "CONTROL_MAX_PAYLOAD",
                    INT2NUM(HYP_WS_CONTROL_MAX_PAYLOAD));
}
