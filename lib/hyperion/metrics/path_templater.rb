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
      end

      # Translate a raw request path into its template form. The result
      # is memoized in the LRU; a cache hit is a single Hash#[] +
      # re-insert (touch). On miss we run the regex chain and trim the
      # oldest entry if we exceed `lru_size`.
      def template(path)
        return path if path.nil? || path.empty?

        @mutex.synchronize do
          if (cached = @cache.delete(path))
            # Re-insert to mark "recently used" (Ruby Hashes preserve
            # insertion order, oldest = first key).
            @cache[path] = cached
            return cached
          end

          templated = compute(path)
          @cache[path] = templated
          @cache.shift if @cache.size > @lru_size
          templated
        end
      end

      def cache_size
        @mutex.synchronize { @cache.size }
      end

      private

      def compute(path)
        @rules.reduce(path) { |p, (regex, replacement)| p.gsub(regex, replacement) }
      end
    end
  end
end
