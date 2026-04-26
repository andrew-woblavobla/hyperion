# frozen_string_literal: true

require 'openssl'
require 'socket'

# RFC 7540 §8.1.2 request validation. Each spec drives the validator on a
# `RequestStream` allocated without its parent initializer (the parent needs
# a real `Protocol::HTTP2::Connection`, which we don't want for a pure
# header-validation unit test). After populating `@request_headers` we call
# the same validation hook the dispatch loop relies on and assert
# `protocol_error?`.
RSpec.describe Hyperion::Http2Handler::RequestStream do
  # Build a stream with the validation-only state initialised, skipping the
  # parent `Protocol::HTTP2::Stream#initialize` (which needs a connection).
  def build_stream
    described_class.allocate.tap do |s|
      s.instance_variable_set(:@request_headers, [])
      s.instance_variable_set(:@request_body, +'')
      s.instance_variable_set(:@request_body_bytes, 0)
      s.instance_variable_set(:@request_complete, false)
      s.instance_variable_set(:@protocol_error_reason, nil)
      s.instance_variable_set(:@declared_content_length, nil)
    end
  end

  def with_headers(headers)
    stream = build_stream
    stream.instance_variable_set(:@request_headers, headers)
    stream.validate_request_headers!
    stream
  end

  describe 'pseudo-header rules (§8.1.2.1)' do
    it 'accepts a well-formed GET' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/'],
                              [':authority', 'example.com'],
                              ['accept', '*/*']
                            ])
      expect(stream.protocol_error?).to be(false)
    end

    it 'rejects unknown pseudo-headers' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/'],
                              [':unknown', 'foo']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include(':unknown')
    end

    it 'rejects :status pseudo-header in requests (response-only)' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/'],
                              [':status', '200']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include(':status')
    end

    it 'rejects pseudo-headers that appear after a regular header' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              ['x-custom', 'a'],
                              [':path', '/']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('after regular header')
    end

    it 'rejects requests missing :method' do
      stream = with_headers([
                              [':scheme', 'https'],
                              [':path', '/']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include(':method')
    end

    it 'rejects requests missing :scheme' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':path', '/']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include(':scheme')
    end

    it 'rejects requests with empty :path' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include(':path')
    end

    it 'rejects duplicated :method' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':method', 'POST'],
                              [':scheme', 'https'],
                              [':path', '/']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('duplicated')
    end

    it 'rejects duplicated :path' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/a'],
                              [':path', '/b']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('duplicated')
    end
  end

  describe 'connection-specific headers (§8.1.2.2)' do
    %w[connection transfer-encoding keep-alive upgrade proxy-connection].each do |forbidden|
      it "rejects #{forbidden} header" do
        stream = with_headers([
                                [':method', 'GET'],
                                [':scheme', 'https'],
                                [':path', '/'],
                                [forbidden, 'whatever']
                              ])
        expect(stream.protocol_error?).to be(true)
        expect(stream.protocol_error_reason).to include(forbidden)
      end
    end

    it 'accepts TE: trailers (case-insensitive)' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/'],
                              ['te', 'Trailers']
                            ])
      expect(stream.protocol_error?).to be(false)
    end

    it 'rejects TE header with value other than trailers' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/'],
                              ['te', 'gzip']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('TE')
    end

    it 'rejects uppercase header names (§8.1.2)' do
      stream = with_headers([
                              [':method', 'GET'],
                              [':scheme', 'https'],
                              [':path', '/'],
                              ['Host', 'example.com']
                            ])
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('uppercase')
    end
  end

  describe 'CONNECT method (§8.3)' do
    it 'requires :authority and forbids :scheme/:path' do
      stream = with_headers([
                              [':method', 'CONNECT'],
                              [':authority', 'example.com:443']
                            ])
      expect(stream.protocol_error?).to be(false)
    end

    it 'rejects CONNECT with :scheme' do
      stream = with_headers([
                              [':method', 'CONNECT'],
                              [':scheme', 'https'],
                              [':authority', 'example.com:443']
                            ])
      expect(stream.protocol_error?).to be(true)
    end

    it 'rejects CONNECT without :authority' do
      stream = with_headers([
                              [':method', 'CONNECT']
                            ])
      expect(stream.protocol_error?).to be(true)
    end
  end

  describe 'content-length consistency (§8.1.2.6)' do
    it 'accepts matching content-length' do
      stream = build_stream
      stream.instance_variable_set(:@request_headers, [
                                     [':method', 'POST'],
                                     [':scheme', 'https'],
                                     [':path', '/'],
                                     ['content-length', '5']
                                   ])
      stream.validate_request_headers!
      expect(stream.protocol_error?).to be(false)

      # Simulate 5 bytes of DATA arriving across one or more frames.
      stream.instance_variable_set(:@request_body_bytes, 5)
      stream.validate_body_length!
      expect(stream.protocol_error?).to be(false)
    end

    it 'rejects content-length mismatch (declared > received)' do
      stream = build_stream
      stream.instance_variable_set(:@request_headers, [
                                     [':method', 'POST'],
                                     [':scheme', 'https'],
                                     [':path', '/'],
                                     ['content-length', '100']
                                   ])
      stream.validate_request_headers!
      stream.instance_variable_set(:@request_body_bytes, 50)
      stream.validate_body_length!
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('content-length mismatch')
    end

    it 'rejects content-length mismatch (received > declared)' do
      stream = build_stream
      stream.instance_variable_set(:@request_headers, [
                                     [':method', 'POST'],
                                     [':scheme', 'https'],
                                     [':path', '/'],
                                     ['content-length', '5']
                                   ])
      stream.validate_request_headers!
      stream.instance_variable_set(:@request_body_bytes, 12)
      stream.validate_body_length!
      expect(stream.protocol_error?).to be(true)
      expect(stream.protocol_error_reason).to include('content-length mismatch')
    end
  end
end

RSpec.describe 'Hyperion HTTP/2 dispatch' do
  let(:app) { ->(env) { [200, { 'content-type' => 'text/plain' }, ["h2 #{env['PATH_INFO']}"]] } }

  it 'serves an HTTP/2 GET request via curl --http2' do
    skip 'curl with HTTP/2 support not on PATH' unless system('curl --version 2>/dev/null | grep -q HTTP2')

    cert, key = TLSHelper.self_signed
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app,
                                  tls: { cert: cert, key: key })
    server.listen
    port = server.port

    serve_thread = Thread.new { server.start }

    # Wait for bind.
    deadline = Time.now + 3
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didnt bind' if Time.now > deadline

      sleep 0.01
    end

    # Use curl --http2 to verify h2 dispatch end-to-end.
    output = `curl -sSk --http2 https://127.0.0.1:#{port}/test 2>/dev/null`
    expect(output).to eq('h2 /test')
  ensure
    server&.stop
    serve_thread&.join(2)
  end

  it 'serves multiple HTTP/2 streams concurrently' do
    skip 'curl with HTTP/2 support not on PATH' unless system('curl --version 2>/dev/null | grep -q HTTP2')

    slow_app = lambda do |env|
      sleep 0.1 if env['PATH_INFO'] == '/slow'
      [200, { 'content-type' => 'text/plain' }, ["served #{env['PATH_INFO']}"]]
    end

    cert, key = TLSHelper.self_signed
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: slow_app,
                                  tls: { cert: cert, key: key })
    server.listen
    port = server.port

    serve_thread = Thread.new { server.start }

    # Wait for bind.
    deadline = Time.now + 3
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didnt bind' if Time.now > deadline

      sleep 0.01
    end

    # Single curl invocation that fires 2 parallel h2 requests on one
    # connection (`-Z` = parallel, same host => connection reuse with --http2).
    started = Time.now
    output = `curl -sSk --http2 -Z https://127.0.0.1:#{port}/slow https://127.0.0.1:#{port}/fast 2>&1`
    elapsed = Time.now - started

    expect(output).to include('served /slow')
    expect(output).to include('served /fast')
    # Concurrent: should complete in ~0.1s + overhead, NOT 0.2s.
    expect(elapsed).to be < 0.4
  ensure
    server&.stop
    serve_thread&.join(2)
  end
end
