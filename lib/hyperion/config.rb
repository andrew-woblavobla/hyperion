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
  # 1.7.0 (RFC A4): grouped settings live in nested subconfigs —
  # `config.h2.*`, `config.admin.*`, `config.worker_health.*`,
  # `config.logging.*`. 1.7 added the nested DSL alongside the legacy
  # flat keys; 1.8 deprecation-warned the flat keys; 2.0 removed them.
  # The nested DSL is the only configuration surface — flat aliases
  # like `h2_max_concurrent_streams` no longer exist on the DSL or on
  # `Config` itself.
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
      accept_fibers_per_worker: 1, # RFC A6 — opt-in multi-fiber accept under :reuseport.
      # 2.3-A: io_uring accept policy (Linux 5.6+ only). Tri-state, mirrors `tls.ktls`:
      #   :off  — never use io_uring; epoll path always (2.3.0 default).
      #   :auto — use io_uring when supported; quietly fall back otherwise.
      #   :on   — demand it; raise at boot if unsupported.
      # Default flips to :auto in 2.4 only after soak. Operators flip on
      # via `HYPERION_IO_URING={on,auto}` env var to A/B test.
      io_uring: :off,
      # Plan #2 (perf roadmap) — io_uring hot path policy. Independent
      # gate from the accept-only `io_uring:` above. Tri-state:
      #   :off  — accept and read/write stay on the existing paths
      #           (default; no behavior change in 2.18 minor cut).
      #   :auto — engage when supported (Linux 5.19+ + buffer-ring
      #           registration succeeds); quietly fall back otherwise.
      #   :on   — demand it. Boot raises if unsupported.
      # Override at runtime via `HYPERION_IO_URING_HOTPATH={off,auto,on}`.
      io_uring_hotpath: :off,
      # 2.3-B: per-connection in-flight cap. nginx upstream keep-alive
      # pipelines many client requests through one upstream connection;
      # without this cap a single greedy upstream conn can hog the worker
      # thread pool and starve siblings. Tri-state:
      #   * Integer >= 1 — explicit cap (e.g., `4` for `-t 16`).
      #   * :auto         — `Config#finalize!` resolves to `thread_count / 4`
      #                     (rounded down, minimum 1). Operator opt-in.
      #   * nil (default) — no cap; matches 2.2.0 behaviour. Hyperion is
      #                     opt-in by default — the cap is a hardening tool
      #                     that operators turn on, not a default flip.
      max_in_flight_per_conn: nil,
      # 2.10-E: explicit `preload_static "/path"` DSL entries plus the
      # CLI's repeatable `--preload-static <dir>` flag accumulate here.
      # Each element is a `{path: String, immutable: Boolean}` Hash.
      # `Server#listen` walks the resolved list (which may also include
      # auto-detected Rails asset paths — see `auto_preload_static_disabled`)
      # and warms `Hyperion::Http::PageCache` before the accept loop spins.
      # Default empty so a vanilla Rack app pays nothing.
      preload_static_dirs: nil,
      # 2.10-E: when truthy, suppress the Rails-aware auto-detect path
      # (`Rails.configuration.assets.paths.first(N)`) at boot.  Set by
      # the `--no-preload-static` CLI flag; lets operators turn off
      # auto-warming on a Rails app while still keeping the option to
      # configure explicit dirs via `preload_static`.
      auto_preload_static_disabled: false,
      # 2.16: app preload toggle. When true (default) the master loads
      # `config.ru` once before forking — workers inherit the loaded app
      # via copy-on-write, the canonical Hyperion model. When false, the
      # master stays a thin supervisor and each worker parses `config.ru`
      # itself post-fork. Mirrors Puma's `preload_app! false` mode.
      #
      # The non-preload mode is the documented escape hatch for macOS
      # workloads where loading native gems in the master (anything that
      # initializes Network.framework / CoreFoundation via XPC) leaves
      # the post-fork resolver in a deadlocked state — `getaddrinfo`
      # hangs forever in `nw_path_evaluator_evaluate`. Setting `preload
      # false` keeps the master's address space free of those globals so
      # workers fork from a clean slate.
      #
      # Trade-off: each worker pays the boot cost (CPU + RSS) on its own,
      # so steady-state RSS is N× higher and worker boot is slower. Linux
      # users should leave this true.
      preload: true
    }.freeze

    HOOKS = %i[before_fork on_worker_boot on_worker_shutdown].freeze

    # Plain top-level accessors. Subconfigs (h2/admin/worker_health/logging)
    # and their flat-forwarder methods are defined further below.
    attr_accessor(*DEFAULTS.keys)
    attr_reader(*HOOKS)

    # Nested subconfig readers. The DSL exposes them as block forms
    # (`h2 do |h| ... end`) and the legacy flat forms (`h2_max_concurrent_streams 256`)
    # both write into the same backing object.
    attr_reader :h2, :admin, :worker_health, :logging, :tls, :websocket, :metrics

    # H2 settings subconfig. RFC 7540 §6.5.2 settings + the new-in-1.7
    # per-process `max_total_streams` admission cap (RFC A7).
    class H2Settings
      ATTRS = %i[max_concurrent_streams initial_window_size max_frame_size
                 max_header_list_size max_total_streams].freeze
      attr_accessor(*ATTRS)

      # 2.0 default for `max_total_streams`. The literal value `:auto`
      # is a deferred sentinel: `Config#finalize!` resolves it to
      # `max_concurrent_streams × workers × 4` once the worker count
      # is known. Operators wanting the pre-2.0 unbounded behaviour
      # write `:unbounded` (or `nil` after finalize); operators wanting
      # a fixed cap write a positive integer.
      AUTO = :auto
      UNBOUNDED = :unbounded

      def initialize
        @max_concurrent_streams = 128
        @initial_window_size    = 1_048_576
        @max_frame_size         = 1_048_576
        @max_header_list_size   = 65_536
        @max_total_streams      = AUTO # 2.0 default — finalize! resolves it.
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

    # 2.3-C: WebSocket subconfig. The headline knob is
    # `permessage_deflate` — RFC 7692 per-message DEFLATE compression
    # for the WS payload. Tri-state, mirrors `tls.ktls`:
    #   :off  — never advertise the extension.
    #   :auto — accept if the client offers it (default; backwards
    #           compatible with clients that don't offer it).
    #   :on   — require it; reject the handshake (400) if the client
    #           doesn't offer a usable variant.
    class WebSocketConfig
      ATTRS = %i[permessage_deflate].freeze
      attr_accessor(*ATTRS)

      DEFAULT_PERMESSAGE_DEFLATE = :auto

      def initialize
        @permessage_deflate = DEFAULT_PERMESSAGE_DEFLATE
      end
    end

    # 2.4-C: Metrics subconfig. The headline knob is `path_templater`,
    # which collapses raw request paths to low-cardinality templates
    # for the per-route latency histogram (operators with Rails-style
    # routes plug in their own templater). `enabled` flips the new
    # 2.4-C histogram/gauge surface as a whole — counters in the legacy
    # surface (requests, bytes_read, …) keep emitting regardless.
    class MetricsConfig
      ATTRS = %i[path_templater enabled].freeze
      attr_accessor(*ATTRS)

      def initialize
        @path_templater = nil # lazily defaulted to PathTemplater.new on first read
        @enabled        = true
      end

      def path_templater
        @path_templater ||= Hyperion::Metrics::PathTemplater.new
      end
    end

    # 2.3-B: top-level `:auto` sentinel for `max_in_flight_per_conn`.
    # `Config#finalize!` resolves to `thread_count / 4`, floor 1. Plain
    # symbol (no nested struct) because the only knob is the cap value.
    MAX_IN_FLIGHT_PER_CONN_AUTO = :auto

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
      ATTRS = %i[session_cache_size ticket_key_rotation_signal ktls handshake_rate_limit].freeze
      attr_accessor(*ATTRS)

      DEFAULT_SESSION_CACHE_SIZE = 20_480
      DEFAULT_ROTATION_SIGNAL    = :USR2
      # 2.2.0 (Phase 9): kernel TLS_TX policy.
      #   :auto — enable on Linux when supported, off elsewhere
      #   :on   — force enable; raise at boot if unsupported
      #   :off  — never enable, always use userspace SSL_write
      DEFAULT_KTLS               = :auto
      # 2.3-B: TLS handshake CPU throttle. Token-bucket budget for
      # SSL_accept calls per second per worker. Defends direct-exposure
      # operators against handshake storms (e.g., many short-lived TLS
      # clients reconnecting at once during a deployment). For the
      # nginx-fronted topology this is mostly defensive — nginx keeps
      # long-lived upstream conns so handshake rate is normally near-zero.
      #   * Integer >= 1 — handshakes/sec/worker (capacity == rate).
      #   * :unlimited (default) — no limit; matches 2.2.0 behaviour.
      DEFAULT_HANDSHAKE_RATE_LIMIT = :unlimited

      def initialize
        @session_cache_size         = DEFAULT_SESSION_CACHE_SIZE
        @ticket_key_rotation_signal = DEFAULT_ROTATION_SIGNAL
        @ktls                       = DEFAULT_KTLS
        @handshake_rate_limit       = DEFAULT_HANDSHAKE_RATE_LIMIT
      end
    end

    # CLI-only flat→nested setter map. The DSL surface no longer
    # honours these names (2.0 removed the flat DSL forwarders), but
    # `Config#merge_cli!` still receives flat-keyed cli_opts hashes
    # built by the OptionParser branches in `Hyperion::CLI`. Routing
    # them via this table keeps CLI flag spellings stable
    # (`--admin-token`, `--log-level`, …) without re-introducing the
    # deprecated DSL surface.
    CLI_FLAT_TO_NESTED = {
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
      log_requests: %i[logging requests],
      tls_handshake_rate_limit: %i[tls handshake_rate_limit]
    }.freeze

    def initialize
      DEFAULTS.each { |k, v| public_send(:"#{k}=", v) }
      HOOKS.each { |h| instance_variable_set(:"@#{h}", []) }
      @h2            = H2Settings.new
      @admin         = AdminConfig.new
      @worker_health = WorkerHealthConfig.new
      @logging       = LoggingConfig.new
      @tls           = TlsConfig.new
      @websocket     = WebSocketConfig.new
      @metrics       = MetricsConfig.new
      # 2.10-E: per-instance Array — DEFAULTS is frozen so we can't share
      # a literal `[]` across Config instances or every operator's DSL
      # `preload_static` call would mutate the same backing list.
      @preload_static_dirs = []
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

    # Sentinel surfaced through `Config#h2.max_total_streams` when the
    # operator hasn't touched the setting and 2.0's auto-default formula
    # ought to compute on their behalf at finalize time. The `nil` value
    # (RFC §3 1.7 default) used to mean "admission disabled forever";
    # 2.0 redefines `nil` as "auto" and adds an explicit
    # `H2Settings::UNBOUNDED` sentinel for operators who want the
    # pre-2.0 unbounded behaviour.
    #
    # The Auto path is a sentinel-only wire — `H2Settings#initialize` no
    # longer sets a hard `nil`; finalize! resolves it to
    # `max_concurrent_streams × workers × 4` and writes the result back
    # onto `h2.max_total_streams`. Operators reading the value before
    # finalize see the sentinel; after finalize see the resolved
    # integer.
    # Resolve any "auto" sentinels to concrete integers based on
    # finalized peer settings. Called once after `merge_cli!` and after
    # the worker count is known (Master#initialize / CLI run_single).
    # Idempotent — a finalized config can be re-finalized without
    # changing values.
    def finalize!(workers:)
      case @h2.max_total_streams
      when H2Settings::AUTO
        @h2.max_total_streams = compute_h2_max_total_streams(workers: workers)
      when H2Settings::UNBOUNDED
        @h2.max_total_streams = nil
      end
      # 2.3-B: resolve the `:auto` sentinel for the per-conn fairness
      # cap. `thread_count / 4` (floor 1) gives each conn at most 25% of
      # the worker's thread budget — the recommended default. Operators
      # who set an explicit integer at config time keep their value
      # untouched; nil (no cap, 2.2.0 default) is also preserved.
      @max_in_flight_per_conn = compute_max_in_flight_per_conn if @max_in_flight_per_conn == MAX_IN_FLIGHT_PER_CONN_AUTO
      self
    end

    # 2.0 default formula (RFC §3): per-conn cap × worker count × 4.
    # The 4× headroom factor assumes the average connection holds 25%
    # of the per-conn cap; well above realistic legitimate fan-out yet
    # still bounds the OOM abuse window (5k conns × 128 streams = 640k
    # fibers).
    def compute_h2_max_total_streams(workers:)
      cap_per_conn = @h2.max_concurrent_streams || H2Settings.new.max_concurrent_streams
      worker_count = (workers && workers.positive? ? workers : 1)
      cap_per_conn * worker_count * 4
    end

    # 2.3-B per-conn fairness default: `thread_count / 4`, floor 1.
    # Each conn caps at 25% of the worker's thread budget so a single
    # greedy upstream connection can't starve siblings. Floor of 1
    # ensures degenerate `-t 1` / `-t 2` / `-t 3` configurations still
    # serve traffic (cap 1 = strictly serial per conn, but no rejects
    # while no conn is currently dispatched).
    def compute_max_in_flight_per_conn
      threads = (@thread_count && @thread_count.positive? ? @thread_count : 1)
      cap = threads / 4
      cap = 1 if cap < 1
      cap
    end

    # Apply CLI overrides on top of an existing config. Only non-nil values
    # in `overrides` are applied — preserves the precedence ordering
    # (CLI > env > config file > default).
    #
    # 2.0.0: flat keys that map to a nested subconfig
    # (`admin_token` → `admin.token`, `log_level` → `logging.level`, …)
    # are dispatched through `CLI_FLAT_TO_NESTED`. The DSL no longer
    # accepts these names, but the CLI flag surface keeps its 1.x
    # spellings — operators don't have to learn a new flag set.
    #
    # 2.10-E: `:preload_static` is special-cased — it's an Array of dir
    # strings from the repeatable `--preload-static` flag, and we
    # APPEND each as `{path:, immutable: true}` to the already-populated
    # `preload_static_dirs` list. Operator config-file entries land
    # first; CLI flags win by being applied last.
    def merge_cli!(overrides)
      overrides.each do |key, value|
        next if value.nil?

        if key == :preload_static
          Array(value).each do |dir|
            preload_static_dirs << { path: dir.to_s, immutable: true }
          end
        elsif (route = CLI_FLAT_TO_NESTED[key])
          group, nested = route
          public_send(group).public_send(:"#{nested}=", value)
        elsif respond_to?(:"#{key}=")
          public_send(:"#{key}=", value)
        end
      end
      self
    end

    # 2.10-E — resolve the operator-supplied preload list, falling
    # through to Rails auto-detect when no explicit dirs are configured
    # AND auto-detect is not disabled by the operator. Always returns
    # an Array of `{path:, immutable:}` Hashes (possibly empty).
    #
    # Precedence:
    #   1. Operator-supplied (DSL `preload_static` or CLI flags) — used verbatim.
    #   2. Otherwise, Rails-detected paths if auto-detect is enabled.
    #   3. Otherwise, [] — no preload, 1.x cold-cache behaviour.
    def resolved_preload_static_dirs
      return preload_static_dirs.dup unless preload_static_dirs.empty?
      return [] if auto_preload_static_disabled

      Hyperion::StaticPreload.detect_rails_paths.map do |path|
        { path: path, immutable: true }
      end
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

      # 2.0.0: the flat DSL keys (`h2_max_concurrent_streams`, `admin_token`,
      # `log_format`, …) are removed. Operators must use the nested DSL
      # blocks defined below. Unknown DSL methods bubble up as
      # `NoMethodError` from the DSL evaluator — typos surface at boot.
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
      %i[h2 admin worker_health logging tls websocket metrics].each do |group|
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

      # 2.10-E — `preload_static "/path", immutable: true` DSL key.
      # Appends `{path:, immutable:}` onto `preload_static_dirs`. The
      # `immutable:` kwarg defaults to true — the whole point of preload
      # is "I promise these don't change without a restart" so the
      # immutable flag is the operator-friendly default. Multiple calls
      # accumulate.
      #
      # Overrides the auto-generated DEFAULTS-based setter for the
      # backing field (which would write the entire array via `=`); this
      # explicit method is the one the DSL actually exposes.
      def preload_static(path, immutable: true)
        @config.preload_static_dirs << { path: path.to_s, immutable: immutable }
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
