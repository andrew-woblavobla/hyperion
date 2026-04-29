# frozen_string_literal: true

require 'net/http'
require 'socket'

# 2.0.0: the legacy `:requests_async_dispatched` /
# `:requests_threadpool_dispatched` keys are retired. Only the
# per-mode `:requests_dispatch_<mode>` key is emitted by
# `Server#record_dispatch`. 1.7→1.8 dual-emitted both for one full
# release cycle to give Grafana boards a migration window.
RSpec.describe 'per-mode dispatch counters (RFC A2 / §3 2.0.0)' do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  before do
    @prev_metrics = Hyperion.instance_variable_get(:@metrics)
    Hyperion.instance_variable_set(:@metrics, Hyperion::Metrics.new)
  end

  after { Hyperion.instance_variable_set(:@metrics, @prev_metrics) }

  it 'increments :requests_dispatch_threadpool_h1 on plain HTTP and does NOT emit the retired legacy key' do
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app)
    server.listen
    serve_thread = Thread.new { server.start }

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
    sleep 0.05

    stats = Hyperion.stats
    expect(stats[:requests_dispatch_threadpool_h1]).to be >= 1
    # Retired legacy keys: must NOT appear at all in 2.0.
    expect(stats).not_to have_key(:requests_threadpool_dispatched)
    expect(stats).not_to have_key(:requests_async_dispatched)
  ensure
    server&.stop
    serve_thread&.join(2)
  end

  describe 'Server#record_dispatch (unit)' do
    let(:server) { Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app) }

    it 'emits ONLY :requests_dispatch_threadpool_h1 for threadpool_h1' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:threadpool_h1))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_threadpool_h1]).to eq(1)
      expect(stats).not_to have_key(:requests_threadpool_dispatched)
    end

    it 'emits ONLY :requests_dispatch_inline_h1_no_pool for inline_h1_no_pool' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:inline_h1_no_pool))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_inline_h1_no_pool]).to eq(1)
      expect(stats).not_to have_key(:requests_threadpool_dispatched)
    end

    it 'emits ONLY :requests_dispatch_tls_h1_inline for tls_h1_inline' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:tls_h1_inline))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_tls_h1_inline]).to eq(1)
      expect(stats).not_to have_key(:requests_async_dispatched)
    end

    it 'emits ONLY :requests_dispatch_async_io_h1_inline for async_io_h1_inline' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:async_io_h1_inline))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_async_io_h1_inline]).to eq(1)
      expect(stats).not_to have_key(:requests_async_dispatched)
    end

    it 'emits ONLY :requests_dispatch_tls_h2 for tls_h2' do
      server.send(:record_dispatch, Hyperion::DispatchMode.new(:tls_h2))
      stats = Hyperion.stats
      expect(stats[:requests_dispatch_tls_h2]).to eq(1)
      expect(stats).not_to have_key(:requests_async_dispatched)
      expect(stats).not_to have_key(:requests_threadpool_dispatched)
    end
  end
end
