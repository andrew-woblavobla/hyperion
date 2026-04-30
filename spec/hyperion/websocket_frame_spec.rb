# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/frame'

# WS-3 (2.1.0) — RFC 6455 frame ser/de spec.  Exercises CFrame.parse,
# CFrame.build, CFrame.unmask + the Parser / Builder façades.  Vectors
# come from RFC 6455 §5.7 ("Examples"), with edge cases for length
# encoding, control-frame caps, fragmentation, malformed input, and
# incomplete buffers.
RSpec.describe Hyperion::WebSocket do
  let(:cframe) { Hyperion::WebSocket::CFrame }

  # ---------------------------------------------------------------
  # 1. RFC 6455 §5.7 — masked client frame "Hello"
  # ---------------------------------------------------------------
  describe 'RFC 6455 §5.7 — masked client text frame "Hello"' do
    let(:wire) do
      [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58].pack('C*')
    end

    it 'parses metadata correctly via the C primitive' do
      fin, opcode, payload_len, masked, mask_key, payload_offset, frame_total_len =
        cframe.parse(wire)
      expect(fin).to eq(true)
      expect(opcode).to eq(0x1)
      expect(payload_len).to eq(5)
      expect(masked).to eq(true)
      expect(mask_key.bytes).to eq([0x37, 0xfa, 0x21, 0x3d])
      expect(payload_offset).to eq(6)
      expect(frame_total_len).to eq(11)
    end

    it 'unmasks the payload to "Hello"' do
      _fin, _opcode, _len, _masked, mask_key, off, _total = cframe.parse(wire)
      expect(cframe.unmask(wire.byteslice(off, 5), mask_key)).to eq('Hello'.b)
    end

    it 'returns a Hyperion::WebSocket::Frame from the Ruby façade' do
      frame = Hyperion::WebSocket::Parser.parse(wire)
      expect(frame).to be_a(Hyperion::WebSocket::Frame)
      expect(frame.fin).to eq(true)
      expect(frame.opcode).to eq(:text)
      expect(frame.payload).to eq('Hello'.b)
    end

    it 'reports the cursor advance via parse_with_cursor' do
      frame, advance = Hyperion::WebSocket::Parser.parse_with_cursor(wire)
      expect(frame.payload).to eq('Hello'.b)
      expect(advance).to eq(11)
    end
  end

  # ---------------------------------------------------------------
  # 2. RFC 6455 §5.7 — server unmasked text frame "Hello"
  # ---------------------------------------------------------------
  describe 'server-side build — unmasked text frame "Hello"' do
    it 'produces 0x81 0x05 H e l l o' do
      out = Hyperion::WebSocket::Builder.build(opcode: :text, payload: 'Hello')
      expect(out.bytes).to eq([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])
    end

    it 'is binary-encoded' do
      out = Hyperion::WebSocket::Builder.build(opcode: :text, payload: 'Hello')
      expect(out.encoding).to eq(Encoding::BINARY)
    end
  end

  # ---------------------------------------------------------------
  # 3. All length encodings — round-trip parse + build
  # ---------------------------------------------------------------
  describe 'length-encoding round trip' do
    [0, 1, 125, 126, 127, 65_535, 65_536, 1_000_000].each do |size|
      it "parses+rebuilds a #{size}-byte unmasked binary frame" do
        payload = 'x'.b * size
        wire    = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: payload)

        frame, advance = Hyperion::WebSocket::Parser.parse_with_cursor(wire)
        expect(advance).to eq(wire.bytesize)
        expect(frame.payload.bytesize).to eq(size)
        expect(frame.payload).to eq(payload)
        expect(frame.opcode).to eq(:binary)
        expect(frame.fin).to eq(true)
      end
    end

    it 'uses 7-bit length when payload < 126' do
      wire = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: 'a'.b * 125)
      expect(wire.getbyte(1) & 0x7f).to eq(125)
      expect(wire.bytesize).to eq(2 + 125)
    end

    it 'uses 16-bit length when 126 <= payload <= 0xFFFF' do
      wire = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: 'a'.b * 126)
      expect(wire.getbyte(1) & 0x7f).to eq(126)
      expect(wire.bytesize).to eq(4 + 126)
    end

    it 'uses 64-bit length when payload > 0xFFFF' do
      wire = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: 'a'.b * 65_536)
      expect(wire.getbyte(1) & 0x7f).to eq(127)
      expect(wire.bytesize).to eq(10 + 65_536)
      # Most-significant 4 bytes of the 64-bit length must be zero.
      expect(wire.getbyte(2)).to eq(0)
      expect(wire.getbyte(3)).to eq(0)
      expect(wire.getbyte(4)).to eq(0)
      expect(wire.getbyte(5)).to eq(0)
    end
  end

  # ---------------------------------------------------------------
  # 4. Control-frame payload cap
  # ---------------------------------------------------------------
  describe 'control-frame validation' do
    it 'raises ArgumentError on a 200-byte ping' do
      expect do
        Hyperion::WebSocket::Builder.build(opcode: :ping, payload: 'x' * 200)
      end.to raise_error(ArgumentError, /125/)
    end

    it 'allows a 125-byte ping' do
      out = Hyperion::WebSocket::Builder.build(opcode: :ping, payload: 'x' * 125)
      expect(out.getbyte(0)).to eq(0x89) # FIN=1 | opcode=0x9
      expect(out.getbyte(1) & 0x7f).to eq(125)
    end

    it 'rejects fin=false on a control frame' do
      expect do
        Hyperion::WebSocket::Builder.build(opcode: :ping, payload: '', fin: false)
      end.to raise_error(ArgumentError, /fin=true/)
    end

    it 'allows close with empty payload' do
      out = Hyperion::WebSocket::Builder.build(opcode: :close, payload: '')
      expect(out.bytes).to eq([0x88, 0x00])
    end
  end

  # ---------------------------------------------------------------
  # 5. Fragmented messages
  # ---------------------------------------------------------------
  describe 'fragmented messages' do
    it 'parses [text fin=0 "Hel"][continuation fin=1 "lo"] correctly' do
      part1 = Hyperion::WebSocket::Builder.build(opcode: :text, payload: 'Hel', fin: false)
      part2 = Hyperion::WebSocket::Builder.build(opcode: :continuation, payload: 'lo', fin: true)
      buf   = part1 + part2

      f1, adv1 = Hyperion::WebSocket::Parser.parse_with_cursor(buf, 0)
      expect(f1.fin).to eq(false)
      expect(f1.opcode).to eq(:text)
      expect(f1.payload).to eq('Hel'.b)

      f2, adv2 = Hyperion::WebSocket::Parser.parse_with_cursor(buf, adv1)
      expect(f2.fin).to eq(true)
      expect(f2.opcode).to eq(:continuation)
      expect(f2.payload).to eq('lo'.b)
      expect(adv1 + adv2).to eq(buf.bytesize)
    end
  end

  # ---------------------------------------------------------------
  # 6. Malformed frames return :error
  # ---------------------------------------------------------------
  describe 'malformed frames return :error' do
    it 'rejects RSV1 set' do
      # 0xC1 = FIN=1, RSV1=1, opcode=text
      buf = [0xC1, 0x00].pack('C*')
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'rejects RSV2 set' do
      buf = [0xA1, 0x00].pack('C*')
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'rejects RSV3 set' do
      buf = [0x91, 0x00].pack('C*')
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'rejects unknown opcode 0xB' do
      # 0x8B = FIN=1, opcode=0xB (reserved control)
      buf = [0x8B, 0x00].pack('C*')
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'rejects fragmented close (FIN=0 on a control frame)' do
      # 0x08 = FIN=0, opcode=0x8 (close)
      buf = [0x08, 0x00].pack('C*')
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'rejects oversized control frame (>125 bytes)' do
      # 0x89 = FIN=1, opcode=0x9 (ping); len7=126 marks 16-bit length
      buf = [0x89, 0x7E, 0x00, 0xFF].pack('C*') + ('x' * 255).b
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'rejects 64-bit length with high bit set (RFC 6455 §5.2)' do
      # 0x82 = FIN=1, opcode=0x2 (binary); len7=127 = 64-bit length
      buf = [0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0].pack('C*')
      expect(cframe.parse(buf)).to eq(:error)
    end

    it 'raises ProtocolError from the Ruby façade on RSV bits' do
      buf = [0xC1, 0x00].pack('C*')
      expect { Hyperion::WebSocket::Parser.parse(buf) }
        .to raise_error(Hyperion::WebSocket::ProtocolError)
    end
  end

  # ---------------------------------------------------------------
  # 7. Incomplete frames return :incomplete
  # ---------------------------------------------------------------
  describe 'incomplete frames return :incomplete' do
    let(:wire) do
      [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58].pack('C*')
    end

    it 'returns :incomplete on an empty buffer' do
      expect(cframe.parse('')).to eq(:incomplete)
    end

    it 'returns :incomplete on the first byte alone' do
      expect(cframe.parse(wire.byteslice(0, 1))).to eq(:incomplete)
    end

    it 'returns :incomplete on header-only (mask key not yet arrived)' do
      # First 5 bytes: header byte + len byte + 3 of 4 mask bytes
      expect(cframe.parse(wire.byteslice(0, 5))).to eq(:incomplete)
    end

    it 'returns :incomplete with header + mask but missing payload bytes' do
      # First 6 bytes: full header + mask, no payload yet
      expect(cframe.parse(wire.byteslice(0, 6))).to eq(:incomplete)
      expect(cframe.parse(wire.byteslice(0, 10))).to eq(:incomplete) # 4 of 5 payload bytes
    end

    it 'returns :incomplete on a 16-bit-length header truncated mid-length' do
      # Build a 200-byte frame, feed back only first 3 bytes (header + 1 of 2 length bytes)
      wire2 = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: 'a'.b * 200)
      expect(cframe.parse(wire2.byteslice(0, 3))).to eq(:incomplete)
    end

    it 'returns :incomplete on a 64-bit-length header truncated mid-length' do
      wire8 = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: 'a'.b * 65_536)
      expect(cframe.parse(wire8.byteslice(0, 9))).to eq(:incomplete) # 7 of 8 length bytes
    end

    it 'completes parsing once the full buffer arrives' do
      result = cframe.parse(wire)
      expect(result).to be_a(Array)
      expect(result.length).to eq(7)
    end
  end

  # ---------------------------------------------------------------
  # 8. Unmask correctness — random 1 KiB payload
  # ---------------------------------------------------------------
  describe '.unmask correctness' do
    it 'matches a manual byte-by-byte XOR for a random 1 KiB payload' do
      payload = (0...1024).map { rand(256).chr }.join.b
      key     = [rand(256), rand(256), rand(256), rand(256)].pack('C*')

      expected = String.new(encoding: Encoding::BINARY)
      payload.bytes.each_with_index do |b, i|
        expected << (b ^ key.getbyte(i & 0x3)).chr
      end

      out = cframe.unmask(payload, key)
      expect(out.bytesize).to eq(payload.bytesize)
      expect(out.encoding).to eq(Encoding::BINARY)
      expect(out).to eq(expected)
    end

    it 'is involutive — unmask(unmask(x, k), k) == x' do
      payload = SecureRandom.bytes(4096)
      key     = SecureRandom.bytes(4)
      expect(cframe.unmask(cframe.unmask(payload, key), key)).to eq(payload)
    end

    it 'handles a 0-byte payload' do
      out = cframe.unmask('', "\x00\x00\x00\x00")
      expect(out).to eq('')
      expect(out.encoding).to eq(Encoding::BINARY)
    end

    it 'handles a 1-byte payload (tail-only path)' do
      out = cframe.unmask("\xff".b, "\x0f\x00\x00\x00")
      expect(out.bytes).to eq([0xff ^ 0x0f])
    end

    it 'handles a 7-byte payload (one word + 3-byte tail)' do
      payload = "\x01\x02\x03\x04\x05\x06\x07".b
      key     = "\x10\x20\x30\x40".b
      expected = [0x11, 0x22, 0x33, 0x44, 0x15, 0x26, 0x37].pack('C*')
      expect(cframe.unmask(payload, key)).to eq(expected)
    end

    it 'rejects a non-4-byte mask_key' do
      expect { cframe.unmask('hello'.b, "\x00\x00\x00".b) }.to raise_error(ArgumentError)
      expect { cframe.unmask('hello'.b, "\x00\x00\x00\x00\x00".b) }.to raise_error(ArgumentError)
    end
  end

  # ---------------------------------------------------------------
  # 9. Performance smoke — 1 MiB unmask < 5 ms
  # ---------------------------------------------------------------
  describe 'performance smoke (asserts the GVL-release C path is in use)' do
    it 'unmasks a 1 MiB payload in under 5 ms' do
      skip 'pure-Ruby fallback in use; perf assertion would be misleading' unless Hyperion::WebSocket::NATIVE_AVAILABLE

      payload = SecureRandom.bytes(1024 * 1024)
      key     = SecureRandom.bytes(4)

      # Warm the C path once so first-call overhead doesn't pollute the
      # measurement.
      cframe.unmask(payload, key)

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cframe.unmask(payload, key)
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0

      expect(elapsed_ms).to be < 5.0,
                            "expected < 5 ms for 1 MiB unmask, got #{elapsed_ms.round(2)} ms " \
                            '(suggests pure-Ruby fallback is in use)'
    end
  end

  # ---------------------------------------------------------------
  # 10. Client-side masked build — round trip against the parser
  # ---------------------------------------------------------------
  describe 'client-side masked build' do
    it 'round-trips through the parser with the mask applied' do
      mask = "\x01\x02\x03\x04".b
      wire = Hyperion::WebSocket::Builder.build(
        opcode: :text,
        payload: 'hello world',
        mask: true,
        mask_key: mask
      )
      # Mask bit on byte 1 must be set.
      expect(wire.getbyte(1) & 0x80).to eq(0x80)

      frame = Hyperion::WebSocket::Parser.parse(wire)
      expect(frame.opcode).to eq(:text)
      expect(frame.payload).to eq('hello world'.b)
    end

    it 'auto-generates a mask_key when none is supplied' do
      wire = Hyperion::WebSocket::Builder.build(opcode: :text, payload: 'auto', mask: true)
      frame = Hyperion::WebSocket::Parser.parse(wire)
      expect(frame.payload).to eq('auto'.b)
    end
  end
end
