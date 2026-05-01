# frozen_string_literal: true

require 'time'

module Hyperion
  # Serializes a Rack [status, headers, body] tuple to an HTTP/1.1 wire stream.
  # Phase 5 adds a chunked-streaming path with per-connection write coalescing;
  # Phase 7 adds a sibling Http2ResponseWriter. Public surface (#write) stays
  # stable.
  class ResponseWriter
    # Phase 5 — chunked-write coalescing tunables. Chunks smaller than the
    # threshold accumulate in a per-response buffer; the buffer flushes on
    # any of (a) >= COALESCE_FLUSH_BYTES filled, (b) the writer-fiber tick
    # of COALESCE_TICK_SECONDS elapsed since the last buffer drain, or
    # (c) end-of-body / explicit body.flush. Picked to keep added latency
    # under 1 ms while still cutting syscall count 3-5× on SSE / streaming
    # JSON / log-tail workloads where per-event payloads are ~50 B.
    COALESCE_SMALL_CHUNK_BYTES = 512
    COALESCE_FLUSH_BYTES       = 4096
    COALESCE_TICK_SECONDS      = 0.001
    CHUNKED_TERMINATOR         = "0\r\n\r\n"

    REASONS = {
      200 => 'OK',
      201 => 'Created',
      204 => 'No Content',
      301 => 'Moved Permanently',
      302 => 'Found',
      304 => 'Not Modified',
      400 => 'Bad Request',
      401 => 'Unauthorized',
      403 => 'Forbidden',
      404 => 'Not Found',
      405 => 'Method Not Allowed',
      408 => 'Request Timeout',
      409 => 'Conflict',
      410 => 'Gone',
      413 => 'Payload Too Large',
      414 => 'URI Too Long',
      422 => 'Unprocessable Entity',
      429 => 'Too Many Requests',
      500 => 'Internal Server Error',
      501 => 'Not Implemented',
      502 => 'Bad Gateway',
      503 => 'Service Unavailable',
      504 => 'Gateway Timeout'
    }.freeze

    CRLF_HEADER_VALUE = /[\r\n]/

    # 2.6-C — `dispatch_mode:` is the per-response opt-in dispatch shape
    # (typically `:inline_blocking` for static-file routes auto-detected
    # by `Adapter::Rack#call`, or `nil` for the default fiber-yielding
    # path).  Only the sendfile branch consumes it today; the chunked
    # and buffered branches ignore it (no fiber-yield in their hot
    # loop to begin with).  Forward-compatible — future per-response
    # dispatch shapes plug in here without changing the call-site
    # arity for non-sendfile branches.
    def write(io, status, headers, body, keep_alive: false, dispatch_mode: nil)
      # Zero-copy fast path: bodies that point at an on-disk file (Rack::Files,
      # asset servers, signed-download responders) get streamed via
      # IO.copy_stream which delegates to sendfile(2) on Linux for plain TCP
      # sockets — bytes go from the file's page cache straight to the socket
      # buffer with no userspace allocation. For TLS sockets we still avoid the
      # multi-MB String build, but encryption forces a userspace round-trip so
      # we count that path separately. Phase 5 leaves this branch untouched —
      # sendfile bypasses the chunked coalescer entirely (the file IS the body
      # buffer, no userspace chunks to coalesce).
      if body.respond_to?(:to_path)
        return write_sendfile(io, status, headers, body, keep_alive: keep_alive,
                                                         dispatch_mode: dispatch_mode)
      end

      # Phase 5 — opt-in chunked streaming path. The app sets
      # `Transfer-Encoding: chunked` to signal "this body is a stream; do not
      # buffer". We then iterate `body.each` and emit each chunk in chunked
      # framing (size-line + payload + CRLF), coalescing chunks <512 B in a
      # per-response buffer to cut syscall count on SSE / streaming JSON.
      return write_chunked(io, status, headers, body, keep_alive: keep_alive) if chunked_transfer?(headers)

      write_buffered(io, status, headers, body, keep_alive: keep_alive)
    end

    private

    def write_buffered(io, status, headers, body, keep_alive:)
      # Phase 1 buffers the full body so Content-Length is exact.
      # Phase 2 introduces chunked transfer-encoding for streaming bodies;
      # Phase 5 batches via IO::Buffer to avoid this intermediate String.
      #
      # Phase 11 — single-element-Array fast path. The overwhelmingly
      # common Rack body shape is `[body_string]` (Rails ActionController,
      # Sinatra, Grape, hand-rolled lambdas). For that shape we skip the
      # `+''` accumulator entirely and treat body[0] as the buffered
      # bytes directly. Multi-chunk bodies and Enumerator-style bodies
      # still take the original loop. Saves one String allocation per
      # response on the hot path; saves the per-chunk `<<` overhead too.
      buffered = nil
      if body.is_a?(Array) && body.length == 1
        chunk = body[0]
        buffered = chunk if chunk.is_a?(String)
      end

      if buffered.nil?
        buffered = +''
        body.each { |chunk| buffered << chunk }
      end

      reason = REASONS[status] || 'Unknown'
      date_str = cached_date

      head = build_head(status, reason, headers, buffered.bytesize, keep_alive, date_str)

      # Phase 8 perf fix: coalesce status line + all headers + body into a
      # SINGLE io.write call. Each syscall round-trip is ~1 usec on macOS
      # kqueue; before this change we issued (1 status) + (N headers) + (1 blank)
      # + (1 body) = 8+ syscalls per response. Now: 1 syscall.
      bytes_out = if buffered.empty?
                    io.write(head)
                    head.bytesize
                  else
                    # Concatenate into the head buffer (which is already a fresh +''
                    # from the C builder or the Ruby fallback) so we still emit a
                    # single write.
                    head << buffered
                    io.write(head)
                    head.bytesize
                  end
      Hyperion.metrics.increment(:bytes_written, bytes_out)
    ensure
      body.close if body.respond_to?(:close)
    end

    # 2.0.1 Phase 8 — coalesce head + body into ONE write for small
    # static files. With Nagle on (kernel default) and TCP_NODELAY off,
    # `io.write(head)` followed by a separate `write(body)` for an 8 KB
    # asset stalled ~40 ms per response on the client's delayed-ACK
    # waiting for the next packet to fill an MSS — capping the static
    # 8 KB row at 121 r/s vs Puma 1,246. By concatenating head + body
    # into a single read+write under the threshold (= Sendfile small-
    # file fast path), the response goes out as one TCP segment train
    # and the client ACKs immediately. No setsockopt churn required.
    SENDFILE_COALESCE_THRESHOLD = 64 * 1024

    def write_sendfile(io, status, headers, body, keep_alive:, dispatch_mode: nil)
      # 2.6-D — when `:inline_blocking` is engaged, wrap the entire
      # write path in `Fiber.blocking { ... }` so the calling fiber's
      # `Fiber.current.blocking?` flag flips to true for the duration
      # of the response.  Without this wrap, `IO.select` and `io.write`
      # inside the helpers below silently route through the Async
      # fiber scheduler under `--async-io` — that was the 2.6-C
      # engagement gap (resolver set `:inline_blocking`, writer
      # plumbed it, but every blocking IO call still yielded the
      # fiber).  With the wrap, the OS thread parks on the kernel
      # write under the GVL — the whole point of the dispatch mode.
      #
      # `Fiber.blocking` is a no-op when no scheduler is current
      # (default threadpool / inline_h1_no_pool / no-async paths) so
      # the perf cost is one method-dispatch when this branch is
      # never the hot path.
      if dispatch_mode == :inline_blocking
        return Fiber.blocking do
          write_sendfile_inner(io, status, headers, body, keep_alive: keep_alive,
                                                          dispatch_mode: dispatch_mode)
        end
      end

      write_sendfile_inner(io, status, headers, body, keep_alive: keep_alive,
                                                      dispatch_mode: dispatch_mode)
    end

    def write_sendfile_inner(io, status, headers, body, keep_alive:, dispatch_mode: nil)
      path = body.to_path
      file = File.open(path, 'rb')
      file_size = file.size

      # If the app explicitly set content-length, respect it; otherwise use the
      # real file size. Rack::Files does not pre-set content-length, so the
      # common case is the File.size branch.
      content_length = explicit_content_length(headers) || file_size

      reason = REASONS[status] || 'Unknown'
      date_str = cached_date
      head = build_head(status, reason, headers, content_length, keep_alive, date_str)

      head_bytes = head.bytesize

      # Phase 8 small-file coalescing. For files <= 64 KiB, read the
      # body bytes inline and emit head + body as one write. This
      # bypasses the Nagle delayed-ACK stall completely (one TCP
      # segment train carries everything; client ACKs the whole
      # response, no second write parked waiting for an ACK on the
      # first). Bonus: skips the syscall round-trip into copy_small.
      copied =
        if file_size.positive? && file_size <= SENDFILE_COALESCE_THRESHOLD
          body_bytes = file.read(file_size)
          head << body_bytes if body_bytes
          io.write(head)
          file_size
        else
          # Streaming path for larger files. 1.7.0 Phase 1 —
          # Hyperion::Http::Sendfile picks the best kernel route:
          #   * Linux + plain TCPSocket → native sendfile(2) (true
          #     zero-copy, page cache → socket buffer, no userspace
          #     intermediate).
          #   * Darwin / *BSD + plain TCPSocket → BSD sendfile(2).
          #   * TLS-wrapped sockets → 64 KiB IO.copy_stream loop
          #     (kernel can't encrypt for us; we still bypass the
          #     per-chunk fiber-hop).
          #   * Hosts where the C ext didn't compile → IO.copy_stream
          #     fallback.
          #
          # 2.6-C — when `dispatch_mode == :inline_blocking` the loop
          # uses `IO.select` + GVL-blocking sendfile instead of
          # fiber-yielding `wait_writable`.  Auto-detected by
          # `Adapter::Rack#call` for `to_path` bodies that don't carry
          # a streaming marker; opt-in via
          # `env['hyperion.dispatch_mode'] = :inline_blocking` for
          # routes the auto-detect doesn't catch.  Default `nil` /
          # any other symbol stays on the fiber-yielding path so
          # existing callers (TLS h1 / async-io / threadpool dispatch)
          # are unaffected.
          io.write(head)
          if dispatch_mode == :inline_blocking
            ::Hyperion::Http::Sendfile.copy_to_socket_blocking(io, file, 0, file_size)
          else
            ::Hyperion::Http::Sendfile.copy_to_socket(io, file, 0, file_size)
          end
        end

      record_zero_copy_metric(io)
      Hyperion.metrics.increment(:bytes_written, head_bytes + copied)
    ensure
      file&.close
      body.close if body.respond_to?(:close)
    end

    def explicit_content_length(headers)
      headers.each do |k, v|
        return v.to_i if k.to_s.casecmp('content-length').zero?
      end
      nil
    end

    # True when the app explicitly opted into chunked transfer-encoding.
    # We only stream when asked — for the common "buffer the whole thing
    # and emit one Content-Length response" case, the existing single-write
    # path is still optimal (one syscall, no chunked-framing overhead).
    def chunked_transfer?(headers)
      headers.each do |k, v|
        next unless k.to_s.casecmp('transfer-encoding').zero?

        return v.to_s.downcase.include?('chunked')
      end
      false
    end

    # Phase 5 — streaming chunked writer with per-response coalescing.
    #
    # Wire format per RFC 7230 §4.1:
    #   <hex-size>\r\n<payload>\r\n  for each chunk
    #   0\r\n\r\n                    terminator
    #
    # Coalescing rules:
    #   * Chunks < COALESCE_SMALL_CHUNK_BYTES (512) accumulate in a per-
    #     response buffer rather than triggering an immediate syscall.
    #   * The buffer drains as soon as it reaches COALESCE_FLUSH_BYTES (4096)
    #     or a 1 ms writer-fiber tick elapses (best-effort; only meaningful
    #     under Async).
    #   * Chunks >= COALESCE_SMALL_CHUNK_BYTES drain the buffer first (to
    #     preserve order on the wire) then emit the large chunk directly.
    #   * If the body responds to #flush or yields :__hyperion_flush__, the
    #     buffer drains immediately — SSE servers use this to push events
    #     past per-event coalescing latency.
    #   * body.close (or end-of-each) drains the buffer and appends the
    #     0\r\n\r\n terminator in a single syscall (atomic w.r.t. the wire).
    def write_chunked(io, status, headers, body, keep_alive:)
      reason = REASONS[status] || 'Unknown'
      date_str = cached_date
      head = build_head_chunked(status, reason, headers, keep_alive, date_str)

      io.write(head)
      bytes_out = head.bytesize

      coalescer = ChunkedCoalescer.new(io)
      body.each do |chunk|
        next if chunk.nil?

        if chunk.equal?(:__hyperion_flush__) || chunk == :__hyperion_flush__
          coalescer.force_flush!
          next
        end

        bytes = chunk.to_s
        next if bytes.empty?

        coalescer.write_chunk(bytes)
      end

      coalescer.flush_and_terminate!
      bytes_out += coalescer.bytes_written
      Hyperion.metrics.increment(:bytes_written, bytes_out)
      Hyperion.metrics.increment(:chunked_responses)
      Hyperion.metrics.increment(:chunked_coalesced_writes, coalescer.coalesced_write_count)
      Hyperion.metrics.increment(:chunked_total_writes, coalescer.total_write_count)
    ensure
      body.close if body.respond_to?(:close)
    end

    # Per-response coalescing buffer. Holds <512 B chunks until either
    # the 4 KiB threshold is hit, the 1 ms writer-fiber tick elapses, or
    # an explicit flush / end-of-body fires. One instance per response;
    # not shared across the connection (state lifecycle = response
    # lifecycle, matches the Stepable-style "per-call object" pattern).
    class ChunkedCoalescer
      attr_reader :bytes_written, :coalesced_write_count, :total_write_count

      def initialize(io)
        @io                     = io
        @buffer                 = String.new(capacity: ResponseWriter::COALESCE_FLUSH_BYTES,
                                             encoding: Encoding::ASCII_8BIT)
        @bytes_written          = 0
        @total_write_count      = 0
        @coalesced_write_count  = 0
        @last_drain_at          = monotonic_now
      end

      # Append a chunk into the wire stream. Small chunks coalesce into the
      # buffer; large chunks drain the buffer first then write directly.
      # Returns the number of body-bytes consumed (used by metrics).
      def write_chunk(payload)
        framed = frame_chunk(payload)
        if payload.bytesize < ResponseWriter::COALESCE_SMALL_CHUNK_BYTES
          append_to_buffer(framed)
          maybe_tick_flush
        else
          # Big chunk: drain anything we've accumulated first so that
          # bytes hit the wire in body-yield order, then write the big
          # chunk in its own syscall (no point coalescing — it's already
          # past the threshold).
          drain_buffer!
          do_write(framed)
        end
        payload.bytesize
      end

      # External flush (body responded to flush, or yielded the flush
      # sentinel). Drains the buffer; safe to call when the buffer is empty.
      def force_flush!
        drain_buffer!
      end

      # End-of-body. Drain any buffered bytes AND emit the chunked terminator
      # in a single syscall — this preserves the "terminator follows the last
      # chunk atomically" invariant on the wire (otherwise a peer could see
      # a half-flushed response if the writer fiber were preempted between
      # our flush + terminator writes).
      def flush_and_terminate!
        if @buffer.empty?
          do_write(ResponseWriter::CHUNKED_TERMINATOR)
        else
          @buffer << ResponseWriter::CHUNKED_TERMINATOR
          drain_buffer!
        end
      end

      private

      # Hex-size + CRLF + payload + CRLF (RFC 7230 §4.1). The size field is
      # lowercased hex without a 0x prefix; bytesize is correct on
      # ASCII-8BIT-encoded inputs (which is what comes off the socket / Rack).
      def frame_chunk(payload)
        size_line = payload.bytesize.to_s(16)
        framed = String.new(capacity: size_line.bytesize + payload.bytesize + 4,
                            encoding: Encoding::ASCII_8BIT)
        framed << size_line << "\r\n" << payload.b << "\r\n"
        framed
      end

      def append_to_buffer(framed)
        @buffer << framed
        return unless @buffer.bytesize >= ResponseWriter::COALESCE_FLUSH_BYTES

        drain_buffer!
      end

      # Best-effort 1 ms tick. We don't spawn a real timer fiber per
      # response — that would cost more than the syscall savings on a
      # short-lived coalescer. Instead we check the wallclock on each
      # chunk arrival; if the buffer has been sitting for >= 1 ms we
      # drain it. Under Async, the per-fiber kernel_sleep round-trip
      # between body.each chunks gives us a natural tick on the slow
      # cadence path. End-of-body always flushes regardless.
      def maybe_tick_flush
        return if @buffer.empty?
        return if (monotonic_now - @last_drain_at) < ResponseWriter::COALESCE_TICK_SECONDS

        drain_buffer!
      end

      def drain_buffer!
        return if @buffer.empty?

        do_write(@buffer)
        @coalesced_write_count += 1
        @buffer = String.new(capacity: ResponseWriter::COALESCE_FLUSH_BYTES,
                             encoding: Encoding::ASCII_8BIT)
        @last_drain_at = monotonic_now
      end

      def do_write(bytes)
        @io.write(bytes)
        @bytes_written     += bytes.bytesize
        @total_write_count += 1
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # Plain TCPSocket → real sendfile(2). TLS-wrapped sockets cannot use
    # sendfile (kernel can't encrypt) but still avoid the per-response String
    # allocation, so we track them under a separate counter.
    def record_zero_copy_metric(io)
      if defined?(::OpenSSL::SSL::SSLSocket) && io.is_a?(::OpenSSL::SSL::SSLSocket)
        Hyperion.metrics.increment(:tls_zerobuf_responses)
      else
        Hyperion.metrics.increment(:sendfile_responses)
      end
    end

    # rc17: prefer the C extension when available — eliminates the per-response
    # status-line interpolation, normalized hash, and per-header String#<<
    # allocations. Pure-Ruby fallback covers JRuby/TruffleRuby/build failures.
    def build_head(status, reason, headers, body_size, keep_alive, date_str)
      if defined?(::Hyperion::CParser) && ::Hyperion::CParser.respond_to?(:build_response_head)
        ::Hyperion::CParser.build_response_head(status, reason, headers, body_size, keep_alive, date_str)
      else
        build_head_ruby(status, reason, headers, body_size, keep_alive, date_str)
      end
    end

    # Cached HTTP `Date:` header at second resolution. `Time.now.httpdate`
    # allocates several strings; at high r/s the cache reuses one String per
    # second per OS thread instead of allocating per response. Stored as a
    # thread variable (truly thread-local across fibers) so under Async
    # every fiber on this thread shares the same cache — otherwise each
    # fiber would rebuild the httpdate String on its first response after
    # a second tick.
    def cached_date
      now_s = Process.clock_gettime(Process::CLOCK_REALTIME, :second)
      thread = Thread.current
      cache = thread.thread_variable_get(:__hyperion_date_cache__)
      if cache.nil?
        cache = [-1, '']
        thread.thread_variable_set(:__hyperion_date_cache__, cache)
      end
      return cache[1] if cache[0] == now_s

      cache[0] = now_s
      cache[1] = Time.now.httpdate
      cache[1]
    end

    def build_head_ruby(status, reason, headers, body_size, keep_alive, date_str)
      normalized = {}
      headers.each { |k, v| normalized[k.to_s.downcase] = v }
      normalized['content-length'] = body_size.to_s
      # Keep-alive negotiated by Connection layer; ResponseWriter just emits it.
      normalized['connection']     = keep_alive ? 'keep-alive' : 'close'
      normalized['date']         ||= date_str

      buf = +"HTTP/1.1 #{status} #{reason}\r\n"
      normalized.each do |k, v|
        value = v.to_s
        raise ArgumentError, "header #{k.inspect} contains CR/LF" if value.match?(CRLF_HEADER_VALUE)

        buf << k << ': ' << value << "\r\n"
      end
      buf << "\r\n"
      buf
    end

    # Phase 5 — chunked-transfer-encoding head. Mirrors build_head_ruby but
    # emits `transfer-encoding: chunked` instead of `content-length` (the
    # two are mutually exclusive per RFC 7230 §3.3.3). Always Ruby (no C
    # builder yet — this is a low-volume opt-in path; the C builder
    # currently always emits content-length).
    def build_head_chunked(status, reason, headers, keep_alive, date_str)
      normalized = {}
      headers.each do |k, v|
        key = k.to_s.downcase
        next if key == 'content-length' # Mutually exclusive with chunked.
        next if key == 'transfer-encoding' # We re-emit ourselves below.

        normalized[key] = v
      end
      normalized['transfer-encoding'] = 'chunked'
      normalized['connection']        = keep_alive ? 'keep-alive' : 'close'
      normalized['date']            ||= date_str

      buf = +"HTTP/1.1 #{status} #{reason}\r\n"
      normalized.each do |k, v|
        value = v.to_s
        raise ArgumentError, "header #{k.inspect} contains CR/LF" if value.match?(CRLF_HEADER_VALUE)

        buf << k << ': ' << value << "\r\n"
      end
      buf << "\r\n"
      buf
    end
  end
end
