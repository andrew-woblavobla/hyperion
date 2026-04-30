//! Hyperion HTTP/2 codec — Rust core, exposed to Ruby via extern "C".
//!
//! Phase 6a (HPACK encoder/decoder) is what 2.0.0 ships. Phase 6b
//! (frame ser/de) is wired through `frames.rs` but the integration
//! into `Http2Handler` reuses `protocol-http2`'s framer for now —
//! frame ser/de is microsecond-scale and not the bottleneck the bench
//! is calling out. HPACK encode is ~70% of the per-stream encoder
//! cost in the 1.x ruby-only path.
//!
//! The Ruby side calls these via Fiddle (see lib/hyperion/h2_codec.rb).
//! Memory model: encoders/decoders are owned Box pointers; Ruby holds
//! an opaque `void*` and explicitly frees via `*_free`. All byte
//! payloads are copied across the boundary — no shared mutable state.

#![allow(clippy::missing_safety_doc)]

mod hpack;
mod frames;

use std::os::raw::{c_int, c_uchar};
use std::os::raw::c_longlong;

/// Opaque handle exported to Ruby.
type EncoderHandle = *mut hpack::Encoder;
/// Opaque handle exported to Ruby.
type DecoderHandle = *mut hpack::Decoder;

// ---------- Encoder ----------

/// Allocate a new HPACK encoder. Returned pointer must be freed by
/// `hyperion_h2_codec_encoder_free`.
#[no_mangle]
pub extern "C" fn hyperion_h2_codec_encoder_new() -> EncoderHandle {
    Box::into_raw(Box::new(hpack::Encoder::new()))
}

/// Free an encoder handle.
#[no_mangle]
pub unsafe extern "C" fn hyperion_h2_codec_encoder_free(ptr: EncoderHandle) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr));
    }
}

/// Encode a header block. Inputs:
///   names_ptr/lens_ptr/count: parallel arrays describing the names
///   vals_ptr/vlens_ptr      : parallel arrays describing the values
///   out_ptr / out_capacity  : caller-provided output buffer
///
/// Returns the number of bytes written, or -1 on overflow / -2 on bad
/// arguments.
#[no_mangle]
pub unsafe extern "C" fn hyperion_h2_codec_encoder_encode(
    handle: EncoderHandle,
    names_ptr: *const *const c_uchar,
    name_lens: *const u32,
    vals_ptr: *const *const c_uchar,
    val_lens: *const u32,
    count: u32,
    out_ptr: *mut c_uchar,
    out_capacity: u32,
) -> c_int {
    if handle.is_null() || out_ptr.is_null() {
        return -2;
    }
    let encoder = &mut *handle;
    let mut buf = Vec::with_capacity(64 * count as usize);

    for i in 0..count as isize {
        let name_p = *names_ptr.offset(i);
        let name_l = *name_lens.offset(i) as usize;
        let val_p = *vals_ptr.offset(i);
        let val_l = *val_lens.offset(i) as usize;
        if name_p.is_null() || (val_p.is_null() && val_l > 0) {
            return -2;
        }
        let name = std::slice::from_raw_parts(name_p, name_l);
        let value = std::slice::from_raw_parts(val_p, val_l);
        encoder.encode_header(name, value, &mut buf);
    }

    if buf.len() > out_capacity as usize {
        return -1;
    }
    std::ptr::copy_nonoverlapping(buf.as_ptr(), out_ptr, buf.len());
    buf.len() as c_int
}

/// fix-B (2.2.x) — flat-blob encode ABI. Eliminates the per-header
/// allocation profile of the v1 entry point: callers pack the
/// concatenated names/values into ONE byte blob and a parallel array
/// of `(name_off, name_len, value_off, value_len)` u64 quads in
/// `argv_ptr`. The Rust side indexes into the blob via offsets — no
/// per-header `Fiddle::Pointer.new` on the Ruby side, no per-header
/// `pack('Q*')`.
///
/// Inputs:
/// * `handle`            — encoder handle (preserved across calls; dyn table state)
/// * `headers_blob_ptr`  — concatenated bytes (name_1, value_1, name_2, value_2, …)
/// * `headers_blob_len`  — length of the blob in bytes
/// * `argv_ptr`          — pointer to `argv_count * 4` little-endian u64s
/// * `argv_count`        — number of header pairs
/// * `out_ptr`           — caller-provided output buffer
/// * `out_capacity`      — bytes available at `out_ptr`
///
/// Returns the number of bytes written, or:
///   -1 = output buffer overflow
///   -2 = bad arguments (null pointer, offset/length out of blob bounds)
///
/// Old `hyperion_h2_codec_encoder_encode` ABI symbol is **preserved
/// unchanged** above for backwards compatibility — older Ruby loaders
/// that still call it continue to work; the in-tree Ruby wrapper
/// switches to v2 at the FFI boundary.
#[no_mangle]
pub unsafe extern "C" fn hyperion_h2_codec_encoder_encode_v2(
    handle: EncoderHandle,
    headers_blob_ptr: *const c_uchar,
    headers_blob_len: usize,
    argv_ptr: *const u64,
    argv_count: usize,
    out_ptr: *mut c_uchar,
    out_capacity: usize,
) -> c_longlong {
    if handle.is_null() || out_ptr.is_null() {
        return -2;
    }
    if argv_count > 0 && argv_ptr.is_null() {
        return -2;
    }
    if headers_blob_len > 0 && headers_blob_ptr.is_null() {
        return -2;
    }

    let encoder = &mut *handle;
    // Reuse the per-encoder scratch buffer instead of allocating a
    // fresh `Vec::with_capacity(64 * count)` per call. `clear()`
    // length-zeros without dropping the backing allocation.
    encoder.scratch.clear();

    let blob: &[u8] = if headers_blob_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(headers_blob_ptr, headers_blob_len)
    };
    let argv: &[u64] = if argv_count == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(argv_ptr, argv_count.saturating_mul(4))
    };

    // Move the scratch out of the encoder while we encode (so the
    // borrow checker lets us call &mut self methods that touch the
    // dyn table). This is a value swap — no allocation. We swap it
    // back at the end so the next call reuses the same allocation.
    let mut scratch = std::mem::take(&mut encoder.scratch);

    for i in 0..argv_count {
        let base = i.saturating_mul(4);
        let name_off = argv[base] as usize;
        let name_len = argv[base + 1] as usize;
        let val_off = argv[base + 2] as usize;
        let val_len = argv[base + 3] as usize;
        if name_off
            .checked_add(name_len)
            .map(|end| end > blob.len())
            .unwrap_or(true)
        {
            encoder.scratch = scratch;
            return -2;
        }
        if val_off
            .checked_add(val_len)
            .map(|end| end > blob.len())
            .unwrap_or(true)
        {
            encoder.scratch = scratch;
            return -2;
        }
        let name = &blob[name_off..name_off + name_len];
        let value = &blob[val_off..val_off + val_len];
        encoder.encode_header(name, value, &mut scratch);
    }

    let written = scratch.len();
    let result: c_longlong = if written > out_capacity {
        -1
    } else {
        std::ptr::copy_nonoverlapping(scratch.as_ptr(), out_ptr, written);
        written as c_longlong
    };

    // Restore the scratch (cleared on next call) so the allocation persists.
    encoder.scratch = scratch;
    result
}

// ---------- Decoder ----------

#[no_mangle]
pub extern "C" fn hyperion_h2_codec_decoder_new() -> DecoderHandle {
    Box::into_raw(Box::new(hpack::Decoder::new()))
}

#[no_mangle]
pub unsafe extern "C" fn hyperion_h2_codec_decoder_free(ptr: DecoderHandle) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr));
    }
}

/// Decode a header block. Output format: a flat byte buffer of
///   [u32 name_len][name bytes][u32 value_len][value bytes]
/// repeated. Returns total bytes written, or:
///   -1 = output buffer overflow
///   -2 = bad arguments
///   -3 = malformed HPACK input
#[no_mangle]
pub unsafe extern "C" fn hyperion_h2_codec_decoder_decode(
    handle: DecoderHandle,
    in_ptr: *const c_uchar,
    in_len: u32,
    out_ptr: *mut c_uchar,
    out_capacity: u32,
) -> c_int {
    if handle.is_null() || in_ptr.is_null() || out_ptr.is_null() {
        return -2;
    }
    let decoder = &mut *handle;
    let input = std::slice::from_raw_parts(in_ptr, in_len as usize);
    let headers = match decoder.decode(input) {
        Ok(h) => h,
        Err(_) => return -3,
    };

    let mut needed: usize = 0;
    for (n, v) in &headers {
        needed = needed.saturating_add(8 + n.len() + v.len());
    }
    if needed > out_capacity as usize {
        return -1;
    }

    let out = std::slice::from_raw_parts_mut(out_ptr, needed);
    let mut off = 0usize;
    for (n, v) in &headers {
        let nl = (n.len() as u32).to_le_bytes();
        out[off..off + 4].copy_from_slice(&nl);
        off += 4;
        out[off..off + n.len()].copy_from_slice(n);
        off += n.len();
        let vl = (v.len() as u32).to_le_bytes();
        out[off..off + 4].copy_from_slice(&vl);
        off += 4;
        out[off..off + v.len()].copy_from_slice(v);
        off += v.len();
    }
    needed as c_int
}

// ---------- Frame primitives (Phase 6b stub) ----------
//
// `frames.rs` is exposed for completeness and self-test; the
// production handler still drives `protocol-http2`'s framer for the
// connection state machine. When the bench shows frame ser/de is the
// next bottleneck we'll wire these in.

#[no_mangle]
pub unsafe extern "C" fn hyperion_h2_codec_encode_data_frame(
    stream_id: u32,
    end_stream: c_int,
    payload_ptr: *const c_uchar,
    payload_len: u32,
    out_ptr: *mut c_uchar,
    out_capacity: u32,
) -> c_int {
    if payload_ptr.is_null() || out_ptr.is_null() {
        return -2;
    }
    let payload = std::slice::from_raw_parts(payload_ptr, payload_len as usize);
    let frame =
        frames::encode_data_frame(stream_id, end_stream != 0, payload);
    if frame.len() > out_capacity as usize {
        return -1;
    }
    std::ptr::copy_nonoverlapping(frame.as_ptr(), out_ptr, frame.len());
    frame.len() as c_int
}

/// Smoke test entry — Ruby calls this in `available?` to confirm the
/// shared library loaded and the symbols resolve correctly. Returns
/// the codec ABI version (incremented on any breaking ABI change so
/// Ruby can refuse to load mismatched binaries).
#[no_mangle]
pub extern "C" fn hyperion_h2_codec_abi_version() -> u32 {
    1
}
