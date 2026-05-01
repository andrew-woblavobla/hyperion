# frozen_string_literal: true

# 2.12-F gRPC end-to-end smoke test.
#
# Gated by `RUN_GRPC_SMOKE=1` because driving a real gRPC client requires
# the `grpc` Ruby gem, which pulls protobuf C bindings (~50 MB build).
# Most CI / dev machines won't have those; the durable coverage lives in
# `grpc_trailers_spec.rb` (raw HPACK + framer + Hyperion's h2 path) which
# proves the wire shape end-to-end without an external client.
#
# This spec runs Hyperion as a server and a real gRPC Ruby client in the
# same process. It uses the official `grpc` gem so any breakage in the
# trailers / TE / half-close path that the unit specs missed gets caught
# by an actual client implementation. Two-step opt-in:
#
#   1. `gem install grpc` (or add to Gemfile, then `bundle install`)
#   2. `RUN_GRPC_SMOKE=1 bundle exec rspec spec/hyperion/grpc_smoke_spec.rb`
#
# The test boots Hyperion on a TLS port with a hand-rolled Rack handler
# that translates one gRPC unary RPC (`Echo.Say`) into a Rack response.
# We don't generate `.proto` stubs (no protoc invocation in CI) — instead
# we use the gRPC generic-client path, which speaks the wire protocol
# directly. This keeps the spec self-contained and fast enough to run on
# every commit when explicitly enabled.
#
# If you're reading this in 2.13+ and the grpc gem has changed its public
# surface, the canonical Ruby gRPC docs are at
# https://github.com/grpc/grpc/tree/master/src/ruby — `GRPC::ClientStub`
# is the generic interface this spec targets.

return unless ENV['RUN_GRPC_SMOKE'] == '1'

begin
  require 'grpc'
rescue LoadError => e
  warn "grpc smoke spec skipped: #{e.message} (install with `gem install grpc`)"
  return
end

require 'openssl'
require 'socket'

RSpec.describe 'Hyperion 2.12-F gRPC end-to-end smoke', :grpc_smoke do
  # Minimal Rack app that handles one unary RPC. Reads the gRPC-framed
  # request, echoes the bytes back framed identically, and returns
  # `grpc-status: 0 / grpc-message: OK` in the trailers.
  let(:echo_app) do
    lambda do |env|
      raw = env['rack.input'].read.dup.force_encoding(Encoding::ASCII_8BIT)
      # gRPC framing: 1 byte compressed-flag + 4 byte big-endian length + payload.
      compressed = raw.byteslice(0).unpack1('C')
      length = raw.byteslice(1, 4).unpack1('N')
      payload = raw.byteslice(5, length)

      reply_payload = payload # Echo
      reply = "\x00".b + [reply_payload.bytesize].pack('N') + reply_payload
      _ = compressed # quiet unused-var lint; kept for parity with what a real impl would inspect

      body = Class.new do
        def initialize(reply) = @reply = reply
        def each = yield @reply
        def trailers = { 'grpc-status' => '0', 'grpc-message' => 'OK' }
        def close; end
      end.new(reply)

      [200, { 'content-type' => 'application/grpc' }, body]
    end
  end

  it 'serves a unary RPC end-to-end and surfaces grpc-status=0 in trailers' do
    cert, key = TLSHelper.self_signed
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: echo_app,
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
    port = server.port

    # Insecure channel over TLS (self-signed cert) — bypass cert
    # verification only because TLSHelper.self_signed is by design
    # ephemeral. Production clients MUST verify.
    creds = GRPC::Core::ChannelCredentials.new(cert.to_pem)
    channel = GRPC::Core::Channel.new(
      "127.0.0.1:#{port}", { 'grpc.ssl_target_name_override' => 'localhost' }, creds
    )
    stub = GRPC::ClientStub.new(channel, GRPC::Core::TimeConsts::INFINITE_FUTURE,
                                channel_override: channel)
    # Call signature: request_request, marshal, unmarshal, deadline, etc.
    # We use raw byte marshalling — no .proto compilation needed.
    request = 'echo-payload-bytes'
    response = stub.request_response(
      '/echo.Echo/Say',
      request,
      ->(s) { s }, # marshal
      ->(s) { s }, # unmarshal
      timeout: 4
    )
    expect(response).to eq(request)
  ensure
    server&.stop
    serve_thread&.join(2)
  end
end
