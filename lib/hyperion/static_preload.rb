# frozen_string_literal: true

require 'find'

require_relative 'http/page_cache'

module Hyperion
  # 2.10-E — Boot-time static-asset preload.
  #
  # `StaticPreload.run` walks each operator-supplied directory tree and
  # populates `Hyperion::Http::PageCache` from the regular files inside.
  # When `immutable: true` (the default for the operator-facing surfaces
  # — the whole point of preload is "I promise these don't change without
  # a restart") every cached entry is marked immutable so the page cache
  # never re-stats the file on subsequent serves.
  #
  # The Server boot path invokes this once per worker after `listen`
  # configures the listener but BEFORE the accept loop spins up — so the
  # very first request lands on a warm cache, not a cold cache miss.
  #
  # Rails-shaped apps get auto-detect for free: when the operator hasn't
  # configured `preload_static` (and didn't pass `--no-preload-static`),
  # `Config#resolved_preload_static_dirs` synthesises a list from
  # `Rails.configuration.assets.paths.first(N)` (cap 8). Hyperion never
  # `require`s rails — `detect_rails_paths` defensively probes
  # `defined?(::Rails) && ::Rails.respond_to?(:configuration)` so the
  # gem stays Rails-agnostic.
  module StaticPreload
    # Default cap on auto-detected Rails asset paths. 8 covers a typical
    # Rails 7+ app (jsbundling/cssbundling/propshaft + a few engine
    # paths) without iterating every gem-installed asset path the host
    # ever depends on. Operators wanting a different cap can pass it
    # explicitly to `detect_rails_paths(cap:)`.
    RAILS_AUTO_DETECT_CAP = 8

    class << self
      # Walk each `entry` and populate the page cache. `entries` is an
      # Array of `{path:, immutable:}` Hashes. Returns the total file
      # count cached across all dirs.
      #
      # `logger` defaults to `Hyperion.logger` so callers in production
      # don't have to thread one through; the spec suite passes an
      # in-memory `Hyperion::Logger` so it can assert on the summary
      # log line without disturbing the global Runtime logger.
      def run(entries, logger: Hyperion.logger)
        return 0 if entries.nil? || entries.empty?
        return 0 unless Hyperion::Http::PageCache.available?

        total = 0
        entries.each do |entry|
          path      = entry[:path]
          immutable = entry.fetch(:immutable, true)

          unless File.directory?(path)
            logger.warn { { message: 'static preload skipped', dir: path, reason: 'not a directory' } }
            next
          end

          stats = preload_dir(path, immutable: immutable)
          total += stats[:files]
          logger.info do
            {
              message: 'static preload complete',
              dir: path,
              files: stats[:files],
              bytes: stats[:bytes],
              ms: stats[:ms]
            }
          end
        end
        total
      end

      # Detect the first `cap` Rails asset paths.  Returns `[]` when
      # Rails is not loaded, when the configuration surface is missing
      # any expected method, or when `assets.paths` is not an Array.
      # NEVER `require 'rails'` — auto-detect must work for the operator
      # who has Rails in their bundle but for a generic Rack app
      # Hyperion is supposed to stay neutral about.
      def detect_rails_paths(cap: RAILS_AUTO_DETECT_CAP)
        return [] unless rails_available?

        config = ::Rails.configuration
        return [] unless config.respond_to?(:assets)

        assets = config.assets
        return [] unless assets.respond_to?(:paths)

        paths = assets.paths
        return [] unless paths.is_a?(Array) && !paths.empty?

        paths.first(cap).map(&:to_s)
      rescue StandardError
        # Auto-detect is a convenience; never let a Rails internals
        # surface change crash boot. Worst case the operator gets the
        # 1.x cold-cache behavior.
        []
      end

      private

      def rails_available?
        defined?(::Rails) && ::Rails.respond_to?(:configuration)
      end

      # Walk a single directory, cache every regular file, optionally
      # mark immutable. Returns `{files:, bytes:, ms:}` so the caller
      # can build the summary log line.
      def preload_dir(dir, immutable:)
        files = 0
        bytes = 0
        t0 = monotonic_ms

        Find.find(dir) do |path|
          next unless File.file?(path)

          result = Hyperion::Http::PageCache.cache_file(path)
          next if result == :missing # symlink loop or unreadable file

          files += 1
          bytes += result if result.is_a?(Integer)
          Hyperion::Http::PageCache.set_immutable(path, true) if immutable
        end

        { files: files, bytes: bytes, ms: (monotonic_ms - t0).round(1) }
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
      end
    end
  end
end
