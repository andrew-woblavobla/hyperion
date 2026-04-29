# frozen_string_literal: true

require 'rack/lint'

module Hyperion
  # Phase 2a (1.7.1) — per-worker `Rack::Lint::Wrapper` pool.
  #
  # In dev mode (`RACK_ENV != 'production'`), Rack guidance is to wrap the
  # response body with a `Rack::Lint::Wrapper` so spec violations surface
  # immediately. The naive shape is one wrapper allocation per request. On a
  # high-rps dev/staging fleet that's a measurable allocation tax — every
  # wrapper carries 8 ivars and a non-trivial init.
  #
  # The pool keeps up to `MAX_POOL_SIZE` reusable wrappers per worker fiber
  # scheduler. On request entry, callers `acquire(app, env)` to get a
  # ready-to-go wrapper. On response close, callers `release(wrapper)` to put
  # it back in the free list. The wrapper's per-request state (`@app`, `@env`,
  # `@response`, status/headers/body, content-length tracking) is reset before
  # reuse so each request gets clean state.
  #
  # Safety:
  #   * Production short-circuit: `acquire` always allocates fresh in
  #     `RACK_ENV=production` so production never carries pool overhead and
  #     never reuses a wrapper that's mid-iteration on another fiber.
  #   * Pool cap: `MAX_POOL_SIZE` bounds steady-state memory. Excess wrappers
  #     fall out of scope and the GC reaps them.
  #   * Single-thread safety: each Hyperion worker runs one fiber scheduler on
  #     one thread, so the underlying `Pool` is contention-free. We don't add
  #     a Mutex — that would be measurable overhead for zero correctness gain
  #     in the supported deployment shape. If a host embeds Hyperion in a
  #     multi-thread context the pool simply won't be reused (each thread
  #     allocates fresh; no corruption).
  #
  # Lint semantics are unchanged: every reused wrapper still validates the
  # body each request via `check_environment`/`check_headers`/etc. inside
  # `Rack::Lint::Wrapper#response`. The only thing reuse skips is the
  # allocation itself — not the validation work.
  module LintWrapperPool
    MAX_POOL_SIZE = 32

    # Reset hook — clear all per-request ivars on a wrapper before it goes
    # back into the free list. Mirrors `Rack::Lint::Wrapper#initialize` so
    # that the wrapper looks freshly-constructed on the next acquire.
    RESET = lambda do |wrapper|
      wrapper.instance_variable_set(:@app, nil)
      wrapper.instance_variable_set(:@env, nil)
      wrapper.instance_variable_set(:@response, nil)
      wrapper.instance_variable_set(:@head_request, false)
      wrapper.instance_variable_set(:@status, nil)
      wrapper.instance_variable_set(:@headers, nil)
      wrapper.instance_variable_set(:@body, nil)
      wrapper.instance_variable_set(:@consumed, nil)
      wrapper.instance_variable_set(:@content_length, nil)
      wrapper.instance_variable_set(:@closed, false)
      wrapper.instance_variable_set(:@size, 0)
      wrapper
    end

    class << self
      # Whether this process should pool Lint wrappers. False in production
      # (Lint is a dev tool; production never inserts it) and false when
      # explicitly disabled via `RACK_LINT_DISABLE=1` for operators who want
      # to side-step the pool entirely.
      def enabled?
        return false if production?
        return false if ENV['RACK_LINT_DISABLE'] == '1'

        true
      end

      def production?
        ENV['RACK_ENV'] == 'production'
      end

      # Acquire a wrapper for `(app, env)`. In production we always allocate
      # fresh (skipping the pool entirely). Outside production we pop a
      # reusable wrapper, rebind it to (app, env) via the reset hook + ivar
      # writes, and return it ready for `#response`.
      #
      # The returned wrapper behaves identically to `Rack::Lint::Wrapper.new(app, env)`.
      def acquire(app, env)
        if enabled?
          wrapper = pool.acquire
          wrapper.instance_variable_set(:@app, app)
          wrapper.instance_variable_set(:@env, env)
          wrapper
        else
          ::Rack::Lint::Wrapper.new(app, env)
        end
      end

      # Release a wrapper back to the pool. No-op in production (where
      # `acquire` returned a fresh allocation that the GC will reap). The
      # underlying `Hyperion::Pool` enforces MAX_POOL_SIZE; releases past
      # the cap drop the wrapper on the floor.
      def release(wrapper)
        return unless enabled?
        return unless wrapper.is_a?(::Rack::Lint::Wrapper)

        pool.release(wrapper)
      end

      # Test seam: clear the free list so spec runs that toggle RACK_ENV
      # don't see warm wrappers from a previous example.
      def reset!
        @pool = nil
      end

      # Read-only accessor for the underlying pool — used by specs to assert
      # reuse without relying on `.equal?` identity through `acquire`.
      def pool_size
        @pool ? @pool.size : 0
      end

      private

      def pool
        @pool ||= Hyperion::Pool.new(
          max_size: MAX_POOL_SIZE,
          factory: -> { ::Rack::Lint::Wrapper.allocate },
          reset: RESET
        )
      end
    end
  end
end
