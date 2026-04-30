# frozen_string_literal: true

require 'socket'
require 'hyperion/connection'
require 'hyperion/thread_pool'

# WS-1 — Rack 3 full-hijack support.
#
# Hyperion 2.0 explicitly disabled hijack (`env['rack.hijack?'] = false`).
# 2.1.0 flips the bit on the HTTP/1.1 path: Rack apps that request the
# socket via `env['rack.hijack'].call` get the raw IO and Hyperion stays
# out of the way for the rest of that connection's lifetime — no response
# write, no socket close, no keep-alive accounting.
#
# Spec tactical note: socket-pair tests deliberately CLOSE the b side
# from the test BEFORE issuing `a.read`. Without that close, the read
# would block forever (which is precisely the design — Hyperion is no
# longer closing on hijack). We are asserting Hyperion's hands-off
# behaviour by manually playing the role of "the app that decided to
# hand the socket over and let it live on past the request".
RSpec.describe 'Rack 3 hijack support (WS-1)' do
  # Thread-pool integration deferred to its own block — most assertions
  # below run on the inline (non-thread-pool) path, where reasoning about
  # ordering is straightforward.
  let(:conn) { Hyperion::Connection.new }

  # Drains any bytes currently readable on `io` within a short window
  # (default 50 ms). Used to assert "Hyperion did NOT write a response"
  # without triggering a blocking read-to-EOF on a still-open socket.
  def drain_available(io, window: 0.05)
    out = +''
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + window
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0

      ready, = IO.select([io], nil, nil, remaining)
      break unless ready

      chunk = io.read_nonblock(4096, exception: false)
      break if chunk.nil? || chunk == :wait_readable

      out << chunk
    end
    out
  end

  describe 'env keys' do
    it "sets env['rack.hijack?'] to true (was false in 1.6-2.0)" do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      captured = nil
      app = lambda do |env|
        captured = env.dup
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end

      conn.serve(b, app)

      expect(captured['rack.hijack?']).to be(true)
      expect(captured['rack.hijack']).to respond_to(:call)
    ensure
      a&.close
      b&.close unless b.nil? || b.closed?
    end

    it "leaves env['rack.hijack?'] false on the h2 dispatch path (no connection:)" do
      # Calling Adapter::Rack.call directly without `connection:` (the h2 /
      # ad-hoc adapter shape) keeps hijack disabled. This is the contract
      # Http2Handler relies on while WS-1 is HTTP/1.1-only.
      request = Hyperion::Request.new(
        method: 'GET', path: '/', query_string: '', http_version: 'HTTP/2',
        headers: { 'host' => 'x' }, body: ''
      )
      captured = nil
      app = lambda do |env|
        captured = env.dup
        [200, {}, ['ok']]
      end

      Hyperion::Adapter::Rack.call(app, request)

      expect(captured['rack.hijack?']).to be(false)
      expect(captured.key?('rack.hijack')).to be(false)
    end
  end

  describe 'env[\'rack.hijack\'].call' do
    it 'returns the underlying socket usable for raw read+write' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      hijacked_io = nil
      app = lambda do |env|
        hijacked_io = env['rack.hijack'].call
        hijacked_io.write('HELLO-FROM-APP')
        [-1, {}, []] # ignored on the hijack path per Rack 3 spec
      end

      conn.serve(b, app)

      expect(hijacked_io).to be(b)
      # Drain whatever's on the wire without waiting for EOF (b is still open).
      expect(drain_available(a)).to eq('HELLO-FROM-APP')
    ensure
      a&.close
      hijacked_io&.close unless hijacked_io.nil? || hijacked_io.closed?
    end

    it 'is idempotent — calling twice returns the same socket without error' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      first = nil
      second = nil
      app = lambda do |env|
        first  = env['rack.hijack'].call
        second = env['rack.hijack'].call
        [200, {}, []]
      end

      conn.serve(b, app)

      expect(first).to be(second)
    ensure
      a&.close
      b&.close unless b.nil? || b.closed?
    end
  end

  describe 'env[\'hyperion.hijack_buffered\']' do
    it 'is empty when no bytes were buffered past the request boundary' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      buffered = nil
      app = lambda do |env|
        env['rack.hijack'].call
        buffered = env['hyperion.hijack_buffered']
        [200, {}, []]
      end

      conn.serve(b, app)

      expect(buffered).to eq('')
    ensure
      a&.close
      b&.close unless b.nil? || b.closed?
    end

    it 'exposes bytes the client sent past the headers (Upgrade-style early send)' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      # Request + 5 trailing bytes glued onto the same TCP segment. These
      # show up in the connection's read buffer past the parsed boundary
      # because the parser only consumes the request itself.
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nEARLY")
      a.close_write

      buffered = nil
      app = lambda do |env|
        env['rack.hijack'].call
        buffered = env['hyperion.hijack_buffered']
        [200, {}, []]
      end

      conn.serve(b, app)

      expect(buffered).to eq('EARLY')
    ensure
      a&.close
      b&.close unless b.nil? || b.closed?
    end
  end

  describe 'after hijack' do
    it 'does NOT write a Hyperion response on the wire (app owns the socket)' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      app = lambda do |env|
        env['rack.hijack'].call
        # The app deliberately writes nothing — we want to assert Hyperion's
        # silence too. Returning a status/headers/body that Hyperion would
        # have written has no effect on the hijack path (Rack 3 spec says
        # the tuple is ignored).
        [200, { 'content-type' => 'text/plain' }, ['SHOULD-BE-IGNORED']]
      end

      conn.serve(b, app)

      payload = drain_available(a)
      expect(payload).to eq('')
      expect(payload).not_to include('HTTP/1.1')
      expect(payload).not_to include('SHOULD-BE-IGNORED')
    ensure
      a&.close
      b&.close unless b.nil? || b.closed?
    end

    it 'does NOT close the socket on connection cleanup (the app owns it)' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      hijacked_io = nil
      app = lambda do |env|
        hijacked_io = env['rack.hijack'].call
        [200, {}, []]
      end

      conn.serve(b, app)

      # Hyperion's serve() returned. Socket MUST still be open.
      expect(b.closed?).to be(false)
      expect(hijacked_io.closed?).to be(false)

      # And the app can keep using it after Hyperion exited.
      hijacked_io.write('POST-HIJACK-BYTES')
      hijacked_io.close
      expect(a.read).to eq('POST-HIJACK-BYTES')
    ensure
      a&.close
    end

    it 'is usable for raw read+write from a separate thread outside the request fiber' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      # Write the request only — keep the write half open so the test can
      # send post-hijack bytes back through `a` after Hyperion exits.
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")

      hijacked_io = nil
      app = lambda do |env|
        hijacked_io = env['rack.hijack'].call
        [200, {}, []]
      end

      conn.serve(b, app)

      # Send 5 bytes from the peer end; read them on a separate thread
      # using only the hijacked IO. This is the WebSocket reader-fiber
      # shape — a different thread from the one that ran the Rack app.
      a.write('PINGS')
      read_bytes = nil
      reader = Thread.new { read_bytes = hijacked_io.read(5) }
      reader.join(2)

      expect(read_bytes).to eq('PINGS')
    ensure
      a&.close
      hijacked_io&.close unless hijacked_io.nil? || hijacked_io.closed?
    end

    it 'flips Connection#hijacked? from false to true' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      observed_before = nil
      observed_after  = nil
      app = lambda do |env|
        observed_before = conn.hijacked?
        env['rack.hijack'].call
        observed_after = conn.hijacked?
        [200, {}, []]
      end

      conn.serve(b, app)

      expect(observed_before).to be(false)
      expect(observed_after).to be(true)
      expect(conn.hijacked?).to be(true)
    ensure
      a&.close
      b&.close unless b.nil? || b.closed?
    end
  end

  describe 'no regression on the non-hijack path' do
    it 'writes a normal response when the app does NOT call rack.hijack' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /normal HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      app = lambda do |_env|
        [200, { 'content-type' => 'text/plain' }, ['hello']]
      end

      conn.serve(b, app)

      payload = a.read # safe: Hyperion closes b on the non-hijack path → EOF
      expect(payload).to start_with("HTTP/1.1 200 OK\r\n")
      expect(payload).to include('hello')
      expect(b.closed?).to be(true)
    ensure
      a&.close
    end

    it 'leaves Connection#hijacked? false when the app ignores hijack' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      app = lambda do |_env|
        [200, {}, ['ok']]
      end

      conn.serve(b, app)

      expect(conn.hijacked?).to be(false)
    ensure
      a&.close
      b&.close unless b.closed?
    end
  end

  describe 'with a thread pool (cross-thread hijack)' do
    let(:pool) { Hyperion::ThreadPool.new(size: 2) }

    after { pool.shutdown }

    it 'still hands the socket to the app and skips Hyperion writer/close' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ws HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      hijacked_io = nil
      handler_thread = nil
      app = lambda do |env|
        handler_thread = Thread.current
        hijacked_io = env['rack.hijack'].call
        hijacked_io.write('FROM-WORKER')
        [200, {}, []]
      end

      pooled_conn = Hyperion::Connection.new(thread_pool: pool)
      pooled_conn.serve(b, app)

      # App ran on a worker thread, not main.
      expect(handler_thread).not_to eq(Thread.main)
      # Hijack flag is observed by the connection fiber after the worker thread returns.
      expect(pooled_conn.hijacked?).to be(true)
      # Socket survives the connection fiber's exit.
      expect(b.closed?).to be(false)
      expect(drain_available(a)).to eq('FROM-WORKER')
    ensure
      a&.close
      hijacked_io&.close if hijacked_io && !hijacked_io.closed?
    end
  end

  describe 'connection cleanup idempotency' do
    it 'does not double-close when the app then closes the socket itself' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      app = lambda do |env|
        io = env['rack.hijack'].call
        io.close # app closes the socket itself — Hyperion must not also close
        [200, {}, []]
      end

      expect { conn.serve(b, app) }.not_to raise_error
      expect(b.closed?).to be(true) # closed by the app, not by Hyperion's ensure block
    ensure
      a&.close
    end
  end
end
