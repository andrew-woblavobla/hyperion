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

    attr_reader :host, :port

    def initialize(app:, host: '127.0.0.1', port: 9292, read_timeout: DEFAULT_READ_TIMEOUT_SECONDS,
                   tls: nil, thread_count: DEFAULT_THREAD_COUNT, max_pending: nil,
                   max_request_read_seconds: 60, h2_settings: nil, async_io: nil)
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
      @thread_pool              = nil
      @stopped                  = false
    end

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
          if @thread_pool.submit_connection(socket, @app,
                                            max_request_read_seconds: @max_request_read_seconds)
            Hyperion.metrics.increment(:requests_threadpool_dispatched)
          else
            reject_connection(socket)
          end
        else
          Hyperion.metrics.increment(:requests_threadpool_dispatched)
          Connection.new.serve(socket, @app, max_request_read_seconds: @max_request_read_seconds)
        end
      end
    end

    # TLS / h2-capable accept loop. The Async wrapper is required because
    # h2 streams (inside Http2Handler) and the ALPN handshake yield
    # cooperatively via the scheduler.
    def start_async_loop
      Async do |task|
        until @stopped
          socket = accept_or_nil
          next unless socket

          apply_timeout(socket)
          task.async { dispatch(socket) }
        end
      end
    end

    def dispatch(socket)
      if socket.is_a?(::OpenSSL::SSL::SSLSocket) && socket.alpn_protocol == 'h2'
        # HTTP/2: each stream runs on a fiber inside Http2Handler. The
        # handler still uses the pool's `#call` for app.call hops on each
        # stream (one per stream, not one per connection). Per-stream
        # counters live inside Http2Handler; we don't bump either of the
        # H1 dispatch buckets here — neither fits the h2 model cleanly.
        Http2Handler.new(app: @app, thread_pool: @thread_pool, h2_settings: @h2_settings).serve(socket)
      elsif inline_h1_dispatch?
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
        # Operators who specifically want TLS+threadpool (e.g. CPU-heavy
        # handlers competing for OS threads) can pass async_io: false to
        # force the pool branch below.
        Hyperion.metrics.increment(:requests_async_dispatched)
        Connection.new.serve(socket, @app, max_request_read_seconds: @max_request_read_seconds)
      elsif @thread_pool
        # HTTP/1.1 default plain-HTTP path, OR explicit async_io: false on
        # TLS (operator opted out of inline-on-fiber dispatch). Hand the
        # connection to a worker thread; the fiber that called dispatch
        # returns immediately. On overflow, reject with 503 + close.
        if @thread_pool.submit_connection(socket, @app,
                                          max_request_read_seconds: @max_request_read_seconds)
          Hyperion.metrics.increment(:requests_threadpool_dispatched)
        else
          reject_connection(socket)
        end
      else
        # No pool (thread_count: 0) on the TLS / async-wrap path with
        # async_io: false. Rare config — neither dispatch bucket fits
        # cleanly. Leave un-counted rather than misclassify; the request
        # still shows up in :requests_total via Connection.
        Connection.new.serve(socket, @app, max_request_read_seconds: @max_request_read_seconds)
      end
    end

    # Decide whether to serve HTTP/1.1 inline on the calling fiber instead
    # of hopping through the worker thread pool. The matrix:
    #   async_io == true       → inline always (plain h1 + TLS h1).
    #   async_io == nil + TLS  → inline (TLS already runs Async loop, so
    #                            the scheduler is current; preserve it).
    #   async_io == nil + plain → pool (pure HTTP/1.1 fast path; no scheduler).
    #   async_io == false       → pool always (explicit opt-out).
    def inline_h1_dispatch?
      return true if @async_io == true
      return false if @async_io == false

      # @async_io.nil? — auto: inline on TLS, pool on plain.
      !@tls.nil?
    end

    # Backpressure rejection. Emits a pre-built 503 + closes the socket.
    # No Rack env, no app dispatch, no access-log line — the overload
    # path must stay cheap so we don't pile rejection cost on top of the
    # already-saturated workers. Bumps :rejected_connections so operators
    # can alert on sustained overload.
    def reject_connection(socket)
      socket.write(REJECT_503)
      Hyperion.metrics.increment(:rejected_connections)
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
      Hyperion.logger.warn { { message: 'tls handshake failed', error: e.message } }
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
      Hyperion.logger.warn { { message: 'tls handshake failed', error: e.message } }
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
      Hyperion.logger.warn do
        { message: 'failed to set read timeout', error: e.message, error_class: e.class.name }
      end
    end
  end
end
