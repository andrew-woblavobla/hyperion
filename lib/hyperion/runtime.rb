# frozen_string_literal: true

module Hyperion
  # Runtime services container — holds per-process or per-server services
  # (metrics sink, logger, clock) that used to live as module-level
  # singletons on `Hyperion`.
  #
  # Pre-1.7 every Connection / Http2Handler / ResponseWriter reached for
  # `Hyperion.metrics` / `Hyperion.logger` directly. That made:
  #
  #   1. Long-lived keep-alive connections impossible to swap services on
  #      mid-flight — `Connection#initialize` cached the singletons in ivars
  #      and never re-read them.
  #   2. Multi-tenant apps unable to give each `Hyperion::Server` its own
  #      metrics sink — the module-level singleton is process-global.
  #   3. Tests messy: stubbing `Hyperion.metrics` is global state mutation
  #      that bleeds across examples unless every spec resets explicitly.
  #
  # 1.7.0 introduces this Runtime and adds a `runtime:` kwarg to `Server`
  # and `Connection`. The default is `Runtime.default`, a process-wide
  # singleton — back-compat with the 1.6.x behaviour. Tests and library
  # users construct their own `Runtime.new(metrics: …, logger: …)` and
  # pass it explicitly; that runtime is then used exclusively by the
  # connection/server it was given to.
  #
  # `Runtime.default` is intentionally NOT frozen after first read.
  # RFC §5 Q4: tests need to swap metrics/logger on the default runtime,
  # and freezing for no real safety benefit just adds ceremony.
  #
  # Module-level `Hyperion.metrics` / `Hyperion.logger` (and their
  # writers) keep working — they delegate to `Runtime.default`. They're
  # marked for deprecation in 1.8.0 and removal in 2.0.
  class Runtime
    attr_reader :clock
    attr_writer :metrics, :logger

    # The default Runtime's metrics / logger readers honour module-level
    # ivar overrides on `Hyperion` itself. This preserves a back-compat
    # seam for 1.6.x specs that swap by reaching into private internals
    # via `Hyperion.instance_variable_set(:@metrics, …)` — the new
    # Runtime-routed code paths (Server / Connection / Http2Handler) all
    # read `runtime.metrics`, so without this the override would only
    # affect the legacy `Hyperion.metrics` reader and the new code path
    # would still write to the original Runtime-owned object.
    #
    # Custom Runtimes (`Hyperion::Runtime.new(...)`) ignore the override
    # entirely — they're per-Server isolated by design.
    def metrics
      override = Hyperion.instance_variable_get(:@metrics) if default?
      override || @metrics
    end

    def logger
      override = Hyperion.instance_variable_get(:@logger) if default?
      override || @logger
    end

    # True when this runtime is `Runtime.default`. The default runtime
    # is the one consulted by legacy module-level accessors — see the
    # `metrics` / `logger` readers above.
    def default?
      Runtime.instance_variable_get(:@default).equal?(self)
    end

    # Process-wide default Runtime. Lazily initialized on first read.
    # Module-level `Hyperion.metrics` / `Hyperion.logger` accessors and
    # writers all delegate to this instance, so legacy callers in 1.6.x
    # shape (`Hyperion.metrics = MyAdapter.new`) keep working without
    # any source change.
    #
    # Tests can mutate `Runtime.default.metrics = …` directly or replace
    # the whole default with `Runtime.default = Runtime.new(...)` (writer
    # below). Resetting between examples is on the test author — there's
    # no auto-reset because the singleton is part of the public surface.
    def self.default
      @default ||= new
    end

    # Test seam: replace the process-wide default. Used in specs that
    # need to inject a known-state Runtime without reaching into
    # `@default` directly.
    def self.default=(runtime)
      raise ArgumentError, 'expected a Hyperion::Runtime' unless runtime.is_a?(Runtime)

      @default = runtime
    end

    # Test seam: clear the memoized default so the next `default` call
    # builds a fresh one. Equivalent to `default = Runtime.new` but
    # without forcing the caller to allocate.
    def self.reset_default!
      @default = nil
    end

    def initialize(metrics: nil, logger: nil, clock: Process)
      @metrics = metrics || Hyperion::Metrics.new
      @logger  = logger  || Hyperion::Logger.new
      @clock   = clock
      # 2.5-C: per-request lifecycle hooks. Pre-allocated empty Arrays so
      # `has_request_hooks?` can be a single `any?` check on each side
      # — no nil-guard, no lazy-init branch on the hot path. Hooks are
      # appended in registration order; FIFO dispatch.
      @before_request_hooks = []
      @after_request_hooks  = []
    end

    # 2.5-C — register a Proc to fire AFTER env is built but BEFORE
    # `app.call`. Receives `(request, env)` where `request` is the
    # parsed `Hyperion::Request` and `env` is the mutable Rack env Hash
    # — callbacks may stash trace context (NewRelic transactions,
    # OpenTelemetry spans, AppSignal/DataDog handles) into the env so
    # the corresponding after-hook can finish them.
    #
    # Hook errors are caught and logged; they DO NOT abort dispatch.
    # Multiple hooks fire in registration order (FIFO).
    def on_request_start(&block)
      raise ArgumentError, 'block required' unless block

      @before_request_hooks << block
      block
    end

    # 2.5-C — register a Proc to fire AFTER `app.call` returns or
    # raises. Receives `(request, env, response, error)`:
    #
    #   * `response` is the `[status, headers, body]` tuple when the
    #     app returned normally, or `nil` when the app raised.
    #   * `error` is the `StandardError` the app raised, or `nil` on
    #     success.
    #
    # Use this to finish trace spans, attach response codes to the
    # active transaction, increment per-route counters, etc. Hook
    # errors are caught and logged — they never break dispatch.
    def on_request_end(&block)
      raise ArgumentError, 'block required' unless block

      @after_request_hooks << block
      block
    end

    # 2.5-C — zero-cost guard used by Adapter::Rack#call. When both
    # arrays are empty (the default — no hooks registered), the
    # adapter skips the dispatch entirely: no Array iteration, no
    # Proc invocation, no allocation. The audit harness
    # (`yjit_alloc_audit_spec`) verifies the per-request alloc count
    # is unchanged from 2.5-B.
    def has_request_hooks?
      !@before_request_hooks.empty? || !@after_request_hooks.empty?
    end

    # 2.5-C — invoked by Adapter::Rack#call after env is built. Wraps
    # each hook in a rescue so a misbehaving observer can't break the
    # dispatch chain — failures are logged with the block's source
    # location so operators can identify which hook went wrong.
    def fire_request_start(request, env)
      @before_request_hooks.each do |hook|
        hook.call(request, env)
      rescue StandardError => e
        log_hook_failure(:before_request, hook, e)
      end
      nil
    end

    # 2.5-C — invoked by Adapter::Rack#call after `app.call` returns
    # (or raises). `response` is the [status, headers, body] tuple on
    # success, `nil` on error; `error` is the raised exception or nil.
    # Same rescue contract as `fire_request_start`: each hook runs
    # independently; one failure does not prevent later hooks from
    # firing or the response from being written.
    def fire_request_end(request, env, response, error)
      @after_request_hooks.each do |hook|
        hook.call(request, env, response, error)
      rescue StandardError => e
        log_hook_failure(:after_request, hook, e)
      end
      nil
    end

    private

    def log_hook_failure(phase, hook, error)
      file, line = hook.source_location
      logger.error do
        {
          message: 'request lifecycle hook raised',
          phase: phase,
          hook_source: file ? "#{file}:#{line}" : 'unknown',
          error: error.message,
          error_class: error.class.name,
          backtrace: (error.backtrace || []).first(5).join(' | ')
        }
      end
    end
  end
end
