# frozen_string_literal: true

require 'stringio'
require_relative '../version'
require_relative '../pool'

module Hyperion
  module Adapter
    # NOTE: this is Hyperion::Adapter::Rack, not the Rack gem.
    # Reference the Rack gem as ::Rack inside this module if needed.
    module Rack
      # Pre-frozen mapping for the 30 most common HTTP request headers.
      # Skips the per-request `"HTTP_#{name.upcase.tr('-', '_')}"` allocation
      # (5–15 string ops per request × N headers). Uncached header names fall
      # back to the dynamic computation. Keys are lowercased to match the
      # parser's normalisation.
      #
      # Phase 2c (1.7.1) widened from 16 to 30 entries to cover the full
      # production-traffic top-30 (Sec-Fetch-*, X-Forwarded-Host, X-Real-IP,
      # If-None-Match, etc.). When the C extension is built, the values
      # below are replaced with the *same* frozen VALUEs registered by
      # CParser::PREINTERNED_HEADERS, so the env hash, parser, and adapter
      # all share string identity for these keys (`#equal?` is true). This
      # is what unlocks the spec assertion that `env['HTTP_USER_AGENT']` key
      # is `equal?` to the pre-interned key — and it lets downstream Rack
      # apps that key into env via these same literal strings hit a
      # GVAR-backed pointer compare instead of a hash byte compare.
      HTTP_KEY_CACHE = {
        'host' => 'HTTP_HOST',
        'user-agent' => 'HTTP_USER_AGENT',
        'accept' => 'HTTP_ACCEPT',
        'accept-encoding' => 'HTTP_ACCEPT_ENCODING',
        'accept-language' => 'HTTP_ACCEPT_LANGUAGE',
        'cache-control' => 'HTTP_CACHE_CONTROL',
        'connection' => 'HTTP_CONNECTION',
        'cookie' => 'HTTP_COOKIE',
        'content-length' => 'HTTP_CONTENT_LENGTH',
        'content-type' => 'HTTP_CONTENT_TYPE',
        'authorization' => 'HTTP_AUTHORIZATION',
        'referer' => 'HTTP_REFERER',
        'origin' => 'HTTP_ORIGIN',
        'upgrade' => 'HTTP_UPGRADE',
        'x-forwarded-for' => 'HTTP_X_FORWARDED_FOR',
        'x-forwarded-proto' => 'HTTP_X_FORWARDED_PROTO',
        'x-forwarded-host' => 'HTTP_X_FORWARDED_HOST',
        'x-real-ip' => 'HTTP_X_REAL_IP',
        'x-request-id' => 'HTTP_X_REQUEST_ID',
        'if-none-match' => 'HTTP_IF_NONE_MATCH',
        'if-modified-since' => 'HTTP_IF_MODIFIED_SINCE',
        'if-match' => 'HTTP_IF_MATCH',
        'etag' => 'HTTP_ETAG',
        'range' => 'HTTP_RANGE',
        'pragma' => 'HTTP_PRAGMA',
        'dnt' => 'HTTP_DNT',
        'sec-ch-ua' => 'HTTP_SEC_CH_UA',
        'sec-fetch-dest' => 'HTTP_SEC_FETCH_DEST',
        'sec-fetch-mode' => 'HTTP_SEC_FETCH_MODE',
        'sec-fetch-site' => 'HTTP_SEC_FETCH_SITE'
      }.freeze

      # If the C extension is loaded, rebind HTTP_KEY_CACHE values to the
      # *same* frozen VALUEs the parser registers in CParser::PREINTERNED_HEADERS.
      # This collapses three otherwise-distinct frozen Strings ("HTTP_HOST" in
      # this Hash, "HTTP_HOST" in the env, "HTTP_HOST" the parser interned) into
      # one shared object — `equal?` becomes pointer-compare for downstream
      # consumers. The mutation runs once at load time, before the constant is
      # observed externally; from that point on the Hash itself is frozen.
      if defined?(::Hyperion::CParser) &&
         ::Hyperion::CParser.const_defined?(:PREINTERNED_HEADERS)
        pairs = ::Hyperion::CParser::PREINTERNED_HEADERS
        # Walk the parallel [lc, http_key, lc, http_key, ...] flat array.
        unfrozen = HTTP_KEY_CACHE.dup
        i = 0
        while i < pairs.length
          lc       = pairs[i]
          http_key = pairs[i + 1]
          unfrozen[lc] = http_key if unfrozen.key?(lc)
          i += 2
        end
        remove_const(:HTTP_KEY_CACHE)
        HTTP_KEY_CACHE = unfrozen.freeze
      end

      ENV_POOL = Hyperion::Pool.new(
        max_size: 256,
        factory: -> { {} },
        reset: ->(env) { env.clear }
      )

      INPUT_POOL = Hyperion::Pool.new(
        max_size: 256,
        factory: -> { StringIO.new },
        reset: lambda { |io|
          io.string = +''
          io.rewind
        }
      )

      # Whether Hyperion::CParser.upcase_underscore is available. Probed lazily
      # at first use (CParser is required after this file, so an eager check
      # at load time would always be false). Memoised in a class-level ivar to
      # keep the hot path branchless.
      def self.c_upcase_available?
        return @c_upcase_available unless @c_upcase_available.nil?

        @c_upcase_available = defined?(::Hyperion::CParser) &&
                              ::Hyperion::CParser.respond_to?(:upcase_underscore)
      end

      # Phase 3a (1.7.1) — whether the full env-build loop has moved into C.
      # When true, build_env hands the populated env Hash + Request to the
      # C ext, which sets REQUEST_METHOD / PATH_INFO / QUERY_STRING /
      # HTTP_VERSION / SERVER_PROTOCOL / CONTENT_TYPE / CONTENT_LENGTH +
      # every HTTP_<UPCASED> header in one trip across the FFI boundary.
      # The Ruby fallback below stays exercised by spec for parity coverage.
      def self.c_build_env_available?
        return @c_build_env_available unless @c_build_env_available.nil?

        @c_build_env_available = defined?(::Hyperion::CParser) &&
                                 ::Hyperion::CParser.respond_to?(:build_env)
      end

      class << self
        # Pre-allocate `n` env-hash and rack-input objects in master before
        # fork. Children inherit the populated free-list via copy-on-write —
        # the hash slots stay shared until a request mutates them. Eliminates
        # the first-N-requests allocation tax that every fresh worker would
        # otherwise pay on cold start. Idempotent: safe to call multiple
        # times; the pool simply caps at its configured `max_size`.
        def warmup_pool(count = 8)
          warmed_envs = Array.new(count) { ENV_POOL.acquire }
          warmed_inputs = Array.new(count) { INPUT_POOL.acquire }
          warmed_envs.each { |e| ENV_POOL.release(e) }
          warmed_inputs.each { |i| INPUT_POOL.release(i) }
          nil
        end

        # 2.1.0 (WS-1): `connection:` is the Hyperion::Connection that owns
        # the underlying socket for this request. When non-nil, the env hash
        # advertises Rack 3 full-hijack support — the app can call
        # `env['rack.hijack'].call` to take ownership of the raw socket and
        # speak any post-HTTP protocol (WebSocket, raw TCP tunnel, etc.).
        # When nil (HTTP/2 path, ad-hoc adapter callers in specs), hijack
        # stays disabled — `env['rack.hijack?']` returns false and the env
        # has no `rack.hijack` key, matching pre-2.1 behaviour.
        def call(app, request, connection: nil)
          env, input = build_env(request, connection: connection)
          status, headers, body = app.call(env)
          [status, headers, body]
        rescue StandardError => e
          Hyperion.metrics.increment(:app_errors)
          Hyperion.logger.error do
            {
              message: 'app raised',
              error: e.message,
              error_class: e.class.name,
              backtrace: (e.backtrace || []).first(20).join(' | ')
            }
          end
          [500, { 'content-type' => 'text/plain' }, ['Internal Server Error']]
        ensure
          # Return env + input to pools after the response has been fully
          # iterated by the writer. We can't release here because Rack body
          # is iterated lazily — release happens after the writer.
          # For Phase 5 simplicity we release synchronously since the writer
          # buffers fully. Phase 7 (HTTP/2 streaming) will revisit.
          #
          # 2.1.0 hijack: when the app full-hijacked the socket, the env
          # references (notably the rack.hijack proc + buffered carry) are
          # *the* live reference to the connection. Returning the env to the
          # pool here would let a subsequent request reuse the same hash and
          # silently null out the hijacker's state. Skip the pool release on
          # hijacked connections and let the hash be GC'd normally.
          if env && connection && connection.respond_to?(:hijacked?) && connection.hijacked?
            # Drop the input back into the pool (it's a fresh StringIO and
            # the hijacker doesn't reference it). Skip env recycling.
            INPUT_POOL.release(input) if input
          else
            ENV_POOL.release(env) if env
            INPUT_POOL.release(input) if input
          end
        end

        private

        def build_env(request, connection: nil)
          host_header = request.header('host') || ''
          server_name, server_port = split_host(host_header)

          env = ENV_POOL.acquire
          input = INPUT_POOL.acquire
          input.string = request.body
          input.rewind

          # Adapter-owned (non-header, non-request-line) env. SERVER_NAME/PORT
          # need split_host, REMOTE_ADDR needs peer info, the rack.* keys are
          # constants — none of these benefit from the FFI hop, so they stay
          # in Ruby regardless of c_build_env_available?.
          env['SERVER_NAME']       = server_name
          env['SERVER_PORT']       = server_port
          env['SERVER_SOFTWARE']   = "Hyperion/#{Hyperion::VERSION}"
          # Rack apps (Rack::Attack throttles, IpHelper.real_ip, audit logging)
          # require REMOTE_ADDR. Fall back to localhost when no peer info is
          # available — typically when a Request is constructed in specs
          # without a backing socket.
          env['REMOTE_ADDR']       = request.peer_address || '127.0.0.1'
          env['rack.url_scheme']   = 'http'
          env['rack.input']        = input
          env['rack.errors']       = $stderr
          if connection
            # 2.1.0 (WS-1) — Rack 3 full-hijack. The proc captures the
            # connection (NOT the socket directly) so the connection can
            # flip its @hijacked flag synchronously inside hijack!; that
            # way the writer / cleanup paths see the flag the moment the
            # app takes over the wire. The proc returns the raw socket
            # IO, per Rack 3 spec.
            env['rack.hijack?'] = true
            env['rack.hijack']  = lambda do
              connection.hijack!
            end
            # Hyperion-specific extension: any bytes the connection had
            # buffered past the parsed request (pipelined/keep-alive
            # carry, or — for an Upgrade — bytes the client sent
            # immediately after the headers). Empty string when none.
            # The app reads these BEFORE reading from the hijacked
            # socket. Documented in CHANGELOG; not a Rack 3 spec key.
            env['hyperion.hijack_buffered'] =
              connection.respond_to?(:hijack_buffered) ? connection.hijack_buffered : +''
          else
            env['rack.hijack?'] = false
          end
          env['rack.version']      = [3, 0]
          env['rack.multithread']  = false
          env['rack.multiprocess'] = false
          env['rack.run_once']     = false
          env['SCRIPT_NAME']       = ''

          if Rack.c_build_env_available?
            # Phase 3a (1.7.1) — single FFI call sets REQUEST_METHOD,
            # PATH_INFO, QUERY_STRING, HTTP_VERSION, SERVER_PROTOCOL,
            # CONTENT_TYPE, CONTENT_LENGTH, and every HTTP_* header.
            ::Hyperion::CParser.build_env(env, request)
          else
            env['REQUEST_METHOD']  = request.method
            env['PATH_INFO']       = request.path
            env['QUERY_STRING']    = request.query_string
            env['SERVER_PROTOCOL'] = request.http_version
            env['HTTP_VERSION']    = request.http_version

            # Header-name → Rack env-key conversion. Cache covers the
            # 30 most common names; uncached headers (X-* customs,
            # vendor-specific) flow through CParser.upcase_underscore
            # (single C-level allocation) when the ext is built, else
            # the pure-Ruby triple-allocation path.
            c_upcase = Rack.c_upcase_available?
            request.headers.each do |name, value|
              key = HTTP_KEY_CACHE[name] ||
                    (c_upcase ? ::Hyperion::CParser.upcase_underscore(name) : "HTTP_#{name.upcase.tr('-', '_')}")
              env[key] = value
            end

            env['CONTENT_TYPE']   = env['HTTP_CONTENT_TYPE']   if env.key?('HTTP_CONTENT_TYPE')
            env['CONTENT_LENGTH'] = env['HTTP_CONTENT_LENGTH'] if env.key?('HTTP_CONTENT_LENGTH')
          end

          [env, input]
        end

        def split_host(host_header)
          return %w[localhost 80] if host_header.empty?

          if host_header.start_with?('[')
            close = host_header.index(']')
            # Malformed bracketed IPv6 (no closing bracket): we used to return
            # the raw garbage as SERVER_NAME, which then leaked into Rack env
            # where downstream URL generators / loggers / SSRF allow-lists
            # would trust attacker-controlled bytes. Fail closed to a safe
            # default and bump a counter so operators can alert on volume.
            # No raise — Rack apps don't expect Hyperion's adapter to throw
            # on header-parse failures, so we degrade gracefully instead.
            unless close
              Hyperion.metrics.increment(:malformed_host_header)
              return %w[localhost 80]
            end

            name = host_header[0..close]
            rest = host_header[(close + 1)..]
            port = rest&.start_with?(':') ? rest[1..] : '80'
            [name, port.to_s.empty? ? '80' : port]
          elsif host_header.include?(':')
            name, port = host_header.split(':', 2)
            [name, port]
          else
            [host_header, '80']
          end
        end
      end
    end
  end
end
