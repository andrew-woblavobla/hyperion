# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/websocket/connection'

RSpec.describe '2.4-C — /-/metrics enrichment' do
  describe Hyperion::Metrics::PathTemplater do
    subject(:templater) { described_class.new }

    it 'replaces integer path segments with :id' do
      expect(templater.template('/users/123')).to eq('/users/:id')
    end

    it 'replaces UUID path segments with :uuid' do
      uuid = '3fa85f64-5717-4562-b3fc-2c963f66afa6'
      expect(templater.template("/orders/#{uuid}")).to eq('/orders/:uuid')
    end

    it 'replaces multiple dynamic segments in one path' do
      uuid = '3fa85f64-5717-4562-b3fc-2c963f66afa6'
      expect(templater.template("/users/42/orders/#{uuid}")).to eq('/users/:id/orders/:uuid')
    end

    it 'preserves static paths unchanged' do
      expect(templater.template('/api/health')).to eq('/api/health')
    end

    it 'returns nil/empty path verbatim' do
      expect(templater.template(nil)).to be_nil
      expect(templater.template('')).to eq('')
    end

    it 'honours custom rules' do
      slug = described_class.new(rules: [[/[a-z][a-z0-9-]+/, ':slug']])
      expect(slug.template('/articles/my-post-2024')).to eq('/:slug/:slug')
    end

    it 'caches templated paths in an LRU' do
      tmpl = described_class.new(lru_size: 3)
      tmpl.template('/a/1')
      tmpl.template('/b/2')
      tmpl.template('/c/3')
      expect(tmpl.cache_size).to eq(3)
      tmpl.template('/d/4')
      expect(tmpl.cache_size).to eq(3) # oldest evicted
    end

    it 'evicts oldest entry when LRU is full' do
      tmpl = described_class.new(lru_size: 2)
      tmpl.template('/a/1')
      tmpl.template('/b/2')
      tmpl.template('/c/3') # evicts /a/1
      expect(tmpl.cache_size).to eq(2)
    end
  end

  describe Hyperion::Metrics, '#observe_histogram' do
    let(:metrics) { described_class.new }

    it 'records observations into the right buckets' do
      metrics.register_histogram(:hist, buckets: [1.0, 5.0, 10.0])
      metrics.observe_histogram(:hist, 0.5)
      metrics.observe_histogram(:hist, 3.0)
      metrics.observe_histogram(:hist, 7.0)
      metrics.observe_histogram(:hist, 100.0) # only +Inf

      snap = metrics.histogram_snapshot[:hist]
      series = snap[:series][[]]
      expect(series[:counts]).to eq([1, 2, 3]) # cumulative
      expect(series[:count]).to eq(4)
      expect(series[:sum]).to eq(110.5)
    end

    it 'observes per-label-tuple separately' do
      metrics.register_histogram(:hist, buckets: [1.0], label_keys: %w[method])
      metrics.observe_histogram(:hist, 0.5, ['GET'])
      metrics.observe_histogram(:hist, 0.5, ['POST'])
      metrics.observe_histogram(:hist, 0.5, ['GET'])

      snap = metrics.histogram_snapshot[:hist]
      expect(snap[:series][['GET']][:count]).to eq(2)
      expect(snap[:series][['POST']][:count]).to eq(1)
    end

    it 'raises on conflicting re-registration' do
      metrics.register_histogram(:hist, buckets: [1.0])
      expect { metrics.register_histogram(:hist, buckets: [2.0]) }
        .to raise_error(ArgumentError, /re-registered with different shape/)
    end

    it 'silently skips observations on unregistered families' do
      expect { metrics.observe_histogram(:nope, 1.0) }.not_to raise_error
    end
  end

  describe Hyperion::Metrics, '#set_gauge / #increment_gauge' do
    let(:metrics) { described_class.new }

    it 'records and reads back gauge values' do
      metrics.set_gauge(:g, 42, ['worker_1'])
      snap = metrics.gauge_snapshot[:g]
      expect(snap[:series][['worker_1']]).to eq(42.0)
    end

    it 'increments + decrements gauges' do
      metrics.increment_gauge(:g, ['w1'])
      metrics.increment_gauge(:g, ['w1'])
      metrics.decrement_gauge(:g, ['w1'])
      expect(metrics.gauge_snapshot[:g][:series][['w1']]).to eq(1.0)
    end

    it 'evaluates block-form gauges at snapshot time' do
      counter = 0
      metrics.set_gauge(:g, nil, []) do
        counter += 1
        counter
      end
      first = metrics.gauge_snapshot[:g][:series][[]]
      second = metrics.gauge_snapshot[:g][:series][[]]
      expect(first).to eq(1.0)
      expect(second).to eq(2.0)
    end
  end

  describe Hyperion::Metrics, '#increment_labeled_counter' do
    let(:metrics) { described_class.new }

    it 'tracks per-label cumulative counts' do
      metrics.register_labeled_counter(:per_conn_rejections, label_keys: %w[worker_id])
      metrics.increment_labeled_counter(:per_conn_rejections, ['1234'])
      metrics.increment_labeled_counter(:per_conn_rejections, ['1234'], 4)
      metrics.increment_labeled_counter(:per_conn_rejections, ['5678'])

      snap = metrics.labeled_counter_snapshot[:per_conn_rejections]
      expect(snap[:series][['1234']]).to eq(5)
      expect(snap[:series][['5678']]).to eq(1)
    end
  end

  describe Hyperion::PrometheusExporter, '.render_full' do
    let(:metrics) { Hyperion::Metrics.new }

    before do
      metrics.register_histogram(:hyperion_request_duration_seconds,
                                 buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 2.5, 10.0],
                                 label_keys: %w[method path status])
      metrics.observe_histogram(:hyperion_request_duration_seconds,
                                0.05, %w[GET /users/:id 2xx])
      metrics.observe_histogram(:hyperion_request_duration_seconds,
                                3.0, %w[GET /users/:id 2xx])

      metrics.register_labeled_counter(:hyperion_per_conn_rejections_total,
                                       label_keys: %w[worker_id])
      metrics.increment_labeled_counter(:hyperion_per_conn_rejections_total, ['1234'])

      metrics.set_gauge(:hyperion_tls_ktls_active_connections, 7, ['1234'])
      metrics.set_gauge(:hyperion_io_uring_workers_active, 1, ['1234'])

      metrics.increment(:requests, 100)
    end

    it 'renders all 2.4-C metric names in the body' do
      body = described_class.render_full(metrics)
      expect(body).to include('hyperion_request_duration_seconds_bucket')
      expect(body).to include('hyperion_request_duration_seconds_sum')
      expect(body).to include('hyperion_request_duration_seconds_count')
      expect(body).to include('hyperion_per_conn_rejections_total')
      expect(body).to include('hyperion_tls_ktls_active_connections')
      expect(body).to include('hyperion_io_uring_workers_active')
      expect(body).to include('hyperion_requests_total 100')
    end

    it 'emits a HELP and TYPE line for every histogram family' do
      body = described_class.render_full(metrics)
      expect(body).to include('# HELP hyperion_request_duration_seconds')
      expect(body).to include('# TYPE hyperion_request_duration_seconds histogram')
    end

    it 'emits +Inf bucket per series with cumulative count' do
      body = described_class.render_full(metrics)
      expect(body).to match(/hyperion_request_duration_seconds_bucket\{[^}]*le="\+Inf"[^}]*\} 2/)
    end

    it 'emits all configured bucket edges per series' do
      body = described_class.render_full(metrics)
      [0.001, 0.005, 0.025, 0.1, 0.5, 2.5, 10].each do |edge|
        formatted = edge == edge.to_i ? edge.to_i.to_s : format('%.6g', edge.to_f)
        expect(body).to include("le=\"#{formatted}\"")
      end
    end

    it 'is parseable as Prometheus text format (basic regex sanity)' do
      body = described_class.render_full(metrics)
      # Each non-comment, non-blank line is `<name>{labels?} <value>` shape.
      body.each_line do |line|
        next if line.start_with?('#')
        next if line.strip.empty?

        expect(line).to match(/\A[a-zA-Z_][a-zA-Z0-9_]*(?:\{[^}]*\})?\s+\S+\n?\z/)
      end
    end

    it 'escapes label values that contain quotes or backslashes' do
      metrics.register_labeled_counter(:dangerous, label_keys: %w[k])
      metrics.increment_labeled_counter(:dangerous, ['a"b\\c'])
      body = described_class.render_full(metrics)
      expect(body).to include('a\\"b\\\\c')
    end
  end

  describe 'Connection request-duration observation', :integration do
    let(:metrics) { Hyperion::Metrics.new }
    let(:runtime) do
      Hyperion::Runtime.new(metrics: metrics, logger: Hyperion.logger)
    end

    it 'records per-route duration for the templated path' do
      Hyperion::Metrics.reset_default_path_templater!
      conn = Hyperion::Connection.new(runtime: runtime)
      request = Hyperion::Request.new(method: 'GET',
                                      path: '/users/42',
                                      query_string: '',
                                      http_version: 'HTTP/1.1',
                                      headers: { 'host' => 'localhost' },
                                      body: '',
                                      peer_address: '127.0.0.1')
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.05
      conn.send(:observe_request_duration, request, 200, started_at)

      snap = metrics.histogram_snapshot[Hyperion::Connection::REQUEST_DURATION_HISTOGRAM]
      expect(snap).not_to be_nil
      keys = snap[:series].keys.first
      expect(keys).to eq(%w[GET /users/:id 2xx])
      expect(snap[:series][keys][:count]).to eq(1)
    end
  end

  describe 'WebSocket deflate ratio observation' do
    it 'observes original/compressed ratio when permessage-deflate is active' do
      Hyperion::Runtime.reset_default!
      original_metrics = Hyperion.metrics

      # Build a minimal WS Connection with the deflater wired up.
      socket = double('socket', write: 1)
      ws = Hyperion::WebSocket::Connection.new(
        socket,
        extensions: { permessage_deflate: { server_max_window_bits: 15,
                                            client_max_window_bits: 15 } }
      )

      # Drive the deflate path directly. WS::Connection defines a
      # public `send(payload)` API for outbound frames that shadows
      # Object#send, so we use __send__ to reach the private helper.
      original = 'a' * 1024
      compressed = ws.__send__(:deflate_message, original.b)
      ratio = original.bytesize.to_f / compressed.bytesize

      snap = original_metrics.histogram_snapshot[
        Hyperion::WebSocket::Connection::DEFLATE_RATIO_HISTOGRAM
      ]
      expect(snap).not_to be_nil
      series = snap[:series][[]]
      expect(series[:count]).to eq(1)
      expect(series[:sum]).to be_within(0.001).of(ratio)
    end
  end

  describe 'Per-conn fairness rejection counter' do
    let(:metrics) { Hyperion::Metrics.new }
    let(:runtime) { Hyperion::Runtime.new(metrics: metrics, logger: Hyperion.logger) }

    it 'increments the labeled counter on cap hit' do
      conn = Hyperion::Connection.new(runtime: runtime, max_in_flight_per_conn: 1)
      # Saturate the cap.
      conn.instance_variable_set(:@in_flight, 1)
      socket_stub = double('socket', write: 1)

      conn.send(:per_conn_admit!, socket_stub, '127.0.0.1')

      snap = metrics.labeled_counter_snapshot[:hyperion_per_conn_rejections_total]
      expect(snap).not_to be_nil
      expect(snap[:series][[Process.pid.to_s]]).to eq(1)
    end
  end

  describe 'kTLS active-conns gauge' do
    let(:metrics) { Hyperion::Metrics.new }

    before do
      Hyperion::Runtime.default.metrics = metrics
    end

    after do
      Hyperion::Runtime.reset_default!
    end

    it 'increments on tracked handshake and decrements on untrack' do
      ssl_socket = Object.new
      allow(Hyperion::TLS).to receive(:ktls_active?).and_return(true)

      Hyperion::TLS.track_ktls_handshake!(ssl_socket)
      gauge_key = [Process.pid.to_s]
      after_track = metrics.gauge_snapshot[Hyperion::TLS::KTLS_ACTIVE_CONNECTIONS_GAUGE]
      expect(after_track[:series][gauge_key]).to eq(1.0)

      Hyperion::TLS.untrack_ktls_handshake!(ssl_socket)
      after_untrack = metrics.gauge_snapshot[Hyperion::TLS::KTLS_ACTIVE_CONNECTIONS_GAUGE]
      expect(after_untrack[:series][gauge_key]).to eq(0.0)
    end

    it 'is a no-op when kTLS is not engaged for the connection' do
      ssl_socket = Object.new
      allow(Hyperion::TLS).to receive(:ktls_active?).and_return(false)

      Hyperion::TLS.track_ktls_handshake!(ssl_socket)
      after_track = metrics.gauge_snapshot[Hyperion::TLS::KTLS_ACTIVE_CONNECTIONS_GAUGE]
      expect(after_track).to be_nil
    end
  end
end
