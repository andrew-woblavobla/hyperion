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
    DEADLINE_SENTINEL               = :__hyperion_request_deadline__
    OVERSIZED_BODY_SENTINEL         = :__hyperion_oversized_body__
    IDLE_KEEPALIVE_TIMEOUT_SECONDS  = 5
    # Phase 2b (1.7.1) — per-Connection pre-sized scratch buffer for the
    # read accumulator. Most HTTP/1.1 request lines + headers fit in a few
    # hundred bytes; 8 KiB covers ~99% of legitimate traffic without ever
    # re-allocating. We reuse the same String across keep-alive requests on
    # the same connection (clear between requests preserves capacity).
    # Requests larger than 8 KiB still parse correctly — `String#<<` grows
    # the underlying buffer transparently — they just pay the realloc the
    # first time, same as the pre-1.7.1 behaviour.
    INBUF_INITIAL_CAPACITY          = 8 * 1024

    # Pre-built canned 413 — body is small + plain text, connection forced
    # closed. Reused across every oversized-CL rejection so the DOS-defense
    # path stays allocation-free and never has to dip into ResponseWriter
    # (which would require a full Rack-style headers hash for an error
    # we can answer with frozen bytes).
    REJECT_413_PAYLOAD_TOO_LARGE = (+"HTTP/1.1 413 Payload Too Large\r\n" \
                                     "content-type: text/plain\r\n" \
                                     "content-length: 18\r\n" \
                                     "connection: close\r\n" \
                                     "\r\n" \
                                     "payload too large\n").freeze

    # Default parser is the C-extension `CParser` when the extension built;
    # otherwise we fall back to the pure-Ruby `Parser`. Evaluated each call
    # because Ruby evaluates default kwargs at call time.
    def self.default_parser
      defined?(::Hyperion::CParser) ? ::Hyperion::CParser.new : ::Hyperion::Parser.new
    end

    def initialize(parser: self.class.default_parser, writer: ResponseWriter.new, thread_pool: nil,
                   log_requests: nil, max_body_bytes: MAX_BODY_BYTES, runtime: nil)
      @parser         = parser
      @writer         = writer
      @thread_pool    = thread_pool
      @max_body_bytes = max_body_bytes
      # 1.7.0: explicit Runtime injection. When the caller passes
      # `runtime:`, that runtime is the sole source of metrics + logger
      # for this connection — no implicit fallback to module-level
      # singletons. When omitted, fall back to `Runtime.default` so
      # legacy callers keep working untouched.
      #
      # We still cache the metrics/logger refs in ivars (vs reading
      # `runtime.metrics` per request) so the hot path doesn't pay a
      # method-dispatch per increment. Long-lived keep-alive connections
      # therefore see a Runtime swap only at construction — that's a
      # 1.7.0 limitation; 2.0 drops the singleton entirely and the
      # ivar cache becomes the only path.
      if runtime
        @runtime = runtime
        @metrics = runtime.metrics
        @logger  = runtime.logger
      else
        # No explicit runtime → keep the 1.6.x shape: ivars cache the
        # module-level accessors. This preserves stub seams used by
        # existing specs (`allow(Hyperion).to receive(:metrics)`) and
        # the `Hyperion.instance_variable_set(:@metrics, ...)` swap.
        @runtime = Hyperion::Runtime.default
        @metrics = Hyperion.metrics
        @logger  = Hyperion.logger
      end
      # Per-request access logging is ON by default (matches Puma+Rails
      # operator expectation). The hot path is optimised end-to-end: one
      # Process.clock_gettime per request, per-thread cached timestamp,
      # hand-rolled line builder, lock-free emit. Operator disables via
      # `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
      @log_requests = if log_requests.nil?
                        # Per-Connection override absent → consult the
                        # Runtime's logging config (1.7.0+) which falls
                        # through to `Hyperion.log_requests?` (env +
                        # default ON).
                        Hyperion.log_requests?
                      else
                        log_requests
                      end
    end

    def serve(socket, app, max_request_read_seconds: 60)
      request_count = 0
      # Phase 2b (1.7.1): pre-size the read accumulator once per connection
      # and reuse it across keep-alive requests. `String#clear` between
      # requests preserves the underlying capacity, so subsequent appends
      # don't pay the realloc tax. Pre-1.7.1 allocated a fresh `+''` per
      # request; per-connection reuse is a strict win because the previous
      # request's carry-over bytes (pipelined input) are copied into this
      # same buffer at the bottom of the loop instead of into a new String.
      @inbuf ||= String.new(capacity: INBUF_INITIAL_CAPACITY, encoding: Encoding::ASCII_8BIT)
      peer_addr = peer_address(socket)
      @metrics.increment(:connections_accepted)
      @metrics.increment(:connections_active)
      loop do
        # Per-request wallclock deadline. Captured fresh for every request so
        # long-lived keep-alive sessions with many small requests don't
        # falsely trip after the cumulative budget elapses.
        request_started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) if max_request_read_seconds
        buffer = read_request(socket, @inbuf, deadline_started_at: request_started_clock,
                                              max_request_read_seconds: max_request_read_seconds,
                                              peer_addr: peer_addr)
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

        # Slowloris-style abort: deadline tripped during read. We've already
        # written the 408 (best-effort) inside read_request; close out here.
        return if buffer == DEADLINE_SENTINEL

        # DOS-defense: client declared a Content-Length larger than
        # max_body_bytes. We've already written the canned 413 + close inside
        # read_request, BEFORE reading any body bytes. Drop the connection.
        return if buffer == OVERSIZED_BODY_SENTINEL

        request, body_end = @parser.parse(buffer)
        # Carry over any pipelined trailing bytes for the next iteration. We
        # rewrite @inbuf in place — `replace` keeps the underlying capacity
        # allocation, so the next request starts with a warm 8 KiB buffer.
        carry_into_inbuf!(buffer, body_end)
        request = enrich_with_peer(request, peer_addr) if peer_addr && request.peer_address.nil?

        @metrics.increment(:bytes_read, body_end)
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

    # Phase 2b: collapse @inbuf in place to retain only the carry-over (any
    # bytes past the parsed request boundary, used for keep-alive pipelining).
    # Operates byte-wise so the underlying capacity allocation stays put —
    # `String#replace` with `byteslice` would allocate a fresh substring AND
    # then memcpy back. Splice-with-empty keeps everything in the original
    # buffer.
    EMPTY_BIN = String.new('', encoding: Encoding::ASCII_8BIT).freeze
    def carry_into_inbuf!(buffer, body_end)
      total = buffer.bytesize
      if body_end >= total
        buffer.clear
      else
        # Splice the [0, body_end) prefix away. Ruby's String#[]=(start, len, "")
        # performs an in-place shift of the remaining bytes — no new String
        # allocation, capacity preserved.
        buffer[0, body_end] = EMPTY_BIN
      end
    end

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
    # TIMEOUT_SENTINEL; on per-request wallclock deadline trip returns
    # DEADLINE_SENTINEL (and emits a best-effort 408 + close).
    def read_request(socket, carry = +'', deadline_started_at: nil, max_request_read_seconds: nil,
                     peer_addr: nil)
      buffer = carry
      until buffer.include?(HEADER_TERM)
        if deadline_exceeded?(deadline_started_at, max_request_read_seconds)
          return abort_for_deadline(socket, deadline_started_at, peer_addr)
        end

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
          if deadline_exceeded?(deadline_started_at, max_request_read_seconds)
            return abort_for_deadline(socket, deadline_started_at, peer_addr)
          end

          chunk = read_chunk(socket)
          break if chunk.nil? || chunk.empty? || chunk == TIMEOUT_SENTINEL

          buffer << chunk
        end
      else
        content_length = headers_part[/^content-length:\s*(\d+)/i, 1].to_i
        # DOS-defense: cap declared Content-Length at max_body_bytes BEFORE
        # we touch the socket again. An attacker advertising
        # `Content-Length: 99999999999` should not get us to allocate a
        # multi-GB read buffer or sit in the read loop draining their
        # body. The pure-int comparison itself is bounded — Ruby's `to_i`
        # on the regex capture stops at the first non-digit, so even an
        # adversarial header value can't blow up here. Negative or
        # malformed values fall through to the parser (which raises
        # ParseError → 400) so existing behaviour is preserved.
        return abort_for_oversized_body(socket, content_length, peer_addr) if content_length > @max_body_bytes

        while buffer.bytesize < header_end + content_length
          if deadline_exceeded?(deadline_started_at, max_request_read_seconds)
            return abort_for_deadline(socket, deadline_started_at, peer_addr)
          end

          chunk = read_chunk(socket)
          break if chunk.nil? || chunk.empty? || chunk == TIMEOUT_SENTINEL

          buffer << chunk
        end
      end

      buffer
    end

    # nil-disabled or budget-untripped → false. Otherwise the wallclock cap
    # has been exceeded and the caller should abort.
    def deadline_exceeded?(started_at, max_seconds)
      return false unless started_at && max_seconds

      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) > max_seconds
    end

    # Slowloris fallback: log a structured warn, bump :slow_request_aborts,
    # write a best-effort 408, and let the caller close the socket. We don't
    # wait on the 408 write — a dribbling client may never read it, and
    # that's the failure mode we're protecting against anyway.
    def abort_for_deadline(socket, started_at, peer_addr)
      elapsed = started_at ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3) : nil
      @metrics.increment(:slow_request_aborts)
      @logger.warn do
        { message: 'request read deadline exceeded', remote_addr: peer_addr, elapsed_seconds: elapsed }
      end
      begin
        socket.write("HTTP/1.1 408 Request Timeout\r\nconnection: close\r\ncontent-length: 0\r\n\r\n")
      rescue StandardError
        # Peer may have already gone — nothing to do.
      end
      @metrics.increment_status(408)
      DEADLINE_SENTINEL
    end

    # DOS-defense fallback: declared Content-Length exceeds the configured
    # max_body_bytes. Emit a canned 413 + close BEFORE reading any body
    # bytes off the socket — that's the whole point of the cap. Best-effort
    # write so a peer that's already gone away doesn't trip an exception
    # we'd swallow in the rescue clause anyway.
    def abort_for_oversized_body(socket, declared_length, peer_addr)
      @metrics.increment(:oversized_body_rejects)
      @logger.warn do
        {
          message: 'rejected oversized Content-Length',
          remote_addr: peer_addr,
          declared_length: declared_length,
          max_body_bytes: @max_body_bytes
        }
      end
      begin
        socket.write(REJECT_413_PAYLOAD_TOO_LARGE)
      rescue StandardError
        # Peer may have already gone — nothing to do.
      end
      @metrics.increment_status(413)
      OVERSIZED_BODY_SENTINEL
    end

    def chunked?(headers_part)
      headers_part.match?(/^transfer-encoding:[ \t]*[^\r\n]*chunked\b/i)
    end

    # Walks chunked framing in `buffer` starting at `body_start` and
    # returns true once the final 0-sized chunk (and trailer terminator)
    # is fully buffered. The C extension folds the size-line scan + hex
    # decode + chunk advance into a single tight loop with no per-iteration
    # Ruby allocation; the pure-Ruby fallback below preserves the original
    # semantics for environments where the C extension didn't build.
    def chunked_body_complete?(buffer, body_start)
      if self.class.c_chunked_available?
        ::Hyperion::CParser.chunked_body_complete?(buffer, body_start).first
      else
        chunked_body_complete_ruby?(buffer, body_start)
      end
    end

    # Whether Hyperion::CParser.chunked_body_complete? is available. Probed
    # lazily at first use; memoised in a class-level ivar to keep the
    # per-request hot path branchless.
    def self.c_chunked_available?
      return @c_chunked_available unless @c_chunked_available.nil?

      @c_chunked_available = defined?(::Hyperion::CParser) &&
                             ::Hyperion::CParser.respond_to?(:chunked_body_complete?)
    end

    def chunked_body_complete_ruby?(buffer, body_start)
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
