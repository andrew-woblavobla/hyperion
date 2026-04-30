# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/connection'
require 'socket'

# WS-4 (2.1.0) — unit specs for Hyperion::WebSocket::Connection.
#
# We drive the wrapper against a `socketpair` so the "peer" side of the
# WebSocket can be controlled directly: write hand-rolled (masked, per
# RFC 6455 §5.3 client frames) bytes onto one end, watch what the
# Connection writes back on the same end. Avoids a real TCP listener
# while still exercising the IO.select / read_nonblock paths in the
# wrapper.
RSpec.describe Hyperion::WebSocket::Connection do
  # mask_key chosen so the on-wire bytes have no zero bytes (helps
  # debugging when something goes wrong and we're staring at hex).
  let(:client_mask) { "\x37\xfa\x21\x3d".b }

  def make_pair
    server, client = UNIXSocket.pair
    [server, client]
  end

  def client_frame(opcode, payload, fin: true)
    Hyperion::WebSocket::Builder.build(
      opcode: opcode,
      payload: payload.b,
      fin: fin,
      mask: true,
      mask_key: client_mask
    )
  end

  def read_frame_from(io, timeout: 1)
    deadline = Time.now + timeout
    buf = +''
    loop do
      raise "timeout reading frame from peer (got #{buf.bytes.inspect})" if Time.now > deadline

      ready, = IO.select([io], nil, nil, 0.05)
      next unless ready

      chunk = io.read_nonblock(4096, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      buf << chunk
      result = begin
        Hyperion::WebSocket::Parser.parse_with_cursor(buf.dup, 0)
      rescue StandardError
        :incomplete
      end
      next if result == :incomplete

      frame, advance = result
      return [frame, buf.byteslice(0, advance), buf.byteslice(advance, buf.bytesize - advance)]
    end
  end

  describe 'round-trip text message' do
    it 'reassembles a single masked text "Hello" into [:text, "Hello"]' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      client.write(client_frame(:text, 'Hello'))

      result = ws.recv
      expect(result).to eq([:text, 'Hello'])
      expect(result[1].encoding).to eq(Encoding::UTF_8)
      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'round-trip binary message' do
    it 'returns [:binary, bytes] for a masked binary frame' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      payload = "\x00\x01\x02\xff".b
      client.write(client_frame(:binary, payload))

      type, bin = ws.recv
      expect(type).to eq(:binary)
      expect(bin).to eq(payload)
      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'fragmented message reassembly' do
    it 'joins [text fin=0 "He"] + [continuation fin=1 "llo"] into "Hello"' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      client.write(client_frame(:text, 'He', fin: false))
      client.write(client_frame(:continuation, 'llo', fin: true))

      expect(ws.recv).to eq([:text, 'Hello'])
      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'ping → auto pong' do
    it 'auto-responds with a pong containing the same payload and fires on_ping' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      observed = nil
      ws.on_ping { |payload| observed = payload }

      client.write(client_frame(:ping, "\x01\x02\x03\x04"))

      # Run recv on a thread; it'll process the ping and then block
      # on the next frame. We pop a text frame in to wake it.
      t = Thread.new { ws.recv }
      pong_frame, _wire, _rest = read_frame_from(client)
      expect(pong_frame.opcode).to eq(:pong)
      expect(pong_frame.payload.bytes).to eq([0x01, 0x02, 0x03, 0x04])

      client.write(client_frame(:text, 'wake'))
      expect(t.value).to eq([:text, 'wake'])

      expect(observed).to eq("\x01\x02\x03\x04".b)
      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'close handshake (peer-initiated)' do
    it 'returns [:close, code, reason] and refuses subsequent recv' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      close_payload = String.new(encoding: Encoding::ASCII_8BIT)
      close_payload << "\x03\xe8".b # 1000 big-endian
      close_payload << 'bye'.b
      client.write(client_frame(:close, close_payload))

      result = ws.recv
      expect(result).to eq([:close, 1000, 'bye'])
      expect { ws.recv }.to raise_error(Hyperion::WebSocket::StateError)

      # Close echo should have been written back.
      echo_frame, _wire, _rest = read_frame_from(client)
      expect(echo_frame.opcode).to eq(:close)
      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'close (locally initiated)' do
    it 'writes a close frame and closes the socket within drain_timeout' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      t = Thread.new { ws.close(code: 1001, reason: 'leaving', drain_timeout: 1) }
      close_frame, _wire, _rest = read_frame_from(client)
      expect(close_frame.opcode).to eq(:close)
      # Bytes 0-1 should be 1001 big-endian; rest is the reason.
      code = (close_frame.payload.getbyte(0) << 8) | close_frame.payload.getbyte(1)
      expect(code).to eq(1001)
      expect(close_frame.payload.byteslice(2, close_frame.payload.bytesize - 2).b).to eq('leaving'.b)

      # Reply with our close so the drain unblocks promptly.
      client.write(client_frame(:close, "\x03\xe9".b + 'ok'.b))
      t.join(2)

      expect(ws.closed?).to be(true)
      client.close
    end
  end

  describe 'message-too-big' do
    it 'sends close 1009 and returns [:close, 1009, _]; subsequent recv raises' do
      server, client = make_pair
      ws = described_class.new(server, max_message_bytes: 16,
                                       ping_interval: nil, idle_timeout: nil)

      client.write(client_frame(:text, 'x' * 32))

      result = ws.recv
      expect(result[0]).to eq(:close)
      expect(result[1]).to eq(1009)
      expect { ws.recv }.to raise_error(Hyperion::WebSocket::StateError)

      close_frame, _wire, _rest = read_frame_from(client)
      expect(close_frame.opcode).to eq(:close)
      code = (close_frame.payload.getbyte(0) << 8) | close_frame.payload.getbyte(1)
      expect(code).to eq(1009)

      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'invalid UTF-8 in a text frame' do
    it 'sends close 1007 (Invalid Frame Payload Data) per RFC 6455 §8.1' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      # 0xFF on its own is never valid UTF-8.
      client.write(client_frame(:text, "\xff\xfe".b))

      result = ws.recv
      expect(result[0]).to eq(:close)
      expect(result[1]).to eq(1007)

      close_frame, _wire, _rest = read_frame_from(client)
      expect(close_frame.opcode).to eq(:close)
      code = (close_frame.payload.getbyte(0) << 8) | close_frame.payload.getbyte(1)
      expect(code).to eq(1007)

      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'server frames are unmasked' do
    it 'writes 81 05 48 65 6c 6c 6f for send("Hello")' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      ws.send('Hello')
      frame_bytes = client.read_nonblock(4096, exception: false)
      expect(frame_bytes.bytes).to eq([0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f])

      ws.close(drain_timeout: 0)
      client.close
    end
  end

  describe 'C ext unmask path' do
    it 'invokes Hyperion::WebSocket::CFrame.unmask when native is available' do
      skip 'pure-Ruby fallback in use' unless Hyperion::WebSocket::NATIVE_AVAILABLE

      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      original = Hyperion::WebSocket::CFrame.method(:unmask)
      called = 0
      Hyperion::WebSocket::CFrame.singleton_class.define_method(:unmask) do |*args, **kw|
        called += 1
        original.call(*args, **kw)
      end

      begin
        client.write(client_frame(:text, 'Hello'))
        expect(ws.recv).to eq([:text, 'Hello'])
        expect(called).to be >= 1
      ensure
        Hyperion::WebSocket::CFrame.singleton_class.define_method(:unmask, &original)
        ws.close(drain_timeout: 0)
        client.close
      end
    end
  end
end
