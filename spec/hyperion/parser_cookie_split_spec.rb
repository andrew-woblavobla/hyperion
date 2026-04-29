# frozen_string_literal: true

require 'spec_helper'

# Phase 3b (1.7.1) — cookie split-parse in C extension.
#
# Hyperion::CParser.parse_cookie_header(str) returns a Hash mapping
# cookie name → opaque value. Cookies are NOT URL-decoded by spec
# (RFC 6265 §5.2 — values are opaque octets); empty values are valid;
# malformed pairs without `=` are skipped; repeated names are last-wins.
RSpec.describe 'Hyperion::CParser.parse_cookie_header' do
  if defined?(Hyperion::CParser) && Hyperion::CParser.respond_to?(:parse_cookie_header)
    it 'parses a single cookie' do
      expect(Hyperion::CParser.parse_cookie_header('name=value')).to eq('name' => 'value')
    end

    it 'parses multiple cookies separated by ";"' do
      out = Hyperion::CParser.parse_cookie_header('a=1; b=2; c=3')
      expect(out).to eq('a' => '1', 'b' => '2', 'c' => '3')
    end

    it 'tolerates extra whitespace between pairs' do
      out = Hyperion::CParser.parse_cookie_header("a=1 ;  b=2  ;\tc=3")
      expect(out['a']).to eq('1')
      expect(out['b']).to eq('2')
      expect(out['c']).to eq('3')
    end

    it 'tolerates a trailing semicolon' do
      out = Hyperion::CParser.parse_cookie_header('a=1; b=2;')
      expect(out).to eq('a' => '1', 'b' => '2')
    end

    it 'preserves an empty value' do
      out = Hyperion::CParser.parse_cookie_header('flag=; other=on')
      expect(out['flag']).to eq('')
      expect(out['other']).to eq('on')
    end

    it 'last-wins on a repeated name' do
      out = Hyperion::CParser.parse_cookie_header('id=first; id=second; id=third')
      expect(out['id']).to eq('third')
      expect(out.size).to eq(1)
    end

    it 'skips pairs without "=" rather than raising' do
      out = Hyperion::CParser.parse_cookie_header('foo;bar; ok=1')
      expect(out).to eq('ok' => '1')
    end

    it 'returns an empty hash for an empty string' do
      expect(Hyperion::CParser.parse_cookie_header('')).to eq({})
    end

    it 'returns an empty hash for a whitespace-only string' do
      expect(Hyperion::CParser.parse_cookie_header('   ;  ; ')).to eq({})
    end

    it 'does NOT URL-decode values (cookies are opaque per RFC 6265)' do
      out = Hyperion::CParser.parse_cookie_header('q=hello%20world%3D')
      expect(out['q']).to eq('hello%20world%3D')
    end

    it 'preserves "=" inside the value (only the first "=" splits name/value)' do
      # When a cookie value itself contains '=', e.g. base64 padding or
      # a JWT, we MUST NOT split on the second '='. The first '=' inside
      # a pair is the canonical separator.
      out = Hyperion::CParser.parse_cookie_header('token=abc=def==; other=x')
      expect(out['token']).to eq('abc=def==')
      expect(out['other']).to eq('x')
    end

    it 'trims whitespace around the name but not inside the value past the first non-ws char' do
      out = Hyperion::CParser.parse_cookie_header('  spaced  =val')
      expect(out['spaced']).to eq('val')
    end

    it 'returns String values that mirror the input bytes' do
      out = Hyperion::CParser.parse_cookie_header('a=1; b=2')
      expect(out['a']).to be_a(String)
      expect(out['b']).to be_a(String)
    end

    it 'returns a fresh Hash on each call (not aliased / not frozen)' do
      a = Hyperion::CParser.parse_cookie_header('x=1')
      b = Hyperion::CParser.parse_cookie_header('x=1')
      expect(a).not_to be(b)
      expect(a).not_to be_frozen
      a['y'] = '2' # must not raise
      expect(a['y']).to eq('2')
    end

    it 'handles long values without truncation' do
      long_val = 'a' * 4096
      out = Hyperion::CParser.parse_cookie_header("session=#{long_val}; other=x")
      expect(out['session']).to eq(long_val)
      expect(out['other']).to eq('x')
    end

    it 'rejects only the malformed pair, not the rest of the header' do
      out = Hyperion::CParser.parse_cookie_header('valid=ok; nokey; alsovalid=2')
      expect(out).to eq('valid' => 'ok', 'alsovalid' => '2')
    end
  else
    it 'is unavailable; tests skipped (C extension missing parse_cookie_header)' do
      skip 'Hyperion::CParser.parse_cookie_header not present'
    end
  end
end
