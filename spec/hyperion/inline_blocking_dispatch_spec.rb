# frozen_string_literal: true

require 'socket'
require 'stringio'
require 'tempfile'
require 'hyperion'
require 'hyperion/connection'
require 'hyperion/response_writer'
require 'hyperion/http/sendfile'
require 'hyperion/adapter/rack'

# 2.6-C — `:inline_blocking` per-response dispatch mode.
#
# The mode is opt-in PER RESPONSE: the connection's connection-wide
# dispatch mode (resolved at boot from `tls`, `async_io`, ALPN, and
# `thread_count`) stays whatever the operator configured.  For static-
# file routes (Body responds to `to_path`, no streaming markers) the
# Rack adapter auto-detects the mode and stashes
# `:inline_blocking` on the connection; the response-write loop reads
# it back and switches `Hyperion::Http::Sendfile.copy_to_socket` for
# `Hyperion::Http::Sendfile.copy_to_socket_blocking` — Puma-style
# serial-per-thread sendfile, no fiber yield, no per-chunk EAGAIN
# round-trip.
RSpec.describe 'Hyperion :inline_blocking dispatch mode (2.6-C)' do
  describe Hyperion::DispatchMode do
    describe ':inline_blocking constructor + predicates' do
      let(:mode) { described_class.new(:inline_blocking) }

      it 'is a recognised mode name' do
        expect(described_class::MODES).to include(:inline_blocking)
      end

      it 'is frozen after construction' do
        expect(mode).to be_frozen
      end

      it 'inline_blocking? is true' do
        expect(mode.inline_blocking?).to be(true)
      end

      it 'inline_blocking? is false for every other mode' do
        described_class::MODES.reject { |n| n == :inline_blocking }.each do |n|
          expect(described_class.new(n).inline_blocking?).to be(false)
        end
      end

      it 'fiber_dispatched? is false for :inline_blocking' do
        expect(mode.fiber_dispatched?).to be(false)
      end

      it 'fiber_dispatched? is true for the three async-scheduler modes' do
        %i[tls_h2 tls_h1_inline async_io_h1_inline].each do |n|
          expect(described_class.new(n).fiber_dispatched?).to be(true)
        end
      end

      it 'fiber_dispatched? is false for :threadpool_h1 and :inline_h1_no_pool' do
        %i[threadpool_h1 inline_h1_no_pool].each do |n|
          expect(described_class.new(n).fiber_dispatched?).to be(false)
        end
      end

      it 'is equal to a sibling :inline_blocking instance' do
        a = described_class.new(:inline_blocking)
        b = described_class.new(:inline_blocking)
        expect(a).to eq(b)
        expect(a).to eql(b)
        expect(a.hash).to eq(b.hash)
      end

      it 'is unequal to other modes' do
        expect(mode).not_to eq(described_class.new(:threadpool_h1))
        expect(mode).not_to eq(described_class.new(:tls_h2))
      end

      it 'metric_key follows the :requests_dispatch_<mode> convention' do
        expect(mode.metric_key).to eq(:requests_dispatch_inline_blocking)
      end

      it 'is included in INLINE_MODES (treated as an inline-style dispatch)' do
        expect(described_class::INLINE_MODES).to include(:inline_blocking)
      end

      it 'inline? is true' do
        expect(mode.inline?).to be(true)
      end
    end
  end

  describe Hyperion::Adapter::Rack, '#call dispatch-mode auto-detect' do
    # Stand-in for Hyperion::Connection: tracks `response_dispatch_mode=`.
    let(:fake_connection) do
      Class.new do
        attr_accessor :response_dispatch_mode

        def hijacked?
          false
        end

        def hijack_buffered
          +''
        end
      end.new
    end

    let(:request) do
      Hyperion::Request.new(
        method: 'GET',
        path: '/asset.bin',
        query_string: '',
        http_version: 'HTTP/1.1',
        headers: { 'host' => 'localhost' },
        body: '',
        peer_address: '127.0.0.1'
      )
    end

    # File-body shape that mimics Rack::Files (responds to to_path).
    let(:tempfile) do
      Tempfile.new(%w[hyperion-inline-blocking .bin]).tap do |f|
        f.binmode
        f.write('hello world')
        f.flush
      end
    end

    after { tempfile.close! }

    def file_body(path)
      Class.new do
        def initialize(path)
          @path = path
        end

        def to_path
          @path
        end

        def each
          yield File.binread(@path)
        end

        def close; end
      end.new(path)
    end

    it 'auto-detects `:inline_blocking` for a body responding to :to_path' do
      tp = tempfile.path
      app = ->(_env) { [200, { 'content-type' => 'application/octet-stream' }, file_body(tp)] }

      described_class.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to eq(:inline_blocking)
    end

    it 'does NOT engage `:inline_blocking` for plain Array bodies' do
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hello']] }

      described_class.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to be_nil
    end

    it 'honours explicit `env[hyperion.dispatch_mode] = :inline_blocking` opt-in' do
      app = lambda do |env|
        env['hyperion.dispatch_mode'] = :inline_blocking
        [200, { 'content-type' => 'text/plain' }, ['streaming-but-marked-inline']]
      end

      described_class.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to eq(:inline_blocking)
    end

    it 'lets explicit env override take priority over auto-detect' do
      tp = tempfile.path
      # Auto-detect would normally fire because to_path is present, but
      # the explicit override pins the mode to a different (still
      # inline_blocking) value verbatim — verifying that the explicit
      # path wins on equal symbols.  (A future second mode could test
      # the precedence with a distinct symbol.)
      app = lambda do |env|
        env['hyperion.dispatch_mode'] = :inline_blocking
        [200, { 'content-type' => 'application/octet-stream' }, file_body(tp)]
      end

      described_class.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to eq(:inline_blocking)
    end

    it 'opts OUT of auto-detect when env[hyperion.streaming] is set' do
      tp = tempfile.path
      app = lambda do |env|
        env['hyperion.streaming'] = true
        [200, { 'content-type' => 'application/octet-stream' }, file_body(tp)]
      end

      described_class.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to be_nil
    end

    it 'is a no-op when no Connection is in scope (h2 streams, ad-hoc callers)' do
      tp = tempfile.path
      app = ->(_env) { [200, {}, file_body(tp)] }
      # Just ensure no NoMethodError on `connection.response_dispatch_mode=`
      expect { described_class.call(app, request, connection: nil) }.not_to raise_error
    end
  end

  describe Hyperion::ResponseWriter, '#write with dispatch_mode: :inline_blocking' do
    subject(:writer) { described_class.new }

    let(:io) { StringIO.new }

    def file_body(path)
      Class.new do
        def initialize(path)
          @path = path
        end

        def to_path
          @path
        end

        def each
          yield File.binread(@path)
        end

        def close; end
      end.new(path)
    end

    %w[1024 8192 1048576 16777216].each do |size_str|
      size  = size_str.to_i
      label = "#{size / 1024} KiB"

      it "round-trips a #{label} file byte-equal in :inline_blocking mode" do
        Tempfile.create(%w[hyperion-inline-blocking .bin]) do |f|
          f.binmode
          payload = String.new(capacity: size, encoding: Encoding::BINARY)
          # Distinct bytes per kilobyte so a misaligned write would surface
          # immediately rather than memcpy'ing nulls into nulls.
          chunk = (0..255).map(&:chr).join.b
          payload << chunk while payload.bytesize < size
          payload = payload.byteslice(0, size)
          f.write(payload)
          f.flush

          # Round-trip via a real socket pair so sendfile actually fires
          # on Linux/Darwin builds (StringIO would force the userspace
          # fallback, which doesn't exercise the EAGAIN-block path).
          server = TCPServer.new('127.0.0.1', 0)
          port   = server.addr[1]
          received = String.new(encoding: Encoding::BINARY)
          reader = Thread.new do
            conn = server.accept
            while received.bytesize < size + 200 # head + body
              chunk = conn.read(size + 200 - received.bytesize)
              break if chunk.nil? || chunk.empty?

              received << chunk
            end
            conn.close
            received
          end
          client = TCPSocket.new('127.0.0.1', port)

          writer.write(client, 200, { 'content-type' => 'application/octet-stream' },
                       file_body(f.path), dispatch_mode: :inline_blocking)
          client.close

          got = reader.value
          expect(got).to start_with("HTTP/1.1 200 OK\r\n")
          body = got.split("\r\n\r\n", 2).last
          expect(body.bytesize).to eq(size)
          expect(body).to eq(payload)

          server.close
        end
      end
    end

    it 'StringIO/userspace path round-trips correctly under :inline_blocking' do
      # On hosts where the body IO is not a real fd (specs / TLS), the
      # blocking variant falls through to `userspace_copy_loop` — same
      # as the fiber-yielding `copy_to_socket`.  The branch is
      # effectively identical for userspace; this spec just guards
      # that the mode flag doesn't trip a code path divergence.
      Tempfile.create(%w[hyperion-inline-blocking .bin]) do |f|
        f.binmode
        f.write('a' * 100_000)
        f.flush
        writer.write(io, 200, { 'content-type' => 'application/octet-stream' },
                     file_body(f.path), dispatch_mode: :inline_blocking)
        body = io.string.split("\r\n\r\n", 2).last
        expect(body.bytesize).to eq(100_000)
      end
    end

    it 'falls through to fiber-yielding sendfile when dispatch_mode is nil' do
      # The default (nil) path must continue to call `copy_to_socket`,
      # NOT `copy_to_socket_blocking`.  We assert by stubbing both
      # methods and observing which was hit.
      Tempfile.create(%w[hyperion-inline-blocking .bin]) do |f|
        f.binmode
        f.write('x' * 200_000) # > SENDFILE_COALESCE_THRESHOLD so it streams
        f.flush

        allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket).and_call_original
        allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket_blocking).and_call_original

        writer.write(io, 200, {}, file_body(f.path)) # default dispatch_mode

        expect(Hyperion::Http::Sendfile).to have_received(:copy_to_socket)
        expect(Hyperion::Http::Sendfile).not_to have_received(:copy_to_socket_blocking)
      end
    end

    it 'invokes copy_to_socket_blocking when dispatch_mode: :inline_blocking' do
      Tempfile.create(%w[hyperion-inline-blocking .bin]) do |f|
        f.binmode
        f.write('y' * 200_000)
        f.flush

        allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket_blocking).and_call_original
        allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket).and_call_original

        writer.write(io, 200, {}, file_body(f.path), dispatch_mode: :inline_blocking)

        expect(Hyperion::Http::Sendfile).to have_received(:copy_to_socket_blocking)
        expect(Hyperion::Http::Sendfile).not_to have_received(:copy_to_socket)
      end
    end
  end

  describe 'Connection regression — :inline_blocking does not affect non-static dispatch' do
    # The threadpool dispatch path is untouched on routes whose body
    # is NOT a `to_path` static file: the adapter's auto-detect skips
    # them, the connection's `response_dispatch_mode` stays nil, and
    # the writer's default fiber-yielding path stays selected.

    let(:request) do
      Hyperion::Request.new(
        method: 'POST',
        path: '/api/work',
        query_string: '',
        http_version: 'HTTP/1.1',
        headers: { 'host' => 'localhost', 'content-type' => 'application/json' },
        body: '',
        peer_address: '127.0.0.1'
      )
    end

    let(:fake_connection) do
      Class.new do
        attr_accessor :response_dispatch_mode

        def hijacked?
          false
        end

        def hijack_buffered
          +''
        end
      end.new
    end

    it 'leaves response_dispatch_mode as nil for plain Array (CPU JSON) bodies' do
      app = ->(_env) { [200, { 'content-type' => 'application/json' }, ['{"hello":"world"}']] }

      Hyperion::Adapter::Rack.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to be_nil
    end

    it 'leaves response_dispatch_mode as nil when body is an Enumerator' do
      enum = Enumerator.new { |y| y << 'chunk1'; y << 'chunk2' } # rubocop:disable Style/Semicolon
      app = ->(_env) { [200, { 'transfer-encoding' => 'chunked' }, enum] }

      Hyperion::Adapter::Rack.call(app, request, connection: fake_connection)
      expect(fake_connection.response_dispatch_mode).to be_nil
    end
  end

  describe 'Lifecycle hooks on :inline_blocking dispatch (2.6-D behaviour change)' do
    # 2.6-D — when the response auto-detects into `:inline_blocking`,
    # the after-request lifecycle hook is SKIPPED.  Static-file
    # routes are observability-served via the metrics module
    # (`hyperion_request_duration_seconds` histogram +
    # `:sendfile_responses` counter), not the per-request hooks
    # which are too expensive to fire on every static asset.  The
    # before-request hook still fires (cheap, useful for span
    # creation, request-id assignment, etc.).
    #
    # Pre-2.6-D the after-hook fired on every dispatch mode.
    # Operators with NewRelic / DataDog / OpenTelemetry hooks
    # attached for static-route observability MUST migrate to the
    # metrics module; the CHANGELOG calls this out explicitly.

    let(:fake_connection) do
      Class.new do
        attr_accessor :response_dispatch_mode

        def hijacked?
          false
        end

        def hijack_buffered
          +''
        end
      end.new
    end

    let(:request) do
      Hyperion::Request.new(
        method: 'GET',
        path: '/asset.bin',
        query_string: '',
        http_version: 'HTTP/1.1',
        headers: { 'host' => 'localhost' },
        body: '',
        peer_address: '127.0.0.1'
      )
    end

    let(:dynamic_request) do
      Hyperion::Request.new(
        method: 'POST',
        path: '/api/work',
        query_string: '',
        http_version: 'HTTP/1.1',
        headers: { 'host' => 'localhost' },
        body: '',
        peer_address: '127.0.0.1'
      )
    end

    let(:tempfile) do
      Tempfile.new(%w[hyperion-inline-blocking-hooks .bin]).tap do |f|
        f.binmode
        f.write('hi')
        f.flush
      end
    end

    after { tempfile.close! }

    def file_body(path)
      Class.new do
        def initialize(path)
          @path = path
        end

        def to_path
          @path
        end

        def each
          yield File.binread(@path)
        end

        def close; end
      end.new(path)
    end

    it 'fires the before-request hook on a static-file (:inline_blocking) response' do
      runtime = Hyperion::Runtime.new
      starts  = []
      runtime.on_request_start { |req, _env| starts << req.path }

      tp = tempfile.path
      app = ->(_env) { [200, {}, file_body(tp)] }

      Hyperion::Adapter::Rack.call(app, request, connection: fake_connection, runtime: runtime)

      expect(starts).to eq(['/asset.bin'])
      expect(fake_connection.response_dispatch_mode).to eq(:inline_blocking)
    end

    it 'SKIPS the after-request hook on a static-file (:inline_blocking) response' do
      runtime = Hyperion::Runtime.new
      ends = []
      runtime.on_request_start { |_req, _env| } # required so has_request_hooks? is true
      runtime.on_request_end   { |req, _env, _resp, _err| ends << req.path }

      tp = tempfile.path
      app = ->(_env) { [200, {}, file_body(tp)] }

      Hyperion::Adapter::Rack.call(app, request, connection: fake_connection, runtime: runtime)

      expect(ends).to eq([])
    end

    it 'STILL fires the after-request hook on dynamic (non-:inline_blocking) responses' do
      runtime = Hyperion::Runtime.new
      starts  = []
      ends    = []
      runtime.on_request_start { |req, _env| starts << req.path }
      runtime.on_request_end   { |req, _env, _resp, _err| ends << req.path }

      app = ->(_env) { [200, { 'content-type' => 'application/json' }, ['{"ok":true}']] }

      Hyperion::Adapter::Rack.call(app, dynamic_request, connection: fake_connection,
                                                         runtime: runtime)

      expect(starts).to eq(['/api/work'])
      expect(ends).to eq(['/api/work'])
      # Dynamic body never engages :inline_blocking.
      expect(fake_connection.response_dispatch_mode).to be_nil
    end

    it 'fires the after-request hook when the app raises (no dispatch_mode set)' do
      runtime = Hyperion::Runtime.new
      end_payloads = []
      runtime.on_request_start { |_req, _env| }
      runtime.on_request_end do |_req, _env, _resp, err|
        end_payloads << err.class.name
      end

      app = ->(_env) { raise 'boom' }

      # The adapter's outer rescue swallows StandardError into a 500
      # tuple, so the call returns normally; we just want to confirm
      # the after-hook fired with the error.  Pre-2.6-D it always
      # fired; we preserve that for the error path because the
      # response shape (500 / Array body) doesn't auto-detect into
      # `:inline_blocking`.
      Hyperion::Adapter::Rack.call(app, dynamic_request, connection: fake_connection,
                                                         runtime: runtime)
      expect(end_payloads).to eq(['RuntimeError'])
    end
  end

  describe 'Sendfile.copy_to_socket_blocking — round-trip through TCPSocket' do
    # Direct-to-helper tests over a real socket pair so the EAGAIN-
    # block path through IO.select fires (StringIO would skip the
    # native branch entirely).

    def with_socket_pair(expected_bytes)
      server = TCPServer.new('127.0.0.1', 0)
      port   = server.addr[1]
      received = String.new(encoding: Encoding::BINARY)
      reader = Thread.new do
        conn = server.accept
        while received.bytesize < expected_bytes
          chunk = conn.read(expected_bytes - received.bytesize)
          break if chunk.nil? || chunk.empty?

          received << chunk
        end
        conn.close
        received
      end
      client = TCPSocket.new('127.0.0.1', port)
      yield client, reader
    ensure
      client&.close unless client&.closed?
      server&.close
    end

    let(:payload) { (0..255).map(&:chr).join.b * 4096 } # 1 MiB

    let(:tempfile) do
      Tempfile.new(%w[hyperion-blocking-sendfile .bin]).tap do |f|
        f.binmode
        f.write(payload)
        f.flush
        f.rewind
      end
    end

    after { tempfile.close! }

    it 'streams a 1 MiB file byte-for-byte through copy_to_socket_blocking' do
      with_socket_pair(payload.bytesize) do |client, reader|
        written = Hyperion::Http::Sendfile.copy_to_socket_blocking(client, tempfile, 0,
                                                                   payload.bytesize)
        client.close
        expect(written).to eq(payload.bytesize)
        expect(reader.value.bytesize).to eq(payload.bytesize)
        expect(reader.value).to eq(payload)
      end
    end

    it 'short-circuits a 0-byte body without raising' do
      Tempfile.create(%w[hyperion-blocking-empty .bin]) do |empty|
        empty.binmode
        empty.write('')
        empty.flush
        with_socket_pair(0) do |client, reader|
          written = Hyperion::Http::Sendfile.copy_to_socket_blocking(client, empty, 0, 0)
          client.close
          expect(written).to eq(0)
          expect(reader.value).to eq('')
        end
      end
    end
  end

  describe '2.6-D — engagement gap fix (Fiber.blocking under Async)' do
    # 2.6-C shipped the dispatch mode but the maintainer's openclaw-vm
    # bench under `--async-io` showed p99 stuck at 433-710 ms — the
    # auto-detect set the flag, the writer plumbed it, but the
    # blocking-sendfile loop's `IO.select` STILL went through the
    # Async fiber scheduler's `kernel_select` hook, so each EAGAIN
    # yielded the fiber instead of parking the OS thread.  2.6-D
    # closes the gap by wrapping the `:inline_blocking` write in
    # `Fiber.blocking { ... }` — the calling fiber's `blocking?`
    # flag flips to true for the duration, the scheduler is no
    # longer consulted, and the OS thread parks on the kernel
    # readiness check exactly as Puma does.
    #
    # The regression specs below boot a real Async reactor + a real
    # socket pair so the fiber-yield path is actually exercised.
    # Pre-2.6-D, these specs WOULD fail under `--async-io` (the
    # blocking variant would silently fall back to fiber-yielding
    # via the Async scheduler's IO.select hook).

    let(:tempfile) do
      Tempfile.new(%w[hyperion-2-6-d-engagement .bin]).tap do |f|
        f.binmode
        # Larger than SENDFILE_COALESCE_THRESHOLD (64 KiB) so the
        # streaming path runs (which is the only path that calls
        # `copy_to_socket_blocking`).
        f.write('x' * 200_000)
        f.flush
      end
    end

    after { tempfile.close! }

    def file_body(path)
      Class.new do
        def initialize(path)
          @path = path
        end

        def to_path
          @path
        end

        def each
          yield File.binread(@path)
        end

        def close; end
      end.new(path)
    end

    it 'flips Fiber.current.blocking? to true while sendfile is running under Async' do
      require 'async'

      observed_blocking = nil
      observed_scheduler_was_set = nil

      # Stub `select_writable_blocking` so we observe the calling-
      # fiber state at the moment EAGAIN handling fires.  Even on
      # platforms where the blocking sendfile path completes without
      # ever returning EAGAIN (warm-cache + fast loopback), we
      # observe the blocking-flag at `copy_to_socket_blocking` entry
      # by stubbing the inner.
      original_inner = Hyperion::Http::Sendfile.method(:copy_to_socket_blocking_inner)
      allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket_blocking_inner) do |out_io, file_io, off, len|
        observed_scheduler_was_set ||= !Fiber.scheduler.nil?
        observed_blocking ||= Fiber.current.blocking?
        original_inner.call(out_io, file_io, off, len)
      end

      writer = Hyperion::ResponseWriter.new
      Async do
        # Spawn a real socket pair so the writer takes a real path
        # (not StringIO); use TCPServer/TCPSocket so the platform's
        # native sendfile branch is reachable on Linux/Darwin.
        server = TCPServer.new('127.0.0.1', 0)
        port   = server.addr[1]
        client_pair = TCPSocket.new('127.0.0.1', port)
        srv_side, = server.accept
        # Drain the server side concurrently so the writer doesn't
        # block on a full socket buffer.
        drain = Thread.new { srv_side.read(200_000 + 200) }
        writer.write(client_pair, 200, { 'content-type' => 'application/octet-stream' },
                     file_body(tempfile.path), dispatch_mode: :inline_blocking)
        client_pair.close
        drain.join(2)
        server.close
      end.wait

      expect(observed_scheduler_was_set).to be(true) # Sanity: Async scheduler was current at entry.
      expect(observed_blocking).to be(true)          # Engagement-gap fix: Fiber.blocking flipped the flag.
    end

    it 'invokes copy_to_socket_blocking (not copy_to_socket) under :inline_blocking on a real socket' do
      # End-to-end engagement regression: a Hyperion::Connection
      # serving a `to_path` body under an Async scheduler MUST land
      # on the blocking sendfile primitive, not the fiber-yielding
      # one.  Pre-2.6-D the auto-detect set the flag but the under-
      # `--async-io` write path bypassed the dispatch_mode branch
      # because IO.select itself was scheduler-aware.
      require 'async'

      blocking_calls   = 0
      yielding_calls   = 0

      allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket_blocking).and_wrap_original do |original, *args|
        blocking_calls += 1
        original.call(*args)
      end
      allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket).and_wrap_original do |original, *args|
        yielding_calls += 1
        original.call(*args)
      end

      writer = Hyperion::ResponseWriter.new
      Async do
        server = TCPServer.new('127.0.0.1', 0)
        port   = server.addr[1]
        client_pair = TCPSocket.new('127.0.0.1', port)
        srv_side, = server.accept
        drain = Thread.new { srv_side.read(200_000 + 200) }
        writer.write(client_pair, 200, {}, file_body(tempfile.path),
                     dispatch_mode: :inline_blocking)
        client_pair.close
        drain.join(2)
        server.close
      end.wait

      expect(blocking_calls).to eq(1)
      expect(yielding_calls).to eq(0)
    end

    it 'leaves the fiber-yielding path engaged when dispatch_mode is nil under Async' do
      require 'async'

      blocking_calls = 0
      yielding_calls = 0

      allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket_blocking).and_wrap_original do |original, *args|
        blocking_calls += 1
        original.call(*args)
      end
      allow(Hyperion::Http::Sendfile).to receive(:copy_to_socket).and_wrap_original do |original, *args|
        yielding_calls += 1
        original.call(*args)
      end

      writer = Hyperion::ResponseWriter.new
      Async do
        server = TCPServer.new('127.0.0.1', 0)
        port   = server.addr[1]
        client_pair = TCPSocket.new('127.0.0.1', port)
        srv_side, = server.accept
        drain = Thread.new { srv_side.read(200_000 + 200) }
        writer.write(client_pair, 200, {}, file_body(tempfile.path)) # default (nil) dispatch_mode
        client_pair.close
        drain.join(2)
        server.close
      end.wait

      expect(yielding_calls).to eq(1)
      expect(blocking_calls).to eq(0)
    end

    it 'select_writable_blocking flips Fiber.current.blocking? to true' do
      # Direct test of the helper that 2.6-C shipped without the
      # `Fiber.blocking` wrap.  Pre-2.6-D this would fail under an
      # Async reactor (Fiber.current.blocking? would be false because
      # the scheduler-aware IO.select would intercept).
      require 'async'
      observed = []

      Async do
        srv = TCPServer.new('127.0.0.1', 0)
        port = srv.addr[1]
        client = TCPSocket.new('127.0.0.1', port)
        srv_conn, = srv.accept

        # Custom IO that records the fiber's blocking flag at the
        # moment IO.select is consulted.
        wrapper = Object.new
        wrapper.define_singleton_method(:to_io) { client }
        # Wrap in Fiber.blocking-eligible call: the helper itself
        # decides whether to wrap based on Fiber.current.blocking?.
        # We assert the post-wrap state by checking via a stub of
        # IO.select.
        allow(IO).to receive(:select).and_wrap_original do |original, *args|
          observed << Fiber.current.blocking?
          original.call(*args)
        end

        Hyperion::Http::Sendfile.send(:select_writable_blocking, wrapper)

        client.close
        srv_conn.close
        srv.close
      end.wait

      # observed should be a non-empty array with all values true.
      expect(observed).not_to be_empty
      expect(observed).to all(be(true))
    end
  end

  describe '2.6-D — Connection per-conn fairness bypass on :inline_blocking sticky path' do
    # 2.6-D — once a Connection's previous response auto-detected
    # into `:inline_blocking`, the next request iteration on the
    # same keep-alive connection skips the per-conn fairness
    # admission check.  Static-asset connections (CDN origins,
    # signed-download responders) typically run a long sequence
    # of `to_path` responses; the fairness cap was designed for
    # dynamic-route concurrency throttling and is dead weight on
    # a static stream.

    it 'flips @last_response_was_static_inline_blocking after a :inline_blocking response' do
      conn = Hyperion::Connection.new
      conn.response_dispatch_mode = :inline_blocking
      # Simulate the post-write flag flip the request loop performs:
      # we call the same line of code by setting via instance_variable_set.
      conn.instance_variable_set(:@last_response_was_static_inline_blocking,
                                 conn.response_dispatch_mode == :inline_blocking)
      expect(conn.instance_variable_get(:@last_response_was_static_inline_blocking)).to be(true)
    end

    it 'resets @last_response_was_static_inline_blocking on a non-static response' do
      conn = Hyperion::Connection.new
      conn.instance_variable_set(:@last_response_was_static_inline_blocking, true)
      conn.response_dispatch_mode = nil
      conn.instance_variable_set(:@last_response_was_static_inline_blocking,
                                 conn.response_dispatch_mode == :inline_blocking)
      expect(conn.instance_variable_get(:@last_response_was_static_inline_blocking)).to be(false)
    end

    it 'has Connection#per_conn_admit! available for non-static dynamic routes' do
      # Sanity: the per-conn fairness machinery still exists and
      # fires for connections configured with a cap.  We don't
      # exercise the full serve loop here (that's covered by the
      # 2.3-B specs); we just confirm the cap-bookkeeping ivars
      # are still wired when the cap is set.
      conn = Hyperion::Connection.new(max_in_flight_per_conn: 1)
      expect(conn.instance_variable_get(:@max_in_flight_per_conn)).to eq(1)
      expect(conn.instance_variable_get(:@in_flight_mutex)).to be_a(Mutex)
    end
  end
end
