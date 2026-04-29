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
        # Drive the splice primitive directly — copy_to_socket no longer
        # routes through it (plain sendfile is the production streaming
        # path; persistent per-thread pipes risked leaking residual
        # bytes between requests on EPIPE). We still own the primitive
        # and verify byte integrity for callers that opt in.
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
