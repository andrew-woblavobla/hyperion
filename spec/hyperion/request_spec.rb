# frozen_string_literal: true

require 'hyperion/request'

RSpec.describe Hyperion::Request do
  subject(:request) do
    described_class.new(
      method: 'POST',
      path: '/foo',
      query_string: 'a=1',
      http_version: 'HTTP/1.1',
      headers: { 'host' => 'x', 'content-type' => 'application/json' },
      body: 'payload'
    )
  end

  it 'exposes attrs' do
    expect(request.method).to eq('POST')
    expect(request.path).to eq('/foo')
    expect(request.query_string).to eq('a=1')
    expect(request.http_version).to eq('HTTP/1.1')
    expect(request.body).to eq('payload')
  end

  it 'header lookup is case-insensitive' do
    expect(request.header('Host')).to eq('x')
    expect(request.header('CONTENT-TYPE')).to eq('application/json')
    expect(request.header('missing')).to be_nil
  end
end
