# frozen_string_literal: true

require 'socket'
require 'timeout'

# 2.12-E — per-worker request counter for the SO_REUSEPORT load-balancing
# audit. Adds a labeled counter `hyperion_requests_dispatch_total{worker_id}`
# that ticks once per dispatched request regardless of which dispatch mode
# served it (Rack via Connection, h2 streams, the 2.12-C accept4 C loop, the
# 2.12-D io_uring C loop). The label value is `Process.pid.to_s` — matches
# the convention already used by `hyperion_io_uring_workers_active` and
# `hyperion_per_conn_rejections_total`.
#
# Operators read this at `/-/metrics` to verify cluster-mode (`-w N`) load
# is distributed across workers. With Linux SO_REUSEPORT the kernel hashes
# 4-tuples; this metric is the only window into whether that hash is
# actually balanced under sustained load (vs. the documented theory).
#
# These specs cover three angles:
#
#   1. The labeled counter family is registered and the per-PID series
#      ticks once per `Connection#serve` request (lock-free per-thread
#      hot path; the family is materialized at scrape time).
#   2. The C-side loop bumps a process-global atomic counter accessible
#      via `PageCache.c_loop_requests_total` — gated on the C ext being
#      available (skipped otherwise).
#   3. `PrometheusExporter.render_full` emits the merged
#      `hyperion_requests_dispatch_total{worker_id="<pid>"}` line, with
#      both the Ruby-side ticks AND the C-loop counter folded in.
RSpec.describe 'Hyperion::Metrics — per-worker request counter (2.12-E)' do
  describe Hyperion::Metrics, '#tick_worker_request' do
    let(:metrics) { described_class.new }

    it 'registers the requests_dispatch_total labeled counter family' do
      metrics.tick_worker_request('1234')
      snap = metrics.labeled_counter_snapshot[:hyperion_requests_dispatch_total]
      expect(snap).not_to be_nil
      expect(snap[:meta][:label_keys]).to eq(%w[worker_id])
    end

    it 'ticks the counter for the supplied worker_id' do
      metrics.tick_worker_request('1234')
      metrics.tick_worker_request('1234')
      metrics.tick_worker_request('5678')
      snap = metrics.labeled_counter_snapshot[:hyperion_requests_dispatch_total]
      expect(snap[:series][['1234']]).to eq(2)
      expect(snap[:series][['5678']]).to eq(1)
    end

    it 'is no-op-safe with a nil worker_id (defensive on misconfigured boots)' do
      expect { metrics.tick_worker_request(nil) }.not_to raise_error
      snap = metrics.labeled_counter_snapshot[:hyperion_requests_dispatch_total]
      # nil is normalized to "0" — see Metrics#tick_worker_request — so the
      # call still records something rather than silently dropping the tick.
      expect(snap[:series]).not_to be_empty
    end
  end

  describe Hyperion::Connection, 'request dispatch ticks the per-worker counter' do
    let(:metrics) { Hyperion::Metrics.new }
    let(:logger)  { Hyperion::Logger.new }
    let(:runtime) { Hyperion::Runtime.new(metrics: metrics, logger: logger) }
    let(:app) do
      ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hi']] }
    end

    def serve_one_request_inline(connection, app)
      cs, ss = ::UNIXSocket.pair
      cs.write("GET /hi HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")
      Thread.new do
        connection.serve(ss, app, max_request_read_seconds: 5)
      rescue StandardError
        nil
      end.tap do |t|
        # Drain the response so the server-side close completes cleanly.
        Timeout.timeout(5) { cs.read }
      ensure
        begin
          cs.close
        rescue StandardError
          nil
        end
        t.join(2)
      end
    end

    it 'increments hyperion_requests_dispatch_total{worker_id=PID} once per served request' do
      pid = Process.pid.to_s
      conn = Hyperion::Connection.new(runtime: runtime)
      serve_one_request_inline(conn, app)

      snap = metrics.labeled_counter_snapshot[:hyperion_requests_dispatch_total]
      expect(snap).not_to be_nil
      expect(snap[:series][[pid]]).to eq(1)
    end
  end

  describe Hyperion::PrometheusExporter, '.render_full emits the per-worker family' do
    # The C-loop fold-in is gated on `metrics_sink == Runtime.default.metrics`
    # so arbitrary spec-only `Metrics.new` fixtures don't pull in a
    # process-global counter that doesn't belong to them. The fold-in
    # test temporarily swaps the default runtime; the simpler render
    # test uses a fresh sink (no C-loop merge expected).

    it 'renders hyperion_requests_dispatch_total with a worker_id label per series' do
      metrics = Hyperion::Metrics.new
      metrics.tick_worker_request('111')
      metrics.tick_worker_request('111')
      metrics.tick_worker_request('222')
      body = described_class.render_full(metrics)
      expect(body).to include('# HELP hyperion_requests_dispatch_total')
      expect(body).to include('# TYPE hyperion_requests_dispatch_total counter')
      expect(body).to match(/hyperion_requests_dispatch_total\{worker_id="111"\} 2/)
      expect(body).to match(/hyperion_requests_dispatch_total\{worker_id="222"\} 1/)
    end

    it 'folds the C-loop counter into the current PID series at scrape time',
       skip: ('C ext not loaded' unless defined?(Hyperion::Http::PageCache) &&
                                       Hyperion::Http::PageCache.respond_to?(:c_loop_requests_total)) do
      prev_default = Hyperion::Runtime.default
      runtime = Hyperion::Runtime.new
      Hyperion::Runtime.default = runtime
      metrics = runtime.metrics
      Hyperion::Http::PageCache.reset_c_loop_requests_total!
      metrics.tick_worker_request(Process.pid.to_s) # 1 Ruby-side tick
      Hyperion::Http::PageCache.bump_c_loop_requests_total_for_test!(3)

      body = described_class.render_full(metrics)
      pid = Process.pid.to_s
      # Total = 1 Ruby + 3 C-loop = 4
      expect(body).to match(/hyperion_requests_dispatch_total\{worker_id="#{pid}"\} 4/)
    ensure
      Hyperion::Http::PageCache.reset_c_loop_requests_total!
      Hyperion::Runtime.default = prev_default if prev_default
    end
  end

  describe 'C accept loop ticks the process-global counter (2.12-C path)' do
    before do
      skip 'C ext not loaded' unless defined?(Hyperion::Http::PageCache) &&
                                     Hyperion::Http::PageCache.respond_to?(:c_loop_requests_total)
      Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
      Hyperion::Http::PageCache.clear
      Hyperion::Http::PageCache.set_lifecycle_active(false)
      Hyperion::Http::PageCache.set_lifecycle_callback(nil)
      Hyperion::Http::PageCache.set_handoff_callback(nil)
      Hyperion::Http::PageCache.reset_c_loop_requests_total!
    end

    after do
      Hyperion::Http::PageCache.stop_accept_loop
      sleep 0.02
      Hyperion::Http::PageCache.set_lifecycle_active(false)
      Hyperion::Http::PageCache.set_lifecycle_callback(nil)
      Hyperion::Http::PageCache.set_handoff_callback(nil)
      Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
      Hyperion::Http::PageCache.clear
      Hyperion::Http::PageCache.reset_c_loop_requests_total!
    end

    it 'increments c_loop_requests_total once per request served from C' do
      Hyperion::Server.handle_static(:GET, '/p', "p\n")
      listener = TCPServer.new('127.0.0.1', 0)
      port = listener.addr[1]

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05

      4.times do
        sock = TCPSocket.new('127.0.0.1', port)
        sock.write("GET /p HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")
        Timeout.timeout(5) { sock.read }
        sock.close
      end

      Hyperion::Http::PageCache.stop_accept_loop
      listener.close
      thread.join(5)

      expect(Hyperion::Http::PageCache.c_loop_requests_total).to be >= 4
    end

    it 'resets to zero on run_static_accept_loop entry' do
      # Pre-bump so we can verify the entry resets.
      Hyperion::Http::PageCache.bump_c_loop_requests_total_for_test!(99)
      expect(Hyperion::Http::PageCache.c_loop_requests_total).to eq(99)

      Hyperion::Server.handle_static(:GET, '/q', "q\n")
      listener = TCPServer.new('127.0.0.1', 0)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.1

      # Entry resets the counter to 0 (no requests served yet).
      expect(Hyperion::Http::PageCache.c_loop_requests_total).to eq(0)

      Hyperion::Http::PageCache.stop_accept_loop
      listener.close
      thread.join(5)
    end
  end

  describe 'Server#dispatch_handed_off (regression for partial.present? Rails-ism)' do
    # 2.12-E — `Server#dispatch_handed_off` checked `partial.present?` —
    # a Rails-only method. On plain Ruby this raised NoMethodError on
    # every C-loop handoff that carried bytes (e.g. /-/metrics scraped
    # against a `handle_static`-only server). The audit harness needs
    # /-/metrics to work; without the fix, the metric the audit relies
    # on cannot be read. This spec drives the path directly through
    # the dispatch helper to lock down the contract.
    around do |ex|
      Hyperion::Runtime.reset_default!
      ex.run
      Hyperion::Runtime.reset_default!
    end

    before do
      Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
      Hyperion::Http::PageCache.clear if defined?(Hyperion::Http::PageCache)
    end

    it 'does not raise when the handoff carries a non-empty partial buffer' do
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['handed off']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen

      # Build a real fd via a connected pair; dispatch_handed_off wraps
      # it in a Socket and runs the inline-no-pool Connection path.
      a, b = ::UNIXSocket.pair
      partial = "GET /handed-off HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n"
      a.write(partial)
      a.close_write

      expect do
        # Drive the handoff with the bytes that triggered the original
        # NoMethodError ("present?" on a String).
        server.send(:dispatch_handed_off, b.fileno, partial.dup)
      end.not_to raise_error

      begin
        a.close
      rescue StandardError
        nil
      end
      server.stop
    end

    it 'does not raise when partial is nil (no pre-read bytes)' do
      app = ->(_env) { [200, {}, ['ok']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen

      a, b = ::UNIXSocket.pair
      a.write("GET /no-partial HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")
      a.close_write

      expect do
        server.send(:dispatch_handed_off, b.fileno, nil)
      end.not_to raise_error

      begin
        a.close
      rescue StandardError
        nil
      end
      server.stop
    end
  end
end
