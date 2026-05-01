# frozen_string_literal: true

module Hyperion
  # Renders Hyperion.stats as Prometheus text exposition format (v0.0.4).
  # Mounted by AdminMiddleware on GET /-/metrics; the returned content-type
  # is `text/plain; version=0.0.4; charset=utf-8`.
  #
  # Mapping rules:
  # - keys listed in KNOWN_METRICS get their canonical name + curated HELP/TYPE
  # - keys matching `responses_<3-digit>` are grouped under a single
  #   `hyperion_responses_status_total` family with a `status` label
  # - any other key is auto-exported as `hyperion_<key>` with a generic HELP
  #   line, so newly-added counters surface in Prometheus without code changes
  #   here (the curated-name path is just nicer presentation, not gating)
  #
  # Output ordering is deterministic for stable scrape diffs:
  # - known metrics in KNOWN_METRICS declaration order
  # - status codes ascending
  # - other keys alphabetically
  module PrometheusExporter
    module_function

    KNOWN_METRICS = {
      requests: { name: 'hyperion_requests_total',
                  help: 'Total HTTP requests handled',
                  type: 'counter' },
      bytes_read: { name: 'hyperion_bytes_read_total',
                    help: 'Total bytes read from request sockets',
                    type: 'counter' },
      bytes_written: { name: 'hyperion_bytes_written_total',
                       help: 'Total bytes written to response sockets',
                       type: 'counter' },
      rejected_connections: { name: 'hyperion_rejected_connections_total',
                              help: 'Connections rejected due to backpressure (max_pending)',
                              type: 'counter' },
      sendfile_responses: { name: 'hyperion_sendfile_responses_total',
                            help: 'Responses sent via plain-TCP sendfile(2) zero-copy path',
                            type: 'counter' },
      tls_zerobuf_responses: { name: 'hyperion_tls_zerobuf_responses_total',
                               help: 'Responses sent via TLS IO.copy_stream (avoids userspace String build, but TLS encryption forces copy)',
                               type: 'counter' }
    }.freeze

    STATUS_KEY_PATTERN = /\Aresponses_(\d{3})\z/

    STATUS_FAMILY_NAME = 'hyperion_responses_status_total'
    STATUS_FAMILY_HELP = 'Responses by HTTP status code'

    # 2.4-C: curated HELP/TYPE preamble for the new histogram + gauge +
    # labeled-counter families. Looking up by name keeps the rendered
    # scrape body human-friendly even when the caller registered the
    # family from a deep code path with no docstring.
    METRIC_DOCS = {
      hyperion_request_duration_seconds: {
        help: 'HTTP request duration in seconds, by route template + method + status class',
        type: 'histogram'
      },
      hyperion_websocket_deflate_ratio: {
        help: 'WebSocket permessage-deflate compression ratio (original_bytes / compressed_bytes)',
        type: 'histogram'
      },
      hyperion_per_conn_rejections_total: {
        help: 'Per-connection in-flight cap rejections (503 + Retry-After), by worker',
        type: 'counter'
      },
      hyperion_tls_ktls_active_connections: {
        help: 'Active TLS connections currently driven by kernel TLS_TX, by worker',
        type: 'gauge'
      },
      hyperion_io_uring_workers_active: {
        help: 'Whether io_uring accept policy is active for this worker (1 = active, 0 = epoll)',
        type: 'gauge'
      },
      hyperion_threadpool_queue_depth: {
        help: 'In-flight count in the worker ThreadPool inbox (snapshot at scrape time)',
        type: 'gauge'
      },
      # 2.12-E — per-worker request counter for the SO_REUSEPORT
      # load-balancing audit. One series per worker (label_value =
      # `Process.pid.to_s`); ticks on every dispatched request from
      # every dispatch shape. Operators scrape /-/metrics N times in
      # cluster mode to gather distribution across workers.
      hyperion_requests_dispatch_total: {
        help: 'Requests dispatched per worker (PID-labeled), across all dispatch modes',
        type: 'counter'
      }
    }.freeze

    # 2.12-E — name of the per-worker request counter family. Hoisted to
    # a constant so the C-loop fold-in below stays declarative.
    REQUESTS_DISPATCH_TOTAL = :hyperion_requests_dispatch_total

    def render(stats)
      buf = +''
      grouped_status = {}
      other = {}
      known = {}

      stats.each do |key, value|
        if (match = key.to_s.match(STATUS_KEY_PATTERN))
          grouped_status[match[1]] = value
        elsif KNOWN_METRICS.key?(key)
          known[key] = value
        else
          other[key] = value
        end
      end

      # Known metrics first, in declaration order — gives the scrape a stable,
      # human-friendly preamble regardless of hash insertion order.
      KNOWN_METRICS.each do |key, meta|
        next unless known.key?(key)

        append_metric(buf, meta[:name], meta[:help], meta[:type], known[key])
      end

      unless grouped_status.empty?
        buf << "# HELP #{STATUS_FAMILY_NAME} #{STATUS_FAMILY_HELP}\n"
        buf << "# TYPE #{STATUS_FAMILY_NAME} counter\n"
        grouped_status.sort.each do |status, value|
          buf << %(#{STATUS_FAMILY_NAME}{status="#{status}"} #{value}\n)
        end
      end

      other.sort_by { |k, _| k.to_s }.each do |key, value|
        name = "hyperion_#{key}"
        append_metric(buf, name, 'Hyperion internal counter (auto-exported)', 'counter', value)
      end

      buf
    end

    # 2.4-C — render histograms, gauges, and labeled counters from a live
    # Metrics instance. Called by AdminMiddleware in addition to `render`
    # so /-/metrics surfaces the full 2.4-C observability surface in one
    # scrape body. Order: legacy counters first (existing render), then
    # histograms, gauges, labeled counters — each curated families first,
    # auto-exported last, alphabetical within each section so scrape
    # diffs stay stable.
    def render_full(metrics_sink)
      buf = +''
      buf << render(metrics_sink.snapshot)
      buf << render_histograms(metrics_sink.histogram_snapshot)
      buf << render_gauges(metrics_sink.gauge_snapshot)
      labeled = metrics_sink.labeled_counter_snapshot
      # 2.12-E — fold in the C-loop counter ONLY for the process-wide
      # default Metrics sink (the one the C accept loop's served
      # requests are conceptually attributed to). Arbitrary spec-only
      # `Metrics.new` fixtures aren't connected to the C loop, so
      # surfacing a process-global atomic on them would let a counter
      # bumped by a previous test leak into a "fresh-sink, empty-body"
      # assertion. Production paths (AdminMiddleware,
      # AdminListener) read `Hyperion.metrics` which IS the default
      # sink, so the fold-in still fires there.
      labeled = merge_c_loop_into_dispatch_snapshot(labeled) if owns_c_loop_counter?(metrics_sink)
      buf << render_labeled_counters(labeled)
      buf
    end

    def owns_c_loop_counter?(metrics_sink)
      return false unless defined?(::Hyperion::Runtime)

      metrics_sink.equal?(::Hyperion::Runtime.default.metrics)
    rescue StandardError
      false
    end

    # 2.12-E — merge `Hyperion::Http::PageCache.c_loop_requests_total`
    # (process-global atomic ticked by the C accept4 + io_uring loops)
    # into the `hyperion_requests_dispatch_total{worker_id=PID}` series
    # for the current worker. Without this fold-in, a `-w 4` cluster
    # serving from the C accept loop would scrape zeros from every
    # worker even though the loop's atomic counter is ticking — the
    # loop bypasses `Connection#serve`, so no Ruby-side
    # `tick_worker_request` call ever lands.
    #
    # Idempotent on snapshots that already contain a series for the
    # current PID (the Connection-served + h2 requests from this same
    # worker are added to the C-loop count). Pure on the input — we
    # build a deep-enough copy of the snapshot so the live Hash
    # behind `Metrics#labeled_counter_snapshot` isn't mutated.
    #
    # Defensive: when the C ext isn't loaded (JRuby / TruffleRuby) we
    # silently skip — the snapshot stays Ruby-only.
    def merge_c_loop_into_dispatch_snapshot(snap)
      c_loop_count = c_loop_requests_total
      return snap if c_loop_count <= 0

      pid_label = Process.pid.to_s
      family = snap[REQUESTS_DISPATCH_TOTAL] || {
        meta: { label_keys: %w[worker_id].freeze },
        series: {}
      }
      merged_series = family[:series].dup
      key = [pid_label].freeze
      existing_key = merged_series.keys.find { |k| k.first == pid_label } || key
      merged_series[existing_key] = (merged_series[existing_key] || 0) + c_loop_count

      merged = snap.dup
      merged[REQUESTS_DISPATCH_TOTAL] = {
        meta: family[:meta] || { label_keys: %w[worker_id].freeze },
        series: merged_series
      }
      merged
    end

    def c_loop_requests_total
      return 0 unless defined?(::Hyperion::Http::PageCache)
      return 0 unless ::Hyperion::Http::PageCache.respond_to?(:c_loop_requests_total)

      ::Hyperion::Http::PageCache.c_loop_requests_total.to_i
    rescue StandardError
      # The scrape path must never raise — observability code degrades
      # to "no fold-in" rather than failing the metrics endpoint.
      0
    end

    def render_histograms(snap)
      buf = +''
      snap.each do |name, payload|
        meta   = payload[:meta]
        series = payload[:series]
        next if meta.nil?

        doc = METRIC_DOCS[name] || { help: 'Hyperion histogram', type: 'histogram' }
        buf << "# HELP #{name} #{doc[:help]}\n"
        buf << "# TYPE #{name} histogram\n"
        series.each do |label_values, snap_data|
          render_histogram_series(buf, name, meta[:label_keys], label_values, snap_data)
        end
      end
      buf
    end

    def render_gauges(snap)
      buf = +''
      snap.each do |name, payload|
        series = payload[:series]
        meta   = payload[:meta] || { label_keys: [].freeze }
        doc = METRIC_DOCS[name] || { help: 'Hyperion gauge', type: 'gauge' }
        buf << "# HELP #{name} #{doc[:help]}\n"
        buf << "# TYPE #{name} gauge\n"
        series.each do |label_values, value|
          buf << render_labeled_value(name, meta[:label_keys], label_values, value)
        end
      end
      buf
    end

    def render_labeled_counters(snap)
      buf = +''
      snap.each do |name, payload|
        series = payload[:series]
        meta   = payload[:meta] || { label_keys: [].freeze }
        doc = METRIC_DOCS[name] || { help: 'Hyperion labeled counter', type: 'counter' }
        buf << "# HELP #{name} #{doc[:help]}\n"
        buf << "# TYPE #{name} counter\n"
        series.each do |label_values, value|
          buf << render_labeled_value(name, meta[:label_keys], label_values, value)
        end
      end
      buf
    end

    def render_histogram_series(buf, name, label_keys, label_values, snap_data)
      buckets = snap_data[:buckets]
      counts  = snap_data[:counts]
      label_keys ||= []
      label_keys = label_keys.size != label_values.size ? %w[method path status][0, label_values.size] : label_keys
      base_pairs = label_keys.zip(label_values)
      buckets.each_with_index do |edge, idx|
        pairs = base_pairs + [['le', format_float(edge)]]
        buf << "#{name}_bucket#{labels_block(pairs)} #{counts[idx]}\n"
      end
      pairs_inf = base_pairs + [['le', '+Inf']]
      buf << "#{name}_bucket#{labels_block(pairs_inf)} #{snap_data[:count]}\n"
      buf << "#{name}_sum#{labels_block(base_pairs)} #{snap_data[:sum]}\n"
      buf << "#{name}_count#{labels_block(base_pairs)} #{snap_data[:count]}\n"
    end

    def render_labeled_value(name, label_keys, label_values, value)
      label_keys ||= []
      label_keys = label_keys.size == label_values.size ? label_keys : default_label_keys(label_values.size)
      pairs = label_keys.zip(label_values)
      "#{name}#{labels_block(pairs)} #{value}\n"
    end

    def default_label_keys(n)
      Array.new(n) { |i| "label_#{i}" }
    end

    def labels_block(pairs)
      return '' if pairs.empty?

      inside = pairs.map { |k, v| %(#{k}="#{escape_label(v.to_s)}") }.join(',')
      "{#{inside}}"
    end

    def escape_label(value)
      out = +''
      value.each_char do |c|
        out << case c
               when '\\' then '\\\\'
               when '"'  then '\\"'
               when "\n" then '\\n'
               else
                 c
               end
      end
      out
    end

    # Render histogram bucket edges with a stable representation. Integer-
    # valued floats stay as `2.5` (not `2.5000000000000004`); fractional
    # ones round to 6 places, plenty for scrape stability.
    def format_float(v)
      f = v.to_f
      f == f.to_i ? f.to_i.to_s : format('%.6g', f)
    end

    def append_metric(buf, name, help, type, value)
      buf << "# HELP #{name} #{help}\n"
      buf << "# TYPE #{name} #{type}\n"
      buf << "#{name} #{value}\n"
    end
    private_class_method :append_metric
  end
end
