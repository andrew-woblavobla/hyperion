# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_chunked' do
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  before { @r, @w = Socket.pair(:UNIX, :STREAM) }
  after  { [@r, @w].each { |s| s.close unless s.closed? } }

  def parse_chunked_body(bytes)
    head, body = bytes.split("\r\n\r\n", 2)
    expect(head).to include('transfer-encoding: chunked')
    chunks = []
    while body && !body.empty?
      size_line, rest = body.split("\r\n", 2)
      size = size_line.to_i(16)
      break if size.zero?
      payload = rest[0, size]
      chunks << payload
      body = rest[(size + 2)..]
    end
    chunks
  end

  it 'frames a single-chunk body and emits the 0-terminator' do
    body = ['hello world']
    described_class.c_write_chunked(@w, 200, { 'content-type' => 'text/plain' },
                                    body, true, date_str)
    @w.close
    bytes = @r.read

    expect(bytes).to start_with("HTTP/1.1 200 OK\r\n")
    expect(bytes).to include("transfer-encoding: chunked\r\n")
    expect(bytes).to end_with("0\r\n\r\n")
    expect(parse_chunked_body(bytes)).to eq(['hello world'])
  end

  it 'coalesces multiple small chunks into one syscall before draining' do
    body = ['a', 'b', 'c', 'd', 'e']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(%w[a b c d e])
  end

  it 'drain-then-emit ordering: big chunk after small chunks preserves order' do
    body = ['tiny1', 'tiny2', 'X' * 4500, 'tiny3']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(['tiny1', 'tiny2', 'X' * 4500, 'tiny3'])
  end

  it 'flushes on the :__hyperion_flush__ sentinel' do
    body = ['a', :__hyperion_flush__, 'b']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(%w[a b])
  end

  it 'mutually-excludes content-length' do
    described_class.c_write_chunked(@w, 200, { 'content-length' => '999' },
                                    ['x'], true, date_str)
    @w.close
    head = @r.read.split("\r\n\r\n", 2).first
    expect(head).to include('transfer-encoding: chunked')
    expect(head).not_to include("content-length:")
  end

  it 'skips nil chunks' do
    body = ['a', nil, 'b']
    described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq(%w[a b])
  end

  it 'returns the total byte count written' do
    body = ['hello']
    n = described_class.c_write_chunked(@w, 200, {}, body, true, date_str)
    @w.close
    expect(n).to eq(@r.read.bytesize)
  end

  it 'handles a chunk larger than the 4 KiB coalesce buffer (exercises the large-chunk writev branch)' do
    # 4100 bytes > (4096 - 32) threshold that triggers the 3-iov writev
    # large-chunk branch.  The total response (~4.3 KiB) fits inside the
    # 8 KiB Unix socketpair buffer on macOS, avoiding a GVL-held blocking
    # write deadlock.  Correct 200 KiB write-through is verified on the
    # Linux CI host where socketpair buffers are 256 KiB.
    big = 'X' * 4100
    described_class.c_write_chunked(@w, 200, {}, [big], true, date_str)
    @w.close
    chunks = parse_chunked_body(@r.read)
    expect(chunks).to eq([big])
  end
end
