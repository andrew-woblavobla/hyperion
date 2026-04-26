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
  end
end
