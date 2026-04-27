# frozen_string_literal: true

if defined?(Hyperion::CParser) && Hyperion::CParser.respond_to?(:upcase_underscore)
  RSpec.describe 'Hyperion::CParser.upcase_underscore' do
    it 'normalises a lowercase header to a Rack env key' do
      expect(Hyperion::CParser.upcase_underscore('content-type')).to eq('HTTP_CONTENT_TYPE')
    end

    it 'replaces every dash with an underscore' do
      expect(Hyperion::CParser.upcase_underscore('x-forwarded-for')).to eq('HTTP_X_FORWARDED_FOR')
    end

    it 'is idempotent on already-uppercase input' do
      expect(Hyperion::CParser.upcase_underscore('X-Request-ID')).to eq('HTTP_X_REQUEST_ID')
    end

    it 'returns "HTTP_" for an empty input' do
      expect(Hyperion::CParser.upcase_underscore('')).to eq('HTTP_')
    end

    it 'handles a single-byte header name' do
      expect(Hyperion::CParser.upcase_underscore('a')).to eq('HTTP_A')
    end

    it 'returns a US-ASCII encoded string' do
      out = Hyperion::CParser.upcase_underscore('content-type')
      expect(out.encoding).to eq(Encoding::US_ASCII)
    end

    it 'passes non-ASCII bytes through bytewise' do
      # Header names are ASCII per RFC 9110; we still must not crash on
      # the rare adversarial / mis-decoded byte. The non-ASCII byte should
      # appear in the output unchanged.
      input = +"x-\xC3\xA9-test"
      out = Hyperion::CParser.upcase_underscore(input)
      # 5 (HTTP_) + len of input
      expect(out.bytesize).to eq(5 + input.bytesize)
      expect(out.bytes[0, 5]).to eq('HTTP_'.bytes)
      # 'x' upcased + '_' for '-' + raw bytes preserved + '_' + 'TEST'
      expect(out.bytes[5]).to eq('X'.ord)
      expect(out.bytes[6]).to eq('_'.ord)
      expect(out.bytes[7]).to eq(0xC3)
      expect(out.bytes[8]).to eq(0xA9)
      expect(out.bytes[9]).to eq('_'.ord)
      expect(out.bytes[10..]).to eq('TEST'.bytes)
    end

    it 'preserves digits and other passthrough characters' do
      expect(Hyperion::CParser.upcase_underscore('x-api-version-2')).to eq('HTTP_X_API_VERSION_2')
    end

    it 'matches the pure-Ruby fallback expression' do
      %w[
        content-type
        x-forwarded-for
        x-request-id
        accept-encoding
        x-api-version-2
        sec-ch-ua-platform
      ].each do |name|
        ruby_expected = "HTTP_#{name.upcase.tr('-', '_')}"
        expect(Hyperion::CParser.upcase_underscore(name)).to eq(ruby_expected)
      end
    end
  end

  RSpec.describe 'Hyperion::Adapter::Rack#build_env (fallback parity)' do
    require 'hyperion/adapter/rack'

    it 'produces the same env-keys with and without the C extension' do
      request = Hyperion::Request.new(
        method: 'GET',
        path: '/x',
        query_string: '',
        http_version: 'HTTP/1.1',
        headers: { 'host' => 'h', 'x-custom-header' => 'v', 'x-api-version' => '2' },
        body: ''
      )

      # Force-flip the cached probe so we walk both branches in one process.
      Hyperion::Adapter::Rack.instance_variable_set(:@c_upcase_available, true)
      env_c, = Hyperion::Adapter::Rack.send(:build_env, request)
      Hyperion::Adapter::Rack.instance_variable_set(:@c_upcase_available, false)
      env_rb, = Hyperion::Adapter::Rack.send(:build_env, request)
      Hyperion::Adapter::Rack.instance_variable_set(:@c_upcase_available, nil)

      expect(env_c['HTTP_X_CUSTOM_HEADER']).to eq('v')
      expect(env_c['HTTP_X_API_VERSION']).to eq('2')
      expect(env_rb['HTTP_X_CUSTOM_HEADER']).to eq('v')
      expect(env_rb['HTTP_X_API_VERSION']).to eq('2')
    end
  end
end
