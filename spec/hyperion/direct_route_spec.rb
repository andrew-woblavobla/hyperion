# frozen_string_literal: true

require 'net/http'
require 'socket'

# 2.10-D — direct-route registration API (Hyperion::Server.handle).
#
# The fast path bypasses the Rack adapter on hit: routes registered
# via `Hyperion::Server.handle(:GET, '/path', handler)` skip env-hash
# construction, the middleware chain, and body iteration; on miss
# the request falls through to the regular Rack adapter dispatch.
# `handle_static(:GET, '/path', body)` builds the full HTTP/1.1
# response buffer at registration time and serves it via a single
# socket.write on hit.
#
# These specs assert:
#   * register / lookup / dispatch happy path
#   * non-matched paths fall through to the Rack adapter unchanged
#   * lifecycle hooks (Runtime#on_request_start / on_request_end)
#     fire on direct routes
#   * handle_static builds the buffer once and writes it byte-exact
#   * method case-insensitive matching (:get vs :GET)
#   * concurrent registration during request handling is safe
RSpec.describe 'Hyperion::Server.handle (direct route registration)' do
  let(:fallback_app) do
    ->(env) { [200, { 'content-type' => 'text/plain' }, ["fallback #{env['PATH_INFO']}"]] }
  end

  before do
    # Each example starts with an empty route table so registrations
    # don't leak across examples.
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
  end

  after do
    # Restore the process-wide singleton so the rest of the suite
    # (which doesn't touch direct routes) sees a known-empty table.
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
  end

  describe Hyperion::Server::RouteTable do
    let(:table) { described_class.new }

    it 'starts empty' do
      expect(table.size).to eq(0)
    end

    it 'registers and looks up an exact-match route' do
      handler = ->(_req) { [200, {}, ['hi']] }
      table.register(:GET, '/hello', handler)
      expect(table.lookup('GET', '/hello')).to be(handler)
      expect(table.size).to eq(1)
    end

    it 'returns nil on miss for an unregistered path' do
      table.register(:GET, '/hello', ->(_req) { [200, {}, ['hi']] })
      expect(table.lookup('GET', '/missing')).to be_nil
    end

    it 'returns nil on miss for a different method on a registered path' do
      table.register(:GET, '/hello', ->(_req) { [200, {}, ['hi']] })
      expect(table.lookup('POST', '/hello')).to be_nil
    end

    it 'normalizes the registration method (lowercase symbol works)' do
      handler = ->(_req) { [200, {}, ['hi']] }
      table.register(:get, '/hello', handler)
      expect(table.lookup('GET', '/hello')).to be(handler)
    end

    it 'rejects unknown HTTP methods at registration time' do
      expect do
        table.register(:FROBNICATE, '/hello', ->(_req) { [200, {}, ['hi']] })
      end.to raise_error(ArgumentError, /unknown method/)
    end

    it 'rejects non-String paths' do
      expect do
        table.register(:GET, :hello, ->(_req) { [200, {}, ['hi']] })
      end.to raise_error(ArgumentError, /path must be a String/)
    end

    it 'rejects handlers that do not respond to #call' do
      expect do
        table.register(:GET, '/hello', Object.new)
      end.to raise_error(ArgumentError, /respond to #call/)
    end

    it 'last writer wins on the same (method, path)' do
      first  = ->(_req) { [200, {}, ['first']] }
      second = ->(_req) { [200, {}, ['second']] }
      table.register(:GET, '/hello', first)
      table.register(:GET, '/hello', second)
      expect(table.lookup('GET', '/hello')).to be(second)
    end

    it 'tolerates concurrent registrations from multiple threads' do
      threads = 8.times.map do |i|
        Thread.new do
          100.times { |j| table.register(:GET, "/r/#{i}/#{j}", ->(_r) { [200, {}, ['x']] }) }
        end
      end
      threads.each(&:join)
      expect(table.size).to eq(800)
    end

    it 'clear removes every registered route' do
      table.register(:GET, '/a', ->(_r) { [200, {}, ['a']] })
      table.register(:POST, '/b', ->(_r) { [200, {}, ['b']] })
      table.clear
      expect(table.size).to eq(0)
    end
  end

  describe Hyperion::Server::RouteTable::StaticEntry do
    it 'wraps a frozen response buffer' do
      buf = "HTTP/1.1 200 OK\r\n\r\nhi".b.freeze
      entry = described_class.new(:GET, '/x', buf)
      expect(entry.response_bytes).to be(buf)
    end
  end

  describe '.handle' do
    it 'registers a handler on the process-wide route table' do
      handler = ->(_req) { [200, {}, ['hi']] }
      Hyperion::Server.handle(:GET, '/x', handler)
      expect(Hyperion::Server.route_table.lookup('GET', '/x')).to be(handler)
    end
  end

  describe '.handle_static' do
    it 'builds the response buffer at registration time' do
      entry = Hyperion::Server.handle_static(:GET, '/health', 'OK')
      expect(entry).to be_a(Hyperion::Server::RouteTable::StaticEntry)
      expect(entry.response_bytes).to include('HTTP/1.1 200 OK')
      expect(entry.response_bytes).to include('content-type: text/plain')
      expect(entry.response_bytes).to include('content-length: 2')
      expect(entry.response_bytes).to end_with("\r\n\r\nOK")
      expect(entry.response_bytes).to be_frozen
    end

    it 'honours a custom content type' do
      entry = Hyperion::Server.handle_static(:GET, '/h.json', '{}', content_type: 'application/json')
      expect(entry.response_bytes).to include('content-type: application/json')
      expect(entry.response_bytes).to include('content-length: 2')
    end

    it 'rejects non-String body bytes' do
      expect do
        Hyperion::Server.handle_static(:GET, '/x', :not_a_string)
      end.to raise_error(ArgumentError, /body_bytes/)
    end
  end

  describe 'end-to-end dispatch via a real TCP socket' do
    let(:port) { 0 } # ephemeral

    around do |ex|
      Hyperion::Runtime.reset_default!
      ex.run
      Hyperion::Runtime.reset_default!
    end

    def boot_server(app)
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      [server, server.port]
    end

    def request(port, method, path)
      sock = TCPSocket.new('127.0.0.1', port)
      sock.write("#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")
      data = +''
      data << sock.read until sock.eof?
      sock.close
      data
    rescue StandardError
      data
    end

    it 'serves a direct-dispatch handler bypassing the Rack adapter' do
      handler_calls = 0
      Hyperion::Server.handle(:GET, '/direct', lambda do |req|
        handler_calls += 1
        # Confirm the handler receives a Hyperion::Request, not a Rack env Hash.
        expect(req).to be_a(Hyperion::Request)
        expect(req.method).to eq('GET')
        expect(req.path).to eq('/direct')
        [200, { 'content-type' => 'text/plain' }, ["direct hit\n"]]
      end)

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = request(port, 'GET', '/direct')

      expect(handler_calls).to eq(1)
      expect(response).to include('200 OK')
      expect(response).to end_with("direct hit\n")
    ensure
      server&.stop
    end

    it 'falls through to the Rack adapter when no direct route matches' do
      Hyperion::Server.handle(:GET, '/direct', ->(_r) { [200, {}, ['unused']] })

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = request(port, 'GET', '/something/else')

      expect(response).to include('200 OK')
      expect(response).to end_with('fallback /something/else')
    ensure
      server&.stop
    end

    it 'serves handle_static via a single pre-built buffer' do
      Hyperion::Server.handle_static(:GET, '/hello', "hello world\n")

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = request(port, 'GET', '/hello')

      # 2.17-A — the C-loop writer serves the keep-alive prebuilt bytes
      # (capital-cased headers + Server + Connection + Date placeholder
      # spliced with the per-second-cached imf-fixdate).
      expect(response).to include('HTTP/1.1 200 OK')
      expect(response).to include('Content-Type: text/plain')
      expect(response).to include('Content-Length: 12')
      expect(response).to match(/Date: \w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT\r\n/)
      expect(response).to end_with("hello world\n")
    ensure
      server&.stop
    end

    it 'matches case-insensitively when registered with a lowercase symbol' do
      Hyperion::Server.handle(:get, '/lower', ->(_r) { [200, {}, ['lower-ok']] })

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = request(port, 'GET', '/lower')

      expect(response).to end_with('lower-ok')
    ensure
      server&.stop
    end

    it 'serves handle_static via the C-ext fast path (2.10-F)' do
      Hyperion::Server.handle_static(:GET, '/c-fast', "fast\n")

      # The handle_static registration MUST also register the prebuilt
      # response with the C-side PageCache so PageCache.serve_request
      # finds it.  This is the contract that 2.10-F's fast path
      # depends on; assert it directly so a regression in
      # Server.handle_static is caught at unit-spec time, not at the
      # next bench run.
      tcp_server = TCPServer.new('127.0.0.1', 0)
      pair_port  = tcp_server.addr[1]
      reader = Thread.new { tcp_server.accept.read }
      client = TCPSocket.new('127.0.0.1', pair_port)
      result = Hyperion::Http::PageCache.serve_request(client, 'GET', '/c-fast')
      client.close
      reader.value
      tcp_server.close
      expect(result).to be_a(Array)
      expect(result.first).to eq(:ok)

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = request(port, 'GET', '/c-fast')
      expect(response).to include('200 OK')
      expect(response).to end_with("fast\n")
    ensure
      server&.stop
    end

    it 'serves HEAD on a handle_static route with headers-only body' do
      body = "this is the body\n"
      Hyperion::Server.handle_static(:GET, '/head-route', body)

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      response = request(port, 'HEAD', '/head-route')

      # Headers must come through; the body bytes MUST NOT be on the
      # wire (HEAD strips the body).
      # 2.17-A — capital-cased headers from the keep-alive prebuilt bytes.
      expect(response).to include('HTTP/1.1 200 OK')
      expect(response).to include('Content-Type: text/plain')
      expect(response).to include("Content-Length: #{body.bytesize}")
      expect(response).not_to include('this is the body')
    ensure
      server&.stop
    end

    it 'fires Runtime lifecycle hooks on direct-dispatch routes' do
      starts = []
      ends   = []
      Hyperion::Runtime.default.on_request_start { |req, env| starts << [req.path, env] }
      Hyperion::Runtime.default.on_request_end   { |req, env, resp, err| ends << [req.path, env, resp&.first, err] }

      Hyperion::Server.handle_static(:GET, '/hooked', 'OK')

      server, port = boot_server(fallback_app)
      Thread.new { server.run_one }
      request(port, 'GET', '/hooked')

      expect(starts.size).to eq(1)
      expect(starts.first.first).to eq('/hooked')
      # env is nil on the direct path (no Rack env was built) — this
      # is the documented contract for observers that need to
      # distinguish the two dispatch shapes.
      expect(starts.first.last).to be_nil

      expect(ends.size).to eq(1)
      expect(ends.first.first).to eq('/hooked')
      # The response tuple isn't propagated back from the
      # StaticEntry write (we never reconstructed it), but the
      # status from the buffer is the documented '200' for static
      # entries — the lifecycle hook still fires so observers can
      # finish spans.
      expect(ends.first[3]).to be_nil # no error
    ensure
      server&.stop
    end
  end
end
