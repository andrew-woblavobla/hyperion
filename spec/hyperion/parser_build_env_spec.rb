# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/adapter/rack'

# Phase 3a (1.7.1) — env-construction loop in C extension.
#
# Hyperion::CParser.build_env(env, request) populates the Rack env hash
# in one FFI hop: REQUEST_METHOD / PATH_INFO / QUERY_STRING /
# HTTP_VERSION / SERVER_PROTOCOL + every parsed header as
# HTTP_<UPCASED_UNDERSCORED>, plus the two RFC-mandated non-HTTP_
# promotions (CONTENT_TYPE / CONTENT_LENGTH).
#
# Spec target: parity with the pre-Phase-3 Ruby loop in
# Hyperion::Adapter::Rack#build_env, plus identity preservation for the
# 30 pre-interned header keys.
RSpec.describe 'Hyperion::CParser.build_env' do
  if defined?(Hyperion::CParser) && Hyperion::CParser.respond_to?(:build_env)
    let(:request) do
      Hyperion::Request.new(
        method: 'POST',
        path: '/api/v1/items',
        query_string: 'page=2&filter=foo',
        http_version: 'HTTP/1.1',
        headers: {
          'host' => 'example.com',
          'user-agent' => 'rspec',
          'accept' => 'application/json',
          'accept-encoding' => 'gzip',
          'content-type' => 'application/json',
          'content-length' => '42',
          'authorization' => 'Bearer abc',
          'x-request-id' => 'rid-123',
          'x-custom-vendor-flag' => 'on'
        },
        body: ''
      )
    end

    it 'sets the request-line keys' do
      env = {}
      Hyperion::CParser.build_env(env, request)
      expect(env['REQUEST_METHOD']).to eq('POST')
      expect(env['PATH_INFO']).to eq('/api/v1/items')
      expect(env['QUERY_STRING']).to eq('page=2&filter=foo')
      expect(env['HTTP_VERSION']).to eq('HTTP/1.1')
      expect(env['SERVER_PROTOCOL']).to eq('HTTP/1.1')
    end

    it 'maps every parsed header to its HTTP_* env key' do
      env = {}
      Hyperion::CParser.build_env(env, request)
      expect(env['HTTP_HOST']).to eq('example.com')
      expect(env['HTTP_USER_AGENT']).to eq('rspec')
      expect(env['HTTP_ACCEPT']).to eq('application/json')
      expect(env['HTTP_ACCEPT_ENCODING']).to eq('gzip')
      expect(env['HTTP_AUTHORIZATION']).to eq('Bearer abc')
      expect(env['HTTP_X_REQUEST_ID']).to eq('rid-123')
      expect(env['HTTP_X_CUSTOM_VENDOR_FLAG']).to eq('on')
    end

    it 'promotes content-length and content-type to non-HTTP_ keys (RFC compatibility)' do
      env = {}
      Hyperion::CParser.build_env(env, request)
      expect(env['CONTENT_LENGTH']).to eq('42')
      expect(env['CONTENT_TYPE']).to eq('application/json')
      # The HTTP_ variants are still present too — Rack apps in the wild
      # read either form, the adapter has always set both.
      expect(env['HTTP_CONTENT_LENGTH']).to eq('42')
      expect(env['HTTP_CONTENT_TYPE']).to eq('application/json')
    end

    it 'returns the same env hash that was passed in' do
      env = {}
      out = Hyperion::CParser.build_env(env, request)
      expect(out).to be(env)
    end

    it 'leaves pre-existing keys (rack.input, REMOTE_ADDR, …) untouched' do
      env = {
        'REMOTE_ADDR' => '10.0.0.1',
        'rack.url_scheme' => 'https',
        'SERVER_NAME' => 'localhost'
      }
      Hyperion::CParser.build_env(env, request)
      expect(env['REMOTE_ADDR']).to eq('10.0.0.1')
      expect(env['rack.url_scheme']).to eq('https')
      expect(env['SERVER_NAME']).to eq('localhost')
    end

    it 'uses the pre-interned HTTP_USER_AGENT key (identity preserved through the parser)' do
      parser = Hyperion::CParser.new
      bytes = "GET /x HTTP/1.1\r\nHost: x\r\nUser-Agent: rspec\r\n\r\n"
      parsed_request, = parser.parse(bytes)

      env = {}
      Hyperion::CParser.build_env(env, parsed_request)

      table = Hyperion::CParser::PREINTERNED_HEADERS
      pre_ua = table[table.index('user-agent') + 1]
      pre_host = table[table.index('host') + 1]

      actual_ua = env.keys.find { |k| k == 'HTTP_USER_AGENT' }
      actual_host = env.keys.find { |k| k == 'HTTP_HOST' }

      expect(actual_ua).to be(pre_ua),
                           'HTTP_USER_AGENT key should be the same frozen String as the pre-interned table entry'
      expect(actual_host).to be(pre_host)
    end

    it 'preserves identity across all 30 pre-interned headers' do
      # Skip a couple of names that llhttp validates strictly (content-length
      # must be all-digits; connection has a small accept-list; upgrade /
      # transfer-encoding cause smuggling-defense failure or upgrade rejection).
      # Identity preservation is independent of the header *value*, so the
      # remaining 26 are sufficient coverage.
      lc_names = Hyperion::CParser::PREINTERNED_HEADERS.each_slice(2).map(&:first) -
                 %w[content-length connection upgrade]
      header_lines = lc_names.map { |n| "#{n}: v" }.join("\r\n")
      bytes = "GET / HTTP/1.1\r\n#{header_lines}\r\n\r\n"

      parser = Hyperion::CParser.new
      parsed_request, = parser.parse(bytes)

      env = {}
      Hyperion::CParser.build_env(env, parsed_request)

      table = Hyperion::CParser::PREINTERNED_HEADERS
      lc_names.each do |name|
        pre = table[table.index(name) + 1]
        actual = env.keys.find { |k| k == pre }
        expect(actual).to be(pre), "expected #{pre} key to be `equal?` to the pre-interned entry"
      end
    end

    it 'falls back to a one-allocation upcase build for off-table custom headers' do
      env = {}
      Hyperion::CParser.build_env(env, request)
      key = env.keys.find { |k| k == 'HTTP_X_CUSTOM_VENDOR_FLAG' }
      expect(key).not_to be_nil
      expect(key.encoding).to eq(Encoding::US_ASCII)
      # Off-table key shouldn't be `equal?` to anything in the pre-interned table.
      table = Hyperion::CParser::PREINTERNED_HEADERS
      expect(table.any? { |s| s.equal?(key) }).to be(false)
    end

    it 'tolerates a request with no headers at all' do
      bare = Hyperion::Request.new(
        method: 'GET',
        path: '/',
        query_string: '',
        http_version: 'HTTP/1.1',
        headers: {},
        body: ''
      )
      env = {}
      expect { Hyperion::CParser.build_env(env, bare) }.not_to raise_error
      expect(env['REQUEST_METHOD']).to eq('GET')
      expect(env['PATH_INFO']).to eq('/')
      expect(env['QUERY_STRING']).to eq('')
      expect(env).not_to have_key('CONTENT_TYPE')
      expect(env).not_to have_key('CONTENT_LENGTH')
    end

    it 'matches the pure-Ruby fallback byte-for-byte on a typical browser request' do
      parser = Hyperion::CParser.new
      bytes = "GET /search?q=hyperion HTTP/1.1\r\n" \
              "Host: example.com\r\n" \
              "User-Agent: Mozilla/5.0\r\n" \
              "Accept: text/html\r\n" \
              "Accept-Encoding: gzip, br\r\n" \
              "Accept-Language: en-US\r\n" \
              "Cookie: session=abc; csrf=def\r\n" \
              "X-Forwarded-For: 1.2.3.4\r\n" \
              "X-Custom: vendor\r\n\r\n"
      parsed_request, = parser.parse(bytes)

      # Walk both branches in one process — flip the cached probe to force
      # the Ruby fallback, build a fresh env, then flip back.
      Hyperion::Adapter::Rack.instance_variable_set(:@c_build_env_available, true)
      env_c, input_c = Hyperion::Adapter::Rack.send(:build_env, parsed_request)
      Hyperion::Adapter::Rack::ENV_POOL.release(env_c)
      Hyperion::Adapter::Rack::INPUT_POOL.release(input_c)

      Hyperion::Adapter::Rack.instance_variable_set(:@c_build_env_available, false)
      env_rb, input_rb = Hyperion::Adapter::Rack.send(:build_env, parsed_request)

      Hyperion::Adapter::Rack.instance_variable_set(:@c_build_env_available, nil)

      # Same set of keys, same values. (We don't compare object identity
      # here — only HTTP_* values.)
      keys_c = env_c.keys.sort
      keys_rb = env_rb.keys.sort
      expect(keys_c).to eq(keys_rb)
      keys_c.each do |k|
        expect(env_c[k]).to eq(env_rb[k]), "mismatch on key #{k.inspect}"
      end
    ensure
      Hyperion::Adapter::Rack::ENV_POOL.release(env_rb) if env_rb
      Hyperion::Adapter::Rack::INPUT_POOL.release(input_rb) if input_rb
    end

    it 'last-wins on duplicate header names (after parser normalisation)' do
      # Headers Hash keys are unique by construction (parser dedups on
      # lowercase name), but verify build_env doesn't synthesise duplicates.
      req = Hyperion::Request.new(
        method: 'GET', path: '/', query_string: '',
        http_version: 'HTTP/1.1',
        headers: { 'x-custom' => 'second' },
        body: ''
      )
      env = {}
      Hyperion::CParser.build_env(env, req)
      expect(env['HTTP_X_CUSTOM']).to eq('second')
      expect(env.keys.count { |k| k == 'HTTP_X_CUSTOM' }).to eq(1)
    end
  else
    it 'is unavailable; tests skipped (C extension missing build_env)' do
      skip 'Hyperion::CParser.build_env not present'
    end
  end
end
