# frozen_string_literal: true

require 'socket'
require 'spec_helper'

# 2.17-A (Hot Path Task 2) — `Hyperion::Server.handle_static` builds the
# COMPLETE HTTP/1.1 wire response (status line + Server + Content-Type +
# Content-Length + Connection: keep-alive + 29-byte Date placeholder +
# CRLF + body) ONCE at registration time and stashes the frozen bytes on
# the `RouteTable::StaticEntry`.  The C-loop writer mem-splices the
# per-second-cached imf-fixdate into a per-write scratch copy at
# `prebuilt_date_offset` before issuing a single write/sendmsg.
#
# These specs lock in the wire layout and the round-trip behaviour:
#
#   * StaticEntry exposes `prebuilt_keepalive_bytes` (frozen, includes
#     the 29-X placeholder at the documented offset) and
#     `prebuilt_date_offset` (Integer index of the placeholder).
#   * The wire bytes contain capital-cased headers (RFC 7230 §3.2 form),
#     Connection: keep-alive, Content-Length matching the body, and a
#     bare `Date: XXXXXXX...` slot at the offset.
#   * A real HTTP/1.1 keep-alive request through a booted Server hits
#     the C splice path and lands a properly-formatted Date header on
#     the wire (matches the imf-fixdate regex from RFC 7231 §7.1.1.1).
#   * The frozen Ruby String is NEVER mutated — the placeholder bytes
#     in `entry.prebuilt_keepalive_bytes` stay 'X' across multiple
#     requests; only the on-the-wire bytes carry the spliced date.
RSpec.describe 'Hyperion::Server.handle_static prebuilt wire bytes' do
  let(:fallback_app) do
    ->(env) { [404, { 'content-type' => 'text/plain' }, ["miss #{env['PATH_INFO']}"]] }
  end

  before do
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
  end

  after do
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
  end

  describe 'StaticEntry shape' do
    it 'exposes frozen prebuilt_keepalive_bytes with a 29-byte Date placeholder' do
      entry = Hyperion::Server.handle_static(:GET, '/x', 'hello',
                                              content_type: 'text/plain')

      expect(entry).to be_a(Hyperion::Server::RouteTable::StaticEntry)
      bytes = entry.prebuilt_keepalive_bytes
      expect(bytes).to be_a(String)
      expect(bytes).to be_frozen
      expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'lays out the head with capital-cased headers + Date placeholder + body' do
      body = 'hello'
      entry = Hyperion::Server.handle_static(:GET, '/x', body,
                                              content_type: 'text/plain')
      bytes = entry.prebuilt_keepalive_bytes

      expect(bytes).to start_with("HTTP/1.1 200 OK\r\n")
      expect(bytes).to include("Server: Hyperion\r\n")
      expect(bytes).to include("Content-Type: text/plain\r\n")
      expect(bytes).to include("Content-Length: #{body.bytesize}\r\n")
      expect(bytes).to include("Connection: keep-alive\r\n")
      expect(bytes).to include("Date: #{'X' * 29}\r\n\r\n")
      expect(bytes).to end_with("\r\nhello")
    end

    it 'records the Date placeholder offset on the entry' do
      entry = Hyperion::Server.handle_static(:GET, '/x', 'hi')
      offset = entry.prebuilt_date_offset

      expect(offset).to be_a(Integer)
      expect(offset).to be > 0
      placeholder = entry.prebuilt_keepalive_bytes.byteslice(offset, 29)
      expect(placeholder).to eq('X' * 29)
    end

    it 'honours a custom content_type in the prebuilt bytes' do
      entry = Hyperion::Server.handle_static(:GET, '/json', '{}',
                                              content_type: 'application/json')

      expect(entry.prebuilt_keepalive_bytes).to include("Content-Type: application/json\r\n")
      expect(entry.prebuilt_keepalive_bytes).to include("Content-Length: 2\r\n")
    end

    it 'preserves the legacy buffer (lowercase headers, no Date) for the Ruby fallback path' do
      # The pre-2.17 `entry.buffer` is still served by the Ruby
      # fallback when the C ext isn't available; it stays lowercase /
      # Date-less for byte-identical compatibility with operators that
      # depended on that exact layout.
      entry = Hyperion::Server.handle_static(:GET, '/legacy', 'OK')

      expect(entry.buffer).to include('content-type: text/plain')
      expect(entry.buffer).to include('content-length: 2')
      expect(entry.buffer).not_to include('Date:')
    end
  end

  describe 'end-to-end via a real keep-alive request' do
    def boot_server(app)
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      [server, server.port]
    end

    def keepalive_request(port, method, path)
      sock = TCPSocket.new('127.0.0.1', port)
      sock.write("#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
      data = +''
      # Read until we see a complete head + the Content-Length-worth of
      # body. The connection stays open (keep-alive) — drain via a
      # bounded loop with a small timeout so the test doesn't block
      # indefinitely when the response is shorter than expected.
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      until data.include?("\r\n\r\n") &&
            (cl = data[/Content-Length: (\d+)/i, 1]) &&
            data.bytesize >= data.index("\r\n\r\n") + 4 + cl.to_i
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start > 2.0

        readable, = IO.select([sock], nil, nil, 0.5)
        break unless readable

        chunk = begin
          sock.read_nonblock(4096)
        rescue IO::WaitReadable
          nil
        end
        break if chunk.nil? || chunk.empty?

        data << chunk
      end
      sock.close
      data
    end

    it 'splices a valid imf-fixdate Date header into the response wire bytes' do
      Hyperion::Server.handle_static(:GET, '/hi', "hello world\n")

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = keepalive_request(port, 'GET', '/hi')

      expect(response).to start_with("HTTP/1.1 200 OK\r\n")
      expect(response).to include("Server: Hyperion\r\n")
      expect(response).to include("Content-Type: text/plain\r\n")
      expect(response).to include("Content-Length: 12\r\n")
      expect(response).to include("Connection: keep-alive\r\n")
      # imf-fixdate per RFC 7231 §7.1.1.1: "Sun, 06 Nov 1994 08:49:37 GMT"
      expect(response).to match(
        /\r\nDate: (Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} GMT\r\n/
      )
      expect(response).to_not include('XXX')
      expect(response).to end_with("hello world\n")
    ensure
      server&.stop
    end

    it 'leaves the registered frozen Ruby String unmutated (placeholder still all Xs)' do
      entry = Hyperion::Server.handle_static(:GET, '/imm', 'OK')
      pre = entry.prebuilt_keepalive_bytes.byteslice(entry.prebuilt_date_offset, 29)
      expect(pre).to eq('X' * 29)

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      keepalive_request(port, 'GET', '/imm')

      post = entry.prebuilt_keepalive_bytes.byteslice(entry.prebuilt_date_offset, 29)
      expect(post).to eq('X' * 29)
      expect(entry.prebuilt_keepalive_bytes).to be_frozen
    ensure
      server&.stop
    end
  end
end
