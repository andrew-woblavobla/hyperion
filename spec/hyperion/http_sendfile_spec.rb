# frozen_string_literal: true

require 'socket'
require 'tempfile'
require 'hyperion'
require 'hyperion/http/sendfile'

# Phase 1 (1.7.0) — exercises the C-extension sendfile fast path through its
# Ruby façade (`Hyperion::Http::Sendfile.copy_to_socket`). These tests target
# the kernel path on the host where they run; on a host without native zero-
# copy compiled in (`Sendfile.supported?` returns false) the same suite still
# exercises the userspace fallback because `copy_to_socket` routes through it.
RSpec.describe Hyperion::Http::Sendfile do
  # Helper: build a `[server_thread, client_socket]` pair where the server
  # thread accepts once, drains exactly `expected_bytes` bytes, and yields
  # them as a String to the spec.
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

  let(:payload) { (0..255).map(&:chr).join.b * 4096 } # 1 MiB of distinct bytes

  let(:tempfile) do
    Tempfile.new(%w[hyperion-sendfile .bin]).tap do |f|
      f.binmode
      f.write(payload)
      f.flush
      f.rewind
    end
  end

  after { tempfile.close! }

  describe '.supported? / .platform_tag' do
    it 'reports a non-nil tag and a Boolean supported?' do
      expect([true, false]).to include(described_class.supported?)
      expect(described_class.platform_tag).to be_a(Symbol)
    end
  end

  describe '.copy_to_socket — round-trip integrity' do
    it 'streams a 1 MiB file byte-for-byte through a real TCPSocket' do
      with_socket_pair(payload.bytesize) do |client, reader|
        written = described_class.copy_to_socket(client, tempfile, 0, payload.bytesize)
        client.close
        expect(written).to eq(payload.bytesize)
        expect(reader.value).to eq(payload)
      end
    end

    it 'handles a 1-byte file (boundary)' do
      one = Tempfile.new(%w[hy-sf-1 .bin]).tap do |f|
        f.binmode
        f.write('Z')
        f.flush
        f.rewind
      end
      begin
        with_socket_pair(1) do |client, reader|
          written = described_class.copy_to_socket(client, one, 0, 1)
          client.close
          expect(written).to eq(1)
          expect(reader.value).to eq('Z')
        end
      ensure
        one.close!
      end
    end

    it 'short-circuits a 0-byte body without raising' do
      empty = Tempfile.new(%w[hy-sf-0 .bin]).tap do |f|
        f.binmode
        f.flush
      end
      begin
        with_socket_pair(0) do |client, reader|
          written = described_class.copy_to_socket(client, empty, 0, 0)
          client.close
          expect(written).to eq(0)
          # Reader sees EOF immediately — empty String.
          expect(reader.value.bytesize).to eq(0)
        end
      ensure
        empty.close!
      end
    end

    it 'serves a Range slice (offset/len in the middle of the file)' do
      offset = 1_000
      length = 1_500
      expected = payload.byteslice(offset, length)
      with_socket_pair(length) do |client, reader|
        written = described_class.copy_to_socket(client, tempfile, offset, length)
        client.close
        expect(written).to eq(length)
        expect(reader.value).to eq(expected)
      end
    end
  end

  describe 'EAGAIN / fiber-yield correctness' do
    # Fake out_io that returns :eagain once then accepts the rest.
    # Verifies the loop yields (calls wait_writable) and resumes from the
    # right cursor instead of busy-spinning or losing bytes.
    it 'yields rather than busy-loops on a transient EAGAIN' do
      stub_out = Class.new do
        attr_reader :waited, :bytes_accepted

        def initialize
          @first  = true
          @waited = 0
          @bytes_accepted = +''.b
        end

        def fileno
          # An invalid-but-non-negative fd; the C ext won't be invoked
          # because the test stubs `Sendfile.copy` directly.
          0
        end

        def wait_writable
          @waited += 1
          self
        end

        def write(s)
          @bytes_accepted << s
          s.bytesize
        end
      end.new

      file_io = StringIO.new(payload.byteslice(0, 256))
      script = [[0, :eagain], [256, :done]]
      script_index = 0

      allow(described_class).to receive(:fast_path_kind).and_return(:native)
      # Phase 8b: on Linux the streaming loop tries copy_splice first.
      # Stub it to defer into the same scripted answers as `copy` so this
      # test runs identically on macOS (no splice) and Linux (splice
      # short-circuited here to keep the EAGAIN-yield assertion stable).
      script_handler = lambda do |_out, in_io, offset, len|
        in_io.seek(offset) if in_io.respond_to?(:seek)
        rec = script[script_index]
        script_index += 1
        if rec[1] == :done
          # Pretend we wrote the bytes onto stub_out so the spec can
          # introspect what reached the wire.
          stub_out.write(in_io.read(len))
        end
        rec
      end
      allow(described_class).to receive(:copy, &script_handler)
      allow(described_class).to receive(:copy_splice, &script_handler) if described_class.respond_to?(:copy_splice)

      written = described_class.copy_to_socket(stub_out, file_io, 0, 256)

      expect(stub_out.waited).to eq(1) # yielded exactly once on EAGAIN
      expect(written).to eq(256)
      expect(stub_out.bytes_accepted.bytesize).to eq(256)
    end
  end

  describe 'error propagation from the kernel' do
    # When the kernel reports a hard error (EPIPE on a fully-closed peer,
    # ECONNRESET on a forcibly-reset connection, EBADF on a stale fd), the
    # Ruby façade must surface it to the caller as a SystemCallError —
    # NOT swallow it, NOT spin on :eagain, NOT crash. We simulate by
    # stubbing the C-level `copy` to raise.
    it 'propagates SystemCallError from the C primitive without retry' do
      out = StringIO.new(+''.b)
      allow(described_class).to receive(:fast_path_kind).and_return(:native)
      # 1024 bytes routes through the small-file fast path (Phase 8a).
      # 65 KiB would route through the streaming `copy` primitive instead.
      allow(described_class).to receive(:copy_small).once.and_raise(Errno::EPIPE)
      allow(described_class).to receive(:copy).once.and_raise(Errno::EPIPE)

      expect do
        described_class.copy_to_socket(out, tempfile, 0, 1024)
      end.to raise_error(Errno::EPIPE)
    end
  end

  describe 'Phase 8a — small-file fast path' do
    it 'exposes a small-file threshold introspection method' do
      skip 'native ext not loaded' unless described_class.respond_to?(:small_file_threshold)

      expect(described_class.small_file_threshold).to eq(64 * 1024)
    end

    it 'routes a 1 KiB single-MSS file through copy_small (one call) and not through copy' do
      skip 'native ext not loaded' unless described_class.respond_to?(:copy_small)

      one_k = Tempfile.new(%w[hy-sf-1k .bin]).tap do |f|
        f.binmode
        f.write('A' * 1024)
        f.flush
        f.rewind
      end
      begin
        with_socket_pair(1024) do |client, reader|
          # Spy on both primitives — copy_small should fire exactly once,
          # copy (the streaming sendfile primitive) should not be invoked
          # at all because the file fits the small-file threshold.
          allow(described_class).to receive(:copy_small).and_call_original
          allow(described_class).to receive(:copy).and_call_original

          written = described_class.copy_to_socket(client, one_k, 0, 1024)
          client.close

          expect(described_class).to have_received(:copy_small).once
          expect(described_class).not_to have_received(:copy)
          expect(written).to eq(1024)
          expect(reader.value.bytesize).to eq(1024)
        end
      ensure
        one_k.close!
      end
    end

    it 'routes an 8 KiB file through copy_small (one call) and not through copy' do
      skip 'native ext not loaded' unless described_class.respond_to?(:copy_small)

      eight_k = Tempfile.new(%w[hy-sf-8k .bin]).tap do |f|
        f.binmode
        f.write('B' * 8192)
        f.flush
        f.rewind
      end
      begin
        with_socket_pair(8192) do |client, reader|
          allow(described_class).to receive(:copy_small).and_call_original
          allow(described_class).to receive(:copy).and_call_original

          written = described_class.copy_to_socket(client, eight_k, 0, 8192)
          client.close

          expect(described_class).to have_received(:copy_small).once
          expect(described_class).not_to have_received(:copy)
          expect(written).to eq(8192)
          expect(reader.value).to eq('B' * 8192)
        end
      ensure
        eight_k.close!
      end
    end

    it 'falls through to the streaming path at the 65 KiB boundary (just over threshold)' do
      skip 'native ext not loaded' unless described_class.respond_to?(:copy_small)

      big = Tempfile.new(%w[hy-sf-65k .bin]).tap do |f|
        f.binmode
        f.write('C' * (65 * 1024))
        f.flush
        f.rewind
      end
      begin
        size = big.size
        with_socket_pair(size) do |client, reader|
          allow(described_class).to receive(:copy_small).and_call_original

          written = described_class.copy_to_socket(client, big, 0, size)
          client.close

          # 65 KiB > SMALL_FILE_THRESHOLD (64 KiB) — small-file path
          # MUST NOT fire on this size.
          expect(described_class).not_to have_received(:copy_small)
          expect(written).to eq(size)
          expect(reader.value.bytesize).to eq(size)
        end
      ensure
        big.close!
      end
    end

    it 'rejects len > SMALL_FILE_THRESHOLD on the C primitive directly' do
      skip 'native ext not loaded' unless described_class.respond_to?(:copy_small)

      with_socket_pair(0) do |client, _reader|
        expect do
          described_class.copy_small(client, tempfile, 0, (64 * 1024) + 1)
        end.to raise_error(ArgumentError, /SMALL_FILE_THRESHOLD/)
        client.close
      end
    end
  end

  describe 'Phase 8b — splice(2) through pipe (Linux-only)' do
    it 'exposes splice_supported? introspection on every host' do
      expect([true, false]).to include(described_class.splice_supported?)
    end

    it 'reports splice_supported? == true on Linux builds' do
      skip 'non-Linux host' unless /linux/i.match?(RbConfig::CONFIG['host_os'])

      expect(described_class.splice_supported?).to be(true)
    end

    it 'transfers a 1 MiB file byte-for-byte via copy_splice (primitive-level)' do
      skip 'splice path not compiled' unless described_class.respond_to?(:copy_splice)
      skip 'splice path inert on this host' unless described_class.splice_supported?

      with_socket_pair(payload.bytesize) do |client, reader|
        # 2.2.0 — the splice primitive is back on the production hot
        # path through copy_to_socket for files > SPLICE_THRESHOLD.
        # We still drive it directly here to assert the C-level
        # byte-integrity contract independent of the Ruby façade.
        remaining = payload.bytesize
        cursor    = 0
        total     = 0
        while remaining.positive?
          bytes, status = described_class.copy_splice(client, tempfile, cursor, remaining)
          break if bytes.zero? && status == :unsupported

          total     += bytes
          cursor    += bytes
          remaining -= bytes
          break if status == :done
        end
        client.close

        expect(total).to eq(payload.bytesize)
        expect(reader.value).to eq(payload)
      end
    end

    it 'falls back to copy() on non-Linux builds — splice_supported? is false' do
      skip 'this host has splice' if described_class.splice_supported?

      # On macOS / BSD splice_supported? is false; the streaming loop
      # uses plain sendfile (the existing 1 MiB integrity test in
      # `.copy_to_socket — round-trip integrity` already covers byte
      # equality on this host, so we just assert the gate is closed.
      expect(described_class.splice_supported?).to be(false)
    end
  end

  describe '2.2.0 — splice fresh-pipe lifecycle' do
    # Helper: count open fds owned by this process.  On Linux we read
    # /proc/self/fd; on macOS we use lsof piped through wc -l.  We
    # don't care about the absolute number — only the delta across a
    # batch of requests.  If the splice path leaks pipe fds (the
    # 2.0.1 disable rationale), this delta grows with the request
    # count.  The 2.2.0 fresh-pipe layout closes both fds on every
    # exit path, so the delta is bounded by transient fds (Tempfile,
    # TCPSocket pair) — a handful at most.
    def open_fd_count
      if File.directory?('/proc/self/fd')
        Dir.children('/proc/self/fd').size
      else
        # macOS fallback: count fds via lsof.  Slower, but only used
        # when we actually need a delta on a non-Linux host (where
        # the splice path is inert anyway and the test asserts the
        # primitive path through copy_splice).
        `lsof -p #{Process.pid} 2>/dev/null | wc -l`.to_i
      end
    end

    it 'closes both pipe fds on every successful copy_splice call (no fd leak across 1000 requests)' do
      skip 'splice path not compiled' unless described_class.respond_to?(:copy_splice)
      skip 'splice path inert on this host' unless described_class.splice_supported?

      # Build one tempfile, reuse it across 1000 connections so the
      # only fd-cycling source is the splice path itself.
      small = Tempfile.new(%w[hy-sf-leak .bin]).tap do |f|
        f.binmode
        f.write('X' * 200_000) # 200 KiB — above SPLICE_THRESHOLD
        f.flush
        f.rewind
      end

      begin
        # Warm the path once to amortize one-time allocations
        # (libc internal buffers, glibc thread-local malloc cache,
        # whatever).  Then snapshot the fd count.
        with_socket_pair(small.size) do |client, reader|
          described_class.copy_splice(client, small, 0, small.size)
          client.close
          reader.value
        end

        baseline = open_fd_count

        1000.times do
          with_socket_pair(small.size) do |client, reader|
            remaining = small.size
            cursor    = 0
            while remaining.positive?
              bytes, status = described_class.copy_splice(client, small, cursor, remaining)
              break if bytes.zero? && status == :unsupported

              cursor    += bytes
              remaining -= bytes
              break if status == :done
            end
            client.close
            reader.value
          end
        end

        # Allow up to ~32 fds of slack — the test infrastructure
        # itself (Tempfile, TCPServer/TCPSocket, Thread join handles)
        # opens transient fds that don't always get reaped between
        # iterations.  The 2.0.1 cached-pipe leak would have grown
        # by 2× num_threads (one pipe pair per thread), but the
        # actual concern is unbounded growth: 1000 calls → 1000+
        # leaked fds.  An fd delta that stays below 32 across
        # 1000 calls is comfortably within the no-leak regime.
        delta = open_fd_count - baseline
        expect(delta).to be < 32,
                         "fd count grew by #{delta} across 1000 splice calls — pipe pair leak suspected"
      ensure
        small.close!
      end
    end

    it 'closes both pipe fds even when the peer closes mid-transfer (EPIPE)' do
      skip 'splice path not compiled' unless described_class.respond_to?(:copy_splice)
      skip 'splice path inert on this host' unless described_class.splice_supported?

      # Build a 4 MiB file so a slow drain on the reader side keeps
      # bytes parked in the pipe long enough for us to slam the
      # peer fd shut.
      big = Tempfile.new(%w[hy-sf-epipe .bin]).tap do |f|
        f.binmode
        f.write('Y' * (4 * 1024 * 1024))
        f.flush
        f.rewind
      end

      begin
        baseline = open_fd_count

        50.times do
          server = TCPServer.new('127.0.0.1', 0)
          port   = server.addr[1]
          slammer = Thread.new do
            conn = server.accept
            # Read just a tiny bit then slam shut — forces EPIPE
            # mid-splice on the writer side.
            begin
              conn.read(1024)
            rescue StandardError
              # ignore
            end
            conn.close
          end
          client = TCPSocket.new('127.0.0.1', port)

          begin
            # Issue splice calls until we either finish or hit EPIPE.
            remaining = big.size
            cursor    = 0
            loop do
              break if remaining.zero?

              bytes, status = described_class.copy_splice(client, big, cursor, remaining)
              break if bytes.zero? && status == :unsupported

              cursor    += bytes
              remaining -= bytes
              break if status == :done
            end
          rescue Errno::EPIPE, Errno::ECONNRESET, Errno::EBADF
            # Expected — peer slammed.  We're testing the lifecycle,
            # not the error class.
          ensure
            client.close
            slammer.join
            server.close
          end
        end

        # 50 mid-transfer EPIPEs MUST NOT leak pipe fds.  Each splice
        # call pays pipe2 + 2× close even on the error path.
        delta = open_fd_count - baseline
        expect(delta).to be < 32,
                         "fd count grew by #{delta} across 50 EPIPE-mid-transfer splice calls — pipe pair leak on error path"
      ensure
        big.close!
      end
    end

    it 'preserves byte equality between splice and plain sendfile for the same payload' do
      skip 'splice path not compiled' unless described_class.respond_to?(:copy_splice)
      skip 'splice path inert on this host' unless described_class.splice_supported?

      # Drive the same 1 MiB payload through both primitives and
      # assert the wire bytes are identical — guards against subtle
      # off-by-one bugs in the offset bookkeeping after the cursor
      # advance through pipe -> socket short-writes.
      via_splice = String.new(encoding: Encoding::BINARY)
      via_sendfile = String.new(encoding: Encoding::BINARY)

      with_socket_pair(payload.bytesize) do |client, reader|
        remaining = payload.bytesize
        cursor    = 0
        while remaining.positive?
          bytes, status = described_class.copy_splice(client, tempfile, cursor, remaining)
          break if bytes.zero? && status == :unsupported

          cursor    += bytes
          remaining -= bytes
          break if status == :done
        end
        client.close
        via_splice = reader.value
      end

      tempfile.rewind
      with_socket_pair(payload.bytesize) do |client, reader|
        remaining = payload.bytesize
        cursor    = 0
        while remaining.positive?
          bytes, status = described_class.copy(client, tempfile, cursor, remaining)
          break if bytes.zero? && status == :unsupported

          cursor    += bytes
          remaining -= bytes
          break if status == :done
        end
        client.close
        via_sendfile = reader.value
      end

      expect(via_splice.bytesize).to eq(payload.bytesize)
      expect(via_sendfile.bytesize).to eq(payload.bytesize)
      expect(via_splice).to eq(via_sendfile)
      expect(via_splice).to eq(payload)
    end

    it 'falls back to plain sendfile when splice_runtime_supported? is stubbed false' do
      skip 'native ext not loaded' unless described_class.respond_to?(:copy_splice)

      # Force the runtime gate closed and assert copy_splice is
      # never called from the production hot path.  Plain `copy`
      # carries the transfer.
      allow(described_class).to receive(:splice_runtime_supported?).and_return(false)
      allow(described_class).to receive(:copy_splice).and_call_original

      with_socket_pair(payload.bytesize) do |client, reader|
        written = described_class.copy_to_socket(client, tempfile, 0, payload.bytesize)
        client.close
        expect(written).to eq(payload.bytesize)
        expect(reader.value).to eq(payload)
      end

      expect(described_class).not_to have_received(:copy_splice)
    ensure
      # Reset the cached runtime flag so the next spec sees the
      # real value (RSpec's allow already drops stub at end of
      # example, but the production path may also have called
      # mark_splice_unsupported! during a fall-back run).
      if described_class.instance_variable_defined?(:@splice_runtime_supported)
        described_class.remove_instance_variable(:@splice_runtime_supported)
      end
    end
  end

  describe 'integration through ResponseWriter#write_sendfile' do
    let(:writer) { Hyperion::ResponseWriter.new }

    it 'preserves byte-perfect content end-to-end via the writer' do
      body = Class.new do
        def initialize(path) = @path = path
        def to_path = @path
        def each = yield File.binread(@path)
        def close; end
      end.new(tempfile.path)

      with_socket_pair(payload.bytesize + 1024) do |client, reader|
        # +1024 cushion lets the reader's loop pull headers + body without
        # blocking on an exact byte-count match (we re-derive the body
        # boundary from the raw response).
        writer.write(client, 200, { 'content-type' => 'application/octet-stream' }, body)
        client.close
        raw = reader.value
        expect(raw).to start_with("HTTP/1.1 200 OK\r\n")
        head, body_bytes = raw.split("\r\n\r\n", 2)
        expect(head).to include("content-length: #{payload.bytesize}")
        expect(body_bytes).to eq(payload)
      end
    end
  end
end
