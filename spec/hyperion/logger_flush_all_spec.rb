# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Hyperion::Logger do
  describe '#flush_all' do
    subject(:logger) { described_class.new(io: io, level: :info, format: :text) }

    let(:io) { StringIO.new }

    # Spawn a worker thread that allocates a per-thread access buffer via
    # Logger#access, then parks on a Queue so the main thread can call
    # #flush_all while the worker (and its thread-local buffer) is still
    # alive. Pushing :stop releases the worker.
    def spawn_writer(call_count: 1)
      ready = Queue.new
      release = Queue.new

      thread = Thread.new do
        call_count.times do |i|
          logger.access('GET', "/path/#{i}", nil, 200, 1, '127.0.0.1', '1.1')
        end
        ready.push(:ready)
        release.pop
      end

      ready.pop
      [thread, release]
    end

    it 'walks per-thread buffers from a third thread and clears them' do
      t1, r1 = spawn_writer(call_count: 1)
      t2, r2 = spawn_writer(call_count: 1)

      # Both worker buffers hold content but neither hit the 4 KiB flush
      # threshold, so io is empty until flush_all runs.
      expect(io.string).to be_empty

      logger.flush_all

      output = io.string
      expect(output).to include('path=/path/0')
      # Two threads each wrote one access line; output contains both.
      expect(output.scan(/message=request/).size).to eq(2)

      r1.push(:stop)
      r2.push(:stop)
      t1.join
      t2.join
    end

    it 'is idempotent — second call is a no-op after buffers are drained' do
      thread, release = spawn_writer(call_count: 1)

      logger.flush_all
      first_output = io.string.dup
      expect(first_output).to include('message=request')

      logger.flush_all
      expect(io.string).to eq(first_output)

      release.push(:stop)
      thread.join
    end

    it 'does not raise even when @out.flush raises' do
      flaky_io = StringIO.new
      def flaky_io.flush
        raise IOError, 'closed stream'
      end

      flaky_logger = described_class.new(io: flaky_io, level: :info, format: :text)
      thread, release = spawn_writer_for(flaky_logger, call_count: 1)

      expect { flaky_logger.flush_all }.not_to raise_error
      expect(flaky_io.string).to include('message=request')

      release.push(:stop)
      thread.join
    end

    it 'flushes the calling thread\'s own buffer' do
      logger.access('GET', '/single', nil, 200, 1, '127.0.0.1', '1.1')
      expect(io.string).to be_empty

      logger.flush_all

      expect(io.string).to include('path=/single')

      # Idempotent: second call is a no-op (buffer is now empty).
      logger.flush_all
      expect(io.string.scan(%r{path=/single}).size).to eq(1)
    end

    # Helper variant for the flaky-IO case — must spawn the writer against
    # a different logger instance than the main `subject(:logger)`.
    def spawn_writer_for(target_logger, call_count: 1)
      ready = Queue.new
      release = Queue.new

      thread = Thread.new do
        call_count.times do |i|
          target_logger.access('GET', "/flaky/#{i}", nil, 200, 1, '127.0.0.1', '1.1')
        end
        ready.push(:ready)
        release.pop
      end

      ready.pop
      [thread, release]
    end
  end
end
