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
      # Phase 1 buffers the full body so Content-Length is exact.
      # Phase 2 introduces chunked transfer-encoding for streaming bodies;
      # Phase 5 batches via IO::Buffer to avoid this intermediate String.
      buffered = +''
      body.each { |chunk| buffered << chunk }

      reason = REASONS[status] || 'Unknown'
      date_str = Time.now.httpdate

      head = build_head(status, reason, headers, buffered.bytesize, keep_alive, date_str)

      # Phase 8 perf fix: coalesce status line + all headers + body into a
      # SINGLE io.write call. Each syscall round-trip is ~1 usec on macOS
      # kqueue; before this change we issued (1 status) + (N headers) + (1 blank)
      # + (1 body) = 8+ syscalls per response. Now: 1 syscall.
      if buffered.empty?
        io.write(head)
      else
        # Concatenate into the head buffer (which is already a fresh +'' from
        # the C builder or the Ruby fallback) so we still emit a single write.
        head << buffered
        io.write(head)
      end
    ensure
      body.close if body.respond_to?(:close)
    end

    private

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
