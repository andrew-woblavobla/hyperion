# frozen_string_literal: true

module Hyperion
  # Mutable configuration container — populated by the DSL evaluator
  # (Hyperion::Config.load) and then read by CLI / Server / Master / Worker /
  # Connection / Logger.
  #
  # All settings have safe defaults that match the per-class DEFAULT_* constants
  # so that running Hyperion without a config file works identically to the
  # pre-rc14 behaviour.
  class Config
    DEFAULTS = {
      host: '127.0.0.1',
      port: 9292,
      workers: 1,
      thread_count: 5,
      tls_cert: nil,
      tls_key: nil,
      read_timeout: 30,
      idle_keepalive: 5,
      graceful_timeout: 30,
      max_header_bytes: 64 * 1024,
      max_body_bytes: 16 * 1024 * 1024,
      log_level: nil, # nil → Logger picks from env / default
      log_format: nil, # nil → Logger picks via auto rule
      log_requests: nil, # nil → Hyperion.log_requests? (default true)
      fiber_local_shim: false,
      yjit: nil, # nil → auto: enable on production/staging; true/false to force.
      worker_max_rss_mb: nil, # Integer, e.g. 1024. When a worker exceeds this RSS in MB, master gracefully cycles it. nil disables.
      worker_check_interval: 30, # Seconds between RSS polls. Tradeoff: tighter = faster recycle, more ps calls. 30s matches Puma WorkerKiller.
      admin_token: nil, # String. When set, exposes admin endpoints (POST /-/quit triggers graceful drain; GET /-/metrics returns Prometheus-format Hyperion.stats). Same token guards both. nil disables admin entirely (paths fall through to the app).
      max_pending: nil, # Integer, e.g. 256. When the per-worker accept inbox has this many queued connections, additional accepts are rejected with HTTP 503 + Retry-After:1 instead of being queued. nil disables (current behaviour: unbounded queue).
      max_request_read_seconds: 60, # Numeric. Total wallclock budget (seconds) for reading the request line + headers + body for ONE request. Defends against slowloris-style drips that satisfy the per-recv read_timeout but never finish the request. Resets between requests on a keep-alive connection. nil disables.
      async_io: nil, # Three-way: nil (default, auto: inline on TLS h1 / pool on plain HTTP/1.1), true (force inline-on-fiber for plain HTTP/1.1 too — required for fiber-cooperative I/O like hyperion-async-pg on plain HTTP), false (force pool hop everywhere — explicit opt-out for operators who specifically want TLS+threadpool with CPU-bound handlers). Costs ~5% throughput on hello-world when inline; in exchange one OS thread can serve N concurrent in-flight DB queries on wait-bound workloads. TLS / HTTP/2 paths always run the Async accept loop regardless of this flag.
      h2_max_concurrent_streams: 128, # HTTP/2 SETTINGS_MAX_CONCURRENT_STREAMS — cap on simultaneously-open streams per connection. Falcon: 64. nil leaves protocol-http2 default (0xFFFFFFFF).
      h2_initial_window_size: 1_048_576, # HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE (octets) — flow-control window per stream at open. Bigger = fewer WINDOW_UPDATE round-trips on large bodies. Spec default is 65535. nil → leave protocol default.
      h2_max_frame_size: 1_048_576, # HTTP/2 SETTINGS_MAX_FRAME_SIZE (octets) — biggest DATA/HEADERS frame we'll accept. Spec floor 16384, ceiling 16777215. We pick 1 MiB to match common CDNs without unbounded buffer growth. nil → leave protocol default (16384).
      h2_max_header_list_size: 65_536 # HTTP/2 SETTINGS_MAX_HEADER_LIST_SIZE (octets) — advisory cap on the decompressed header block. Bounds memory of pathological client headers. nil → leave protocol default (unbounded).
    }.freeze

    HOOKS = %i[before_fork on_worker_boot on_worker_shutdown].freeze

    attr_accessor(*DEFAULTS.keys)
    attr_reader(*HOOKS)

    def initialize
      DEFAULTS.each { |k, v| public_send(:"#{k}=", v) }
      HOOKS.each { |h| instance_variable_set(:"@#{h}", []) }
    end

    HOOKS.each do |hook|
      define_method(:"add_#{hook}") do |&block|
        instance_variable_get(:"@#{hook}") << block if block
      end
    end

    # Load a Ruby DSL config file. Returns the populated Config.
    # Path is the operator-supplied --config argument; we evaluate it in a
    # DSL context that maps method calls to attribute setters.
    def self.load(path)
      cfg = new
      contents = File.read(path)
      DSL.new(cfg).instance_eval(contents, path)
      cfg
    end

    # Apply CLI overrides on top of an existing config. Only non-nil values
    # in `overrides` are applied — preserves the precedence ordering
    # (CLI > env > config file > default).
    def merge_cli!(overrides)
      overrides.each do |key, value|
        next if value.nil?

        public_send(:"#{key}=", value) if respond_to?(:"#{key}=")
      end
      self
    end

    # DSL receiver. Each method call on the DSL maps to a Config setter or
    # to a hook registration. Unknown methods raise NoMethodError so typos
    # surface immediately at boot rather than as silent ignores.
    class DSL
      def initialize(config)
        @config = config
      end

      # `bind` is the Puma-style alias for `host` — operators expect it.
      def bind(value)
        @config.host = value
      end

      Config::DEFAULTS.each_key do |key|
        define_method(key) do |value|
          @config.public_send(:"#{key}=", value)
        end
      end

      Config::HOOKS.each do |hook|
        define_method(hook) do |&block|
          @config.public_send(:"add_#{hook}", &block)
        end
      end

      # `tls_cert_path` / `tls_key_path` are convenience aliases that read
      # the file off disk so the DSL stays terse. The parsed cert/key are
      # stored on the config and Server consumes them directly.
      def tls_cert_path(path)
        require 'openssl'
        @config.tls_cert = OpenSSL::X509::Certificate.new(File.read(path))
      end

      def tls_key_path(path)
        require 'openssl'
        @config.tls_key = OpenSSL::PKey.read(File.read(path))
      end
    end
  end
end
