# frozen_string_literal: true

require 'stringio'
require 'hyperion/adapter/rack'
require 'hyperion/request'

RSpec.describe Hyperion::Adapter::Rack do
  let(:request) do
    Hyperion::Request.new(
      method: 'POST',
      path: '/api/items',
      query_string: 'page=2',
      http_version: 'HTTP/1.1',
      headers: { 'host' => 'example.com:9292', 'content-type' => 'application/json' },
      body: '{"a":1}'
    )
  end

  let(:rack_app) do
    captured = nil
    app = lambda do |env|
      captured = env.dup
      [201, { 'content-type' => 'text/plain' }, ['ok']]
    end
    [app, ->(_) { captured }]
  end

  it 'builds a valid Rack 3 env from a Hyperion::Request' do
    app, peek = rack_app
    status, headers, body = described_class.call(app, request)

    expect(status).to eq(201)
    expect(headers).to eq('content-type' => 'text/plain')
    expect(body.to_a).to eq(['ok'])

    env = peek.call(nil)
    expect(env['REQUEST_METHOD']).to eq('POST')
    expect(env['PATH_INFO']).to eq('/api/items')
    expect(env['QUERY_STRING']).to eq('page=2')
    expect(env['SERVER_NAME']).to eq('example.com')
    expect(env['SERVER_PORT']).to eq('9292')
    expect(env['HTTP_HOST']).to eq('example.com:9292')
    expect(env['HTTP_CONTENT_TYPE']).to eq('application/json')
    expect(env['rack.input'].read).to eq('{"a":1}')
    expect(env['rack.url_scheme']).to eq('http')
    expect(env['SERVER_PROTOCOL']).to eq('HTTP/1.1')
    expect(env['SERVER_SOFTWARE']).to start_with('Hyperion/')
    expect(env['rack.version']).to eq([3, 0])
    expect(env['rack.multithread']).to be(false)
    expect(env['rack.multiprocess']).to be(false)
    expect(env['rack.run_once']).to be(false)
  end

  it 'returns 500 with redacted body if app raises' do
    app = ->(_env) { raise 'kaboom' }
    status, headers, body = described_class.call(app, request)

    expect(status).to eq(500)
    expect(headers['content-type']).to eq('text/plain')
    expect(body.to_a.join).to eq('Internal Server Error')
  end

  it 'sets bare CGI CONTENT_TYPE and CONTENT_LENGTH alongside HTTP_* form' do
    req = Hyperion::Request.new(
      method: 'POST',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => 'x', 'content-type' => 'application/json', 'content-length' => '7' },
      body: 'payload'
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['CONTENT_TYPE']).to eq('application/json')
    expect(captured['CONTENT_LENGTH']).to eq('7')
    expect(captured['HTTP_CONTENT_TYPE']).to eq('application/json')
    expect(captured['HTTP_CONTENT_LENGTH']).to eq('7')
  end

  it 'falls back to localhost:80 when host header is missing' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: {},
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['SERVER_NAME']).to eq('localhost')
    expect(captured['SERVER_PORT']).to eq('80')
  end

  it 'parses IPv6 host without port' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => '[::1]' },
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['SERVER_NAME']).to eq('[::1]')
    expect(captured['SERVER_PORT']).to eq('80')
  end

  it 'sets REMOTE_ADDR from request peer_address' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => 'x' },
      body: '',
      peer_address: '198.51.100.42'
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['REMOTE_ADDR']).to eq('198.51.100.42')
  end

  it 'falls back to 127.0.0.1 when peer_address is nil' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => 'x' },
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['REMOTE_ADDR']).to eq('127.0.0.1')
  end

  it 'parses IPv6 host with port' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => '[::1]:9292' },
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['SERVER_NAME']).to eq('[::1]')
    expect(captured['SERVER_PORT']).to eq('9292')
  end

  it 'parses plain IPv4 host with port' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => '127.0.0.1:8080' },
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['SERVER_NAME']).to eq('127.0.0.1')
    expect(captured['SERVER_PORT']).to eq('8080')
  end

  it 'parses bare hostname without port and defaults to 80' do
    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => 'example.com' },
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['SERVER_NAME']).to eq('example.com')
    expect(captured['SERVER_PORT']).to eq('80')
  end

  # Regression: pre-1.5.0, a malformed bracketed IPv6 (no closing bracket)
  # was returned as-is in SERVER_NAME, leaking attacker-controlled bytes
  # into Rack env where URL generators / SSRF allow-lists / log lines would
  # trust them. The adapter must fail closed to a safe default and bump a
  # metric so operators can alert on volume — without raising, since Rack
  # apps don't expect a server adapter to throw on header parse failures.
  it 'falls back to localhost:80 and bumps :malformed_host_header on bracketed IPv6 without closing bracket' do
    Hyperion.metrics.reset!
    before = Hyperion.stats[:malformed_host_header] || 0

    req = Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: { 'host' => '[::1' },
      body: ''
    )
    captured = nil
    app = lambda do |env|
      captured = env
      [200, {}, []]
    end

    described_class.call(app, req)

    expect(captured['SERVER_NAME']).to eq('localhost')
    expect(captured['SERVER_PORT']).to eq('80')
    expect(Hyperion.stats[:malformed_host_header].to_i).to eq(before.to_i + 1)
  end
end
