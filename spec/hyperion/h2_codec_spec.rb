# frozen_string_literal: true

require 'securerandom'

# Phase 6 (RFC §3 2.0.0): native HPACK encode/decode via the
# `hyperion_h2_codec` Rust cdylib + Fiddle binding. These specs only
# run when the cdylib is available — on a host without Rust, the
# extension isn't built and `Hyperion::H2Codec.available?` returns
# false. We skip the suite in that case rather than fail; the
# `h2_codec_fallback_spec` covers the off path.
RSpec.describe Hyperion::H2Codec, if: Hyperion::H2Codec.available? do
  describe '.available?' do
    it 'returns true when the native library loaded' do
      expect(described_class.available?).to be(true)
    end
  end

  describe Hyperion::H2Codec::Encoder do
    it 'encodes a fully-static-table-matched header to a single indexed byte' do
      enc = described_class.new
      # ':method GET' is index 2 in the static table → 0x80 | 2 = 0x82.
      bytes = enc.encode([[':method', 'GET']])
      expect(bytes.bytes).to eq([0x82])
    end

    it 'encodes a name-indexed literal (:authority + example.com) with incremental indexing' do
      enc = described_class.new
      bytes = enc.encode([[':authority', 'example.com']])
      # 0x41 (literal w/ inc indexing, name idx 1) | 0x0b len + raw bytes
      expect(bytes.bytes.first).to eq(0x41)
      expect(bytes).to include('example.com')
    end

    it 'encodes a fully-novel name as a literal-with-incremental-indexing block' do
      # Phase 10 (2.2.0): novel names now go through "literal with
      # incremental indexing" (prefix 0x40 with 6-bit zero index +
      # literal name + literal value) instead of "literal without
      # indexing" (0x00). The wire format is RFC 7541-compliant in
      # both shapes but indexing makes repeats collapse to a 1-byte
      # reference, which closes the bench gap with protocol-hpack's
      # Ruby Compressor.
      enc = described_class.new
      bytes = enc.encode([%w[x-hyperion-test yes]])
      expect(bytes.bytes.first).to eq(0x40)
      expect(bytes).to include('x-hyperion-test')
      expect(bytes).to include('yes')
    end

    it 'handles many sequential header sets without error' do
      enc = described_class.new
      100.times do |i|
        bytes = enc.encode([[':status', '200'], ['x-iter', i.to_s]])
        expect(bytes).not_to be_empty
      end
    end
  end

  describe Hyperion::H2Codec::Decoder do
    it 'decodes the RFC 7541 C.2.1 example (literal with incremental indexing)' do
      # custom-key: custom-header
      bytes = ['400a637573746f6d2d6b65790d637573746f6d2d686561646572'].pack('H*')
      dec = described_class.new
      out = dec.decode(bytes)
      expect(out).to eq([%w[custom-key custom-header]])
    end

    it 'decodes the RFC 7541 C.4.1 Huffman-encoded :authority' do
      bytes = ['418cf1e3c2e5f23a6ba0ab90f4ff'].pack('H*')
      dec = described_class.new
      out = dec.decode(bytes)
      expect(out).to eq([[':authority', 'www.example.com']])
    end

    it 'decodes a single indexed-only header (e.g. 0x82 → :method GET)' do
      dec = described_class.new
      out = dec.decode([0x82].pack('C*'))
      expect(out).to eq([[':method', 'GET']])
    end
  end

  describe 'round-trip through Encoder + Decoder' do
    let(:enc) { Hyperion::H2Codec::Encoder.new }
    let(:dec) { Hyperion::H2Codec::Decoder.new }

    it 'survives 100 random header sets byte-for-byte' do
      100.times do
        n = rand(1..16)
        headers = Array.new(n) do
          name = (if rand < 0.5
                    %w[:method :path :status content-type accept user-agent server
                       etag].sample
                  else
                    "x-#{SecureRandom.hex(4)}"
                  end)
          value = SecureRandom.alphanumeric(rand(1..32))
          [name, value]
        end
        wire = enc.encode(headers)
        round = dec.decode(wire)
        expect(round).to eq(headers),
                         "round trip mismatch for #{headers.inspect} (wire=#{wire.unpack1('H*')})"
      end
    end

    it 'preserves a typical Rails response header set' do
      headers = [
        [':status', '200'],
        ['content-type', 'text/html; charset=utf-8'],
        ['content-length', '1234'],
        ['cache-control', 'max-age=0, private, must-revalidate'],
        ['x-request-id', '01HZ8N9Q3J5K6M7P8R9S0T1V2W'],
        ['set-cookie', '_session=abc123; path=/; secure; httponly'],
        ['vary', 'Accept-Encoding'],
        ['etag', 'W/"deadbeef"']
      ]
      wire = enc.encode(headers)
      round = dec.decode(wire)
      expect(round).to eq(headers)
    end

    it 'preserves a typical browser request header set with multiple values' do
      headers = [
        [':method', 'GET'],
        [':path', '/api/v1/items?limit=50'],
        [':scheme', 'https'],
        [':authority', 'api.example.com'],
        ['accept', 'application/json'],
        ['accept-encoding', 'gzip, deflate'],
        ['user-agent', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5)']
      ]
      wire = enc.encode(headers)
      round = dec.decode(wire)
      expect(round).to eq(headers)
    end
  end

  describe 'integer prefix encoding (RFC 7541 §5.1)' do
    # The Rust crate has its own unit tests for this. The Ruby side
    # exercises it through the encoder which calls into the prefix
    # encoder for both indexed-name (6-bit) and length-prefixed
    # strings (7-bit). A value just over each prefix boundary
    # exercises the multi-byte continuation path.
    it 'encodes a literal name longer than 127 bytes (multi-byte length prefix)' do
      enc = Hyperion::H2Codec::Encoder.new
      dec = Hyperion::H2Codec::Decoder.new
      long_value = 'v' * 256
      wire = enc.encode([['x-long', long_value]])
      out = dec.decode(wire)
      expect(out).to eq([['x-long', long_value]])
    end
  end
end
