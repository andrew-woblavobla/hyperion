# frozen_string_literal: true

module Hyperion
  # Pure-Ruby HTTP/1.1 parser.
  # Phase 4 replaces this with a C extension wrapping llhttp; the interface
  # (parse(buffer) -> [Request, end_offset] | raise ParseError | raise UnsupportedError)
  # stays stable.
  class Parser
    REQUEST_LINE_RE = %r{\A([A-Z]+) ([^ ?]+)(?:\?([^ ]*))? (HTTP/\d\.\d)\r\n}
    HEADER_RE       = /\G([!-9;-~]+):[ \t]*(.*?)[ \t]*\r\n/

    # Returns [Request, end_offset] where end_offset is the byte index just AFTER
    # the last byte consumed by parsing. The caller (Connection) uses end_offset
    # to compute carry-over for pipelining.
    def parse(buffer)
      m = REQUEST_LINE_RE.match(buffer)
      raise ParseError, 'invalid request line' unless m

      method, path, query, version = m.captures
      offset = m.end(0)

      headers = {}
      loop do
        if buffer.byteslice(offset, 2) == "\r\n"
          offset += 2
          break
        end
        h = HEADER_RE.match(buffer, offset)
        raise ParseError, 'invalid header line' unless h && h.begin(0) == offset

        headers[h[1].downcase] = h[2]
        offset = h.end(0)
      end

      headers_end = offset

      has_content_length     = headers.key?('content-length')
      has_transfer_encoding  = headers.key?('transfer-encoding')

      # RFC 9112 §6.1: a sender MUST NOT send a message containing both
      # Content-Length and Transfer-Encoding. Refuse rather than risk
      # request smuggling.
      if has_content_length && has_transfer_encoding
        raise ParseError, 'both Content-Length and Transfer-Encoding present'
      end

      if has_transfer_encoding
        encodings = headers['transfer-encoding'].split(',').map { |e| e.strip.downcase }
        unless encodings.last == 'chunked'
          raise UnsupportedError,
                "Transfer-Encoding #{headers['transfer-encoding'].inspect} not supported"
        end

        result = dechunk(buffer, headers_end)
        raise ParseError, 'truncated chunked body' if result.nil?

        body, end_offset = result
        request = Request.new(
          method: method,
          path: path,
          query_string: query || '',
          http_version: version,
          headers: headers,
          body: body
        )
        return [request, end_offset]
      end

      content_length = headers['content-length']&.to_i || 0
      body = buffer.byteslice(headers_end, content_length) || ''
      raise ParseError, "content-length mismatch (declared #{content_length}, got #{body.bytesize})" \
        if body.bytesize != content_length

      end_offset = headers_end + content_length
      request = Request.new(
        method: method,
        path: path,
        query_string: query || '',
        http_version: version,
        headers: headers,
        body: body
      )
      [request, end_offset]
    end

    private

    # Decode RFC 9112 §7.1 chunked body starting at `start` in `buffer`.
    # Returns [body_bytes, end_offset] on success. Returns nil if buffer is
    # truncated (caller treats as ParseError).
    def dechunk(buffer, start)
      body = +''
      cursor = start

      loop do
        line_end = buffer.index("\r\n", cursor)
        return nil unless line_end

        size_line = buffer.byteslice(cursor, line_end - cursor)
        size_token = size_line.split(';').first.to_s.strip
        return nil if size_token.empty?

        size = size_token.to_i(16)
        cursor = line_end + 2

        if size.zero?
          # Skip optional trailer headers until blank line.
          loop do
            nl = buffer.index("\r\n", cursor)
            return nil unless nl
            return [body, cursor + 2] if nl == cursor

            cursor = nl + 2
          end
        end

        return nil if buffer.bytesize < cursor + size + 2

        body << buffer.byteslice(cursor, size)
        cursor += size

        return nil unless buffer.byteslice(cursor, 2) == "\r\n"

        cursor += 2
      end
    end
  end
end
