# frozen_string_literal: true

require 'socket'
require 'hyperion/connection'

# Phase 2b (1.7.1) — per-connection read accumulator reuse.
#
# Pre-1.7.1 the read accumulator (`buffer = +''`) was allocated fresh per
# request, with the previous request's pipelined carry copied into a new
# String. 1.7.1 swaps that for a single per-Connection `@inbuf` allocated
# with `String.new(capacity: 8 KiB, encoding: ASCII-8BIT)` and reused across
# every request on the same keep-alive connection.
#
# We assert reuse via `object_id` — the @inbuf identity must be preserved
# across a 2-request keep-alive sequence, and the underlying capacity must
# survive the carry collapse so the second request doesn't realloc.
RSpec.describe Hyperion::Connection do
  let(:app) do
    lambda do |env|
      [200, { 'content-type' => 'text/plain' }, ["seen #{env['PATH_INFO']}"]]
    end
  end

  describe '@inbuf reuse across keep-alive requests' do
    it 'allocates @inbuf once per connection and reuses it on the 2nd request' do
      conn = described_class.new
      a, b = ::Socket.pair(:UNIX, :STREAM)
      # Two pipelined HTTP/1.1 keep-alive requests on the same socket.
      a.write("GET /one HTTP/1.1\r\nHost: x\r\n\r\n" \
              "GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      first_inbuf_id = nil
      second_inbuf_id = nil
      requests_seen = 0

      tap_app = lambda do |env|
        requests_seen += 1
        ivar = conn.instance_variable_get(:@inbuf)
        if requests_seen == 1
          first_inbuf_id = ivar.object_id
        elsif requests_seen == 2
          second_inbuf_id = ivar.object_id
        end
        [200, { 'content-type' => 'text/plain' }, ["ok #{env['PATH_INFO']}"]]
      end

      conn.serve(b, tap_app)

      expect(requests_seen).to eq(2)
      expect(first_inbuf_id).not_to be_nil
      expect(second_inbuf_id).to eq(first_inbuf_id),
                                 "expected @inbuf reuse across keep-alive requests, but got #{first_inbuf_id} → #{second_inbuf_id}"
    ensure
      a&.close
      b&.close
    end

    it 'preserves @inbuf encoding (ASCII-8BIT) and clears it after parse' do
      conn = described_class.new
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      a.close_write

      observed_encoding = nil
      tap_app = lambda do |_env|
        ivar = conn.instance_variable_get(:@inbuf)
        observed_encoding = ivar.encoding
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end

      conn.serve(b, tap_app)
      # After the connection finishes, the carry-into-inbuf collapse should
      # have left @inbuf empty (no pipelined trailing bytes on this single-
      # request stream).
      expect(observed_encoding).to eq(Encoding::ASCII_8BIT)
      final = conn.instance_variable_get(:@inbuf)
      expect(final.bytesize).to eq(0)
    ensure
      a&.close
      b&.close
    end

    it 'two separate Connection instances each get their own @inbuf' do
      conn1 = described_class.new
      conn2 = described_class.new
      a1, b1 = ::Socket.pair(:UNIX, :STREAM)
      a2, b2 = ::Socket.pair(:UNIX, :STREAM)
      a1.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      a1.close_write
      a2.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      a2.close_write

      conn1.serve(b1, app)
      conn2.serve(b2, app)

      buf1 = conn1.instance_variable_get(:@inbuf)
      buf2 = conn2.instance_variable_get(:@inbuf)
      expect(buf1.object_id).not_to eq(buf2.object_id)
    ensure
      [a1, b1, a2, b2].each { |s| s&.close }
    end
  end

  describe 'oversized headers fall back to growable buffer (still parses correctly)' do
    it 'serves a request whose headers exceed the 8 KiB pre-sized capacity' do
      conn = described_class.new
      a, b = ::Socket.pair(:UNIX, :STREAM)
      big_value = 'x' * (12 * 1024) # >8 KiB header value forces realloc
      payload = "GET / HTTP/1.1\r\nHost: x\r\nX-Big: #{big_value}\r\n\r\n"
      # macOS UNIX socket pair sndbuf defaults to 8 KiB; a single blocking
      # write of 12 KiB+ deadlocks because there's no concurrent reader yet.
      # Drive the writer from a background thread so the server's read loop
      # can drain in parallel.
      writer = Thread.new do
        a.write(payload)
        a.close_write
      end

      observed_path = nil
      observed_big = nil
      app = lambda do |env|
        observed_path = env['PATH_INFO']
        observed_big = env['HTTP_X_BIG']
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end

      conn.serve(b, app)
      writer.join

      expect(observed_path).to eq('/')
      expect(observed_big&.bytesize).to eq(big_value.bytesize)
    ensure
      a&.close
      b&.close
    end
  end
end
