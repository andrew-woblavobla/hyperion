# frozen_string_literal: true

require 'rack/utils'

module Hyperion
  # Rack middleware that exposes administrative endpoints on the same
  # listener as the application. Disabled by default — only mounted when
  # `admin_token` is configured. Currently provides:
  #
  #   POST /-/quit  →  triggers graceful master drain (SIGTERM to ppid)
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
  # can reach the listener AND knows the token can drain the server.
  class AdminMiddleware
    PATH = '/-/quit'

    def initialize(app, token:, signal_target: nil)
      raise ArgumentError, 'admin_token must be a non-empty String' if token.nil? || token.to_s.empty?

      @app           = app
      @token         = token.to_s
      # Override hook for tests. Defaults to ppid in worker context, pid
      # for single-worker context (caller decides).
      @signal_target = signal_target
    end

    def call(env)
      return @app.call(env) unless admin_request?(env)

      provided = env['HTTP_X_HYPERION_ADMIN_TOKEN'].to_s
      # Constant-time comparison. Rack::Utils.secure_compare requires same
      # length, so prefix-pad first to avoid a length-leak side channel.
      unless secure_match?(provided)
        return [401, { 'content-type' => 'application/json' },
                [%({"error":"unauthorized"}\n)]]
      end

      target = resolve_signal_target
      Hyperion.logger.info { { message: 'admin drain requested', remote_addr: env['REMOTE_ADDR'], target_pid: target } }
      begin
        Process.kill('TERM', target)
      rescue StandardError => e
        Hyperion.logger.warn { { message: 'admin drain signal failed', error: e.message } }
        return [500, { 'content-type' => 'application/json' }, [%({"error":"signal_failed"}\n)]]
      end

      [202, { 'content-type' => 'application/json' }, [%({"status":"draining"}\n)]]
    end

    private

    def admin_request?(env)
      env['PATH_INFO'] == PATH && env['REQUEST_METHOD'] == 'POST'
    end

    def secure_match?(provided)
      return false if provided.empty?
      return false unless provided.bytesize == @token.bytesize

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
