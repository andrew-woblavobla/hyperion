# frozen_string_literal: true

require 'time'

module Hyperion
  # Serializes a Rack [status, headers, body] tuple to an HTTP/1.1 wire stream.
  # Phase 5 replaces this with an io_buffer-batched writer; Phase 7 adds a
  # sibling Http2ResponseWriter. Public surface (#write) stays stable.
  class ResponseWriter
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

    def write(io, status, headers, body, keep_alive: false)
      # Zero-copy fast path: bodies that point at an on-disk file (Rack::Files,
      # asset servers, signed-download responders) get streamed via
      # IO.copy_stream which delegates to sendfile(2) on Linux for plain TCP
      # sockets — bytes go from the file's page cache straight to the socket
      # buffer with no userspace allocation. For TLS sockets we still avoid the
      # multi-MB String build, but encryption forces a userspace round-trip so
      # we count that path separately.
      return write_sendfile(io, status, headers, body, keep_alive: keep_alive) if body.respond_to?(:to_path)

      write_buffered(io, status, headers, body, keep_alive: keep_alive)
    end

    private

    def write_buffered(io, status, headers, body, keep_alive:)
      # Phase 1 buffers the full body so Content-Length is exact.
      # Phase 2 introduces chunked transfer-encoding for streaming bodies;
      # Phase 5 batches via IO::Buffer to avoid this intermediate String.
      buffered = +''
      body.each { |chunk| buffered << chunk }

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

    def write_sendfile(io, status, headers, body, keep_alive:)
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

      io.write(head)
      # IO.copy_stream copies up to file_size bytes from the file to the socket.
      # On Linux + plain TCPSocket this triggers sendfile(2) — kernel-level
      # zero-copy. On TLS sockets and non-Linux platforms it falls back to
      # internal read+write loops, but we still avoid building a String the
      # size of the file in Ruby.
      copied = IO.copy_stream(file, io, file_size)

      record_zero_copy_metric(io)
      Hyperion.metrics.increment(:bytes_written, head.bytesize + copied)
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
  end
end
