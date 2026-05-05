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
    class << self
      # 2.4-C — process-wide default PathTemplater. Read by Connection at
      # construction; written by the boot path (Worker / single-mode CLI)
      # from `Hyperion::Config#metrics.path_templater`. Per-Connection
      # override stays available via the `path_templater:` kwarg for
      # specs and library users that build a Connection manually.
      attr_writer :default_path_templater

      def default_path_templater
        @default_path_templater ||= PathTemplater.new
      end

      def reset_default_path_templater!
        @default_path_templater = nil
      end
    end

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

      # 2.4-C — observability enrichment. Histograms and gauges live as
      # separate keyed structures (vs counters) because the wire format
      # is different (per-bucket cumulative counts + sum/count for
      # histograms; a single instantaneous reading for gauges). Both are
      # mutex-guarded — these are scrape-rate operations (one observe per
      # request, one set per worker boot/shutdown), not per-syscall.
      #
      # Histograms: `{ name => { labels_tuple_array => HistogramAccumulator } }`.
      # Gauges:     `{ name => { labels_tuple_array => Float } }`.
      # `labels_tuple_array` is a frozen Array<String> of label values
      # (stable order, supplied by the observer); it doubles as the Hash
      # key for cheap O(1) lookup.
      @histograms      = {}
      @histograms_meta = {} # name => { buckets:, label_keys: }
      @gauges          = {}
      @gauges_meta     = {} # name => { label_keys: }
      @hg_mutex        = Mutex.new
      # Snapshot block hooks for gauges whose value is read on demand
      # (ThreadPool queue depth, etc.). `{ name => { labels_tuple => Proc } }`.
      @gauge_blocks    = {}

      # 2.13-A — per-thread shards for the hot-path metrics that USED to
      # take @hg_mutex on every observe / increment. The pre-2.13-A
      # comment in `increment_labeled_counter` claimed those paths were
      # "low-rate" — that turned out to be wrong: `tick_worker_request`
      # fires once per Rack request, and `observe_histogram` fires once
      # per request via the per-route duration histogram. Under -t 32
      # the single mutex serialised every worker thread on the
      # request-completion tail. Per-thread shards remove the
      # contention; snapshots merge across threads under the mutex
      # (snapshot is a low-rate operation — once per /-/metrics scrape).
      #
      # Thread-variable storage (NOT Thread.current[]) for the same
      # reason as the unlabeled counter path: under an Async scheduler
      # `Thread.current[:k]` is fiber-local, which would let snapshots
      # miss observations made on a fiber that already exited.
      @hg_thread_key   = :"__hyperion_metrics_hg_#{object_id}__"
      @lc_thread_key   = :"__hyperion_metrics_lc_#{object_id}__"
      # Holds direct references to every per-thread shard ever
      # allocated through this Metrics instance (mirrors @thread_counters)
      # so snapshots survive thread death.
      @thread_histograms = []
      @thread_labeled_counters = []
      @hg_thread_mutex         = Mutex.new
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

    # PR3-1 — STATUS_SYMBOLS: pre-intern :"responses_NNN" for the 40 most
    # common HTTP status codes.  `increment_status` was doing
    # `:"responses_#{code}"` per request — that's a String allocation +
    # Symbol table lookup on every response.  The table lookup is O(1) Hash
    # but the interpolation pays a hidden 1-String-per-call cost even when
    # the resulting Symbol is already interned.  Pre-building the frozen
    # Hash eliminates that allocation on the hot path; the fallback
    # `:"responses_#{code}"` covers exotic codes without breaking anything.
    STATUS_SYMBOLS = begin
      codes = [
        100, 101, 200, 201, 202, 203, 204, 205, 206,
        301, 302, 303, 304, 307, 308,
        400, 401, 402, 403, 404, 405, 406, 407, 408, 409,
        410, 411, 412, 413, 414, 415, 416, 422, 429,
        500, 501, 502, 503, 504, 505
      ]
      h = {}
      codes.each { |c| h[c] = :"responses_#{c}" }
      h.freeze
    end

    def increment_status(code)
      increment(STATUS_SYMBOLS[code] || :"responses_#{code}")
    end

    # 2.12-E — labeled counter family that observes which worker
    # process a given request landed on. Ticks once per dispatched
    # request from every dispatch shape (Connection#serve, h2 streams,
    # the C accept4 + io_uring loops; see PrometheusExporter for the
    # C-loop fold-in at scrape time).
    #
    # `worker_id` is conventionally `Process.pid.to_s` — matches the
    # 2.4-C `hyperion_io_uring_workers_active` and
    # `hyperion_per_conn_rejections_total` labeling convention; lets
    # operators correlate distribution rows with `ps`/`/proc` data
    # without a separate worker_id <-> pid mapping table.
    #
    # Hot-path cost: one `@hg_mutex` acquisition per tick. That's
    # acceptable for the audit metric: contention shows up only on
    # the `tick + render` overlap, never inside the C accept loop
    # (which uses its own atomic counter folded in at scrape time).
    # Worth the simplicity over an extra lock-free per-thread cache.
    REQUESTS_DISPATCH_TOTAL = :hyperion_requests_dispatch_total
    WORKER_ID_LABEL_KEYS = %w[worker_id].freeze

    def tick_worker_request(worker_id)
      label = worker_id.nil? || worker_id.to_s.empty? ? '0' : worker_id.to_s
      ensure_worker_request_family_registered!
      increment_labeled_counter(REQUESTS_DISPATCH_TOTAL, [label])
    end

    # 2.12-E — Idempotently register the labeled-counter family. Public
    # so `Server#run_c_accept_loop` can register at boot — the
    # PrometheusExporter's C-loop fold-in is gated on the family being
    # in the snapshot, and a 100% C-loop worker never goes through
    # `tick_worker_request` to register lazily.
    def ensure_worker_request_family_registered!
      return if @worker_request_family_registered

      register_labeled_counter(REQUESTS_DISPATCH_TOTAL, label_keys: WORKER_ID_LABEL_KEYS)
      @worker_request_family_registered = true
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
    #
    # 2.13-A — also clear per-thread histogram and labeled-counter
    # shards. Without this, an observation made on thread A in spec X
    # would leak into spec Y's snapshot because the shard hashes are
    # held alive by `@thread_histograms` / `@thread_labeled_counters`
    # for the lifetime of the Metrics instance.
    def reset!
      @counters_mutex.synchronize do
        @thread_counters.each(&:clear)
      end
      @hg_mutex.synchronize do
        @histograms.each_value(&:clear)
        @gauges.each_value(&:clear)
        @gauge_blocks.each_value(&:clear)
      end
      @hg_thread_mutex.synchronize do
        @thread_histograms.each(&:clear)
        @thread_labeled_counters.each(&:clear)
      end
    end

    # ---- 2.4-C histogram + gauge API ---------------------------------

    # Register a histogram family. Idempotent — re-registering with the
    # same buckets/label_keys is a no-op; mismatched re-register raises
    # so a typo surfaces at boot rather than corrupting the scrape output.
    def register_histogram(name, buckets:, label_keys: [])
      @hg_mutex.synchronize do
        if (existing = @histograms_meta[name])
          unless existing[:buckets] == buckets && existing[:label_keys] == label_keys
            raise ArgumentError,
                  "histogram #{name.inspect} re-registered with different shape " \
                  "(was buckets=#{existing[:buckets]} labels=#{existing[:label_keys]}; " \
                  "now buckets=#{buckets} labels=#{label_keys})"
          end

          return
        end
        @histograms_meta[name] = { buckets: buckets.dup.freeze, label_keys: label_keys.dup.freeze }
        @histograms[name]      = {}
      end
    end

    # Observe `value` on a previously-registered histogram. `label_values`
    # MUST be supplied in the same order as `label_keys` at registration.
    #
    # 2.13-A — Hot-path lock-free shard. Each thread keeps its own
    # `{ name => { labels => HistogramAccumulator } }` map; observations
    # never block on `@hg_mutex`. Snapshots merge across threads under
    # the mutex (low-rate). Allocation footprint per observe: zero on
    # the cached-key path; one frozen Array + one HistogramAccumulator
    # on first observation for a given (name, label-set, thread).
    #
    # Bench impact (generic Rack hello, -t 32 -c 100):
    # contention on `@hg_mutex` was the dominant tail latency
    # contributor — this fires once per request via the per-route
    # request-duration histogram, multiplied by N worker threads.
    def observe_histogram(name, value, label_values = EMPTY_LABELS)
      meta = @histograms_meta[name]
      return unless meta # silently skip unregistered observations

      thread = Thread.current
      shard = thread.thread_variable_get(@hg_thread_key)
      shard = register_thread_histograms(thread) if shard.nil?

      family = (shard[name] ||= {})
      accum  = family[label_values]
      unless accum
        accum = HistogramAccumulator.new(meta[:buckets])
        # Freeze the label tuple so future identical-content tuples
        # hash to the same bucket — but we keep the original ref
        # provided by the caller as the canonical key so subsequent
        # observes with the same Array bypass the freeze step.
        family[label_values.frozen? ? label_values : label_values.dup.freeze] = accum
      end
      accum.observe(value)
    end

    # Set a gauge value. `label_values` follows the same convention as
    # `observe_histogram`. Pass a block to register a callback that's
    # evaluated lazily at snapshot time (ThreadPool queue depth, etc.) —
    # the callback's return value is the gauge's current reading.
    def set_gauge(name, value = nil, label_values = EMPTY_LABELS, &block)
      @hg_mutex.synchronize do
        @gauges_meta[name] ||= { label_keys: [].freeze }
        if block
          (@gauge_blocks[name] ||= {})[label_values.frozen? ? label_values : label_values.dup.freeze] = block
        else
          (@gauges[name] ||= {})[label_values.frozen? ? label_values : label_values.dup.freeze] = value.to_f
        end
      end
    end

    # Increment a gauge by `delta` (default 1). Used for kTLS active
    # connections, etc. — paired with `decrement_gauge` on close.
    def increment_gauge(name, label_values = EMPTY_LABELS, delta = 1)
      @hg_mutex.synchronize do
        @gauges_meta[name] ||= { label_keys: [].freeze }
        family = (@gauges[name] ||= {})
        key    = label_values.frozen? ? label_values : label_values.dup.freeze
        family[key] = (family[key] || 0.0) + delta.to_f
      end
    end

    def decrement_gauge(name, label_values = EMPTY_LABELS, delta = 1)
      increment_gauge(name, label_values, -delta)
    end

    # Register that a histogram/gauge family exists with this label
    # ordering. The PrometheusExporter calls `histogram_meta` /
    # `gauge_meta` at scrape time to build the HELP/TYPE preamble.
    def histogram_meta(name)
      @hg_mutex.synchronize { @histograms_meta[name]&.dup }
    end

    def gauge_meta(name)
      @hg_mutex.synchronize { @gauges_meta[name]&.dup }
    end

    # Snapshot helpers — read-only views of the current histogram /
    # gauge state. The exporter uses these to render the scrape body.
    #
    # 2.13-A — Histograms merge across the per-thread shards on the
    # snapshot path. The mutex is held only long enough to copy the
    # shard list (every shard Hash is owned by one thread, so we can
    # iterate its current contents safely while merging — torn reads
    # of in-progress observations show as a slightly stale snapshot,
    # never as a corrupted Accumulator).
    def histogram_snapshot
      out = {}

      # Pre-seed names from registered families so a histogram with
      # zero observations still appears in the scrape (matches the
      # pre-2.13-A behaviour where `register_histogram` populated the
      # `@histograms[name] = {}` slot eagerly).
      @hg_mutex.synchronize do
        @histograms_meta.each_key { |name| out[name] = { meta: @histograms_meta[name], series: {} } }
      end

      shards = @hg_thread_mutex.synchronize { @thread_histograms.dup }
      shards.each do |shard|
        shard.each do |name, family|
          slot = (out[name] ||= { meta: @histograms_meta[name], series: {} })
          series = slot[:series]
          family.each do |labels, accum|
            existing = series[labels]
            if existing.nil?
              series[labels] = accum.snapshot
            else
              merge_histogram_snapshot!(existing, accum)
            end
          end
        end
      end

      out
    end

    def gauge_snapshot
      out = {}
      @hg_mutex.synchronize do
        names = (@gauges.keys + @gauge_blocks.keys).uniq
        names.each do |name|
          per_labels = {}
          @gauges[name]&.each { |labels, value| per_labels[labels] = value.to_f }
          @gauge_blocks[name]&.each do |labels, block|
            # Block-evaluated gauges read live state at scrape time. We
            # release the mutex around the block call to avoid holding
            # while user code runs, BUT we currently hold @hg_mutex —
            # the contract is that the block is short and side-effect-
            # free (e.g., reads ThreadPool#queue_size). That's the only
            # use case we wire today; document if extended.
            per_labels[labels] = block.call.to_f
          rescue StandardError
            # Snapshot must never raise — a misbehaving block degrades
            # to "no reading" rather than a 500 on /-/metrics.
            next
          end
          out[name] = { meta: @gauges_meta[name] || { label_keys: [].freeze }, series: per_labels }
        end
      end
      out
    end

    # Frozen empty Array used as the default label tuple. Reused across
    # all label-less observations so we don't allocate a fresh `[]` per
    # scrape — keeps hot-path work allocation-free for the un-labeled
    # gauge/histogram families.
    EMPTY_LABELS = [].freeze

    # Labeled counter — separate from the legacy thread-local counter
    # surface (which is unlabeled and per-thread for hot-path
    # contention-free increments).
    #
    # 2.13-A — moved to a per-thread shard for the same reason as
    # `observe_histogram`: the previous "low-rate paths" claim was wrong
    # (`tick_worker_request` is per-Rack-request), and at -t 32 the
    # single mutex serialised every worker thread on the request-
    # completion tail. Per-thread shards remove the contention;
    # `labeled_counter_snapshot` merges shards under the mutex.
    def increment_labeled_counter(name, label_values = EMPTY_LABELS, by = 1)
      thread = Thread.current
      shard = thread.thread_variable_get(@lc_thread_key)
      shard = register_thread_labeled_counters(thread) if shard.nil?

      # Defensive: ensure the family meta exists so `register_labeled_counter`
      # is not strictly required for hot-path increments. Pre-2.13-A the
      # mutex'd path lazily registered an unlabeled meta; we mirror that
      # under @hg_mutex so the shape stays consistent across threads.
      unless @labeled_counters_meta && @labeled_counters_meta[name]
        @hg_mutex.synchronize do
          @labeled_counters_meta ||= {}
          @labeled_counters_meta[name] ||= { label_keys: [].freeze }
        end
      end

      family = (shard[name] ||= {})
      key    = label_values.frozen? ? label_values : label_values.dup.freeze
      family[key] = (family[key] || 0) + by
    end

    def register_labeled_counter(name, label_keys: [])
      @hg_mutex.synchronize do
        @labeled_counters_meta ||= {}
        @labeled_counters_meta[name] = { label_keys: label_keys.dup.freeze }
        @labeled_counters ||= {}
        @labeled_counters[name] ||= {}
      end
    end

    # 2.13-A — Snapshot merges per-thread shards. Pre-seeded with
    # `@labeled_counters_meta` so registered-but-unticked families still
    # show up in the scrape (matches pre-2.13-A behaviour where
    # `register_labeled_counter` eagerly created the `[name] = {}` slot).
    def labeled_counter_snapshot
      out = {}
      @hg_mutex.synchronize do
        (@labeled_counters_meta || {}).each do |name, meta|
          out[name] = { meta: meta, series: {} }
        end
      end

      shards = @hg_thread_mutex.synchronize { @thread_labeled_counters.dup }
      shards.each do |shard|
        shard.each do |name, family|
          meta = (@labeled_counters_meta || {})[name] || { label_keys: [].freeze }
          slot = (out[name] ||= { meta: meta, series: {} })
          series = slot[:series]
          family.each do |labels, count|
            series[labels] = (series[labels] || 0) + count
          end
        end
      end
      out
    end

    # Per-(name, labels) histogram accumulator. Fixed-size Integer Array
    # of bucket counters + scalar sum/count. Cumulative bucket semantics
    # match Prometheus client convention: bucket[i] counts observations
    # whose value <= bucket_edges[i], and the implicit `+Inf` bucket is
    # `count` itself. The exporter writes the +Inf bucket as the total
    # count plus a `le="+Inf"` line per Prometheus text format.
    class HistogramAccumulator
      attr_reader :buckets, :counts, :sum, :count

      def initialize(buckets)
        @buckets = buckets.freeze
        @counts  = Array.new(buckets.size, 0)
        @sum     = 0.0
        @count   = 0
      end

      # Walk the buckets linearly. For 7 buckets (the default request-
      # duration set) this is faster than binary search; for any
      # reasonable bucket count (< 30) the constant factor wins. Mutex-
      # guarded by the caller (Metrics#observe_histogram).
      def observe(value)
        v = value.to_f
        @sum   += v
        @count += 1
        i = 0
        len = @buckets.length
        while i < len
          @counts[i] += 1 if v <= @buckets[i]
          i += 1
        end
      end

      def snapshot
        # Return a new struct so callers don't see a live, mutating ref.
        { buckets: @buckets, counts: @counts.dup, sum: @sum, count: @count }
      end
    end

    private

    def register_thread_counters(thread)
      counters = Hash.new(0)
      thread.thread_variable_set(@thread_key, counters)
      @counters_mutex.synchronize { @thread_counters << counters }
      counters
    end

    # 2.13-A — allocate this thread's histogram shard and register it
    # in `@thread_histograms` so snapshots find it. Idempotent per
    # thread: callers always check `thread_variable_get` first.
    def register_thread_histograms(thread)
      shard = {}
      thread.thread_variable_set(@hg_thread_key, shard)
      @hg_thread_mutex.synchronize { @thread_histograms << shard }
      shard
    end

    # 2.13-A — same shape as register_thread_histograms but for labeled
    # counters. Each thread gets its own `{ name => { labels => Integer } }`
    # map; the snapshot path merges across shards.
    def register_thread_labeled_counters(thread)
      shard = {}
      thread.thread_variable_set(@lc_thread_key, shard)
      @hg_thread_mutex.synchronize { @thread_labeled_counters << shard }
      shard
    end

    # 2.13-A — fold a per-thread HistogramAccumulator's contents into an
    # already-snapshotted entry (`{buckets:, counts:, sum:, count:}`).
    # Both arguments share the same `:buckets` so the bucket index axis
    # is identical; we sum `counts` per bucket plus the scalars. Used
    # when two threads observed the SAME (name, labels) pair — a
    # legitimate steady state on a Rack route hit by concurrent
    # workers.
    def merge_histogram_snapshot!(existing, accum)
      counts = existing[:counts]
      acc_counts = accum.counts
      i = 0
      len = counts.length
      while i < len
        counts[i] += acc_counts[i]
        i += 1
      end
      existing[:sum]   += accum.sum
      existing[:count] += accum.count
    end
  end
end

require_relative 'metrics/path_templater'
