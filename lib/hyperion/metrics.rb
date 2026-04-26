# frozen_string_literal: true

module Hyperion
  # Lock-free per-thread counters. Each worker thread mutates its own Hash
  # on the hot path — no mutex acquire/release on every increment, no
  # contention across the thread pool. `snapshot` aggregates lazily across
  # all threads that have ever incremented (one short mutex section, only
  # taken when the operator asks for stats).
  #
  # Reset semantics: counters monotonically increase. Operators that want
  # rate-of-change should snapshot, sleep, snapshot, diff.
  #
  # Public API:
  #   Hyperion.stats -> Hash with all current values across all threads.
  class Metrics
    def initialize
      @threads = Set.new
      @threads_mutex = Mutex.new
      # Each Metrics instance has its own thread-local key so spec runs that
      # build fresh Metrics objects don't share state across examples.
      @thread_key = :"__hyperion_metrics_#{object_id}__"
    end

    # Hot path: one TLS lookup + one hash op. No mutex.
    def increment(key, by = 1)
      counters = Thread.current[@thread_key] ||= register_thread_counters
      counters[key] += by
    end

    def decrement(key, by = 1)
      increment(key, -by)
    end

    def increment_status(code)
      increment(:"responses_#{code}")
    end

    def snapshot
      result = Hash.new(0)
      @threads_mutex.synchronize do
        @threads.delete_if { |t| !t.alive? }
        @threads.each do |t|
          counters = t[@thread_key]
          next unless counters

          counters.each { |k, v| result[k] += v }
        end
      end
      result.default = nil
      result
    end

    # Tests can call .reset! between examples to avoid cross-spec leakage.
    def reset!
      @threads_mutex.synchronize do
        @threads.each { |t| t[@thread_key]&.clear }
      end
    end

    private

    def register_thread_counters
      counters = Hash.new(0)
      @threads_mutex.synchronize { @threads << Thread.current }
      counters
    end
  end
end
