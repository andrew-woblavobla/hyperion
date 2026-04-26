# frozen_string_literal: true

require_relative 'hyperion/version'
require_relative 'hyperion/logger'
require_relative 'hyperion/metrics'
require_relative 'hyperion/config'

module Hyperion
  class Error < StandardError; end
  class ParseError < Error; end
  class UnsupportedError < Error; end

  class << self
    def logger
      @logger ||= Logger.new
    end

    attr_writer :logger, :log_requests

    def metrics
      @metrics ||= Metrics.new
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
require_relative 'hyperion/adapter/rack'
require_relative 'hyperion/admin_middleware'
require_relative 'hyperion/response_writer'
require_relative 'hyperion/thread_pool'
require_relative 'hyperion/connection'
require_relative 'hyperion/tls'
require_relative 'hyperion/http2_handler'
require_relative 'hyperion/server'
require_relative 'hyperion/worker'
require_relative 'hyperion/worker_health'
require_relative 'hyperion/master'
