# frozen_string_literal: true

require 'async'

# 2.11-A — h2 first-stream TLS handshake parallelization. Bucket 2 fix:
# the per-stream dispatch fiber is no longer spawned lazily on the first
# `ready_ids` tick. We pre-spawn a fixed pool of warm dispatch worker
# fibers when `serve` enters, parked on a per-connection
# `dispatch_queue`. When a stream becomes ready, the connection-loop
# fiber pushes the stream onto the queue; a parked worker grabs it and
# calls `dispatch_stream`. Streams that arrive when the pool is busy
# fall back to ad-hoc `task.async {}` so concurrency is never artificially
# capped (admission control is the operator-facing knob).
#
# These specs lock the contract WITHOUT booting a full TLS stack:
#
#   1. WriterContext exposes the dispatch queue + a worker-count reader
#      that bench harnesses + diagnostics can introspect.
#   2. Pre-spawned workers exist as soon as `serve` has called the warmup
#      hook — the first stream does NOT pay a fiber-spawn cost.
#   3. Workers terminate cleanly when the queue is closed (connection
#      teardown).
#   4. The pool size is configurable via env var `HYPERION_H2_DISPATCH_POOL`
#      with a sane default; invalid values fall back to the default
#      rather than crashing the connection.
RSpec.describe 'Hyperion::Http2Handler 2.11-A dispatch worker pool' do
  describe Hyperion::Http2Handler::WriterContext do
    it 'exposes a dispatch_queue (Async::Queue) for the worker pool' do
      ctx = described_class.new
      expect(ctx.dispatch_queue).to be_a(::Async::Queue)
    end

    it 'starts with worker_count 0 (workers are spawned by serve)' do
      ctx = described_class.new
      expect(ctx.dispatch_worker_count).to eq(0)
    end

    it 'tracks worker_count as workers register + unregister' do
      ctx = described_class.new
      ctx.register_dispatch_worker
      ctx.register_dispatch_worker
      expect(ctx.dispatch_worker_count).to eq(2)
      ctx.unregister_dispatch_worker
      expect(ctx.dispatch_worker_count).to eq(1)
    end

    it 'unregister floors at 0 (paranoia against double-unregister)' do
      ctx = described_class.new
      ctx.unregister_dispatch_worker
      expect(ctx.dispatch_worker_count).to eq(0)
    end
  end

  describe '#resolve_dispatch_pool_size' do
    let(:handler) { Hyperion::Http2Handler.new(app: ->(_env) { [200, {}, ['ok']] }) }

    around do |ex|
      saved = ENV['HYPERION_H2_DISPATCH_POOL']
      ex.run
    ensure
      saved.nil? ? ENV.delete('HYPERION_H2_DISPATCH_POOL') : ENV['HYPERION_H2_DISPATCH_POOL'] = saved
    end

    it 'defaults to a small positive integer when env unset' do
      ENV.delete('HYPERION_H2_DISPATCH_POOL')
      size = handler.send(:resolve_dispatch_pool_size)
      expect(size).to be >= 1
      expect(size).to be <= 16
    end

    it 'honours an operator-supplied positive integer' do
      ENV['HYPERION_H2_DISPATCH_POOL'] = '8'
      expect(handler.send(:resolve_dispatch_pool_size)).to eq(8)
    end

    it 'falls back to the default for non-integer / non-positive values' do
      ENV.delete('HYPERION_H2_DISPATCH_POOL')
      default_size = handler.send(:resolve_dispatch_pool_size)
      ['0', '-1', 'abc', '', '   '].each do |bad|
        ENV['HYPERION_H2_DISPATCH_POOL'] = bad
        expect(handler.send(:resolve_dispatch_pool_size)).to eq(default_size), "for #{bad.inspect}"
      end
    end

    it 'caps the pool size at the documented ceiling' do
      ENV['HYPERION_H2_DISPATCH_POOL'] = '100'
      # Ceiling guards against a pathological config that would spawn
      # hundreds of idle fibers per connection.
      size = handler.send(:resolve_dispatch_pool_size)
      expect(size).to be <= 16
    end
  end

  describe '#warmup_dispatch_pool!' do
    let(:handler) { Hyperion::Http2Handler.new(app: ->(_env) { [200, {}, ['ok']] }) }
    let(:writer_ctx) { Hyperion::Http2Handler::WriterContext.new }

    it 'spawns N pre-warmed worker fibers parked on dispatch_queue' do
      Async do |task|
        handler.send(:warmup_dispatch_pool!, task, writer_ctx, peer_addr: nil, pool_size: 3)

        # Workers register synchronously when scheduled — yield once so they
        # all run their start-of-loop bookkeeping.
        task.yield

        expect(writer_ctx.dispatch_worker_count).to eq(3)

        # Closing the queue makes workers fall out of `dequeue`. Wait a
        # microtask to let them unregister.
        writer_ctx.dispatch_queue.close
        task.yield until writer_ctx.dispatch_worker_count.zero?

        expect(writer_ctx.dispatch_worker_count).to eq(0)
      end
    end

    it 'workers process queued items by calling dispatch_stream' do
      seen = []
      stub_handler = Hyperion::Http2Handler.new(app: ->(_env) { [200, {}, ['ok']] })
      # Patch dispatch_stream so the spec doesn't need a real protocol-http2
      # Stream — we only assert the pool plumbing routes work to workers.
      stub_handler.define_singleton_method(:dispatch_stream) do |stream, _ctx, _peer|
        seen << stream
      end

      Async do |task|
        ctx = Hyperion::Http2Handler::WriterContext.new
        stub_handler.send(:warmup_dispatch_pool!, task, ctx, peer_addr: '1.2.3.4', pool_size: 2)
        task.yield

        ctx.dispatch_queue.enqueue(:stream_a)
        ctx.dispatch_queue.enqueue(:stream_b)
        # Yield until both have been picked up + processed.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
        task.yield while seen.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        expect(seen).to contain_exactly(:stream_a, :stream_b)
      ensure
        ctx.dispatch_queue.close
      end
    end

    it 'one bad stream does NOT poison the worker pool — workers keep running' do
      seen = []
      stub_handler = Hyperion::Http2Handler.new(app: ->(_env) { [200, {}, ['ok']] })
      stub_handler.define_singleton_method(:dispatch_stream) do |stream, _ctx, _peer|
        # Simulate a stream that escaped `dispatch_stream`'s own rescue net
        # — the worker rescue must catch it and keep going.
        raise 'kaboom' if stream == :poisoned

        seen << stream
      end

      Async do |task|
        ctx = Hyperion::Http2Handler::WriterContext.new
        stub_handler.send(:warmup_dispatch_pool!, task, ctx, peer_addr: nil, pool_size: 1)
        task.yield

        ctx.dispatch_queue.enqueue(:poisoned)
        ctx.dispatch_queue.enqueue(:good_one)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
        task.yield while seen.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        expect(seen).to eq([:good_one])
        expect(ctx.dispatch_worker_count).to eq(1) # worker still alive
      ensure
        ctx.dispatch_queue.close
      end
    end
  end
end

# 2.11-A integration: end-to-end via curl --http2 on a real TLS listener.
# Locks (a) the preface SETTINGS frame goes out before the response DATA
# on a cold connection (asserted via successful curl response — the spec
# would fail with REFUSED_STREAM / GOAWAY if the pre-warm hook caused a
# frame-ordering regression) and (c) the timing instrumentation continues
# to fire the same `'h2 first-stream timing'` log shape with all four
# deltas reported.
RSpec.describe 'Hyperion::Http2Handler 2.11-A end-to-end' do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok-2.11A']] } }

  around do |ex|
    saved = ENV['HYPERION_H2_TIMING']
    ENV['HYPERION_H2_TIMING'] = '1'
    ex.run
  ensure
    saved.nil? ? ENV.delete('HYPERION_H2_TIMING') : ENV['HYPERION_H2_TIMING'] = saved
  end

  it 'serves a cold HTTP/2 connection (preface ordering preserved post-warmup)' do
    skip 'curl with HTTP/2 support not on PATH' unless system('curl --version 2>/dev/null | grep -q HTTP2')

    cert, key = TLSHelper.self_signed
    timing_logs = []
    logger = Object.new
    log_lock = Mutex.new
    logger.define_singleton_method(:info) { |&blk| log_lock.synchronize { timing_logs << blk.call } if blk }
    logger.define_singleton_method(:warn) { |&_blk| nil }
    logger.define_singleton_method(:error) { |&_blk| nil }
    logger.define_singleton_method(:debug) { |&_blk| nil }

    runtime = Hyperion::Runtime.new(metrics: Hyperion::Metrics.new, logger: logger)
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app,
                                  tls: { cert: cert, key: key },
                                  runtime: runtime)
    server.listen
    port = server.port

    serve_thread = Thread.new { server.start }

    deadline = Time.now + 3
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didnt bind' if Time.now > deadline

      sleep 0.01
    end

    output = `curl -sSk --http2 https://127.0.0.1:#{port}/test 2>/dev/null`
    expect(output).to eq('ok-2.11A')

    # Connection close happens after curl exits; allow a moment for the
    # ensure block in `serve` to emit the timing line.
    timing_line = nil
    timing_deadline = Time.now + 2
    until timing_line || Time.now > timing_deadline
      timing_line = log_lock.synchronize do
        timing_logs.find { |l| l.is_a?(Hash) && l[:message] == 'h2 first-stream timing' }
      end
      sleep 0.05 unless timing_line
    end

    expect(timing_line).not_to be_nil, "expected an 'h2 first-stream timing' log, got: #{timing_logs.inspect}"
    # Lock the documented log shape: all four deltas must be present.
    expect(timing_line.keys).to include(
      :message, :t0_to_t1_ms, :t1_to_t2_enc_ms, :t2_enc_to_t2_wire_ms, :t0_to_t2_wire_ms
    )
    # t0_to_t1_ms (preface exchange) and t0_to_t2_wire_ms (preface bytes
    # on the wire) must be non-negative — they bracket strict happens-before
    # relationships in the connection lifecycle.
    expect(timing_line[:t0_to_t1_ms]).to be >= 0
    expect(timing_line[:t0_to_t2_wire_ms]).to be >= 0
  ensure
    server&.stop
    serve_thread&.join(2)
  end
end
