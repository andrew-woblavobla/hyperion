# frozen_string_literal: true

require 'openssl'

RSpec.describe Hyperion::TLS do
  it 'builds an SSLContext with h2 + http/1.1 ALPN protocols' do
    cert, key = TLSHelper.self_signed
    ctx = described_class.context(cert: cert, key: key)

    expect(ctx).to be_a(OpenSSL::SSL::SSLContext)
    expect(ctx.alpn_protocols).to eq(%w[h2 http/1.1])
  end

  it 'selects h2 when the client offers it' do
    cert, key = TLSHelper.self_signed
    ctx = described_class.context(cert: cert, key: key)

    expect(ctx.alpn_select_cb.call(%w[h2 http/1.1])).to eq('h2')
  end

  it 'falls back to http/1.1 when h2 is not offered' do
    cert, key = TLSHelper.self_signed
    ctx = described_class.context(cert: cert, key: key)

    expect(ctx.alpn_select_cb.call(['http/1.1'])).to eq('http/1.1')
  end
end
