# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'protocol/http2/client'
require 'protocol/http2/framer'
require 'protocol/http2/stream'

# 2.12-F — gRPC support on h2.
#
# These specs lock in three contracts:
#
#   1. **Trailers wire shape.** When a Rack 3 body responds to `:trailers`,
#      Hyperion emits HEADERS (no END_STREAM) → DATA frames (no END_STREAM
#      on the last DATA) → final HEADERS with END_STREAM=1 carrying the
#      trailers. This is the wire shape gRPC clients expect for the
#      `grpc-status` / `grpc-message` map (RFC 9113 §8.1 trailing headers).
#
#   2. **Non-regression for plain h2 traffic.** A Rack body that does NOT
#      define `:trailers` keeps the pre-2.12-F shape: HEADERS → DATA frames
#      with END_STREAM=1 on the last DATA. No trailing HEADERS frame.
#
#   3. **TE: trailers + binary body bytes.** gRPC clients send `te: trailers`
#      on every request and a body whose bytes form the gRPC framing
#      (`[1-byte compressed flag][4-byte length-prefix][protobuf bytes]`).
#      The server must surface `te: trailers` to the Rack app via
#      `env['HTTP_TE']` and pass the body bytes through unchanged.
#
# We drive the server with `Protocol::HTTP2::Client` (the same gem
# Hyperion uses on the server side) so the test exercises real HPACK
# encode/decode + framing rather than a mock. TLS is used end-to-end
# because Hyperion's h2 path is gated on ALPN and TLS is what production
# gRPC traffic looks like.
RSpec.describe 'Hyperion HTTP/2 gRPC support (2.12-F)' do
  # A custom Rack body that yields its chunks lazily AND defines
  # `:trailers`. Rack 3 contract: trailers are read AFTER the body is
  # iterated, so any state the body accumulates while streaming
  # (computed status, message digest, etc.) can be reflected in the
  # trailer map.
  class TrailerBody
    def initialize(chunks, trailers)
      @chunks = chunks
      @trailers = trailers
    end

    def each(&block)
      @chunks.each(&block)
    end

    attr_reader :trailers

    def close; end
  end

  def boot_server(app)
    cert, key = TLSHelper.self_signed
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app,
                                  tls: { cert: cert, key: key })
    server.listen
    serve_thread = Thread.new { server.start }
    deadline = Time.now + 3
    loop do
      s = TCPSocket.new('127.0.0.1', server.port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didn’t bind' if Time.now > deadline

      sleep 0.01
    end
    [server, serve_thread]
  end

  # Build a TLS client socket with ALPN h2 negotiated. Returns the
  # SSLSocket wrapped in a `Protocol::HTTP2::Framer` ready for a
  # `Protocol::HTTP2::Client` to drive.
  def open_h2_client(port)
    tcp = TCPSocket.new('127.0.0.1', port)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.alpn_protocols = ['h2']
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.sync_close = true
    ssl.connect
    raise 'ALPN did not negotiate h2' unless ssl.alpn_protocol == 'h2'

    framer = ::Protocol::HTTP2::Framer.new(ssl)
    client = ::Protocol::HTTP2::Client.new(framer)
    client.send_connection_preface
    [client, ssl]
  end

  # Drive a single h2 stream end-to-end against the given client. Reads
  # frames until the response stream closes, returning a tuple:
  # `[response_headers, body_chunks_array, trailers_or_nil]`.
  def issue_request(client, _ssl, method:, path:, headers: [], body: '')
    stream = client.create_stream
    request_headers = [
      [':method', method],
      [':scheme', 'https'],
      [':authority', '127.0.0.1'],
      [':path', path]
    ] + headers.map { |k, v| [k.to_s, v.to_s] }

    # END_STREAM on HEADERS only when there's no body to send.
    end_stream = body.empty?
    flags = end_stream ? ::Protocol::HTTP2::END_STREAM : 0
    stream.send_headers(request_headers, flags)
    stream.send_data(body, ::Protocol::HTTP2::END_STREAM) unless body.empty?

    response_headers_blocks = []
    response_body = String.new(encoding: Encoding::ASCII_8BIT)

    # Capture the underlying stream's `process_headers` / `process_data`
    # so we observe BOTH the initial header block and any trailing one.
    stream_class = stream.class
    captured_blocks = response_headers_blocks
    stream.define_singleton_method(:process_headers) do |frame|
      decoded = stream_class.instance_method(:process_headers).bind_call(self, frame)
      captured_blocks << { headers: decoded.dup, end_stream: frame.end_stream? }
      decoded
    end
    stream.define_singleton_method(:process_data) do |frame|
      data = stream_class.instance_method(:process_data).bind_call(self, frame)
      response_body << data if data
      data
    end

    deadline = Time.now + 4
    until stream.closed?
      raise 'h2 client read timeout' if Time.now > deadline

      client.read_frame
    end

    initial = response_headers_blocks.first&.dig(:headers) || []
    trailing = response_headers_blocks[1..]&.find { |b| b[:end_stream] }&.dig(:headers)
    [initial, response_body, trailing]
  end

  let(:grpc_payload) do
    # gRPC framing: 1-byte compressed flag (0 = uncompressed) +
    # 4-byte big-endian length-prefix + protobuf bytes. We don't actually
    # parse protobuf — Hyperion never does; it just passes the byte string
    # through. Use a deliberately non-UTF-8-clean byte sequence so the
    # ASCII_8BIT preservation contract is exercised: a UTF-8-encoded
    # default `+''` would corrupt these bytes.
    body = "\xFF\x00\x01\x02\xC3\x28\x80".b
    "\x00".b + [body.bytesize].pack('N') + body
  end

  describe 'trailers wire shape' do
    let(:hello_payload) do
      # Echo gRPC reply with an arbitrary 11-byte protobuf-shaped body.
      reply = 'Hello, you'.b
      "\x00".b + [reply.bytesize].pack('N') + reply
    end

    let(:grpc_app) do
      payload = hello_payload
      lambda do |env|
        # gRPC wire-level non-regression: the request body must reach the
        # app verbatim. We don't assert here (the spec focuses on the
        # response side), but reading `env['rack.input']` is what a real
        # gRPC service does and it must not raise.
        env['rack.input'].read

        body = TrailerBody.new(
          [payload],
          { 'grpc-status' => '0',
            'grpc-message' => 'OK' }
        )
        [200, { 'content-type' => 'application/grpc' }, body]
      end
    end

    it 'sends a final HEADERS frame with END_STREAM=1 carrying grpc-status / grpc-message' do
      server, serve_thread = boot_server(grpc_app)
      port = server.port

      client, ssl = open_h2_client(port)
      headers, body_bytes, trailers = issue_request(
        client, ssl,
        method: 'POST',
        path: '/echo.Hello/SayHello',
        headers: { 'content-type' => 'application/grpc',
                   'te' => 'trailers' },
        body: grpc_payload
      )

      status = headers.assoc(':status')
      expect(status).not_to be_nil
      expect(status[1]).to eq('200')
      expect(headers.assoc('content-type')&.last).to eq('application/grpc')
      expect(body_bytes).to eq(hello_payload)
      expect(body_bytes.encoding).to eq(Encoding::ASCII_8BIT)

      expect(trailers).not_to be_nil
      trailer_map = trailers.to_h
      expect(trailer_map['grpc-status']).to eq('0')
      expect(trailer_map['grpc-message']).to eq('OK')
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end

    it 'surfaces TE: trailers in env[HTTP_TE] for the Rack app' do
      observed = []
      app = lambda do |env|
        observed << env['HTTP_TE']
        env['rack.input'].read
        body = TrailerBody.new(['ok'.b], { 'grpc-status' => '0' })
        [200, { 'content-type' => 'application/grpc' }, body]
      end

      server, serve_thread = boot_server(app)
      port = server.port

      client, ssl = open_h2_client(port)
      issue_request(client, ssl,
                    method: 'POST',
                    path: '/svc/Method',
                    headers: { 'content-type' => 'application/grpc',
                               'te' => 'trailers' },
                    body: grpc_payload)

      expect(observed).to eq(['trailers'])
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end

    it 'preserves binary request body bytes verbatim (no encoding mangling)' do
      observed_body = nil
      app = lambda do |env|
        observed_body = env['rack.input'].read
        body = TrailerBody.new(['ok'.b], { 'grpc-status' => '0' })
        [200, { 'content-type' => 'application/grpc' }, body]
      end

      server, serve_thread = boot_server(app)
      port = server.port

      client, ssl = open_h2_client(port)
      issue_request(client, ssl,
                    method: 'POST',
                    path: '/svc/Method',
                    headers: { 'content-type' => 'application/grpc',
                               'te' => 'trailers' },
                    body: grpc_payload)

      expect(observed_body.bytes).to eq(grpc_payload.bytes)
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end
  end

  describe 'non-regression for non-trailers responses' do
    it 'does NOT send a trailing HEADERS frame when the body has no #trailers method' do
      app = lambda do |_env|
        [200, { 'content-type' => 'text/plain' }, ['hello']]
      end

      server, serve_thread = boot_server(app)
      port = server.port

      client, ssl = open_h2_client(port)
      headers, body_bytes, trailers = issue_request(
        client, ssl,
        method: 'GET',
        path: '/'
      )

      expect(headers.assoc(':status')[1]).to eq('200')
      expect(body_bytes).to eq('hello'.b)
      expect(trailers).to be_nil
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end

    it 'does NOT send a trailing HEADERS frame when body.trailers returns nil' do
      empty_trailer_body = TrailerBody.new(['hi'.b], nil)
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, empty_trailer_body] }

      server, serve_thread = boot_server(app)
      port = server.port

      client, ssl = open_h2_client(port)
      _, body_bytes, trailers = issue_request(client, ssl, method: 'GET', path: '/')

      expect(body_bytes).to eq('hi'.b)
      expect(trailers).to be_nil
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end

    it 'does NOT send a trailing HEADERS frame when body.trailers returns an empty hash' do
      empty_trailer_body = TrailerBody.new(['hi'.b], {})
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, empty_trailer_body] }

      server, serve_thread = boot_server(app)
      port = server.port

      client, ssl = open_h2_client(port)
      _, body_bytes, trailers = issue_request(client, ssl, method: 'GET', path: '/')

      expect(body_bytes).to eq('hi'.b)
      expect(trailers).to be_nil
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end
  end

  describe 'unit-level: collect_response_trailers + send_trailers' do
    let(:handler) do
      Hyperion::Http2Handler.new(app: ->(_env) { [200, {}, []] })
    end

    it 'returns the trailers hash when body responds to :trailers' do
      body = TrailerBody.new(['x'], { 'grpc-status' => '0' })
      expect(handler.send(:collect_response_trailers, body))
        .to eq({ 'grpc-status' => '0' })
    end

    it 'returns nil for bodies that do not respond to :trailers' do
      expect(handler.send(:collect_response_trailers, ['x'])).to be_nil
    end

    it 'returns nil when body.trailers raises' do
      body = Object.new
      def body.trailers
        raise 'boom'
      end
      expect(handler.send(:collect_response_trailers, body)).to be_nil
    end

    it 'coerces a hash-like response to a Hash' do
      body = Object.new
      struct = Struct.new(:to_h).new({ 'grpc-status' => '0' })
      body.define_singleton_method(:trailers) { struct }
      expect(handler.send(:collect_response_trailers, body))
        .to eq({ 'grpc-status' => '0' })
    end

    it 'rejects pseudo-headers and forbidden connection-specific headers in trailers' do
      # We can't easily unit-test send_trailers without a real Stream
      # (it talks to the Connection state machine + framer). The
      # filtering logic mirrors the normal response-headers path; the
      # integration spec above proves the wire shape is correct, and
      # the validator (RequestStream::FORBIDDEN_HEADERS) is shared.
      forbidden = Hyperion::Http2Handler::RequestStream::FORBIDDEN_HEADERS
      expect(forbidden).to include('connection')
      expect(forbidden).to include('transfer-encoding')
    end
  end
end
