# frozen_string_literal: true

require 'hyperion/adapter/rack'
require 'hyperion/runtime'
require 'hyperion/request'
require 'hyperion/logger'

# 2.5-C — per-request lifecycle hooks (Runtime#on_request_start /
# #on_request_end). Apps that wire NewRelic / AppSignal / OpenTelemetry /
# DataDog used to monkey-patch `Adapter::Rack#call` to attach
# trace-span start/end. 2.5-C exposes those callbacks as a first-class
# API so observers register from outside without patching.
RSpec.describe 'Request lifecycle hooks (2.5-C)' do
  let(:request) do
    Hyperion::Request.new(
      method: 'GET',
      path: '/widgets',
      query_string: 'q=1',
      http_version: 'HTTP/1.1',
      headers: { 'host' => '127.0.0.1', 'user-agent' => 'rspec' },
      body: '',
      peer_address: '127.0.0.1'
    )
  end

  let(:app) do
    lambda do |env|
      env['app.observed_path'] = env['PATH_INFO']
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
  end

  let(:runtime) { Hyperion::Runtime.new }

  describe 'registration API' do
    it 'requires a block for on_request_start' do
      expect { runtime.on_request_start }.to raise_error(ArgumentError, /block required/)
    end

    it 'requires a block for on_request_end' do
      expect { runtime.on_request_end }.to raise_error(ArgumentError, /block required/)
    end

    it 'reports has_request_hooks? false when no hooks registered' do
      expect(runtime.has_request_hooks?).to be(false)
    end

    it 'reports has_request_hooks? true after a before-hook is registered' do
      runtime.on_request_start { |_req, _env| nil }
      expect(runtime.has_request_hooks?).to be(true)
    end

    it 'reports has_request_hooks? true after an after-hook is registered' do
      runtime.on_request_end { |_req, _env, _resp, _err| nil }
      expect(runtime.has_request_hooks?).to be(true)
    end
  end

  describe 'dispatch — happy path' do
    it 'fires before-hook AFTER env is built and BEFORE app.call' do
      env_at_before_hook = nil
      env_at_app = nil
      runtime.on_request_start do |_req, env|
        env_at_before_hook = env.dup
      end
      probe_app = lambda do |env|
        env['app.observed_path'] = env['PATH_INFO']
        env_at_app = env.dup
        [200, {}, ['ok']]
      end

      Hyperion::Adapter::Rack.call(probe_app, request, runtime: runtime)

      expect(env_at_before_hook).not_to be_nil
      expect(env_at_before_hook['REQUEST_METHOD']).to eq('GET')
      expect(env_at_before_hook['PATH_INFO']).to eq('/widgets')
      # The before-hook saw env BEFORE the app populated `app.observed_path`.
      expect(env_at_before_hook['app.observed_path']).to be_nil
      expect(env_at_app['app.observed_path']).to eq('/widgets')
    end

    it 'fires after-hook AFTER app.call with the response tuple and nil error' do
      captured = nil
      runtime.on_request_end do |req, env, response, error|
        captured = { req: req, env_path: env['PATH_INFO'], response: response, error: error }
      end

      Hyperion::Adapter::Rack.call(app, request, runtime: runtime)

      expect(captured[:req]).to equal(request)
      expect(captured[:env_path]).to eq('/widgets')
      expect(captured[:response]).to eq([200, { 'content-type' => 'text/plain' }, ['ok']])
      expect(captured[:error]).to be_nil
    end

    it 'fires multiple hooks in registration order (FIFO)' do
      order = []
      runtime.on_request_start { |_req, _env| order << :before_a }
      runtime.on_request_start { |_req, _env| order << :before_b }
      runtime.on_request_start { |_req, _env| order << :before_c }
      runtime.on_request_end { |_req, _env, _r, _e| order << :after_a }
      runtime.on_request_end { |_req, _env, _r, _e| order << :after_b }

      Hyperion::Adapter::Rack.call(app, request, runtime: runtime)

      expect(order).to eq(%i[before_a before_b before_c after_a after_b])
    end

    it 'shares the same env Hash across before/after — middleware can stash trace context' do
      stashed = nil
      runtime.on_request_start do |_req, env|
        env['otel.span'] = :fake_span_handle
      end
      runtime.on_request_end do |_req, env, _resp, _err|
        stashed = env['otel.span']
      end

      Hyperion::Adapter::Rack.call(app, request, runtime: runtime)

      expect(stashed).to eq(:fake_span_handle)
    end
  end

  describe 'dispatch — failure path' do
    let(:failing_app) do
      lambda do |_env|
        raise StandardError, 'app blew up'
      end
    end

    it 'fires after-hook with response=nil and the raised error' do
      captured = nil
      runtime.on_request_end do |_req, _env, response, error|
        captured = [response, error]
      end

      # The outer rescue (Hyperion.logger) translates the raise into a
      # 500 — verify the hook saw the original error before the
      # translation, and that the translated response still flows back
      # to the caller. Silence the global logger so the example output
      # stays clean.
      original_default_logger = Hyperion::Runtime.default.logger
      response = nil
      begin
        Hyperion::Runtime.default.logger = Hyperion::Logger.new(io: StringIO.new)
        response = Hyperion::Adapter::Rack.call(failing_app, request, runtime: runtime)
      ensure
        Hyperion::Runtime.default.logger = original_default_logger if original_default_logger
      end

      expect(captured[0]).to be_nil
      expect(captured[1]).to be_a(StandardError)
      expect(captured[1].message).to eq('app blew up')
      expect(response[0]).to eq(500)
    end

    it 'does not break the chain when a hook raises — subsequent hooks still fire and the response still returns' do
      order = []
      log_io = StringIO.new
      runtime.logger = Hyperion::Logger.new(io: log_io)

      runtime.on_request_start { |_req, _env| order << :before_a }
      runtime.on_request_start { |_req, _env| raise 'busted before' }
      runtime.on_request_start { |_req, _env| order << :before_c }
      runtime.on_request_end { |_req, _env, _r, _e| order << :after_a }
      runtime.on_request_end { |_req, _env, _r, _e| raise 'busted after' }
      runtime.on_request_end { |_req, _env, _r, _e| order << :after_c }

      response = Hyperion::Adapter::Rack.call(app, request, runtime: runtime)

      expect(order).to eq(%i[before_a before_c after_a after_c])
      expect(response[0]).to eq(200)
      log_output = log_io.string
      expect(log_output).to include('request lifecycle hook raised')
      expect(log_output).to include('busted before')
      expect(log_output).to include('busted after')
    end

    it "logs the offending hook's source location so operators can identify it" do
      log_io = StringIO.new
      runtime.logger = Hyperion::Logger.new(io: log_io)
      runtime.on_request_start { |_req, _env| raise 'observer crash' }

      Hyperion::Adapter::Rack.call(app, request, runtime: runtime)

      expect(log_io.string).to match(/request_lifecycle_hooks_spec\.rb:\d+/)
    end
  end

  describe 'zero-cost path (audit harness compatibility)' do
    # Mirrors yjit_alloc_audit_spec — when no hooks are registered the
    # per-request alloc count must stay ≤ 10 objects/req. The audit
    # spec covers `Adapter::Rack.call(app, request)` (no runtime kwarg);
    # this spec covers the explicit `runtime: runtime_with_no_hooks`
    # path so we know plumbing it through doesn't blow the budget.
    require 'hyperion/response_writer'

    let(:writer) { Hyperion::ResponseWriter.new }
    let(:sink) do
      Class.new do
        def write(b) = b.bytesize
        def closed? = false
        def flush; end
      end.new
    end

    it 'allocates ≤ 10 objects per request when runtime has no hooks' do
      iterations = 2_000
      # Warm up (cached_date, lazy paths).
      20.times do
        status, headers, body = Hyperion::Adapter::Rack.call(app, request, runtime: runtime)
        writer.write(sink, status, headers, body, keep_alive: true)
      end

      GC.disable
      GC.start
      before = GC.stat[:total_allocated_objects]
      iterations.times do
        status, headers, body = Hyperion::Adapter::Rack.call(app, request, runtime: runtime)
        writer.write(sink, status, headers, body, keep_alive: true)
      end
      after = GC.stat[:total_allocated_objects]
      GC.enable

      per_req = (after - before).fdiv(iterations)
      # Same 10/req threshold as yjit_alloc_audit_spec — passing the
      # runtime kwarg + checking has_request_hooks? must not push
      # allocations above the budget.
      expect(per_req).to be <= 10.0,
                         "expected ≤ 10.0 objects/req, got #{per_req.round(2)}"
    end
  end
end
