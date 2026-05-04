# frozen_string_literal: true

# 2.16.1 — macOS fork-safety. Mirrors the guard at the top of
# `bin/hyperion` so programmatic `require 'hyperion'` (specs,
# embedded uses) gets the same workaround. The Obj-C runtime's
# post-fork check crashes workers that touch a Foundation class
# which was mid-init in the master at fork time (NSCharacterSet
# is a frequent victim — it loads transitively via OpenSSL / system
# resolver paths). `||=` so an operator who has set the var
# explicitly is honoured. No-op on non-darwin platforms.
ENV['OBJC_DISABLE_INITIALIZE_FORK_SAFETY'] ||= 'YES' if RUBY_PLATFORM.include?('darwin')

require_relative 'hyperion/version'
require_relative 'hyperion/logger'
require_relative 'hyperion/metrics'
require_relative 'hyperion/runtime'
require_relative 'hyperion/deprecations'
require_relative 'hyperion/dispatch_mode'
require_relative 'hyperion/config'
require_relative 'hyperion/h2_admission'

module Hyperion
  class Error < StandardError; end
  class ParseError < Error; end
  class UnsupportedError < Error; end

  # Probe table for fiber-cooperative I/O libraries. 1.7.0 expanded
  # the validation surface (RFC A9): `async_io: true` now requires at
  # least one of these to be loaded, otherwise CLI bootstrap raises
  # at `Hyperion.validate_async_io_loaded_libs!`. The CLI's pre-fork
  # `warn_orphan_async_io` (1.6.1) still emits a soft warn for the
  # nil-default case so existing operators see the same advisory log.
  FIBER_IO_PROBES = {
    'hyperion-async-pg' => -> { defined?(::Hyperion::AsyncPg) },
    'async-redis' => -> { defined?(::Async::Redis) },
    'async-http' => -> { defined?(::Async::HTTP) }
  }.freeze

  class << self
    # 2.0.0: legacy module-level `Hyperion.metrics =` / `Hyperion.logger =`
    # SETTERS are removed. The getters stay as Runtime.default delegators —
    # they're the canonical REPL convenience — and assignment now happens
    # via the Runtime API:
    #
    #   Hyperion::Runtime.default.metrics = MyAdapter.new   # mutate default
    #   server = Hyperion::Server.new(app:, runtime: Hyperion::Runtime.new(metrics: …))
    #
    # The 1.8.0 deprecation warns called this out for one full release;
    # in-tree spec rewrites flipped to `Runtime.default.metrics =` already.
    def logger
      Runtime.default.logger
    end

    attr_writer :log_requests

    def metrics
      Runtime.default.metrics
    end

    def stats
      metrics.snapshot
    end

    # Whether YJIT is currently enabled in this Ruby process. False on Rubies
    # that don't ship YJIT (JRuby, TruffleRuby) and on CRuby builds compiled
    # without YJIT support. Cheap (no allocations) — safe to call from hot
    # paths if needed for diagnostics.
    def yjit_enabled?
      defined?(::RubyVM::YJIT) && ::RubyVM::YJIT.enabled?
    end

    # Whether the llhttp C extension loaded. False on JRuby/TruffleRuby and
    # any environment where extconf.rb / make failed at install time. The
    # pure-Ruby parser handles those cases correctly but is ~2× slower on
    # parse-heavy workloads. Operators running production should confirm this
    # returns true; CLI emits a startup banner if it doesn't.
    def c_parser_available?
      defined?(::Hyperion::CParser) && ::Hyperion::CParser.respond_to?(:build_response_head)
    end

    # Per-request access logging is ON by default — matches Puma/Rails operator
    # expectations (Rails::Rack::Logger emits one line per request out of the
    # box). Operators can disable it via `--no-log-requests`,
    # `HYPERION_LOG_REQUESTS=0|false|no|off`, or programmatically via
    # `Hyperion.log_requests = false`. When false, Connection skips ALL
    # access-log work — no Process.clock_gettime, no hash build, nothing.
    #
    # The hot path uses Logger#access (single-interpolation line build,
    # per-thread cached timestamp, lock-free emit) so default-ON throughput
    # stays well above Puma's default-OFF baseline.
    def log_requests?
      return @log_requests unless @log_requests.nil?

      env = ENV['HYPERION_LOG_REQUESTS']&.downcase
      @log_requests =
        case env
        when '0', 'false', 'no', 'off' then false
        when '1', 'true', 'yes', 'on'  then true
        else true # default ON
        end
    end

    # Pre-fork warmup. Run by Master and CLI single-mode BEFORE children are
    # forked (or before the lone worker starts accepting). Pre-allocates the
    # Rack adapter's object pools and eager-touches lazily-resolved constants
    # so each forked child inherits warm memory via copy-on-write — the first
    # N requests on a fresh worker no longer pay the allocation / autoload
    # tax that would otherwise serialize behind the GVL on cold start.
    #
    # Idempotent — second and later calls are no-ops. Failures are swallowed
    # with a warn log: warmup is an optimization, not a correctness gate.
    # If, for instance, OpenSSL can't be required in some odd environment,
    # we'd rather start cold than refuse to boot.
    # PID of the Hyperion master process. Writable so the master records its
    # own PID at boot; readable everywhere so AdminMiddleware (and other
    # would-be signallers) can target the master regardless of context.
    #
    # Why not `Process.ppid`? Two reasons:
    #
    #   1. In single-worker mode, the "master" and "worker" are the same
    #      process; `Process.ppid` points to the shell / init that launched
    #      hyperion, NOT to ourselves.
    #   2. When the master runs as PID 1 inside containerd / Docker (the
    #      default for `hyperion` as a container CMD), `Process.ppid` from a
    #      worker is `1` — but the worker IS a child of PID 1, so `kill`ing
    #      ppid signals the master correctly only by accident, and the
    #      pre-1.6.3 fallback `ppid > 1 ? ppid : Process.pid` would
    #      MIS-target the worker itself. (Repro: `docker run -e
    #      HYPERION_ADMIN_TOKEN=… hyperion` then `curl -X POST /-/quit` —
    #      response says draining, nothing happens.)
    #
    # The master sets this at boot (cluster: Master#run, single: CLI.run_single)
    # AND exports `HYPERION_MASTER_PID` into ENV so forked workers read the
    # correct value via copy-on-write. The reader prefers the in-process
    # ivar (faster) and falls back to ENV (cross-fork) and finally to
    # `Process.pid` (last-resort: someone constructed AdminMiddleware before
    # the master booted, or in a non-Hyperion test context).
    def master_pid
      return @master_pid if @master_pid

      env = ENV['HYPERION_MASTER_PID']
      env_pid = env && env =~ /\A\d+\z/ ? env.to_i : nil
      env_pid&.positive? ? env_pid : Process.pid
    end

    # Record the master PID and export it for forked workers. Called once
    # by the master at boot. Workers inherit ENV via fork; the worker's own
    # `master_pid` ivar stays nil and its reader falls back to ENV.
    def master_pid!(pid = Process.pid)
      @master_pid = pid
      ENV['HYPERION_MASTER_PID'] = pid.to_s
      pid
    end

    # Returns the list of currently-loaded fiber-cooperative I/O
    # libraries. Reads `Hyperion::FIBER_IO_PROBES` via `const_get` so
    # `stub_const('Hyperion::FIBER_IO_PROBES', ...)` works for the
    # strict-validation specs without needing a method-injection seam.
    def fiber_io_libs_loaded
      probes = Hyperion.const_get(:FIBER_IO_PROBES)
      probes.select { |_name, probe| probe.call }.keys
    end

    # Strict tri-state validation of `async_io` at warmup time (RFC A9).
    # Run after `Hyperion.warmup!`'s eager-load section so any library
    # that monkey-patches in fiber-cooperative I/O during boot has had
    # the chance to install itself.
    #
    # - `true`  → MUST have at least one fiber-IO library loaded; raise
    #            ArgumentError otherwise. The error message lists the
    #            checked libraries so operators can pick one.
    # - `false` → No fiber-IO library should be loaded; if one is, emit
    #            a warn (the operator may still want this for some
    #            edge case, so we don't raise).
    # - `nil`   → Default. The CLI's existing soft-warn path covers
    #            this; warmup is a no-op.
    def validate_async_io_loaded_libs!(setting)
      probes = Hyperion.const_get(:FIBER_IO_PROBES)
      case setting
      when true
        loaded = fiber_io_libs_loaded
        if loaded.empty?
          raise ArgumentError,
                'async_io: true requires a fiber-cooperative I/O library to be loaded ' \
                "(checked: #{probes.keys.join(', ')}); none detected. " \
                'See https://github.com/andrew-woblavobla/hyperion#operator-guidance'
        end
      when false
        loaded = fiber_io_libs_loaded
        unless loaded.empty?
          Hyperion.logger.warn do
            {
              message: 'async_io: false but fiber-cooperative I/O library is loaded',
              loaded: loaded,
              impact: 'the library will not yield to a scheduler under async_io: false; verify this is intentional'
            }
          end
        end
      end
      nil
    end

    def warmup!
      return if @warmed

      @warmed = true

      if defined?(::Hyperion::Adapter::Rack) && ::Hyperion::Adapter::Rack.respond_to?(:warmup_pool)
        ::Hyperion::Adapter::Rack.warmup_pool(8)
      end

      # Touch the C extension's response-head builder so its lazily-initialized
      # internal state runs in the master, not in every child after fork.
      ::Hyperion::CParser.respond_to?(:build_response_head) if defined?(::Hyperion::CParser)

      # Eager-load TLS / SSLSocket. The sendfile path's `is_a?` check would
      # otherwise trigger autoload in the worker on the first TLS response.
      require 'openssl'
      defined?(::OpenSSL::SSL::SSLSocket) && ::OpenSSL::SSL::SSLSocket.name

      # Force Ruby's tzinfo / strftime-cache load by emitting one httpdate.
      # Subsequent calls hit the per-thread `cached_date` slot in response_writer.
      Time.now.httpdate
      nil
    rescue ArgumentError
      # Strict-validation error from `validate_async_io_loaded_libs!` —
      # propagate so operators see the boot-time abort, not a warn-and-
      # continue.
      raise
    rescue StandardError => e
      Hyperion.logger.warn { { message: 'warmup failed (non-fatal)', error: e.message } }
      nil
    end

    # Test seam: clear the warmup flag so a fresh `warmup!` call can
    # re-run. Used by the async_io strict-validation specs that need to
    # exercise the raise/warn paths multiple times in one process.
    def reset_warmup!
      @warmed = false
    end
  end
end

# Runtime guard: warn early if the host app pulled openssl 4.x in despite the
# gemspec pin. Some Rails apps mutate `OpenSSL::SSL::SSLContext::DEFAULT_PARAMS`
# (e.g. the AWS SDK pattern that injects ciphers); 4.0 froze that hash, so the
# mutation now raises FrozenError on boot. We don't fix the host app — we just
# point at the source so the operator doesn't think it's a Hyperion bug.
if defined?(::OpenSSL::VERSION) &&
   ::Gem::Version.new(::OpenSSL::VERSION) >= ::Gem::Version.new('4.0.0') &&
   ::OpenSSL::SSL::SSLContext::DEFAULT_PARAMS.frozen?
  Hyperion.logger.warn do
    {
      message: 'openssl froze SSLContext::DEFAULT_PARAMS — apps mutating that hash crash on boot',
      openssl_version: ::OpenSSL::VERSION,
      remediation: 'pin openssl < 4.0 in your Gemfile until the upstream initializer is updated'
    }
  end
end

require_relative 'hyperion/pool'
require_relative 'hyperion/fiber_local'
require_relative 'hyperion/request'
require_relative 'hyperion/parser'
require_relative 'hyperion/c_parser'
require_relative 'hyperion/http/sendfile'
require_relative 'hyperion/http/page_cache'
require_relative 'hyperion/static_preload'
require_relative 'hyperion/adapter/rack'
require_relative 'hyperion/lint_wrapper_pool'
require_relative 'hyperion/prometheus_exporter'
require_relative 'hyperion/admin_middleware'
require_relative 'hyperion/admin_listener'
require_relative 'hyperion/h2_codec'
require_relative 'hyperion/io_uring'
require_relative 'hyperion/response_writer'
require_relative 'hyperion/thread_pool'
require_relative 'hyperion/connection'
require_relative 'hyperion/tls'
require_relative 'hyperion/http2_handler'
require_relative 'hyperion/server'
require_relative 'hyperion/worker'
require_relative 'hyperion/worker_health'
require_relative 'hyperion/master'
