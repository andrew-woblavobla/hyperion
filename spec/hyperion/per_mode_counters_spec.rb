# frozen_string_literal: true

require 'net/http'
require 'socket'

RSpec.describe 'per-mode dispatch counters with dual-emit (RFC A2 / §3 1.7.0)' do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  before do
    @prev_metrics = Hyperion.instance_variable_get(:@metrics)
    Hyperion.instance_variable_set(:@metrics, Hyperion::Metrics.new)
  end

  after { Hyperion.instance_variable_set(:@metrics, @prev_metrics) }

  it 'increments BOTH the new :requests_dispatch_threadpool_h1 and legacy :requests_threadpool_dispatched on plain HTTP' do
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app)
    server.listen
    serve_thread = Thread.new { server.start }

    # Wait for accept
    deadline = Time.now + 2
    loop do
      s = TCPSocket.new('127.0.0.1', server.port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server did not bind' if Time.now > deadline

      sleep 0.01
    end

    Net::HTTP.get(URI("http://127.0.0.1:#{server.port}/"))
    Net::HTTP.get(URI("http://127.0.0.1:#{server.port}/"))
    sleep 0.05 # let metrics settle

    stats = Hyperion.stats
    expect(stats[:requests_dispatch_threadpool_h1]).to be >= 1
    expect(stats[:requests_threadpool_dispatched]).to be >= 1
    # Both keys reflect the same dispatches.
    expect(stats[:requests_dispatch_threadpool_h1]).to eq(stats[:requests_threadpool_dispatched])
  ensure
    server&.stop
    serve_thread&.join(2)
  end

  describe 'Server#record_dispatch (unit)' do
    let(:server) { Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app) }

    it 'dual-emits threadpool_h1 → both keys' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:threadpool_h1))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_threadpool_h1]).to eq(1)
      expect(stats[:requests_threadpool_dispatched]).to eq(1)
    end

    it 'dual-emits inline_h1_no_pool under the legacy threadpool key' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:inline_h1_no_pool))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_inline_h1_no_pool]).to eq(1)
      expect(stats[:requests_threadpool_dispatched]).to eq(1)
    end

    it 'dual-emits tls_h1_inline → both keys' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:tls_h1_inline))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_tls_h1_inline]).to eq(1)
      expect(stats[:requests_async_dispatched]).to eq(1)
    end

    it 'dual-emits async_io_h1_inline under the legacy async key' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:async_io_h1_inline))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_async_io_h1_inline]).to eq(1)
      expect(stats[:requests_async_dispatched]).to eq(1)
    end

    it 'tls_h2 emits ONLY the new key (not the legacy buckets)' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:tls_h2))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_tls_h2]).to eq(1)
      expect(stats[:requests_async_dispatched]).to be_nil
      expect(stats[:requests_threadpool_dispatched]).to be_nil
    end
  end
end
