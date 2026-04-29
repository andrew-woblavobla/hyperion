# frozen_string_literal: true

module Hyperion
  # Internal value object replacing the 4-flag / 5-output if/elsif state
  # machine that lived in `Server#dispatch` and `Server#inline_h1_dispatch?`.
  # Pre-1.7 the matrix (`@tls`, `@async_io ∈ {nil, true, false}`,
  # `@thread_count`, ALPN) was prose-only — no enum, no boot validation,
  # operators verified the shape by reading the 1.4.0 changelog.
  #
  # 1.7 ships the value object internally + plumbs it at the dispatch call
  # sites. Operators don't see it — they read modes via per-mode counters
  # (`Hyperion.stats[:requests_dispatch_<mode>]`). Two reasons it is NOT
  # public surface:
  #
  #   1. The `name` set is small but expected to grow as we add transports
  #      (HTTP/3, h2c upgrade); locking it now would force a major-bump
  #      churn for every new mode.
  #   2. Operators using stats keys instead of reflection are insulated
  #      from rename refactors — `:requests_dispatch_threadpool` keeps
  #      working even if the internal symbol changes.
  #
  # Frozen after construction so a caller can't mutate the mode out from
  # under a hot-path branch. Equality + hash are by `name` so it slots
  # cleanly into per-mode metric keys without surprising identity checks.
  class DispatchMode
    # The 5 dispatch shapes Hyperion currently honours. Names mirror the
    # RFC's wording so readers can map between the two without translation:
    #   :tls_h2              — TLS connection that ALPN-picked HTTP/2
    #   :tls_h1_inline       — TLS HTTP/1.1, served inline on accept fiber
    #                          (1.4.0+ default; preserves Async scheduler
    #                          for hyperion-async-pg / async-redis)
    #   :async_io_h1_inline  — Plain HTTP/1.1 with `async_io: true`,
    #                          served inline on the calling fiber
    #   :threadpool_h1       — Plain or TLS HTTP/1.1 dispatched to the
    #                          worker thread pool (`-t N`, default)
    #   :inline_h1_no_pool   — Plain HTTP/1.1, no pool (`-t 0`); served
    #                          inline on the accept thread/fiber
    MODES = %i[tls_h2 tls_h1_inline async_io_h1_inline threadpool_h1 inline_h1_no_pool].freeze

    INLINE_MODES = %i[tls_h1_inline async_io_h1_inline inline_h1_no_pool].freeze

    attr_reader :name

    # Resolve the mode for a single dispatch from the four signals that
    # drive the matrix. ALPN is only relevant when TLS is in play; the
    # caller passes nil for plain HTTP. `thread_count` is a positive
    # integer (pool present) or 0 (no pool, dispatch inline).
    #
    # Semantics intentionally mirror the pre-1.7 if/elsif chain in
    # `Server#dispatch` so the refactor is behaviour-preserving.
    def self.resolve(tls:, async_io:, thread_count:, alpn: nil)
      return new(:tls_h2) if tls && alpn == 'h2'
      return new(:tls_h1_inline) if tls && async_io != false
      return new(:async_io_h1_inline) if !tls && async_io == true
      return new(:threadpool_h1) if thread_count.to_i.positive?

      new(:inline_h1_no_pool)
    end

    def initialize(name)
      raise ArgumentError, "unknown DispatchMode #{name.inspect}" unless MODES.include?(name)

      @name = name
      freeze
    end

    # Inline-on-fiber dispatch (no thread-pool hop). Three shapes qualify:
    # tls_h1_inline (default for TLS h1), async_io_h1_inline (operator
    # opted into fiber I/O on plain h1), inline_h1_no_pool (`-t 0`).
    def inline?
      INLINE_MODES.include?(@name)
    end

    def threadpool?
      @name == :threadpool_h1
    end

    def h2?
      @name == :tls_h2
    end

    # Whether dispatch yields cooperatively (Async scheduler current on
    # the calling fiber). True for TLS h1 inline (TLS already wraps the
    # accept loop in Async), async_io_h1_inline (operator opted in), and
    # h2 (per-stream fibers). False for threadpool dispatch (worker
    # thread, no scheduler) and `-t 0` plain HTTP.
    def async?
      @name == :tls_h2 || @name == :tls_h1_inline || @name == :async_io_h1_inline
    end

    # Whether the dispatch goes through `ThreadPool#submit_connection`
    # (or `ThreadPool#call` on the h2 per-stream path).
    def pooled?
      @name == :threadpool_h1
    end

    # Per-mode metric key. Stable across releases — operators alert on
    # `:requests_dispatch_threadpool` etc. directly. The full set is
    # documented in the README's Metrics section.
    def metric_key
      :"requests_dispatch_#{@name}"
    end

    def ==(other)
      other.is_a?(DispatchMode) && other.name == @name
    end
    alias eql? ==

    # Symbol#hash — DispatchMode is a value object keyed on `name`, so
    # rehashing under the underlying symbol gives correct Hash bucket
    # placement without allocating.
    def hash
      n = @name
      n.hash
    end

    # -- this gem has no ActiveSupport on
    # its dependency graph; `delegate` is unavailable. Plain method.
    def to_s
      n = @name
      n.to_s
    end

    def inspect
      "#<Hyperion::DispatchMode #{@name}>"
    end
  end
end
