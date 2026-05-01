# frozen_string_literal: true

require 'fileutils'
require 'socket'
require 'tempfile'
require 'tmpdir'
require 'hyperion'
require 'hyperion/http/page_cache'

# 2.10-C — Hyperion::Http::PageCache (pre-built static-response cache).
#
# Mirrors agoo's agooPage design: each cached static asset's full HTTP/1.1
# response (status line + Content-Type + Content-Length + body) lives in
# ONE contiguous heap buffer.  On the hot path the cache issues a single
# write() syscall with zero Ruby allocations.  These specs assert:
#
#   * Cache hit → byte-exact response on the wire (via real TCP pair).
#   * Cache miss → :missing.
#   * Mtime invalidation: file changed past `recheck_seconds` → response
#     buffer rebuilt.
#   * Immutable flag: file changed → response buffer NOT rebuilt.
#   * Recursive preload of a directory tree.
#   * Per-extension Content-Type lookup covers the common asset types.
#   * Hot-path zero-allocation: 1000 cache hits add < 100 Ruby objects to
#     the allocation counter.
RSpec.describe Hyperion::Http::PageCache do
  before { described_class.clear }
  after  { described_class.clear }

  # Build a TCP socket pair where the server thread accepts once and
  # drains every byte the client writes; yields the populated client
  # socket to the spec block, then returns the bytes the server saw.
  def with_tcp_pair
    server = TCPServer.new('127.0.0.1', 0)
    port   = server.addr[1]
    String.new(encoding: Encoding::BINARY)
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
    yield client
    client.close
    received = reader.value
    server.close
    received
  end

  # Helper: write `body` to a tempfile in `dir` under `name`, return path.
  def write_file(dir, name, body)
    path = File.join(dir, name)
    File.binwrite(path, body)
    path
  end

  describe '.available?' do
    it 'is true when the C primitive is registered' do
      expect(described_class.available?).to eq(true)
    end
  end

  describe '.cache_file + .fetch + .write_to round trip on a 1 KiB file' do
    let(:body) { 'x' * 1024 }
    let(:path) do
      Dir::Tmpname.create(['hyperion-pc-1k', '.bin']) do |p|
        File.binwrite(p, body)
      end
    end

    after { FileUtils.rm_f(path) }

    it 'caches, reports :ok, and writes a byte-exact HTTP/1.1 response' do
      expect(described_class.cache_file(path)).to eq(1024)
      expect(described_class.fetch(path)).to eq(:ok)
      expect(described_class.body_bytes(path)).to eq(1024)
      expect(described_class.content_type(path)).to eq('application/octet-stream')

      received = with_tcp_pair do |client|
        n = described_class.write_to(client, path)
        expect(n).to be > 1024 # body + headers
      end

      # Status line + headers + blank line + body bytes.
      expect(received).to start_with("HTTP/1.1 200 OK\r\n")
      expect(received).to include("Content-Type: application/octet-stream\r\n")
      expect(received).to include("Content-Length: 1024\r\n\r\n")
      expect(received[-1024..]).to eq(body)
    end
  end

  describe '.write_to' do
    it 'returns :missing when the path is not cached' do
      result = with_tcp_pair { |client| described_class.write_to(client, '/nope/abc') }
      # `write_to` returns :missing without touching the socket; `received`
      # is whatever the server saw, which is empty bytes.
      expect(result).to be_a(String).or be_empty
      # Re-run inline to capture the return value cleanly.
      server = TCPServer.new('127.0.0.1', 0)
      client = TCPSocket.new('127.0.0.1', server.addr[1])
      expect(described_class.write_to(client, '/nope/abc')).to eq(:missing)
      client.close
      server.close
    end
  end

  describe 'mtime invalidation' do
    around do |example|
      Dir.mktmpdir('hyperion-pc-mtime') do |dir|
        @dir  = dir
        @path = File.join(dir, 'index.html')
        File.binwrite(@path, '<h1>v1</h1>')
        # Stamp v1 well in the past so a fresh File.binwrite below
        # produces an mtime that differs at second resolution even on
        # filesystems with coarse mtime granularity.
        File.utime(Time.now - 60, Time.now - 60, @path)
        described_class.recheck_seconds = 0.0 # force re-stat on every read
        example.run
        described_class.recheck_seconds = 5.0
      end
    end

    it 'rebuilds the response buffer when the file mtime advances' do
      expect(described_class.cache_file(@path)).to eq(11)
      expect(described_class.response_bytes(@path)).to include('<h1>v1</h1>')

      File.binwrite(@path, '<h1>v2-with-extra-bytes</h1>')
      File.utime(Time.now, Time.now, @path)

      expect(described_class.fetch(@path)).to eq(:stale)
      expect(described_class.response_bytes(@path)).to include('<h1>v2-with-extra-bytes</h1>')
      expect(described_class.body_bytes(@path)).to eq(28)
    end
  end

  describe 'immutable flag' do
    around do |example|
      Dir.mktmpdir('hyperion-pc-immut') do |dir|
        @path = File.join(dir, 'asset-abc123.css')
        File.binwrite(@path, '.a{color:red}')
        # Stamp v1 well in the past so a fresh `File.utime(Time.now, ...)`
        # below produces an mtime that differs at second resolution
        # (some filesystems round mtime to the nearest second).
        File.utime(Time.now - 60, Time.now - 60, @path)
        described_class.recheck_seconds = 0.0
        example.run
        described_class.recheck_seconds = 5.0
      end
    end

    it 'does not re-stat when the file is marked immutable' do
      expect(described_class.cache_file(@path)).to eq(13)
      expect(described_class.mark_immutable(@path)).to eq(true)

      File.binwrite(@path, '.a{color:blue}')
      File.utime(Time.now, Time.now, @path)

      expect(described_class.fetch(@path)).to eq(:ok)
      # Buffer still holds the v1 body.
      expect(described_class.response_bytes(@path)).to include('color:red')

      # Flip back to mutable; re-stat picks up v2.
      expect(described_class.mark_mutable(@path)).to eq(true)
      expect(described_class.fetch(@path)).to eq(:stale)
      expect(described_class.response_bytes(@path)).to include('color:blue')
    end
  end

  describe '.preload' do
    it 'recursively walks a tree and caches every regular file' do
      Dir.mktmpdir('hyperion-pc-tree') do |dir|
        write_file(dir, 'index.html', '<h1>i</h1>')
        write_file(dir, 'style.css', '.a{}')
        FileUtils.mkdir_p(File.join(dir, 'sub'))
        write_file(dir, 'sub/app.js', 'alert(1)')

        count = described_class.preload(dir)
        expect(count).to eq(3)
        expect(described_class.size).to eq(3)
        expect(described_class.fetch(File.join(dir, 'index.html'))).to eq(:ok)
        expect(described_class.fetch(File.join(dir, 'sub/app.js'))).to eq(:ok)
      end
    end

    it 'returns 0 and does not raise for a missing directory' do
      expect(described_class.preload('/no/such/dir')).to eq(0)
    end

    it 'marks every entry immutable when immutable: true' do
      Dir.mktmpdir('hyperion-pc-immut-pre') do |dir|
        described_class.recheck_seconds = 0.0
        path = write_file(dir, 'asset-abc.svg', '<svg/>')
        described_class.preload(dir, immutable: true)

        File.binwrite(path, '<svg>v2</svg>')
        File.utime(Time.now, Time.now, path)

        expect(described_class.fetch(path)).to eq(:ok)
        expect(described_class.response_bytes(path)).to include('<svg/>')
        described_class.recheck_seconds = 5.0
      end
    end
  end

  describe 'per-extension Content-Type' do
    {
      'foo.html' => 'text/html',
      'foo.htm' => 'text/html',
      'foo.css' => 'text/css',
      'foo.js' => 'application/javascript',
      'foo.json' => 'application/json',
      'foo.png' => 'image/png',
      'foo.jpg' => 'image/jpeg',
      'foo.svg' => 'image/svg+xml',
      'foo.txt' => 'text/plain; charset=utf-8',
      'foo.woff2' => 'font/woff2',
      'foo.unknown_ext' => 'application/octet-stream',
      'no_ext_at_all' => 'application/octet-stream'
    }.each do |fname, expected_ct|
      it "maps #{fname.inspect} → #{expected_ct.inspect}" do
        Dir.mktmpdir('hyperion-pc-ct') do |dir|
          path = write_file(dir, fname, 'x')
          described_class.cache_file(path)
          expect(described_class.content_type(path)).to eq(expected_ct)
        end
      end
    end
  end

  describe 'hot-path zero-allocation' do
    it 'allocates < 100 Ruby objects across 1000 cache hits' do
      Dir.mktmpdir('hyperion-pc-alloc') do |dir|
        path = write_file(dir, 'small.html', 'x' * 256)
        described_class.recheck_seconds = 1_000.0 # never re-stat
        described_class.cache_file(path)

        # Reach steady state: open a socket pair we'll reuse.
        server = TCPServer.new('127.0.0.1', 0)
        client = TCPSocket.new('127.0.0.1', server.addr[1])
        sink   = server.accept
        # Drain in a thread so writes don't block on a full TCP buffer.
        # `read` returns when the client side closes (EOF), so we close
        # client first then join the drain thread.
        drain = Thread.new { sink.read }

        # Warm-up to populate per-thread caches in the C ext.
        100.times { described_class.write_to(client, path) }

        GC.start
        before = GC.stat(:total_allocated_objects)
        1000.times { described_class.write_to(client, path) }
        after = GC.stat(:total_allocated_objects)
        delta = after - before

        client.close
        drain.join
        sink.close
        server.close

        # The C path returns a SSIZET2NUM Integer per call.  Small ints
        # (≤ FIXNUM_MAX) are pointer-encoded and don't bump the
        # allocator at all; large ints would.  We're well under the
        # FIXNUM cap (a few KiB written), so the delta should be
        # ≤ a handful of objects coming from the surrounding spec
        # plumbing (test harness, not the cache path).  The plan
        # threshold is 100; we assert under 100 to give some
        # platform headroom.
        expect(delta).to be < 100
      end
    end
  end

  describe '.size and .clear' do
    it 'tracks cached count and resets on clear' do
      Dir.mktmpdir('hyperion-pc-count') do |dir|
        a = write_file(dir, 'a.html', '<a/>')
        b = write_file(dir, 'b.html', '<b/>')
        described_class.cache_file(a)
        described_class.cache_file(b)
        expect(described_class.size).to eq(2)
        described_class.clear
        expect(described_class.size).to eq(0)
        expect(described_class.fetch(a)).to eq(:missing)
      end
    end
  end

  describe '.write_response alias' do
    it 'is functionally equivalent to .write_to' do
      Dir.mktmpdir('hyperion-pc-alias') do |dir|
        path = write_file(dir, 'index.html', 'hi')
        described_class.cache_file(path)
        received = with_tcp_pair do |client|
          described_class.write_response(client, path)
        end
        expect(received).to start_with("HTTP/1.1 200 OK\r\n")
        expect(received).to end_with('hi')
      end
    end
  end

  describe 'recheck_seconds knob' do
    it 'rejects negative values' do
      expect { described_class.recheck_seconds = -1.0 }.to raise_error(ArgumentError)
    end

    it 'round-trips a positive value' do
      described_class.recheck_seconds = 12.5
      expect(described_class.recheck_seconds).to eq(12.5)
      described_class.recheck_seconds = 5.0
    end
  end
end
