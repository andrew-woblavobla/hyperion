# frozen_string_literal: true

module Hyperion
  class Metrics
    # 2.4-C — turn raw request paths into low-cardinality templates so the
    # per-route histogram doesn't blow up to one label-set per `/users/<id>`.
    #
    # The default rules collapse `/users/123` → `/users/:id` and
    # `/orders/3fa85f64-5717-4562-b3fc-2c963f66afa6` → `/orders/:uuid`. They
    # cover the bulk of real-world REST paths; operators with Rails-style
    # routes (`/articles/cool-slug-2024`) plug in their own rules via
    # `Hyperion::Config#metrics.path_templater = MyTemplater.new`.
    #
    # An LRU cache keyed on the raw path side-steps repeating the regex walk
    # on every keep-alive request to the same handler. 1000 entries is sized
    # for typical Rails-shape apps (sub-1000 unique route templates); apps
    # with more should pass `lru_size:` explicitly.
    class PathTemplater
      DEFAULT_RULES = [
        [/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, ':uuid'],
        [/\b\d+\b/, ':id']
      ].freeze

      DEFAULT_LRU_SIZE = 1000

      attr_reader :lru_size

      def initialize(rules: DEFAULT_RULES, lru_size: DEFAULT_LRU_SIZE)
        @rules    = rules
        @lru_size = lru_size
        @cache    = {} # Insertion-ordered Hash doubles as an LRU.
        @mutex    = Mutex.new
        # PR3-2 — per-thread shadow cache. On a keep-alive benchmark
        # connection the same path is seen on every request; the shared
        # LRU's mutex acquire (even uncontended) costs a syscall-comparable
        # overhead under high concurrency. Each worker thread keeps its own
        # small (DEFAULT_THREAD_CACHE_SIZE-entry) Hash; on a hit we return
        # without touching the mutex at all.  On a miss we fall through to
        # the shared LRU and backfill the thread cache.  The thread cache
        # is stored with Thread#thread_variable_* (true thread-local, not
        # fiber-local) so it survives async-io scheduler yields correctly.
        @thread_cache_key = :"__hyperion_pt_cache_#{object_id}__"
        @thread_size_key  = :"__hyperion_pt_size_#{object_id}__"
      end

      DEFAULT_THREAD_CACHE_SIZE = 64

      # Translate a raw request path into its template form. The result
      # is memoized in the LRU; a cache hit is a single Hash#[] +
      # re-insert (touch). On miss we run the regex chain and trim the
      # oldest entry if we exceed `lru_size`.
      #
      # PR3-2: Fast path checks the per-thread shadow cache first (no mutex).
      def template(path)
        return path if path.nil? || path.empty?

        thread = Thread.current
        tc = thread.thread_variable_get(@thread_cache_key)
        if tc && (hit = tc[path])
          return hit
        end

        @mutex.synchronize do
          if (cached = @cache.delete(path))
            # Re-insert to mark "recently used" (Ruby Hashes preserve
            # insertion order, oldest = first key).
            @cache[path] = cached
            tc = thread_cache_for(thread)
            tc[path] = cached
            return cached
          end

          templated = compute(path)
          @cache[path] = templated
          @cache.shift if @cache.size > @lru_size
          tc = thread_cache_for(thread)
          tc[path] = templated
          templated
        end
      end

      def cache_size
        @mutex.synchronize { @cache.size }
      end

      private

      # PR3-2 — allocate or return the per-thread shadow cache Hash.
      # Evicts the oldest entry when the thread cache is full.
      def thread_cache_for(thread)
        tc = thread.thread_variable_get(@thread_cache_key)
        unless tc
          tc = {}
          thread.thread_variable_set(@thread_cache_key, tc)
        end
        if tc.size >= DEFAULT_THREAD_CACHE_SIZE
          # Evict oldest (insertion-order first key).
          tc.shift
        end
        tc
      end

      def compute(path)
        @rules.reduce(path) { |p, (regex, replacement)| p.gsub(regex, replacement) }
      end
    end
  end
end
