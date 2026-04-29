# frozen_string_literal: true

module Hyperion
  # FiberLocal — tooling for fiber-local request scope under the Async scheduler.
  #
  # ## Background
  #
  # Under fiber-per-request concurrency (Hyperion Phase 2+, Falcon), all
  # in-flight requests share the same OS thread. Code that stores per-request
  # state on `Thread.current` would leak between requests.
  #
  # **Ruby 3.2+ already solves the most common case:** `Thread.current[:k] = v`
  # writes to FIBER-local storage, not thread-local storage. Each fiber's
  # `Thread.current[:k]` is independent. This is what Hyperion relies on.
  #
  # The remaining footgun is `Thread.current.thread_variable_set`, which IS
  # genuinely thread-shared and will leak across fiber-scheduled requests.
  # Old Rails code (< 7.0) sometimes used this. Modern Rails uses
  # `ActiveSupport::IsolatedExecutionState` (which routes to Fiber storage),
  # so well-maintained apps are not affected.
  #
  # ## What this module provides
  #
  # `Hyperion::FiberLocal.verify_environment!` — sanity check that the
  # current Ruby actually isolates `Thread.current[:k]` per-fiber. Raises if
  # not (which would only happen on Ruby < 3.2).
  #
  # `Hyperion::FiberLocal.install!(async_io:)` — opt-in monkey-patch that
  # routes `thread_variable_get`/`thread_variable_set` to fiber storage. Use
  # only if your app uses `thread_variable_set` for request scope under
  # fiber-per-request concurrency.
  #
  # ## 1.4.x compat — the regression this gates against
  #
  # 1.4.x fixed a bug where Hyperion's own Logger access buffer + Metrics
  # counters were stranded under `Async::Scheduler` because they were stored
  # on `Thread.current[:k]` (which is fiber-local in Ruby 3.2+). The fix
  # switched those to `Thread#thread_variable_*`, which is the only TRUE
  # thread-local storage in CRuby (commits f987462 + e8db450). A blanket
  # FiberLocal monkey-patch would re-route those calls to fiber storage and
  # restage the exact bug 1.4.x fixed. To stay compatible:
  #
  # 1. When `async_io` is OFF (the default — single-thread or thread-pool
  #    mode, no scheduler in play), `install!` is a no-op. The shim has no
  #    purpose without fibers, and patching only risks re-introducing the
  #    1.4.x stranded-counter bug if a thread pool ever runs job N and
  #    job N+1 in distinct fibers on the same OS thread.
  # 2. When `async_io` is ON, the patched `thread_variable_*` reserves the
  #    `__hyperion_*` symbol keys for true thread-local storage so Hyperion's
  #    Logger/Metrics keep aggregating correctly. Everything else routes to
  #    `Fiber.current.storage` for fiber-per-request isolation.
  module FiberLocal
    # Symbol keys with this prefix bypass the fiber-storage routing and use
    # the original `thread_variable_*` semantics. Hyperion's internal
    # Logger access buffer + ts-cache and Metrics counters all live behind
    # this prefix and rely on TRUE thread-local storage to survive fiber
    # scheduling on the same OS thread (1.4.x guarantee).
    HYPERION_KEY_PREFIX = '__hyperion_'

    @installed = false

    class << self
      def installed?
        @installed
      end

      # Confirm that the current Ruby treats Thread.current[:k] as fiber-local.
      # Raises NotImplementedError on older Ruby where the leak still exists.
      def verify_environment!
        marker = :__hyperion_fiber_isolation_check__
        ::Thread.current[marker] = :outer

        observed = nil
        ::Fiber.new { observed = ::Thread.current[marker] }.resume

        unless observed.nil?
          raise NotImplementedError,
                'Thread.current[:k] is NOT fiber-local on this Ruby. ' \
                'Hyperion requires Ruby 3.2+ for safe fiber-per-request scope. ' \
                "Got Ruby #{RUBY_VERSION}."
        end

        true
      ensure
        ::Thread.current[marker] = nil
      end

      # Opt-in patch that routes thread_variable_get/set to fiber storage.
      #
      # `async_io:` MUST be true to install the shim. With async_io off there
      # are no fibers in flight and patching only risks the 1.4.x regression
      # (stranded Logger/Metrics counters when a thread pool runs successive
      # jobs in different fibers). When async_io is off we log a warning and
      # leave thread_variable_* on its original (truly thread-local) path.
      #
      # Even with the shim installed, `__hyperion_*` symbol keys still route
      # to the original thread_variable_* — Hyperion's own Logger and Metrics
      # depend on true thread-local storage and must not be redirected to
      # fiber storage. See the module docstring for the full rationale.
      def install!(async_io: false)
        return if @installed

        unless async_io
          # 1.4.x compat: with no fibers in play the shim has no purpose,
          # and patching `thread_variable_*` to fiber storage would
          # re-introduce the bug 1.4.x fixed (Logger/Metrics counters
          # stranded across thread-pool jobs that happen to run in distinct
          # fibers on the same OS thread). Make this a no-op and tell the
          # operator we ignored their flag.
          Hyperion.logger.warn do
            { message: 'FiberLocal.install! ignored — async_io is off',
              hint: 'The shim only matters under fiber-per-request concurrency. ' \
                    'Enable async_io: true (or pass --async-io) to opt in.' }
          end
          return
        end

        prefix = HYPERION_KEY_PREFIX

        ::Thread.class_eval do
          alias_method :__hyperion_orig_tvar_get, :thread_variable_get
          alias_method :__hyperion_orig_tvar_set, :thread_variable_set

          define_method(:thread_variable_get) do |key|
            sym = key.to_sym
            # Hyperion-internal keys always use TRUE thread-local storage
            # to preserve the 1.4.x guarantee for Logger/Metrics.
            return __hyperion_orig_tvar_get(sym) if sym.to_s.start_with?(prefix)

            # Fiber#storage returns a COPY, so the canonical fiber-local
            # access path is `Fiber[]` — it reads through to the underlying
            # storage and falls back to inherited storage on parent fibers.
            ::Fiber[sym]
          end

          define_method(:thread_variable_set) do |key, value|
            sym = key.to_sym
            # Hyperion-internal keys always use TRUE thread-local storage
            # to preserve the 1.4.x guarantee for Logger/Metrics.
            return __hyperion_orig_tvar_set(sym, value) if sym.to_s.start_with?(prefix)

            # Use `Fiber[]=` (not `Fiber.current.storage[k] = v`) — the
            # latter mutates a copy and does not persist across reads.
            ::Fiber[sym] = value
          end
        end

        @installed = true
      end

      # Test-only undo. Not promised for production.
      def uninstall!
        return unless @installed

        ::Thread.class_eval do
          alias_method :thread_variable_get, :__hyperion_orig_tvar_get
          alias_method :thread_variable_set, :__hyperion_orig_tvar_set
          remove_method :__hyperion_orig_tvar_get
          remove_method :__hyperion_orig_tvar_set
        end

        @installed = false
      end
    end
  end
end
