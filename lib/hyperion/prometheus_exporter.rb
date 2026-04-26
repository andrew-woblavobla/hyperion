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

    def append_metric(buf, name, help, type, value)
      buf << "# HELP #{name} #{help}\n"
      buf << "# TYPE #{name} #{type}\n"
      buf << "#{name} #{value}\n"
    end
    private_class_method :append_metric
  end
end
