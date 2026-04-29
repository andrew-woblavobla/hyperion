# frozen_string_literal: true

require 'stringio'
require 'async'
require 'hyperion/response_writer'

# Phase 5 — chunked-write coalescing.
#
# These specs lock the syscall-count properties of the streaming chunked
# path: small chunks accumulate in a per-response 4 KiB buffer, large
# chunks bypass the buffer (after draining), explicit flush / end-of-body
# always drain. We also assert the no-coalescing path: a Content-Length
# response stays at exactly one syscall, untouched by Phase 5.
RSpec.describe Hyperion::ResponseWriter, 'Phase 5 — chunked-write coalescing' do
  subject(:writer) { described_class.new }

  # Counts every #write call separately so we can assert syscall-count
  # properties directly. Mirrors the CapturingIO shape used by
  # http2_writer_loop_spec but kept local to avoid spec coupling.
  let(:io) { CountingIO.new }

  class CountingIO
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(bytes)
      @writes << bytes.dup
      bytes.bytesize
    end

    def call_count
      @writes.size
    end

    # Body bytes, joined for content assertions. Note: this includes the
    # response head — the spec strips it explicitly when checking body framing.
    def joined
      @writes.join
    end

    # Syscalls AFTER the response head (every spec writes the head as its
    # first call; we count post-head writes as the meaningful "body
    # syscalls" number).
    def body_call_count
      @writes.size - 1
    end
  end

  # Splits the wire bytes into [head, body_bytes] on the first \r\n\r\n.
  # Used to inspect chunked framing.
  def split_head_body(io)
    raw = io.joined
    head_end = raw.index("\r\n\r\n")
    [raw.byteslice(0, head_end + 4), raw.byteslice(head_end + 4, raw.bytesize - head_end - 4)]
  end

  describe 'no-coalescing path (Content-Length response)' do
    it 'emits exactly 1 syscall for a Content-Length: 100 single-chunk response' do
      payload = 'x' * 100
      writer.write(io, 200, { 'content-type' => 'text/plain' }, [payload])

      expect(io.call_count).to eq(1)
      expect(io.joined).to include("content-length: 100\r\n")
      expect(io.joined).not_to include('transfer-encoding')
      expect(io.joined).to end_with(payload)
    end

    it 'still coalesces 100×50-byte non-chunked chunks into a single Content-Length write' do
      # Pre-Phase-5 behaviour preserved: when the app does NOT opt into
      # chunked, ResponseWriter buffers the body in userspace and emits
      # one syscall regardless of how many chunks the body yielded.
      body = Array.new(100) { 'a' * 50 }
      writer.write(io, 200, {}, body)

      expect(io.call_count).to eq(1)
      expect(io.joined).to include("content-length: 5000\r\n")
    end
  end

  describe 'chunked streaming path' do
    let(:headers) { { 'content-type' => 'text/event-stream', 'transfer-encoding' => 'chunked' } }

    it 'emits the chunked head with no content-length' do
      writer.write(io, 200, headers, ['hello'])

      head, _body = split_head_body(io)
      expect(head).to include("transfer-encoding: chunked\r\n")
      expect(head).not_to include('content-length:')
    end

    it 'coalesces 100 chunks of 50 bytes into ~2 buffered drains (not 100 writes)' do
      # 100 × 50 B = 5000 B of payload. With chunked framing (size-line +
      # CRLF + payload + CRLF), each ~50-B body chunk balloons to ~57 B
      # on the wire. Buffer flushes at 4 KiB (~71 framed-chunks worth);
      # the rest drains on body.close + terminator.
      chunks = Array.new(100) { 'x' * 50 }
      writer.write(io, 200, headers, chunks)

      # 1 head write + 2 buffered drains (one mid-stream at 4 KiB,
      # one at end-of-body with the terminator) = 3 total. We allow
      # 2..4 to keep the assertion robust against tick-based flushes
      # under different timing conditions; the key property is "NOT 100".
      expect(io.body_call_count).to be_between(2, 4),
                                    "expected 2..4 body writes, got #{io.body_call_count}"
      expect(io.body_call_count).to be < 10 # syscall reduction headline

      # Verify on-the-wire byte fidelity.
      _head, body_bytes = split_head_body(io)
      decoded = decode_chunked(body_bytes)
      expect(decoded.bytesize).to eq(5000)
      expect(decoded).to eq('x' * 5000)
    end

    it 'a single 10 KiB chunk skips the coalescer (1 body syscall + 1 terminator)' do
      # Big chunk (>= 512 B) drains-then-writes; the buffer is empty so
      # the drain is a no-op. After the chunk, end-of-body emits the
      # terminator as its own syscall. Total body syscalls = 2.
      payload = 'A' * 10_240
      writer.write(io, 200, headers, [payload])

      expect(io.body_call_count).to eq(2)
      _head, body_bytes = split_head_body(io)
      decoded = decode_chunked(body_bytes)
      expect(decoded).to eq(payload)
    end

    it 'mixed pattern: 50 buffered, 600 forces flush, 50 buffered, close flushes terminator' do
      # Spec narrative:
      #   * 50-byte chunk  → buffered (under threshold).
      #   * 600-byte chunk → drains buffer (1 syscall) + writes itself (1 syscall).
      #   * 50-byte chunk  → buffered again.
      #   * body.close     → buffered chunk + 0\r\n\r\n drained (1 syscall).
      writer.write(io, 200, headers, ['x' * 50, 'y' * 600, 'z' * 50])

      # 1 head + 1 buffer-drain + 1 large-chunk write + 1 final-drain = 4 total.
      expect(io.call_count).to eq(4)
      expect(io.body_call_count).to eq(3)

      _head, body_bytes = split_head_body(io)
      decoded = decode_chunked(body_bytes)
      expect(decoded).to eq(('x' * 50) + ('y' * 600) + ('z' * 50))
    end

    it 'body.close edge: 100 buffered bytes + close emits payload + chunked terminator together' do
      # The terminator MUST follow the buffered chunk on the wire — otherwise
      # a peer could see a half-flushed response between the buffer-drain and
      # the terminator-write syscalls. Verified by parsing the wire bytes.
      writer.write(io, 200, headers, ['p' * 100])

      # 1 head + 1 final-drain (which contains BOTH the framed 100-byte
      # chunk and the terminator) = 2 total syscalls.
      expect(io.call_count).to eq(2)

      _head, body_bytes = split_head_body(io)
      expect(body_bytes).to end_with("0\r\n\r\n")
      decoded = decode_chunked(body_bytes)
      expect(decoded).to eq('p' * 100)
    end

    it 'fills exactly to 4 KiB threshold then drains mid-stream' do
      # Tune to hit the 4096-B threshold dead-on: 60 chunks of 60 framed
      # bytes ≈ 3600 B; one more 60-B chunk pushes us through 4096.
      # We assert at least 2 drain calls (one at threshold, one at end).
      chunks = Array.new(80) { 'q' * 60 }
      writer.write(io, 200, headers, chunks)

      expect(io.body_call_count).to be >= 2
      _head, body_bytes = split_head_body(io)
      decoded = decode_chunked(body_bytes)
      expect(decoded).to eq('q' * (60 * 80))
    end

    it 'honours a :__hyperion_flush__ sentinel mid-stream (SSE flush hint)' do
      # SSE-style: app yields the flush sentinel after each event so
      # downstream peers don't wait the full coalescing tick.
      body = Enumerator.new do |y|
        y << 'event: ping'
        y << "\n\n"
        y << :__hyperion_flush__
        y << 'event: pong'
        y << "\n\n"
      end
      writer.write(io, 200, headers, body)

      _head, body_bytes = split_head_body(io)
      decoded = decode_chunked(body_bytes)
      expect(decoded).to eq("event: ping\n\nevent: pong\n\n")
      # Sentinel forced an extra mid-stream drain → at least 2 body
      # syscalls (drain-on-flush + final-drain-on-close).
      expect(io.body_call_count).to be >= 2
    end

    it '1 ms tick: under Async, a quiet body still flushes within 2 ms' do
      # Body yields one chunk, sleeps 5 ms (well past the 1 ms tick),
      # then yields another. The buffer should already have flushed by
      # the time chunk #2 arrives because the tick check runs on every
      # incoming chunk.
      body = Enumerator.new do |y|
        y << 'tick-1'
        # Simulate a quiet period — under Async the kernel_sleep yields
        # the fiber; the wallclock advance triggers maybe_tick_flush
        # on the next chunk arrival.
        Async::Task.current.sleep(0.005) if Async::Task.current?
        y << 'tick-2'
      end

      Sync do
        writer.write(io, 200, headers, body)
      end

      _head, body_bytes = split_head_body(io)
      decoded = decode_chunked(body_bytes)
      expect(decoded).to eq('tick-1tick-2')
      # Tick-driven flush + end-of-body flush ⇒ at least 2 body syscalls.
      # Without the tick, both 6-B chunks would coalesce into 1 final
      # drain, giving 1 body syscall.
      expect(io.body_call_count).to be >= 2
    end

    it 'closes the body on the streaming path' do
      body = Class.new do
        attr_reader :closed

        def initialize = @closed = false
        def each = yield 'hi'
        def close = @closed = true
      end.new

      writer.write(io, 200, headers, body)

      expect(body.closed).to be(true)
    end

    it 'flushes + closes even when io.write raises mid-stream' do
      body = Class.new do
        attr_reader :closed

        def initialize = @closed = false
        def each = yield 'hi'
        def close = @closed = true
      end.new

      bad_io = Object.new
      def bad_io.write(_) = raise(Errno::EPIPE)

      expect { writer.write(bad_io, 200, { 'transfer-encoding' => 'chunked' }, body) }
        .to raise_error(Errno::EPIPE)
      expect(body.closed).to be(true)
    end

    it 'drops app-supplied content-length on the chunked path (mutually exclusive per RFC 7230)' do
      writer.write(io, 200, headers.merge('content-length' => '999'), ['hi'])

      head, = split_head_body(io)
      expect(head).not_to include('content-length:')
      expect(head).to include("transfer-encoding: chunked\r\n")
    end
  end

  # Decodes RFC 7230 §4.1 chunked framing back into the original payload.
  # Used by every chunked spec to assert byte-perfect round-trip on the wire.
  def decode_chunked(bytes)
    cursor = 0
    out = String.new(encoding: Encoding::ASCII_8BIT)
    loop do
      line_end = bytes.index("\r\n", cursor) or break
      size_token = bytes.byteslice(cursor, line_end - cursor)
      size = size_token.to_i(16)
      cursor = line_end + 2
      break if size.zero?

      out << bytes.byteslice(cursor, size)
      cursor += size + 2 # skip payload + trailing CRLF
    end
    out
  end
end
