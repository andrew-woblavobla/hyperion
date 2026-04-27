# frozen_string_literal: true

require 'async'
require 'stringio'

# Coverage for the per-connection send queue + writer fiber introduced in
# 1.6.0 (replaces the global @send_mutex). These specs exercise the moving
# parts directly without booting a full TLS stack:
#
#   * SendQueueIO.write enqueues bytes onto the WriterContext queue.
#   * The writer-loop drains the queue in enqueue order onto a captured IO.
#   * Multiple "encoder fibers" can enqueue concurrently and the bytes land
#     on the wire in the order they were handed off.
#   * Backpressure: encoders block when @pending_bytes exceeds the cap and
#     resume after the writer drains.
#   * Shutdown drains any final frames before the writer fiber exits.
RSpec.describe Hyperion::Http2Handler, 'send queue + writer loop' do
  # A minimal IO-shape that records every write call. Closed? state is
  # reported faithfully so the writer loop's flush guard behaves correctly.
  class CapturingIO
    attr_reader :writes

    def initialize
      @writes = []
      @closed = false
      @mutex  = Mutex.new
    end

    def write(bytes)
      @mutex.synchronize { @writes << bytes.dup }
      bytes.bytesize
    end

    def flush; end

    def close
      @mutex.synchronize { @closed = true }
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def all_bytes
      @mutex.synchronize { @writes.join }
    end
  end

  let(:handler) { described_class.new(app: ->(_env) { [200, {}, []] }) }

  # The writer loop is a private instance method on Http2Handler. Use #send
  # so tests don't need to redefine it through a public shim.
  def run_writer(socket, ctx)
    handler.send(:run_writer_loop, socket, ctx)
  end

  describe Hyperion::Http2Handler::SendQueueIO do
    let(:ctx) { Hyperion::Http2Handler::WriterContext.new }
    let(:socket) { CapturingIO.new }
    let(:io) { described_class.new(socket, ctx) }

    it 'returns the bytesize from #write so framer accounting is correct' do
      expect(io.write('hello')).to eq(5)
    end

    it 'enqueues bytes onto the WriterContext queue without writing to the socket' do
      io.write('frame-1')
      io.write('frame-2')
      expect(socket.writes).to be_empty
      expect(ctx.pending_bytes).to eq(7 + 7)
    end

    it 'is a no-op for empty / nil writes (avoids spurious enqueue)' do
      expect(io.write('')).to eq(0)
      expect(io.write(nil)).to eq(0)
      expect(ctx.pending_bytes).to eq(0)
    end

    it 'reports the underlying socket close state' do
      expect(io.closed?).to be(false)
      socket.close
      expect(io.closed?).to be(true)
    end
  end

  describe 'writer loop drains enqueued bytes in order' do
    it 'flushes a single encoder fiber\'s frames in enqueue order' do
      ctx = Hyperion::Http2Handler::WriterContext.new
      socket = CapturingIO.new

      Async do |task|
        writer = task.async { run_writer(socket, ctx) }

        # Encoder enqueues 3 chunks under the encode mutex (mirrors how
        # send_headers + send_data interact with the per-stream write path).
        ctx.encode_mutex.synchronize do
          ctx.enqueue('HEADERS')
          ctx.enqueue('DATA-A')
          ctx.enqueue('DATA-END')
        end

        ctx.shutdown!
        writer.wait
      end

      expect(socket.writes).to eq(%w[HEADERS DATA-A DATA-END])
    end

    it 'preserves per-encoder ordering when two encoders push concurrently' do
      ctx = Hyperion::Http2Handler::WriterContext.new
      socket = CapturingIO.new

      Async do |task|
        writer = task.async { run_writer(socket, ctx) }

        # Two encoder fibers, each emitting an ordered triplet for their
        # stream. Per-stream order MUST be preserved on the wire
        # (HEADERS → DATA → END_STREAM); cross-stream interleaving is fine.
        encoder_a = task.async do
          ctx.encode_mutex.synchronize do
            ctx.enqueue('A:HEADERS')
            ctx.enqueue('A:DATA')
            ctx.enqueue('A:END')
          end
        end
        encoder_b = task.async do
          ctx.encode_mutex.synchronize do
            ctx.enqueue('B:HEADERS')
            ctx.enqueue('B:DATA')
            ctx.enqueue('B:END')
          end
        end

        encoder_a.wait
        encoder_b.wait
        ctx.shutdown!
        writer.wait
      end

      a_indices = socket.writes.each_index.select { |i| socket.writes[i].start_with?('A:') }
      b_indices = socket.writes.each_index.select { |i| socket.writes[i].start_with?('B:') }

      expect(socket.writes.size).to eq(6)
      expect(a_indices.size).to eq(3)
      expect(b_indices.size).to eq(3)

      # Per-stream wire order MUST be HEADERS → DATA → END.
      expect(a_indices.map { |i| socket.writes[i] }).to eq(%w[A:HEADERS A:DATA A:END])
      expect(b_indices.map { |i| socket.writes[i] }).to eq(%w[B:HEADERS B:DATA B:END])
    end
  end

  describe 'backpressure on @pending_bytes' do
    it 'parks the encoder when pending bytes exceed the cap and resumes after drain' do
      cap = 1024
      ctx = Hyperion::Http2Handler::WriterContext.new(max_pending_bytes: cap)
      socket = CapturingIO.new

      enqueue_log = []

      Async do |task|
        # Fill the queue to the cap WITHOUT a writer running — encoder will
        # be allowed through up to the cap.
        ctx.enqueue('a' * cap)
        # The next enqueue MUST block. Spawn the encoder as a task and
        # verify it does not complete until the writer drains.
        encoder = task.async do
          ctx.enqueue('b' * 256)
          enqueue_log << :encoder_returned
        end

        # Yield a few times to give the encoder a chance to either complete
        # (bug) or park (correct).
        3.times { task.yield }
        expect(enqueue_log).to be_empty
        expect(encoder.running?).to be(true)

        # Now spawn the writer. It will drain the queue and signal the
        # encoder waiting on @drained_notify.
        writer = task.async { run_writer(socket, ctx) }

        encoder.wait
        ctx.shutdown!
        writer.wait
      end

      expect(enqueue_log).to eq([:encoder_returned])
      expect(socket.all_bytes.bytesize).to eq(cap + 256)
    end
  end

  describe 'shutdown handshake' do
    it 'drains all queued bytes before the writer fiber exits' do
      ctx = Hyperion::Http2Handler::WriterContext.new
      socket = CapturingIO.new

      Async do |task|
        writer = task.async { run_writer(socket, ctx) }

        # Enqueue a final batch then immediately request shutdown — the
        # writer must flush all of them before returning.
        10.times { |i| ctx.enqueue("frame-#{i}") }
        ctx.shutdown!

        writer.wait
        expect(writer.running?).to be_falsy
      end

      expect(socket.writes.size).to eq(10)
      expect(socket.writes).to eq((0..9).map { |i| "frame-#{i}" })
    end

    it 'exits cleanly when shutdown is requested with an empty queue' do
      ctx = Hyperion::Http2Handler::WriterContext.new
      socket = CapturingIO.new

      Async do |task|
        writer = task.async { run_writer(socket, ctx) }

        # No bytes enqueued — writer is parked on @send_notify. shutdown!
        # signals it; the loop sees writer_done? && queue_empty? and exits.
        ctx.shutdown!
        writer.wait
        expect(writer.running?).to be_falsy
      end

      expect(socket.writes).to be_empty
    end
  end
end
