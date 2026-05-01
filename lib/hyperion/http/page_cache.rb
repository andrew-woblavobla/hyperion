# frozen_string_literal: true

require 'find'

module Hyperion
  module Http
    # Pre-built static-response cache.  Mirrors agoo's `agooPage`
    # design: each cached asset's full HTTP/1.1 response (status line +
    # Content-Type + Content-Length + body) lives in ONE contiguous
    # heap buffer; the hot path issues a single `write()` syscall with
    # zero Ruby-side allocation.
    #
    # The C primitives are registered as singleton methods on this
    # very module by `ext/hyperion_http/page_cache.c` (see
    # `Init_hyperion_page_cache`).  Surface from C:
    #
    #   PageCache.fetch(path) -> :ok | :stale | :missing
    #   PageCache.cache_file(path) -> Integer | :missing
    #   PageCache.write_to(socket, path) -> Integer | :missing
    #   PageCache.set_immutable(path, bool) -> bool
    #   PageCache.size -> Integer
    #   PageCache.clear -> nil
    #   PageCache.recheck_seconds -> Float
    #   PageCache.recheck_seconds=(secs) -> Float
    #   PageCache.response_bytes(path)   -> String|nil  (specs helper)
    #   PageCache.body_bytes(path)       -> Integer|nil (specs helper)
    #   PageCache.content_type(path)     -> String|nil  (specs helper)
    #   PageCache.auto_threshold         -> Integer
    #   PageCache.max_key_len            -> Integer
    #
    # This Ruby file extends the surface with composite helpers that
    # are easier to express above the C boundary:
    #
    #   PageCache.write_response(socket, path) — alias of #write_to
    #   PageCache.preload(dir, immutable: false) — recursive cache_file
    #   PageCache.mark_immutable(path) / .mark_mutable(path)
    #   PageCache.available? — feature probe (true when C ext loaded)
    #
    # Auto-engaged from `Hyperion::Adapter::Rack` for Rack body objects
    # that respond to `:to_path` and whose file size is below
    # `AUTO_THRESHOLD` (64 KiB).  Above the threshold the existing
    # sendfile path keeps winning (Hyperion already dominates big
    # static at 9× Agoo per the 2.10-B baseline).
    #
    # Operators wanting predictable first-request latency can call
    # `PageCache.preload` on boot to warm the cache over a tree of
    # static assets.
    #
    # If the C extension didn't compile (e.g. JRuby, an unusual host),
    # `PageCache.available?` returns false and `Hyperion::Adapter::Rack`
    # skips the cache engagement.
    module PageCache
      # File-size auto-engage threshold.  Files at or below this size
      # are eligible for the page-cache path; larger files keep their
      # existing sendfile route (Hyperion's win on big static).
      AUTO_THRESHOLD = 64 * 1024

      class << self
        # Alias of {.write_to}.  The plan-spec public name; calling
        # convention preferred for new operator code.  Returns the
        # number of bytes written, or `:missing` when the path is
        # not cached.
        def write_response(socket, path)
          write_to(socket, path)
        end

        # Walk a directory tree and populate the cache for every
        # regular file inside it.  Returns the count of files
        # successfully cached.  When `immutable: true`, every cached
        # entry is also marked immutable so subsequent writes never
        # re-stat (use for content-hashed asset bundles).
        def preload(dir, immutable: false)
          return 0 unless File.directory?(dir)

          count = 0
          Find.find(dir) do |path|
            next unless File.file?(path)

            result = cache_file(path)
            next if result == :missing

            count += 1
            set_immutable(path, true) if immutable
          end
          count
        end

        # Mark a specific path as immutable: subsequent reads via
        # `write_to` skip the mtime stat entirely.  Returns true when
        # the path was present in the cache, false otherwise.
        def mark_immutable(path)
          set_immutable(path, true)
        end

        # Mark a path as mutable (default).  Subsequent reads honor
        # the `recheck_seconds` mtime poll.
        def mark_mutable(path)
          set_immutable(path, false)
        end

        # Whether the C primitive successfully linked into the running
        # interpreter.  True on builds where parser.c compiled (the
        # current 2.10-C drop on every supported host).  Kept as a
        # forward-looking introspection hook so JRuby / TruffleRuby
        # ports can flip it false without blowing up callers.
        def available?
          respond_to?(:write_to)
        end
      end
    end
  end
end
