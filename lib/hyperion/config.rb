# frozen_string_literal: true

module Hyperion
  # Mutable configuration container — populated by the DSL evaluator
  # (Hyperion::Config.load) and then read by CLI / Server / Master / Worker /
  # Connection / Logger.
  #
  # All settings have safe defaults that match the per-class DEFAULT_* constants
  # so that running Hyperion without a config file works identically to the
  # pre-rc14 behaviour.
  #
  # 1.7.0 (RFC A4): grouped settings move into nested subconfigs —
  # `config.h2.*`, `config.admin.*`, `config.worker_health.*`,
  # `config.logging.*`. The flat top-level setters keep working without
  # any deprecation warn (warns land in 1.8.0; removal in 2.0). Flat
  # writes proxy into the nested object, and the legacy `attr_accessor`
  # generated `Config#h2_max_concurrent_streams` etc. read back from
  # the same place — there's only one source of truth per setting.
  class Config
    # Top-level (un-nested) defaults. Flat fields that don't group
    # naturally are deliberately kept here per the RFC's "only 8 fields
    # warrant nesting in A4" guidance — `max_pending`, `idle_keepalive`,
    # `graceful_timeout`, the `tls_*` family, `read_timeout`, and the
    # body/header byte caps stay flat.
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
      fiber_local_shim: false,
      yjit: nil, # nil → auto: enable on production/staging; true/false to force.
      max_pending: nil,
      max_request_read_seconds: 60,
      async_io: nil, # nil/true/false (validated strictly in 1.7.0+ via Server constructor).
      accept_fibers_per_worker: 1 # RFC A6 — opt-in multi-fiber accept under :reuseport.
    }.freeze

    HOOKS = %i[before_fork on_worker_boot on_worker_shutdown].freeze

    # Plain top-level accessors. Subconfigs (h2/admin/worker_health/logging)
    # and their flat-forwarder methods are defined further below.
    attr_accessor(*DEFAULTS.keys)
    attr_reader(*HOOKS)

    # Nested subconfig readers. The DSL exposes them as block forms
    # (`h2 do |h| ... end`) and the legacy flat forms (`h2_max_concurrent_streams 256`)
    # both write into the same backing object.
    attr_reader :h2, :admin, :worker_health, :logging, :tls

    # H2 settings subconfig. RFC 7540 §6.5.2 settings + the new-in-1.7
    # per-process `max_total_streams` admission cap (RFC A7).
    class H2Settings
      ATTRS = %i[max_concurrent_streams initial_window_size max_frame_size
                 max_header_list_size max_total_streams].freeze
      attr_accessor(*ATTRS)

      def initialize
        @max_concurrent_streams = 128
        @initial_window_size    = 1_048_576
        @max_frame_size         = 1_048_576
        @max_header_list_size   = 65_536
        @max_total_streams      = nil # RFC A7 — opt-in 1.7; default flips in 2.0.
      end
    end

    # Admin endpoint subconfig. `token` was `admin_token` in 1.6.x;
    # `listener_port` / `listener_host` are new-in-1.7 (RFC A8 sibling
    # listener; default nil keeps admin mounted in-app via AdminMiddleware).
    class AdminConfig
      ATTRS = %i[token listener_port listener_host].freeze
      attr_accessor(*ATTRS)

      def initialize
        @token         = nil
        @listener_port = nil
        @listener_host = '127.0.0.1'
      end
    end

    # Worker health subconfig. `max_rss_mb` recycles a worker that
    # exceeds the configured RSS; `check_interval` is the poll period
    # in seconds. The new `timeout` field is reserved for 1.8+ worker-
    # heartbeat work; ships now so operators can pre-configure.
    class WorkerHealthConfig
      ATTRS = %i[max_rss_mb check_interval timeout].freeze
      attr_accessor(*ATTRS)

      def initialize
        @max_rss_mb     = nil
        @check_interval = 30
        @timeout        = nil
      end
    end

    # Logging subconfig. `level` / `format` mirror the 1.6.x flat
    # setters; `requests` is the new home for `log_requests`. nil =
    # delegate to `Hyperion.log_requests?` (env + default ON).
    class LoggingConfig
      ATTRS = %i[level format requests].freeze
      attr_accessor(*ATTRS)

      def initialize
        @level    = nil
        @format   = nil
        @requests = nil
      end
    end

    # TLS subconfig. New in 1.8.0 (Phase 4 — TLS session resumption).
    # `session_cache_size` controls the size of the in-process server-
    # side session cache used to short-circuit the full handshake when a
    # client returns with a previously-issued session id. The default of
    # 20_480 is sized for ~16 MiB of cache memory at 800 B/session — well
    # under the workload-default 128 MiB worker RSS cap.
    #
    # `ticket_key_rotation_signal` selects the OS signal that triggers
    # a session-cache flush + ticket-key roll on the master. `:USR2`
    # (default) is conventional for "rotate keys" signals (nginx uses
    # SIGUSR2 for binary-upgrade, but here it's the rotation event).
    # Set to `:NONE` to disable rotation entirely (workloads that don't
    # care about ticket-key rotation security guarantees).
    class TlsConfig
      ATTRS = %i[session_cache_size ticket_key_rotation_signal].freeze
      attr_accessor(*ATTRS)

      DEFAULT_SESSION_CACHE_SIZE = 20_480
      DEFAULT_ROTATION_SIGNAL    = :USR2

      def initialize
        @session_cache_size         = DEFAULT_SESSION_CACHE_SIZE
        @ticket_key_rotation_signal = DEFAULT_ROTATION_SIGNAL
      end
    end

    # Map flat setter name → [subconfig accessor, nested attribute].
    # Used by both the flat-named DSL methods and the `Config#xxx=`
    # forwarders below so there's one source of truth.
    FLAT_TO_NESTED = {
      h2_max_concurrent_streams: %i[h2 max_concurrent_streams],
      h2_initial_window_size: %i[h2 initial_window_size],
      h2_max_frame_size: %i[h2 max_frame_size],
      h2_max_header_list_size: %i[h2 max_header_list_size],
      h2_max_total_streams: %i[h2 max_total_streams],
      admin_token: %i[admin token],
      admin_listener_port: %i[admin listener_port],
      admin_listener_host: %i[admin listener_host],
      worker_max_rss_mb: %i[worker_health max_rss_mb],
      worker_check_interval: %i[worker_health check_interval],
      log_level: %i[logging level],
      log_format: %i[logging format],
      log_requests: %i[logging requests]
    }.freeze

    # Pre-rendered "use the nested DSL instead" snippet per flat key.
    # Computed once at load time so the deprecation warn doesn't pay a
    # string-build cost on every flat-DSL invocation.
    FLAT_TO_NESTED_DEPRECATION = FLAT_TO_NESTED.each_with_object({}) do |(flat, (group, nested)), h|
      h[flat] = "use `#{group} do |#{group[0]}|; #{group[0]}.#{nested} = ...; end` instead — " \
                "flat `#{flat}` removed in 2.0"
    end.freeze

    def initialize
      DEFAULTS.each { |k, v| public_send(:"#{k}=", v) }
      HOOKS.each { |h| instance_variable_set(:"@#{h}", []) }
      @h2            = H2Settings.new
      @admin         = AdminConfig.new
      @worker_health = WorkerHealthConfig.new
      @logging       = LoggingConfig.new
      @tls           = TlsConfig.new
    end

    # Generate flat-name forwarders so callers reading
    # `config.h2_max_concurrent_streams` (Master#build_h2_settings used
    # to do this) get the value back from the nested object. Same for
    # writes — they proxy into the nested config.
    FLAT_TO_NESTED.each do |flat, (group, nested)|
      define_method(flat) do
        public_send(group).public_send(nested)
      end

      define_method(:"#{flat}=") do |value|
        public_send(group).public_send(:"#{nested}=", value)
      end
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
    #
    # 1.7.0 (RFC A4) added nested block forms — `h2 do |h| ... end` and
    # the bare-block `worker_health do; max_rss_mb 1024; end` shape. The
    # flat `h2_max_concurrent_streams 256` form keeps working untouched
    # in 1.7; deprecation warn lands in 1.8, removal in 2.0.
    class DSL
      def initialize(config)
        @config = config
      end

      # `bind` is the Puma-style alias for `host` — operators expect it.
      def bind(value)
        @config.host = value
      end

      # Top-level flat setters. We define them dynamically off the
      # DEFAULTS hash so adding a new top-level field auto-wires the DSL.
      Config::DEFAULTS.each_key do |key|
        define_method(key) do |value|
          @config.public_send(:"#{key}=", value)
        end
      end

      # Flat-name forwarders for the soon-to-be-nested settings (RFC A4).
      # Pre-1.7 these were generated off `attr_accessor`; now they go
      # through `Config#flat_setter=` which proxies into the nested
      # subconfig. The DSL surface is unchanged for operators on the
      # 1.6.x flat shape.
      #
      # 1.8.0 (RFC §3): each flat-DSL key now emits a one-shot
      # deprecation warn through `Hyperion::Deprecations`. Behaviour is
      # unchanged — the value still lands in the same nested slot. The
      # warn dedup key is the flat name itself, so each key warns once
      # per process regardless of how many config files / hot-reloads
      # call into it.
      Config::FLAT_TO_NESTED.each_key do |flat|
        message = Config::FLAT_TO_NESTED_DEPRECATION[flat]
        define_method(flat) do |value|
          ::Hyperion::Deprecations.warn_once(:"flat_dsl_#{flat}", message)
          @config.public_send(:"#{flat}=", value)
        end
      end

      Config::HOOKS.each do |hook|
        define_method(hook) do |&block|
          @config.public_send(:"add_#{hook}", &block)
        end
      end

      # Nested-block DSL — `h2 do |h| h.max_concurrent_streams 256 end`
      # OR `h2 do; max_concurrent_streams 256; end`. The block is
      # eval'd against a BlockProxy that proxies bareword method calls
      # into the subconfig's accessors; explicit-arg form (`|h|`) gives
      # callers the proxy directly so they can pass it around.
      %i[h2 admin worker_health logging tls].each do |group|
        define_method(group) do |&block|
          subconfig = @config.public_send(group)
          if block.nil?
            subconfig
          else
            proxy = BlockProxy.new(subconfig)
            if block.arity.zero? || block.arity.negative?
              proxy.instance_eval(&block)
            else
              block.call(proxy)
            end
            subconfig
          end
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

    # Block-form DSL proxy for nested subconfigs. Each bareword call
    # inside `h2 do; max_concurrent_streams 256; end` lands on this
    # proxy, which forwards into the wrapped subconfig's setter. Also
    # supports explicit-arg form `h2 do |h| h.max_concurrent_streams 256 end`
    # via the same accessor path. Unknown method names raise
    # NoMethodError — typos surface at boot, matching the top-level
    # DSL's strictness.
    #
    # Inherits from BasicObject so Ruby's `Kernel#format` / `Kernel#level`
    # / etc. don't shadow our subconfig setters when callers write
    # `logging do; format :json; end` — Kernel methods are absent on
    # BasicObject, so the bareword falls through to method_missing.
    class BlockProxy < BasicObject
      def initialize(target)
        @target = target
      end

      def method_missing(name, *args, &block)
        setter = :"#{name}="
        if @target.respond_to?(setter)
          # Single-arg sets (`max_concurrent_streams 256`) write the
          # value through. Zero-arg calls (`max_concurrent_streams`)
          # behave as readers — needed by the explicit-arg form so
          # `h.max_concurrent_streams` returns the current value.
          if args.length == 1
            @target.public_send(setter, args.first)
          elsif args.empty? && @target.respond_to?(name)
            @target.public_send(name)
          else
            ::Kernel.raise ::NoMethodError, "no DSL setter for #{name.inspect} on #{@target.class}"
          end
        elsif @target.respond_to?(name)
          @target.public_send(name, *args, &block)
        else
          ::Kernel.raise ::NoMethodError, "no DSL setter for #{name.inspect} on #{@target.class}"
        end
      end

      def respond_to_missing?(name, include_private = false)
        setter = :"#{name}="
        @target.respond_to?(setter) || @target.respond_to?(name, include_private)
      end

      # BasicObject lacks #class — provide it for tests + introspection.
      def class
        ::Hyperion::Config::BlockProxy
      end
    end
  end
end
