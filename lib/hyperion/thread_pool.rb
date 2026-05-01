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

    def initialize(size:, max_pending: nil, max_in_flight_per_conn: nil, route_table: nil)
      @size        = size
      @max_pending = max_pending
      # 2.3-B: per-conn fairness cap propagated to every Connection
      # constructed by `:connection` jobs. nil (default) = no cap,
      # matches 2.2.0. Positive integer = per-conn ceiling.
      @max_in_flight_per_conn = max_in_flight_per_conn
      # 2.10-D — direct-dispatch route table propagated to every
      # Connection constructed by `:connection` jobs.  nil falls
      # through to `Hyperion::Server.route_table` (the process-wide
      # singleton); a non-nil instance is honoured verbatim (test
      # / multi-tenant seam).
      @route_table = route_table
      @inbox = Queue.new # multiplexes both kinds of jobs
      # Pre-allocate one reply queue per in-flight slot for the legacy `#call`
      # path. Bounded by `size`: if all workers are busy, all reply queues are
      # checked out, and the next caller blocks on `@reply_pool.pop` until a
      # worker frees one. That's the correct backpressure shape.
      @reply_pool = Queue.new
      size.times { @reply_pool << Queue.new }
      @workers = Array.new(size) { spawn_worker }
      # 2.4-C: snapshot-time gauge — operator scrape sees the live
      # inbox depth as of /-/metrics scrape, not a stale-since-init
      # number. The block reads `Queue#size` (cheap, lock-free) so the
      # scrape path doesn't perturb the running pool.
      register_queue_depth_gauge!
    end

    THREADPOOL_QUEUE_DEPTH_GAUGE = :hyperion_threadpool_queue_depth

    def queue_size
      @inbox.size
    end

    def register_queue_depth_gauge!
      Hyperion.metrics.set_gauge(THREADPOOL_QUEUE_DEPTH_GAUGE,
                                 nil,
                                 [Process.pid.to_s]) { @inbox.size }
    rescue StandardError
      nil
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
    def submit_connection(socket, app, max_request_read_seconds: 60, carry: nil)
      return false if @max_pending && @inbox.size >= @max_pending

      # 2.12-E — `carry:` carries any partial header bytes the C accept
      # loop already read off the fd before deciding to hand the
      # connection off to Ruby. The worker thread pre-loads them into
      # `Connection#@inbuf` so the parser sees the full request, not a
      # short read that times out. Pre-2.12-E the threadpool handoff
      # path silently dropped the partial buffer (the inline-no-pool
      # path was the only one wired) — a server with `-t N>0` and the
      # C accept loop engaged returned "Request Timeout" on every
      # handed-off request, including the audit harness's own
      # `/-/metrics` scrape.
      @inbox << [:connection, socket, app, max_request_read_seconds, carry]
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
      @inbox << [:call, app, request, reply, nil]
      result = reply.pop
      @reply_pool << reply
      result
    end

    # 2.1.0 (WS-1) — same as #call, but threads a `Hyperion::Connection`
    # through to `Adapter::Rack.call(app, request, connection:)` so the
    # Rack env hash advertises full-hijack support. The worker pushes the
    # standard [status, headers, body] tuple back; if the app called
    # `env['rack.hijack'].call`, the connection's `@hijacked` ivar was
    # flipped from inside the worker thread and the calling fiber will
    # observe it on return (Ruby ivars are visible across the GVL boundary
    # for plain assignments — no Mutex/atomic needed).
    def call_with_connection(app, request, connection)
      reply = @reply_pool.pop
      @inbox << [:call, app, request, reply, connection]
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
            _, socket, app, max_request_read_seconds, carry = job
            # Worker thread owns the connection for its full lifetime. Pass
            # thread_pool: nil so Connection#call_app inlines Adapter::Rack.call
            # — the worker IS the pool, no further hop required. 2.3-B
            # threads `max_in_flight_per_conn` so the per-conn fairness
            # cap (if configured) takes effect on this worker's serve loop.
            begin
              connection = Hyperion::Connection
                           .new(max_in_flight_per_conn: @max_in_flight_per_conn,
                                route_table: @route_table)
              # 2.12-E — preload `@inbuf` with the partial buffer the C
              # accept loop already drained off the fd, mirroring the
              # inline-no-pool branch in `Server#dispatch_handed_off`.
              # `carry` is nil on the regular accept path; only the C
              # loop's handoff path supplies it.
              connection.instance_variable_set(:@inbuf, +carry.b) if carry.is_a?(String) && !carry.empty?
              connection.serve(socket, app, max_request_read_seconds: max_request_read_seconds)
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
            _, app, request, reply, connection = job
            reply <<
              begin
                if connection
                  Hyperion::Adapter::Rack.call(app, request, connection: connection)
                else
                  Hyperion::Adapter::Rack.call(app, request)
                end
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
