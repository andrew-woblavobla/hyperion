# frozen_string_literal: true

module Hyperion
  # 1.8.0 deprecation-warn helper. RFC §3 requires a one-shot warn per
  # deprecated API call site / key per process — emitted via the runtime
  # logger when available, falling back to $stderr at very-early boot
  # (before `Hyperion::Runtime.default.logger` is reachable).
  #
  # The deprecated APIs themselves keep working untouched in 1.8.0; the
  # warn is purely informational. Removal lands in 2.0.0 per the RFC §3
  # release plan.
  #
  # Tests that trip the deprecation paths intentionally can capture the
  # output by swapping `Hyperion::Runtime.default.logger`; tests that
  # want silence call `Deprecations.silence!` in a `before(:each)` and
  # `Deprecations.reset!` in `after(:each)` to start with a clean slate.
  module Deprecations
    @warned = {}
    @silenced = false
    MUTEX = Mutex.new

    module_function

    # Emit a one-shot deprecation warn for `key`. Subsequent calls with
    # the same key in the same process are no-ops. Thread-safe (the
    # check-and-record runs under a Mutex) so two workers initializing
    # at once don't double-emit on the same key.
    def warn_once(key, message)
      return if @silenced

      MUTEX.synchronize do
        return if @warned[key]

        @warned[key] = true
      end

      emit("[hyperion] DEPRECATION: #{message}")
    end

    # Test seam: clear the dedup table so a spec can re-trigger a warn
    # it just exercised. Combined with `silence!`/`unsilence!` tests can
    # both assert the dedup behaviour and avoid noise on baseline runs.
    def reset!
      MUTEX.synchronize { @warned.clear }
    end

    # Test seam: suppress all warns until `unsilence!` is called. Used
    # by the broad test suite which intentionally exercises the
    # deprecated DSL surface and would otherwise flood output.
    def silence!
      @silenced = true
    end

    def unsilence!
      @silenced = false
    end

    def silenced?
      @silenced
    end

    # Visibility for assertion: did we already warn on `key`?
    def warned?(key)
      MUTEX.synchronize { @warned.key?(key) }
    end

    def emit(line)
      logger = Hyperion::Runtime.default.logger if defined?(Hyperion::Runtime)
      if logger.respond_to?(:warn)
        logger.warn { { message: 'deprecation', detail: line } }
      else
        warn(line)
      end
    rescue StandardError
      # Logger swap mid-emit / very-early boot — fall back to $stderr so
      # the operator at least sees something on the console.
      warn(line)
    end
    private_class_method :emit
  end
end
