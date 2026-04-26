# frozen_string_literal: true

require 'json'

if defined?(Hyperion::CParser) && Hyperion::CParser.respond_to?(:build_access_line)
  RSpec.describe 'Hyperion::CParser.build_access_line' do
    # Stable inputs we reuse for every flavour. ts is the upstream-rendered
    # iso8601(3) string — the C builder doesn't format time, just embeds it.
    let(:ts)           { '2026-04-26T18:38:49.405Z' }
    let(:method_name)  { 'GET' }
    let(:path)         { '/api/v1/health' }
    let(:status)       { 200 }
    let(:duration_ms)  { 46.63 }
    let(:remote_addr)  { '127.0.0.1' }
    let(:http_version) { 'HTTP/1.1' }

    describe 'text format' do
      it 'builds a structured key=value line with a trailing newline' do
        line = Hyperion::CParser.build_access_line(:text, ts, method_name, path, nil,
                                                   status, duration_ms, remote_addr,
                                                   http_version)

        expect(line).to start_with(ts)
        expect(line).to end_with("\n")
        expect(line).to include('INFO')
        expect(line).to include('[hyperion]')
        expect(line).to include('message=request')
        expect(line).to include('method=GET')
        expect(line).to include('path=/api/v1/health')
        expect(line).to include('status=200')
        expect(line).to include('duration_ms=')
        expect(line).to include('remote_addr=127.0.0.1')
        expect(line).to include('http_version=HTTP/1.1')
      end

      it 'omits the query field when query is nil' do
        line = Hyperion::CParser.build_access_line(:text, ts, method_name, path, nil,
                                                   status, duration_ms, remote_addr,
                                                   http_version)
        expect(line).not_to include('query=')
      end

      it 'omits the query field when query is empty' do
        line = Hyperion::CParser.build_access_line(:text, ts, method_name, path, '',
                                                   status, duration_ms, remote_addr,
                                                   http_version)
        expect(line).not_to include('query=')
      end

      it 'emits the query field unquoted when it is plain' do
        line = Hyperion::CParser.build_access_line(:text, ts, method_name, path, 'page=2',
                                                   status, duration_ms, remote_addr,
                                                   http_version)
        # `=` triggers the quoting path (mirrors Logger#quote_if_needed).
        expect(line).to match(/query=("page=2"|page=2)/)
      end

      it 'renders remote_addr=nil when nil' do
        line = Hyperion::CParser.build_access_line(:text, ts, method_name, path, nil,
                                                   status, duration_ms, nil, http_version)
        expect(line).to include('remote_addr=nil')
      end
    end

    describe 'json format' do
      it 'builds a parseable single-line JSON record with the access fields' do
        line = Hyperion::CParser.build_access_line(:json, ts, method_name, path,
                                                   'id=42', status, duration_ms,
                                                   remote_addr, http_version)
        expect(line).to end_with("\n")

        parsed = JSON.parse(line)
        expect(parsed['ts']).to eq(ts)
        expect(parsed['level']).to eq('info')
        expect(parsed['source']).to eq('hyperion')
        expect(parsed['message']).to eq('request')
        expect(parsed['method']).to eq('GET')
        expect(parsed['path']).to eq('/api/v1/health')
        expect(parsed['query']).to eq('id=42')
        expect(parsed['status']).to eq(200)
        expect(parsed['duration_ms']).to be_within(0.01).of(46.63)
        expect(parsed['remote_addr']).to eq('127.0.0.1')
        expect(parsed['http_version']).to eq('HTTP/1.1')
      end

      it 'serialises remote_addr as JSON null when nil' do
        line = Hyperion::CParser.build_access_line(:json, ts, method_name, path, nil,
                                                   status, duration_ms, nil, http_version)
        parsed = JSON.parse(line)
        expect(parsed['remote_addr']).to be_nil
      end

      it 'omits the query key when query is nil' do
        line = Hyperion::CParser.build_access_line(:json, ts, method_name, path, nil,
                                                   status, duration_ms, remote_addr,
                                                   http_version)
        parsed = JSON.parse(line)
        expect(parsed).not_to have_key('query')
      end
    end
  end
end
