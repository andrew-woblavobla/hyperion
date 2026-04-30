//! Pure-Rust HPACK (RFC 7541) encoder + decoder.
//!
//! Scope:
//! - Static table (61 entries from RFC 7541 Appendix A).
//! - Indexed Header Field encoding when name+value match a static slot.
//! - Indexed Header Field encoding when name+value match a *dynamic*
//!   slot (Phase 10, RFC §3 Phase 6c) — closes the wire-bytes gap
//!   with protocol-hpack on repeated headers, which is what makes
//!   wiring the codec into the hot path actually faster.
//! - Indexed-Name + Literal Value with incremental indexing (`0x40`)
//!   when name matches a static OR dynamic slot, AND for wholly-novel
//!   names (so future repeats hit the indexed path).
//! - We deliberately do NOT emit Huffman-encoded strings — h2
//!   conformance allows raw octets and the wire-size win on
//!   server-side response headers is small (<10% on real workloads).
//!
//! The decoder is the operationally important half: clients (browsers,
//! curl, h2load) routinely Huffman-encode their request headers, so we
//! must round-trip those. RFC 7541 Appendix B Huffman codes are
//! embedded inline in `huffman.rs`.
//!
//! Dynamic table: maintained per-encoder/per-decoder, default 4096
//! bytes (RFC 7541 §6.5).

use crate::frames::HpackError;

mod huffman;

// ---- Static table (RFC 7541 Appendix A). 1-indexed in the spec; we
// store at offset 0 = entry 1 to keep encoder math readable.
const STATIC_TABLE: &[(&[u8], &[u8])] = &[
    (b":authority", b""),
    (b":method", b"GET"),
    (b":method", b"POST"),
    (b":path", b"/"),
    (b":path", b"/index.html"),
    (b":scheme", b"http"),
    (b":scheme", b"https"),
    (b":status", b"200"),
    (b":status", b"204"),
    (b":status", b"206"),
    (b":status", b"304"),
    (b":status", b"400"),
    (b":status", b"404"),
    (b":status", b"500"),
    (b"accept-charset", b""),
    (b"accept-encoding", b"gzip, deflate"),
    (b"accept-language", b""),
    (b"accept-ranges", b""),
    (b"accept", b""),
    (b"access-control-allow-origin", b""),
    (b"age", b""),
    (b"allow", b""),
    (b"authorization", b""),
    (b"cache-control", b""),
    (b"content-disposition", b""),
    (b"content-encoding", b""),
    (b"content-language", b""),
    (b"content-length", b""),
    (b"content-location", b""),
    (b"content-range", b""),
    (b"content-type", b""),
    (b"cookie", b""),
    (b"date", b""),
    (b"etag", b""),
    (b"expect", b""),
    (b"expires", b""),
    (b"from", b""),
    (b"host", b""),
    (b"if-match", b""),
    (b"if-modified-since", b""),
    (b"if-none-match", b""),
    (b"if-range", b""),
    (b"if-unmodified-since", b""),
    (b"last-modified", b""),
    (b"link", b""),
    (b"location", b""),
    (b"max-forwards", b""),
    (b"proxy-authenticate", b""),
    (b"proxy-authorization", b""),
    (b"range", b""),
    (b"referer", b""),
    (b"refresh", b""),
    (b"retry-after", b""),
    (b"server", b""),
    (b"set-cookie", b""),
    (b"strict-transport-security", b""),
    (b"transfer-encoding", b""),
    (b"user-agent", b""),
    (b"vary", b""),
    (b"via", b""),
    (b"www-authenticate", b""),
];

const STATIC_TABLE_LEN: usize = STATIC_TABLE.len(); // 61

// ---- Dynamic table entry. Owned bytes, sized per RFC 7541 §4.1.
#[derive(Clone)]
struct DynEntry {
    name: Vec<u8>,
    value: Vec<u8>,
}

impl DynEntry {
    fn size(&self) -> usize {
        // RFC 7541 §4.1: "size of an entry is the sum of its name's
        // length in octets, its value's length in octets, and 32".
        self.name.len() + self.value.len() + 32
    }
}

#[derive(Default)]
struct DynTable {
    entries: std::collections::VecDeque<DynEntry>,
    size: usize,
    max_size: usize,
}

impl DynTable {
    fn new(max_size: usize) -> Self {
        Self {
            entries: std::collections::VecDeque::new(),
            size: 0,
            max_size,
        }
    }

    fn set_max_size(&mut self, new_max: usize) {
        self.max_size = new_max;
        self.evict_to_fit(0);
    }

    fn add(&mut self, name: Vec<u8>, value: Vec<u8>) {
        let entry = DynEntry { name, value };
        if entry.size() > self.max_size {
            // Spec: an entry larger than the dynamic table size simply
            // empties the table.
            self.entries.clear();
            self.size = 0;
            return;
        }
        self.evict_to_fit(entry.size());
        self.size += entry.size();
        self.entries.push_front(entry);
    }

    fn evict_to_fit(&mut self, incoming: usize) {
        while self.size + incoming > self.max_size {
            match self.entries.pop_back() {
                Some(e) => self.size -= e.size(),
                None => break,
            }
        }
    }

    /// Index in the combined table. `idx` is 1-based per RFC 7541.
    /// Static is 1..=STATIC_TABLE_LEN; dynamic begins at STATIC_TABLE_LEN+1.
    fn lookup(&self, idx: usize) -> Option<(&[u8], &[u8])> {
        if idx == 0 {
            return None;
        }
        if idx <= STATIC_TABLE_LEN {
            let (n, v) = STATIC_TABLE[idx - 1];
            Some((n, v))
        } else {
            let off = idx - STATIC_TABLE_LEN - 1;
            self.entries.get(off).map(|e| (e.name.as_slice(), e.value.as_slice()))
        }
    }
}

// ---- Integer encoding (RFC 7541 §5.1).
fn encode_integer(prefix_bits: u8, value: usize, prefix_byte: u8, out: &mut Vec<u8>) {
    let max_prefix = (1usize << prefix_bits) - 1;
    if value < max_prefix {
        out.push(prefix_byte | value as u8);
        return;
    }
    out.push(prefix_byte | max_prefix as u8);
    let mut v = value - max_prefix;
    while v >= 128 {
        out.push(((v & 0x7f) | 0x80) as u8);
        v >>= 7;
    }
    out.push(v as u8);
}

fn decode_integer(input: &[u8], prefix_bits: u8) -> Result<(usize, usize), HpackError> {
    if input.is_empty() {
        return Err(HpackError::Truncated);
    }
    let max_prefix = (1usize << prefix_bits) - 1;
    let mut value = (input[0] as usize) & max_prefix;
    if value < max_prefix {
        return Ok((value, 1));
    }
    let mut consumed = 1usize;
    let mut shift = 0u32;
    loop {
        if consumed >= input.len() {
            return Err(HpackError::Truncated);
        }
        let b = input[consumed];
        consumed += 1;
        value = value
            .checked_add(((b & 0x7f) as usize) << shift)
            .ok_or(HpackError::Overflow)?;
        if (b & 0x80) == 0 {
            return Ok((value, consumed));
        }
        shift += 7;
        if shift > 63 {
            return Err(HpackError::Overflow);
        }
    }
}

// ---- String encoding. Always emit raw (Huffman bit cleared).
fn encode_string(s: &[u8], out: &mut Vec<u8>) {
    encode_integer(7, s.len(), 0x00, out);
    out.extend_from_slice(s);
}

// Decode a string literal (Huffman-flagged or raw).
fn decode_string(input: &[u8]) -> Result<(Vec<u8>, usize), HpackError> {
    if input.is_empty() {
        return Err(HpackError::Truncated);
    }
    let huffman = (input[0] & 0x80) != 0;
    let (len, hdr) = decode_integer(input, 7)?;
    let total = hdr + len;
    if input.len() < total {
        return Err(HpackError::Truncated);
    }
    let raw = &input[hdr..total];
    let bytes = if huffman {
        huffman::decode(raw)?
    } else {
        raw.to_vec()
    };
    Ok((bytes, total))
}

// ---- Encoder.

pub struct Encoder {
    dyn_table: DynTable,
}

impl Encoder {
    pub fn new() -> Self {
        Self {
            dyn_table: DynTable::new(4096),
        }
    }

    pub fn encode_header(&mut self, name: &[u8], value: &[u8], out: &mut Vec<u8>) {
        // 1) full static-table match → 0x80 | index. Cheapest path; takes
        // priority over the dynamic table for headers like `:method GET`
        // where the static index is shorter or equal.
        for (i, (n, v)) in STATIC_TABLE.iter().enumerate() {
            if *n == name && *v == value {
                encode_integer(7, i + 1, 0x80, out);
                return;
            }
        }
        // 2) full dynamic-table match → 0x80 | (STATIC_TABLE_LEN + 1 + offset).
        // Phase 10 (Phase 6c) — without this branch the encoder never
        // re-uses dyn-table inserts on repeated headers, so a stream
        // that re-sends the same `cookie: …` collapses to a literal
        // every time. Adding the search closes the wire-bytes gap with
        // protocol-hpack's Ruby Compressor (which DOES search the
        // dynamic table); fixes the regression where wire-mode native
        // HPACK ran slower than fallback because of the missing
        // compression.
        for (off, e) in self.dyn_table.entries.iter().enumerate() {
            if e.name == name && e.value == value {
                let idx = STATIC_TABLE_LEN + 1 + off;
                encode_integer(7, idx, 0x80, out);
                return;
            }
        }
        // 3) name-only static match → 0x40 | index, then literal value;
        // insert into dyn table so future repeats hit branch (2).
        for (i, (n, _)) in STATIC_TABLE.iter().enumerate() {
            if *n == name {
                encode_integer(6, i + 1, 0x40, out);
                encode_string(value, out);
                self.dyn_table.add(name.to_vec(), value.to_vec());
                return;
            }
        }
        // 4) name-only dynamic match → 0x40 | (STATIC_TABLE_LEN + 1 + off),
        // literal value, insert new entry. Same shape as (3) but the
        // name comes from the dyn table instead of the static one.
        for (off, e) in self.dyn_table.entries.iter().enumerate() {
            if e.name == name {
                let idx = STATIC_TABLE_LEN + 1 + off;
                encode_integer(6, idx, 0x40, out);
                encode_string(value, out);
                self.dyn_table.add(name.to_vec(), value.to_vec());
                return;
            }
        }
        // 5) Wholly novel name. Use literal-with-incremental-indexing
        // (0x40 prefix, 6-bit zero index, name lit, value lit) so
        // future repeats can collapse via branches (2)/(4). Previously
        // emitted as "literal without indexing" (0x00 prefix), which
        // is RFC-compliant but leaves zero compression on the table —
        // since the wire path is now hot, paying one slot in the dyn
        // table is the right tradeoff.
        out.push(0x40);
        encode_string(name, out);
        encode_string(value, out);
        self.dyn_table.add(name.to_vec(), value.to_vec());
    }
}

// ---- Decoder.

pub struct Decoder {
    dyn_table: DynTable,
}

impl Decoder {
    pub fn new() -> Self {
        Self {
            dyn_table: DynTable::new(4096),
        }
    }

    pub fn decode(&mut self, mut input: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>, HpackError> {
        let mut out = Vec::new();
        while !input.is_empty() {
            let first = input[0];
            if first & 0x80 != 0 {
                // Indexed header field (RFC 7541 §6.1).
                let (idx, used) = decode_integer(input, 7)?;
                if idx == 0 {
                    return Err(HpackError::ZeroIndex);
                }
                let (n, v) = self
                    .dyn_table
                    .lookup(idx)
                    .ok_or(HpackError::BadIndex)?;
                out.push((n.to_vec(), v.to_vec()));
                input = &input[used..];
            } else if first & 0xc0 == 0x40 {
                // Literal with incremental indexing (§6.2.1).
                let (idx, used) = decode_integer(input, 6)?;
                input = &input[used..];
                let name = if idx == 0 {
                    let (n, c) = decode_string(input)?;
                    input = &input[c..];
                    n
                } else {
                    let (n, _) = self
                        .dyn_table
                        .lookup(idx)
                        .ok_or(HpackError::BadIndex)?;
                    n.to_vec()
                };
                let (value, c) = decode_string(input)?;
                input = &input[c..];
                self.dyn_table.add(name.clone(), value.clone());
                out.push((name, value));
            } else if first & 0xe0 == 0x20 {
                // Dynamic table size update (§6.3).
                let (new_max, used) = decode_integer(input, 5)?;
                self.dyn_table.set_max_size(new_max);
                input = &input[used..];
            } else {
                // 0x00 (literal without indexing) or 0x10 (never indexed)
                // — same wire shape, just different routing semantics.
                let (idx, used) = decode_integer(input, 4)?;
                input = &input[used..];
                let name = if idx == 0 {
                    let (n, c) = decode_string(input)?;
                    input = &input[c..];
                    n
                } else {
                    let (n, _) = self
                        .dyn_table
                        .lookup(idx)
                        .ok_or(HpackError::BadIndex)?;
                    n.to_vec()
                };
                let (value, c) = decode_string(input)?;
                input = &input[c..];
                out.push((name, value));
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_roundtrip_examples_rfc7541_c1() {
        // C.1.1 — value 10, prefix 5 → 0b00001010
        let mut buf = Vec::new();
        encode_integer(5, 10, 0x00, &mut buf);
        assert_eq!(buf, [0x0a]);
        // C.1.2 — value 1337, prefix 5 → 0b00011111 0b10011010 0b00001010
        buf.clear();
        encode_integer(5, 1337, 0x00, &mut buf);
        assert_eq!(buf, [0x1f, 0x9a, 0x0a]);

        let (v, used) = decode_integer(&[0x1f, 0x9a, 0x0a], 5).unwrap();
        assert_eq!(v, 1337);
        assert_eq!(used, 3);
    }

    #[test]
    fn round_trip_basic_request_headers() {
        let mut enc = Encoder::new();
        let mut buf = Vec::new();
        enc.encode_header(b":method", b"GET", &mut buf);
        enc.encode_header(b":path", b"/", &mut buf);
        enc.encode_header(b":scheme", b"https", &mut buf);
        enc.encode_header(b":authority", b"example.com", &mut buf);
        enc.encode_header(b"accept", b"*/*", &mut buf);

        let mut dec = Decoder::new();
        let out = dec.decode(&buf).unwrap();
        assert_eq!(out.len(), 5);
        assert_eq!(out[0].0, b":method");
        assert_eq!(out[0].1, b"GET");
        assert_eq!(out[3].0, b":authority");
        assert_eq!(out[3].1, b"example.com");
    }

    #[test]
    fn round_trip_response_headers() {
        let mut enc = Encoder::new();
        let mut buf = Vec::new();
        enc.encode_header(b":status", b"200", &mut buf);
        enc.encode_header(b"content-type", b"text/plain", &mut buf);
        enc.encode_header(b"content-length", b"42", &mut buf);

        let mut dec = Decoder::new();
        let out = dec.decode(&buf).unwrap();
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], (b":status".to_vec(), b"200".to_vec()));
        assert_eq!(out[1], (b"content-type".to_vec(), b"text/plain".to_vec()));
    }
}
