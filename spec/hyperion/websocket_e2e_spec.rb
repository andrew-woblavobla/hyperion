# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/connection'
require 'socket'
require 'base64'
require 'securerandom'

# WS-4 (2.1.0) — end-to-end smoke for the full WebSocket stack:
# Hyperion server boots on a random port, accepts an HTTP/1.1 →
# WebSocket upgrade, the Rack app hijacks the socket, hands it to a
# Hyperion::WebSocket::Connection, and echoes 100 messages each
# direction before closing cleanly with code 1000.
#
# Uses a hand-rolled raw-TCP client to avoid pulling in
# `websocket-client-simple` as a runtime/test dep — the gem already
# owns the framing primitives, so a minimal client is just
# Builder.build (mask: true) for sends and Parser.parse_with_cursor
# for receives. Keeps the dep surface to zero.
RSpec.describe 'WebSocket end-to-end echo smoke' do
  ECHO_APP = lambda do |env|
    result = env['hyperion.websocket.handshake']
    raise 'expected ws upgrade' unless result&.first == :ok

    socket = env['rack.hijack'].call
    socket.write(
      Hyperion::WebSocket::Handshake.build_101_response(result[1], result[2])
    )
    ws = Hyperion::WebSocket::Connection.new(
      socket,
      buffered: env['hyperion.hijack_buffered'],
      ping_interval: nil,
      idle_timeout: nil
    )

    100.times do
      type, payload = ws.recv
      break if type == :close || type.nil?

      ws.send(payload, opcode: type)
    end

    ws.close(code: 1000, drain_timeout: 1)
    [-1, {}, []]
  end

  def boot_server(app)
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app)
    server.listen
    port = server.port
    thread = Thread.new { server.start }

    deadline = Time.now + 2
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise "server didn't bind within 2s" if Time.now > deadline

      sleep 0.01
    end

    [server, port, thread]
  end

  def stop_server(server, thread)
    server&.stop
    thread&.join(2)
  end

  def upgrade(sock, port)
    key = Base64.strict_encode64(SecureRandom.bytes(16))
    sock.write(
      "GET /chat HTTP/1.1\r\n" \
      "Host: 127.0.0.1:#{port}\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Key: #{key}\r\n" \
      "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    # Read the 101 response.
    response = read_until(sock, "\r\n\r\n")
    raise "expected 101, got: #{response.lines.first}" unless response.start_with?('HTTP/1.1 101')
  end

  def read_until(socket, terminator, timeout: 2)
    buf = +''
    deadline = Time.now + timeout
    until buf.include?(terminator)
      raise 'timeout waiting for response' if Time.now > deadline

      ready, = IO.select([socket], nil, nil, 0.1)
      next unless ready

      chunk = socket.read_nonblock(4096, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      buf << chunk
    end
    buf
  end

  def send_masked(sock, opcode, payload)
    sock.write(
      Hyperion::WebSocket::Builder.build(
        opcode: opcode,
        payload: payload.b,
        mask: true,
        mask_key: SecureRandom.bytes(4)
      )
    )
  end

  # Read one full frame off the wire from the server (server frames
  # are unmasked). Buffers across reads — partial frames are fine.
  def recv_unmasked(sock, buf, timeout: 2)
    deadline = Time.now + timeout
    loop do
      result =
        begin
          Hyperion::WebSocket::Parser.parse_with_cursor(buf, 0)
        rescue Hyperion::WebSocket::ProtocolError
          :error
        end

      if result.is_a?(Array)
        frame, advance = result
        buf.replace(buf.byteslice(advance, buf.bytesize - advance))
        return frame
      end

      raise 'timeout reading frame' if Time.now > deadline

      ready, = IO.select([sock], nil, nil, 0.1)
      next unless ready

      chunk = sock.read_nonblock(4096, exception: false)
      raise 'peer EOF before frame complete' if chunk.nil?
      next if chunk == :wait_readable

      buf << chunk
    end
  end

  it 'echoes 100 text messages and closes with code 1000' do
    server, port, thread = boot_server(ECHO_APP)
    sock = TCPSocket.new('127.0.0.1', port)
    upgrade(sock, port)

    rx_buf = String.new(encoding: Encoding::ASCII_8BIT)
    latencies = []

    100.times do |i|
      msg = "ping-#{i}"
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      send_masked(sock, :text, msg)
      frame = recv_unmasked(sock, rx_buf)
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      latencies << ((t1 - t0) * 1000.0)

      expect(frame.opcode).to eq(:text)
      expect(frame.payload.force_encoding(Encoding::UTF_8)).to eq(msg)
    end

    # Send our close to make the app's loop exit cleanly. The app
    # writes its own close back; we accept either ordering.
    send_masked(sock, :close, "\x03\xe8".b + 'done'.b)
    final = recv_unmasked(sock, rx_buf)
    expect(final.opcode).to eq(:close)
    code = (final.payload.getbyte(0) << 8) | final.payload.getbyte(1)
    expect(code).to eq(1000)

    p50 = latencies.sort[latencies.size / 2]
    # Not asserting — just logging so devs running rspec see it. Anything
    # under a few ms means the read+frame+write pipeline is healthy on
    # localhost; CI runners may be slower without it indicating a regression.
    warn "[ws-e2e] p50 echo round-trip: #{p50.round(3)} ms (max=#{latencies.max.round(3)})"
  ensure
    sock&.close
    stop_server(server, thread)
  end
end
