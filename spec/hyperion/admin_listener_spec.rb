# frozen_string_literal: true

require 'net/http'

RSpec.describe Hyperion::AdminListener do
  let(:token) { 'admin-listener-token' }
  let(:metrics) { Hyperion::Metrics.new }
  let(:logger)  { Hyperion::Logger.new(io: StringIO.new) }
  let(:runtime) { Hyperion::Runtime.new(metrics: metrics, logger: logger) }

  describe '#initialize' do
    it 'requires a non-empty token' do
      expect do
        described_class.new(host: '127.0.0.1', port: 0, token: nil, runtime: runtime,
                            signal_target: Process.pid)
      end.to raise_error(ArgumentError, /token/)
      expect do
        described_class.new(host: '127.0.0.1', port: 0, token: '', runtime: runtime,
                            signal_target: Process.pid)
      end.to raise_error(ArgumentError, /token/)
    end
  end

  describe '#start / live HTTP requests' do
    let(:listener) do
      described_class.new(host: '127.0.0.1', port: 0, token: token,
                          runtime: runtime, signal_target: Process.pid)
    end

    after { listener.stop }

    def get(path, headers: {})
      listener.start
      uri = URI("http://127.0.0.1:#{listener.port}#{path}")
      req = Net::HTTP::Get.new(uri)
      headers.each { |k, v| req[k] = v }
      Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    end

    it 'rejects /-/metrics without a token (401)' do
      response = get('/-/metrics')
      expect(response.code).to eq('401')
      expect(response.body).to include('unauthorized')
    end

    it 'rejects /-/metrics with the wrong token (401)' do
      response = get('/-/metrics', headers: { 'X-Hyperion-Admin-Token' => 'wrong' })
      expect(response.code).to eq('401')
    end

    it 'serves /-/metrics in Prometheus format with the right token' do
      metrics.increment(:requests_total, 7)
      response = get('/-/metrics', headers: { 'X-Hyperion-Admin-Token' => token })
      expect(response.code).to eq('200')
      expect(response['content-type']).to start_with('text/plain; version=0.0.4')
      expect(response.body).to include('hyperion_requests_total 7')
    end

    it 'returns 404 on unknown paths' do
      response = get('/etc/passwd', headers: { 'X-Hyperion-Admin-Token' => token })
      expect(response.code).to eq('404')
    end
  end

  describe 'integration: Server with admin_listener_port' do
    let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hi']] } }

    it 'spawns the sibling listener when admin_listener_port + admin_token are set' do
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                    admin_listener_port: 0,
                                    admin_token: token,
                                    runtime: runtime)
      server.listen
      server.send(:maybe_start_admin_listener)
      sibling = server.instance_variable_get(:@admin_listener)
      expect(sibling).to be_a(described_class)
      expect(sibling.port).to be > 0

      response = Net::HTTP.start('127.0.0.1', sibling.port) do |h|
        req = Net::HTTP::Get.new('/-/metrics')
        req['X-Hyperion-Admin-Token'] = token
        h.request(req)
      end
      expect(response.code).to eq('200')
    ensure
      server&.stop
      sibling&.stop
    end

    it 'does NOT spawn a sibling listener when port is nil (default)' do
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                    admin_token: token, runtime: runtime)
      server.listen
      server.send(:maybe_start_admin_listener)
      expect(server.instance_variable_get(:@admin_listener)).to be_nil
    ensure
      server&.stop
    end

    it 'does NOT spawn a sibling listener when token is unset (defence in depth)' do
      server = Hyperion::Server.new(app: app, host: '127.0.0.1', port: 0,
                                    admin_listener_port: 0,
                                    admin_token: nil, runtime: runtime)
      server.listen
      server.send(:maybe_start_admin_listener)
      expect(server.instance_variable_get(:@admin_listener)).to be_nil
    ensure
      server&.stop
    end
  end
end
