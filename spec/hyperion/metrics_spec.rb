# frozen_string_literal: true

RSpec.describe Hyperion::Metrics do
  subject(:metrics) { described_class.new }

  it 'tracks counter increments' do
    metrics.increment(:requests_total)
    metrics.increment(:requests_total, 4)
    expect(metrics.snapshot[:requests_total]).to eq(5)
  end

  it 'tracks decrements' do
    metrics.increment(:in_flight, 3)
    metrics.decrement(:in_flight)
    expect(metrics.snapshot[:in_flight]).to eq(2)
  end

  it 'tracks per-status response counts' do
    metrics.increment_status(200)
    metrics.increment_status(200)
    metrics.increment_status(404)
    snap = metrics.snapshot
    expect(snap[:responses_200]).to eq(2)
    expect(snap[:responses_404]).to eq(1)
  end

  describe 'cross-fiber aggregation' do
    # The bug we're guarding against: pre-fix increments used
    # `Thread.current[:key]` which is FIBER-local in Ruby 1.9+, so a
    # fiber that increments on Thread A puts the counter in its private
    # slot, and `snapshot` (called from a different fiber, even on the
    # same thread) walks @threads but reads the OWNING-thread's root-
    # fiber slot — which is empty. Increments are stranded.
    #
    # Fix: thread_variable_get/set is truly thread-local, shared across
    # all fibers on a given OS thread.

    it 'aggregates increments from a non-root fiber on the same thread' do
      Fiber.new { metrics.increment(:from_fiber, 7) }.resume
      expect(metrics.snapshot[:from_fiber]).to eq(7)
    end

    it 'aggregates increments from a different OS thread' do
      done = Queue.new
      t = Thread.new do
        metrics.increment(:from_thread, 11)
        done << :ready
      end
      done.pop
      t.join
      expect(metrics.snapshot[:from_thread]).to eq(11)
    end

    it 'aggregates increments from a non-root fiber on a different thread' do
      done = Queue.new
      t = Thread.new do
        Fiber.new { metrics.increment(:from_other_fiber, 3) }.resume
        done << :ready
      end
      done.pop
      t.join
      expect(metrics.snapshot[:from_other_fiber]).to eq(3)
    end

    it 'aggregates increments from many fibers on the same thread' do
      fibers = 20.times.map do |i|
        Fiber.new { metrics.increment(:hits, i + 1) }
      end
      fibers.each(&:resume)
      # 1 + 2 + ... + 20 = 210
      expect(metrics.snapshot[:hits]).to eq(210)
    end
  end

  # 2.13-A — per-thread shard for hot-path histogram + labeled-counter
  # observations. Pre-2.13-A every observe took @hg_mutex; with `-t 32`
  # that single mutex serialised 32 worker threads on the request-
  # completion tail. The new path keeps a per-thread shard and merges
  # at snapshot time. These specs assert the merge stays correct under
  # concurrency AND that the snapshot still surfaces registered-but-
  # never-observed families (the pre-seed contract).
  describe 'per-thread shard aggregation (2.13-A)' do
    it 'aggregates histogram observations from many threads under one (name, labels)' do
      metrics.register_histogram(:lat, buckets: [0.001, 0.01, 0.1, 1.0], label_keys: %w[route])
      threads = 8.times.map do
        Thread.new do
          1000.times { metrics.observe_histogram(:lat, 0.005, %w[/]) }
        end
      end
      threads.each(&:join)

      snap = metrics.histogram_snapshot
      lat = snap.fetch(:lat)
      series = lat.fetch(:series)
      key = series.keys.find { |k| k == %w[/] }
      data = series.fetch(key)
      expect(data[:count]).to eq(8 * 1000)
      # 0.005 falls into bucket index 1 (0.01) and beyond — verify
      # cumulative bucket convention is preserved across the merge.
      expect(data[:counts][0]).to eq(0)
      expect(data[:counts][1]).to eq(8 * 1000)
      expect(data[:counts][2]).to eq(8 * 1000)
      expect(data[:counts][3]).to eq(8 * 1000)
      expect(data[:sum]).to be_within(0.0001).of(0.005 * 8 * 1000)
    end

    it 'aggregates labeled-counter increments from many threads' do
      metrics.register_labeled_counter(:hits_total, label_keys: %w[worker_id])
      threads = 16.times.map do |tidx|
        Thread.new do
          500.times { metrics.increment_labeled_counter(:hits_total, [tidx.to_s]) }
        end
      end
      threads.each(&:join)

      snap = metrics.labeled_counter_snapshot
      hits = snap.fetch(:hits_total)
      series = hits.fetch(:series)
      expect(series.size).to eq(16)
      series.each_value { |count| expect(count).to eq(500) }
    end

    it 'still surfaces registered-but-never-observed histograms in the snapshot' do
      metrics.register_histogram(:never_observed, buckets: [0.1, 1.0])
      snap = metrics.histogram_snapshot
      expect(snap).to have_key(:never_observed)
      expect(snap[:never_observed][:series]).to eq({})
    end

    it 'still surfaces registered-but-never-observed labeled counters in the snapshot' do
      metrics.register_labeled_counter(:never_ticked, label_keys: %w[a])
      snap = metrics.labeled_counter_snapshot
      expect(snap).to have_key(:never_ticked)
      expect(snap[:never_ticked][:series]).to eq({})
    end

    it 'reset! clears per-thread shards across threads' do
      metrics.register_histogram(:reset_check, buckets: [0.1])
      Thread.new { metrics.observe_histogram(:reset_check, 0.05) }.join
      expect(metrics.histogram_snapshot.dig(:reset_check, :series).values.first[:count]).to eq(1)

      metrics.reset!
      snap = metrics.histogram_snapshot
      expect(snap[:reset_check][:series]).to eq({})
    end

    it 'observe_histogram on an unregistered family is a silent no-op' do
      expect { metrics.observe_histogram(:not_registered, 0.1) }.not_to raise_error
      expect(metrics.histogram_snapshot[:not_registered]).to be_nil
    end

    # Concurrency / contention sanity check: the entire point of the
    # per-thread shard refactor was that observe_histogram / increment_
    # labeled_counter are CALLED at request-completion frequency from
    # every Connection-serving thread, and the previous mutex made
    # them serialize. We're not measuring time here (CI variance), just
    # asserting that high-concurrency mixed observations + snapshots
    # don't deadlock and the final counts add up.
    it 'allows concurrent observe + snapshot without deadlock or torn counts' do
      metrics.register_histogram(:race_lat, buckets: [0.1])
      metrics.register_labeled_counter(:race_hits, label_keys: %w[t])
      observers = 8.times.map do |tidx|
        Thread.new do
          1000.times do
            metrics.observe_histogram(:race_lat, 0.05)
            metrics.increment_labeled_counter(:race_hits, [tidx.to_s])
          end
        end
      end
      # While observers run, take 50 snapshots to exercise the merge
      # path's mutex sections under live writers.
      50.times do
        metrics.histogram_snapshot
        metrics.labeled_counter_snapshot
      end
      observers.each(&:join)
      stop = true
      _ = stop

      hist = metrics.histogram_snapshot[:race_lat][:series].values.first
      expect(hist[:count]).to eq(8 * 1000)

      hits = metrics.labeled_counter_snapshot[:race_hits][:series]
      expect(hits.size).to eq(8)
      hits.each_value { |c| expect(c).to eq(1000) }
    end
  end
end
