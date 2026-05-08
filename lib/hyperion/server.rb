# frozen_string_literal: true

require 'socket'
require 'openssl'
require 'async'
require 'async/scheduler'

require_relative 'server/route_table'
require_relative 'server/connection_loop'

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

    # 2.10-D — process-wide direct-dispatch route table.  Operators
    # register routes via `Hyperion::Server.handle(:GET, '/hello',
    # handler)` BEFORE forking workers; each forked worker inherits
    # the populated table via copy-on-write.  Per-Server instances
    # can override by passing `route_table:` to the constructor (a
    # test seam — production code uses the class singleton).
    #
    # Lazily initialized so `require 'hyperion'` itself doesn't pay
    # the allocation when the operator never registers a direct
    # route (the common 1.x deployment).
    def self.route_table
      @route_table ||= RouteTable.new
    end

    # Test seam: replace the process-wide route table with a fresh
    # (or stub) instance.  Used by `direct_route_spec.rb` so each
    # example starts from an empty table without needing to call
    # `clear` (which would interfere with parallel registration
    # tests).
    class << self
      attr_writer :route_table
    end

    # 2.10-D — register a direct-dispatch handler.  Bypasses the Rack
    # adapter on hit: when a request whose method + path matches
    # this entry arrives, `Connection#serve` skips the env-hash
    # build, the middleware chain, and the body-iteration loop —
    # the handler is called directly with a `Hyperion::Request`
    # value object.
    #
    # `method_sym` is one of `:GET`, `:POST`, `:PUT`, `:DELETE`,
    # `:HEAD`, `:PATCH`, `:OPTIONS` (case-insensitive — `:get`
    # works too).  `path` is an exact-match String (regex / glob
    # routing is intentionally out of scope; future work).
    # `handler` is any object responding to `#call(request)` that
    # returns a `[status, headers, body]` Rack tuple.
    #
    # Lifecycle hooks (`Runtime#on_request_start` /
    # `on_request_end`) still fire on direct routes so NewRelic /
    # AppSignal / OpenTelemetry instrumentation works regardless
    # of dispatch shape.
    #
    # On a non-match (any path / method not registered here) the
    # request falls through to the regular Rack adapter dispatch
    # — existing behaviour for un-handled routes is unchanged.
    def self.handle(method_sym, path, handler = nil, &block)
      raise ArgumentError, 'pass a handler OR a block, not both' if handler && block
      raise ArgumentError, 'must pass a handler or block' if handler.nil? && block.nil?

      if block
        # 2.14-A — block form: `Server.handle(:GET, '/x') { |env| ... }`.
        # Wraps the block in a `DynamicBlockEntry` so the C accept loop
        # (when engaged) can recognise the entry and dispatch via the
        # registered C-loop helper. The block receives a Rack env hash
        # — same shape Rack apps see — and must return a `[status,
        # headers, body]` triple per the Rack spec.
        method_key = method_sym.to_s.upcase.to_sym
        entry = RouteTable::DynamicBlockEntry.new(method_key, path.dup.freeze, block).freeze
        route_table.register(method_sym, path, entry)
        entry
      else
        # Legacy 2.10-D handler form: `handler#call(request)` returning
        # a `[status, headers, body]` triple. The C accept loop does
        # NOT engage on these — they fall through to the Connection
        # path so the Hyperion::Request shape contract holds.
        route_table.register(method_sym, path, handler)
      end
    end

    # 2.10-D — register a direct-dispatch route whose response is
    # FULLY known at registration time.  The full HTTP/1.1 response
    # buffer (status line + Content-Type + Content-Length + body)
    # is built ONCE here and stashed in a `RouteTable::StaticEntry`;
    # on hit, `Connection#serve` issues a single `socket.write` of
    # the pre-built bytes — no header build, no body iteration,
    # zero per-request allocation past the Connection ivars.
    #
    # Mirrors agoo's optimal hello-world path.  `body_bytes` is
    # the response body (frozen automatically); `content_type`
    # defaults to `text/plain`.  Returns the registered
    # `StaticEntry` for inspection.
    def self.handle_static(method_sym, path, body_bytes, content_type: 'text/plain')
      raise ArgumentError, 'body_bytes must be a String' unless body_bytes.is_a?(String)
      raise ArgumentError, 'content_type must be a String' unless content_type.is_a?(String)

      body = body_bytes.dup.b.freeze
      head = +"HTTP/1.1 200 OK\r\n" \
              "content-type: #{content_type}\r\n" \
              "content-length: #{body.bytesize}\r\n" \
              "\r\n"
      head.force_encoding(Encoding::ASCII_8BIT)
      buffer = (head + body).freeze

      # 2.17-A (Hot Path Task 2) — pre-build the keep-alive wire bytes
      # with a 29-byte Date placeholder so the C-loop writer can splice
      # the per-second-cached httpdate string in without rebuilding the
      # head from scratch every request.  Returned as `[bytes, offset]`
      # — `offset` is the byte index of the first placeholder byte.
      prebuilt_ka_bytes, date_offset =
        build_static_wire_bytes(body, content_type: content_type, server_string: 'Hyperion')

      method_key = method_sym.to_s.upcase.to_sym
      # 2.10-F — record the headers prefix length on the StaticEntry
      # struct so HEAD-method writes can serve a headers-only prefix.
      # 2.17-A — also stash the keep-alive prebuilt bytes + Date offset
      # so the C splice helper (or the Ruby fallback in
      # Connection#serve_static_entry) can stamp the cached date in
      # before each write.
      entry = RouteTable::StaticEntry.new(method_key, path.dup.freeze, buffer, head.bytesize,
                                           prebuilt_ka_bytes, date_offset).freeze
      # 2.10-F — register the entry DIRECTLY (StaticEntry responds to
      # `#call`) instead of wrapping it in a closure, so the dispatch
      # path can branch on `is_a?(StaticEntry)` BEFORE invoking the
      # handler — that's what unlocks the C-ext fast path.
      route_table.register(method_sym, path, entry)
      # 2.10-F — also register HEAD for any GET registration.  HTTP
      # mandates HEAD-on-a-GET-resource, and the C fast path strips
      # the body bytes for HEAD requests inside `serve_request`.
      # Idiomatic for static-asset routes (every CDN-shaped GET URL
      # MUST also answer HEAD with the same headers).  No-op on a
      # POST/PUT/etc. registration — those don't get a HEAD twin.
      route_table.register(:HEAD, path, entry) if method_key == :GET
      # 2.17-A — fold the keep-alive prebuilt bytes (with Date placeholder)
      # into the C-side PageCache so `PageCache.serve_request` and the
      # C accept loop both serve the new shape.  The 4-arg
      # `register_prebuilt` form (introduced in 2.17-A) records the
      # Date offset on the C-side `hyp_page_t` so every snapshot
      # site splices the cached date before writing.  Best-effort:
      # the C ext may be absent on JRuby / TruffleRuby — the
      # dispatcher silently falls back to the Ruby `socket.write`
      # path that's been there since 2.10-D.
      if defined?(::Hyperion::Http::PageCache) && ::Hyperion::Http::PageCache.respond_to?(:register_prebuilt)
        ::Hyperion::Http::PageCache.register_prebuilt(path, prebuilt_ka_bytes, body.bytesize, date_offset)
      end
      entry
    end

    # 2.17-A (Hot Path Task 2) — assemble the prebuilt keep-alive
    # wire bytes for a static route registered via `handle_static`.
    # Returns `[frozen_bytes, date_offset]`:
    #   * `frozen_bytes` — ASCII-8BIT, frozen String of the full
    #     HTTP/1.1 response (status line + Server + Content-Type +
    #     Content-Length + Connection: keep-alive + Date placeholder
    #     + CRLFCRLF + body).  The Date placeholder is a 29-byte 'X'
    #     run that the C splice helper overwrites in a per-write
    #     scratch buffer (the frozen String itself is NEVER mutated).
    #   * `date_offset` — Integer index of the first placeholder
    #     byte within `frozen_bytes`.  29 bytes is the canonical RFC
    #     7231 imf-fixdate length (`Sun, 06 Nov 1994 08:49:37 GMT`).
    #
    # Header order is fixed on purpose — the C splice helper relies
    # on the offset being stable across requests; placing Date last
    # keeps the offset arithmetic trivial regardless of body length
    # variations between routes.  Headers are capitalized in the
    # canonical RFC 7230 §3.2 form (case-insensitive but
    # conventionally capitalized) so the wire output matches what
    # CDN / proxy logs expect.
    def self.build_static_wire_bytes(body, content_type:, server_string:)
      placeholder = 'X' * 29
      head_prefix = +"HTTP/1.1 200 OK\r\n" \
                     "Server: #{server_string}\r\n" \
                     "Content-Type: #{content_type}\r\n" \
                     "Content-Length: #{body.bytesize}\r\n" \
                     "Connection: keep-alive\r\n" \
                     "Date: "
      head_prefix.force_encoding(Encoding::ASCII_8BIT)
      date_offset = head_prefix.bytesize
      head = head_prefix + placeholder + "\r\n\r\n"
      head.force_encoding(Encoding::ASCII_8BIT)
      bytes = (head + body).b.freeze
      [bytes, date_offset]
    end
    private_class_method :build_static_wire_bytes

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
                   admin_listener_host: '127.0.0.1', admin_token: nil,
                   tls_session_cache_size: TLS::DEFAULT_SESSION_CACHE_SIZE,
                   tls_ktls: :auto,
                   io_uring: :off,
                   io_uring_hotpath: :off,
                   max_in_flight_per_conn: nil,
                   tls_handshake_rate_limit: :unlimited,
                   route_table: nil,
                   preload_static_dirs: nil)
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
      # 2.0: `h2_max_total_streams` is normally a positive integer (the
      # default-flipped cap from `Config#finalize!`) or nil (operator
      # opted out via `h2.max_total_streams :unbounded`). Defensive
      # branch: treat the `:auto` / `:unbounded` sentinels as "no cap"
      # if a caller bypasses Config and constructs Server directly.
      @h2_admission             = if h2_max_total_streams.is_a?(Integer) && h2_max_total_streams.positive?
                                    Hyperion::H2Admission.new(max_total_streams: h2_max_total_streams)
                                  end
      @admin_listener_port      = admin_listener_port
      @admin_listener_host      = admin_listener_host
      @admin_token              = admin_token
      @admin_listener           = nil
      @thread_pool              = nil
      @stopped                  = false
      @tls_session_cache_size   = tls_session_cache_size
      @tls_ktls                 = tls_ktls
      @ktls_logged              = false
      # 2.3-A: resolve the io_uring accept policy. `:off` (the 2.3.0
      # default) skips the resolve step entirely so hosts without the
      # cdylib don't trigger any Fiddle.dlopen probe at boot.
      # Workers don't share rings across fork — each child opens its
      # own ring lazily on first use inside `run_accept_fiber`.
      @io_uring_policy          = io_uring
      @io_uring_active          = io_uring != :off && Hyperion::IOUring.resolve_policy!(io_uring)
      log_io_uring_state_once
      # Plan #2 — hotpath gate. Independent of @io_uring_active: the
      # hotpath owns multishot accept + multishot recv + send SQEs on a
      # single unified ring, while the accept-only path uses a simpler
      # ring that only drives accept SQEs. The two paths are mutually
      # exclusive at runtime — HotpathRing takes priority when active.
      # Workers don't share hotpath rings across fork; each child opens
      # its own ring lazily on first use inside `run_accept_fiber`.
      @io_uring_hotpath_policy  = io_uring_hotpath
      @io_uring_hotpath_active  = io_uring_hotpath != :off &&
                                   Hyperion::IOUring.resolve_hotpath_policy!(io_uring_hotpath)
      log_io_uring_hotpath_state_once
      # 2.3-B: per-conn fairness cap (validated/finalized upstream by
      # `Config#finalize!`; constructor accepts the resolved value, not
      # a sentinel). nil = no cap (default). The cap propagates to
      # every Connection the ThreadPool's `:connection` worker builds.
      @max_in_flight_per_conn   = max_in_flight_per_conn
      # 2.3-B: TLS handshake CPU throttle. One limiter per worker
      # (per-Server). `:unlimited` short-circuits every `acquire_token!`
      # to true so the hot path stays branchless. Built eagerly so
      # bench harnesses can introspect via `server.tls_handshake_limiter`.
      @tls_handshake_limiter    = Hyperion::TLS::HandshakeRateLimiter.new(tls_handshake_rate_limit)
      # 2.10-D: per-instance route table (defaults to the class-level
      # singleton).  Tests can inject a fresh table to isolate
      # registrations from other examples.
      @route_table              = route_table || Hyperion::Server.route_table
      # 2.10-E: list of `{path:, immutable:}` entries the worker warms
      # into `Hyperion::Http::PageCache` at boot. Resolved by
      # `Config#resolved_preload_static_dirs` and threaded through
      # Master → Worker → Server. nil/[] = no preload (1.x cold-cache
      # behaviour).
      @preload_static_dirs      = preload_static_dirs
      @preloaded                = false
    end

    # Read-only handle for tests + bench harness introspection.
    attr_reader :tls_handshake_limiter

    # 2.10-D — read-only handle to the per-instance route table.
    # Connection#serve consults this after parse to decide whether
    # to engage the direct-dispatch fast path.  Defaults to the
    # process-wide `Hyperion::Server.route_table` singleton.
    attr_reader :route_table

    # Read-only handle to the per-worker SSL context (nil when the
    # listener is plain TCP). Exposed so the worker can call
    # `Hyperion::TLS.rotate!(server.ssl_context)` from its SIGUSR2
    # handler without reaching into Server internals.
    attr_reader :ssl_ctx

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
        @ssl_ctx = TLS.context(cert: @tls[:cert], key: @tls[:key], chain: @tls[:chain],
                               session_cache_size: @tls_session_cache_size,
                               ktls: @tls_ktls)
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
      if @tls
        @ssl_ctx = TLS.context(cert: @tls[:cert], key: @tls[:key], chain: @tls[:chain],
                               session_cache_size: @tls_session_cache_size,
                               ktls: @tls_ktls)
      end
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
      # 2.10-E: warm the page cache before any request can land. Idempotent
      # via `@preloaded`, so repeated `start` calls (test harnesses,
      # Worker#run respawn) don't re-walk the tree. Runs after `listen`
      # (so `@server` exists for the operator's introspection hooks if any
      # future runtime fires off boot-side instrumentation) but before the
      # accept loop fires up — first request hits warm cache.
      preload_static!
      if @thread_count.positive?
        @thread_pool = ThreadPool.new(size: @thread_count, max_pending: @max_pending,
                                      max_in_flight_per_conn: @max_in_flight_per_conn,
                                      route_table: @route_table)
      end
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

    # 2.14-B — graceful stop sequence.
    #
    # Pre-2.14-B this was three lines: flip the Ruby `@stopped` flag,
    # `close()` the listener, drop the references. That was enough
    # for the Ruby/Async accept loops on every kernel — those poll
    # `@stopped` every 100 ms via the `IO.select` timeout in
    # `accept_or_nil` and exit at the next tick. It was NOT enough
    # for the C accept loop introduced by 2.12-C: that loop calls a
    # blocking `accept(2)` with the GVL released and only checks
    # `hyp_cl_stop` between accepts. On Linux ≥ 6.x, calling
    # `close()` on a listening socket from one thread does NOT
    # interrupt another thread that is currently parked in
    # `accept(2)` on that same fd — so the C loop stayed parked
    # until a real connection arrived. SIGTERM-driven graceful
    # shutdown then hung until the master's `graceful_timeout`
    # (default 30 s) expired and SIGKILL fired. See CHANGELOG
    # ### 2.13-C for the full discovery story.
    #
    # Fix surface: only the C accept loop needs the wake-connect
    # dance. The wake gate (`wake_required?`) keeps the change
    # surgical: TLS, async-IO, and thread-pool servers see the same
    # close-then-drop sequence they had pre-2.14-B; only the C-loop
    # server pays the burst cost. Wiring the wake into the Async
    # path would be unnecessary (it polls @stopped) and would
    # introduce a close-vs-`IO.select`-EBADF race on macOS kqueue.
    #
    # Order rationale (C-loop case).
    # 1. The wake-connect dial happens BEFORE `close_listeners` so
    #    THIS process's listener fd is still in the SO_REUSEPORT
    #    pool when the kernel hashes the SYN. Closing first would
    #    drop us from the pool — every dial would hash to a sibling
    #    worker (in `:reuseport` cluster mode) and never reach our
    #    own parked accept thread.
    # 2. The burst (`WAKE_CONNECT_BURST` dials) drives the miss
    #    probability down for the SO_REUSEPORT-distributes-unevenly
    #    case. Single-server / `:share` cluster mode (Darwin/BSD)
    #    just sees K extra zero-byte connects — cheap.
    # 3. `close_listeners` runs last as a belt-and-braces close on
    #    macOS / *BSD where the close-on-accept-wake guarantee still
    #    holds, and to release the bound port to the OS promptly.
    #
    # Idempotent: a second `stop` call is a no-op — `wake_target`
    # returns `[nil, nil]` once the listener references are nilled,
    # and `close_listeners` swallows the EBADF.
    def stop
      @stopped = true
      if wake_required?
        # C-loop path: flip the C-side flag, dial the wake-connect
        # burst, THEN close. The wake makes any thread parked in
        # `accept(2)` return; the loop checks the flag, exits cleanly.
        stop_c_accept_loop
        host, port = wake_target
        ConnectionLoop.wake_listener(host, port, count: ConnectionLoop::WAKE_CONNECT_BURST) \
          if host && port
      end
      # Pre-2.14-B `close` path. For TLS / async-IO / thread-pool
      # servers this is the entire stop sequence and matches the
      # behaviour the spec suite (and operators) have been observing
      # since 1.0 — the wake-connect dance is a no-op for them and
      # has been deliberately gated out via `wake_required?`.
      close_listeners
      nil
    end

    private

    # 2.14-B — predicate: is the wake-connect needed for THIS server
    # instance? Only servers driving the C accept loop need it; the
    # Ruby/Async paths poll `@stopped` and exit on the next 100 ms
    # `IO.select` tick. We piggyback on the existing
    # `engage_c_accept_loop?` predicate so the wake gate stays in
    # sync with engagement: if the runtime ever changes the C-loop
    # eligibility rules, both call sites update together.
    #
    # Async-IO path explicitly excluded: even if the route table
    # would otherwise be C-loop-eligible, `start_async_loop` runs
    # the Ruby accept fibers (the C loop never engages alongside
    # Async). Adding wake-connect there would race close()-on-fd
    # vs. an IO.select that's already parked on the listener — on
    # macOS kqueue that surfaces as `Errno::EBADF` from
    # `select_internal_with_gvl:kevent`, propagating up through
    # `start_async_loop`'s rescue-wait.
    def wake_required?
      return false if @tls
      return false if @async_io

      engage_c_accept_loop?
    end

    # Capture the bound `(host, port)` of the listener BEFORE we close
    # it. We deliberately read `@host` (the configured bind addr —
    # `127.0.0.1` / `0.0.0.0` / a real interface IP) rather than
    # `@server.addr` because:
    #
    # 1. Once `close()` lands the addr struct is gone — we'd dial
    #    against a stale value.
    # 2. The wake-connect target only needs to reach this kernel's
    #    listener fd; localhost works for any bound address (the
    #    kernel routes locally).
    #
    # Special case: bind addr `0.0.0.0` / `::` / empty — dial 127.0.0.1
    # (loopback always reaches the worker's own listener). Same trick
    # the spec helper uses.
    def wake_target
      return [nil, nil] unless @port && @port.positive?

      host = @host
      host = '127.0.0.1' if host.nil? || host.empty? || host == '0.0.0.0'
      host = '::1' if host == '::'
      [host, @port]
    end

    # Flip the C-side stop flag so the C accept loop (2.12-C / 2.12-D
    # / 2.14-A variants) drops out at the next `accept(2)` return.
    # Idempotent — flipping the flag twice is harmless. The C ext may
    # be absent on JRuby / TruffleRuby; the `respond_to?` guard keeps
    # those builds working.
    def stop_c_accept_loop
      pc = defined?(::Hyperion::Http::PageCache) ? ::Hyperion::Http::PageCache : nil
      pc.stop_accept_loop if pc.respond_to?(:stop_accept_loop)
    rescue StandardError
      # Best-effort. Stop must never raise — it's called from a signal
      # handler thread, where an unhandled exception would hang the
      # whole worker.
      nil
    end

    # Close + nil-out both listener references. The pre-2.14-B
    # `close` is preserved as the primary signal for non-Linux
    # platforms and as a belt-and-braces measure on Linux for the
    # case where the wake-connect raced ahead of us.
    def close_listeners
      @server&.close
    rescue IOError, Errno::EBADF
      # Listener already closed — `stop` was called twice or the
      # C accept loop tore it down via its own error path.
      nil
    ensure
      @server = nil
      @tcp_server = nil
    end

    public

    # 2.10-E — Walk every configured preload directory, populate
    # `Hyperion::Http::PageCache`, and mark every entry immutable when
    # asked.  Called from `start` once per worker.  Idempotent — second
    # call is a no-op so test harnesses + Worker respawn paths don't
    # re-walk the tree.
    #
    # `logger` is exposed as a kwarg purely for the spec suite; production
    # callers omit it and the runtime logger is used.
    def preload_static!(logger: runtime_logger)
      return 0 if @preloaded

      @preloaded = true
      entries = @preload_static_dirs
      return 0 if entries.nil? || entries.empty?

      Hyperion::StaticPreload.run(entries, logger: logger)
    end

    private

    # Plain HTTP/1.1 accept loop — no fiber wrap. Connections go straight to
    # a worker via the thread pool, or are served inline when no pool is
    # configured (thread_count: 0). Matches the dispatch contract used by
    # the TLS path; just skips the irrelevant h2/ALPN branch.
    #
    # 2.12-C — when the route table is composed entirely of `StaticEntry`
    # registrations (and at least one is present), and the C ext is
    # available, the entire accept-and-serve loop runs in C via
    # `Hyperion::Http::PageCache.run_static_accept_loop`. Ruby is only
    # re-entered for lifecycle hooks (gated by a C-side flag) and for
    # the handoff path when a request doesn't match any StaticEntry.
    def start_raw_loop
      return run_c_accept_loop if engage_c_accept_loop?

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
          Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                         max_in_flight_per_conn: @max_in_flight_per_conn,
                         route_table: @route_table).serve(
                           socket, @app, max_request_read_seconds: @max_request_read_seconds
                         )
        end
      end
    end

    # Whether all engagement conditions hold for the C accept loop.
    def engage_c_accept_loop?
      return false if @tls
      return false unless ConnectionLoop.available?
      return false unless ConnectionLoop.eligible_route_table?(@route_table)

      true
    end
    private :engage_c_accept_loop?

    # Hand control of the listening fd to the C loop. Wires up the
    # lifecycle + handoff callbacks first; on return (clean stop or
    # `:crashed` sentinel from C), bumps the dispatch metric and
    # falls through to the regular Ruby accept loop on `:crashed`
    # so an unrecoverable C-side accept error doesn't leave the
    # listener idle.
    def run_c_accept_loop
      pc = ::Hyperion::Http::PageCache
      pc.set_lifecycle_callback(ConnectionLoop.build_lifecycle_callback(@runtime))
      pc.set_lifecycle_active(@runtime.has_request_hooks?)
      pc.set_handoff_callback(ConnectionLoop.build_handoff_callback(self))

      # 2.14-A — wire up the dynamic-block dispatch surface. Registers
      # every `RouteTable::DynamicBlockEntry` with the C-side path
      # registry and stashes the bound dispatch closure on the C loop
      # so per-request hits can call back into Ruby with the right
      # runtime context.
      register_dynamic_blocks_with_c_loop(pc) if pc.respond_to?(:register_dynamic_block)
      # 2.12-E — register the per-worker request counter family on the
      # runtime's metrics sink BEFORE the C loop starts ticking. The
      # PrometheusExporter's C-loop fold-in is gated on the family
      # already existing in the snapshot (so spec-only sinks that
      # never tick stay clean), and the C accept loop bypasses
      # `Connection#serve` — without an explicit boot-time register,
      # a 100% C-loop worker would scrape zero requests even with
      # the atomic happily ticking.
      runtime_metrics.ensure_worker_request_family_registered! \
        if runtime_metrics.respond_to?(:ensure_worker_request_family_registered!)

      # 2.12-D — io_uring path takes precedence over accept4 when the
      # operator opted in AND the runtime probe at boot succeeds. The
      # C-side `run_static_io_uring_loop` returns `:unavailable` if
      # `io_uring_queue_init` fails; we treat that as "fall back to
      # the 2.12-C accept4 path" without operator intervention. A
      # `:crashed` from io_uring also falls back — the contract
      # mirrors 2.12-C's `:crashed -> Ruby accept loop`.
      use_io_uring = ConnectionLoop.io_uring_eligible?
      mode_name = use_io_uring ? :c_accept_loop_io_uring_h1 : :c_accept_loop_h1
      mode = DispatchMode.new(mode_name)
      record_dispatch(mode)
      runtime_logger.info do
        { message: 'engaging C accept loop',
          variant: use_io_uring ? :io_uring : :accept4,
          static_routes: @route_table.size,
          host: @host,
          port: @port }
      end
      result = if use_io_uring
                 io_uring_result = pc.run_static_io_uring_loop(@tcp_server.fileno)
                 if io_uring_result == :unavailable
                   runtime_logger.warn do
                     { message: 'io_uring runtime probe failed; falling back to accept4 loop' }
                   end
                   pc.run_static_accept_loop(@tcp_server.fileno)
                 else
                   io_uring_result
                 end
               else
                 pc.run_static_accept_loop(@tcp_server.fileno)
               end
      if result == :crashed
        runtime_logger.warn do
          { message: 'C accept loop crashed; falling back to Ruby accept loop' }
        end
        # Fall back to the Ruby loop so the listener doesn't go silent.
        until @stopped
          socket = accept_or_nil
          next unless socket

          apply_timeout(socket)
          dispatch_one_h1(socket)
        end
      else
        runtime_logger.info do
          { message: 'C accept loop exited', requests_served: result.to_i,
            variant: use_io_uring ? :io_uring : :accept4 }
        end
        runtime_metrics.increment(:c_accept_loop_requests, result.to_i)
      end
    ensure
      # Best-effort: clear the lifecycle callback so a subsequent
      # Server boot in the same process (test harnesses) doesn't see
      # stale state.
      pc&.set_lifecycle_active(false) if defined?(pc)
      pc&.set_lifecycle_callback(nil) if defined?(pc)
      pc&.set_handoff_callback(nil) if defined?(pc)
      # 2.14-A — also clear dynamic block registrations + dispatch
      # callback so a re-engage with a different runtime / route
      # table starts clean.
      if defined?(pc) && pc.respond_to?(:clear_dynamic_blocks!)
        pc.clear_dynamic_blocks!
        pc.set_dynamic_dispatch_callback(nil)
      end
    end
    private :run_c_accept_loop

    # 2.14-A — Walk `@route_table` and push every `DynamicBlockEntry`
    # into the C-side path registry. Also installs the dispatch
    # callback that the C loop invokes per dynamic-block hit; the
    # callback closes over `@runtime` so per-tenant Hyperion::Runtime
    # observers see the right server's hooks fire.
    def register_dynamic_blocks_with_c_loop(pc)
      runtime = @runtime
      pc.set_dynamic_dispatch_callback(
        lambda do |method_str, path_str, query_str, host_str,
                   headers_blob, remote_addr, block, keep_alive|
          ::Hyperion::Adapter::Rack.dispatch_for_c_loop(
            method_str, path_str, query_str, host_str,
            headers_blob, remote_addr, block, keep_alive, runtime
          )
        end
      )
      pc.clear_dynamic_blocks!
      @route_table.instance_variable_get(:@routes).each do |method_sym, path_table|
        next unless %i[GET HEAD].include?(method_sym)

        path_table.each do |path, handler|
          next unless handler.is_a?(::Hyperion::Server::RouteTable::DynamicBlockEntry)

          pc.register_dynamic_block(path, method_sym, handler.block)
        end
      end
    end
    private :register_dynamic_blocks_with_c_loop

    # Dispatch a connection that the C accept loop handed off to Ruby
    # because it couldn't be served from the static cache (path miss,
    # malformed request, body present, h2 upgrade requested, etc.).
    # `partial` is the partial header buffer the C loop already read
    # off the fd, or nil if the C loop hadn't started reading.
    #
    # The fd is owned by Ruby from this point on — the C loop will
    # not touch it again. We wrap it in a `::Socket` (matches the
    # `accept_nonblock` path's return type) and dispatch through the
    # existing thread-pool / inline path.
    def dispatch_handed_off(fd, partial)
      require 'socket'
      socket = ::Socket.for_fd(fd)
      socket.autoclose = true
      apply_timeout(socket)
      # 2.12-E — `partial.present?` was a Rails-ism that crashed the
      # handoff path with NoMethodError on plain Ruby. Hit by every
      # request that lands on a static-only server (e.g. /-/metrics
      # against `bench/hello_static.ru`) — the C loop hands off, the
      # handoff dispatch raised, and the connection was force-closed
      # with `:c_loop_handoff_failed`. Surfaced by the 2.12-E audit
      # harness which scrapes /-/metrics on a handle_static-only
      # cluster; pre-existing bug, fixed here so the metric is
      # actually readable. The `is_a?(String)` guard is deliberate —
      # it both narrows the contract (the C loop never hands off
      # anything but a plain String or nil) and pins the shape so
      # `rubocop-rails`'s Style/Present autocorrect can't rewrite
      # this back to `partial.present?`.
      carry = partial.is_a?(String) && !partial.empty? ? partial.dup.b : nil

      if @thread_pool
        mode = DispatchMode.new(:threadpool_h1)
        # 2.12-E — thread the carry through to the worker so the
        # `Connection#@inbuf` is preloaded with the partial header
        # bytes the C accept loop already drained off the fd. Pre-2.12-E
        # the threadpool handoff path silently dropped the buffer
        # (only the inline-no-pool branch wired it), so every
        # `-t N>0` server with the C accept loop engaged returned
        # "Request Timeout" on every handed-off request — including
        # the audit harness's own `/-/metrics` scrape.
        if @thread_pool.submit_connection(socket, @app,
                                          max_request_read_seconds: @max_request_read_seconds,
                                          carry: carry)
          record_dispatch(mode)
        else
          reject_connection(socket)
        end
      else
        mode = DispatchMode.new(:inline_h1_no_pool)
        record_dispatch(mode)
        connection = Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                                    max_in_flight_per_conn: @max_in_flight_per_conn,
                                    route_table: @route_table)
        connection.instance_variable_set(:@inbuf, +carry.b) if carry
        connection.serve(socket, @app,
                         max_request_read_seconds: @max_request_read_seconds)
      end
    end
    private :dispatch_handed_off

    def dispatch_one_h1(socket)
      if @thread_pool
        mode = DispatchMode.new(:threadpool_h1)
        if @thread_pool.submit_connection(socket, @app,
                                          max_request_read_seconds: @max_request_read_seconds)
          record_dispatch(mode)
        else
          reject_connection(socket)
        end
      else
        mode = DispatchMode.new(:inline_h1_no_pool)
        record_dispatch(mode)
        Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                       max_in_flight_per_conn: @max_in_flight_per_conn,
                       route_table: @route_table).serve(
                         socket, @app, max_request_read_seconds: @max_request_read_seconds
                       )
      end
    end
    private :dispatch_one_h1

    # TLS / h2-capable accept loop. The Async wrapper is required because
    # h2 streams (inside Http2Handler) and the ALPN handshake yield
    # cooperatively via the scheduler.
    #
    # 1.7.0 (RFC A6): `accept_fibers_per_worker > 1` spawns N accept
    # fibers that each `IO.select` on the same listening fd. On `:reuseport`
    # workers (Linux) the kernel hashes connections fairly across siblings;
    # on `:share` (Darwin) the knob is silently honoured but shows no
    # scaling benefit — operators already know Darwin is special.
    # 2.15-A — outer rescue for `Errno::EBADF` / `IOError`.
    #
    # Background: prior to 2.15-A this was just the inner
    # `task.children.each { child.wait rescue StandardError; nil }`
    # pattern. That handles raises from the accept fiber bodies, but
    # NOT from `Async::Scheduler#close`, which runs implicitly when the
    # `Async do ... end` block exits and which itself parks in
    # `epoll_wait` / `kevent`. If `stop` closed the listener fd while
    # the scheduler still had it registered, the scheduler-close
    # surfaces `Errno::EBADF: Bad file descriptor —
    # select_internal_with_gvl:epoll_wait` and re-raises it past the
    # inner rescue (the inner rescue is only on `child.wait`).
    #
    # Symptom in CI: `async_io: true` boot/stop integration specs flake
    # on Ruby 3.4 + async 2.39 with EBADF bubbling out of the worker
    # thread. The race window is widest with `thread_count: 0` because
    # the entire dispatch path runs on the same fiber as the accept
    # loop, so there's no thread-pool synchronization barrier between
    # `stop` and scheduler close.
    #
    # Fix: catch `Errno::EBADF`/`IOError` at the outer `Async do` scope.
    # These are exclusively shutdown signals (the listener fd only goes
    # bad when `close_listeners` has run); swallowing them here is
    # equivalent to the C-loop path, which already swallows them inside
    # `accept_or_nil`. The change is intentionally narrow — other
    # `StandardError` from inside the loop bodies still propagates out
    # so genuine accept-loop bugs are not masked.
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
    rescue Errno::EBADF, IOError
      # Listener fd already closed by `stop` — scheduler close-time
      # epoll_wait / kevent saw the bad fd. Benign at this point;
      # the server is shutting down by design.
      nil
    end

    # Single accept fiber's run loop. Called N times (default 1) from
    # `start_async_loop`. All accept fibers share `@server` / `@tcp_server`
    # via closure; the kernel arbitrates which fiber wins each
    # IO.select / accept_nonblock race.
    #
    # 2.3-A: when `io_uring: :auto/:on` resolves to active, each accept
    # fiber lazily opens its OWN ring (per-fiber lifecycle — see
    # `Hyperion::IOUring` docs for the fork+threads sharp edges this
    # avoids). The ring is closed at fiber exit. The TLS path keeps the
    # epoll branch — io_uring accept is wired only for the plain TCP
    # listener; the SSL handshake still wants the userspace
    # `accept` + `SSL_accept` dance.
    #
    # Plan #2: when `io_uring_hotpath: :auto/:on` resolves to active, the
    # hotpath ring takes priority — it owns multishot accept + multishot recv
    # + send SQEs. The accept-only ring and the epoll path are mutually
    # exclusive with it. TLS still uses the epoll branch regardless.
    def run_accept_fiber(task)
      if @io_uring_hotpath_active && !@tls
        run_accept_fiber_io_uring_hotpath(task)
      elsif @io_uring_active && !@tls
        run_accept_fiber_io_uring(task)
      else
        run_accept_fiber_epoll(task)
      end
    end

    def run_accept_fiber_epoll(task)
      until @stopped
        socket = accept_or_nil
        next unless socket

        apply_timeout(socket)
        task.async { dispatch(socket) }
      end
    end

    # 2.3-A: io_uring accept loop. Opens a per-fiber ring on first
    # use, drains accept CQEs, and hands the resulting fd to the
    # existing `dispatch` path via a Ruby `Socket.for_fd` wrapper so
    # the rest of the server (Connection, ResponseWriter, …) keeps
    # working off a `::Socket` object identical to what
    # `accept_nonblock` would have returned.
    def run_accept_fiber_io_uring(task)
      ring = Fiber[:hyperion_io_uring] ||= Hyperion::IOUring::Ring.new(queue_depth: 256)
      listener_fd = listening_io.fileno
      until @stopped
        client_fd = ring.accept(listener_fd)
        next if client_fd == :wouldblock

        socket = ::Socket.for_fd(client_fd)
        socket.autoclose = true
        apply_timeout(socket)
        task.async { dispatch(socket) }
      end
    rescue IOError, Errno::EBADF
      @stopped = true
    rescue StandardError => e
      runtime_logger.warn do
        { message: 'io_uring accept fiber error; falling back to epoll for this fiber',
          error: e.message, error_class: e.class.name }
      end
      run_accept_fiber_epoll(task)
    ensure
      ring = Fiber[:hyperion_io_uring]
      if ring && !ring.closed?
        ring.close
        Fiber[:hyperion_io_uring] = nil
      end
    end

    # Plan #2 — io_uring hotpath accept loop. Opens a per-fiber
    # HotpathRing on first use (multishot accept + multishot recv +
    # send SQEs on one unified ring). For this task the loop only
    # submits the multishot accept SQE and drains accept completions;
    # the per-connection recv wiring is added in Task 2.3.4.
    #
    # On failure it closes the hotpath ring and falls back to the epoll
    # path, matching the accept-only ring's fallback contract.
    def run_accept_fiber_io_uring_hotpath(task)
      ring = Fiber[:hyperion_hotpath_ring] ||=
               Hyperion::IOUring::HotpathRing.new
      listener_fd = listening_io.fileno
      ring.submit_accept_multishot(listener_fd)
      # Plan #2 Task 2.3.4 — per-connection state map.
      # Maps client_fd (Integer) → Connection.  Populated on OP_ACCEPT
      # and cleared on OP_RECV result <= 0 (EOF / error).  Single-fiber
      # — no mutex needed.
      hotpath_connections = {}
      until @stopped
        ring.each_completion(min_complete: 1, timeout_ms: 100) do |c|
          case c[:op_kind]
          when Hyperion::IOUring::HotpathRing::OP_ACCEPT
            next if c[:result].negative?

            client_fd = c[:result].to_i
            socket = ::Socket.for_fd(client_fd)
            socket.autoclose = true
            apply_timeout(socket)
            # Build a Connection for the accepted fd. io_uring_owned: true
            # arms the guard in read_chunk (should never be called for
            # these connections) and signals close_for_eof callers.
            conn = Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                                  max_in_flight_per_conn: @max_in_flight_per_conn,
                                  route_table: @route_table,
                                  io_uring_owned: true,
                                  app: @app)
            conn.instance_variable_set(:@socket, socket)
            # Server has no @metrics ivar — sibling accept paths bump
            # these counters via runtime_metrics (record_dispatch et al.)
            # or via Connection#serve, which we bypass here. Using @metrics
            # here raised NoMethodError on the first ACCEPT completion and
            # took down the --async-io + hotpath=on + 1w boot before
            # wait_for_bind could land its first probe (row-19 BOOT-FAIL).
            runtime_metrics.increment(:connections_accepted)
            runtime_metrics.increment(:connections_active)
            hotpath_connections[client_fd] = conn
            # Post the first multishot-recv SQE for this fd.  From here
            # on, the kernel delivers recv CQEs for every batch of bytes
            # that arrives on this socket until EOF or cancel.
            ring.submit_recv_multishot(client_fd)

          when Hyperion::IOUring::HotpathRing::OP_RECV
            fd     = c[:fd]
            result = c[:result]
            buf_id = c[:buf_id]

            conn = hotpath_connections[fd]
            next unless conn

            if result <= 0
              # 0 = peer EOF; negative = error.  Clean up and discard.
              hotpath_connections.delete(fd)
              conn.close_for_eof
              begin
                conn.socket&.close unless conn.socket&.closed?
              rescue StandardError
                nil
              end
            else
              # Copy `result` bytes from the kernel buffer slot into a
              # Ruby String (one allocation), then release the slot so
              # the kernel can reuse it for the next recv.
              bytes = ring.copy_buffer(buf_id, result)
              ring.release_buffer(buf_id)
              conn.feed_read_bytes(bytes)
            end
          end
        end

        # Plan #2 Task 2.5.2 — per-worker fallback-engaged detection.
        # After each completion drain, check whether the ring went
        # unhealthy (sustained SQE submit failures / repeated EBADR
        # from the Rust side set a dirty flag). When detected:
        #   1. Increment the observable metric so operators can alert.
        #   2. Emit a single warn-level log line (actionable, not spammy).
        #   3. Flip @io_uring_hotpath_active to false so subsequent
        #      accept-fiber dispatch (run_accept_fiber's top-level branch)
        #      uses the epoll path for newly-spawned accept fibers on
        #      restart — the current fiber exits the loop and falls
        #      through to run_accept_fiber_epoll below.
        unless ring.healthy?
          runtime_metrics.increment(:io_uring_hotpath_fallback_engaged)
          runtime_logger.warn do
            { message: 'io_uring hotpath ring unhealthy; engaging accept4 fallback per-worker',
              worker_pid: Process.pid }
          end
          @io_uring_hotpath_active = false
          begin
            ring.close
          rescue StandardError
            nil
          end
          Fiber[:hyperion_hotpath_ring] = nil
          break
        end
      end
      # If we broke out due to an unhealthy ring (not a clean stop), fall
      # through to the epoll path so existing + new connections keep being
      # served. @stopped is still false in that case — the server is alive.
      run_accept_fiber_epoll(task) unless @stopped
    rescue IOError, Errno::EBADF
      @stopped = true
    rescue Hyperion::IOUring::Unsupported => e
      runtime_logger.warn do
        { message: 'io_uring hotpath unsupported at fiber open; falling back to epoll',
          error: e.message }
      end
      close_hotpath_ring_for_fallback
      run_accept_fiber_epoll(task)
    rescue StandardError => e
      runtime_logger.warn do
        { message: 'io_uring hotpath accept fiber error; falling back to epoll',
          error: e.message, error_class: e.class.name }
      end
      close_hotpath_ring_for_fallback
      run_accept_fiber_epoll(task)
    ensure
      close_hotpath_ring_for_fallback
    end

    # Cancel the multishot-accept SQE armed on @listener_fd by closing
    # the hotpath ring before the epoll fallback takes over. Without this,
    # `accept_or_nil` in run_accept_fiber_epoll competes with a still-armed
    # kernel-side multishot-accept consumer and inbound connections can be
    # delivered to a dead CQ. Idempotent.
    def close_hotpath_ring_for_fallback
      ring = Fiber[:hyperion_hotpath_ring]
      return unless ring && !ring.closed?

      ring.close
      Fiber[:hyperion_hotpath_ring] = nil
    rescue StandardError
      nil
    end
    private :close_hotpath_ring_for_fallback

    # Plan #2 — test seam: returns the active HotpathRing on the current
    # accept fiber, or nil if none. Used by io_uring_hotpath_fallback_engaged_spec
    # to inject force_unhealthy! without exposing the ring through the
    # public Server surface.
    def hotpath_ring_for_test
      Fiber[:hyperion_hotpath_ring]
    end
    private :hotpath_ring_for_test

    # Boot-time log line per worker capturing the resolved io_uring
    # state. Mirrors the `log_ktls_state_once` pattern from 2.2.0.
    # Single-shot via the class-level ivar so multi-worker boots
    # don't fan into N identical lines.
    def log_io_uring_state_once
      return if Hyperion::Server.instance_variable_get(:@io_uring_state_logged)
      return if @io_uring_policy == :off

      Hyperion::Server.instance_variable_set(:@io_uring_state_logged, true)
      runtime_logger.info do
        {
          message: 'io_uring accept policy resolved',
          policy: @io_uring_policy,
          active: @io_uring_active,
          supported: Hyperion::IOUring.supported?
        }
      end
    rescue StandardError
      nil
    end

    # Plan #2 — boot-time log for the hotpath gate. Single-shot via the
    # class-level ivar so multi-worker boots don't fan into N identical
    # lines. Mirrors the log_io_uring_state_once pattern.
    def log_io_uring_hotpath_state_once
      return if Hyperion::Server.instance_variable_get(:@io_uring_hotpath_state_logged)
      return if @io_uring_hotpath_policy == :off

      Hyperion::Server.instance_variable_set(:@io_uring_hotpath_state_logged, true)
      runtime_logger.info do
        {
          message: 'io_uring hotpath state',
          policy: @io_uring_hotpath_policy,
          active: @io_uring_hotpath_active,
          kernel_ok: Hyperion::IOUring.kernel_supports_io_uring?,
          hotpath_supported: Hyperion::IOUring.respond_to?(:hotpath_supported?) &&
                              Hyperion::IOUring.hotpath_supported?
        }
      end
    rescue StandardError
      nil
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
        Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                       max_in_flight_per_conn: @max_in_flight_per_conn,
                       route_table: @route_table).serve(
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
          Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                         max_in_flight_per_conn: @max_in_flight_per_conn,
                         route_table: @route_table).serve(
                           socket, @app, max_request_read_seconds: @max_request_read_seconds
                         )
        end
      when :inline_h1_no_pool
        # `-t 0` on the TLS / async-wrap path. Rare config — debug /
        # spec aid (RFC §5 Q3 keeps `--async-io -t 0` valid). Counted
        # under its own bucket now (pre-1.7 it was un-counted).
        record_dispatch(mode)
        Connection.new(runtime: @explicit_runtime ? @runtime : nil,
                       max_in_flight_per_conn: @max_in_flight_per_conn,
                       route_table: @route_table).serve(
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

    # Bump the per-mode dispatch counter. 1.7→1.8 dual-emitted under the
    # legacy `:requests_async_dispatched` / `:requests_threadpool_dispatched`
    # keys for one full release cycle so operators could migrate Grafana
    # boards. 2.0 retires the legacy keys: only `:requests_dispatch_<mode>`
    # is emitted (one of `:requests_dispatch_threadpool_h1`,
    # `:requests_dispatch_inline_h1_no_pool`, `:requests_dispatch_tls_h1_inline`,
    # `:requests_dispatch_async_io_h1_inline`, `:requests_dispatch_tls_h2`).
    def record_dispatch(mode)
      runtime_metrics.increment(mode.metric_key)
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
        log_ktls_state_once(ssl)
        # 2.4-C: bump the per-worker active-kTLS-connections gauge if
        # the kernel module accepted this connection. Connection#serve
        # decrements on close.
        Hyperion::TLS.track_ktls_handshake!(ssl)
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
        log_ktls_state_once(ssl)
        Hyperion::TLS.track_ktls_handshake!(ssl)
        ssl
      else
        socket, = @server.accept
        socket
      end
    rescue OpenSSL::SSL::SSLError => e
      runtime_logger.warn { { message: 'tls handshake failed', error: e.message } }
      nil
    end

    # 2.2.0 (Phase 9): emit a single info-level log line per worker boot
    # capturing whether kTLS_TX engaged for this listener and which cipher
    # the first connection landed on. The cipher is per-connection (not
    # per-context), so we wait for the first successful handshake — at
    # that point either the kernel module is in use or the listener fell
    # back to userspace SSL_write. Subsequent connections skip the log
    # via `@ktls_logged`.
    def log_ktls_state_once(ssl)
      return if @ktls_logged

      @ktls_logged = true
      cipher_name = ssl.cipher && ssl.cipher.first rescue nil # rubocop:disable Style/RescueModifier
      ktls_active = Hyperion::TLS.ktls_active?(ssl)
      runtime_logger.info do
        {
          message: 'tls listener ready',
          ktls_policy: @tls_ktls,
          ktls_supported: Hyperion::TLS.ktls_supported?,
          ktls_active: ktls_active,
          cipher: cipher_name
        }
      end
    rescue StandardError
      # Logging is best-effort — never let a log line take down the
      # accept loop.
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
      apply_tcp_nodelay(target)
    rescue StandardError => e
      runtime_logger.warn do
        { message: 'failed to set read timeout', error: e.message, error_class: e.class.name }
      end
    end

    # 2.10-G — disable Nagle so HTTP/2 stream responses (and any small-payload
    # write that doesn't already coalesce head+body via the 2.0.1 Phase 8 path)
    # don't stall ~40 ms on the client's delayed-ACK timer.
    #
    # Symptom that surfaced this: 2.9-B Falcon comparison flagged Hyperion's
    # h2 max-latency stuck at ~40 ms across all rows; the 2.10-G bench showed
    # the **min** latency was 40.6 ms (every stream, not just the first).
    # That's the canonical Linux delayed-ACK + Nagle interaction —
    # protocol-http2 emits HEADERS and DATA as separate framer writes, the
    # first arrives at the peer alone, the peer waits 40 ms for an ACK so it
    # can piggyback, Hyperion's writer fiber waits because Nagle is buffering
    # the DATA frame until the HEADERS ACK lands. TCP_NODELAY breaks the
    # cycle — every framer write goes out immediately.
    #
    # Cost: a few extra TCP packets for chatty streams. Worth it; Falcon and
    # Agoo both set TCP_NODELAY.
    def apply_tcp_nodelay(target)
      target.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_NODELAY, 1)
    rescue StandardError
      # SSLSocket-without-#io, UDPSocket, or platform without TCP_NODELAY
      # (Windows-on-WSL2 occasionally). Silently skip — the socket still
      # works; only delayed-ACK behavior is affected.
    end
  end
end
