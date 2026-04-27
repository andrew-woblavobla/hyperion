# frozen_string_literal: true

require 'stringio'
require_relative '../version'
require_relative '../pool'

module Hyperion
  module Adapter
    # NOTE: this is Hyperion::Adapter::Rack, not the Rack gem.
    # Reference the Rack gem as ::Rack inside this module if needed.
    module Rack
      # Pre-frozen mapping for the 16 most common HTTP request headers.
      # Skips the per-request `"HTTP_#{name.upcase.tr('-', '_')}"` allocation
      # (5–15 string ops per request × N headers). Uncached header names fall
      # back to the dynamic computation. Keys are lowercased to match the
      # parser's normalisation.
      HTTP_KEY_CACHE = {
        'host' => 'HTTP_HOST',
        'user-agent' => 'HTTP_USER_AGENT',
        'accept' => 'HTTP_ACCEPT',
        'accept-encoding' => 'HTTP_ACCEPT_ENCODING',
        'accept-language' => 'HTTP_ACCEPT_LANGUAGE',
        'connection' => 'HTTP_CONNECTION',
        'content-type' => 'HTTP_CONTENT_TYPE',
        'content-length' => 'HTTP_CONTENT_LENGTH',
        'cookie' => 'HTTP_COOKIE',
        'authorization' => 'HTTP_AUTHORIZATION',
        'cache-control' => 'HTTP_CACHE_CONTROL',
        'referer' => 'HTTP_REFERER',
        'origin' => 'HTTP_ORIGIN',
        'x-forwarded-for' => 'HTTP_X_FORWARDED_FOR',
        'x-forwarded-proto' => 'HTTP_X_FORWARDED_PROTO',
        'x-real-ip' => 'HTTP_X_REAL_IP'
      }.freeze

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

        def call(app, request)
          env, input = build_env(request)
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
          ENV_POOL.release(env) if env
          INPUT_POOL.release(input) if input
        end

        private

        def build_env(request)
          host_header = request.header('host') || ''
          server_name, server_port = split_host(host_header)

          env = ENV_POOL.acquire
          input = INPUT_POOL.acquire
          input.string = request.body
          input.rewind

          env['REQUEST_METHOD']    = request.method
          env['PATH_INFO']         = request.path
          env['QUERY_STRING']      = request.query_string
          env['SERVER_NAME']       = server_name
          env['SERVER_PORT']       = server_port
          env['SERVER_PROTOCOL']   = request.http_version
          env['HTTP_VERSION']      = request.http_version
          env['SERVER_SOFTWARE']   = "Hyperion/#{Hyperion::VERSION}"
          # Rack apps (Rack::Attack throttles, IpHelper.real_ip, audit logging)
          # require REMOTE_ADDR. Fall back to localhost when no peer info is
          # available — typically when a Request is constructed in specs
          # without a backing socket.
          env['REMOTE_ADDR']       = request.peer_address || '127.0.0.1'
          env['rack.url_scheme']   = 'http'
          env['rack.input']        = input
          env['rack.errors']       = $stderr
          env['rack.hijack?']      = false
          env['rack.version']      = [3, 0]
          env['rack.multithread']  = false
          env['rack.multiprocess'] = false
          env['rack.run_once']     = false
          env['SCRIPT_NAME']       = ''

          # Header-name → Rack env-key conversion. Cache covers the 16 most
          # common names; uncached headers (X-* customs, vendor-specific) flow
          # through CParser.upcase_underscore (single C-level allocation) when
          # the extension is built, else the pure-Ruby triple-allocation path.
          c_upcase = Rack.c_upcase_available?
          request.headers.each do |name, value|
            key = HTTP_KEY_CACHE[name] ||
                  (c_upcase ? ::Hyperion::CParser.upcase_underscore(name) : "HTTP_#{name.upcase.tr('-', '_')}")
            env[key] = value
          end

          env['CONTENT_TYPE']   = env['HTTP_CONTENT_TYPE']   if env.key?('HTTP_CONTENT_TYPE')
          env['CONTENT_LENGTH'] = env['HTTP_CONTENT_LENGTH'] if env.key?('HTTP_CONTENT_LENGTH')

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
