//! HTTP/2 frame primitives (RFC 7540 §6).
//!
//! Phase 6a only ships the simplest frame types the writer fiber
//! needs in the response path: HEADERS, DATA, RST_STREAM, WINDOW_UPDATE.
//! The h2 connection state machine continues to be driven by
//! `protocol-http2` for now — we just expose the wire-formatting
//! primitives so a future Phase 6b can replace the Ruby-side framer.

use std::fmt;

/// HPACK error type, shared between encoder/decoder. Public so the
/// FFI layer can surface a numeric code to Ruby.
#[derive(Debug)]
pub enum HpackError {
    Truncated,
    Overflow,
    BadIndex,
    ZeroIndex,
    HuffmanInvalid,
}

impl fmt::Display for HpackError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HpackError::Truncated => write!(f, "truncated input"),
            HpackError::Overflow => write!(f, "integer overflow"),
            HpackError::BadIndex => write!(f, "invalid HPACK index"),
            HpackError::ZeroIndex => write!(f, "HPACK index 0 is reserved"),
            HpackError::HuffmanInvalid => write!(f, "invalid Huffman sequence"),
        }
    }
}

// Frame type constants. RFC 7540 §11.2 / RFC 9113 §6.
// Some are unused by the Phase 6a wire path but ship now so that the
// FFI surface, when expanded in Phase 6b, doesn't churn ABI numbers.
#[allow(dead_code)]
pub const FRAME_DATA: u8 = 0x0;
#[allow(dead_code)]
pub const FRAME_HEADERS: u8 = 0x1;
#[allow(dead_code)]
pub const FRAME_RST_STREAM: u8 = 0x3;
#[allow(dead_code)]
pub const FRAME_SETTINGS: u8 = 0x4;
#[allow(dead_code)]
pub const FRAME_PING: u8 = 0x6;
#[allow(dead_code)]
pub const FRAME_GOAWAY: u8 = 0x7;
#[allow(dead_code)]
pub const FRAME_WINDOW_UPDATE: u8 = 0x8;
#[allow(dead_code)]
pub const FRAME_CONTINUATION: u8 = 0x9;

#[allow(dead_code)]
pub const FLAG_END_STREAM: u8 = 0x1;
#[allow(dead_code)]
pub const FLAG_END_HEADERS: u8 = 0x4;

/// 9-byte frame header + payload writer (RFC 7540 §4.1).
fn write_frame_header(out: &mut Vec<u8>, len: u32, kind: u8, flags: u8, stream_id: u32) {
    out.push(((len >> 16) & 0xff) as u8);
    out.push(((len >> 8) & 0xff) as u8);
    out.push((len & 0xff) as u8);
    out.push(kind);
    out.push(flags);
    let sid = stream_id & 0x7fff_ffff; // R-bit cleared per spec
    out.push(((sid >> 24) & 0xff) as u8);
    out.push(((sid >> 16) & 0xff) as u8);
    out.push(((sid >> 8) & 0xff) as u8);
    out.push((sid & 0xff) as u8);
}

pub fn encode_data_frame(stream_id: u32, end_stream: bool, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(9 + payload.len());
    let flags = if end_stream { FLAG_END_STREAM } else { 0 };
    write_frame_header(&mut out, payload.len() as u32, FRAME_DATA, flags, stream_id);
    out.extend_from_slice(payload);
    out
}

#[allow(dead_code)]
pub fn encode_headers_frame(
    stream_id: u32,
    end_stream: bool,
    end_headers: bool,
    block: &[u8],
) -> Vec<u8> {
    let mut out = Vec::with_capacity(9 + block.len());
    let mut flags = 0u8;
    if end_stream {
        flags |= FLAG_END_STREAM;
    }
    if end_headers {
        flags |= FLAG_END_HEADERS;
    }
    write_frame_header(&mut out, block.len() as u32, FRAME_HEADERS, flags, stream_id);
    out.extend_from_slice(block);
    out
}

#[allow(dead_code)]
pub fn encode_rst_stream(stream_id: u32, error_code: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(9 + 4);
    write_frame_header(&mut out, 4, FRAME_RST_STREAM, 0, stream_id);
    out.extend_from_slice(&error_code.to_be_bytes());
    out
}

#[allow(dead_code)]
pub fn encode_window_update(stream_id: u32, increment: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(9 + 4);
    let inc = increment & 0x7fff_ffff;
    write_frame_header(&mut out, 4, FRAME_WINDOW_UPDATE, 0, stream_id);
    out.extend_from_slice(&inc.to_be_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_frame_layout() {
        let frame = encode_data_frame(1, true, b"hello");
        // 9-byte header: 00 00 05 00 01 00 00 00 01
        assert_eq!(frame[0..3], [0, 0, 5]);
        assert_eq!(frame[3], FRAME_DATA);
        assert_eq!(frame[4], FLAG_END_STREAM);
        assert_eq!(u32::from_be_bytes([frame[5], frame[6], frame[7], frame[8]]), 1);
        assert_eq!(&frame[9..], b"hello");
    }

    #[test]
    fn rst_stream_layout() {
        let frame = encode_rst_stream(3, 0xa);
        assert_eq!(frame[3], FRAME_RST_STREAM);
        assert_eq!(u32::from_be_bytes([frame[5], frame[6], frame[7], frame[8]]), 3);
        assert_eq!(u32::from_be_bytes([frame[9], frame[10], frame[11], frame[12]]), 0xa);
    }
}
