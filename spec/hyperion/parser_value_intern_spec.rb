# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

RSpec.describe 'CParser header-value intern table' do
  before do
    skip 'C parser unavailable' unless defined?(Hyperion::CParser)
  end

  it 'returns the same frozen VALUE object across parses for an interned value' do
    raw = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
    p1 = Hyperion::CParser.new
    req1, _ = p1.parse(raw.b)
    p2 = Hyperion::CParser.new
    req2, _ = p2.parse(raw.b)

    v1 = req1.headers.fetch('host')
    v2 = req2.headers.fetch('host')
    expect(v1).to eq('localhost')
    expect(v1.frozen?).to be true
    expect(v1.equal?(v2)).to be(true), "expected interned identity, got #{v1.object_id} vs #{v2.object_id}"

    c1 = req1.headers.fetch('connection')
    c2 = req2.headers.fetch('connection')
    expect(c1).to eq('keep-alive')
    expect(c1.frozen?).to be true
    expect(c1.equal?(c2)).to be(true)
  end

  it 'falls back to fresh allocation for an uncommon header value' do
    rare = SecureRandom.hex(16)
    raw  = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Trace-Id: #{rare}\r\n\r\n"
    p = Hyperion::CParser.new
    req, _ = p.parse(raw.b)
    v = req.headers.fetch('x-trace-id')
    expect(v).to eq(rare)
    expect(v.frozen?).to be false
  end

  it 'preserves ASCII-8BIT encoding on intern hits' do
    raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
    p = Hyperion::CParser.new
    req, _ = p.parse(raw.b)
    v = req.headers.fetch('host')
    expect(v.encoding).to eq(Encoding::ASCII_8BIT)
  end

  it 'returns the same identity for wrk-style User-Agent' do
    ua  = 'Mozilla/5.0 (compatible; wrk/4.2.0)'
    raw = "GET / HTTP/1.1\r\nHost: localhost\r\nUser-Agent: #{ua}\r\n\r\n"
    p1 = Hyperion::CParser.new
    p2 = Hyperion::CParser.new
    req1, _ = p1.parse(raw.b)
    req2, _ = p2.parse(raw.b)
    expect(req1.headers.fetch('user-agent').equal?(req2.headers.fetch('user-agent'))).to be true
  end
end
