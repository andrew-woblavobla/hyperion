# frozen_string_literal: true

if defined?(Hyperion::CParser) && Hyperion::CParser.respond_to?(:chunked_body_complete?)
  RSpec.describe 'Hyperion::CParser.chunked_body_complete?' do
    it 'returns [true, end_offset] for a single complete chunk + terminator' do
      buf = "5\r\nhello\r\n0\r\n\r\n"
      complete, offset = Hyperion::CParser.chunked_body_complete?(buf, 0)
      expect(complete).to be(true)
      expect(offset).to eq(buf.bytesize)
    end

    it 'returns [true, end_offset] across multiple chunks' do
      buf = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n"
      complete, offset = Hyperion::CParser.chunked_body_complete?(buf, 0)
      expect(complete).to be(true)
      expect(offset).to eq(buf.bytesize)
    end

    it 'returns [true, end_offset] when trailers are present' do
      buf = "5\r\nhello\r\n0\r\nFoo: bar\r\n\r\n"
      complete, offset = Hyperion::CParser.chunked_body_complete?(buf, 0)
      expect(complete).to be(true)
      expect(offset).to eq(buf.bytesize)
    end

    it 'returns [false, _] when no CRLF is present yet' do
      complete, = Hyperion::CParser.chunked_body_complete?('5', 0)
      expect(complete).to be(false)
    end

    it 'returns [false, _] when the trailer terminator is missing' do
      complete, = Hyperion::CParser.chunked_body_complete?("5\r\nhello\r\n0\r\n", 0)
      expect(complete).to be(false)
    end

    it 'returns [false, _] when chunk data is short' do
      complete, = Hyperion::CParser.chunked_body_complete?("5\r\nhel", 0)
      expect(complete).to be(false)
    end

    it 'accepts chunk extensions on the size line' do
      buf = "5;name=value\r\nhello\r\n0\r\n\r\n"
      complete, offset = Hyperion::CParser.chunked_body_complete?(buf, 0)
      expect(complete).to be(true)
      expect(offset).to eq(buf.bytesize)
    end

    it 'reports the last safe cursor when the body is partially buffered' do
      # Two complete chunks then partial data — the C parser should be
      # able to advance through the first two and then return the cursor
      # at the start of the unread tail.
      buf = "3\r\nfoo\r\n3\r\nbar\r\n3\r\nba"
      complete, offset = Hyperion::CParser.chunked_body_complete?(buf, 0)
      expect(complete).to be(false)
      # First chunk: "3\r\nfoo\r\n" = 8 bytes. Second chunk: another 8.
      # Cursor should be at 16 (start of the third chunk's size line).
      expect(offset).to eq(16)
    end

    it 'honours the body_start offset' do
      preamble = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
      buf = preamble + "5\r\nhello\r\n0\r\n\r\n"
      complete, offset = Hyperion::CParser.chunked_body_complete?(buf, preamble.bytesize)
      expect(complete).to be(true)
      expect(offset).to eq(buf.bytesize)
    end

    it 'matches the Ruby fallback for a wide variety of inputs' do
      ruby_check = lambda do |buffer, body_start|
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

      cases = [
        "5\r\nhello\r\n0\r\n\r\n",
        "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n",
        "5\r\nhello\r\n0\r\nFoo: bar\r\n\r\n",
        '5',
        "5\r\nhello\r\n0\r\n",
        "5\r\nhel",
        "0\r\n\r\n",
        "a\r\n0123456789\r\n0\r\n\r\n"
      ]

      cases.each do |buf|
        c_complete, = Hyperion::CParser.chunked_body_complete?(buf, 0)
        expect(c_complete).to eq(ruby_check.call(buf, 0)), "mismatch on #{buf.inspect}"
      end
    end

    it 'raises ArgumentError when body_start is negative' do
      expect { Hyperion::CParser.chunked_body_complete?('x', -1) }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError when body_start exceeds buffer size' do
      expect { Hyperion::CParser.chunked_body_complete?('x', 99) }.to raise_error(ArgumentError)
    end
  end

  RSpec.describe 'Hyperion::Connection#chunked_body_complete? (fallback parity)' do
    let(:conn) { Hyperion::Connection.new }

    it 'matches the C extension on the same set of inputs' do
      cases = [
        "5\r\nhello\r\n0\r\n\r\n",
        "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n",
        "5\r\nhello\r\n0\r\nFoo: bar\r\n\r\n",
        '5',
        "5\r\nhel"
      ]

      Hyperion::Connection.instance_variable_set(:@c_chunked_available, true)
      c_results = cases.map { |buf| conn.send(:chunked_body_complete?, buf, 0) }
      Hyperion::Connection.instance_variable_set(:@c_chunked_available, false)
      rb_results = cases.map { |buf| conn.send(:chunked_body_complete?, buf, 0) }
      Hyperion::Connection.instance_variable_set(:@c_chunked_available, nil)

      expect(c_results).to eq(rb_results)
    end
  end
end
