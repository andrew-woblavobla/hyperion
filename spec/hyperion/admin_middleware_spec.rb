# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Hyperion::AdminMiddleware do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hello']] } }
  let(:token) { 'super-secret-token' }
  # A constant fake target prevents Process.kill from actually signalling
  # the test process (or anything else) when the success path runs. Tests
  # that want to assert the call still verify it via expect(...).to receive.
  let(:fake_target) { 12_345 }

  def env_for(method:, path:, headers: {})
    env = { 'REQUEST_METHOD' => method, 'PATH_INFO' => path, 'REMOTE_ADDR' => '127.0.0.1' }
    headers.each { |k, v| env[k] = v }
    env
  end

  describe '#initialize' do
    it 'raises ArgumentError when token is nil' do
      expect { described_class.new(app, token: nil) }.to raise_error(ArgumentError, /non-empty/)
    end

    it 'raises ArgumentError when token is empty string' do
      expect { described_class.new(app, token: '') }.to raise_error(ArgumentError, /non-empty/)
    end
  end

  describe 'signal target resolution' do
    # These cover the S1 hotfix: `AdminMiddleware#resolve_signal_target`
    # used to mistarget when the Hyperion master runs as PID 1 (the
    # default shape inside containerd / Docker, where `CMD ["hyperion",
    # …]` makes the master process PID 1). Old logic:
    #
    #     ppid = Process.ppid
    #     ppid > 1 ? ppid : Process.pid
    #
    # In a worker forked from a PID-1 master, `Process.ppid` returns 1,
    # so the fallback branch fired and mistargeted *the worker itself*.
    # SIGTERM landed on the worker, the master kept running, and the
    # admin endpoint returned 202 "draining" while nothing happened at
    # the fleet level. The fix routes resolution through
    # `Hyperion.master_pid`, which the master writes at boot and
    # exports into ENV so workers inherit the correct PID via fork.

    # Build a middleware WITHOUT injecting signal_target so the resolver runs.
    let(:resolving_middleware) { described_class.new(app, token: token) }
    let(:env_quit) do
      env_for(method: 'POST', path: '/-/quit',
              headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => token })
    end

    around do |example|
      prev_ivar = Hyperion.instance_variable_get(:@master_pid)
      prev_env  = ENV['HYPERION_MASTER_PID']
      example.run
    ensure
      Hyperion.instance_variable_set(:@master_pid, prev_ivar)
      if prev_env.nil?
        ENV.delete('HYPERION_MASTER_PID')
      else
        ENV['HYPERION_MASTER_PID'] = prev_env
      end
    end

    it 'targets Hyperion.master_pid (NOT Process.ppid) when master runs as PID 1' do
      # Simulate a worker forked from a master that is PID 1 inside a
      # container. ppid == 1 is the trap: pre-fix code took the
      # `ppid > 1 ? ppid : Process.pid` branch and signalled the
      # worker itself.
      master_pid_in_container = 1
      worker_pid_in_container = 42
      allow(Process).to receive(:ppid).and_return(master_pid_in_container)
      allow(Process).to receive(:pid).and_return(worker_pid_in_container)

      # The master would have done this at boot before forking us.
      Hyperion.instance_variable_set(:@master_pid, master_pid_in_container)
      ENV['HYPERION_MASTER_PID'] = master_pid_in_container.to_s

      expect(Process).to receive(:kill).with('TERM', master_pid_in_container)

      status, = resolving_middleware.call(env_quit)
      expect(status).to eq(202)
    end

    it 'reads HYPERION_MASTER_PID from ENV when the in-process ivar is absent (post-fork worker)' do
      # In a real worker, `Hyperion.master_pid!` was called in the
      # master only — the child's @master_pid ivar is nil but the env
      # var was inherited via fork.
      Hyperion.instance_variable_set(:@master_pid, nil)
      ENV['HYPERION_MASTER_PID'] = '99999'

      expect(Process).to receive(:kill).with('TERM', 99_999)

      status, = resolving_middleware.call(env_quit)
      expect(status).to eq(202)
    end

    it 'falls back to Process.pid when master_pid is unset (single-mode pre-boot or non-Hyperion test context)' do
      Hyperion.instance_variable_set(:@master_pid, nil)
      ENV.delete('HYPERION_MASTER_PID')
      allow(Process).to receive(:pid).and_return(7777)

      expect(Process).to receive(:kill).with('TERM', 7777)

      status, = resolving_middleware.call(env_quit)
      expect(status).to eq(202)
    end

    it 'ignores malformed HYPERION_MASTER_PID and falls back to Process.pid' do
      Hyperion.instance_variable_set(:@master_pid, nil)
      ENV['HYPERION_MASTER_PID'] = 'not-a-number'
      allow(Process).to receive(:pid).and_return(8888)

      expect(Process).to receive(:kill).with('TERM', 8888)

      status, = resolving_middleware.call(env_quit)
      expect(status).to eq(202)
    end

    it 'prefers the explicit signal_target constructor arg over Hyperion.master_pid' do
      Hyperion.instance_variable_set(:@master_pid, 11_111)
      explicit = described_class.new(app, token: token, signal_target: 22_222)

      expect(Process).to receive(:kill).with('TERM', 22_222)

      status, = explicit.call(env_quit)
      expect(status).to eq(202)
    end
  end

  describe '#call' do
    subject(:middleware) { described_class.new(app, token: token, signal_target: fake_target) }

    it 'delegates to the wrapped app for non-admin paths' do
      env = env_for(method: 'GET', path: '/users')
      status, _headers, body = middleware.call(env)
      expect(status).to eq(200)
      expect(body).to eq(['hello'])
    end

    it 'delegates to the wrapped app for admin path with non-POST method' do
      env = env_for(method: 'GET', path: '/-/quit')
      status, _headers, body = middleware.call(env)
      expect(status).to eq(200)
      expect(body).to eq(['hello'])
    end

    it 'returns 401 on POST /-/quit without the token header' do
      # Stub Process.kill to ensure we never reach the signal path even
      # if auth somehow passed — defense-in-depth for the test itself.
      allow(Process).to receive(:kill)

      env = env_for(method: 'POST', path: '/-/quit')
      status, headers, body = middleware.call(env)
      expect(status).to eq(401)
      expect(headers['content-type']).to eq('application/json')
      expect(body.first).to include('unauthorized')
      expect(Process).not_to have_received(:kill)
    end

    it 'returns 401 on POST /-/quit with the wrong token' do
      allow(Process).to receive(:kill)

      env = env_for(method: 'POST', path: '/-/quit',
                    headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => 'wrong-token-here-XYZ' })
      status, _headers, body = middleware.call(env)
      expect(status).to eq(401)
      expect(body.first).to include('unauthorized')
      expect(Process).not_to have_received(:kill)
    end

    it 'returns 401 when the provided token has a different length than the configured token' do
      # Length-mismatch must fail BEFORE secure_compare is called, since
      # secure_compare raises on differing lengths. This guards the
      # length-leak side channel without leaking timing.
      allow(Process).to receive(:kill)

      env = env_for(method: 'POST', path: '/-/quit',
                    headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => 'short' })
      status, = middleware.call(env)
      expect(status).to eq(401)
      expect(Process).not_to have_received(:kill)
    end

    it 'signals the configured target and returns 202 on POST /-/quit with the correct token' do
      expect(Process).to receive(:kill).with('TERM', fake_target)

      env = env_for(method: 'POST', path: '/-/quit',
                    headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => token })
      status, headers, body = middleware.call(env)
      expect(status).to eq(202)
      expect(headers['content-type']).to eq('application/json')
      expect(body.first).to include('draining')
    end

    it 'returns 500 with JSON error and does not raise when Process.kill fails' do
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH, 'No such process')

      env = env_for(method: 'POST', path: '/-/quit',
                    headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => token })
      status, headers, body = middleware.call(env)
      expect(status).to eq(500)
      expect(headers['content-type']).to eq('application/json')
      expect(body.first).to include('signal_failed')
    end

    describe 'GET /-/metrics' do
      # Use a real fresh Metrics so we exercise the actual snapshot path
      # (no stubs) — keeps this spec honest about the integration.
      before do
        @prev_metrics = Hyperion.instance_variable_get(:@metrics)
        Hyperion.instance_variable_set(:@metrics, Hyperion::Metrics.new)
      end

      after { Hyperion.instance_variable_set(:@metrics, @prev_metrics) }

      it 'returns 401 without the token header' do
        env = env_for(method: 'GET', path: '/-/metrics')
        status, headers, body = middleware.call(env)
        expect(status).to eq(401)
        expect(headers['content-type']).to eq('application/json')
        expect(body.first).to include('unauthorized')
      end

      it 'returns 401 with the wrong token' do
        env = env_for(method: 'GET', path: '/-/metrics',
                      headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => 'wrong-token-here-XYZ' })
        status, = middleware.call(env)
        expect(status).to eq(401)
      end

      it 'returns 200 with Prometheus body when authenticated' do
        Hyperion.metrics.increment(:requests, 42)
        Hyperion.metrics.increment_status(200)

        env = env_for(method: 'GET', path: '/-/metrics',
                      headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => token })
        status, headers, body = middleware.call(env)
        expect(status).to eq(200)
        expect(headers['content-type']).to eq('text/plain; version=0.0.4; charset=utf-8')
        text = body.first
        expect(text).to include('# TYPE hyperion_requests_total counter')
        expect(text).to include('hyperion_requests_total 42')
        expect(text).to include('hyperion_responses_status_total{status="200"} 1')
      end

      it 'returns empty body when no metrics have been recorded' do
        env = env_for(method: 'GET', path: '/-/metrics',
                      headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => token })
        status, _headers, body = middleware.call(env)
        expect(status).to eq(200)
        expect(body.first).to eq('')
      end

      it 'falls through to the app on POST /-/metrics (wrong method)' do
        env = env_for(method: 'POST', path: '/-/metrics',
                      headers: { 'HTTP_X_HYPERION_ADMIN_TOKEN' => token })
        status, _headers, response_body = middleware.call(env)
        expect(status).to eq(200)
        expect(response_body).to eq(['hello'])
      end
    end
  end
end
