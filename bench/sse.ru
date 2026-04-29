# frozen_string_literal: true

# Phase 5 — SSE streaming bench app.
#
# Streams 1000 Server-Sent-Events of ~50 bytes each over a single
# keep-alive connection, with a periodic flush hint so the server can
# decide to drain the coalescing buffer mid-stream. Used to measure
# syscall reduction from chunked-write coalescing.
#
# Run:
#   bundle exec hyperion --no-tls --port 9292 -t 1 -w 1 \
#     -c bench/sse.ru
#   wrk -t1 -c1 -d10s http://127.0.0.1:9292/
#
# Measure syscall count:
#   Linux:  strace -f -c -e write -p $(pidof ruby)
#   macOS:  sudo dtruss -c -t write -p $(pgrep -f hyperion)
#
# Pre-Phase-5 baseline (one io.write per event): ~1000 writes / response.
# Post-Phase-5 expected: ~10-15 writes / response (1 head + N buffer
# drains + 1 terminator).

# Lazy-iterator body: yields chunks one at a time without pre-allocating
# the full 50 KiB array. Mirrors how a real SSE app would push events
# off a queue.
class SseBody
  EVENT_COUNT  = 1000
  FLUSH_EVERY  = 50

  def each
    EVENT_COUNT.times do |i|
      # ~50-byte SSE event: id + data + double-newline.
      yield(format("id: %d\ndata: {\"x\":%d,\"t\":%d}\n\n", i, i, i))
      # Flush hint every N events — exercises ChunkedCoalescer#force_flush!.
      yield(:__hyperion_flush__) if (i + 1) % FLUSH_EVERY == 0
    end
  end

  def close
    # No backing resource; here for Rack compliance.
  end
end

run lambda { |_env|
  [
    200,
    {
      'content-type'      => 'text/event-stream',
      'cache-control'     => 'no-cache',
      'transfer-encoding' => 'chunked'
    },
    SseBody.new
  ]
}
