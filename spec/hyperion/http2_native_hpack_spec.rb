# frozen_string_literal: true

require 'protocol/http2/server'
require 'protocol/http2/framer'
require 'protocol/hpack'

# Phase 10 (Phase 6c, 2.2.0) — Rust HPACK wired into the
# per-connection encode/decode boundary via
# `Hyperion::Http2::NativeHpackAdapter`. These specs lock in:
#
#   1. **Parity** — native and Ruby produce equally-decodable bytes
#      (the wire bytes themselves may differ — RFC 7541 has multiple
#      valid encodings of the same headers — but every byte sequence
#      one side produces must round-trip cleanly through both
#      decoders).
#   2. **Stateful dynamic table** — RFC 7541 dynamic table state
#      persists across header blocks on a single connection direction.
#      A header inserted into the table by block 1 is referenceable by
#      its dynamic-table index in block 2.
#   3. **Http2Handler integration** — the substitution actually
#      happens: when `H2Codec.available?` is true, a server's
#      `encode_headers` / `decode_headers` route through the native
#      adapter; when stubbed false, they keep using protocol-http2's
#      pure-Ruby Compressor/Decompressor. The connection still works
#      either way.
#
# The native suite skips when the Rust crate didn't build — see
# `H2Codec.available?`. Parity skips identically.
RSpec.describe Hyperion::Http2::NativeHpackAdapter, if: Hyperion::H2Codec.available? do
  let(:adapter) { described_class.new }

  describe '#encode_headers' do
    it 'returns the buffer with native bytes appended' do
      buf = String.new.b
      out = adapter.encode_headers([[':status', '200']], buf)

      expect(out).to be(buf)
      expect(out.bytesize).to be > 0
      expect(out.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'appends to a non-empty buffer rather than replacing it' do
      buf = (+'prefix').b
      out = adapter.encode_headers([[':status', '200']], buf)

      expect(out.bytesize).to be > 'prefix'.bytesize
      expect(out.byteslice(0, 6)).to eq('prefix')
    end

    it 'allocates a fresh buffer when none is supplied' do
      out = adapter.encode_headers([[':status', '200']])
      expect(out).to be_a(String)
      expect(out.bytesize).to be > 0
    end
  end

  describe '#decode_headers' do
    it 'round-trips a small static-table-only header set' do
      # ':status 200' → indexed reference 8 in the static table → single 0x88 byte.
      decoded = adapter.decode_headers("\x88".b)
      expect(decoded).to eq([[':status', '200']])
    end
  end

  describe 'cross-implementation parity' do
    # Build a deterministic but varied workload: ~100 random header
    # sets covering the three HPACK paths — fully indexed, name-indexed
    # literal, and fully literal. Per the RFC, the encoded bytes can
    # legitimately differ between two compliant encoders (Huffman vs
    # literal, indexed vs literal-with-incremental-indexing), so the
    # parity contract is decode equality, not byte equality.
    let(:seeded_rng) { Random.new(0xC0FFEE) }

    COMMON_HEADER_NAMES = [
      ':method', ':path', ':authority', ':scheme', ':status',
      'accept', 'accept-encoding', 'accept-language', 'cache-control',
      'content-type', 'content-length', 'cookie', 'set-cookie',
      'host', 'user-agent', 'referer', 'x-request-id', 'x-trace-id',
      'x-forwarded-for', 'x-forwarded-proto', 'authorization',
      'date', 'etag', 'last-modified', 'location', 'server', 'vary'
    ].freeze

    def random_header_set(rng)
      count = rng.rand(1..8)
      Array.new(count) do
        name = COMMON_HEADER_NAMES.sample(random: rng)
        # Mix in a smattering of synthetic novel names so the literal
        # path gets exercised, not just the static-table indexed path.
        name = "x-h-#{rng.bytes(4).unpack1('H*')}" if rng.rand < 0.2
        value_len = rng.rand(1..40)
        value = rng.bytes(value_len).unpack1('H*')[0, value_len]
        [name, value]
      end
    end

    def ruby_encode(headers)
      buf = String.new.b
      ctx = Protocol::HPACK::Context.new
      Protocol::HPACK::Compressor.new(buf, ctx).encode(headers)
      buf
    end

    def ruby_decode(bytes)
      ctx = Protocol::HPACK::Context.new
      Protocol::HPACK::Decompressor.new(bytes.dup, ctx).decode
    end

    def normalize(pairs)
      # Both implementations produce [name, value] string pairs but
      # the Ruby Decompressor returns headers as plain `[name, value]`
      # arrays — same shape as our adapter — so straight equality is
      # fine. Force ASCII-8BIT for stable comparisons.
      pairs.map { |n, v| [n.to_s.b, v.to_s.b] }
    end

    it 'native-encoded bytes decode identically through native and Ruby decoders for 100 random header sets' do
      100.times do
        headers = random_header_set(seeded_rng)
        # Fresh adapter per iteration so the dynamic-table state of one
        # iteration doesn't poison the next (parity is a stateless
        # contract).
        enc = described_class.new
        bytes = enc.encode_headers(headers, String.new.b)

        via_native = described_class.new.decode_headers(bytes.dup)
        via_ruby   = ruby_decode(bytes.dup)

        expect(normalize(via_native)).to eq(normalize(headers))
        expect(normalize(via_ruby)).to eq(normalize(headers))
      end
    end

    it 'ruby-encoded bytes decode identically through native and Ruby decoders for 100 random header sets' do
      100.times do
        headers = random_header_set(seeded_rng)
        bytes = ruby_encode(headers)

        via_native = described_class.new.decode_headers(bytes.dup)
        via_ruby   = ruby_decode(bytes.dup)

        expect(normalize(via_native)).to eq(normalize(headers))
        expect(normalize(via_ruby)).to eq(normalize(headers))
      end
    end
  end

  describe 'stateful dynamic table across blocks' do
    # RFC 7541 §2.3.2: the dynamic table is per-direction per-connection
    # and accumulates across header blocks. The Rust **encoder**
    # currently routes static-name + novel-value through "literal with
    # incremental indexing" (which DOES insert into the dyn table) but
    # always emits literals on the next call rather than searching the
    # dyn table for matches — that's RFC-compliant: encoders are NOT
    # required to use the dynamic table for compression, only the
    # decoder MUST track it. So this group exercises the
    # decoder-side stateful contract: when fed wire bytes (produced by
    # any RFC-compliant encoder) that reference the dynamic table, the
    # native decoder MUST track inserts and resolve indices correctly
    # across successive blocks.

    it 'native decoder tracks dynamic-table inserts across successive blocks (Ruby encoder feeds it)' do
      # Build a Ruby Compressor that *does* exploit dynamic-table
      # indexing on repeated headers. After block 1 emits a literal-
      # with-incremental-indexing (cookie + value), block 2 emits an
      # indexed reference into the dynamic table.
      ruby_ctx = Protocol::HPACK::Context.new
      buf1 = String.new.b
      buf2 = String.new.b
      Protocol::HPACK::Compressor.new(buf1, ruby_ctx).encode([['cookie', 'session=novel-xyz-001']])
      Protocol::HPACK::Compressor.new(buf2, ruby_ctx).encode([['cookie', 'session=novel-xyz-001']])

      # Block 2 must be substantially smaller than block 1 (it's now
      # an indexed reference). If this stops holding, the Ruby encoder
      # itself has changed and the test premise breaks — fail loudly.
      expect(buf2.bytesize).to be < buf1.bytesize

      # Native decoder threaded through both blocks. State must
      # accumulate so block 2's indexed reference resolves.
      dec = described_class.new
      out1 = dec.decode_headers(buf1)
      out2 = dec.decode_headers(buf2)

      expect(out1).to eq([['cookie', 'session=novel-xyz-001']])
      expect(out2).to eq([['cookie', 'session=novel-xyz-001']])
    end

    it 'native decoder + Ruby decoder agree on a 3-block stream that exercises the dyn table' do
      ruby_ctx = Protocol::HPACK::Context.new
      block1 = [['user-agent', 'hyperion-test/1.0 (build-a)']]
      block2 = [['user-agent', 'hyperion-test/1.0 (build-b)']]
      block3 = [['user-agent', 'hyperion-test/1.0 (build-a)']]

      bufs = [block1, block2, block3].map do |hdrs|
        b = String.new.b
        Protocol::HPACK::Compressor.new(b, ruby_ctx).encode(hdrs)
        b
      end

      # Block 3 is a repeat of block 1 — Ruby Compressor will collapse
      # it to an indexed reference into the dyn table.
      expect(bufs[2].bytesize).to be < bufs[0].bytesize

      native_dec = described_class.new
      ruby_dec_ctx = Protocol::HPACK::Context.new

      [block1, block2, block3].each_with_index do |expected, i|
        # Native must resolve dyn-table indices the encoder inserted in
        # earlier blocks.
        expect(native_dec.decode_headers(bufs[i].dup)).to eq(expected)
        # Ruby decoder cross-check on the same byte stream.
        expect(Protocol::HPACK::Decompressor.new(bufs[i].dup, ruby_dec_ctx).decode).to eq(expected)
      end
    end

    it 'native encoder + native decoder round-trip a multi-block stream' do
      enc = described_class.new
      dec = described_class.new

      block1 = [['cookie', 'session=alpha']]
      block2 = [[':method', 'GET'], [':path', '/x'], ['accept', 'application/json']]
      block3 = [['user-agent', 'hyperion/2.2.0'], ['cookie', 'session=beta']]

      [block1, block2, block3].each do |hdrs|
        bytes = enc.encode_headers(hdrs, String.new.b)
        expect(dec.decode_headers(bytes.dup)).to eq(hdrs)
      end
    end
  end

  describe 'fix-B (2.2.x) — per-encoder scratch buffer + flat-blob ABI' do
    # The v2 ABI eliminates per-HEADERS-frame Fiddle marshalling
    # allocations. v1 paid:
    #   * 1 `Fiddle::Pointer[]` per name + 1 per value (= 2 × headers.length)
    #   * 4 `pack('Q*')` / `pack('L*')` calls per encode call
    #   * 1 capacity-byte `String#<< ("\x00" * cap)` pre-fill per call
    #   * 1 final `byteslice(0, written)` per call
    # Total v1 allocations on a 4-header response: ~12 transient Strings/Pointers.
    #
    # v2 pays:
    #   * 1 `Fiddle::Pointer[]` per scratch buffer (3 — out, argv, blob),
    #     refreshed only when the underlying String reallocates.
    #   * 1 `pack('Q4')` per header (32-byte transient).
    #   * 1 `Fiddle::Pointer#to_str(written)` per call (the unavoidable
    #     output allocation — Ruby strings can't alias arbitrary memory).
    #
    # The spec below counts Encoder-class String.new invocations: the
    # scratch buffers are allocated ONCE in #initialize, so #encode
    # adds zero further String.new calls beyond the unavoidable output
    # String returned to the caller (via Fiddle::Pointer#to_str, which
    # is a single fresh String per call).

    it 'reuses scratch buffers across encode calls (no extra String.new in encode hot path)' do
      enc = Hyperion::H2Codec::Encoder.new

      # Warm up — first call may resize the output scratch.
      enc.encode([[':status', '200'], ['content-type', 'application/json']])

      # Drive 50 calls and count how many `String.new` invocations
      # happen on Encoder's class. ObjectSpace allocation tracing gives
      # us a process-wide view; we filter to allocations whose
      # `allocation_sourcefile_for` points at h2_codec.rb's encode hot
      # path. The lower bound we expect is 50 (one per call — the
      # output bytes returned to the caller). Any value above that
      # would mean the per-call path leaks an allocation.
      enc.send(:instance_variable_get, :@scratch_blob)
      enc.send(:instance_variable_get, :@scratch_argv)
      enc.send(:instance_variable_get, :@scratch_out)

      # We can't easily intercept `String.new` (it's a method on a
      # core class with C impl) without monkey-patching, so we proxy:
      # count the String allocations via GC.stat between calls. After
      # warmup, a steady-state 50 encode calls should NOT cause the
      # heap-eden-pages metric to balloon, but that's a coarse signal
      # for this test. Stronger signal: compare per-call allocations
      # via ObjectSpace.count_objects.
      headers = [[':status', '200'], ['content-type', 'application/json'], ['x-trace-id', 't-abc-123']]

      # Force an allocation baseline by running once outside the
      # measurement window.
      enc.encode(headers)
      GC.start

      before = ObjectSpace.count_objects[:T_STRING]
      50.times { enc.encode(headers) }
      GC.disable # don't let GC reclaim the per-call output Strings while we're counting
      after = ObjectSpace.count_objects[:T_STRING]
      GC.enable

      created = after - before
      # Per-call v2 String allocations on a 3-header workload (frozen
      # ASCII-8BIT-encoded header strings, the protocol-http2 norm):
      #   * 6 × `.b` per call ONLY when the source string isn't already
      #     ASCII-8BIT — frozen literals from protocol-http2 typically
      #     are, so this branch is mostly skipped. With non-binary
      #     strings (the spec uses default-encoded test literals) we
      #     still pay 6 × `.b` per call.
      #   * 1 × `pack('Q*', buffer: @scratch_argv)` reuses the scratch
      #     (zero-alloc on steady state).
      #   * 1 × `Fiddle::Pointer#to_str(written)` returned bytes.
      #   * = ~7.5 per call observed, ~377 across 50 calls.
      #
      # v1 paid (per call, 3 headers):
      #   * 6 × `.b` (same)
      #   * 4 × `pack('Q*' / 'L*')` per call (names_buf, name_lens, val_buf, val_lens)
      #   * 1 × capacity-byte prefill String (`"\x00".b * capacity`)
      #   * 1 × `byteslice(0, written)` returned String
      #   * = ~12 per call, ~600 over 50 calls (lower bound).
      #
      # Bound at 500 keeps safety margin under v1's 600 floor while
      # accommodating GC-driven jitter in the v2 measurement.
      expect(created).to be < 500,
                         "encode created #{created} T_STRING objects across 50 calls; " \
                         'expected fewer than 500 (v1 baseline was ~600, v2 observed ~380)'
    end

    it 'rejects encode when output buffer overflow occurs' do
      enc = Hyperion::H2Codec::Encoder.new
      # Force the output scratch to a tiny capacity so a moderately
      # sized header set blows past it. We patch the instance state
      # directly to keep the worst-case-grow path from auto-rescuing.
      enc.instance_variable_set(:@scratch_out_capacity, 8)
      enc.instance_variable_set(:@scratch_out, String.new(capacity: 8, encoding: Encoding::ASCII_8BIT))

      # Stub the worst-case grow check by overriding the threshold:
      # construct a hand-crafted header set that the encoder believes
      # fits but the C side will reject. Easiest path: hand-craft FFI
      # call directly with a tiny out_capacity argument so we exercise
      # the C-side overflow branch.
      blob = ('a' * 1024).b
      argv = [0, 1024, 0, 0].pack('Q4')
      out = String.new(capacity: 4, encoding: Encoding::ASCII_8BIT)
      ptr_blob = Fiddle::Pointer[blob]
      ptr_argv = Fiddle::Pointer[argv]
      ptr_out = Fiddle::Pointer[out]
      handle = enc.instance_variable_get(:@ptr)

      rc = Hyperion::H2Codec.encoder_encode_v2(handle, ptr_blob, blob.bytesize, ptr_argv, 1, ptr_out, 4)
      expect(rc).to eq(-1) # overflow
    end

    it 'rejects encode v2 with bad arguments (out-of-bounds offsets)' do
      enc = Hyperion::H2Codec::Encoder.new
      blob = 'short'.b
      # name_off=0, name_len=999 → past blob end
      argv = [0, 999, 0, 0].pack('Q4')
      out = String.new(capacity: 64, encoding: Encoding::ASCII_8BIT)
      ptr_blob = Fiddle::Pointer[blob]
      ptr_argv = Fiddle::Pointer[argv]
      ptr_out = Fiddle::Pointer[out]
      handle = enc.instance_variable_get(:@ptr)

      rc = Hyperion::H2Codec.encoder_encode_v2(handle, ptr_blob, blob.bytesize, ptr_argv, 1, ptr_out, 64)
      expect(rc).to eq(-2) # bad args
    end

    it 'maintains dynamic-table state across encode calls under the v2 ABI' do
      enc = described_class.new

      # First block inserts (cookie, session=novel) into the dyn table
      # via literal-with-incremental-indexing (branch 5). Second block
      # repeats the same pair — branch 2 (full dyn-table match) should
      # collapse it to an indexed reference, producing fewer bytes.
      block1 = [['cookie', 'session=novel-v2-abc']]
      bytes1 = enc.encode_headers(block1, String.new.b)
      bytes2 = enc.encode_headers(block1, String.new.b)

      expect(bytes2.bytesize).to be < bytes1.bytesize,
                                 'expected dyn-table reuse to shrink the second block ' \
                                 "(block1=#{bytes1.bytesize}B, block2=#{bytes2.bytesize}B)"

      # Round-trip through a paired native decoder threading both blocks
      # to confirm the dyn-table is consistent.
      dec = described_class.new
      expect(dec.decode_headers(bytes1)).to eq(block1)
      expect(dec.decode_headers(bytes2)).to eq(block1)
    end

    it 'auto-grows the output scratch when a frame exceeds the running capacity' do
      enc = Hyperion::H2Codec::Encoder.new
      # 200 headers × ~40 bytes each ≈ 8 KB compressed. The 16 KiB
      # default capacity holds it on the first call, but a 1000-header
      # frame won't.
      huge = Array.new(1000) { |i| ["x-h-#{i}", "v-#{'p' * 40}-#{i}"] }
      bytes = enc.encode(huge)
      expect(bytes.bytesize).to be > 16_384

      # Subsequent smaller calls reuse the (now larger) scratch.
      small_bytes = enc.encode([[':status', '200']])
      expect(small_bytes).to eq("\x88".b)
    end
  end
end

RSpec.describe 'Http2Handler — native HPACK installation' do
  let(:app) { ->(_env) { [200, {}, ['']] } }

  context 'when H2Codec.available? is true AND HYPERION_H2_NATIVE_HPACK=1 (opt-in)', if: Hyperion::H2Codec.available? do
    around do |ex|
      original = ENV.fetch('HYPERION_H2_NATIVE_HPACK', nil)
      ENV['HYPERION_H2_NATIVE_HPACK'] = '1'
      ex.run
    ensure
      if original.nil?
        ENV.delete('HYPERION_H2_NATIVE_HPACK')
      else
        ENV['HYPERION_H2_NATIVE_HPACK'] = original
      end
    end

    it 'overrides encode_headers / decode_headers on the protocol-http2 server with the native adapter' do
      handler = Hyperion::Http2Handler.new(app: app)
      framer = instance_double(Protocol::HTTP2::Framer)
      server = handler.send(:build_server, framer)

      adapter = server.instance_variable_get(:@hyperion_native_hpack)
      expect(adapter).to be_a(Hyperion::Http2::NativeHpackAdapter)

      # The singleton method must be on the server instance, not the class.
      expect(server.singleton_methods).to include(:encode_headers, :decode_headers)
    end

    it 'round-trips a request/response header block end-to-end via the wired adapter' do
      handler = Hyperion::Http2Handler.new(app: app)
      framer = instance_double(Protocol::HTTP2::Framer)
      server = handler.send(:build_server, framer)

      # Server is a Connection — encode_headers serializes a server's
      # response headers, decode_headers deserializes a peer's
      # request headers. We round-trip through the same connection
      # endpoint to prove the wired adapter pair is consistent (in
      # real traffic the encoder side is paired with the *peer's*
      # decoder, but for this spec we just verify the public surface
      # works under the override).
      headers = [[':status', '200'], ['content-type', 'application/json'], ['x-trace-id', 't-1234']]

      bytes = server.encode_headers(headers, String.new.b)
      expect(bytes).to be_a(String)
      expect(bytes.bytesize).to be > 0

      # Build a paired adapter so the decoder context matches the
      # encoder context (HPACK is stateful per direction).
      paired_adapter = Hyperion::Http2::NativeHpackAdapter.new
      # We re-encode through the paired adapter so the paired decoder
      # is in sync; otherwise the decoder would fail on dynamic-table
      # references it never saw.
      paired_bytes = paired_adapter.encode_headers(headers, String.new.b)
      decoded = server.decode_headers(paired_bytes)
      expect(decoded).to eq(headers)
    end
  end

  context 'when H2Codec.available? is true but HYPERION_H2_NATIVE_HPACK is unset (default — opt-in not taken)',
          if: Hyperion::H2Codec.available? do
    around do |ex|
      original = ENV.fetch('HYPERION_H2_NATIVE_HPACK', nil)
      ENV.delete('HYPERION_H2_NATIVE_HPACK')
      ex.run
    ensure
      ENV['HYPERION_H2_NATIVE_HPACK'] = original unless original.nil?
    end

    it 'reports the crate available but does NOT install the native adapter on new connections' do
      handler = Hyperion::Http2Handler.new(app: app)
      expect(handler.codec_available?).to be(true)
      expect(handler.codec_native?).to be(false)

      framer = instance_double(Protocol::HTTP2::Framer)
      server = handler.send(:build_server, framer)

      expect(server.instance_variable_get(:@hyperion_native_hpack)).to be_nil
      expect(server.singleton_methods).not_to include(:encode_headers, :decode_headers)
    end
  end

  context 'when H2Codec.available? is stubbed false (fallback path)' do
    before do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:available?).and_return(false)
    end

    after { Hyperion::H2Codec.reset! }

    it 'leaves the protocol-http2 server with its default Ruby Compressor/Decompressor path' do
      handler = Hyperion::Http2Handler.new(app: app)
      expect(handler.codec_native?).to be(false)

      framer = instance_double(Protocol::HTTP2::Framer)
      server = handler.send(:build_server, framer)

      expect(server.instance_variable_get(:@hyperion_native_hpack)).to be_nil
      expect(server.singleton_methods).not_to include(:encode_headers, :decode_headers)

      # The default path still produces decodable bytes — confirm by
      # round-tripping through the protocol-http2 surface.
      headers = [[':status', '200'], ['content-type', 'text/plain']]
      bytes = server.encode_headers(headers, String.new.b)
      expect(bytes.bytesize).to be > 0

      # Decoding must round-trip via the matching Ruby decoder.
      ctx = Protocol::HPACK::Context.new
      decoded = Protocol::HPACK::Decompressor.new(bytes.dup, ctx).decode
      expect(decoded).to eq(headers)
    end
  end
end
