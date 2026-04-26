# frozen_string_literal: true

if defined?(Hyperion::CParser)
  RSpec.describe Hyperion::CParser do
    subject(:parser) { described_class.new }

    it 'parses a simple GET' do
      buffer = "GET /hello?x=1 HTTP/1.1\r\nHost: example.com\r\n\r\n"
      request, offset = parser.parse(buffer)

      expect(request.method).to eq('GET')
      expect(request.path).to eq('/hello')
      expect(request.query_string).to eq('x=1')
      expect(request.http_version).to eq('HTTP/1.1')
      expect(request.headers['host']).to eq('example.com')
      expect(offset).to eq(buffer.bytesize)
    end

    it 'parses a POST with Content-Length' do
      buffer = "POST /submit HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
      request, offset = parser.parse(buffer)

      expect(request.method).to eq('POST')
      expect(request.path).to eq('/submit')
      expect(request.body).to eq('hello')
      expect(offset).to eq(buffer.bytesize)
    end

    it 'parses chunked' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
      request, = parser.parse(buffer)
      expect(request.body).to eq('hello')
    end

    it 'raises ParseError on malformed' do
      buffer = "INVALID\r\n\r\n"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::ParseError)
    end

    it 'raises UnsupportedError on non-chunked TE' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\nx"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::UnsupportedError)
    end

    it 'raises ParseError on smuggling (CL + TE both present)' do
      buffer = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello"
      expect { parser.parse(buffer) }.to raise_error(Hyperion::ParseError, /content-length|transfer-encoding/i)
    end
  end
else
  RSpec.describe 'Hyperion::CParser (skipped — extension not built)' do
    it 'is unavailable; tests skipped' do
      skip 'C extension not built'
    end
  end
end
