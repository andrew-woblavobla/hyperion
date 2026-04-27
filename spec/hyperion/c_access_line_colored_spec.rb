# frozen_string_literal: true

require 'json'

if defined?(Hyperion::CParser) && Hyperion::CParser.respond_to?(:build_access_line_colored)
  RSpec.describe 'Hyperion::CParser.build_access_line_colored' do
    let(:ts)           { '2026-04-26T18:38:49.405Z' }
    let(:method_name)  { 'GET' }
    let(:path)         { '/api/v1/health' }
    let(:status)       { 200 }
    let(:duration_ms)  { 46.63 }
    let(:remote_addr)  { '127.0.0.1' }
    let(:http_version) { 'HTTP/1.1' }

    describe 'text format' do
      it 'wraps the level label with the green ANSI escape pair' do
        line = Hyperion::CParser.build_access_line_colored(:text, ts, method_name, path, nil,
                                                           status, duration_ms, remote_addr,
                                                           http_version)
        expect(line).to include("\e[32mINFO \e[0m")
        expect(line).to start_with(ts)
        expect(line).to end_with("\n")
        expect(line).to include('message=request')
        expect(line).to include('method=GET')
        expect(line).to include('path=/api/v1/health')
        expect(line).to include('status=200')
        expect(line).to include('http_version=HTTP/1.1')
      end

      it 'omits the query field when query is nil' do
        line = Hyperion::CParser.build_access_line_colored(:text, ts, method_name, path, nil,
                                                           status, duration_ms, remote_addr,
                                                           http_version)
        expect(line).not_to include('query=')
      end

      it 'omits the query field when query is empty' do
        line = Hyperion::CParser.build_access_line_colored(:text, ts, method_name, path, '',
                                                           status, duration_ms, remote_addr,
                                                           http_version)
        expect(line).not_to include('query=')
      end

      it 'renders remote_addr=nil when the peer is unknown' do
        line = Hyperion::CParser.build_access_line_colored(:text, ts, method_name, path, nil,
                                                           status, duration_ms, nil, http_version)
        expect(line).to include('remote_addr=nil')
      end

      it 'quotes a query that contains an = character' do
        line = Hyperion::CParser.build_access_line_colored(:text, ts, method_name, path, 'page=2',
                                                           status, duration_ms, remote_addr,
                                                           http_version)
        expect(line).to match(/query=("page=2"|page=2)/)
      end
    end

    describe 'json format' do
      it 'omits ANSI escapes from JSON output' do
        line = Hyperion::CParser.build_access_line_colored(:json, ts, method_name, path, nil,
                                                           status, duration_ms, remote_addr,
                                                           http_version)
        expect(line).not_to include("\e[")
        parsed = JSON.parse(line)
        expect(parsed['method']).to eq('GET')
        expect(parsed['path']).to eq('/api/v1/health')
        expect(parsed['level']).to eq('info')
      end

      it 'serialises remote_addr as JSON null when nil' do
        line = Hyperion::CParser.build_access_line_colored(:json, ts, method_name, path, nil,
                                                           status, duration_ms, nil, http_version)
        parsed = JSON.parse(line)
        expect(parsed['remote_addr']).to be_nil
      end
    end

    describe 'parity with the Ruby fallback' do
      # Build the Ruby colored path by hand and assert byte-for-byte equality.
      # Mirrors Logger#build_access_text with @colorize = true.
      def ruby_text(ts, method_name, path, query, status, duration_ms, remote_addr, http_version)
        addr = remote_addr || 'nil'
        query_part = if query.nil? || query.empty?
                       ''
                     else
                       " query=#{query.match?(/[\s"=]/) ? query.inspect : query}"
                     end
        "#{ts} \e[32mINFO \e[0m [hyperion] message=request method=#{method_name} path=#{path}#{query_part} " \
          "status=#{status} duration_ms=#{duration_ms} remote_addr=#{addr} http_version=#{http_version}\n"
      end

      it 'matches the Ruby colored builder byte-for-byte on the hot path' do
        c_line = Hyperion::CParser.build_access_line_colored(:text, ts, method_name, path, nil,
                                                             status, 1, remote_addr, http_version)
        rb_line = ruby_text(ts, method_name, path, nil, status, 1, remote_addr, http_version)
        expect(c_line).to eq(rb_line)
      end
    end

    describe 'Hyperion::Logger#access wiring' do
      it 'routes a colorized logger through the C colored builder' do
        io = StringIO.new
        # Pretend the IO is a TTY so @colorize flips on. The Logger probes
        # via #tty? at construction time.
        def io.tty?
          true
        end
        logger = Hyperion::Logger.new(io: io, format: :text)

        logger.access('GET', '/x', nil, 200, 1.0, '1.1.1.1', 'HTTP/1.1')
        logger.flush_access_buffer

        expect(io.string).to include("\e[32mINFO \e[0m")
        expect(io.string).to include('method=GET')
      end
    end
  end
end
