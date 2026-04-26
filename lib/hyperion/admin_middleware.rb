# frozen_string_literal: true

require 'rack/utils'

module Hyperion
  # Rack middleware that exposes administrative endpoints on the same
  # listener as the application. Disabled by default — only mounted when
  # `admin_token` is configured. Currently provides:
  #
  #   POST /-/quit     →  triggers graceful master drain (SIGTERM to ppid)
  #   GET  /-/metrics  →  returns Hyperion.stats in Prometheus text format
  #
  # Auth: the request must include `X-Hyperion-Admin-Token: <token>`.
  # Mismatch → 401. Path/method mismatch → falls through to the app
  # (so the app can still own /-/anything if Hyperion's admin is off).
  # When the token is unset, the constructor refuses to wrap — callers
  # must skip mounting this middleware at all.
  #
  # SECURITY: the bearer token is defense-in-depth, not a substitute for
  # network isolation. Operators MUST keep the listener on a private
  # network or behind TLS + an authenticating reverse proxy. Anyone who
  # can reach the listener AND knows the token can drain the server or
  # scrape its metrics. See docs/REVERSE_PROXY.md for nginx/ALB recipes
  # that block /-/* at the edge.
  class AdminMiddleware
    PATH_QUIT    = '/-/quit'
    PATH_METRICS = '/-/metrics'

    METRICS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'
    JSON_CONTENT_TYPE    = 'application/json'

    UNAUTHORIZED_BODY = %({"error":"unauthorized"}\n)

    def initialize(app, token:, signal_target: nil)
      raise ArgumentError, 'admin_token must be a non-empty String' if token.nil? || token.to_s.empty?

      @app           = app
      @token         = token.to_s
      # Override hook for tests. Defaults to ppid in worker context, pid
      # for single-worker context (caller decides).
      @signal_target = signal_target
    end

    def call(env)
      path   = env['PATH_INFO']
      method = env['REQUEST_METHOD']

      if path == PATH_QUIT && method == 'POST'
        authorize(env) { handle_quit(env) }
      elsif path == PATH_METRICS && method == 'GET'
        authorize(env) { handle_metrics }
      else
        @app.call(env)
      end
    end

    private

    # Wrap a handler in the shared bearer-token check. Yields only when the
    # token matches; returns the canonical 401 response otherwise.
    def authorize(env)
      provided = env['HTTP_X_HYPERION_ADMIN_TOKEN'].to_s
      return unauthorized unless secure_match?(provided)

      yield
    end

    def unauthorized
      [401, { 'content-type' => JSON_CONTENT_TYPE }, [UNAUTHORIZED_BODY]]
    end

    def handle_quit(env)
      target = resolve_signal_target
      Hyperion.logger.info do
        { message: 'admin drain requested', remote_addr: env['REMOTE_ADDR'], target_pid: target }
      end
      begin
        Process.kill('TERM', target)
      rescue StandardError => e
        Hyperion.logger.warn { { message: 'admin drain signal failed', error: e.message } }
        return [500, { 'content-type' => JSON_CONTENT_TYPE }, [%({"error":"signal_failed"}\n)]]
      end

      [202, { 'content-type' => JSON_CONTENT_TYPE }, [%({"status":"draining"}\n)]]
    end

    def handle_metrics
      body = PrometheusExporter.render(Hyperion.stats)
      [200, { 'content-type' => METRICS_CONTENT_TYPE }, [body]]
    end

    def secure_match?(provided)
      return false if provided.empty?
      return false unless provided.bytesize == @token.bytesize

      # Constant-time comparison. Rack::Utils.secure_compare requires same
      # length, so we prefix-pad first to avoid a length-leak side channel.
      Rack::Utils.secure_compare(provided, @token)
    end

    def resolve_signal_target
      return @signal_target if @signal_target

      # In a forked worker, ppid IS the master; in single-worker mode,
      # the master + worker are the same process — signal self.
      ppid = Process.ppid
      ppid > 1 ? ppid : Process.pid
    end
  end
end
