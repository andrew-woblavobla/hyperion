# frozen_string_literal: true

require 'etc'
require 'openssl'
require 'optparse'
require 'rack'
require_relative '../hyperion'

module Hyperion
  class CLI
    DEFAULT_CONFIG_PATH = 'config/hyperion.rb'

    def self.run(argv)
      cli_opts, config_path = parse_argv!(argv)

      # Precedence: CLI > config file > built-in default. We auto-load
      # config/hyperion.rb if present so operators can drop a file in their
      # repo and have it take effect without having to remember -C.
      config_path ||= DEFAULT_CONFIG_PATH if File.exist?(DEFAULT_CONFIG_PATH)
      config = config_path ? Hyperion::Config.load(config_path) : Hyperion::Config.new
      config.merge_cli!(cli_opts)

      # Install logger early so every subsequent log call honours the operator's
      # chosen format/level (config file or CLI) before anything else logs.
      if config.log_level || config.log_format
        Hyperion.logger = Hyperion::Logger.new(level: config.log_level, format: config.log_format)
      end

      # Advisory: operators frequently flip --async-io expecting "fast mode"
      # without installing a fiber-cooperative I/O library. On hello-world this
      # costs ~5% rps; on no-I/O workloads more. The flag only pays off when
      # paired with `hyperion-async-pg` / `async-redis` / `async-http`. We log
      # once at boot pointing at the operator-guidance docs; the operator's
      # setting is still honoured.
      warn_orphan_async_io(config)

      # Propagate log_requests so every Connection picks it up via
      # `Hyperion.log_requests?` without needing to thread it through
      # Server/ThreadPool/Master plumbing. Default is ON; nil means "don't
      # touch — fall through to the env/default chain in Hyperion.log_requests?".
      Hyperion.log_requests = config.log_requests unless config.log_requests.nil?

      # Enable YJIT before workers fork / connections start. Auto-on in
      # production/staging gives operators the perf bump for free; explicit
      # config.yjit (true/false) overrides the env-based default.
      maybe_enable_yjit(config)

      rackup = argv.first || 'config.ru'
      abort("[hyperion] no such rackup file: #{rackup}") unless File.exist?(rackup)

      if config.fiber_local_shim
        # Gate on async_io: with no fibers in play the shim has no purpose
        # and patching `thread_variable_*` would re-stage the 1.4.x bug
        # (stranded Logger/Metrics counters across thread-pool jobs running
        # in distinct fibers). FiberLocal.install! itself enforces this and
        # warns when ignored — we mirror the gate here for the success log.
        Hyperion::FiberLocal.install!(async_io: config.async_io == true)
        Hyperion.logger.info { { message: 'FiberLocal shim installed' } } if Hyperion::FiberLocal.installed?
      end

      app = load_rack_app(rackup)
      app = wrap_admin_middleware(app, config)
      workers = config.workers.zero? ? Etc.nprocessors : config.workers

      if workers <= 1
        run_single(config, app)
      else
        run_cluster(config, app, workers)
      end
    end

    # Extracted from #run so the flag-to-cli_opts mapping can be unit-tested
    # without booting a server. Returns [cli_opts, config_path]. Mutates argv
    # in place (consumes flags, leaves the rackup path for the caller).
    def self.parse_argv!(argv)
      cli_opts    = {}
      config_path = nil

      parser = OptionParser.new do |o|
        o.banner = 'Usage: hyperion [options] config.ru'
        o.on('-C', '--config PATH', "Hyperion config file (default ./#{DEFAULT_CONFIG_PATH} if it exists)") do |p|
          config_path = p
        end
        o.on('-b', '--bind HOST', 'host (default 127.0.0.1)') { |h| cli_opts[:host] = h }
        o.on('-p', '--port PORT', Integer, 'port (default 9292)') { |p| cli_opts[:port] = p }
        o.on('-w', '--workers N', Integer, 'worker processes (0 = nprocessors)') { |w| cli_opts[:workers] = w }
        o.on('-t', '--threads N', Integer, 'Rack handler thread pool size (0 disables)') do |t|
          cli_opts[:thread_count] = t
        end
        o.on('--tls-cert PATH', 'TLS certificate (PEM; chained intermediates supported)') do |p|
          # Parse every BEGIN/END block in the file — production certs ship
          # as leaf+intermediate(s) bundled together. `OpenSSL::X509::Certificate.new`
          # only reads the first block, so loading via that single call would
          # silently drop the chain. See Hyperion::TLS.parse_pem_chain.
          certs = Hyperion::TLS.parse_pem_chain(File.read(p))
          abort("[hyperion] no certificates found in #{p}") if certs.empty?

          cli_opts[:tls_cert]  = certs.first
          cli_opts[:tls_chain] = certs[1..]
        end
        o.on('--tls-key PATH', 'TLS private key (PEM)') do |p|
          cli_opts[:tls_key] = OpenSSL::PKey.read(File.read(p))
        end
        o.on('--log-level LEVEL', %w[debug info warn error fatal], 'log level (default info)') do |l|
          cli_opts[:log_level] = l.to_sym
        end
        o.on('--log-format FORMAT', %w[text json auto],
             'log format: text | json | auto (default auto: json on RAILS_ENV/RACK_ENV=production, colored text on TTY, json otherwise)') do |f|
          cli_opts[:log_format] = f.to_sym
        end
        o.on('--[no-]log-requests',
             'Per-request access log line (default ON; pass --no-log-requests to disable).') do |v|
          cli_opts[:log_requests] = v
        end
        o.on('--fiber-local-shim', 'Patch Thread.current[] to be fiber-local (Rails-compat for older gems)') do
          cli_opts[:fiber_local_shim] = true
        end
        o.on('--[no-]yjit',
             'Enable Ruby YJIT (default: auto on RAILS_ENV/RACK_ENV=production/staging)') do |v|
          cli_opts[:yjit] = v
        end
        o.on('--[no-]async-io',
             'Run plain HTTP/1.1 connections under Async::Scheduler (required for hyperion-async-pg and other fiber-cooperative I/O; default off)') do |v|
          cli_opts[:async_io] = v
        end
        o.on('--max-body-bytes BYTES', Integer,
             'Maximum request body size in bytes (default 16777216 = 16 MiB)') do |n|
          cli_opts[:max_body_bytes] = n
        end
        o.on('--max-header-bytes BYTES', Integer,
             'Maximum total request-header size in bytes (default 65536 = 64 KiB)') do |n|
          cli_opts[:max_header_bytes] = n
        end
        o.on('--max-pending COUNT', Integer,
             'Maximum queued connections per worker before new accepts are rejected with 503 (default unbounded)') do |n|
          cli_opts[:max_pending] = n
        end
        o.on('--max-request-read-seconds SECONDS', Float,
             'Total wallclock budget for reading request line + headers + body (default 60.0; 0 disables)') do |n|
          cli_opts[:max_request_read_seconds] = n
        end
        # Security-sensitive: read the token verbatim and never echo it back
        # in any subsequent log/help line. argv is visible via `ps` on most
        # systems; production deployments should prefer --admin-token-file.
        o.on('--admin-token TOKEN',
             "Bearer token for the /-/quit and /-/metrics admin endpoints. \
WARNING: argv is visible via `ps`; prefer --admin-token-file PATH for production.") do |t|
          cli_opts[:admin_token] = t
        end
        o.on('--admin-token-file PATH',
             'Read the admin token from a file. File must NOT be world-readable (perms must mask 0o007).') do |p|
          cli_opts[:admin_token] = read_admin_token_file(p)
        end
        o.on('--worker-max-rss-mb MB', Integer,
             'Recycle a worker when its RSS exceeds MB megabytes (default unset; nil disables)') do |n|
          cli_opts[:worker_max_rss_mb] = n
        end
        o.on('--idle-keepalive SECONDS', Float,
             'Idle keep-alive timeout in seconds (default 5.0)') do |n|
          cli_opts[:idle_keepalive] = n
        end
        o.on('--graceful-timeout SECONDS', Integer,
             'Graceful shutdown deadline in seconds before SIGKILL (default 30)') do |n|
          cli_opts[:graceful_timeout] = n
        end
        o.on('-h', '--help', 'show help') do
          puts o
          exit 0
        end
      end
      parser.parse!(argv)

      [cli_opts, config_path]
    end

    def self.run_single(config, app)
      tls = build_tls_from_config(config)
      server = Server.new(host: config.host, port: config.port, app: app,
                          tls: tls, thread_count: config.thread_count,
                          read_timeout: config.read_timeout,
                          max_pending: config.max_pending,
                          max_request_read_seconds: config.max_request_read_seconds,
                          h2_settings: Master.build_h2_settings(config),
                          async_io: config.async_io)
      server.listen
      scheme = tls ? 'https' : 'http'
      Hyperion.logger.info { { message: 'listening', url: "#{scheme}://#{server.host}:#{server.port}" } }
      warn_c_parser_unavailable

      # Pre-allocate Rack env-pool entries and eager-touch lazy constants.
      # In single-mode there's no fork, but the warmup still pays for itself
      # by frontloading the first-N-request allocation cost off the first
      # real client. Idempotent — safe to call once per process.
      Hyperion.warmup!

      # Single-worker mode reuses the lifecycle hooks: before_fork is a no-op
      # here (no fork happens), and on_worker_boot/on_worker_shutdown fire
      # for the lone in-process "worker" so app code that opens DB pools etc.
      # gets the same lifecycle whether you run 1 or N workers.
      config.on_worker_boot.each { |h| h.call(0) }

      shutdown_r, shutdown_w = IO.pipe
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          shutdown_w.write_nonblock('!')
        rescue StandardError
          nil
        end
      end

      shutdown_thread = Thread.new do
        shutdown_r.read(1)
        server.stop
      end
      shutdown_thread.report_on_exception = false

      server.start
      shutdown_thread.join
      config.on_worker_shutdown.each { |h| h.call(0) }
      # Drain per-thread access buffers + sync stdio. Single-worker mode
      # doesn't go through Master#shutdown_children, so without this call
      # buffered access lines + final shutdown messages can be lost on
      # SIGTERM. See Hyperion::Logger#flush_all.
      Hyperion.logger.flush_all
    end

    def self.run_cluster(config, app, workers)
      tls = build_tls_from_config(config)
      Master.new(host: config.host, port: config.port, app: app,
                 workers: workers, tls: tls, thread_count: config.thread_count,
                 read_timeout: config.read_timeout, config: config).run
    end

    # Rack 3's parse_file returns a single app value; Rack 2 returned [app, options].
    # Normalize so we get just the app either way.
    def self.load_rack_app(path)
      result = ::Rack::Builder.parse_file(path)
      result.is_a?(Array) ? result.first : result
    end
    private_class_method :load_rack_app

    def self.build_tls_from_config(config)
      return nil unless config.tls_cert || config.tls_key

      abort('[hyperion] tls_cert and tls_key must be supplied together') unless config.tls_cert && config.tls_key

      { cert: config.tls_cert, key: config.tls_key }
    end
    private_class_method :build_tls_from_config

    # Decide whether to enable YJIT and flip the switch once at boot.
    # Precedence:
    #   1. config.yjit explicitly true/false  → honour exactly.
    #   2. config.yjit nil (default)          → auto: on for production/staging.
    # No-op on Rubies without YJIT (e.g. JRuby/TruffleRuby) and idempotent if
    # the operator already passed `ruby --yjit` upstream.
    def self.maybe_enable_yjit(config)
      return unless defined?(::RubyVM::YJIT)
      return if ::RubyVM::YJIT.enabled?

      enable = if config.yjit.nil?
                 env_name = ENV['HYPERION_ENV'] || ENV['RAILS_ENV'] || ENV['RACK_ENV']
                 %w[production staging].include?(env_name)
               else
                 config.yjit
               end

      return unless enable

      ::RubyVM::YJIT.enable
      Hyperion.logger.info do
        { message: 'YJIT enabled', mode: config.yjit.nil? ? 'auto' : 'explicit' }
      end
    end
    private_class_method :maybe_enable_yjit

    # Probe table for fiber-cooperative I/O libraries. If `async_io: true` is
    # set but none of these are loaded, the operator has likely flipped the
    # flag without reading the bench numbers — `--async-io` adds Async-loop
    # overhead and only pays off when paired with a library whose I/O calls
    # yield to the scheduler. Hello-world bench (BENCH_2026_04_27.md) showed
    # a 47% rps regression + 3.65 s p99 spike on this shape.
    ASYNC_IO_PROBE_LIBS = {
      'hyperion-async-pg' => -> { defined?(::Hyperion::AsyncPg) },
      'async-redis' => -> { defined?(::Async::Redis) },
      'async-http' => -> { defined?(::Async::HTTP) }
    }.freeze

    def self.warn_orphan_async_io(config)
      return unless config.async_io == true # nil and false are both no-ops here

      detected = ASYNC_IO_PROBE_LIBS.select { |_name, probe| probe.call }.keys
      return unless detected.empty?

      Hyperion.logger.warn do
        {
          message: 'async_io enabled but no fiber-cooperative I/O library detected',
          libraries_checked: ASYNC_IO_PROBE_LIBS.keys,
          impact: 'async_io adds Async-loop overhead (~5-47% rps depending on workload) and only pays off when paired with a library that yields to the Async scheduler on socket waits.',
          docs: 'https://github.com/andrew-woblavobla/hyperion#operator-guidance'
        }
      end
    end
    private_class_method :warn_orphan_async_io

    # When admin_token is configured, wrap the app in AdminMiddleware so
    # POST /-/quit and GET /-/metrics become token-protected admin endpoints.
    # Skipped when the token is unset — those paths fall through to the app,
    # so apps may still own /-/anything if Hyperion's admin is off.
    def self.wrap_admin_middleware(app, config)
      return app if config.admin_token.nil? || config.admin_token.to_s.empty?

      Hyperion.logger.info do
        { message: 'admin endpoint enabled',
          paths: [AdminMiddleware::PATH_QUIT, AdminMiddleware::PATH_METRICS] }
      end
      AdminMiddleware.new(app, token: config.admin_token)
    end
    private_class_method :wrap_admin_middleware

    # Read the admin token from a file on disk. Refuses to load if the file
    # is missing, unreadable, or world-readable — the whole point of using a
    # file instead of `--admin-token` is to keep the token off argv (which
    # `ps` exposes) and off other-user-readable storage. Trailing whitespace
    # is stripped so operators can use `echo "$TOKEN" > /etc/hyperion-token`
    # without inadvertently embedding a newline. Empty files abort.
    def self.read_admin_token_file(path)
      abort("[hyperion] admin token file not found: #{path}") unless File.file?(path)
      abort("[hyperion] admin token file not readable: #{path}") unless File.readable?(path)

      mode = File.stat(path).mode & 0o777
      if (mode & 0o007).positive?
        abort("[hyperion] admin token file #{path} is world-readable (mode #{format('%04o', mode)}); chmod 600")
      end

      token = File.read(path).strip
      abort("[hyperion] admin token file is empty: #{path}") if token.empty?

      token
    end
    private_class_method :read_admin_token_file

    # Warn loudly at boot if the C parser didn't load — operators running
    # production with the pure-Ruby fallback are paying ~2× CPU on parse-heavy
    # workloads and probably don't know it.
    def self.warn_c_parser_unavailable
      return if Hyperion.c_parser_available?

      Hyperion.logger.warn do
        {
          message: 'llhttp C parser not loaded — using pure-Ruby fallback (slower)',
          remediation: 'rebuild the gem with `bundle exec rake compile` or check your OpenSSL/build-essential install'
        }
      end
    end
    private_class_method :warn_c_parser_unavailable
  end
end
