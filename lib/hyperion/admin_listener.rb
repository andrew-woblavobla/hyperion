# frozen_string_literal: true

require 'socket'
require 'rack/utils'

module Hyperion
  # Sibling HTTP listener for admin endpoints (RFC A8). When the operator
  # sets `admin.listener_port`, Hyperion spawns a small dedicated server
  # on `127.0.0.1:<port>` that handles ONLY `/-/quit` and `/-/metrics`
  # (Prometheus exposition). The application listener is unchanged —
  # admin paths can stay mounted in-app simultaneously, depending on
  # whether `AdminMiddleware` is wrapped.
  #
  # **Why a sibling listener, not just middleware?** Three failure modes
  # AdminMiddleware can't escape on its own:
  #
  #   1. Misordered `Rack::Builder` middleware can disable admin (a
  #      `use` of a custom 404 middleware in front of Hyperion's wrap).
  #   2. Request-headers-logging middleware (`Rack::CommonLogger` derivs,
  #      OpenTelemetry HTTP instrumentation, app-level header dumpers)
  #      logs the `X-Hyperion-Admin-Token` value to access logs. The
  #      sibling listener's path never goes through that pipeline.
  #   3. Operators who don't want to manually 404 `/-/*` at the edge
  #      proxy can simply not expose this port.
  #
  # **Defence-in-depth, not a replacement for network isolation.** The
  # bearer token still gates every request. Operators MUST keep this
  # port on a private interface (default `127.0.0.1`) or behind an
  # authenticating reverse proxy. Same `secure_match?` logic as
  # AdminMiddleware.
  #
  # **Implementation note.** Single accept thread, no Rack pipeline. We
  # parse the request line + Authorization header by hand because:
  #
  #   * The two endpoints are trivial (drain via SIGTERM; render
  #     pre-formatted Prometheus text).
  #   * Pulling in a full Rack stack inside Hyperion to serve two
  #     endpoints would re-introduce the misordering footgun (#1 above).
  #   * The bytes per response are tiny — encryption / chunked encoding
  #     / keep-alive aren't needed.
  #
  # Returns 202 + `{"status":"draining"}` on quit, 200 + Prometheus text
  # on metrics, 401 on bearer mismatch, 404 on anything else.
  class AdminListener
    PATH_QUIT    = '/-/quit'
    PATH_METRICS = '/-/metrics'

    METRICS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'
    JSON_CONTENT_TYPE    = 'application/json'

    UNAUTHORIZED_BODY = %({"error":"unauthorized"}\n)
    NOT_FOUND_BODY    = %({"error":"not_found"}\n)
    DRAINING_BODY     = %({"status":"draining"}\n)
    SIGNAL_FAILED     = %({"error":"signal_failed"}\n)

    attr_reader :host, :port

    def initialize(host:, port:, token:, runtime: nil, signal_target: nil)
      raise ArgumentError, 'admin listener token must be a non-empty String' if token.nil? || token.to_s.empty?

      @host          = host
      @port          = port
      @token         = token.to_s
      @runtime       = runtime || Hyperion::Runtime.default
      @signal_target = signal_target
      @stopped       = false
    end

    # Bind + spawn the accept thread. Returns self so callers can chain
    # `.start.join` or just hold the reference for `#stop`.
    def start
      @server = ::TCPServer.new(@host, @port)
      # Honour port: 0 (let kernel pick) — the test suite uses this so
      # multiple AdminListeners can coexist without port conflicts.
      @port = @server.addr[1]

      @thread = Thread.new { accept_loop }
      @thread.report_on_exception = false
      @runtime.logger.info do
        { message: 'admin listener started', host: @host, port: @port,
          paths: [PATH_QUIT, PATH_METRICS] }
      end
      self
    end

    def stop
      @stopped = true
      @server&.close
      @thread&.join(5)
      nil
    rescue StandardError
      nil
    end

    private

    def accept_loop
      until @stopped
        begin
          client = @server.accept
        rescue IOError, Errno::EBADF
          break # listener closed
        rescue StandardError => e
          @runtime.logger.warn { { message: 'admin listener accept error', error: e.message } }
          next
        end

        begin
          handle(client)
        rescue StandardError => e
          @runtime.logger.warn { { message: 'admin listener handler error', error: e.message } }
        ensure
          begin
            client.close unless client.closed?
          rescue StandardError
            nil
          end
        end
      end
    end

    # Parse one request off the socket and dispatch. We deliberately don't
    # implement keep-alive — `Connection: close` on every response is fine
    # for an admin endpoint that handles ones-of operator probes.
    def handle(socket)
      request_line = socket.gets("\r\n", 1024)
      return write_response(socket, 400, JSON_CONTENT_TYPE, NOT_FOUND_BODY) if request_line.nil?

      method, path, _http = request_line.strip.split(' ', 3)
      headers = read_headers(socket)
      # Drain Content-Length body if present (POST /-/quit may carry one).
      content_length = headers['content-length'].to_i
      socket.read(content_length) if content_length.positive?

      provided = (headers['x-hyperion-admin-token'] || '').to_s
      return write_response(socket, 401, JSON_CONTENT_TYPE, UNAUTHORIZED_BODY) unless secure_match?(provided)

      if path == PATH_QUIT && method == 'POST'
        handle_quit(socket)
      elsif path == PATH_METRICS && method == 'GET'
        handle_metrics(socket)
      else
        write_response(socket, 404, JSON_CONTENT_TYPE, NOT_FOUND_BODY)
      end
    end

    def read_headers(socket)
      headers = {}
      while (line = socket.gets("\r\n", 8192))
        line = line.strip
        break if line.empty?

        name, value = line.split(':', 2)
        next if name.nil? || value.nil?

        headers[name.strip.downcase] = value.strip
      end
      headers
    end

    def handle_quit(socket)
      target = @signal_target || Hyperion.master_pid
      @runtime.logger.info { { message: 'admin drain requested', target_pid: target, via: 'sibling-listener' } }
      begin
        Process.kill('TERM', target)
      rescue StandardError => e
        @runtime.logger.warn { { message: 'admin drain signal failed', error: e.message } }
        return write_response(socket, 500, JSON_CONTENT_TYPE, SIGNAL_FAILED)
      end

      write_response(socket, 202, JSON_CONTENT_TYPE, DRAINING_BODY)
    end

    def handle_metrics(socket)
      body = Hyperion::PrometheusExporter.render(@runtime.metrics.snapshot)
      write_response(socket, 200, METRICS_CONTENT_TYPE, body)
    end

    def secure_match?(provided)
      return false if provided.empty?
      return false unless provided.bytesize == @token.bytesize

      Rack::Utils.secure_compare(provided, @token)
    end

    def write_response(socket, status, content_type, body)
      reason = case status
               when 200 then 'OK'
               when 202 then 'Accepted'
               when 400 then 'Bad Request'
               when 401 then 'Unauthorized'
               when 404 then 'Not Found'
               when 500 then 'Internal Server Error'
               else 'Unknown'
               end
      head = +"HTTP/1.1 #{status} #{reason}\r\n" \
              "content-type: #{content_type}\r\n" \
              "content-length: #{body.bytesize}\r\n" \
              "connection: close\r\n\r\n"
      socket.write(head)
      socket.write(body)
    rescue StandardError
      # Peer hung up — nothing to do.
      nil
    end
  end
end
