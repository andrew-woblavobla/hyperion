# frozen_string_literal: true

require 'stringio'
require_relative '../version'
require_relative '../pool'
require_relative '../websocket/handshake'

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

      # Phase 11 — shared frozen empty buffer for StringIO reset. Pre-Phase-11
      # the reset lambda allocated a fresh `+''` per request (one String per
      # acquire). The next call to `build_env` immediately swaps in
      # `input.string = request.body`, so we never mutate this buffer — a
      # single frozen empty String is sufficient as a "clean slate" sentinel.
      EMPTY_INPUT_BUFFER = String.new('', encoding: Encoding::ASCII_8BIT).freeze

      # Phase 11 — frozen literal constants for env values that pre-Phase-11
      # were rebuilt per request:
      #   * SERVER_SOFTWARE — `"Hyperion/#{VERSION}"` interpolated each call.
      #   * RACK_VERSION    — `[3, 0]` Array literal allocated each call.
      # The Array is frozen so Rack apps can't mutate the shared instance.
      SERVER_SOFTWARE_VALUE = "Hyperion/#{Hyperion::VERSION}".freeze
      RACK_VERSION          = [3, 0].freeze

      INPUT_POOL = Hyperion::Pool.new(
        max_size: 256,
        factory: -> { StringIO.new },
        reset: lambda { |io|
          io.string = EMPTY_INPUT_BUFFER
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
        #
        # 2.5-C: `runtime:` is the Hyperion::Runtime that owns this
        # request's metrics + logger + lifecycle hooks. When nil (the
        # default — every existing in-tree call site stays untouched),
        # the adapter resolves to `Hyperion::Runtime.default`, which is
        # the same singleton legacy `Hyperion.metrics` / `Hyperion.logger`
        # delegate to. Apps with multiple servers (multi-tenant) pass an
        # explicit Runtime so each server's NewRelic / AppSignal /
        # OpenTelemetry hooks remain isolated.
        def call(app, request, connection: nil, runtime: nil)
          env, input = build_env(request, connection: connection)

          # 2.1.0 (WS-2) — RFC 6455 §4.2 handshake interception. Runs
          # AFTER env is built (so the WS module sees the same env keys
          # the app would see) but BEFORE app.call. Branches:
          #   * :not_websocket   — request is plain HTTP; no-op
          #   * :ok              — valid WS handshake; stash the
          #     [:ok, accept, subprotocol] tuple in env so the app can
          #     read accept_value without re-running SHA1/base64. The
          #     app is still responsible for writing the 101 response
          #     to the hijacked socket (Option B from the WS-2 plan,
          #     mirrors faye-websocket / ActionCable convention).
          #   * :bad_request / :upgrade_required — short-circuit; the
          #     app never sees the env. Hyperion writes the 4xx itself.
          ws_result = Hyperion::WebSocket::Handshake.validate(env)
          case ws_result.first
          when :ok
            env['hyperion.websocket.handshake'] = ws_result
          when :bad_request, :upgrade_required
            return websocket_handshake_failure_response(ws_result)
          end

          # 2.5-C — per-request lifecycle hooks. The `has_request_hooks?`
          # guard collapses to two empty-Array checks when no observers
          # are registered (the default for every Hyperion install that
          # hasn't opted in), so the hot path stays allocation-free
          # — verified by `yjit_alloc_audit_spec`. Resolving `runtime`
          # is itself zero-allocation: `Runtime.default` returns a
          # memoised singleton.
          #
          # 2.6-D — when the response auto-detects into `:inline_blocking`
          # (static-file body responding to `:to_path`, no streaming
          # marker) we SKIP the after-request lifecycle hook.  Static
          # asset traffic is high-volume + low-value for trace
          # instrumentation: a NewRelic / OpenTelemetry hook firing on
          # every 200-byte favicon or 1 MiB asset response wastes CPU
          # finishing spans nobody queries.  Operators wanting to
          # observe static traffic should use the metrics module
          # (per-route histogram + sendfile_responses counter), which
          # is allocation-free on the hot path.  The before-request
          # hook still fires — its semantic ("the request is about
          # to be processed") is preserved across all dispatch modes;
          # it's the after-hook (typically heavy: span flush, DB
          # write, async-queue enqueue) that benefits from the skip.
          rt = runtime || Hyperion::Runtime.default
          if rt.has_request_hooks?
            rt.fire_request_start(request, env)
            begin
              response = app.call(env)
            rescue StandardError => e
              rt.fire_request_end(request, env, nil, e)
              raise
            end
            resolve_dispatch_mode!(env, response, connection)
            rt.fire_request_end(request, env, response, nil) unless inline_blocking_resolved?(connection)
            return response
          end

          # Phase 11 — return the app's tuple directly. Pre-Phase-11
          # destructured it into 3 locals and re-built the [status, headers,
          # body] Array (one Array allocation per request). Apps already
          # return a [status, headers, body] triple per Rack spec, so the
          # rebuild is pure overhead.
          response = app.call(env)
          resolve_dispatch_mode!(env, response, connection)
          response
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

        # 2.1.0 (WS-2) — translate a Handshake.validate failure tuple
        # into a Rack response triple. 400 for protocol errors,
        # 426 for unsupported Sec-WebSocket-Version (RFC 6455 §4.4)
        # — the 426 path always carries `sec-websocket-version: 13`
        # so the client sees the version Hyperion supports.
        def websocket_handshake_failure_response(ws_result)
          tag, body, extra_headers = ws_result
          status = tag == :upgrade_required ? 426 : 400
          response_headers = { 'content-type' => 'text/plain' }
          extra_headers.each { |k, v| response_headers[k.to_s] = v.to_s }
          [status, response_headers, [body.to_s]]
        end

        # 2.6-C — resolve the per-response dispatch-mode override and
        # stash it on the connection so `Connection#serve` can forward
        # it to `ResponseWriter#write`.  Two opt-in mechanisms, in
        # priority order:
        #
        #   1. Explicit: the Rack app set
        #      `env['hyperion.dispatch_mode'] = :inline_blocking` (or
        #      another future symbol).  Operator-level escape hatch
        #      for routes the auto-detect doesn't catch (e.g. a custom
        #      lazy-streaming body that responds to `:to_path` for
        #      Range-request reasons but is logically a streaming
        #      response).  We honour any explicit non-nil value
        #      verbatim; the writer's branch is keyed on the symbol
        #      so unknown symbols fall through to the default fiber-
        #      yielding path.
        #
        #   2. Auto-detect: response body responds to `:to_path` AND
        #      `env['hyperion.streaming']` is not set.  `to_path` is
        #      Rack's strongest "this is a static file on disk"
        #      signal — Rack::Files, Rack::SendFile, asset servers,
        #      and signed-download responders all set it; streaming
        #      bodies (SSE, JSON streams, chunked Enumerators) do not.
        #      The `hyperion.streaming` env key is the operator's
        #      escape valve to opt OUT of the auto-detect (e.g. a
        #      custom Range-request body that responds to `:to_path`
        #      but should still take the fiber-yielding path because
        #      the body itself does I/O wait between chunks).
        #
        # Conservative-by-design: if `connection` is nil (no socket-
        # owning Connection in scope — h2 streams, ad-hoc adapter
        # callers in specs), we skip the override entirely.  The
        # h2 path has its own per-stream fiber dispatch and doesn't
        # benefit from `:inline_blocking`.
        #
        # Skips a bad response shape (anything that's not a 3-element
        # Array) gracefully — the caller's main rescue clause owns
        # malformed-response handling.
        def resolve_dispatch_mode!(env, response, connection)
          return unless connection
          return unless connection.respond_to?(:response_dispatch_mode=)
          return unless response.is_a?(Array) && response.length == 3

          # 1. Explicit opt-in via env wins.
          explicit = env && env['hyperion.dispatch_mode']
          if explicit
            connection.response_dispatch_mode = explicit
            return
          end

          # 2. Auto-detect on `to_path` static-file responses.  Skip
          # when the app set `hyperion.streaming` — that's the
          # operator's "this body responds to to_path but is
          # logically a streaming response" escape valve.
          return if env && env['hyperion.streaming']

          body = response[2]
          return unless body.respond_to?(:to_path)

          connection.response_dispatch_mode = :inline_blocking
        end

        # 2.6-D — read-back of the resolved dispatch mode.  Used by the
        # lifecycle-hook branch in `#call` to decide whether to fire
        # the after-request hook.  Returns false when `connection` is
        # nil (h2 streams, ad-hoc adapter callers in specs) so those
        # paths keep their hook firing behaviour unchanged.
        def inline_blocking_resolved?(connection)
          return false unless connection
          return false unless connection.respond_to?(:response_dispatch_mode)

          connection.response_dispatch_mode == :inline_blocking
        end

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
          env['SERVER_SOFTWARE']   = SERVER_SOFTWARE_VALUE
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
          env['rack.version']      = RACK_VERSION
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

          # Phase 11 — reuse a per-thread 2-element scratch Array for the
          # `env, input = build_env(...)` destructuring return. Pre-Phase-11
          # allocated a fresh `[env, input]` Array per request; the caller
          # destructures immediately and never holds onto the Array, so a
          # mutable per-thread tuple is safe (each request runs to the
          # destructure on the same thread before any nested build_env call
          # could observe it).
          tup = (Thread.current[:__hyperion_build_env_tuple__] ||= [nil, nil])
          tup[0] = env
          tup[1] = input
          tup
        end

        # Phase 11 — frozen "no port specified" sentinels so the
        # overwhelmingly common host_header == "host" / "host:80" /
        # "host:443" branches don't allocate a fresh Array on every
        # request. The caller destructures into `server_name, server_port =
        # split_host(...)` immediately and never holds the returned Array,
        # so a per-thread mutable scratch Array is safe (and the frozen
        # `LOCALHOST_DEFAULTS` sentinel covers the empty-host cases without
        # any allocation at all).
        LOCALHOST_DEFAULTS = %w[localhost 80].freeze
        DEFAULT_PORT_80    = '80'

        def split_host(host_header)
          return LOCALHOST_DEFAULTS if host_header.empty?

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
              return LOCALHOST_DEFAULTS
            end

            name = host_header[0..close]
            rest = host_header[(close + 1)..]
            port = rest&.start_with?(':') ? rest[1..] : DEFAULT_PORT_80
            split_host_tuple(name, port.to_s.empty? ? DEFAULT_PORT_80 : port)
          elsif (idx = host_header.index(':'))
            # Phase 11 — replace `split(':', 2)` (allocates 2 Strings + 1
            # transient Array that's then discarded for a fresh `[name,
            # port]` literal). Hand-rolled byteslice keeps the 2 substring
            # allocations (unavoidable — the env hash retains them) but
            # routes the surrounding container through the per-thread
            # scratch tuple, dropping 1 Array allocation per request.
            split_host_tuple(host_header.byteslice(0, idx),
                             host_header.byteslice(idx + 1, host_header.bytesize - idx - 1))
          else
            split_host_tuple(host_header, DEFAULT_PORT_80)
          end
        end

        # Per-thread 2-element scratch Array for split_host's return tuple.
        # See note on `__hyperion_build_env_tuple__` in build_env — the
        # caller destructures immediately; no nested split_host call can
        # observe the same thread's tuple before the destructure completes.
        def split_host_tuple(name, port)
          tup = (Thread.current[:__hyperion_split_host_tuple__] ||= [nil, nil])
          tup[0] = name
          tup[1] = port
          tup
        end
      end
    end
  end
end
