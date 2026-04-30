# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/handshake'

# WS-2 (2.1.0) — RFC 6455 §1.3 / §4.2 handshake.  Exercises
# Hyperion::WebSocket::Handshake.validate + accept_value + build_101_response.
# Vectors: RFC 6455 §1.3 (the canonical accept_value test) plus the
# WS-2 plan's 13 scenarios.
RSpec.describe Hyperion::WebSocket::Handshake do
  # The b64 of 16 zero bytes — used wherever a spec wants a syntactically
  # valid Sec-WebSocket-Key without caring about its value.
  let(:valid_key)        { 'AAAAAAAAAAAAAAAAAAAAAA==' }
  let(:rfc_key)          { 'dGhlIHNhbXBsZSBub25jZQ==' }
  let(:rfc_accept_value) { 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=' }

  def base_env(overrides = {})
    {
      'REQUEST_METHOD' => 'GET',
      'SERVER_PROTOCOL' => 'HTTP/1.1',
      'HTTP_HOST' => 'example.com:8080',
      'HTTP_UPGRADE' => 'websocket',
      'HTTP_CONNECTION' => 'Upgrade',
      'HTTP_SEC_WEBSOCKET_KEY' => valid_key,
      'HTTP_SEC_WEBSOCKET_VERSION' => '13'
    }.merge(overrides)
  end

  # ---------------------------------------------------------------
  # 1. RFC 6455 §1.3 accept-value vector
  # ---------------------------------------------------------------
  describe '.accept_value' do
    it 'matches the RFC 6455 §1.3 test vector' do
      expect(described_class.accept_value(rfc_key)).to eq(rfc_accept_value)
    end
  end

  # ---------------------------------------------------------------
  # 2. Valid handshake
  # ---------------------------------------------------------------
  it 'accepts a well-formed handshake with all required headers' do
    tag, accept, sub = described_class.validate(base_env)
    expect(tag).to eq(:ok)
    expect(accept).to eq(described_class.accept_value(valid_key))
    expect(sub).to be_nil
  end

  # ---------------------------------------------------------------
  # 3. Missing Sec-WebSocket-Key
  # ---------------------------------------------------------------
  it 'rejects missing Sec-WebSocket-Key as 400' do
    env = base_env
    env.delete('HTTP_SEC_WEBSOCKET_KEY')
    tag, body, = described_class.validate(env)
    expect(tag).to eq(:bad_request)
    expect(body).to match(/Sec-WebSocket-Key/i)
  end

  # ---------------------------------------------------------------
  # 4. Bad Sec-WebSocket-Version (8) → 426 Upgrade Required + hint
  # ---------------------------------------------------------------
  it 'rejects Sec-WebSocket-Version != 13 as 426 with version hint header' do
    tag, body, extra = described_class.validate(base_env('HTTP_SEC_WEBSOCKET_VERSION' => '8'))
    expect(tag).to eq(:upgrade_required)
    expect(body).to match(/Sec-WebSocket-Version/i)
    expect(extra).to eq('sec-websocket-version' => '13')
  end

  # ---------------------------------------------------------------
  # 5. Missing Upgrade header → :not_websocket (passthrough)
  # ---------------------------------------------------------------
  it 'returns :not_websocket when Upgrade header is missing' do
    env = base_env
    env.delete('HTTP_UPGRADE')
    # 2.3-C: tuple gained a 4th slot for negotiated extensions; the
    # `:not_websocket` sentinel keeps the shape (`{}`).
    expect(described_class.validate(env)).to eq([:not_websocket, nil, nil, {}])
  end

  it 'returns :not_websocket when Upgrade is something other than websocket (e.g. h2c)' do
    expect(described_class.validate(base_env('HTTP_UPGRADE' => 'h2c'))).to eq([:not_websocket, nil, nil, {}])
  end

  # ---------------------------------------------------------------
  # 6. Connection header is `keep-alive, Upgrade` (multi-token)
  # ---------------------------------------------------------------
  it 'accepts Connection: keep-alive, Upgrade (multi-token list)' do
    tag, accept, = described_class.validate(base_env('HTTP_CONNECTION' => 'keep-alive, Upgrade'))
    expect(tag).to eq(:ok)
    expect(accept).to be_a(String)
  end

  it 'accepts case-insensitive Upgrade / Connection tokens' do
    tag, = described_class.validate(
      base_env('HTTP_UPGRADE' => 'WebSocket', 'HTTP_CONNECTION' => 'KEEP-ALIVE, UPGRADE')
    )
    expect(tag).to eq(:ok)
  end

  # ---------------------------------------------------------------
  # 7. Sec-WebSocket-Key with wrong b64-decoded length (15 bytes)
  # ---------------------------------------------------------------
  it 'rejects a Sec-WebSocket-Key that decodes to 15 bytes' do
    bad_key = Base64.strict_encode64('A' * 15) # 15 bytes != 16
    tag, body, = described_class.validate(base_env('HTTP_SEC_WEBSOCKET_KEY' => bad_key))
    expect(tag).to eq(:bad_request)
    expect(body).to match(/16 bytes/)
  end

  it 'rejects a Sec-WebSocket-Key that is not valid base64 at all' do
    tag, = described_class.validate(base_env('HTTP_SEC_WEBSOCKET_KEY' => 'not-base64!!!'))
    expect(tag).to eq(:bad_request)
  end

  # ---------------------------------------------------------------
  # 8. Subprotocol negotiation: client offers chat,superchat → pick superchat
  # ---------------------------------------------------------------
  it 'echoes the subprotocol selected by the selector' do
    selector = ->(offers) { offers.include?('superchat') ? 'superchat' : nil }
    tag, _accept, sub = described_class.validate(
      base_env('HTTP_SEC_WEBSOCKET_PROTOCOL' => 'chat, superchat'),
      subprotocol_selector: selector
    )
    expect(tag).to eq(:ok)
    expect(sub).to eq('superchat')
  end

  # ---------------------------------------------------------------
  # 9. Selector returns nil → no protocol echoed
  # ---------------------------------------------------------------
  it 'omits the subprotocol when the selector returns nil' do
    selector = ->(_offers) { nil }
    tag, _accept, sub = described_class.validate(
      base_env('HTTP_SEC_WEBSOCKET_PROTOCOL' => 'chat, superchat'),
      subprotocol_selector: selector
    )
    expect(tag).to eq(:ok)
    expect(sub).to be_nil
  end

  # ---------------------------------------------------------------
  # 10. Selector returns a protocol the client didn't offer → ignored
  # ---------------------------------------------------------------
  it 'ignores a selector return value that the client never offered' do
    selector = ->(_offers) { 'gopher' }
    _tag, _accept, sub = described_class.validate(
      base_env('HTTP_SEC_WEBSOCKET_PROTOCOL' => 'chat, superchat'),
      subprotocol_selector: selector
    )
    expect(sub).to be_nil
  end

  # ---------------------------------------------------------------
  # 11. Origin allow-list
  # ---------------------------------------------------------------
  it 'accepts an Origin in the allow-list' do
    tag, = described_class.validate(
      base_env('HTTP_ORIGIN' => 'http://allowed.com'),
      origin_allow_list: %w[http://allowed.com]
    )
    expect(tag).to eq(:ok)
  end

  it 'rejects an Origin not in the allow-list' do
    tag, body, = described_class.validate(
      base_env('HTTP_ORIGIN' => 'http://evil.com'),
      origin_allow_list: %w[http://allowed.com]
    )
    expect(tag).to eq(:bad_request)
    expect(body).to match(/Origin/i)
  end

  it 'accepts any Origin when allow_list is nil (default)' do
    tag, = described_class.validate(base_env('HTTP_ORIGIN' => 'http://anything.example'))
    expect(tag).to eq(:ok)
  end

  # ---------------------------------------------------------------
  # 12. Method != GET → 400
  # ---------------------------------------------------------------
  it 'rejects a non-GET upgrade attempt as 400' do
    tag, body, = described_class.validate(base_env('REQUEST_METHOD' => 'POST'))
    expect(tag).to eq(:bad_request)
    expect(body).to match(/GET/)
  end

  # ---------------------------------------------------------------
  # 13. HTTP/1.0 with WS headers → 400
  # ---------------------------------------------------------------
  it 'rejects HTTP/1.0 + WS headers as 400' do
    tag, body, = described_class.validate(base_env('SERVER_PROTOCOL' => 'HTTP/1.0'))
    expect(tag).to eq(:bad_request)
    expect(body).to match(%r{HTTP/1\.1})
  end

  it 'accepts HTTP/2.0 (>= HTTP/1.1)' do
    # Even though Hyperion intentionally doesn't run the WS-over-h2 path,
    # the version validator is HTTP/1.1+ — hardcoding "1.1" only would
    # break a future HTTP/2 caller. Numeric comparison keeps the door open.
    tag, = described_class.validate(base_env('SERVER_PROTOCOL' => 'HTTP/2.0'))
    expect(tag).to eq(:ok)
  end

  # ---------------------------------------------------------------
  # Misc — Host, build_101_response
  # ---------------------------------------------------------------
  it 'rejects a request without Host header' do
    env = base_env
    env.delete('HTTP_HOST')
    tag, body, = described_class.validate(env)
    expect(tag).to eq(:bad_request)
    expect(body).to match(/Host/i)
  end

  describe '.build_101_response' do
    it 'emits a well-formed 101 response with the accept header' do
      bytes = described_class.build_101_response(rfc_accept_value)
      expect(bytes).to start_with("HTTP/1.1 101 Switching Protocols\r\n")
      expect(bytes).to include("upgrade: websocket\r\n")
      expect(bytes).to include("connection: Upgrade\r\n")
      expect(bytes).to include("sec-websocket-accept: #{rfc_accept_value}\r\n")
      expect(bytes).to end_with("\r\n\r\n")
    end

    it 'echoes a subprotocol header when one is selected' do
      bytes = described_class.build_101_response(rfc_accept_value, 'superchat')
      expect(bytes).to include("sec-websocket-protocol: superchat\r\n")
    end

    it 'omits the subprotocol header when nil' do
      bytes = described_class.build_101_response(rfc_accept_value, nil)
      expect(bytes).not_to include('sec-websocket-protocol')
    end

    it 'appends arbitrary extra headers (e.g. extensions negotiation)' do
      bytes = described_class.build_101_response(
        rfc_accept_value, nil,
        'sec-websocket-extensions' => 'permessage-deflate'
      )
      expect(bytes).to include("sec-websocket-extensions: permessage-deflate\r\n")
    end
  end

  describe 'env-var driven origin allow-list' do
    it 'reads HYPERION_WS_ORIGIN_ALLOW_LIST as comma-separated default' do
      original = ENV.fetch('HYPERION_WS_ORIGIN_ALLOW_LIST', nil)
      ENV['HYPERION_WS_ORIGIN_ALLOW_LIST'] = 'http://a.example, http://b.example'
      begin
        list = described_class.default_origin_allow_list
        expect(list).to eq(%w[http://a.example http://b.example])
      ensure
        ENV['HYPERION_WS_ORIGIN_ALLOW_LIST'] = original
      end
    end

    it 'returns nil when the env var is absent' do
      original = ENV.fetch('HYPERION_WS_ORIGIN_ALLOW_LIST', nil)
      ENV.delete('HYPERION_WS_ORIGIN_ALLOW_LIST')
      begin
        expect(described_class.default_origin_allow_list).to be_nil
      ensure
        ENV['HYPERION_WS_ORIGIN_ALLOW_LIST'] = original if original
      end
    end
  end
end

RSpec.describe Hyperion::WebSocket::HandshakeError do
  it 'preserves status + extra_headers for downstream rescue handlers' do
    e = described_class.new(426, 'bad version', 'sec-websocket-version' => '13')
    expect(e.status).to eq(426)
    expect(e.message).to eq('bad version')
    expect(e.extra_headers).to eq('sec-websocket-version' => '13')
  end
end
