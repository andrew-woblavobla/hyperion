# frozen_string_literal: true

# Generic Server-Sent-Events bench rackup. No Hyperion-specific
# flush sentinels — uses standard Rack 3 chunked streaming so the
# rackup works identically on Hyperion, Puma, and Falcon.
#
# Workload: 1000 SSE events of ~50 bytes each, "data: ...\n\n" format.
# Compare msg/s + p99 latency across servers.
#
# Run:
#   bundle exec hyperion -t 5 -w 1 -p 9760 bench/sse_generic.ru
#   bundle exec puma     -t 5:5 -w 1 -b tcp://127.0.0.1:9760 bench/sse_generic.ru
#   wrk -t1 -c1 -d10s --latency http://127.0.0.1:9760/
#
# Companion to `bench/sse.ru`. The sibling rackup uses the
# Hyperion-specific `:__hyperion_flush__` sentinel which exercises
# Hyperion's ChunkedCoalescer flush hook but breaks framing on Puma
# (Puma emits the symbol as a literal chunk). This file is portable
# across servers and is the right rackup for cross-server SSE
# comparisons.

# Lazy-iterator body: yields chunks one at a time without pre-allocating
# the full event stream. Mirrors how a real SSE app would push events
# off a queue.
class SSEGenericBody
  EVENT_COUNT = 1000

  def each
    EVENT_COUNT.times do |i|
      # ~50-byte SSE event: "data: ...\n\n" — Rack 3 streaming protocol
      # yields a String per chunk (no [chunk] arrays, no flush sentinel).
      yield "data: event=#{i} ts=#{Time.now.to_f.round(3)}\n\n"
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
      'content-type'  => 'text/event-stream',
      'cache-control' => 'no-cache'
    },
    SSEGenericBody.new
  ]
}
