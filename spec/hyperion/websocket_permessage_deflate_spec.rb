# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/handshake'
require 'hyperion/websocket/connection'
require 'socket'
require 'zlib'

# 2.3-C — RFC 7692 permessage-deflate.  Three layers of coverage:
#
#   1. Handshake negotiation (Hyperion::WebSocket::Handshake.validate)
#   2. Frame-builder + parser RSV1 contract (CFrame.build / parse)
#   3. End-to-end Connection#send / #recv with the extension active
#
# The test client side runs Zlib::Deflate / Zlib::Inflate by hand so we
# exercise the wire format symmetrically; the server side rides on the
# Connection helpers.
RSpec.describe 'Hyperion::WebSocket permessage-deflate (RFC 7692)' do
  let(:valid_key) { 'AAAAAAAAAAAAAAAAAAAAAA==' }
  let(:client_mask) { "\x37\xfa\x21\x3d".b }

  def base_env(overrides = {})
    {
      'REQUEST_METHOD' => 'GET',
      'SERVER_PROTOCOL' => 'HTTP/1.1',
      'HTTP_HOST' => 'example.com:8080',
      'HTTP_UPGRADE' => 'websocket',
      'HTTP_CONNECTION' => 'Upgrade',
      'HTTP_SEC_WEBSOCKET_KEY' => valid_key,
      'HTTP_SEC_WEBSOCKET_VERSION' => '13'
    }.merge(overrides)
  end

  # ----------------------------------------------------------------
  # Layer 1 — handshake negotiation
  # ----------------------------------------------------------------
  describe 'handshake negotiation' do
    it 'accepts a bare permessage-deflate offer' do
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(
        base_env('HTTP_SEC_WEBSOCKET_EXTENSIONS' => 'permessage-deflate')
      )
      expect(tag).to eq(:ok)
      expect(ext).to eq(
        permessage_deflate: {
          server_no_context_takeover: false,
          client_no_context_takeover: false,
          server_max_window_bits: 15,
          client_max_window_bits: 15
        }
      )
    end

    it 'echoes server_no_context_takeover when the client offers it' do
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(
        base_env('HTTP_SEC_WEBSOCKET_EXTENSIONS' =>
                 'permessage-deflate; server_no_context_takeover')
      )
      expect(tag).to eq(:ok)
      expect(ext[:permessage_deflate][:server_no_context_takeover]).to eq(true)
      header = Hyperion::WebSocket::Handshake.format_extensions_header(ext)
      expect(header).to include('server_no_context_takeover')
    end

    it 'returns no extension when the client did not offer it' do
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(base_env)
      expect(tag).to eq(:ok)
      expect(ext).to eq({})
      expect(Hyperion::WebSocket::Handshake.format_extensions_header(ext)).to be_nil
    end

    it 'picks the first acceptable offer when the client lists multiple' do
      # First offer has unknown param `garbage` → reject; second is
      # plain permessage-deflate → accept.
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(
        base_env('HTTP_SEC_WEBSOCKET_EXTENSIONS' =>
                 'permessage-deflate; garbage_param, permessage-deflate')
      )
      expect(tag).to eq(:ok)
      expect(ext[:permessage_deflate]).not_to be_nil
    end

    it 'never advertises the extension when policy is :off' do
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(
        base_env('HTTP_SEC_WEBSOCKET_EXTENSIONS' => 'permessage-deflate'),
        permessage_deflate: :off
      )
      expect(tag).to eq(:ok)
      expect(ext).to eq({})
    end

    it 'rejects the handshake (400) when policy is :on and client did not offer' do
      tag, body, = Hyperion::WebSocket::Handshake.validate(
        base_env, permessage_deflate: :on
      )
      expect(tag).to eq(:bad_request)
      expect(body).to match(/permessage-deflate/i)
    end

    it 'accepts client_max_window_bits=10 (≤ default)' do
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(
        base_env('HTTP_SEC_WEBSOCKET_EXTENSIONS' =>
                 'permessage-deflate; client_max_window_bits=10')
      )
      expect(tag).to eq(:ok)
      expect(ext[:permessage_deflate][:client_max_window_bits]).to eq(10)
    end

    it 'silently drops an offer carrying an unknown parameter (and falls back to no-extension when there is no other offer)' do
      tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(
        base_env('HTTP_SEC_WEBSOCKET_EXTENSIONS' =>
                 'permessage-deflate; some_garbage_key=42')
      )
      expect(tag).to eq(:ok)
      expect(ext).to eq({})
    end
  end

  # ----------------------------------------------------------------
  # Layer 2 — wire vectors via Zlib (RFC 7692 §7.2.3.1)
  # ----------------------------------------------------------------
  describe 'RFC 7692 §7.2.3.1 "Hello" wire vector' do
    # The RFC's worked example: `Hello` deflates (with shared
    # context) to f2 48 cd c9 c9 07 00. With server_no_context_takeover
    # the inflater would reset between messages but the first message
    # has the same body. We just check the symmetric round-trip via
    # Zlib here — the bytes Zlib emits on macOS and Linux match the RFC.
    it 'round-trips "Hello" through raw deflate' do
      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -15)
      compressed = deflater.deflate('Hello', Zlib::SYNC_FLUSH)
      expect(compressed.byteslice(-4, 4)).to eq("\x00\x00\xff\xff".b)
      stripped = compressed.byteslice(0, compressed.bytesize - 4)

      inflater = Zlib::Inflate.new(-15)
      back = inflater.inflate(stripped + "\x00\x00\xff\xff".b)
      expect(back).to eq('Hello')
      deflater.close
      inflater.close
    end
  end

  # ----------------------------------------------------------------
  # Layer 3 — Connection round-trips
  # ----------------------------------------------------------------
  describe 'Connection#send compresses and Connection#recv decompresses' do
    let(:negotiated) do
      {
        permessage_deflate: {
          server_no_context_takeover: false,
          client_no_context_takeover: false,
          server_max_window_bits: 15,
          client_max_window_bits: 15
        }
      }
    end

    def make_pair
      UNIXSocket.pair
    end

    # Build a masked compressed frame the way a real client would —
    # deflate "Hello" with raw -15 window, strip trailer, set RSV1.
    def client_compressed_text_frame(client_deflater, payload, fin: true)
      compressed = client_deflater.deflate(payload, Zlib::SYNC_FLUSH)
      stripped = compressed.byteslice(0, compressed.bytesize - 4)
      Hyperion::WebSocket::Builder.build(
        opcode: :text, payload: stripped, fin: fin,
        mask: true, mask_key: client_mask, rsv1: true
      )
    end

    it 'decompresses an inbound RSV1 text frame end-to-end' do
      server, client = make_pair
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                extensions: negotiated
      )

      client_def = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -15)
      client.write(client_compressed_text_frame(client_def, 'Hello'))

      expect(ws.recv).to eq([:text, 'Hello'])
      ws.close(drain_timeout: 0)
      client.close
      client_def.close
    end

    it 'compresses an outbound text frame with RSV1 set' do
      server, client = make_pair
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                extensions: negotiated
      )

      ws.send('Hello')

      # Read back what we wrote on the wire.
      sleep 0.05
      bytes = client.read_nonblock(4096, exception: false)
      expect(bytes).to be_a(String)
      result = Hyperion::WebSocket::Parser.parse_with_cursor(bytes, 0)
      frame, _adv = result
      expect(frame.opcode).to eq(:text)
      expect(frame.rsv1).to eq(true)

      # Decompress on this side to verify byte-level correctness.
      client_inf = Zlib::Inflate.new(-15)
      back = client_inf.inflate(frame.payload + "\x00\x00\xff\xff".b)
      expect(back).to eq('Hello')

      ws.close(drain_timeout: 0)
      client.close
      client_inf.close
    end

    it 'round-trips a multi-message sequence with shared context (default takeover)' do
      server, client = make_pair
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                extensions: negotiated
      )

      sizes = []
      3.times do
        ws.send('hello hello hello hello hello')
        sleep 0.02
        bytes = client.read_nonblock(4096, exception: false)
        next if bytes == :wait_readable

        result = Hyperion::WebSocket::Parser.parse_with_cursor(bytes, 0)
        frame, _adv = result
        sizes << frame.payload.bytesize
      end

      # 2nd and 3rd messages have shared dictionary state →
      # compressed payload is smaller than the first (which has to
      # spell out the literal vocabulary).
      expect(sizes.length).to eq(3)
      expect(sizes[1]).to be <= sizes[0]
      expect(sizes[2]).to be <= sizes[0]

      ws.close(drain_timeout: 0)
      client.close
    end

    it 'no-takeover mode: every message compresses to the same size' do
      server, client = make_pair
      negotiated_no_takeover = {
        permessage_deflate: {
          server_no_context_takeover: true,
          client_no_context_takeover: true,
          server_max_window_bits: 15,
          client_max_window_bits: 15
        }
      }
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                extensions: negotiated_no_takeover
      )

      sizes = []
      3.times do
        ws.send('hello hello hello hello hello')
        sleep 0.02
        bytes = client.read_nonblock(4096, exception: false)
        next if bytes == :wait_readable

        result = Hyperion::WebSocket::Parser.parse_with_cursor(bytes, 0)
        frame, _adv = result
        sizes << frame.payload.bytesize
      end

      expect(sizes.uniq.length).to eq(1)

      ws.close(drain_timeout: 0)
      client.close
    end
  end

  # ----------------------------------------------------------------
  # Layer 4 — control-frame protections
  # ----------------------------------------------------------------
  describe 'control frames are never compressed' do
    let(:negotiated) do
      {
        permessage_deflate: {
          server_no_context_takeover: false,
          client_no_context_takeover: false,
          server_max_window_bits: 15,
          client_max_window_bits: 15
        }
      }
    end

    def make_pair
      UNIXSocket.pair
    end

    it 'send: ping frames carry RSV1=0 even when the extension is active' do
      server, client = UNIXSocket.pair
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                extensions: negotiated
      )

      # Use the private send_ping_frame path indirectly: the proactive
      # idle ping. Easiest is to call the Builder directly through
      # the wrapper's ping-after-idle hook, but here we just verify
      # the Builder's contract — control frames refuse rsv1.
      expect do
        Hyperion::WebSocket::Builder.build(
          opcode: :ping, payload: 'x', rsv1: true
        )
      end.to raise_error(ArgumentError, /control frame/i)

      ws.close(drain_timeout: 0)
      client.close
    end

    it 'recv: a ping with RSV1=1 triggers close 1002' do
      server, client = UNIXSocket.pair
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                extensions: negotiated
      )

      # Hand-craft a ping with RSV1 set + masked client frame.
      # 0xC9 = FIN=1, RSV1=1, opcode=ping. The C parser already
      # rejects this as :error → ProtocolError → close 1002.
      bad_ping = [0xC9, 0x80, *client_mask.bytes].pack('C*')
      client.write(bad_ping)

      expect { ws.recv }.to raise_error(Hyperion::WebSocket::StateError)
      expect(ws.close_code).to eq(Hyperion::WebSocket::CLOSE_PROTOCOL_ERROR)

      ws.close(drain_timeout: 0)
      client.close
    end
  end

  # ----------------------------------------------------------------
  # Layer 5 — compression bomb defense
  # ----------------------------------------------------------------
  describe 'compression bomb defense' do
    let(:negotiated) do
      {
        permessage_deflate: {
          server_no_context_takeover: false,
          client_no_context_takeover: false,
          server_max_window_bits: 15,
          client_max_window_bits: 15
        }
      }
    end

    it 'closes 1009 when an inflated payload exceeds max_message_bytes' do
      server, client = UNIXSocket.pair
      # Tight cap so the bomb is small enough to construct quickly.
      ws = Hyperion::WebSocket::Connection.new(
        server, ping_interval: nil, idle_timeout: nil,
                max_message_bytes: 64 * 1024,
                extensions: negotiated
      )

      # Build a deflate stream that compresses a giant repeated string.
      # 4 MB of zeroes deflates to ~4 KB but inflates back to 4 MB —
      # well above our 64 KB cap.
      big = "\x00".b * (4 * 1024 * 1024)
      client_def = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -15)
      compressed = client_def.deflate(big, Zlib::SYNC_FLUSH)
      stripped = compressed.byteslice(0, compressed.bytesize - 4)

      # Mask + frame with RSV1 set.
      frame = Hyperion::WebSocket::Builder.build(
        opcode: :binary, payload: stripped,
        mask: true, mask_key: client_mask, rsv1: true
      )
      client.write(frame)

      result = ws.recv
      expect(result.first).to eq(:close)
      expect(result[1]).to eq(Hyperion::WebSocket::CLOSE_MESSAGE_TOO_BIG)

      # Subsequent recv raises StateError (compression-bomb defense
      # marks the connection :closing immediately).
      expect { ws.recv }.to raise_error(Hyperion::WebSocket::StateError)

      ws.close(drain_timeout: 0)
      client.close
      client_def.close
    end
  end

  # ----------------------------------------------------------------
  # Layer 6 — Config knob plumbing
  # ----------------------------------------------------------------
  describe 'Hyperion::Config#websocket.permessage_deflate' do
    it 'defaults to :auto' do
      config = Hyperion::Config.new
      expect(config.websocket.permessage_deflate).to eq(:auto)
    end

    it 'is settable via the nested DSL' do
      config = Hyperion::Config.new
      Hyperion::Config::DSL.new(config).instance_eval do
        websocket do
          permessage_deflate :off
        end
      end
      expect(config.websocket.permessage_deflate).to eq(:off)
    end
  end
end
