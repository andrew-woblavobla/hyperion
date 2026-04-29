# frozen_string_literal: true

require 'net/http'
require 'rbconfig'

RSpec.describe 'accept_fibers_per_worker (RFC A6)' do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  describe 'Server#initialize' do
    it 'defaults accept_fibers_per_worker to 1' do
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0)
      expect(server.instance_variable_get(:@accept_fibers_per_worker)).to eq(1)
    end

    it 'honours an explicit positive value' do
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                    accept_fibers_per_worker: 4)
      expect(server.instance_variable_get(:@accept_fibers_per_worker)).to eq(4)
    end

    it 'clamps zero/negative to 1 (a single accept fiber is always required)' do
      [0, -1].each do |bad|
        server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                      accept_fibers_per_worker: bad)
        expect(server.instance_variable_get(:@accept_fibers_per_worker)).to eq(1)
      end
    end

    it 'is plumbed through Config (default 1)' do
      cfg = Hyperion::Config.new
      expect(cfg.accept_fibers_per_worker).to eq(1)
    end
  end

  describe 'multi-fiber accept loop' do
    it 'spawns N children under start_async_loop on Linux + macOS alike' do
      # We don't need a real network round-trip — just observe that
      # `start_async_loop` invokes `run_accept_fiber` N times.
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                    accept_fibers_per_worker: 3)
      server.listen

      # Stub `run_accept_fiber` to count how many fibers spawn, then
      # immediately `@stopped = true` so each fiber's `until @stopped`
      # loop exits cleanly. The count assertion runs on the main fiber
      # after the Async wrapper resolves.
      call_count = 0
      mu = Mutex.new
      server.define_singleton_method(:run_accept_fiber) do |_task|
        mu.synchronize { call_count += 1 }
      end

      # Set @stopped so accept_or_nil short-circuits immediately when
      # invoked. The fibers we spawn should each see the flag.
      server.instance_variable_set(:@stopped, true)
      server.send(:start_async_loop)
      expect(call_count).to eq(3)
    ensure
      server&.stop
    end

    it 'silently honours accept_fibers_per_worker > 1 on Darwin (RFC §5 Q5)' do
      # Documented as "no scaling benefit on Darwin's :share mode but no
      # boot-time error either"; this codifies the no-error half of the
      # contract.
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                    accept_fibers_per_worker: 8)
      expect(server.instance_variable_get(:@accept_fibers_per_worker)).to eq(8)
    end
  end
end
