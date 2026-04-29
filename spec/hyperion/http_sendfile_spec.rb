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
      allow(described_class).to receive(:copy) do |_out, in_io, offset, len|
        # Simulate that we read from `in_io` so the userspace fallback path
        # (if it triggered by mistake) wouldn't be hit. We only return the
        # scripted answer.
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
      allow(described_class).to receive(:copy).once.and_raise(Errno::EPIPE)

      expect do
        described_class.copy_to_socket(out, tempfile, 0, 1024)
      end.to raise_error(Errno::EPIPE)
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
