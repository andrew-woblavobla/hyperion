# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/connection'
require 'hyperion/websocket/close_codes'
require 'socket'

# 2.5-A — RFC 6455 §7.4.1 close-code validation specs.
#
# Closes the 10 autobahn-testsuite section-7 failures from 2.4-D. The
# server MUST reject invalid peer close codes with 1002 (Protocol
# Error) rather than echoing them back.
RSpec.describe 'WebSocket close-payload validation' do
  let(:client_mask) { "\x37\xfa\x21\x3d".b }

  def make_pair
    UNIXSocket.pair
  end

  def client_close_frame(code: nil, reason: '', raw_payload: nil)
    payload = raw_payload || begin
      buf = String.new(encoding: Encoding::ASCII_8BIT)
      if code
        buf << ((code >> 8) & 0xFF).chr
        buf << (code & 0xFF).chr
      end
      buf << reason.b unless reason.nil? || reason.empty?
      buf
    end
    Hyperion::WebSocket::Builder.build(
      opcode: :close,
      payload: payload.b,
      fin: true,
      mask: true,
      mask_key: client_mask
    )
  end

  def read_close_response(io, timeout: 1)
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

      frame, = result
      return frame
    end
  end

  def response_code(frame)
    return nil if frame.payload.bytesize < 2

    (frame.payload.getbyte(0) << 8) | frame.payload.getbyte(1)
  end

  describe Hyperion::WebSocket::CloseCodes do
    describe '.validate' do
      # The 10 autobahn case codes from 2.4-D's failures.
      [0, 999, 1004, 1100, 1016, 2000, 2999].each do |code|
        it "rejects invalid/reserved code #{code}" do
          verdict = described_class.validate(code)
          expect(verdict).not_to eq(:ok), "expected #{code} to be invalid, got :ok"
        end
      end

      it 'rejects 1005 (No Status Received) as :no_status_on_wire' do
        expect(described_class.validate(1005)).to eq(:no_status_on_wire)
      end

      it 'rejects 1006 (Abnormal Closure) as :no_status_on_wire' do
        expect(described_class.validate(1006)).to eq(:no_status_on_wire)
      end

      it 'classifies 1100 as :reserved' do
        expect(described_class.validate(1100)).to eq(:reserved)
      end

      it 'classifies 1016 as :reserved' do
        expect(described_class.validate(1016)).to eq(:reserved)
      end

      it 'classifies 2999 as :reserved (last in the IETF reserved range)' do
        expect(described_class.validate(2999)).to eq(:reserved)
      end

      it 'classifies 0 as :invalid' do
        expect(described_class.validate(0)).to eq(:invalid)
      end

      it 'classifies 999 as :invalid' do
        expect(described_class.validate(999)).to eq(:invalid)
      end

      it 'classifies 1004 as :invalid (reserved code, no defined meaning)' do
        expect(described_class.validate(1004)).to eq(:invalid)
      end

      it 'classifies 5000 as :invalid (out of any defined range)' do
        expect(described_class.validate(5000)).to eq(:invalid)
      end

      # The 10 autobahn case codes — verify defined codes accept.
      it 'accepts 1015 (TLS handshake) — defined code, NOT among the 10 failures' do
        expect(described_class.validate(1015)).to eq(:ok)
      end

      [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015,
       3000, 3500, 3999, 4000, 4500, 4999].each do |code|
        it "accepts defined code #{code}" do
          expect(described_class.validate(code)).to eq(:ok)
        end
      end
    end

    describe '.invalid?' do
      it 'returns true for 1005 / 1006 / 1004 / 999' do
        expect(described_class.invalid?(1005)).to be(true)
        expect(described_class.invalid?(1006)).to be(true)
        expect(described_class.invalid?(1004)).to be(true)
        expect(described_class.invalid?(999)).to be(true)
      end

      it 'returns false for 1000 / 1015 / 3000 / 4500' do
        expect(described_class.invalid?(1000)).to be(false)
        expect(described_class.invalid?(1015)).to be(false)
        expect(described_class.invalid?(3000)).to be(false)
        expect(described_class.invalid?(4500)).to be(false)
      end
    end
  end

  describe Hyperion::WebSocket::Connection do
    # The 10 autobahn case codes from 2.4-D's section-7 failures. All
    # should be rejected with 1002 (or 1006 — also invalid). 1015 is
    # explicitly NOT in this list because it IS a defined code.
    [0, 999, 1004, 1005, 1006, 1016, 1100, 2000, 2999].each do |bad_code|
      it "rejects close code #{bad_code} with a 1002 (Protocol Error) response" do
        server, client = make_pair
        ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

        client.write(client_close_frame(code: bad_code, reason: 'oops'))

        result = ws.recv
        expect(result[0]).to eq(:close)
        # The peer's code is surfaced verbatim to the caller (so the
        # operator can see what arrived), but the wire response is 1002.
        expect(result[1]).to eq(bad_code)

        echo = read_close_response(client)
        expect(echo.opcode).to eq(:close)
        expect(response_code(echo)).to eq(1002),
                                       "expected 1002, got #{response_code(echo)} for code=#{bad_code}"

        ws.close(drain_timeout: 0)
        client.close
      end
    end

    # Defined / valid codes — accept and echo back.
    [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015,
     3000, 3500, 3999, 4000, 4500, 4999].each do |good_code|
      it "accepts close code #{good_code} and echoes it back" do
        server, client = make_pair
        ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

        client.write(client_close_frame(code: good_code, reason: 'bye'))

        result = ws.recv
        expect(result[0]).to eq(:close)
        expect(result[1]).to eq(good_code)

        echo = read_close_response(client)
        expect(echo.opcode).to eq(:close)
        expect(response_code(echo)).to eq(good_code),
                                       "expected echo of #{good_code}, got #{response_code(echo)}"

        ws.close(drain_timeout: 0)
        client.close
      end
    end

    it 'sends 1002 for a 1-byte close payload (status code cannot fit)' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      client.write(client_close_frame(raw_payload: "\x03".b))

      result = ws.recv
      expect(result[0]).to eq(:close)

      echo = read_close_response(client)
      expect(response_code(echo)).to eq(1002)

      ws.close(drain_timeout: 0)
      client.close
    end

    it 'accepts an empty close payload (graceful close per RFC 6455 §5.5.1)' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      client.write(client_close_frame(raw_payload: ''.b))

      result = ws.recv
      expect(result).to eq([:close, nil, nil])

      echo = read_close_response(client)
      expect(echo.opcode).to eq(:close)
      # Empty inbound → we respond with a 1000 Normal close (and empty
      # reason). The peer didn't tell us a code, so we pick the default.
      expect(response_code(echo)).to eq(1000)

      ws.close(drain_timeout: 0)
      client.close
    end

    it 'sends 1007 for invalid UTF-8 in the close reason' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      # Valid code 1000, but reason bytes are not valid UTF-8.
      bad_reason = "\xff\xfe\xfd".b
      client.write(client_close_frame(raw_payload: "\x03\xe8".b + bad_reason))

      result = ws.recv
      expect(result[0]).to eq(:close)
      expect(result[1]).to eq(1000)

      echo = read_close_response(client)
      expect(response_code(echo)).to eq(1007),
                                     "expected 1007 (Invalid Frame Payload Data), got #{response_code(echo)}"

      ws.close(drain_timeout: 0)
      client.close
    end

    it 'accepts a valid UTF-8 reason and echoes the close back cleanly' do
      server, client = make_pair
      ws = described_class.new(server, ping_interval: nil, idle_timeout: nil)

      # Multi-byte UTF-8: "héllo" — h, é (0xC3 0xA9), l, l, o.
      reason = "h\xC3\xA9llo".b
      client.write(client_close_frame(raw_payload: "\x03\xe8".b + reason))

      result = ws.recv
      expect(result[0]).to eq(:close)
      expect(result[1]).to eq(1000)
      expect(result[2].force_encoding(Encoding::UTF_8)).to eq('héllo')

      echo = read_close_response(client)
      expect(response_code(echo)).to eq(1000)

      ws.close(drain_timeout: 0)
      client.close
    end
  end
end
