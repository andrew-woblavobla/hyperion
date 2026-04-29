# frozen_string_literal: true

module Hyperion
  # Process-wide HTTP/2 stream admission control (RFC A7).
  #
  # **Problem.** `h2_max_concurrent_streams` (default 128) caps streams
  # *per connection*. An abuser can open 5,000 connections × 128 streams
  # = 640k fibers → OOM → master respawns → abuser reconnects. The 1.6.0
  # backpressure cap on bytes-in-queue is 16 MiB *per connection*, so it
  # doesn't bound aggregate fiber count either. Real DoS vector,
  # currently no built-in defence.
  #
  # **Shape.** A single per-process atomic counter shared across all
  # `Http2Handler` instances within a worker. Each new stream calls
  # `#admit` before invoking the app; the call returns true when the
  # slot was reserved and false when the cap is hit. False → caller
  # sends `RST_STREAM REFUSED_STREAM` (RFC 7540 §11 / RFC 9113 §5.4.1).
  # Slot is freed by `#release` from the dispatch ensure block.
  #
  # **Default.** `max_total_streams: nil` — admission disabled, every
  # `#admit` returns true. `Server` only constructs an `H2Admission`
  # when the operator passes a positive cap. The 1.7.0 default is `nil`;
  # 2.0 flips to `h2_max_concurrent_streams × workers × 4` (RFC §3
  # 1.x-vs-2.0 split).
  #
  # **Concurrency.** Mutex hold time is "increment + compare", in the
  # tens of nanoseconds. The mutex is contention-bounded by the actual
  # rate of new stream admits, which is much lower than dispatch rate
  # (one mutex acquire per stream, not per frame). On the abuser's
  # path this is also where they hit the wall — by design.
  class H2Admission
    attr_reader :max

    def initialize(max_total_streams:)
      @max     = max_total_streams
      @count   = 0
      @rejected = 0
      @mutex = Mutex.new
    end

    # Try to acquire one stream slot. Returns true when admitted, false
    # when the cap is hit. nil cap (admission disabled) returns true
    # without taking the mutex — keeps the hot path branchless when
    # admission is off.
    def admit
      return true if @max.nil?

      @mutex.synchronize do
        if @count >= @max
          @rejected += 1
          false
        else
          @count += 1
          true
        end
      end
    end

    # Release a previously-admitted slot. Idempotent: if the count is
    # already zero (paranoia: double-release on a programming bug) this
    # is a no-op. nil cap is a no-op (admission disabled).
    def release
      return if @max.nil?

      @mutex.synchronize { @count -= 1 if @count.positive? }
    end

    # Snapshot the admission state. `in_flight` = streams currently
    # holding a slot, `rejected` = cumulative count of REFUSED_STREAM
    # events served by this gate, `max` = configured cap. Used by
    # operator dashboards via `Hyperion.stats[:h2_admission_*]` keys
    # (the stats publisher pulls these out and surfaces them).
    def stats
      @mutex.synchronize { { in_flight: @count, rejected: @rejected, max: @max } }
    end
  end
end
