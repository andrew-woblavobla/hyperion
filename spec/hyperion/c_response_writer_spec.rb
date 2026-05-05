# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_buffered' do
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  before do
    @r, @w = Socket.pair(:UNIX, :STREAM)
  end

  after do
    [@r, @w].each { |s| s.close unless s.closed? }
  end

  it 'is available when the C ext is built' do
    expect(described_class.available?).to eq(true)
    expect(described_class).to respond_to(:c_write_buffered)
  end

  it 'writes a complete HTTP/1.1 response in one syscall on a kernel fd' do
    headers = { 'content-type' => 'text/plain' }
    body    = ['hello']
    bytes_written = described_class.c_write_buffered(
      @w, 200, headers, body, true, date_str
    )

    @w.close
    response = @r.read
    expect(response).to start_with("HTTP/1.1 200 OK\r\n")
    expect(response).to include("content-type: text/plain\r\n")
    expect(response).to include("content-length: 5\r\n")
    expect(response).to include("connection: keep-alive\r\n")
    expect(response).to include("date: #{date_str}\r\n")
    expect(response).to end_with("\r\n\r\nhello")
    expect(bytes_written).to eq(response.bytesize)
  end

  it 'handles a multi-element Array body' do
    headers = { 'content-type' => 'text/plain' }
    body    = %w[hello world]

    described_class.c_write_buffered(@w, 200, headers, body, false, date_str)
    @w.close
    response = @r.read
    expect(response).to include("content-length: 10\r\n")
    expect(response).to include("connection: close\r\n")
    expect(response).to end_with("\r\n\r\nhelloworld")
  end

  it 'handles an empty body Array' do
    described_class.c_write_buffered(@w, 204, {}, [], true, date_str)
    @w.close
    response = @r.read
    expect(response).to start_with("HTTP/1.1 204 No Content\r\n")
    expect(response).to include("content-length: 0\r\n")
    expect(response).to end_with("\r\n\r\n")
  end

  it 'returns the byte count' do
    headers = { 'content-type' => 'text/plain' }
    body    = ['x' * 100]

    bytes = described_class.c_write_buffered(@w, 200, headers, body, true, date_str)
    @w.close
    expect(bytes).to eq(@r.read.bytesize)
  end

  it 'raises ArgumentError when a header value contains CR/LF' do
    expect {
      described_class.c_write_buffered(
        @w, 200, { 'x-bad' => "value\r\nInjected: yes" },
        ['ok'], true, date_str
      )
    }.to raise_error(ArgumentError, /CR\/LF|control|inject/i)
  end

  it 'raises TypeError when a body chunk is not a String' do
    expect {
      described_class.c_write_buffered(
        @w, 200, { 'content-type' => 'text/plain' },
        [42], true, date_str
      )
    }.to raise_error(TypeError)
  end

  it 'exposes a WOULDBLOCK constant for the EAGAIN sentinel' do
    expect(described_class).to be_const_defined(:WOULDBLOCK)
    expect(described_class::WOULDBLOCK).to be_a(Integer)
    expect(described_class::WOULDBLOCK).to be < 0
  end
end
