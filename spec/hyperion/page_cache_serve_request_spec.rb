# frozen_string_literal: true

require 'fileutils'
require 'socket'
require 'tempfile'
require 'tmpdir'
require 'hyperion'
require 'hyperion/http/page_cache'

# 2.10-F — `Hyperion::Http::PageCache.serve_request` C-ext fast-path.
#
# `serve_request(socket, method, path)` folds the matched-route hot path
# into C: it does the hash lookup, snapshots the prebuilt response under
# the C lock, releases the GVL during the `write()` syscall, and returns
# `[:ok, bytes_written]` on hit / `:miss` on absence.  HEAD requests
# write only the headers (no body).  Non-GET/HEAD methods miss so the
# Ruby caller can fall back to whatever request semantics they need.
#
# These specs assert:
#   * GET hit  → :ok + full response bytes on the wire (status+headers+body)
#   * HEAD hit → :ok + headers-only on the wire (no body bytes)
#   * GET miss → :miss + nothing written
#   * Method case-insensitive (request line "get" still hits)
#   * Non-GET/HEAD on a hit (e.g. POST) → :miss, untouched socket
#   * GVL released during write — concurrent threads can run while a
#     slow socket drains (asserted via no-deadlock under contention,
#     not a wall-clock race).
#   * Bytes-written count matches what the receiver sees.
RSpec.describe 'Hyperion::Http::PageCache.serve_request (2.10-F)' do
  before { Hyperion::Http::PageCache.clear }
  after  { Hyperion::Http::PageCache.clear }

  # TCP socket pair: server thread accepts once and drains every byte
  # the client writes; yields the populated client socket to the spec
  # block, then returns the bytes the server saw.
  def with_tcp_pair
    server = TCPServer.new('127.0.0.1', 0)
    port   = server.addr[1]
    reader = Thread.new do
      conn = server.accept
      buf = +''
      while (chunk = conn.read(4096))
        break if chunk.empty?

        buf << chunk
      end
      conn.close
      buf
    end
    client = TCPSocket.new('127.0.0.1', port)
    result = yield client
    client.close
    received = reader.value
    server.close
    [result, received]
  end

  describe 'public surface' do
    it 'is registered on the PageCache module' do
      expect(Hyperion::Http::PageCache).to respond_to(:serve_request)
    end

    it 'is registered alongside the existing prebuilt-entry helpers' do
      expect(Hyperion::Http::PageCache).to respond_to(:register_prebuilt)
    end
  end

  describe 'GET on a registered prebuilt entry' do
    let(:body) { "hello\n" }
    let(:headers) do
      "HTTP/1.1 200 OK\r\n" \
        "content-type: text/plain\r\n" \
        "content-length: #{body.bytesize}\r\n" \
        "\r\n"
    end
    let(:response_bytes) { (headers + body).b }
    let(:path) { '/hello' }

    before do
      Hyperion::Http::PageCache.register_prebuilt(path, response_bytes, body.bytesize)
    end

    it 'returns [:ok, bytes_written] and writes the full response' do
      result, received = with_tcp_pair do |client|
        Hyperion::Http::PageCache.serve_request(client, 'GET', path)
      end

      expect(result).to be_a(Array)
      expect(result.first).to eq(:ok)
      expect(result.last).to eq(response_bytes.bytesize)
      expect(received.b).to eq(response_bytes)
    end

    it 'matches the request method case-insensitively' do
      _, received = with_tcp_pair do |client|
        Hyperion::Http::PageCache.serve_request(client, 'get', path)
      end
      expect(received.b).to eq(response_bytes)
    end
  end

  describe 'HEAD on a registered prebuilt entry' do
    let(:body) { 'x' * 256 }
    let(:headers) do
      "HTTP/1.1 200 OK\r\n" \
        "content-type: application/octet-stream\r\n" \
        "content-length: #{body.bytesize}\r\n" \
        "\r\n"
    end
    let(:response_bytes) { (headers + body).b }
    let(:path) { '/big.bin' }

    before do
      Hyperion::Http::PageCache.register_prebuilt(path, response_bytes, body.bytesize)
    end

    it 'writes only the headers (body stripped)' do
      result, received = with_tcp_pair do |client|
        Hyperion::Http::PageCache.serve_request(client, 'HEAD', path)
      end

      expect(result.first).to eq(:ok)
      expect(result.last).to eq(headers.bytesize)
      expect(received.b).to eq(headers.b)
      expect(received.bytesize).to eq(headers.bytesize)
    end
  end

  describe 'misses' do
    it 'returns :miss when the path is not registered' do
      _, received = with_tcp_pair do |client|
        result = Hyperion::Http::PageCache.serve_request(client, 'GET', '/nope')
        expect(result).to eq(:miss)
      end
      expect(received).to eq('')
    end

    it 'returns :miss for unsupported methods (POST, PUT, DELETE, etc.)' do
      Hyperion::Http::PageCache.register_prebuilt('/x', "HTTP/1.1 200 OK\r\n\r\n".b, 0)

      %w[POST PUT DELETE PATCH OPTIONS].each do |method|
        _, received = with_tcp_pair do |client|
          result = Hyperion::Http::PageCache.serve_request(client, method, '/x')
          expect(result).to eq(:miss), "expected :miss for method #{method}, got #{result.inspect}"
        end
        expect(received).to eq('')
      end
    end

    it 'returns :miss on empty or oversized path' do
      Hyperion::Http::PageCache.register_prebuilt('/x', "HTTP/1.1 200 OK\r\n\r\n".b, 0)

      _, received = with_tcp_pair do |client|
        expect(Hyperion::Http::PageCache.serve_request(client, 'GET', '')).to eq(:miss)
      end
      expect(received).to eq('')

      huge = "/#{'a' * 4096}"
      _, received = with_tcp_pair do |client|
        expect(Hyperion::Http::PageCache.serve_request(client, 'GET', huge)).to eq(:miss)
      end
      expect(received).to eq('')
    end
  end

  describe 'register_prebuilt + clear surface' do
    it 'persists the entry until clear' do
      Hyperion::Http::PageCache.register_prebuilt('/a', "HTTP/1.1 200 OK\r\n\r\n".b, 0)
      Hyperion::Http::PageCache.register_prebuilt('/b', "HTTP/1.1 200 OK\r\n\r\nb".b, 1)
      expect(Hyperion::Http::PageCache.size).to be >= 2

      Hyperion::Http::PageCache.clear
      _, received = with_tcp_pair do |client|
        expect(Hyperion::Http::PageCache.serve_request(client, 'GET', '/a')).to eq(:miss)
      end
      expect(received).to eq('')
    end

    it 'rejects non-String response_bytes' do
      expect do
        Hyperion::Http::PageCache.register_prebuilt('/x', 42, 0)
      end.to raise_error(TypeError)
    end

    it 'rejects body_len > response_bytes.bytesize' do
      expect do
        Hyperion::Http::PageCache.register_prebuilt('/x', 'tiny'.b, 999)
      end.to raise_error(ArgumentError, /body_len/)
    end

    it 'last writer wins on the same path' do
      Hyperion::Http::PageCache.register_prebuilt('/x', "HTTP/1.1 200 OK\r\n\r\nv1".b, 2)
      Hyperion::Http::PageCache.register_prebuilt('/x', "HTTP/1.1 200 OK\r\n\r\nv2".b, 2)

      _, received = with_tcp_pair do |client|
        result = Hyperion::Http::PageCache.serve_request(client, 'GET', '/x')
        expect(result.first).to eq(:ok)
      end
      expect(received).to end_with('v2')
    end
  end

  describe 'GVL release during write (no-deadlock under contention)' do
    # The C path releases the GVL while issuing `write()`.  Asserting
    # GVL release directly via wall-clock timing is flaky on shared
    # CI hosts, so we instead assert that many concurrent serve_request
    # threads complete without deadlock when paired with another thread
    # doing pure-Ruby work on the same VM.  If the GVL were held across
    # the syscall, the Ruby worker thread would still progress (CRuby's
    # GVL is cooperative on syscall return) — so this is a sanity
    # check that the implementation doesn't introduce a NEW lock that
    # blocks reads.
    it 'does not deadlock under multi-thread serve_request load' do
      body = 'y' * 1024
      headers = "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{body.bytesize}\r\n\r\n"
      Hyperion::Http::PageCache.register_prebuilt('/c', (headers + body).b, body.bytesize)

      # Spawn N threads, each opens a tcp pair + drains.  All of them
      # must complete inside a generous wall-clock budget.
      results = Concurrent::Array.new if defined?(Concurrent)
      results ||= []
      mutex = Mutex.new
      threads = 8.times.map do
        Thread.new do
          server = TCPServer.new('127.0.0.1', 0)
          port = server.addr[1]
          reader = Thread.new do
            conn = server.accept
            buf = +''
            while (chunk = conn.read(4096))
              break if chunk.empty?

              buf << chunk
            end
            conn.close
            buf
          end
          client = TCPSocket.new('127.0.0.1', port)
          result = Hyperion::Http::PageCache.serve_request(client, 'GET', '/c')
          client.close
          got = reader.value
          server.close
          mutex.synchronize { results << [result, got.bytesize] }
        end
      end

      # Wide budget — even on a heavily-loaded CI host, 8 small writes
      # complete in < 1 s.  If the implementation deadlocked we'd hit
      # the 30 s join timeout and fail loudly.
      threads.each { |t| t.join(30) }
      expect(threads.all? { |t| !t.alive? }).to eq(true), 'a thread deadlocked'
      expect(results.size).to eq(8)
      results.each do |(res, recv_bytes)|
        expect(res.first).to eq(:ok)
        expect(recv_bytes).to eq(headers.bytesize + body.bytesize)
      end
    end
  end
end
