# frozen_string_literal: true

module Hyperion
  # Thread pool for Rack dispatch. Has two modes:
  #
  # 1. `#submit_connection(socket, app)` — HTTP/1.1 path. The whole socket is
  #    handed to a worker thread, which runs `Connection#serve(socket, app)`
  #    directly with `thread_pool: nil` (the worker IS the pool). Zero
  #    per-request hop, one OS thread per in-flight connection — Puma's model.
  #
  # 2. `#call(app, request)` — old hop-based API. Used by Http2Handler, where
  #    each h2 stream runs on a fiber inside the connection fiber and DOES
  #    need the cross-thread hop for `app.call(env)`.
  #
  # Why we need this: synchronous Rack handlers (Rails dev-mode reloader,
  # ActiveRecord, many gems) hold global mutexes that serialize work across
  # fibers on a single thread. Fibers give us cheap connection counts but
  # cannot deliver true parallelism for blocking handlers. The thread pool
  # gives us Puma-style OS-thread concurrency for `app.call(env)` while the
  # accept loop stays on fibers.
  #
  # Cross-thread fiber wakeup (for the legacy `#call` path): on Ruby 3.2+ with
  # the Async fiber scheduler, `Queue#pop` is fiber-aware — the fiber yields
  # cooperatively while waiting on the queue. Verified experimentally on Ruby
  # 3.3.3.
  class ThreadPool
    SHUTDOWN = :__hyperion_thread_pool_shutdown__

    attr_reader :size, :max_pending

    def initialize(size:, max_pending: nil)
      @size        = size
      @max_pending = max_pending
      @inbox       = Queue.new # multiplexes both kinds of jobs
      # Pre-allocate one reply queue per in-flight slot for the legacy `#call`
      # path. Bounded by `size`: if all workers are busy, all reply queues are
      # checked out, and the next caller blocks on `@reply_pool.pop` until a
      # worker frees one. That's the correct backpressure shape.
      @reply_pool = Queue.new
      size.times { @reply_pool << Queue.new }
      @workers = Array.new(size) { spawn_worker }
    end

    # HTTP/1.1 path: hand the whole socket to a worker thread. The worker
    # runs `Connection#serve(socket, app)` directly. No per-request hop.
    # Returns immediately — caller does not wait.
    #
    # Returns true on enqueue, false on rejection. When `max_pending` is set
    # and the inbox already has at least that many entries, the connection
    # is rejected up to the caller (Server emits a 503 and closes the
    # socket). Without `max_pending` (default nil) the queue is unbounded
    # and we always return true — preserves pre-1.2 behaviour.
    #
    # The check is inherently racy with worker drain — workers may pop
    # between our `size` read and the `<<`. Backpressure is statistical,
    # not strict. Off-by-one over the configured cap during a thundering
    # accept burst is acceptable; the cost of stricter sync would be a
    # mutex on every enqueue, which we won't pay on the hot path.
    def submit_connection(socket, app, max_request_read_seconds: 60)
      return false if @max_pending && @inbox.size >= @max_pending

      @inbox << [:connection, socket, app, max_request_read_seconds]
      true
    end

    # HTTP/2 + sub-call path: hop one `app.call` from the calling fiber to a
    # worker thread. The fiber yields until the worker pushes the result back.
    #
    # Reply-queue lifecycle invariant: `@reply_pool` always contains queues
    # that are empty. We check one out, hand it to the worker, the worker
    # pushes exactly one result, we pop it, then return the queue to the
    # pool. If `app.call` raises, the worker still pushes a 500 result — see
    # `spawn_worker`.
    def call(app, request)
      reply = @reply_pool.pop
      @inbox << [:call, app, request, reply]
      result = reply.pop
      @reply_pool << reply
      result
    end

    def shutdown
      @size.times { @inbox << SHUTDOWN }
      @workers.each { |t| t.join(5) }
    end

    private

    def spawn_worker
      Thread.new do
        loop do
          job = @inbox.pop
          break if job.equal?(SHUTDOWN)

          case job[0]
          when :connection
            _, socket, app, max_request_read_seconds = job
            # Worker thread owns the connection for its full lifetime. Pass
            # thread_pool: nil so Connection#call_app inlines Adapter::Rack.call
            # — the worker IS the pool, no further hop required.
            begin
              Hyperion::Connection.new.serve(socket, app, max_request_read_seconds: max_request_read_seconds)
            rescue StandardError => e
              Hyperion.logger.error do
                {
                  message: 'thread pool worker connection raised',
                  error: e.message,
                  error_class: e.class.name
                }
              end
            end
          when :call
            _, app, request, reply = job
            reply <<
              begin
                Hyperion::Adapter::Rack.call(app, request)
              rescue StandardError => e
                Hyperion.logger.error do
                  { message: 'thread pool worker raised', error: e.message, error_class: e.class.name }
                end
                [500, { 'content-type' => 'text/plain' }, ['Internal Server Error']]
              end
          end
        end
      rescue StandardError => e
        Hyperion.logger.error do
          { message: 'thread pool worker died', error: e.message, error_class: e.class.name }
        end
      end
    end
  end
end
