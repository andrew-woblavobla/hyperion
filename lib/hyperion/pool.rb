# frozen_string_literal: true

module Hyperion
  # Single-thread object pool with a maximum size.
  # Acquire returns an existing object (mutated for reuse) or constructs a new one.
  # Release returns the object to the pool unless the pool is full.
  #
  # Not thread-safe. Each Hyperion worker process runs one fiber scheduler on
  # one thread, so a per-process pool is contention-free.
  class Pool
    def initialize(max_size:, factory:, reset: nil)
      @max_size = max_size
      @factory  = factory
      @reset    = reset
      @free     = []
    end

    def acquire
      obj = @free.pop || @factory.call
      @reset&.call(obj)
      obj
    end

    def release(obj)
      return if @free.size >= @max_size

      @free.push(obj)
    end

    def size # rubocop:disable Rails/Delegate
      @free.size
    end
  end
end
