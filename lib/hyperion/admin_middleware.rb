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
      # Override hook for tests. When unset, resolve_signal_target consults
      # Hyperion.master_pid (master writes itself there at boot, exports
      # HYPERION_MASTER_PID into ENV so forked workers inherit it).
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
      # 2.4-C: render the full surface — legacy counters + histograms +
      # gauges + labeled counters. The exporter falls back to the legacy
      # `render(stats)` body when the sink doesn't expose the new
      # snapshot helpers (defensive: third-party Metrics adapters that
      # quack-implement the 1.x surface still emit a valid scrape body).
      body = if Hyperion.metrics.respond_to?(:histogram_snapshot)
               PrometheusExporter.render_full(Hyperion.metrics)
             else
               PrometheusExporter.render(Hyperion.stats)
             end
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

      # Always prefer the explicitly-recorded master PID. In a worker the
      # master wrote `HYPERION_MASTER_PID` into ENV before forking, so
      # `Hyperion.master_pid` returns the master from inside the worker
      # via inherited ENV. In single-mode the master IS the running
      # process and `master_pid!` set the ivar in #run_single.
      #
      # Why not Process.ppid? Two failure modes:
      #
      #   1. Master runs as PID 1 inside containerd / Docker (default
      #      shape: `CMD ["hyperion", "config.ru"]`). A worker's
      #      `Process.ppid` is 1 — and the previous fallback
      #      `ppid > 1 ? ppid : Process.pid` then mistargeted the
      #      *worker itself* on a graceful drain, so SIGTERM killed the
      #      worker but left the master + the rest of the workers intact.
      #      Operators saw the admin endpoint return 202 "draining" and
      #      nothing happen at the fleet level.
      #
      #   2. Single-worker mode has no parent Hyperion process; ppid is
      #      whatever launched us (shell, systemd, a supervisor). Killing
      #      that is at best confusing, at worst destructive.
      #
      # Hyperion.master_pid handles both correctly without any ppid math.
      Hyperion.master_pid
    end
  end
end
