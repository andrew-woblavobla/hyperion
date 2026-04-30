# frozen_string_literal: true

require 'socket'
require 'base64'
require 'digest/sha1'

# WS-2 (2.1.0) — end-to-end integration smoke for the RFC 6455 handshake.
#
# Boots a real Hyperion server on a random port, sends a hand-rolled WS
# upgrade request over a raw TCPSocket, and asserts the server either
# (a) gives the app the chance to write a 101 (the :ok path) or
# (b) short-circuits a 400/426 BEFORE invoking the app for malformed
# requests. The "(a)" assertion uses an app that hijacks the socket and
# writes the canonical 101 response itself — that's the contract WS-2
# documented for ActionCable / faye-websocket compatibility.
RSpec.describe 'WebSocket handshake integration' do
  let(:hijack_app) do
    lambda do |env|
      tag, accept, sub = env['hyperion.websocket.handshake']
      raise 'expected :ok handshake' unless tag == :ok

      io = env['rack.hijack'].call
      io.write(Hyperion::WebSocket::Handshake.build_101_response(accept, sub))
      io.flush
      # Don't close — leave socket alive; client will close when done.
      [-1, {}, []]
    end
  end
  let(:rfc_key)    { 'dGhlIHNhbXBsZSBub25jZQ==' }
  let(:rfc_accept) { 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=' }

  def boot_server(app)
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app)
    server.listen
    port = server.port
    thread = Thread.new { server.start }

    # Wait until accept loop is ready.
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

  def send_handshake(port, key:, version: '13', method: 'GET', upgrade: 'websocket', extra: {})
    sock = TCPSocket.new('127.0.0.1', port)
    headers = [
      "#{method} /chat HTTP/1.1",
      "Host: 127.0.0.1:#{port}",
      "Upgrade: #{upgrade}",
      'Connection: Upgrade',
      "Sec-WebSocket-Key: #{key}",
      "Sec-WebSocket-Version: #{version}"
    ]
    extra.each { |k, v| headers << "#{k}: #{v}" }
    sock.write("#{headers.join("\r\n")}\r\n\r\n")
    sock
  end

  it 'completes a valid handshake when the app writes the 101 from the hijacked socket' do
    server, port, thread = boot_server(hijack_app)
    sock = send_handshake(port, key: rfc_key)
    response = read_until(sock, "\r\n\r\n")

    expect(response).to start_with('HTTP/1.1 101 Switching Protocols')
    expect(response).to match(/sec-websocket-accept: #{Regexp.escape(rfc_accept)}/i)
  ensure
    sock&.close
    stop_server(server, thread)
  end

  it 'short-circuits a 400 when the client omits Sec-WebSocket-Key' do
    bad_app = ->(_env) { raise 'app should never be called for malformed handshakes' }
    server, port, thread = boot_server(bad_app)

    sock = TCPSocket.new('127.0.0.1', port)
    sock.write(
      "GET /chat HTTP/1.1\r\n" \
      "Host: 127.0.0.1:#{port}\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    response = read_until(sock, "\r\n\r\n")

    expect(response).to start_with('HTTP/1.1 400')
  ensure
    sock&.close
    stop_server(server, thread)
  end

  it 'short-circuits a 426 with version hint when Sec-WebSocket-Version is wrong' do
    bad_app = ->(_env) { raise 'app should never be called for unsupported version' }
    server, port, thread = boot_server(bad_app)

    sock = send_handshake(port, key: rfc_key, version: '8')
    response = read_until(sock, "\r\n\r\n")

    expect(response).to start_with('HTTP/1.1 426')
    expect(response).to match(/sec-websocket-version: 13/i)
  ensure
    sock&.close
    stop_server(server, thread)
  end

  it 'lets non-WebSocket Upgrade requests (e.g. h2c) flow to the app normally' do
    plain_app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok-plain']] }
    server, port, thread = boot_server(plain_app)

    sock = TCPSocket.new('127.0.0.1', port)
    sock.write(
      "GET / HTTP/1.1\r\n" \
      "Host: 127.0.0.1:#{port}\r\n" \
      "Upgrade: h2c\r\n" \
      "Connection: Upgrade\r\n\r\n"
    )
    response = read_until(sock, "\r\n\r\n")

    expect(response).to start_with('HTTP/1.1 200')
    expect(response).to include('ok-plain')
  ensure
    sock&.close
    stop_server(server, thread)
  end
end
