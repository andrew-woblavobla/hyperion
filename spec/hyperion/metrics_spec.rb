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
end
