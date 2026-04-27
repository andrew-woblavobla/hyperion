# frozen_string_literal: true

module Hyperion
  # Lock-free per-thread counters. Each worker thread mutates its own Hash
  # on the hot path — no mutex acquire/release on every increment, no
  # contention across the thread pool. `snapshot` aggregates lazily across
  # all threads that have ever incremented (one short mutex section, only
  # taken when the operator asks for stats).
  #
  # Storage: counters live behind `Thread#thread_variable_*`, which is the
  # only TRUE thread-local in Ruby 1.9+ — `Thread.current[:key]` is in fact
  # FIBER-local, so under an `Async::Scheduler` (TLS path, h2 streams, the
  # 1.3.0+ `--async-io` plain HTTP/1.1 path) every handler fiber would get
  # its own private counters Hash that `snapshot` could never find.
  # Verified with hyperion-async-pg 0.4.0's bench round; before the fix
  # the dispatch counters dropped requests entirely under `--async-io` and
  # an external scrape (Prometheus exporter on a different fiber than the
  # handler) saw the dispatch buckets at zero.
  #
  # Cross-fiber races on the same OS thread: the `+=` is technically read-
  # modify-write, but Ruby's fiber scheduler only preempts at IO boundaries
  # (Fiber.scheduler-aware system calls), and `Hash#[]=` is purely Ruby —
  # no preemption mid-increment, no torn writes. Two fibers cannot
  # interleave a single `+=` on the same OS thread.
  #
  # Reset semantics: counters monotonically increase. Operators that want
  # rate-of-change should snapshot, sleep, snapshot, diff.
  #
  # Public API:
  #   Hyperion.stats -> Hash with all current values across all threads.
  class Metrics
    def initialize
      # Direct list of every per-thread counters Hash ever allocated through
      # this Metrics instance. We hold the Hash refs ourselves (instead of
      # holding Thread refs and looking the Hash up via thread-local
      # storage) so snapshot survives thread death — counters from a
      # short-lived worker that already exited still aggregate. Tiny per-
      # thread footprint (one Hash + one slot in this Array).
      @thread_counters = []
      @counters_mutex = Mutex.new
      # Per-instance thread-local key so spec runs that build fresh Metrics
      # objects don't share state across examples.
      @thread_key = :"__hyperion_metrics_#{object_id}__"
    end

    # Hot path: one thread-variable lookup + one hash op. No mutex on the
    # increment fast path; the mutex is taken only on first allocation per
    # OS thread (very rare) and on snapshot.
    #
    # Storage uses Thread#thread_variable_*, which is the only TRUE thread-
    # local in Ruby 1.9+ — Thread.current[:key] is in fact FIBER-local, so
    # under an Async::Scheduler (TLS path, h2 streams, the 1.3.0+ --async-io
    # plain HTTP/1.1 path) every handler fiber would get its own private
    # counters Hash that snapshot could never aggregate. Verified with
    # hyperion-async-pg 0.4.0's bench round; before the fix the dispatch
    # counters dropped requests under --async-io.
    #
    # Cross-fiber races on the same OS thread: the `+=` is read-modify-write,
    # but Ruby's fiber scheduler only preempts at IO boundaries (Fiber-
    # scheduler-aware system calls). Hash#[]= is purely Ruby — no
    # preemption mid-increment, no torn writes. Two fibers cannot
    # interleave a single `+=` on the same OS thread.
    def increment(key, by = 1)
      thread = Thread.current
      counters = thread.thread_variable_get(@thread_key)
      counters = register_thread_counters(thread) if counters.nil?
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
      counters_snapshot = @counters_mutex.synchronize { @thread_counters.dup }
      counters_snapshot.each do |counters|
        counters.each { |k, v| result[k] += v }
      end
      result.default = nil
      result
    end

    # Tests can call .reset! between examples to avoid cross-spec leakage.
    def reset!
      @counters_mutex.synchronize do
        @thread_counters.each(&:clear)
      end
    end

    private

    def register_thread_counters(thread)
      counters = Hash.new(0)
      thread.thread_variable_set(@thread_key, counters)
      @counters_mutex.synchronize { @thread_counters << counters }
      counters
    end
  end
end
