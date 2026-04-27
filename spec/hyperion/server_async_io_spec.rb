# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'net/http'

# `async_io: true` config flag rewires Hyperion's plain HTTP/1.1 accept loop
# to dispatch each connection on a fiber under `Async::Scheduler` instead
# of handing the socket to a worker thread. This is what makes
# hyperion-async-pg (and other Async-aware libraries) actually cooperate.
RSpec.describe Hyperion::Server, 'async_io flag' do
  def free_port
    s = ::TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  let(:port) { free_port }
  let(:scheduler_probe) { { saw_scheduler: nil } }

  let(:probe_app) do
    probe = scheduler_probe
    lambda do |_env|
      probe[:saw_scheduler] = !Fiber.scheduler.nil?
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
  end

  def serve_one_request(server, port)
    server_thread = Thread.new { server.start }
    begin
      until_listening(port)
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
      response
    ensure
      server.stop
      server_thread.join(2)
    end
  end

  def until_listening(port, timeout: 2)
    deadline = Time.now + timeout
    loop do
      socket = ::TCPSocket.new('127.0.0.1', port)
      socket.close
      return
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise 'server never listened' if Time.now > deadline

      sleep 0.05
    end
  end

  context 'with default async_io: false (perf-bypass)' do
    it 'serves the request without a fiber scheduler current in the handler' do
      server = described_class.new(app: probe_app, host: '127.0.0.1', port: port,
                                   thread_count: 0)
      server.listen
      response = serve_one_request(server, port)
      expect(response.code).to eq('200')
      expect(response.body).to eq('ok')
      expect(scheduler_probe[:saw_scheduler]).to be(false)
    end
  end

  context 'with async_io: true' do
    it 'serves the request with Fiber.scheduler set on the handler' do
      server = described_class.new(app: probe_app, host: '127.0.0.1', port: port,
                                   thread_count: 0, async_io: true)
      server.listen
      response = serve_one_request(server, port)
      expect(response.code).to eq('200')
      expect(response.body).to eq('ok')
      expect(scheduler_probe[:saw_scheduler]).to be(true)
    end

    it 'bypasses the thread pool: handler runs on the accept-loop thread under a scheduler' do
      seen = { thread: nil, scheduler: nil }
      app = lambda do |_env|
        # With async_io: true and thread_count > 0, dispatch must still go
        # inline on the accept-loop fiber (not the pool) so Fiber.scheduler
        # is visible to the handler. Capture the thread that ran the
        # handler and compare against the accept loop's thread below.
        seen[:thread] = Thread.current
        seen[:scheduler] = Fiber.scheduler
        [200, {}, ['ok']]
      end
      server = described_class.new(app: app, host: '127.0.0.1', port: port,
                                   thread_count: 5, async_io: true)
      server.listen
      server_thread = nil
      thread_capture = ->(t) { server_thread = t }
      runner_thread = Thread.new do
        thread_capture.call(Thread.current)
        server.start
      end
      begin
        until_listening(port)
        response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
        expect(response.code).to eq('200')
        expect(seen[:thread]).to eq(server_thread)
        expect(seen[:scheduler]).not_to be_nil
      ensure
        server.stop
        runner_thread.join(2)
      end
    end
  end
end
