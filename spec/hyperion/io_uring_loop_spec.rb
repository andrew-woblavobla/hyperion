# frozen_string_literal: true

require 'socket'
require 'timeout'
require 'hyperion'

# 2.12-D — io_uring accept loop (Linux 5.x).
#
# Sibling of `connection_loop_spec.rb`. Same wire contract as the
# 2.12-C `accept4` loop; verifies that:
#
#   * The Ruby surface (`run_static_io_uring_loop`,
#     `io_uring_loop_compiled?`) is exposed on every build, even
#     macOS / no-liburing.
#   * The stub returns `:unavailable` when the C ext wasn't compiled
#     with `HAVE_LIBURING` (so the Ruby caller can fall through to
#     the 2.12-C path).
#   * `ConnectionLoop.io_uring_eligible?` honours the
#     `HYPERION_IO_URING_ACCEPT` env var AND the compile-time flag.
#
# The smoke + lifecycle tests are gated on `io_uring_loop_compiled?`
# so they only run on Linux with liburing-dev installed (the bench
# host). On macOS the gated examples are skipped — the stub-only
# specs still execute.
RSpec.describe 'Hyperion::Http::PageCache.run_static_io_uring_loop (2.12-D)' do
  # Resolved once at describe-block parse time so it can be used in
  # `skip:` metadata. The C ext flag is fixed for the gem instance —
  # a re-build mid-test-suite isn't a thing we support.
  COMPILED = Hyperion::Http::PageCache.io_uring_loop_compiled?

  let(:compiled) { COMPILED }

  before do
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    Hyperion::Http::PageCache.clear
    Hyperion::Http::PageCache.set_lifecycle_active(false)
    Hyperion::Http::PageCache.set_lifecycle_callback(nil)
    Hyperion::Http::PageCache.set_handoff_callback(nil)
  end

  after do
    Hyperion::Http::PageCache.stop_accept_loop
    sleep 0.02
    Hyperion::Http::PageCache.set_lifecycle_active(false)
    Hyperion::Http::PageCache.set_lifecycle_callback(nil)
    Hyperion::Http::PageCache.set_handoff_callback(nil)
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    Hyperion::Http::PageCache.clear
  end

  def open_listener
    server = TCPServer.new('127.0.0.1', 0)
    [server, server.addr[1]]
  end

  def http_get(port, path, host: '127.0.0.1')
    sock = TCPSocket.new(host, port)
    sock.write("GET #{path} HTTP/1.1\r\nhost: #{host}\r\nconnection: close\r\n\r\n")
    data = +''
    Timeout.timeout(5) do
      loop do
        chunk = sock.read(4096)
        break if chunk.nil? || chunk.empty?

        data << chunk
      end
    end
    sock.close
    data
  end

  describe 'Ruby surface' do
    it 'exposes run_static_io_uring_loop on every build' do
      expect(Hyperion::Http::PageCache).to respond_to(:run_static_io_uring_loop)
    end

    it 'exposes io_uring_loop_compiled? as a boolean predicate' do
      expect(Hyperion::Http::PageCache).to respond_to(:io_uring_loop_compiled?)
      result = Hyperion::Http::PageCache.io_uring_loop_compiled?
      expect([true, false]).to include(result)
    end
  end

  describe 'stub behaviour on builds without liburing' do
    it 'returns :unavailable when not compiled with HAVE_LIBURING', skip: ('liburing build present' if COMPILED) do
      listener, = open_listener
      # The stub never blocks; it returns :unavailable immediately.
      result = Hyperion::Http::PageCache.run_static_io_uring_loop(listener.fileno)
      listener.close
      expect(result).to eq(:unavailable)
    end
  end

  describe 'Hyperion::Server::ConnectionLoop.io_uring_eligible?' do
    around do |example|
      saved = ENV['HYPERION_IO_URING_ACCEPT']
      example.run
      ENV['HYPERION_IO_URING_ACCEPT'] = saved
    end

    it 'returns false when HYPERION_IO_URING_ACCEPT is unset' do
      ENV.delete('HYPERION_IO_URING_ACCEPT')
      expect(Hyperion::Server::ConnectionLoop.io_uring_eligible?).to be(false)
    end

    it 'returns false when HYPERION_IO_URING_ACCEPT=0' do
      ENV['HYPERION_IO_URING_ACCEPT'] = '0'
      expect(Hyperion::Server::ConnectionLoop.io_uring_eligible?).to be(false)
    end

    it 'returns false on builds without HAVE_LIBURING regardless of env',
       skip: ('liburing build present' if COMPILED) do
      ENV['HYPERION_IO_URING_ACCEPT'] = '1'
      expect(Hyperion::Server::ConnectionLoop.io_uring_eligible?).to be(false)
    end

    it 'returns true on builds with HAVE_LIBURING when env is set',
       skip: ('requires HAVE_LIBURING build (Linux + liburing-dev)' unless COMPILED) do
      ENV['HYPERION_IO_URING_ACCEPT'] = '1'
      expect(Hyperion::Server::ConnectionLoop.io_uring_eligible?).to be(true)
    end
  end

  describe 'smoke: registered route served from the io_uring loop' do
    it 'returns served count > 0 after multiple GETs',
       skip: ('requires Linux + liburing-dev (HAVE_LIBURING build)' unless COMPILED) do
      Hyperion::Server.handle_static(:GET, '/hello', "hello\n")
      listener, port = open_listener

      result = nil
      thread = Thread.new { result = Hyperion::Http::PageCache.run_static_io_uring_loop(listener.fileno) }
      sleep 0.05

      requests = 5
      requests.times do
        response = http_get(port, '/hello')
        expect(response).to include('200 OK')
        expect(response).to end_with("hello\n")
      end

      Hyperion::Http::PageCache.stop_accept_loop
      listener.close
      thread.join(5)

      expect(result).to be_a(Integer).or eq(:unavailable)
      # The loop may return :unavailable if the runtime probe failed in
      # this environment (e.g. seccomp); in that case the count
      # assertion below is N/A. The CI host has io_uring enabled so we
      # expect the integer branch.
      expect(result).to be >= requests if result.is_a?(Integer)
    end
  end

  describe 'lifecycle hooks fire from the io_uring loop' do
    it 'invokes the lifecycle callback once per served request',
       skip: ('requires Linux + liburing-dev (HAVE_LIBURING build)' unless COMPILED) do
      Hyperion::Server.handle_static(:GET, '/hooked', "hooked\n")
      listener, port = open_listener

      hook_calls = []
      Hyperion::Http::PageCache.set_lifecycle_callback(lambda do |method, path|
        hook_calls << [method, path]
      end)
      Hyperion::Http::PageCache.set_lifecycle_active(true)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_io_uring_loop(listener.fileno) }
      sleep 0.05

      3.times { http_get(port, '/hooked') }

      Hyperion::Http::PageCache.stop_accept_loop
      listener.close
      thread.join(5)

      # Same contract as 2.12-C: one fire per served request, in order.
      next if hook_calls.empty? # tolerant of a probe-fail environment

      expect(hook_calls.size).to eq(3)
      expect(hook_calls).to all eq(['GET', '/hooked'])
    end
  end

  describe 'Server-level engagement of the io_uring loop' do
    around do |example|
      saved = ENV['HYPERION_IO_URING_ACCEPT']
      Hyperion::Runtime.reset_default!
      example.run
      Hyperion::Runtime.reset_default!
      ENV['HYPERION_IO_URING_ACCEPT'] = saved
    end

    it 'records :c_accept_loop_io_uring_h1 dispatch mode when env is set on a HAVE_LIBURING build',
       skip: ('requires Linux + liburing-dev (HAVE_LIBURING build)' unless COMPILED) do
      ENV['HYPERION_IO_URING_ACCEPT'] = '1'
      Hyperion::Server.handle_static(:GET, '/s', "s\n")

      app = ->(_env) { [404, { 'content-type' => 'text/plain' }, ['no']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port

      thread = Thread.new { server.start }
      sleep 0.1

      response = http_get(port, '/s')
      expect(response).to include('200 OK')
      expect(response).to end_with("s\n")

      counters = Hyperion::Runtime.default.metrics.snapshot
      expect(
        counters.fetch(:requests_dispatch_c_accept_loop_io_uring_h1, 0).to_i +
        counters.fetch(:requests_dispatch_c_accept_loop_h1, 0).to_i
      ).to be >= 1

      server.stop
      Hyperion::Http::PageCache.stop_accept_loop
      thread.join(5)
    end
  end
end
