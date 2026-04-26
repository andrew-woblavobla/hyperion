# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Hyperion::ThreadPool do
  describe '#submit_connection backpressure' do
    # The blocked-worker pattern leaves dangling sockets that the test
    # closes during teardown — Connection#serve emits the resulting
    # "closed stream" / "Bad file descriptor" lines as noise. We don't
    # care about those here (this spec exercises the queue, not the
    # connection lifecycle), so silence the error logger for the duration.
    before do
      @prev_logger = Hyperion.logger
      Hyperion.logger = Hyperion::Logger.new(level: :fatal)
    end

    after { Hyperion.logger = @prev_logger }

    # Helper: build a real socket pair so submit_connection can hand a
    # genuine IO to the worker without contriving a stub. We close the
    # writer end immediately so the worker's read returns 0 bytes and
    # serve() exits cleanly without dispatching to any app.
    def fresh_socket_pair
      ::Socket.pair(:UNIX, :STREAM)
    end

    it 'returns true for the first N submissions and false once the inbox is full' do
      # Block all worker threads so the inbox actually grows. Each worker
      # waits on `block_pop.pop` — they'll never drain until we push.
      block_pop = Queue.new
      pool = described_class.new(size: 1, max_pending: 2)
      blocked_app = lambda { |_env|
        block_pop.pop
        [200, {}, []]
      }

      a1, b1 = fresh_socket_pair
      a2, b2 = fresh_socket_pair
      a3, b3 = fresh_socket_pair
      a4, b4 = fresh_socket_pair

      # First socket goes to the (only) worker thread immediately, so the
      # inbox never sees it. Subsequent submits queue up behind it.
      expect(pool.submit_connection(b1, blocked_app)).to be(true)

      # Give the worker a moment to pop the first job before measuring.
      sleep 0.05

      expect(pool.submit_connection(b2, blocked_app)).to be(true)  # inbox: 1
      expect(pool.submit_connection(b3, blocked_app)).to be(true)  # inbox: 2 — at cap
      expect(pool.submit_connection(b4, blocked_app)).to be(false) # rejected
    ensure
      # Unblock workers so #shutdown can join them.
      10.times { block_pop << :go }
      [a1, a2, a3, a4, b1, b2, b3, b4].each { |s| s&.close }
      pool&.shutdown
    end

    it 'returns true unconditionally when max_pending is nil (default)' do
      # No backpressure — preserves pre-1.2 behaviour. Even with all
      # workers blocked, every accept must succeed.
      block_pop = Queue.new
      pool = described_class.new(size: 1) # max_pending omitted
      blocked_app = lambda { |_env|
        block_pop.pop
        [200, {}, []]
      }

      sockets = Array.new(10) { fresh_socket_pair }
      results = sockets.map { |(_, b)| pool.submit_connection(b, blocked_app) }

      expect(results).to all(be(true))
    ensure
      10.times { block_pop << :go }
      sockets&.each do |(a, b)|
        a.close
        b.close
      end
      pool&.shutdown
    end

    it 'accepts new connections again after the queue drains below the cap' do
      # Saturate the queue, then unblock workers and confirm subsequent
      # submits succeed once the inbox has drained.
      block_pop = Queue.new
      pool = described_class.new(size: 1, max_pending: 2)
      blocked_app = lambda { |_env|
        block_pop.pop
        [200, {}, []]
      }

      sockets = []
      4.times do
        a, b = fresh_socket_pair
        sockets << a << b
        pool.submit_connection(b, blocked_app)
      end

      # Now the inbox should be at 2 (one in-flight + 2 pending; the 4th
      # was rejected). Drain everything.
      10.times { block_pop << :go }

      # Wait briefly for workers to clear the inbox.
      deadline = Time.now + 2
      sleep 0.01 until pool.instance_variable_get(:@inbox).size.zero? || Time.now > deadline

      a, b = fresh_socket_pair
      sockets << a << b
      expect(pool.submit_connection(b, blocked_app)).to be(true)
    ensure
      10.times { block_pop << :go }
      sockets&.each(&:close)
      pool&.shutdown
    end
  end
end
