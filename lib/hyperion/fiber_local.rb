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
  # `Hyperion::FiberLocal.install!` — opt-in monkey-patch that ALSO routes
  # `thread_variable_get`/`thread_variable_set` to fiber storage. Use only
  # if you know your app stores request scope via thread variables and you
  # accept the trade-offs (genuine thread-pool patterns will break).
  module FiberLocal
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
      # Most apps DO NOT need this — Ruby 3.2+ symbol-keyed Thread.current[]
      # is already fiber-local. Only install! if your app uses
      # thread_variable_set for request scope.
      def install!
        return if @installed

        ::Thread.class_eval do
          alias_method :__hyperion_orig_tvar_get, :thread_variable_get
          alias_method :__hyperion_orig_tvar_set, :thread_variable_set

          define_method(:thread_variable_get) do |key|
            sym = key.to_sym
            storage = ::Fiber.current.storage
            return storage[sym] if storage&.key?(sym)

            __hyperion_orig_tvar_get(key)
          end

          define_method(:thread_variable_set) do |key, value|
            ::Fiber.current.storage ||= {}
            ::Fiber.current.storage[key.to_sym] = value
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
