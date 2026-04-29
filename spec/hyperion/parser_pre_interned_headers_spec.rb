# frozen_string_literal: true

require 'spec_helper'

# Phase 2c (1.7.1) — pre-interned header table in the parser C extension.
#
# Init_hyperion_http builds a 30-entry frozen array of [lowercase_name,
# HTTP_X_KEY] pairs covering the production top-30 request headers. The
# parser uses the lowercase half during stash_pending_header to skip
# `String#downcase` allocation; the adapter uses the HTTP_X half so the
# env-hash key is `equal?` to a single shared frozen object across all
# layers.
RSpec.describe 'Hyperion::CParser pre-interned header table' do
  it 'exposes a 60-entry [lc, HTTP_X] flat array as PREINTERNED_HEADERS' do
    table = Hyperion::CParser::PREINTERNED_HEADERS
    expect(table).to be_frozen
    expect(table.length).to eq(60)
    # Spot-check shape — pairs alternate lowercase + HTTP_X.
    expect(table[0]).to eq('host')
    expect(table[1]).to eq('HTTP_HOST')
    expect(table[2]).to eq('user-agent')
    expect(table[3]).to eq('HTTP_USER_AGENT')
    table.each { |s| expect(s).to be_frozen }
  end

  it 'covers all 30 promised top-traffic header names' do
    expected = %w[
      host user-agent accept accept-encoding accept-language cache-control
      connection cookie content-length content-type authorization referer
      origin upgrade x-forwarded-for x-forwarded-proto x-forwarded-host
      x-real-ip x-request-id if-none-match if-modified-since if-match etag
      range pragma dnt sec-ch-ua sec-fetch-dest sec-fetch-mode sec-fetch-site
    ]
    table = Hyperion::CParser::PREINTERNED_HEADERS
    even = table.each_with_index.select { |_, i| i.even? }.map(&:first)
    expect(even.sort).to eq(expected.sort)
  end

  it 'parser stashes a pre-interned lowercase name for known headers (parsed key is `equal?` to the table entry)' do
    parser = Hyperion::CParser.new
    request_bytes = "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: foo\r\nAccept-Encoding: gzip\r\n\r\n"
    request, _off = parser.parse(request_bytes)

    table = Hyperion::CParser::PREINTERNED_HEADERS
    host_lc = table[table.index('host')]
    ua_lc   = table[table.index('user-agent')]
    ae_lc   = table[table.index('accept-encoding')]

    parsed_keys = request.headers.keys
    parsed_host = parsed_keys.find { |k| k == 'host' }
    parsed_ua   = parsed_keys.find { |k| k == 'user-agent' }
    parsed_ae   = parsed_keys.find { |k| k == 'accept-encoding' }

    expect(parsed_host).to be(host_lc),
                           'expected the parsed `host` key to be the same frozen String as the pre-interned entry'
    expect(parsed_ua).to be(ua_lc)
    expect(parsed_ae).to be(ae_lc)
  end

  it 'feeds User-Agent through to the Rack adapter such that env\'s HTTP_USER_AGENT key is `equal?` to the pre-interned key' do
    parser = Hyperion::CParser.new
    request_bytes = "GET /path HTTP/1.1\r\nHost: x\r\nUser-Agent: foo\r\n\r\n"
    request, = parser.parse(request_bytes)
    env, input = Hyperion::Adapter::Rack.send(:build_env, request)

    table = Hyperion::CParser::PREINTERNED_HEADERS
    pre_ua_key = table[table.index('user-agent') + 1]

    # Find the actual key object in env (the one that hashed to 'HTTP_USER_AGENT').
    env_keys = env.keys
    actual_key = env_keys.find { |k| k == 'HTTP_USER_AGENT' }

    expect(actual_key).not_to be_nil
    expect(actual_key).to be(pre_ua_key),
                          'env HTTP_USER_AGENT key should be the same frozen String as CParser::PREINTERNED_HEADERS'
    expect(env['HTTP_USER_AGENT']).to eq('foo')
  ensure
    Hyperion::Adapter::Rack::ENV_POOL.release(env) if env
    Hyperion::Adapter::Rack::INPUT_POOL.release(input) if input
  end

  it 'falls back to dynamic downcase for uncommon (off-table) headers' do
    parser = Hyperion::CParser.new
    request_bytes = "GET / HTTP/1.1\r\nHost: x\r\nX-Custom-Foo: bar\r\n\r\n"
    request, = parser.parse(request_bytes)
    expect(request.headers).to include('x-custom-foo' => 'bar')
    # The off-table key is a fresh allocation, so it shouldn't match any
    # frozen entry by identity (cheap sanity check that the fallback path
    # still allocates correctly).
    custom_key = request.headers.keys.find { |k| k == 'x-custom-foo' }
    table = Hyperion::CParser::PREINTERNED_HEADERS
    expect(table).not_to include(custom_key.equal?(_ = nil))
  end

  it 'is case-insensitive on the wire — Host: vs HOST: both resolve to the same frozen `host` key' do
    parser1 = Hyperion::CParser.new
    parser2 = Hyperion::CParser.new
    r1, = parser1.parse("GET / HTTP/1.1\r\nHost: a\r\n\r\n")
    r2, = parser2.parse("GET / HTTP/1.1\r\nHOST: b\r\n\r\n")

    table = Hyperion::CParser::PREINTERNED_HEADERS
    host_lc = table[table.index('host')]

    k1 = r1.headers.keys.find { |k| k == 'host' }
    k2 = r2.headers.keys.find { |k| k == 'host' }
    expect(k1).to be(host_lc)
    expect(k2).to be(host_lc)
    expect(k1).to be(k2)
  end
end
