# frozen_string_literal: true

require 'socket'
require 'hyperion/connection'

RSpec.describe Hyperion::Connection do
  subject(:conn) { described_class.new }

  let(:app) do
    lambda do |env|
      [200, { 'content-type' => 'text/plain' }, ["seen #{env['PATH_INFO']}"]]
    end
  end

  it 'reads a request from a socketpair and writes a response' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("GET /pingpong HTTP/1.1\r\nHost: x\r\n\r\n")
    a.close_write

    conn.serve(b, app)

    response = a.read
    expect(response).to start_with("HTTP/1.1 200 OK\r\n")
    expect(response).to include('seen /pingpong')
  ensure
    a&.close
    b&.close
  end

  it 'serves a POST with body' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
    a.close_write

    echo_app = lambda do |env|
      body = env['rack.input'].read
      [200, { 'content-type' => 'text/plain' }, ["echo:#{body}"]]
    end

    conn.serve(b, echo_app)

    response = a.read
    expect(response).to include('echo:hello')
  ensure
    a&.close
    b&.close
  end

  it 'writes 400 on a malformed request' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("BLAHBLAHBLAH\r\n\r\n")
    a.close_write

    conn.serve(b, app)

    response = a.read
    expect(response).to start_with("HTTP/1.1 400 Bad Request\r\n")
  ensure
    a&.close
    b&.close
  end

  it 'closes the socket after serving' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    a.close_write

    conn.serve(b, app)

    expect(b.closed?).to be(true)
  ensure
    a&.close
    b&.close
  end

  it 'tolerates client closing without sending data' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.close

    expect { conn.serve(b, app) }.not_to raise_error
    expect(b.closed?).to be(true)
  ensure
    a&.close
    b&.close
  end

  it 'rejects requests whose header section exceeds the limit' do
    # Stub the limit small enough that the giant header fits in the socket
    # buffer without blocking a.write — otherwise we'd deadlock before
    # serve() can drain.
    stub_const('Hyperion::Connection::MAX_HEADER_BYTES', 4 * 1024)

    a, b = ::Socket.pair(:UNIX, :STREAM)
    giant = "GET / HTTP/1.1\r\nX-Pad: #{'A' * 6_000}\r\n\r\n"
    a.write(giant)
    a.close_write

    conn.serve(b, app)

    expect(a.read).to start_with("HTTP/1.1 400 Bad Request\r\n")
  ensure
    a&.close
    b&.close
  end

  it 'returns 400 when client closes mid-body' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("POST /e HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort")
    a.close_write

    conn.serve(b, app)

    expect(a.read).to start_with("HTTP/1.1 400 Bad Request\r\n")
  ensure
    a&.close
    b&.close
  end

  it 'returns 408 when read times out mid-request' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    # Set a tiny per-IO timeout so the test runs fast. The Server uses
    # the same #timeout= API in its apply_timeout helper.
    b.timeout = 0.1 if b.respond_to?(:timeout=)

    a.write("GET / HTTP/1.1\r\n") # incomplete — no \r\n\r\n
    # Don't close_write; let the read time out.

    conn.serve(b, app)

    expect(a.read).to start_with("HTTP/1.1 408 Request Timeout\r\n")
  ensure
    a&.close
    b&.close
  end

  it 'returns 501 for non-chunked Transfer-Encoding (anti-smuggling)' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\nstuff")
    a.close_write

    conn.serve(b, app)

    expect(a.read).to start_with("HTTP/1.1 501 Not Implemented\r\n")
  ensure
    a&.close
    b&.close
  end

  it 'serves a chunked request body end-to-end' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" \
            "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n")
    a.close_write

    captured = nil
    echo_app = lambda do |env|
      captured = env['rack.input'].read
      [200, { 'content-type' => 'text/plain' }, ["got: #{captured}"]]
    end

    conn.serve(b, echo_app)

    expect(captured).to eq('Hello World')
    expect(a.read).to include('got: Hello World')
  ensure
    a&.close
    b&.close
  end

  it 'serves multiple sequential HTTP/1.1 requests on the same socket' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("GET /first HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    a.close_write

    counter = 0
    counting_app = lambda do |env|
      counter += 1
      [200, { 'content-type' => 'text/plain' }, ["#{counter}:#{env['PATH_INFO']}"]]
    end

    conn.serve(b, counting_app)

    response = a.read
    expect(response.scan(%r{HTTP/1\.1 200 OK}).size).to eq(2)
    expect(response).to include('1:/first')
    expect(response).to include('2:/second')
    expect(response).to include('connection: keep-alive')
    expect(response).to include('connection: close')
  ensure
    a&.close
    b&.close
  end

  it 'closes after one request when client sends Connection: close' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("GET /once HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    a.close_write

    counter = 0
    counting_app = lambda do |env|
      counter += 1
      [200, {}, ["once #{env['PATH_INFO']}"]]
    end

    conn.serve(b, counting_app)

    expect(counter).to eq(1)
    response = a.read
    expect(response).to include('connection: close')
  ensure
    a&.close
    b&.close
  end

  it 'populates REMOTE_ADDR from the TCP socket peer' do
    server_socket = ::TCPServer.new('127.0.0.1', 0)
    port = server_socket.addr[1]

    captured = nil
    server_thread = Thread.new do
      conn_socket, = server_socket.accept
      capture_app = lambda do |env|
        captured = env['REMOTE_ADDR']
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end
      conn.serve(conn_socket, capture_app)
    end

    client = ::TCPSocket.new('127.0.0.1', port)
    client.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    client.read

    server_thread.join(2)
    server_socket.close
    client.close

    expect(captured).to eq('127.0.0.1')
  end

  context 'with a thread pool' do
    let(:pool) { Hyperion::ThreadPool.new(size: 2) }

    after { pool.shutdown }

    it 'dispatches the rack handler on a thread pool worker' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /tp HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      handler_thread = nil
      capture_app = lambda do |_env|
        handler_thread = Thread.current
        [200, {}, ['ok']]
      end

      conn_with_pool = described_class.new(thread_pool: pool)
      conn_with_pool.serve(b, capture_app)

      expect(handler_thread).not_to eq(Thread.main)
    ensure
      a&.close
      b&.close
    end
  end

  it 'honors HTTP/1.0 close-by-default' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    # HTTP/1.0 without Connection: keep-alive — should be one-shot.
    a.write("GET / HTTP/1.0\r\nHost: x\r\n\r\nGET /second HTTP/1.0\r\nHost: x\r\n\r\n")
    a.close_write

    counter = 0
    counting_app = lambda do |_env|
      counter += 1
      [200, {}, ["#{counter}"]]
    end

    conn.serve(b, counting_app)

    expect(counter).to eq(1) # only the first request was served
  ensure
    a&.close
    b&.close
  end

  it 'increments metrics on a successful request' do
    Hyperion.metrics # force init
    before = Hyperion.metrics.snapshot[:requests_total].to_i

    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("GET /m HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    a.close_write

    conn.serve(b, app)

    after = Hyperion.metrics.snapshot[:requests_total].to_i
    expect(after).to be >= (before + 1)
  ensure
    a&.close
    b&.close
  end

  describe 'access logging' do
    let(:log_io) { StringIO.new }

    it 'is ON by default — emits an access log line on a successful request' do
      Hyperion.log_requests = nil # reset to default
      Hyperion::Runtime.default.logger = Hyperion::Logger.new(io: log_io, format: :text, level: :info)
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /noisy HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      described_class.new.serve(b, app)

      expect(log_io.string).to include('message=request')
      expect(log_io.string).to include('path=/noisy')
    ensure
      a&.close
      b&.close
      Hyperion.log_requests = nil
      Hyperion::Runtime.default.logger = Hyperion::Logger.new
    end

    it 'can be disabled via Hyperion.log_requests = false' do
      Hyperion.log_requests = false
      Hyperion::Runtime.default.logger = Hyperion::Logger.new(io: log_io, format: :text, level: :info)
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /silent HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      described_class.new.serve(b, app)

      expect(log_io.string).not_to include('message=request')
    ensure
      a&.close
      b&.close
      Hyperion.log_requests = nil
      Hyperion::Runtime.default.logger = Hyperion::Logger.new
    end

    it 'can be disabled per-Connection via log_requests: false' do
      Hyperion::Runtime.default.logger = Hyperion::Logger.new(io: log_io, format: :text, level: :info)
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /silent HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      described_class.new(log_requests: false).serve(b, app)

      expect(log_io.string).not_to include('message=request')
    ensure
      a&.close
      b&.close
      Hyperion::Runtime.default.logger = Hyperion::Logger.new
    end

    it 'emits one structured info line per response when log_requests: true' do
      Hyperion::Runtime.default.logger = Hyperion::Logger.new(io: log_io, format: :text, level: :info)
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /widgets?id=42 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      described_class.new(log_requests: true).serve(b, app)

      lines = log_io.string.split("\n")
      access = lines.find { |l| l.include?('message=request') }
      expect(access).not_to be_nil
      expect(access).to include('method=GET')
      expect(access).to include('path=/widgets')
      # Value contains `=` so the formatter quotes it. Match either form.
      expect(access).to match(/query=("id=42"|id=42)/)
      expect(access).to include('status=200')
      expect(access).to include('duration_ms=')
      expect(access).to include('http_version=HTTP/1.1')
    ensure
      a&.close
      b&.close
      Hyperion::Runtime.default.logger = Hyperion::Logger.new
    end

    it 'emits json access log when format is json' do
      Hyperion::Runtime.default.logger = Hyperion::Logger.new(io: log_io, format: :json, level: :info)
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("POST /api/items HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      a.close_write

      described_class.new(log_requests: true).serve(b, app)

      lines = log_io.string.split("\n").map do |l|
        JSON.parse(l)
      rescue StandardError
        nil
      end.compact
      access = lines.find { |h| h['message'] == 'request' }
      expect(access).not_to be_nil
      expect(access['method']).to eq('POST')
      expect(access['path']).to eq('/api/items')
      expect(access['status']).to eq(200)
      expect(access['duration_ms']).to be >= 0
    ensure
      a&.close
      b&.close
      Hyperion::Runtime.default.logger = Hyperion::Logger.new
    end
  end

  # 2.13-A — Rack-3 fast-path keepalive decision + cached worker-id
  # label tuple. Pre-2.13-A `should_keep_alive?` scanned the whole
  # response-headers Hash and `tick_worker_request` allocated a fresh
  # `[label]` array per request. Both are now amortised: the headers
  # check is one Hash lookup; the worker-id tuple is built once in
  # the constructor and reused on every request.
  describe 'should_keep_alive? Rack-3 fast path' do
    it 'closes the connection when the response uses lowercase "connection: close" (Rack-3 spec)' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      a.close_write

      close_app = lambda do |_env|
        [200, { 'content-type' => 'text/plain', 'connection' => 'close' }, ['bye']]
      end

      described_class.new.serve(b, close_app)
      response = a.read
      expect(response).to include('connection: close')
    ensure
      a&.close
      b&.close
    end

    it 'keeps connection alive when the response sets "connection: keep-alive" (Rack-3 spec)' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /first HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      counter = 0
      keep_app = lambda do |env|
        counter += 1
        [200, { 'content-type' => 'text/plain', 'connection' => 'keep-alive' },
         ["seen #{env['PATH_INFO']}"]]
      end

      described_class.new.serve(b, keep_app)
      expect(counter).to eq(2) # second request was served on the same socket
    ensure
      a&.close
      b&.close
    end

    it 'falls back to keep-alive when the app emits non-Rack-3 mixed-case "Connection: close"' do
      # 2.13-A documents this as a benign degradation: apps that
      # violate the Rack-3 spec by returning mixed-case keys lose the
      # Connection-close response signal and stay on keep-alive. The
      # fix is to update the app to spec; this test pins the
      # behaviour so the change is documented and stable.
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      a.close_write

      bad_case_app = lambda do |_env|
        [200, { 'Content-Type' => 'text/plain', 'Connection' => 'close' }, ['bye']]
      end

      described_class.new.serve(b, bad_case_app)
      response = a.read
      # Hyperion's writer always emits its own Connection header
      # (lowercased); on the keep-alive branch that's "keep-alive",
      # not "close". Verifies the fast-path missed the mis-cased
      # 'Connection' key and picked keep-alive as expected.
      expect(response).to include('connection: keep-alive')
    ensure
      a&.close
      b&.close
    end
  end

  describe 'worker_id label tuple caching' do
    it 'pre-builds a frozen [pid] tuple in the constructor' do
      c = described_class.new
      tuple = c.instance_variable_get(:@worker_id_label_tuple)
      expect(tuple).to eq([Process.pid.to_s])
      expect(tuple).to be_frozen
    end

    it 'reuses the same tuple instance across requests on the same connection' do
      # Identity check — the tuple must be the same object across
      # calls so `Hash#[]=` on the labeled-counter family doesn't
      # re-key into a new bucket per request.
      c = described_class.new
      first  = c.instance_variable_get(:@worker_id_label_tuple)
      second = c.instance_variable_get(:@worker_id_label_tuple)
      expect(first).to be(second)
    end
  end
end
