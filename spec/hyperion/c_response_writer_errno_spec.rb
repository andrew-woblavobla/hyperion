# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_buffered errno paths' do
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  it 'raises Errno::EPIPE when the peer has closed' do
    r, w = Socket.pair(:UNIX, :STREAM)
    r.close
    expect {
      described_class.c_write_buffered(
        w, 200, { 'content-type' => 'text/plain' }, ['x'], true, date_str
      )
    }.to raise_error(SystemCallError) # EPIPE on most platforms; tolerate ECONNRESET on some
  ensure
    w.close unless w.closed?
  end

  it 'raises a SystemCallError on a closed write fd' do
    r, w = Socket.pair(:UNIX, :STREAM)
    fd_dup = w.fileno
    w.close
    bogus = Object.new
    bogus.define_singleton_method(:fileno) { fd_dup }
    expect {
      described_class.c_write_buffered(
        bogus, 200, { 'content-type' => 'text/plain' }, ['x'], true, date_str
      )
    }.to raise_error(SystemCallError) # EBADF or EPIPE depending on kernel + race
  ensure
    r.close unless r.closed?
  end

  it 'returns WOULDBLOCK when the kernel send buffer is full' do
    r, w = Socket.pair(:UNIX, :STREAM)
    # Shrink send buffer aggressively + non-blocking + fill the buffer.
    w.setsockopt(:SOCKET, :SNDBUF, 1024) rescue nil
    r.setsockopt(:SOCKET, :RCVBUF, 1024) rescue nil
    require 'fcntl'
    flags = w.fcntl(Fcntl::F_GETFL)
    w.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)

    big = 'x' * 4096
    fill_count = 0
    begin
      loop do
        w.write_nonblock(big)
        fill_count += 1
        break if fill_count > 1024  # safety cap
      end
    rescue IO::WaitWritable, Errno::EAGAIN
      # Buffer full as expected.
    end

    rc = described_class.c_write_buffered(
      w, 200, { 'content-type' => 'text/plain' }, ['payload'],
      true, date_str
    )
    expect(rc).to eq(Hyperion::Http::ResponseWriter::WOULDBLOCK)
  ensure
    [r, w].each { |s| s.close unless s.closed? }
  end

  it 'returns the WOULDBLOCK constant verbatim (Integer, equals -2)' do
    expect(Hyperion::Http::ResponseWriter::WOULDBLOCK).to eq(-2)
  end
end

RSpec.describe Hyperion::Http::ResponseWriter, '#c_write_chunked errno paths' do
  let(:date_str) { 'Tue, 05 May 2026 12:00:00 GMT' }

  it 'raises a SystemCallError when the peer has closed before head emit' do
    r, w = Socket.pair(:UNIX, :STREAM)
    r.close
    expect {
      described_class.c_write_chunked(
        w, 200, { 'content-type' => 'text/plain' }, ['x'], true, date_str
      )
    }.to raise_error(SystemCallError)
  ensure
    w.close unless w.closed?
  end

  it 'raises Errno::EAGAIN on mid-body backpressure (non-blocking + tiny buffer)' do
    r, w = Socket.pair(:UNIX, :STREAM)
    w.setsockopt(:SOCKET, :SNDBUF, 1024) rescue nil
    r.setsockopt(:SOCKET, :RCVBUF, 1024) rescue nil
    require 'fcntl'
    flags = w.fcntl(Fcntl::F_GETFL)
    w.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)

    # Body is many small chunks; with the tiny send buffer, mid-body
    # writev will eventually return EAGAIN. The chunked drain raises
    # Errno::EAGAIN per the response_writer.c contract (no silent drop).
    body = Array.new(50) { 'X' * 256 } # 12.8 KiB total >> 1 KiB SNDBUF
    expect {
      described_class.c_write_chunked(
        w, 200, { 'content-type' => 'text/plain' }, body, true, date_str
      )
    }.to raise_error(Errno::EAGAIN, /chunked.*backpressure|WOULDBLOCK|Resource temporarily unavailable/i)
  ensure
    [r, w].each { |s| s.close unless s.closed? }
  end
end
