# frozen_string_literal: true

require 'openssl'
require 'socket'

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
