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
        o.on('-h', '--help', 'show help') do
          puts o
          exit 0
        end
      end
      parser.parse!(argv)

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

      # Propagate log_requests so every Connection picks it up via
      # `Hyperion.log_requests?` without needing to thread it through
      # Server/ThreadPool/Master plumbing. Default is ON; nil means "don't
      # touch — fall through to the env/default chain in Hyperion.log_requests?".
      Hyperion.log_requests = config.log_requests unless config.log_requests.nil?

      rackup = argv.first || 'config.ru'
      abort("[hyperion] no such rackup file: #{rackup}") unless File.exist?(rackup)

      if config.fiber_local_shim
        Hyperion::FiberLocal.install!
        Hyperion.logger.info { { message: 'FiberLocal shim installed' } }
      end

      app = load_rack_app(rackup)
      workers = config.workers.zero? ? Etc.nprocessors : config.workers

      if workers <= 1
        run_single(config, app)
      else
        run_cluster(config, app, workers)
      end
    end

    def self.run_single(config, app)
      tls = build_tls_from_config(config)
      server = Server.new(host: config.host, port: config.port, app: app,
                          tls: tls, thread_count: config.thread_count,
                          read_timeout: config.read_timeout)
      server.listen
      scheme = tls ? 'https' : 'http'
      Hyperion.logger.info { { message: 'listening', url: "#{scheme}://#{server.host}:#{server.port}" } }
      warn_c_parser_unavailable

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
