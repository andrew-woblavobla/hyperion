# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'

# 2.14-B — `Hyperion::Server#stop` must return promptly (and let any
# accept-loop thread exit) regardless of whether the underlying accept
# call honours the `close()`-on-listener wake (Linux ≥ 6.x silently
# drops that guarantee — see CHANGELOG ### 2.13-C). The fix is the same
# wake-connect dance the spec suite uses: flip the C-side stop flag,
# then dial one throwaway TCP connection at the listener so any thread
# parked in `accept(2)` returns.
RSpec.describe Hyperion::Server, '#stop accept-wake (2.14-B)' do
  let(:noop_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  def free_port
    s = ::TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  def until_listening(port, timeout: 2)
    deadline = Time.now + timeout
    loop do
      ::TCPSocket.new('127.0.0.1', port).close
      return
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise 'server never listened' if Time.now > deadline

      sleep 0.02
    end
  end

  describe 'Ruby accept loop path' do
    it 'returns from stop within a bounded interval and the accept thread exits' do
      port = free_port
      server = described_class.new(app: noop_app, host: '127.0.0.1', port: port,
                                   thread_count: 0)
      server.listen

      thread = Thread.new { server.start }
      until_listening(port)

      stop_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.stop
      stop_returned = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      joined = thread.join(2)
      thread_exited = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(joined).to eq(thread), 'accept thread should exit within 2s of stop'
      expect(stop_returned - stop_started).to be < 1.5,
                                              'stop itself must return promptly'
      expect(thread_exited - stop_started).to be < 2.5,
                                              'thread exit must be bounded'
    ensure
      thread&.kill
      thread&.join(1)
    end
  end

  describe 'C accept loop path' do
    before do
      skip 'C accept loop unavailable' unless defined?(::Hyperion::Http::PageCache) &&
                                              ::Hyperion::Http::PageCache.respond_to?(:run_static_accept_loop)
    end

    after do
      # Hermetic teardown — mirror what `connection_loop_spec` does
      # so a later spec doesn't see our /hello registration, the
      # C-side stop flag, or any leftover lifecycle/handoff callback.
      pc = ::Hyperion::Http::PageCache
      pc.stop_accept_loop if pc.respond_to?(:stop_accept_loop)
      pc.set_lifecycle_active(false) if pc.respond_to?(:set_lifecycle_active)
      pc.set_lifecycle_callback(nil) if pc.respond_to?(:set_lifecycle_callback)
      pc.set_handoff_callback(nil) if pc.respond_to?(:set_handoff_callback)
      if pc.respond_to?(:clear_dynamic_blocks!)
        pc.clear_dynamic_blocks!
        pc.set_dynamic_dispatch_callback(nil)
      end
      Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
      pc.clear if pc.respond_to?(:clear)
    end

    it 'wakes the parked C accept loop and returns promptly' do
      Hyperion::Server.handle_static(:GET, '/hello', "hello\n")

      port = free_port
      server = described_class.new(app: noop_app, host: '127.0.0.1', port: port,
                                   thread_count: 0)
      server.listen

      thread = Thread.new { server.start }
      until_listening(port)

      # Serve one request so we know the C loop is engaged + parked in
      # accept(2) when we call stop.
      ::TCPSocket.open('127.0.0.1', port) do |s|
        s.write("GET /hello HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")
        s.read # drain
      end

      stop_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.stop
      stop_returned = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      joined = thread.join(2)

      expect(joined).to eq(thread),
                        'C accept loop should observe stop_accept_loop + wake-connect and exit within 2s'
      expect(stop_returned - stop_started).to be < 1.5
    ensure
      thread&.kill
      thread&.join(1)
    end
  end

  describe 'idempotency' do
    it 'is safe to call stop twice' do
      port = free_port
      server = described_class.new(app: noop_app, host: '127.0.0.1', port: port,
                                   thread_count: 0)
      server.listen
      thread = Thread.new { server.start }
      until_listening(port)

      server.stop
      thread.join(2)

      expect { server.stop }.not_to raise_error
    ensure
      thread&.kill
      thread&.join(1)
    end
  end

  describe '.wake_listener helper' do
    it 'is a no-op when listener is already closed' do
      port = free_port
      # No listener bound at `port` — wake should swallow the ECONNREFUSED.
      expect do
        Hyperion::Server::ConnectionLoop.wake_listener('127.0.0.1', port)
      end.not_to raise_error
    end

    it 'connects-and-closes against a live listener without raising' do
      listener = ::TCPServer.new('127.0.0.1', 0)
      port = listener.addr[1]
      accepted = nil
      acceptor = Thread.new do
        accepted = begin
          listener.accept
        rescue StandardError
          nil
        end
      end

      expect do
        Hyperion::Server::ConnectionLoop.wake_listener('127.0.0.1', port)
      end.not_to raise_error

      acceptor.join(1)
      expect(accepted).to be_a(::TCPSocket).or be_a(::Socket)
    ensure
      accepted&.close
      listener&.close
      acceptor&.kill
    end

    it 'bursts `count` connections against a live listener' do
      listener = ::TCPServer.new('127.0.0.1', 0)
      port = listener.addr[1]
      accepted = []
      drain_thread = Thread.new do
        loop do
          sock = begin
            listener.accept
          rescue StandardError
            break
          end
          accepted << sock
        end
      end

      Hyperion::Server::ConnectionLoop.wake_listener('127.0.0.1', port,
                                                     count: Hyperion::Server::ConnectionLoop::WAKE_CONNECT_BURST)

      # Give the acceptor a beat to drain the burst.
      sleep 0.1
      expect(accepted.size).to be >= 1
      expect(accepted.size).to be <= Hyperion::Server::ConnectionLoop::WAKE_CONNECT_BURST
    ensure
      accepted.each(&:close)
      listener&.close
      drain_thread&.kill
    end

    it 'aborts the burst early when the listener is gone (does not pay N×timeout)' do
      port = free_port
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Hyperion::Server::ConnectionLoop.wake_listener('127.0.0.1', port,
                                                     count: 32, connect_timeout: 0.5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      # A single ECONNREFUSED returns in microseconds; without the
      # short-circuit we'd pay up to 32×0.5s = 16s here.
      expect(elapsed).to be < 1.0
    end

    it 'respects the connect_timeout cap and does not block forever' do
      # 192.0.2.1 is the TEST-NET-1 address; SYNs to it black-hole on most
      # routers so a connect there exercises the timeout path. We use a
      # 0.2s cap so the assertion is robust against slow CI machines.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Hyperion::Server::ConnectionLoop.wake_listener('192.0.2.1', 9, connect_timeout: 0.2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 1.0
    end
  end
end
