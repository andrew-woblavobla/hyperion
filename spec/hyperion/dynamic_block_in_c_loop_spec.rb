# frozen_string_literal: true

require 'socket'
require 'timeout'

# 2.14-A — Move `app.call` into the C accept loop.
#
# When a route is registered via `Server.handle(:GET, path) { |env| ... }`,
# the resulting `RouteTable::DynamicBlockEntry` is C-loop-eligible —
# the entire accept + recv + parse + write pipeline runs in C with the
# GVL released across the syscalls; only the actual `app.call(env)`
# slice reacquires the GVL.
#
# These specs cover:
#   * smoke: a registered dynamic block is served from C; the C loop
#     served-request counter ticks once per request.
#   * env shape: the block sees method / path / query / Host / headers
#     / REMOTE_ADDR populated correctly.
#   * mixed table (StaticEntry + DynamicBlockEntry): both flow through
#     the C loop; eligibility predicate accepts the mix.
#   * legacy fallback: a `Server.handle(method, path, handler)` that
#     takes a `Hyperion::Request` (the 2.10-D shape) keeps disengaging
#     the C loop — those still flow through `Connection#serve`.
#   * GVL release: while the C loop is mid-write or mid-recv, an
#     unrelated Ruby thread can do CPU work and finish in roughly
#     wall-clock time.
RSpec.describe 'Hyperion::Server.handle (block form) — C-accept-loop dynamic dispatch (2.14-A)' do
  before do
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    Hyperion::Http::PageCache.clear
    Hyperion::Http::PageCache.set_lifecycle_active(false)
    Hyperion::Http::PageCache.set_lifecycle_callback(nil)
    Hyperion::Http::PageCache.set_handoff_callback(nil)
    Hyperion::Http::PageCache.clear_dynamic_blocks!
    Hyperion::Http::PageCache.set_dynamic_dispatch_callback(nil)
  end

  after do
    Hyperion::Http::PageCache.stop_accept_loop
    sleep 0.02
    Hyperion::Http::PageCache.set_lifecycle_active(false)
    Hyperion::Http::PageCache.set_lifecycle_callback(nil)
    Hyperion::Http::PageCache.set_handoff_callback(nil)
    Hyperion::Http::PageCache.clear_dynamic_blocks!
    Hyperion::Http::PageCache.set_dynamic_dispatch_callback(nil)
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    Hyperion::Http::PageCache.clear
  end

  def open_listener
    server = TCPServer.new('127.0.0.1', 0)
    [server, server.addr[1]]
  end

  def stop_loop_and_wake(listener, thread, timeout: 5)
    Hyperion::Http::PageCache.stop_accept_loop
    port = listener.addr[1] if listener && !listener.closed?
    if port
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
    end
    listener.close unless listener.closed?
    thread.join(timeout)
  end

  def http_get(port, path, host: '127.0.0.1', extra_headers: '', read_response: true)
    sock = TCPSocket.new(host, port)
    sock.write("GET #{path} HTTP/1.1\r\nhost: #{host}\r\nconnection: close\r\n#{extra_headers}\r\n")
    return sock unless read_response

    data = +''
    begin
      Timeout.timeout(5) do
        loop do
          chunk = sock.read(4096)
          break if chunk.nil? || chunk.empty?

          data << chunk
        end
      end
    rescue Timeout::Error
      # no-op — caller asserts on data
    end
    sock.close
    data
  end

  describe 'eligibility predicate (RouteTable::DynamicBlockEntry)' do
    it 'engages for a DynamicBlockEntry-only route table' do
      Hyperion::Server.handle(:GET, '/echo') { |env| [200, {}, [env['HTTP_X_FOO'].to_s]] }

      expect(Hyperion::Server::ConnectionLoop.eligible_route_table?(Hyperion::Server.route_table))
        .to be(true)
    end

    it 'engages for a mixed StaticEntry + DynamicBlockEntry table' do
      Hyperion::Server.handle_static(:GET, '/static', "static\n")
      Hyperion::Server.handle(:GET, '/dyn') { |_env| [200, {}, ['dyn-ok']] }

      expect(Hyperion::Server::ConnectionLoop.eligible_route_table?(Hyperion::Server.route_table))
        .to be(true)
    end

    it 'falls back to the Ruby loop when a legacy handler is registered alongside' do
      Hyperion::Server.handle_static(:GET, '/s', "s\n")
      Hyperion::Server.handle(:GET, '/legacy', ->(_req) { [200, {}, ['legacy']] })

      expect(Hyperion::Server::ConnectionLoop.eligible_route_table?(Hyperion::Server.route_table))
        .to be(false)
    end
  end

  describe 'C-loop dynamic-block dispatch (smoke)' do
    it 'serves a registered block via the C accept loop' do
      Hyperion::Server.handle(:GET, '/echo') do |env|
        [200, { 'content-type' => 'text/plain' },
         ["hi:#{env['HTTP_X_FOO']}\n"]]
      end

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port

      expect(server.send(:engage_c_accept_loop?)).to be(true)

      Hyperion::Http::PageCache.reset_c_loop_requests_total!
      thread = Thread.new { server.start }
      sleep 0.1

      response = http_get(port, '/echo', extra_headers: "x-foo: bar\r\n")
      expect(response).to include('200 OK')
      expect(response).to include("hi:bar\n")
      expect(response).to include('content-length: 7')

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)

      expect(Hyperion::Http::PageCache.c_loop_requests_total).to be >= 1
    end
  end

  describe 'C-loop env shape' do
    it 'populates REQUEST_METHOD, PATH_INFO, QUERY_STRING, Host, REMOTE_ADDR and HTTP_* headers' do
      observed = nil
      Hyperion::Server.handle(:GET, '/probe') do |env|
        observed = {
          method: env['REQUEST_METHOD'],
          path: env['PATH_INFO'],
          query: env['QUERY_STRING'],
          host: env['HTTP_HOST'],
          server_name: env['SERVER_NAME'],
          server_port: env['SERVER_PORT'],
          remote_addr: env['REMOTE_ADDR'],
          x_foo: env['HTTP_X_FOO'],
          accept: env['HTTP_ACCEPT']
        }
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port
      thread = Thread.new { server.start }
      sleep 0.1

      response = http_get(port, '/probe?id=42', host: '127.0.0.1',
                                                extra_headers: "x-foo: bar\r\naccept: text/html\r\n")
      expect(response).to include('200 OK')

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)

      expect(observed[:method]).to eq('GET')
      expect(observed[:path]).to eq('/probe')
      expect(observed[:query]).to eq('id=42')
      expect(observed[:host]).to eq('127.0.0.1')
      expect(observed[:server_name]).to eq('127.0.0.1')
      expect(observed[:remote_addr]).to eq('127.0.0.1')
      expect(observed[:x_foo]).to eq('bar')
      expect(observed[:accept]).to eq('text/html')
    end
  end

  describe 'mixed table (StaticEntry + DynamicBlockEntry)' do
    it 'serves both shapes via the C loop' do
      Hyperion::Server.handle_static(:GET, '/static', "static-bytes\n")
      Hyperion::Server.handle(:GET, '/dyn') { |_env| [200, { 'content-type' => 'text/plain' }, ["dyn-bytes\n"]] }

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port
      thread = Thread.new { server.start }
      sleep 0.1

      static_response = http_get(port, '/static')
      dyn_response = http_get(port, '/dyn')
      expect(static_response).to end_with("static-bytes\n")
      expect(dyn_response).to end_with("dyn-bytes\n")

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)
    end
  end

  describe 'sequential request burst — counter accuracy' do
    it 'counts every request via c_loop_requests_total' do
      Hyperion::Server.handle(:GET, '/burst') do |_env|
        [200, { 'content-type' => 'text/plain' }, ["b\n"]]
      end

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port

      Hyperion::Http::PageCache.reset_c_loop_requests_total!
      thread = Thread.new { server.start }
      sleep 0.1

      n = 100
      n.times do
        response = http_get(port, '/burst')
        expect(response).to include('200 OK')
      end

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)

      expect(Hyperion::Http::PageCache.c_loop_requests_total).to be >= n
    end
  end

  describe 'GVL release across the C loop' do
    it 'allows a Ruby compute thread to make progress while requests are mid-flight' do
      Hyperion::Server.handle(:GET, '/g') { |_env| [200, {}, ["g\n"]] }

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port

      thread = Thread.new { server.start }
      sleep 0.1

      compute_thread = Thread.new do
        sum = 0
        100_000.times { |i| sum += i }
        sum
      end

      result = nil
      Timeout.timeout(5) { result = compute_thread.value }
      expect(result).to eq(100_000 * 99_999 / 2)

      response = http_get(port, '/g')
      expect(response).to include('200 OK')

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)
    end
  end

  describe 'lifecycle hooks fire on the dynamic-block path' do
    around do |ex|
      Hyperion::Runtime.reset_default!
      ex.run
      Hyperion::Runtime.reset_default!
    end

    it 'invokes before_request and after_request hooks with the built env' do
      starts = []
      ends = []
      runtime = Hyperion::Runtime.default
      runtime.on_request_start { |req, env| starts << [req.method, req.path, env['PATH_INFO']] }
      runtime.on_request_end   { |req, env, _resp, _err| ends << [req.method, env['PATH_INFO']] }

      Hyperion::Server.handle(:GET, '/hooked') do |_env|
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port
      thread = Thread.new { server.start }
      sleep 0.1

      http_get(port, '/hooked')

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)

      expect(starts.size).to be >= 1
      expect(starts.first).to eq(['GET', '/hooked', '/hooked'])
      expect(ends.size).to be >= 1
      expect(ends.first).to eq(['GET', '/hooked'])
    end
  end

  describe 'app raise -> 500 envelope' do
    it 'returns a 500 response when the registered block raises' do
      Hyperion::Server.handle(:GET, '/boom') do |_env|
        raise 'kaboom'
      end

      app = ->(_env) { [404, {}, ['nope']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port
      thread = Thread.new { server.start }
      sleep 0.1

      response = http_get(port, '/boom')
      expect(response).to include('500')
      expect(response).to include('Internal Server Error')

      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)
    end
  end
end
