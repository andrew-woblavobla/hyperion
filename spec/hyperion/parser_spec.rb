# frozen_string_literal: true

require 'hyperion/request'
require 'hyperion/parser'

RSpec.describe Hyperion::Parser do
  subject(:parser) { described_class.new }

  describe '#parse' do
    it 'parses a simple GET request' do
      buffer = "GET /hello?x=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: rspec\r\n\r\n"
      request, end_offset = parser.parse(buffer)

      expect(request.method).to eq('GET')
      expect(request.path).to eq('/hello')
      expect(request.query_string).to eq('x=1')
      expect(request.http_version).to eq('HTTP/1.1')
      expect(request.headers['host']).to eq('example.com')
      expect(request.headers['user-agent']).to eq('rspec')
      expect(request.body).to eq('')
      expect(end_offset).to eq(buffer.bytesize)
    end

    it 'parses a POST with Content-Length body' do
      buffer = "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
      request, end_offset = parser.parse(buffer)

      expect(request.method).to eq('POST')
      expect(request.path).to eq('/submit')
      expect(request.body).to eq('hello')
      expect(end_offset).to eq(buffer.bytesize)
    end

    it 'normalizes header names to lowercase' do
      buffer = "GET / HTTP/1.1\r\nContent-Type: application/json\r\nX-Custom: yes\r\n\r\n"
      request, = parser.parse(buffer)

      expect(request.headers).to include('content-type' => 'application/json', 'x-custom' => 'yes')
    end

    it 'handles paths without query string' do
      buffer = "GET /just-path HTTP/1.1\r\nHost: x\r\n\r\n"
      request, = parser.parse(buffer)

      expect(request.path).to eq('/just-path')
      expect(request.query_string).to eq('')
    end

    it 'raises ParseError on malformed request line' do
      buffer = "NOT-AN-HTTP-REQUEST\r\n\r\n"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::ParseError)
    end

    it 'raises ParseError when Content-Length disagrees with body size' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nshort"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::ParseError, /content-length/i)
    end

    it 'raises UnsupportedError when Transfer-Encoding is present and not chunked' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\nstuff"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::UnsupportedError, /Transfer-Encoding/)
    end

    it 'parses a chunked POST body' do
      # Two chunks: "Hello, " (7 bytes) + "world" (5 bytes), then 0-terminator.
      buffer = "POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" \
               "7\r\nHello, \r\n5\r\nworld\r\n0\r\n\r\n"

      request, end_offset = parser.parse(buffer)

      expect(request.method).to eq('POST')
      expect(request.body).to eq('Hello, world')
      expect(end_offset).to eq(buffer.bytesize)
    end

    it 'parses a chunked body with extension on size line' do
      # Chunk size lines may include extensions after a semicolon.
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" \
               "5;name=val\r\nhello\r\n0\r\n\r\n"

      request, = parser.parse(buffer)
      expect(request.body).to eq('hello')
    end

    it 'parses a chunked body with trailer headers (ignored)' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" \
               "5\r\nhello\r\n0\r\nX-Trailer: ignored\r\n\r\n"

      request, = parser.parse(buffer)
      expect(request.body).to eq('hello')
      expect(request.headers).not_to have_key('x-trailer')
    end

    it 'rejects requests with both Content-Length and Transfer-Encoding (smuggling defense)' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::ParseError, /both/i)
    end

    it 'raises ParseError on truncated chunked body' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::ParseError, /chunked|truncated/i)
    end
  end
end
