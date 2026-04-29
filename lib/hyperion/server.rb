# frozen_string_literal: true

require 'socket'
require 'openssl'
require 'async'
require 'async/scheduler'

module Hyperion
  # Phase 2a server: bind a TCPServer, accept connections, schedule each on its
  # own fiber via Async. Multiple in-flight requests run concurrently on a
  # single OS thread. Keep-alive is still off — connection closes after one
  # request (Phase 2b will add keep-alive).
  #
  # Phase 7 (scoped): when `tls:` is supplied, wrap the listener in an
  # OpenSSL::SSL::SSLServer with ALPN advertising `h2` + `http/1.1`. After
  # the handshake, dispatch on the negotiated protocol — http/1.1 goes
  # through Connection (real path); h2 goes to Http2Handler (505 stub
  # until Phase 8).
  class Server
    DEFAULT_READ_TIMEOUT_SECONDS = 30
    DEFAULT_THREAD_COUNT         = 5

    # Pre-built minimal 503 response for the backpressure path. We bypass
    # ResponseWriter / Rack entirely — no env build, no app dispatch, no
    # access-log line. The bytes are frozen and reused across every
    # rejection so the overload path stays allocation-free. Body is JSON
    # so JSON-only API consumers don't have to special-case the format.
    REJECT_503 = lambda {
      body = +%({"error":"server_busy","retry_after_seconds":1}\n)
      body.force_encoding(Encoding::ASCII_8BIT)
      head = +"HTTP/1.1 503 Service Unavailable\r\n" \
              "content-type: application/json\r\n" \
              "content-length: #{body.bytesize}\r\n" \
              "retry-after: 1\r\n" \
              "connection: close\r\n" \
              "\r\n"
      head.force_encoding(Encoding::ASCII_8BIT)
      (head + body).freeze
    }.call

    attr_reader :host, :port, :runtime

    # 1.7.0 added kwargs (all default to current behaviour):
    #   * `runtime:`             — `Hyperion::Runtime` instance (default
    #                               `Runtime.default`). Threaded through to
    #                               every per-connection / per-stream code
    #                               path so per-server metrics/logger
    #                               isolation works.
    #   * `accept_fibers_per_worker:` — Integer, default 1. When > 1 and the
    #                               accept loop is async-wrapped, spawn N
    #                               accept fibers that race on the same
    #                               listening fd. Linear scaling on
    #                               `:reuseport` (Linux); Darwin honours the
    #                               knob silently with no scaling benefit
    #                               (RFC §5 Q5).
    #   * `h2_max_total_streams:` — Integer or nil (default nil). Process-
    #                               wide cap on simultaneously-open h2
    #                               streams across all connections. nil
    #                               disables (current behaviour); set to
    #                               opt into RFC A7 admission control.
    #   * `admin_listener_port:`  — Integer or nil (default nil). When set,
    #                               spawn a sibling HTTP listener on
    #                               `127.0.0.1:<port>` that serves only
    #                               `/-/quit` and `/-/metrics`. nil keeps
    #                               admin mounted in-app (current shape).
    def initialize(app:, host: '127.0.0.1', port: 9292, read_timeout: DEFAULT_READ_TIMEOUT_SECONDS,
                   tls: nil, thread_count: DEFAULT_THREAD_COUNT, max_pending: nil,
                   max_request_read_seconds: 60, h2_settings: nil, async_io: nil,
                   runtime: nil, accept_fibers_per_worker: 1,
                   h2_max_total_streams: nil, admin_listener_port: nil,
                   admin_listener_host: '127.0.0.1', admin_token: nil)
      validate_async_io!(async_io)
      @host                     = host
      @port                     = port
      @app                      = app
      @read_timeout             = read_timeout
      @tls                      = tls
      @thread_count             = thread_count
      @max_pending              = max_pending
      @max_request_read_seconds = max_request_read_seconds
      @h2_settings              = h2_settings
      @async_io                 = async_io
      # `@explicit_runtime` toggles between 1.7.0 isolation (an
      # explicitly-passed Runtime) and 1.6.x compat (legacy module-level
      # accessors honoured for stub seams). All record_dispatch /
      # reject_connection / log lines route through `runtime_metrics` /
      # `runtime_logger` helpers below.
      @runtime                  = runtime || Hyperion::Runtime.default
      @explicit_runtime         = !runtime.nil?
      @accept_fibers_per_worker = [accept_fibers_per_worker.to_i, 1].max
      @h2_admission             = if h2_max_total_streams
                                    Hyperion::H2Admission.new(max_total_streams: h2_max_total_streams)
                                  end
      @admin_listener_port      = admin_listener_port
      @admin_listener_host      = admin_listener_host
      @admin_token              = admin_token
      @admin_listener           = nil
      @thread_pool              = nil
      @stopped                  = false
    end

    # Strict validation of the tri-state `async_io` flag (RFC A9). Pre-1.7
    # the Server constructor accepted any object; `1`, `:yes`, `'true'`
    # silently landed in the wrong matrix cell. Now: raise immediately so
    # the operator's typo surfaces at boot, not as a "why is my fiber-pg
    # config not behaving" report three hours later.
    def validate_async_io!(value)
      return if value.nil? || value == true || value == false

      raise ArgumentError, "async_io must be nil, true, or false (got #{value.inspect})"
    end
    private :validate_async_io!

    def listen
      tcp = ::TCPServer.new(@host, @port)
      @port = tcp.addr[1]

      if @tls
        @ssl_ctx = TLS.context(cert: @tls[:cert], key: @tls[:key], chain: @tls[:chain])
        ssl_server = ::OpenSSL::SSL::SSLServer.new(tcp, @ssl_ctx)
        ssl_server.start_immediately = false
        @server = ssl_server
        @tcp_server = tcp
      else
        @server = tcp
        @tcp_server = tcp
      end
      self
    end

    # Phase 3: workers pass in a pre-bound, SO_REUSEPORT-set socket built
    # by Hyperion::Worker. Bypasses #listen but keeps the rest of the
    # accept loop intact since Socket and TCPServer both quack #accept_nonblock.
    #
    # Phase 8: when `tls:` was supplied to the constructor, also build the
    # SSL context here so the accept loop can wrap incoming connections.
    # Each worker builds its own context — they don't share state.
    def adopt_listener(sock)
      @server = sock
      @tcp_server = sock
      @port = case sock
              when ::TCPServer
                sock.addr[1]
              else
                sock.local_address.ip_port
              end
      @ssl_ctx = TLS.context(cert: @tls[:cert], key: @tls[:key], chain: @tls[:chain]) if @tls
      self
    end

    def run_one
      Async do
        socket = blocking_accept
        next unless socket

        apply_timeout(socket)
        dispatch(socket)
      end.wait
    end

    def start
      listen unless @server
      @thread_pool = ThreadPool.new(size: @thread_count, max_pending: @max_pending) if @thread_count.positive?
      maybe_start_admin_listener

      if @tls || @async_io
        # TLS path: ALPN may pick `h2`, and h2 spawns one fiber per stream
        # inside Http2Handler. Keep the Async wrapper so the scheduler is
        # available for those fibers and for handshake yields. Plain
        # HTTP/1.1-over-TLS dispatch is also handled inline on the calling
        # fiber by default in 1.4.0+ (see #dispatch) — fiber-cooperative
        # libraries (async-pg, async-redis) work without --async-io.
        #
        # async_io: true: operator opt-in for plain HTTP/1.1. The Async wrap
        # is required when callers want fiber cooperative I/O — e.g.
        # `hyperion-async-pg` yielding while a Postgres query is in flight.
        # Pays ~5% throughput vs the raw-loop fast path; in exchange one
        # OS thread can serve N concurrent in-flight DB queries instead of 1.
        start_async_loop
      else
        # Plain HTTP/1.1, async_io: nil (default with no TLS) or
        # async_io: false (explicit opt-out): the worker thread owns each
        # connection for its lifetime, so the Async wrapper adds zero value
        # (no fibers ever run on this loop's task). Skip it — pure
        # IO.select + accept_nonblock shaves measurable overhead off the
        # accept hot path.
        start_raw_loop
      end
    ensure
      @thread_pool&.shutdown
      @admin_listener&.stop
    end

    def stop
      @stopped = true
      @server&.close
      @server = nil
      @tcp_server = nil
    end

    private

    # Plain HTTP/1.1 accept loop — no fiber wrap. Connections go straight to
    # a worker via the thread pool, or are served inline when no pool is
    # configured (thread_count: 0). Matches the dispatch contract used by
    # the TLS path; just skips the irrelevant h2/ALPN branch.
    def start_raw_loop
      until @stopped
        socket = accept_or_nil
        next unless socket

        apply_timeout(socket)
        if @thread_pool
          mode = DispatchMode.new(:threadpool_h1)
          if @thread_pool.submit_connection(socket, @app,
                                            max_request_read_seconds: @max_request_read_seconds)
            record_dispatch(mode)
          else
            reject_connection(socket)
          end
        else
          # `-t 0` plain HTTP/1.1 — no pool, serve inline on the accept
          # thread. RFC §5 Q3: `--async-io -t 0` keeps working — see
          # start_async_loop's `inline_h1_no_pool` branch.
          mode = DispatchMode.new(:inline_h1_no_pool)
          record_dispatch(mode)
          Connection.new(runtime: @explicit_runtime ? @runtime : nil).serve(
            socket, @app, max_request_read_seconds: @max_request_read_seconds
          )
        end
      end
    end

    # TLS / h2-capable accept loop. The Async wrapper is required because
    # h2 streams (inside Http2Handler) and the ALPN handshake yield
    # cooperatively via the scheduler.
    #
    # 1.7.0 (RFC A6): `accept_fibers_per_worker > 1` spawns N accept
    # fibers that each `IO.select` on the same listening fd. On `:reuseport`
    # workers (Linux) the kernel hashes connections fairly across siblings;
    # on `:share` (Darwin) the knob is silently honoured but shows no
    # scaling benefit — operators already know Darwin is special.
    def start_async_loop
      Async do |task|
        n = @accept_fibers_per_worker
        n.times { task.async { run_accept_fiber(task) } }
        # `task.children.each(&:wait)` would deadlock if no children — n is
        # always >= 1, so we're safe; but use rescue-wait pattern in case
        # one accept fiber raises.
        task.children.each do |child|
          child.wait
        rescue StandardError
          nil
        end
      end
    end

    # Single accept fiber's run loop. Called N times (default 1) from
    # `start_async_loop`. All accept fibers share `@server` / `@tcp_server`
    # via closure; the kernel arbitrates which fiber wins each
    # IO.select / accept_nonblock race.
    def run_accept_fiber(task)
      until @stopped
        socket = accept_or_nil
        next unless socket

        apply_timeout(socket)
        task.async { dispatch(socket) }
      end
    end

    def dispatch(socket)
      alpn = socket.is_a?(::OpenSSL::SSL::SSLSocket) ? socket.alpn_protocol : nil
      mode = DispatchMode.resolve(tls: !@tls.nil?, async_io: @async_io,
                                  thread_count: @thread_count, alpn: alpn)
      case mode.name
      when :tls_h2
        # HTTP/2: each stream runs on a fiber inside Http2Handler. Per-
        # stream counters live there. We bump the per-mode counter
        # (`:requests_dispatch_tls_h2`) at connection-accept time so
        # operators see the connection's chosen transport even when the
        # h2 streams happen on later fibers.
        record_dispatch(mode)
        Http2Handler.new(app: @app, thread_pool: @thread_pool,
                         h2_settings: @h2_settings,
                         runtime: @explicit_runtime ? @runtime : nil,
                         h2_admission: @h2_admission).serve(socket)
      when :tls_h1_inline, :async_io_h1_inline
        # Inline-on-fiber HTTP/1.1 dispatch. Two ways to land here:
        #   1. async_io: true — operator explicitly opted into fiber I/O on
        #      the plain HTTP/1.1 path.
        #   2. async_io: nil (default) AND TLS configured — TLS already
        #      runs the Async accept loop for ALPN handshake + h2 streams,
        #      so the scheduler is current on this fiber. Handing the
        #      socket to a worker thread would strip the scheduler context
        #      for no perf benefit (we paid the Async-loop cost already)
        #      and would defeat hyperion-async-pg / async-redis on the
        #      TLS h1 path.
        record_dispatch(mode)
        Connection.new(runtime: @explicit_runtime ? @runtime : nil).serve(
          socket, @app, max_request_read_seconds: @max_request_read_seconds
        )
      when :threadpool_h1
        # HTTP/1.1 default plain-HTTP path, OR explicit async_io: false on
        # TLS (operator opted out of inline-on-fiber dispatch). Hand the
        # connection to a worker thread; the fiber that called dispatch
        # returns immediately. On overflow, reject with 503 + close.
        if @thread_pool
          if @thread_pool.submit_connection(socket, @app,
                                            max_request_read_seconds: @max_request_read_seconds)
            record_dispatch(mode)
          else
            reject_connection(socket)
          end
        else
          # `run_one` / spec entry points dispatch without having
          # started the pool — serve inline and count under
          # threadpool_h1 (the connection's logical mode).
          record_dispatch(mode)
          Connection.new(runtime: @explicit_runtime ? @runtime : nil).serve(
            socket, @app, max_request_read_seconds: @max_request_read_seconds
          )
        end
      when :inline_h1_no_pool
        # `-t 0` on the TLS / async-wrap path. Rare config — debug /
        # spec aid (RFC §5 Q3 keeps `--async-io -t 0` valid). Counted
        # under its own bucket now (pre-1.7 it was un-counted).
        record_dispatch(mode)
        Connection.new(runtime: @explicit_runtime ? @runtime : nil).serve(
          socket, @app, max_request_read_seconds: @max_request_read_seconds
        )
      end
    end

    # Resolve the metrics sink for write-side ops. When the operator
    # passed an explicit `runtime:` we honour it; otherwise we read
    # the module-level singleton (`Hyperion.metrics`) so 1.6.x test
    # stubs (`allow(Hyperion).to receive(:metrics)`) keep working.
    def runtime_metrics
      @explicit_runtime ? @runtime.metrics : Hyperion.metrics
    end

    def runtime_logger
      @explicit_runtime ? @runtime.logger : Hyperion.logger
    end

    # Bump per-mode dispatch counter + (transitionally, until 2.0) the
    # legacy `:requests_async_dispatched` / `:requests_threadpool_dispatched`
    # keys. Operators on Grafana dashboards from the 1.x line keep getting
    # data; new dashboards should switch to `:requests_dispatch_<mode>`.
    # 2.0 drops the dual-emit.
    def record_dispatch(mode)
      m = runtime_metrics
      m.increment(mode.metric_key)
      # Legacy-key dual emit. The h2 path historically wasn't counted in
      # either legacy bucket — keep that behaviour so dashboards that
      # ignore h2 don't suddenly see a spike.
      case mode.name
      when :threadpool_h1, :inline_h1_no_pool
        m.increment(:requests_threadpool_dispatched)
      when :tls_h1_inline, :async_io_h1_inline
        m.increment(:requests_async_dispatched)
      end
    end

    # Spawn the optional sibling admin listener (RFC A8). When
    # `admin.listener_port` is unset (default), admin endpoints stay
    # mounted in-app via `AdminMiddleware` — no behaviour change.
    def maybe_start_admin_listener
      return unless @admin_listener_port
      return if @admin_token.nil? || @admin_token.empty?

      @admin_listener = Hyperion::AdminListener.new(
        host: @admin_listener_host,
        port: @admin_listener_port,
        token: @admin_token,
        runtime: @runtime
      )
      @admin_listener.start
    end

    # Backpressure rejection. Emits a pre-built 503 + closes the socket.
    # No Rack env, no app dispatch, no access-log line — the overload
    # path must stay cheap so we don't pile rejection cost on top of the
    # already-saturated workers. Bumps :rejected_connections so operators
    # can alert on sustained overload.
    def reject_connection(socket)
      socket.write(REJECT_503)
      runtime_metrics.increment(:rejected_connections)
    rescue StandardError
      # Client may have hung up between accept and our 503 write — that's
      # the failure mode we're protecting them from anyway, so swallow.
      nil
    ensure
      begin
        socket.close
      rescue StandardError
        nil
      end
    end

    def listening_io
      @tcp_server
    end

    def accept_or_nil
      ready, = IO.select([listening_io], nil, nil, 0.1)
      return nil unless ready

      if @tls
        raw, = listening_io.accept_nonblock
        ssl = ::OpenSSL::SSL::SSLSocket.new(raw, @ssl_ctx)
        ssl.sync_close = true
        ssl.accept # blocks; under Async this yields cooperatively via the scheduler
        ssl
      else
        socket, = listening_io.accept_nonblock
        socket
      end
    rescue IO::WaitReadable, Errno::EINTR, Errno::ECONNABORTED
      nil
    rescue IOError, Errno::EBADF
      @stopped = true
      nil
    rescue OpenSSL::SSL::SSLError => e
      runtime_logger.warn { { message: 'tls handshake failed', error: e.message } }
      nil
    end

    def blocking_accept
      if @tls
        raw, = listening_io.accept
        ssl = ::OpenSSL::SSL::SSLSocket.new(raw, @ssl_ctx)
        ssl.sync_close = true
        ssl.accept
        ssl
      else
        socket, = @server.accept
        socket
      end
    rescue OpenSSL::SSL::SSLError => e
      runtime_logger.warn { { message: 'tls handshake failed', error: e.message } }
      nil
    end

    # Defensively set a per-connection read deadline so a stalled client
    # cannot wedge the worker. Phase 2 (fiber scheduler) will replace this
    # with cooperative timeouts driven by the scheduler.
    def apply_timeout(socket)
      target = socket.respond_to?(:io) ? socket.io : socket
      if target.respond_to?(:timeout=)
        target.timeout = @read_timeout
      else
        timeval = [@read_timeout, 0].pack('l_l_')
        target.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_RCVTIMEO, timeval)
      end
    rescue StandardError => e
      runtime_logger.warn do
        { message: 'failed to set read timeout', error: e.message, error_class: e.class.name }
      end
    end
  end
end
