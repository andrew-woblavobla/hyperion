# frozen_string_literal: true

module Hyperion
  # Drives one TCP connection through its lifecycle:
  # read until headers complete + body, parse, dispatch via Rack adapter, write, close.
  # Phase 2 adds fiber scheduling and keep-alive; the public surface (#serve)
  # is stable.
  #
  # Phase 1 assumes blocking I/O: socket.read(N) blocks until N bytes or EOF, so
  # `break if chunk.nil? || chunk.empty?` correctly detects EOF in read_request.
  # Phase 2 (fiber scheduler) introduces non-blocking semantics where short reads
  # and EAGAIN must be distinguished from EOF — read_request will need to handle
  # IO::WaitReadable explicitly at that point.
  class Connection
    READ_CHUNK                      = 16 * 1024
    MAX_HEADER_BYTES                = 64 * 1024
    MAX_BODY_BYTES                  = 16 * 1024 * 1024 # 16 MB cap. Phase 5 introduces streaming bodies.
    HEADER_TERM                     = "\r\n\r\n"
    TIMEOUT_SENTINEL                = :__hyperion_read_timeout__
    IDLE_KEEPALIVE_TIMEOUT_SECONDS  = 5

    # Default parser is the C-extension `CParser` when the extension built;
    # otherwise we fall back to the pure-Ruby `Parser`. Evaluated each call
    # because Ruby evaluates default kwargs at call time.
    def self.default_parser
      defined?(::Hyperion::CParser) ? ::Hyperion::CParser.new : ::Hyperion::Parser.new
    end

    def initialize(parser: self.class.default_parser, writer: ResponseWriter.new, thread_pool: nil,
                   log_requests: nil)
      @parser      = parser
      @writer      = writer
      @thread_pool = thread_pool
      # Cache module-level singletons once per Connection instance so the hot
      # path doesn't re-dispatch through Hyperion.metrics / Hyperion.logger
      # (each was a method call + ivar nil-check on every request).
      @metrics     = Hyperion.metrics
      @logger      = Hyperion.logger
      # Per-request access logging is ON by default (matches Puma+Rails
      # operator expectation). The hot path is optimised end-to-end: one
      # Process.clock_gettime per request, per-thread cached timestamp,
      # hand-rolled line builder, lock-free emit. Operator disables via
      # `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
      @log_requests = log_requests.nil? ? Hyperion.log_requests? : log_requests
    end

    def serve(socket, app)
      request_count = 0
      carry = +'' # bytes already pulled off the socket but past the prev request boundary
      peer_addr = peer_address(socket)
      @metrics.increment(:connections_accepted)
      @metrics.increment(:connections_active)
      loop do
        buffer = read_request(socket, carry)
        return unless buffer

        if buffer == TIMEOUT_SENTINEL
          # Idle timeout between keep-alive requests: close silently — the peer
          # never started a new request, so there's nothing to 408 about.
          @metrics.increment(:read_timeouts)
          return if request_count.positive?

          safe_write_error(socket, 408, 'Request Timeout')
          @metrics.increment_status(408)
          return
        end

        request, body_end = @parser.parse(buffer)
        carry = +(buffer.byteslice(body_end, buffer.bytesize - body_end) || '')
        request = enrich_with_peer(request, peer_addr) if peer_addr && request.peer_address.nil?

        @metrics.increment(:requests_total)
        @metrics.increment(:requests_in_flight)
        request_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) if @log_requests
        begin
          status, headers, body = call_app(app, request)
        ensure
          @metrics.decrement(:requests_in_flight)
        end

        keep_alive = should_keep_alive?(request, status, headers)
        @writer.write(socket, status, headers, body, keep_alive: keep_alive)
        @metrics.increment_status(status)
        log_request(request, status, request_started_at) if @log_requests
        request_count += 1

        return unless keep_alive

        # Idle wait between requests: don't hold a fiber forever on a quiet conn.
        set_idle_timeout(socket)
      end
    rescue ParseError => e
      @metrics.increment(:parse_errors)
      @logger.warn { { message: 'parse error', error: e.message, error_class: e.class.name } }
      safe_write_error(socket, 400, 'Bad Request')
      @metrics.increment_status(400)
    rescue UnsupportedError => e
      @logger.warn { { message: 'unsupported request', error: e.message, error_class: e.class.name } }
      safe_write_error(socket, 501, 'Not Implemented')
      @metrics.increment_status(501)
    rescue StandardError => e
      @metrics.increment(:app_errors)
      @logger.error do
        { message: 'unhandled in connection', error: e.message, error_class: e.class.name }
      end
    ensure
      @metrics.decrement(:connections_active)
      # Flush any buffered access-log lines for this thread before letting
      # the connection go idle. Otherwise a low-traffic worker would hold
      # logs in its per-thread buffer indefinitely.
      @logger.flush_access_buffer if @log_requests && @logger.respond_to?(:flush_access_buffer)
      begin
        socket.close unless socket.closed?
      rescue StandardError
        # Already failing; swallow close errors so we don't mask the real cause.
      end
    end

    private

    # Route Rack dispatch through the thread pool when one was injected,
    # otherwise run inline on the current fiber. Inline keeps the test path
    # simple (no extra threads spun up for unit specs) and provides a
    # debugging escape hatch via `Server#thread_count: 0`.
    def call_app(app, request)
      if @thread_pool
        @thread_pool.call(app, request)
      else
        Adapter::Rack.call(app, request)
      end
    end

    # Extract the peer IP from the underlying socket, if available.
    # Works for TCPSocket and OpenSSL::SSL::SSLSocket (via #io). UNIX sockets
    # return AF_UNIX with an empty path — we return nil there so the adapter
    # falls back to its localhost default.
    def peer_address(socket)
      raw = socket.respond_to?(:io) ? socket.io : socket
      return nil unless raw.respond_to?(:peeraddr)

      addr = raw.peeraddr
      ip = addr[3] || addr[2]
      return nil if ip.nil? || ip.to_s.empty?

      ip
    rescue StandardError
      nil
    end

    # Request is frozen — to enrich it we build a new value object with the
    # peer address copied in. Cheap on the fast path because we only do this
    # once per connection (peer_addr is captured before the request loop).
    def enrich_with_peer(request, peer_addr)
      Hyperion::Request.new(
        method: request.method,
        path: request.path,
        query_string: request.query_string,
        http_version: request.http_version,
        headers: request.headers,
        body: request.body,
        peer_address: peer_addr
      )
    end

    def should_keep_alive?(request, _status, headers)
      # App-emitted Connection: close wins.
      conn_response = headers.find { |k, _| k.to_s.downcase == 'connection' }
      return false if conn_response && conn_response.last.to_s.downcase == 'close'

      # Request-side Connection header.
      conn_request = request.header('connection')&.downcase

      case request.http_version
      when 'HTTP/1.1'
        conn_request != 'close'
      when 'HTTP/1.0'
        conn_request == 'keep-alive'
      else
        false
      end
    end

    def set_idle_timeout(socket)
      socket.timeout = IDLE_KEEPALIVE_TIMEOUT_SECONDS if socket.respond_to?(:timeout=)
    rescue StandardError
      # Best-effort; if the socket type doesn't support it, read_chunk's
      # IO.select fallback still gives us a deadline via read_timeout_for.
    end

    # Reads one complete request off the socket. `carry` is bytes already
    # buffered from the previous request's trailing read (keep-alive
    # pipelining). Returns the full buffer (with any trailing pipelined
    # bytes intact); the parser's returned end_offset tells the caller
    # where this request ends. On EOF returns nil; on read timeout returns
    # TIMEOUT_SENTINEL.
    def read_request(socket, carry = +'')
      buffer = carry
      until buffer.include?(HEADER_TERM)
        chunk = read_chunk(socket)
        return chunk if chunk.nil? || chunk == TIMEOUT_SENTINEL
        return nil if chunk.empty?

        buffer << chunk
        raise ParseError, 'header section too large' if buffer.bytesize > MAX_HEADER_BYTES
      end

      header_end = buffer.index(HEADER_TERM) + HEADER_TERM.bytesize
      headers_part = buffer.byteslice(0, header_end)

      if chunked?(headers_part)
        until chunked_body_complete?(buffer, header_end)
          raise ParseError, 'chunked body exceeds limit' if buffer.bytesize - header_end > MAX_BODY_BYTES

          chunk = read_chunk(socket)
          break if chunk.nil? || chunk.empty? || chunk == TIMEOUT_SENTINEL

          buffer << chunk
        end
      else
        content_length = headers_part[/^content-length:\s*(\d+)/i, 1].to_i
        while buffer.bytesize < header_end + content_length
          chunk = read_chunk(socket)
          break if chunk.nil? || chunk.empty? || chunk == TIMEOUT_SENTINEL

          buffer << chunk
        end
      end

      buffer
    end

    def chunked?(headers_part)
      headers_part.match?(/^transfer-encoding:[ \t]*[^\r\n]*chunked\b/i)
    end

    # Walks chunked framing in `buffer` starting at `body_start` and
    # returns true once the final 0-sized chunk (and trailer terminator)
    # is fully buffered. Mirrors the parser's dechunk walk; Phase 4's C
    # parser folds these together via incremental parsing.
    def chunked_body_complete?(buffer, body_start)
      cursor = body_start
      loop do
        line_end = buffer.index("\r\n", cursor)
        return false unless line_end

        size_line = buffer.byteslice(cursor, line_end - cursor)
        size_token = size_line.split(';').first.to_s.strip
        return false if size_token.empty?

        size = size_token.to_i(16)
        cursor = line_end + 2

        if size.zero?
          loop do
            nl = buffer.index("\r\n", cursor)
            return false unless nl
            return true if nl == cursor

            cursor = nl + 2
          end
        end

        return false if buffer.bytesize < cursor + size + 2

        cursor += size + 2
      end
    end

    # Read up to READ_CHUNK bytes, returning whatever's available. Unlike
    # IO#read(N) — which blocks until N bytes or EOF — read_nonblock returns
    # as soon as any data arrives, which is what we need for live HTTP
    # clients that send a small request and then wait for a response on
    # the same socket without closing the write half.
    #
    # Phase 8 perf fix: try read_nonblock FIRST, only fall through to IO.select
    # if no data is buffered. wrk and other benchmarkers pre-buffer the entire
    # request so the first readpartial succeeds and we skip the select syscall
    # entirely. The IO.select fallback still gives us a deterministic deadline
    # against stalled peers (SO_RCVTIMEO and IO#timeout= don't reliably trip
    # readpartial on Ruby 3.3).
    def read_chunk(socket)
      result = socket.read_nonblock(READ_CHUNK, exception: false)
      return result if result.is_a?(String) # hot path: data was buffered, return immediately
      return nil if result.nil?             # EOF

      # :wait_readable — fall back to IO.select with a deadline.
      timeout = read_timeout_for(socket)
      ready, = IO.select([socket], nil, nil, timeout)
      return TIMEOUT_SENTINEL if ready.nil?

      retry_read_nonblock(socket)
    rescue EOFError
      nil
    rescue Errno::EAGAIN, Errno::EWOULDBLOCK, IO::TimeoutError
      TIMEOUT_SENTINEL
    end

    def retry_read_nonblock(socket)
      socket.read_nonblock(READ_CHUNK)
    rescue IO::WaitReadable
      TIMEOUT_SENTINEL
    rescue EOFError
      nil
    end

    def read_timeout_for(socket)
      socket.respond_to?(:timeout) && socket.timeout || 30
    rescue StandardError
      30
    end

    def safe_write_error(socket, status, body_text)
      @writer.write(socket, status, { 'content-type' => 'text/plain' }, [body_text])
    rescue StandardError => e
      @logger.error do
        { message: 'failed to write error response', error: e.message, error_class: e.class.name }
      end
    end

    # Emit one structured access-log line per response. Default ON; operator
    # disables via `--no-log-requests`. Routes through Logger#access which
    # uses a hand-rolled single-interpolation builder + per-thread cached
    # timestamp + lock-free emit (no mutex, no flush) — at 16 threads the
    # default-ON path runs within a few percent of the disabled path.
    def log_request(request, status, started_at)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
      @logger.access(
        request.method,
        request.path,
        request.query_string,
        status,
        duration_ms,
        request.peer_address,
        request.http_version
      )
    end
  end
end
