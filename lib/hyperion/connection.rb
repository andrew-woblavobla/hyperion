# frozen_string_literal: true

module Hyperion
  # Drives one TCP connection through its lifecycle:
  # read until headers complete + body, parse, dispatch via Rack adapter, write, close.
  # Phase 2 adds fiber scheduling and keep-alive; the public surface (#serve)
  # is stable.
  #
  # Phase 1 assumes blocking I/O: socket.read(N) blocks until N bytes or EOF, so
  # `break if chunk.nil? || chunk.empty?` correctly detects EOF in read_request.
  # Phase 2 (fiber scheduler) introduces non-blocking semantics where short reads
  # and EAGAIN must be distinguished from EOF — read_request will need to handle
  # IO::WaitReadable explicitly at that point.
  class Connection
    READ_CHUNK                      = 16 * 1024
    MAX_HEADER_BYTES                = 64 * 1024
    MAX_BODY_BYTES                  = 16 * 1024 * 1024 # 16 MB cap. Phase 5 introduces streaming bodies.
    HEADER_TERM                     = "\r\n\r\n"
    TIMEOUT_SENTINEL                = :__hyperion_read_timeout__
    DEADLINE_SENTINEL               = :__hyperion_request_deadline__
    OVERSIZED_BODY_SENTINEL         = :__hyperion_oversized_body__
    IDLE_KEEPALIVE_TIMEOUT_SECONDS  = 5
    # Phase 2b (1.7.1) — per-Connection pre-sized scratch buffer for the
    # read accumulator. Most HTTP/1.1 request lines + headers fit in a few
    # hundred bytes; 8 KiB covers ~99% of legitimate traffic without ever
    # re-allocating. We reuse the same String across keep-alive requests on
    # the same connection (clear between requests preserves capacity).
    # Requests larger than 8 KiB still parse correctly — `String#<<` grows
    # the underlying buffer transparently — they just pay the realloc the
    # first time, same as the pre-1.7.1 behaviour.
    INBUF_INITIAL_CAPACITY          = 8 * 1024

    # Pre-built canned 413 — body is small + plain text, connection forced
    # closed. Reused across every oversized-CL rejection so the DOS-defense
    # path stays allocation-free and never has to dip into ResponseWriter
    # (which would require a full Rack-style headers hash for an error
    # we can answer with frozen bytes).
    REJECT_413_PAYLOAD_TOO_LARGE = (+"HTTP/1.1 413 Payload Too Large\r\n" \
                                     "content-type: text/plain\r\n" \
                                     "content-length: 18\r\n" \
                                     "connection: close\r\n" \
                                     "\r\n" \
                                     "payload too large\n").freeze

    # 2.3-B per-conn fairness 503. Connection stays alive (no
    # `connection: close` here, no `Connection: close` to nginx) so
    # the upstream peer can retry the request in 1s — nginx-friendly.
    # Body is small + plain text + frozen so the reject path stays
    # allocation-free on the hot path.
    REJECT_503_PER_CONN_OVERLOAD = (+"HTTP/1.1 503 Service Unavailable\r\n" \
                                     "content-type: text/plain\r\n" \
                                     "content-length: 31\r\n" \
                                     "retry-after: 1\r\n" \
                                     "\r\n" \
                                     "per-connection overload, retry\n").freeze

    # Default parser is the C-extension `CParser` when the extension built;
    # otherwise we fall back to the pure-Ruby `Parser`. Evaluated each call
    # because Ruby evaluates default kwargs at call time.
    def self.default_parser
      defined?(::Hyperion::CParser) ? ::Hyperion::CParser.new : ::Hyperion::Parser.new
    end

    # 2.4-C — histogram bucket edges for the per-route request duration
    # histogram. Powers-of-5 spread covers 1ms to 10s, the realistic range
    # for any HTTP-served workload. Frozen so the same Array is reused
    # across every Connection (cheaper hist registration, no per-conn
    # allocation).
    REQUEST_DURATION_BUCKETS = [0.001, 0.005, 0.025, 0.1, 0.5, 2.5, 10.0].freeze

    REQUEST_DURATION_HISTOGRAM = :hyperion_request_duration_seconds

    # Pre-bucketed status-class strings. Lookup `STATUS_CLASS[status / 100]`
    # avoids `"#{n}xx"` interpolation per request.
    STATUS_CLASS = %w[0xx 1xx 2xx 3xx 4xx 5xx 6xx 7xx 8xx 9xx].each(&:freeze).freeze

    def initialize(parser: self.class.default_parser, writer: ResponseWriter.new, thread_pool: nil,
                   log_requests: nil, max_body_bytes: MAX_BODY_BYTES, runtime: nil,
                   max_in_flight_per_conn: nil, path_templater: nil, route_table: nil)
      @parser         = parser
      @writer         = writer
      @thread_pool    = thread_pool
      @max_body_bytes = max_body_bytes
      # 2.3-B: per-conn fairness cap. nil disables the check entirely
      # (the hot path stays branchless). Positive integer sets the
      # in-flight ceiling. The counter + dedup-warn flag live as ivars
      # so a single Connection's lifetime sees one warn at most, not
      # one per rejected request.
      @max_in_flight_per_conn = max_in_flight_per_conn
      @in_flight              = 0
      @in_flight_mutex        = Mutex.new if max_in_flight_per_conn
      @overload_warned        = false
      # 1.7.0: explicit Runtime injection. When the caller passes
      # `runtime:`, that runtime is the sole source of metrics + logger
      # for this connection — no implicit fallback to module-level
      # singletons. When omitted, fall back to `Runtime.default` so
      # legacy callers keep working untouched.
      #
      # We still cache the metrics/logger refs in ivars (vs reading
      # `runtime.metrics` per request) so the hot path doesn't pay a
      # method-dispatch per increment. Long-lived keep-alive connections
      # therefore see a Runtime swap only at construction — that's a
      # 1.7.0 limitation; 2.0 drops the singleton entirely and the
      # ivar cache becomes the only path.
      if runtime
        @runtime = runtime
        @metrics = runtime.metrics
        @logger  = runtime.logger
      else
        # No explicit runtime → keep the 1.6.x shape: ivars cache the
        # module-level accessors. This preserves stub seams used by
        # existing specs (`allow(Hyperion).to receive(:metrics)`) and
        # the `Hyperion.instance_variable_set(:@metrics, ...)` swap.
        @runtime = Hyperion::Runtime.default
        @metrics = Hyperion.metrics
        @logger  = Hyperion.logger
      end
      # Per-request access logging is ON by default (matches Puma+Rails
      # operator expectation). The hot path is optimised end-to-end: one
      # Process.clock_gettime per request, per-thread cached timestamp,
      # hand-rolled line builder, lock-free emit. Operator disables via
      # `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
      @log_requests = if log_requests.nil?
                        # Per-Connection override absent → consult the
                        # Runtime's logging config (1.7.0+) which falls
                        # through to `Hyperion.log_requests?` (env +
                        # default ON).
                        Hyperion.log_requests?
                      else
                        log_requests
                      end
      # 2.4-C: cache the path-templater ref at construction. Reading it
      # via Hyperion::Metrics.default_path_templater per request would
      # add a method dispatch + a memo branch on every observation — we
      # keep the existing pattern of caching boot-time refs as ivars so
      # the per-request observe stays a single Hash lookup.
      @path_templater = path_templater || Hyperion::Metrics.default_path_templater
      # 2.12-E — per-worker request counter label. Cached once per
      # Connection (Process.pid is process-constant — re-reading it per
      # request would allocate the to_s String every time the operator
      # asked Ruby for the symbol/label). Each Connection lives in
      # exactly one process, so the cache is tight and never stale.
      @worker_id = Process.pid.to_s
      # 2.13-A — pre-build the frozen single-element label tuple that
      # `tick_worker_request` would otherwise allocate every request
      # (`[@worker_id]` per call). Per-Connection caching is safe
      # because @worker_id is process-constant and the tuple is
      # frozen so consumers can't mutate the shared instance.
      @worker_id_label_tuple = [@worker_id].freeze
      # 2.13-A — register the labeled-counter family ONCE here (used
      # to fire on every `tick_worker_request` via an `unless`-flag
      # check; the early-return cost is small but real on the
      # 8000 r/s -c1 single-thread profile).  After this, the
      # request loop calls `increment_labeled_counter` directly.
      @metrics.ensure_worker_request_family_registered!
      # 2.10-D — direct-dispatch route table.  The hot-path lookup
      # is `@route_table&.lookup(method, path)` so the nil-default
      # case (no operator-registered direct routes — the
      # overwhelming majority of 2.x deployments) collapses to a
      # single `nil`-test before falling through to the Rack
      # adapter.  When `route_table:` is passed we honour the
      # explicit value (test seam / multi-tenant).  When omitted
      # AND the Hyperion::Server class is loaded, we resolve to
      # the process-wide singleton; ad-hoc Connection callers in
      # specs that don't load Server keep the nil fallback.
      @route_table = if route_table
                       route_table
                     elsif defined?(Hyperion::Server) && Hyperion::Server.respond_to?(:route_table)
                       Hyperion::Server.route_table
                     end
      register_request_duration_histogram!
    end

    # 2.4-C: register the per-route histogram family on this Connection's
    # metrics sink. Idempotent — `Metrics#register_histogram` no-ops on
    # re-registration with the same shape. Called once per Connection so
    # the histogram exists before the first observe.
    def register_request_duration_histogram!
      @metrics.register_histogram(
        REQUEST_DURATION_HISTOGRAM,
        buckets: REQUEST_DURATION_BUCKETS,
        label_keys: %w[method path status]
      )
    rescue StandardError
      # Histogram registration is observability — never block a Connection
      # from booting because the metrics sink misbehaved.
      nil
    end

    # 2.1.0 (WS-1): the connection itself caches the live socket so that
    # `hijack!` (called from inside the app, possibly on a thread-pool
    # worker thread) can reach back and yield it. `@hijacked` is the flag
    # that gates writer + cleanup behaviour after the app returns. Reset
    # at the top of each request iteration: a keep-alive client that does
    # NOT hijack on request N must still get the normal response path,
    # and a hijack on request N+1 should not be observed during request N.
    attr_reader :socket

    # 2.6-C — per-response dispatch-mode override.  Reset to `nil` at
    # the top of each request iteration; the Rack adapter sets this to
    # `:inline_blocking` when it auto-detects a static-file body
    # (`body.respond_to?(:to_path)`) or when the app explicitly opts in
    # via `env['hyperion.dispatch_mode'] = :inline_blocking`.  The
    # response-write path reads it back here in `serve` and forwards
    # the symbol to `ResponseWriter#write` so the writer can pick the
    # blocking-sendfile variant.
    #
    # The override is per-RESPONSE, NOT per-connection: the connection's
    # connection-wide dispatch mode (resolved at boot from `tls`,
    # `async_io`, `thread_count`, ALPN) stays whatever the operator
    # configured.  Only the response-write loop downgrades.
    attr_accessor :response_dispatch_mode

    def hijacked?
      @hijacked == true
    end

    # Called by the Rack app (via `env['rack.hijack'].call`). Flips the
    # `@hijacked` flag — Connection#serve checks this after `call_app`
    # returns and skips the writer + the ensure-block close. Returns the
    # raw socket IO so the app can speak any post-HTTP protocol on it.
    #
    # Idempotent: a subsequent call returns the same socket without
    # re-flipping (the flag is monotonic). Defensive — apps occasionally
    # do `io = env['rack.hijack'].call; io2 = env['rack.hijack'].call`
    # when chaining middleware.
    def hijack!
      @hijacked = true
      Hyperion.metrics.increment(:rack_hijacks) if defined?(Hyperion) && Hyperion.respond_to?(:metrics)
      @socket
    end

    # Bytes the connection had buffered past the parsed request boundary
    # at the moment we entered the dispatch step (pipelined keep-alive
    # carry, or — for an Upgrade — early bytes the client sent right
    # after the headers, before they could see our 101 response).
    # Returns a binary-encoded String (possibly empty). Captured fresh
    # per request inside `serve` *before* `call_app` so reads from the
    # socket past this point still go to the OS buffer; the carry is
    # the application's responsibility to drain.
    def hijack_buffered
      @hijack_buffered ||= +''
    end

    def serve(socket, app, max_request_read_seconds: 60)
      request_count = 0
      @socket = socket
      @hijacked = false
      # 2.6-D — sticky flag set after each `:inline_blocking` response
      # so the next request iteration on the same keep-alive
      # connection can bypass the per-conn fairness admission check
      # (and the bookkeeping it carries).  See the
      # `skip_per_conn_fairness` branch in the request loop below.
      @last_response_was_static_inline_blocking = false
      # Phase 2b (1.7.1): pre-size the read accumulator once per connection
      # and reuse it across keep-alive requests. `String#clear` between
      # requests preserves the underlying capacity, so subsequent appends
      # don't pay the realloc tax. Pre-1.7.1 allocated a fresh `+''` per
      # request; per-connection reuse is a strict win because the previous
      # request's carry-over bytes (pipelined input) are copied into this
      # same buffer at the bottom of the loop instead of into a new String.
      @inbuf ||= String.new(capacity: INBUF_INITIAL_CAPACITY, encoding: Encoding::ASCII_8BIT)
      peer_addr = peer_address(socket)
      @metrics.increment(:connections_accepted)
      @metrics.increment(:connections_active)
      loop do
        # Per-request wallclock deadline. Captured fresh for every request so
        # long-lived keep-alive sessions with many small requests don't
        # falsely trip after the cumulative budget elapses.
        request_started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) if max_request_read_seconds
        # 2.6-C — clear the per-response dispatch-mode override at the
        # top of every request iteration.  The Rack adapter sets it
        # *during* `app.call` (auto-detect on `to_path` body or
        # explicit `env['hyperion.dispatch_mode']` override) and the
        # writer reads it back; a keep-alive client whose request N
        # was static must NOT have request N+1 inherit the
        # `:inline_blocking` flag if request N+1's body is a streaming
        # response.
        @response_dispatch_mode = nil
        buffer = read_request(socket, @inbuf, deadline_started_at: request_started_clock,
                                              max_request_read_seconds: max_request_read_seconds,
                                              peer_addr: peer_addr)
        return unless buffer

        if buffer == TIMEOUT_SENTINEL
          # Idle timeout between keep-alive requests: close silently — the peer
          # never started a new request, so there's nothing to 408 about.
          @metrics.increment(:read_timeouts)
          return if request_count.positive?

          safe_write_error(socket, 408, 'Request Timeout')
          @metrics.increment_status(408)
          return
        end

        # Slowloris-style abort: deadline tripped during read. We've already
        # written the 408 (best-effort) inside read_request; close out here.
        return if buffer == DEADLINE_SENTINEL

        # DOS-defense: client declared a Content-Length larger than
        # max_body_bytes. We've already written the canned 413 + close inside
        # read_request, BEFORE reading any body bytes. Drop the connection.
        return if buffer == OVERSIZED_BODY_SENTINEL

        request, body_end = @parser.parse(buffer)
        # Carry over any pipelined trailing bytes for the next iteration. We
        # rewrite @inbuf in place — `replace` keeps the underlying capacity
        # allocation, so the next request starts with a warm 8 KiB buffer.
        #
        # 2.1.0 (WS-1): snapshot the carry BEFORE we collapse it back into
        # the read buffer. If the app full-hijacks this request, those
        # bytes are the application's responsibility (sent right after the
        # Upgrade headers, etc.) — exposed via `env['hyperion.hijack_buffered']`.
        # On the non-hijack hot path the snapshot is empty (no allocation
        # past the constant `EMPTY_BIN`) for keep-alive without pipelining.
        @hijack_buffered = if buffer.bytesize > body_end
                             buffer.byteslice(body_end,
                                              buffer.bytesize - body_end).b
                           else
                             EMPTY_BIN
                           end
        carry_into_inbuf!(buffer, body_end)
        request = enrich_with_peer(request, peer_addr) if peer_addr && request.peer_address.nil?

        @metrics.increment(:bytes_read, body_end)
        @metrics.increment(:requests_total)
        @metrics.increment(:requests_in_flight)
        # 2.12-E — per-worker request counter for the SO_REUSEPORT
        # load-balancing audit. Worker_id is the OS pid (matches the
        # 2.4-C `hyperion_io_uring_workers_active` convention). Single
        # location for every Ruby-side dispatch shape: regular Rack
        # via `dispatch_request`, direct dispatch via `dispatch_direct!`,
        # and the StaticEntry fast path via `dispatch_direct_static!`
        # all flow through this point in `serve`.
        #
        # 2.13-A — call `increment_labeled_counter` directly with the
        # pre-built frozen `[@worker_id]` tuple instead of going
        # through `tick_worker_request`. The wrapper allocates a
        # fresh `[label]` array AND calls `worker_id.to_s` per
        # request; cached tuple skips both. Family registration was
        # done once in the constructor (idempotent on the Metrics
        # instance) so the request loop is registration-free.
        @metrics.increment_labeled_counter(Hyperion::Metrics::REQUESTS_DISPATCH_TOTAL,
                                           @worker_id_label_tuple)
        # 2.4-C: capture start time for the per-route duration histogram.
        # Same Process.clock_gettime that the access-log path was already
        # paying — at default-ON log_requests the second call here is
        # avoided (we reuse `request_started_at`).
        request_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # 2.10-D — direct-dispatch fast path.  Bypasses the Rack
        # adapter entirely (no env-hash build, no middleware chain,
        # no body-iteration overhead) on routes the operator
        # registered via `Hyperion::Server.handle(:GET, '/path',
        # handler)` or `.handle_static(...)`.  Lifecycle hooks
        # still fire so trace instrumentation works regardless of
        # dispatch shape.
        #
        # Lookup is O(1) (two Hash#[] hits) and the nil-default
        # case (no direct routes registered — the overwhelming
        # majority of deployments) collapses to one nil-test plus
        # one Hash#[] miss before falling through to the regular
        # path; cost on the regular path is < 1 us.
        if @route_table && (direct_handler = @route_table.lookup(request.method, request.path))
          dispatch_direct!(socket, request, direct_handler, request_started_at, peer_addr)
          request_count += 1
          break unless should_keep_alive_after_direct?(request)

          set_idle_timeout(socket)
          next
        end
        # 2.3-B per-conn fairness gate. Returns true when the slot was
        # reserved (caller must release in ensure), false when the cap
        # was hit and a 503 was emitted. nil cap → admit always (hot
        # path stays branchless).
        #
        # 2.6-D — skip the fairness check entirely on connections whose
        # previous response was `:inline_blocking` (auto-detected
        # static-file traffic).  Static streams are dominated by the
        # write phase, not concurrent app.call invocations, so the
        # per-conn fairness cap is dead weight here — its purpose is
        # to throttle dynamic-route concurrency on a single keep-alive
        # connection.  Static-asset connections (CDN origins, signed-
        # download responders) typically run a long sequence of
        # `to_path` responses; once the first one auto-detects, the
        # remaining requests skip the admit / release / metric trio.
        # The flag flips back to false the moment a non-static
        # response lands on the same connection.
        skip_per_conn_fairness = @last_response_was_static_inline_blocking
        if @max_in_flight_per_conn && !skip_per_conn_fairness && !per_conn_admit!(socket, peer_addr)
          @metrics.decrement(:requests_in_flight)
          request_count += 1
          # Don't close — keep the conn alive so the upstream peer can
          # retry after the in-flight request drains. Skip writer +
          # logging (we wrote a canned response above) and proceed to
          # the next iteration's read.
          set_idle_timeout(socket)
          next
        end
        begin
          status, headers, body = call_app(app, request)
        ensure
          @metrics.decrement(:requests_in_flight)
          per_conn_release! if @max_in_flight_per_conn && !skip_per_conn_fairness
        end

        # 2.1.0 (WS-1): if the app called `env['rack.hijack'].call` during
        # `call_app`, the connection has handed the socket over. We MUST
        # NOT write a response (the app is now driving the wire) and we
        # MUST NOT close the socket (the app owns it). The status/headers/body
        # tuple from the app is ignored on this path — Rack 3 spec calls this
        # out explicitly. Drop out of the per-request loop; the ensure block
        # will skip socket close because of @hijacked.
        if @hijacked
          @logger.debug do
            { message: 'rack hijack', method: request.method, path: request.path, peer_addr: peer_addr }
          end
          # Drop body if the app still returned one — apps occasionally
          # return [-1, {}, []] but some return real arrays out of habit.
          # We don't iterate or close the body; iterating would let it
          # write to the (now app-owned) socket via env['rack.input'] etc.
          # body.close is the one safe call (frees temp files), best-effort.
          body.close if body.respond_to?(:close)
          return
        end

        keep_alive = should_keep_alive?(request, status, headers)
        # 2.6-C — pass the per-response dispatch-mode override to the
        # writer.  Default `nil` means "use the writer's default
        # (fiber-yielding sendfile / userspace copy)".  Only
        # `:inline_blocking` currently flips the writer onto a
        # different code path (the Puma-style serial-per-thread
        # blocking-sendfile loop).  Forward-compatible — future per-
        # response dispatch modes plug in here without changing the
        # call-site shape.
        @writer.write(socket, status, headers, body, keep_alive: keep_alive,
                                                     dispatch_mode: @response_dispatch_mode)
        # 2.6-D — record whether this response engaged
        # `:inline_blocking` so the next request iteration can skip
        # the per-conn fairness admission check (see the
        # `skip_per_conn_fairness` branch above).  Sticky on
        # consecutive static responses; resets on the first non-
        # static response back on the same conn.
        @last_response_was_static_inline_blocking =
          @response_dispatch_mode == :inline_blocking
        @metrics.increment_status(status)
        log_request(request, status, request_started_at) if @log_requests
        # 2.4-C: per-route duration histogram observation. Templating the
        # path (e.g. `/users/123` → `/users/:id`) keeps cardinality
        # bounded; the templater itself is LRU-cached so the cost on a
        # repeated path is one Hash#[] + one Hash re-insert. We swallow
        # any exception — observability must never block a response.
        observe_request_duration(request, status, request_started_at)
        request_count += 1

        return unless keep_alive

        # Idle wait between requests: don't hold a fiber forever on a quiet conn.
        set_idle_timeout(socket)
      end
    rescue ParseError => e
      @metrics.increment(:parse_errors)
      @logger.warn { { message: 'parse error', error: e.message, error_class: e.class.name } }
      safe_write_error(socket, 400, 'Bad Request')
      @metrics.increment_status(400)
    rescue UnsupportedError => e
      @logger.warn { { message: 'unsupported request', error: e.message, error_class: e.class.name } }
      safe_write_error(socket, 501, 'Not Implemented')
      @metrics.increment_status(501)
    rescue StandardError => e
      @metrics.increment(:app_errors)
      @logger.error do
        { message: 'unhandled in connection', error: e.message, error_class: e.class.name }
      end
    ensure
      @metrics.decrement(:connections_active)
      # Flush any buffered access-log lines for this thread before letting
      # the connection go idle. Otherwise a low-traffic worker would hold
      # logs in its per-thread buffer indefinitely.
      @logger.flush_access_buffer if @log_requests && @logger.respond_to?(:flush_access_buffer)
      # 2.1.0 (WS-1): when the app full-hijacked the socket, ownership has
      # transferred. Hyperion MUST NOT close — the app may still be reading
      # from / writing to the wire (e.g. an open WebSocket) long after this
      # fiber exits. Skip the close branch entirely; the app is the sole
      # closer from this point on.
      unless @hijacked
        # 2.4-C: drop the per-worker kTLS gauge for this socket if it
        # was tracked at handshake time. No-op for plain TCP and for
        # TLS-without-kTLS sockets.
        Hyperion::TLS.untrack_ktls_handshake!(socket) if defined?(Hyperion::TLS)
        begin
          socket.close unless socket.closed?
        rescue StandardError
          # Already failing; swallow close errors so we don't mask the real cause.
        end
      end
    end

    private

    # 2.10-D — direct-dispatch handler invocation.  Bypasses the
    # Rack adapter (`Adapter::Rack.call` builds the env hash, walks
    # the middleware chain, runs WS handshake validation — none of
    # which a direct route needs).  Fires the runtime's lifecycle
    # hooks so NewRelic / AppSignal / OpenTelemetry instrumentation
    # is mode-agnostic; `env` is `nil` on direct routes (no env was
    # built) — observers documented to expect a nil env on this
    # branch.
    #
    # Two write shapes:
    #
    #   * `RouteTable::StaticEntry` — pre-built response buffer
    #     from `handle_static`.  The hot path: ONE socket.write of
    #     the full HTTP/1.1 response (status + Content-Type +
    #     Content-Length + body), zero header build, zero body
    #     iteration.
    #   * Plain `[status, headers, body]` Rack tuple — the
    #     standard ResponseWriter writes it via the existing
    #     code path.  Slower than StaticEntry but still skips the
    #     entire Rack env construction.
    def dispatch_direct!(socket, request, handler, request_started_at, peer_addr)
      @metrics.increment(:bytes_read, 0) # no-op — bytes already counted upstream
      @metrics.increment(:requests_in_flight)
      @metrics.increment(:direct_route_hits)

      # 2.10-F — C-ext fast path for prebuilt static responses.  When
      # the matched route is a `StaticEntry`, the prebuilt response
      # bytes are already registered with `Hyperion::Http::PageCache`
      # under the route path; `PageCache.serve_request` does the
      # whole thing — hash lookup, snapshot under the C lock, GVL-
      # released write — without invoking the handler closure or
      # building a `[status, headers, body]` tuple.  Lifecycle hooks
      # still fire (with `env=nil`, matching the 2.10-D contract) so
      # APM observers see direct-route requests regardless of whether
      # the wire write happens in Ruby or C.
      if handler.is_a?(::Hyperion::Server::RouteTable::StaticEntry)
        return dispatch_direct_static!(socket, request, handler, request_started_at)
      end

      response = nil
      error    = nil
      begin
        @runtime.fire_request_start(request, nil) if @runtime.has_request_hooks?
        response = handler.call(request)
      rescue StandardError => e
        error = e
        @metrics.increment(:app_errors)
        @logger.error do
          {
            message: 'direct route raised',
            method: request.method,
            path: request.path,
            error: e.message,
            error_class: e.class.name
          }
        end
        response = [500, { 'content-type' => 'text/plain' }, ['Internal Server Error']]
      ensure
        @metrics.decrement(:requests_in_flight)
      end

      status = write_direct_response(socket, response)

      if @runtime.has_request_hooks?
        @runtime.fire_request_end(request, nil, error.nil? ? response : nil, error)
      end

      @metrics.increment_status(status)
      log_request(request, status, request_started_at) if @log_requests
      observe_request_duration(request, status, request_started_at)
      status
    rescue StandardError => e
      # Lifecycle-hook failure is logged inside fire_request_*; this
      # rescue catches socket write errors so the request loop sees
      # the problem and can decide whether to keep the connection
      # alive (we just close on any exception here — it's the safe
      # default).
      @logger.error do
        { message: 'direct dispatch write failed',
          peer_addr: peer_addr,
          error: e.message,
          error_class: e.class.name }
      end
      500
    end

    # 2.10-F — StaticEntry-only dispatch path.  Calls `PageCache.serve_request`
    # which performs the full lookup + snapshot + write entirely in C
    # (with the GVL released across the write syscall).  On `:miss`
    # (e.g. the C cache was cleared between registration and request,
    # or the request method is something we didn't pre-register —
    # POST against a GET route would have already missed the route
    # table, so this branch is paranoia) we fall back to the Ruby
    # `socket.write` path — same bytes, slightly more overhead.
    #
    # Lifecycle hooks (`Runtime#on_request_start` / `#on_request_end`)
    # MUST still fire here so APM observers see direct-route hits.
    # `env` is `nil` on direct routes, matching the 2.10-D contract.
    def dispatch_direct_static!(socket, request, entry, request_started_at)
      error = nil
      begin
        @runtime.fire_request_start(request, nil) if @runtime.has_request_hooks?
        bytes_written = serve_static_entry(socket, request, entry)
        # We always emit a 200 from a StaticEntry (that's what
        # `Server.handle_static` builds).  Track the bytes for
        # operators tracking egress, mirroring what ResponseWriter
        # does on the regular path.
        @metrics.increment(:bytes_written, bytes_written)
      rescue StandardError => e
        error = e
        @metrics.increment(:app_errors)
        @logger.error do
          { message: 'static direct route write failed',
            method: request.method,
            path: request.path,
            error: e.message,
            error_class: e.class.name }
        end
      ensure
        @metrics.decrement(:requests_in_flight)
      end

      if @runtime.has_request_hooks?
        @runtime.fire_request_end(request, nil, error.nil? ? entry : nil, error)
      end

      status = error ? 500 : 200
      @metrics.increment_status(status)
      log_request(request, status, request_started_at) if @log_requests
      observe_request_duration(request, status, request_started_at)
      status
    end

    # 2.10-F — call into the C ext when available, else fall back to
    # the 2.10-D Ruby `socket.write` path.  Returns bytes written.
    def serve_static_entry(socket, request, entry)
      if defined?(::Hyperion::Http::PageCache) &&
         ::Hyperion::Http::PageCache.respond_to?(:serve_request)
        result = ::Hyperion::Http::PageCache.serve_request(socket, request.method, entry.path)
        return result.last if result.is_a?(Array) && result.first == :ok
      end
      # Fallback: Ruby write of the full buffer (or headers-only on HEAD).
      bytes = if request.method == 'HEAD' && entry.headers_bytesize < entry.buffer.bytesize
                entry.buffer.byteslice(0, entry.headers_bytesize)
              else
                entry.buffer
              end
      socket.write(bytes)
    end

    # 2.10-D — write a direct-route response.  Returns the status
    # code that was written (so `dispatch_direct!` can bump the
    # status counter without re-parsing the response).  Two
    # shapes — the StaticEntry one-shot write is the agoo-style
    # hot path; the Rack-tuple branch lets handlers compute a
    # response per-request without paying for env construction.
    def write_direct_response(socket, response)
      if response.is_a?(::Hyperion::Server::RouteTable::StaticEntry)
        # 2.10-F note: the StaticEntry-from-handler path (a Rack-style
        # handler that returns a StaticEntry, not a route registered
        # via `Server.handle_static`) lands here.  Keep the 2.10-D
        # one-shot Ruby write — these are NOT in the C cache.
        socket.write(response.response_bytes)
        return 200
      end

      status, headers, body = response
      @writer.write(socket, status, headers, body, keep_alive: true)
      status
    end

    # 2.10-D — keep-alive decision for direct-dispatch responses.
    # Direct routes don't get the full
    # `Connection: close` header inspection that Rack tuples
    # receive (StaticEntry has its headers baked in; we trust the
    # operator); we just honour the request-side `Connection`
    # header.  HTTP/1.1 default-keepalive, HTTP/1.0 default-close.
    def should_keep_alive_after_direct?(request)
      conn_request = request.header('connection')&.downcase
      case request.http_version
      when 'HTTP/1.1' then conn_request != 'close'
      when 'HTTP/1.0' then conn_request == 'keep-alive'
      else false
      end
    end

    # 2.3-B per-conn fairness admit. Mutex-guarded compare-and-bump so
    # async-io fibers / pipelined requests on the same OS thread don't
    # race the counter. Returns true when the slot was reserved, false
    # when the cap was hit (caller writes 503 + Retry-After). The 503
    # path bumps a metric, emits a deduplicated warn, and writes a
    # canned response — all best-effort; a peer that's gone away is
    # silently swallowed.
    def per_conn_admit!(socket, peer_addr)
      cap = @max_in_flight_per_conn
      admitted = @in_flight_mutex.synchronize do
        if @in_flight >= cap
          false
        else
          @in_flight += 1
          true
        end
      end
      return true if admitted

      @metrics.increment(:per_conn_overload_rejects)
      # 2.4-C: also feed the labeled counter so operators can break
      # rejections down per worker (one row per worker_id at scrape
      # time) without losing the legacy unlabeled counter for back-
      # compat dashboards.
      @metrics.increment_labeled_counter(:hyperion_per_conn_rejections_total,
                                         [Process.pid.to_s])
      @metrics.increment_status(503)
      unless @overload_warned
        @logger.warn do
          { message: 'per-connection in-flight cap hit, returning 503 + Retry-After',
            remote_addr: peer_addr, cap: cap, in_flight: cap }
        end
        @overload_warned = true
      end
      begin
        socket.write(REJECT_503_PER_CONN_OVERLOAD)
      rescue StandardError
        # Peer may have already gone — nothing to do.
      end
      false
    end

    def per_conn_release!
      @in_flight_mutex.synchronize { @in_flight -= 1 if @in_flight.positive? }
    end

    # Phase 2b: collapse @inbuf in place to retain only the carry-over (any
    # bytes past the parsed request boundary, used for keep-alive pipelining).
    # Operates byte-wise so the underlying capacity allocation stays put —
    # `String#replace` with `byteslice` would allocate a fresh substring AND
    # then memcpy back. Splice-with-empty keeps everything in the original
    # buffer.
    EMPTY_BIN = String.new('', encoding: Encoding::ASCII_8BIT).freeze
    def carry_into_inbuf!(buffer, body_end)
      total = buffer.bytesize
      if body_end >= total
        buffer.clear
      else
        # Splice the [0, body_end) prefix away. Ruby's String#[]=(start, len, "")
        # performs an in-place shift of the remaining bytes — no new String
        # allocation, capacity preserved.
        buffer[0, body_end] = EMPTY_BIN
      end
    end

    # Route Rack dispatch through the thread pool when one was injected,
    # otherwise run inline on the current fiber. Inline keeps the test path
    # simple (no extra threads spun up for unit specs) and provides a
    # debugging escape hatch via `Server#thread_count: 0`.
    #
    # 2.1.0 (WS-1) passes `self` as the hijack target so the env hash gets
    # a working `rack.hijack?` + `rack.hijack` proc. Both modes (inline and
    # thread-pool) plumb the connection through — the app can hijack on
    # either path; the connection's `@hijacked` ivar is the source of
    # truth that's read back here in `serve` after `call_app` returns,
    # regardless of which thread evaluated the proc.
    def call_app(app, request)
      if @thread_pool && @thread_pool.respond_to?(:call_with_connection)
        @thread_pool.call_with_connection(app, request, self)
      elsif @thread_pool
        # Older ThreadPool (or stubs) without the WS-1 helper — fall
        # back to the no-hijack path. Keeps third-party pool plug-ins
        # working at the cost of disabling hijack on those paths.
        @thread_pool.call(app, request)
      else
        # 2.5-C — thread the per-conn Runtime through so request
        # lifecycle hooks fire against the correct (per-server, in
        # multi-tenant deployments) observer registry. `@runtime` is
        # always set by the initializer (either an explicit injection
        # or `Runtime.default`), so this is a non-nil pass-through.
        Adapter::Rack.call(app, request, connection: self, runtime: @runtime)
      end
    end

    # Extract the peer IP from the underlying socket, if available.
    # Works for TCPSocket and OpenSSL::SSL::SSLSocket (via #io). UNIX sockets
    # return AF_UNIX with an empty path — we return nil there so the adapter
    # falls back to its localhost default.
    def peer_address(socket)
      raw = socket.respond_to?(:io) ? socket.io : socket
      return nil unless raw.respond_to?(:peeraddr)

      addr = raw.peeraddr
      ip = addr[3] || addr[2]
      return nil if ip.nil? || ip.to_s.empty?

      ip
    rescue StandardError
      nil
    end

    # Request is frozen — to enrich it we build a new value object with the
    # peer address copied in. Cheap on the fast path because we only do this
    # once per connection (peer_addr is captured before the request loop).
    def enrich_with_peer(request, peer_addr)
      Hyperion::Request.new(
        method: request.method,
        path: request.path,
        query_string: request.query_string,
        http_version: request.http_version,
        headers: request.headers,
        body: request.body,
        peer_address: peer_addr
      )
    end

    # 2.13-A — Rack 3 (the version Hyperion advertises in
    # `env['rack.version']`) requires response header keys to be
    # lowercase Strings (Rack 3 spec §6.4 "Headers must be a Hash;
    # the header keys must be lowercase Strings"). Pre-2.13-A this
    # method scanned the whole Hash via `headers.find` + per-key
    # `k.to_s.downcase` to find the Connection header — that's an
    # O(N) walk + N transient string allocations on EVERY response
    # (and most responses don't carry a Connection header at all,
    # so the loop ran to completion every time).
    #
    # The new path is a single Hash lookup. Apps that violate the
    # Rack 3 spec by returning mixed-case keys (some legacy gems
    # still do; less common in 2026) lose the Connection-close
    # signal and stay on keep-alive — that's a benign degradation
    # (the connection is reused; the next request still goes through
    # request-side `Connection: close` parsing) and the fix is to
    # update the app to spec.
    CONNECTION_HEADER_KEY_DOWNCASE = 'connection'

    def should_keep_alive?(request, _status, headers)
      # App-emitted Connection: close wins. Rack-3 fast path: O(1)
      # Hash lookup; non-Hash headers (Array-of-pairs, etc.) fall
      # back to a single allocation-free scan.
      conn_response_value = if headers.is_a?(Hash)
                              headers[CONNECTION_HEADER_KEY_DOWNCASE]
                            else
                              find_connection_header_array(headers)
                            end
      return false if conn_response_value && conn_response_value.to_s.downcase == 'close'

      # Request-side Connection header.
      conn_request = request.header('connection')&.downcase

      case request.http_version
      when 'HTTP/1.1'
        conn_request != 'close'
      when 'HTTP/1.0'
        conn_request == 'keep-alive'
      else
        false
      end
    end

    # 2.13-A — non-Hash headers fallback (Array of [key, value] pairs).
    # Rack 3 mandates Hash, but legacy code occasionally returns an
    # Array; we walk it case-sensitively because Rack-3 lowercase is
    # part of the contract for non-Hash returns too. Apps emitting
    # `'Connection'`-cased keys via Array form fall through to no-
    # match and stay on keep-alive — same benign degradation as the
    # Hash branch.
    def find_connection_header_array(headers)
      headers.each do |pair|
        next unless pair.is_a?(Array) && pair.length >= 2
        return pair[1] if pair[0] == CONNECTION_HEADER_KEY_DOWNCASE
      end
      nil
    end

    def set_idle_timeout(socket)
      socket.timeout = IDLE_KEEPALIVE_TIMEOUT_SECONDS if socket.respond_to?(:timeout=)
    rescue StandardError
      # Best-effort; if the socket type doesn't support it, read_chunk's
      # IO.select fallback still gives us a deadline via read_timeout_for.
    end

    # Reads one complete request off the socket. `carry` is bytes already
    # buffered from the previous request's trailing read (keep-alive
    # pipelining). Returns the full buffer (with any trailing pipelined
    # bytes intact); the parser's returned end_offset tells the caller
    # where this request ends. On EOF returns nil; on read timeout returns
    # TIMEOUT_SENTINEL; on per-request wallclock deadline trip returns
    # DEADLINE_SENTINEL (and emits a best-effort 408 + close).
    def read_request(socket, carry = +'', deadline_started_at: nil, max_request_read_seconds: nil,
                     peer_addr: nil)
      buffer = carry
      until buffer.include?(HEADER_TERM)
        if deadline_exceeded?(deadline_started_at, max_request_read_seconds)
          return abort_for_deadline(socket, deadline_started_at, peer_addr)
        end

        chunk = read_chunk(socket)
        return chunk if chunk.nil? || chunk == TIMEOUT_SENTINEL
        return nil if chunk.empty?

        buffer << chunk
        raise ParseError, 'header section too large' if buffer.bytesize > MAX_HEADER_BYTES
      end

      header_end = buffer.index(HEADER_TERM) + HEADER_TERM.bytesize
      headers_part = buffer.byteslice(0, header_end)

      if chunked?(headers_part)
        until chunked_body_complete?(buffer, header_end)
          raise ParseError, 'chunked body exceeds limit' if buffer.bytesize - header_end > MAX_BODY_BYTES
          if deadline_exceeded?(deadline_started_at, max_request_read_seconds)
            return abort_for_deadline(socket, deadline_started_at, peer_addr)
          end

          chunk = read_chunk(socket)
          break if chunk.nil? || chunk.empty? || chunk == TIMEOUT_SENTINEL

          buffer << chunk
        end
      else
        content_length = headers_part[/^content-length:\s*(\d+)/i, 1].to_i
        # DOS-defense: cap declared Content-Length at max_body_bytes BEFORE
        # we touch the socket again. An attacker advertising
        # `Content-Length: 99999999999` should not get us to allocate a
        # multi-GB read buffer or sit in the read loop draining their
        # body. The pure-int comparison itself is bounded — Ruby's `to_i`
        # on the regex capture stops at the first non-digit, so even an
        # adversarial header value can't blow up here. Negative or
        # malformed values fall through to the parser (which raises
        # ParseError → 400) so existing behaviour is preserved.
        return abort_for_oversized_body(socket, content_length, peer_addr) if content_length > @max_body_bytes

        while buffer.bytesize < header_end + content_length
          if deadline_exceeded?(deadline_started_at, max_request_read_seconds)
            return abort_for_deadline(socket, deadline_started_at, peer_addr)
          end

          chunk = read_chunk(socket)
          break if chunk.nil? || chunk.empty? || chunk == TIMEOUT_SENTINEL

          buffer << chunk
        end
      end

      buffer
    end

    # nil-disabled or budget-untripped → false. Otherwise the wallclock cap
    # has been exceeded and the caller should abort.
    def deadline_exceeded?(started_at, max_seconds)
      return false unless started_at && max_seconds

      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) > max_seconds
    end

    # Slowloris fallback: log a structured warn, bump :slow_request_aborts,
    # write a best-effort 408, and let the caller close the socket. We don't
    # wait on the 408 write — a dribbling client may never read it, and
    # that's the failure mode we're protecting against anyway.
    def abort_for_deadline(socket, started_at, peer_addr)
      elapsed = started_at ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(3) : nil
      @metrics.increment(:slow_request_aborts)
      @logger.warn do
        { message: 'request read deadline exceeded', remote_addr: peer_addr, elapsed_seconds: elapsed }
      end
      begin
        socket.write("HTTP/1.1 408 Request Timeout\r\nconnection: close\r\ncontent-length: 0\r\n\r\n")
      rescue StandardError
        # Peer may have already gone — nothing to do.
      end
      @metrics.increment_status(408)
      DEADLINE_SENTINEL
    end

    # DOS-defense fallback: declared Content-Length exceeds the configured
    # max_body_bytes. Emit a canned 413 + close BEFORE reading any body
    # bytes off the socket — that's the whole point of the cap. Best-effort
    # write so a peer that's already gone away doesn't trip an exception
    # we'd swallow in the rescue clause anyway.
    def abort_for_oversized_body(socket, declared_length, peer_addr)
      @metrics.increment(:oversized_body_rejects)
      @logger.warn do
        {
          message: 'rejected oversized Content-Length',
          remote_addr: peer_addr,
          declared_length: declared_length,
          max_body_bytes: @max_body_bytes
        }
      end
      begin
        socket.write(REJECT_413_PAYLOAD_TOO_LARGE)
      rescue StandardError
        # Peer may have already gone — nothing to do.
      end
      @metrics.increment_status(413)
      OVERSIZED_BODY_SENTINEL
    end

    def chunked?(headers_part)
      headers_part.match?(/^transfer-encoding:[ \t]*[^\r\n]*chunked\b/i)
    end

    # Walks chunked framing in `buffer` starting at `body_start` and
    # returns true once the final 0-sized chunk (and trailer terminator)
    # is fully buffered. The C extension folds the size-line scan + hex
    # decode + chunk advance into a single tight loop with no per-iteration
    # Ruby allocation; the pure-Ruby fallback below preserves the original
    # semantics for environments where the C extension didn't build.
    def chunked_body_complete?(buffer, body_start)
      if self.class.c_chunked_available?
        ::Hyperion::CParser.chunked_body_complete?(buffer, body_start).first
      else
        chunked_body_complete_ruby?(buffer, body_start)
      end
    end

    # Whether Hyperion::CParser.chunked_body_complete? is available. Probed
    # lazily at first use; memoised in a class-level ivar to keep the
    # per-request hot path branchless.
    def self.c_chunked_available?
      return @c_chunked_available unless @c_chunked_available.nil?

      @c_chunked_available = defined?(::Hyperion::CParser) &&
                             ::Hyperion::CParser.respond_to?(:chunked_body_complete?)
    end

    def chunked_body_complete_ruby?(buffer, body_start)
      cursor = body_start
      loop do
        line_end = buffer.index("\r\n", cursor)
        return false unless line_end

        size_line = buffer.byteslice(cursor, line_end - cursor)
        size_token = size_line.split(';').first.to_s.strip
        return false if size_token.empty?

        size = size_token.to_i(16)
        cursor = line_end + 2

        if size.zero?
          loop do
            nl = buffer.index("\r\n", cursor)
            return false unless nl
            return true if nl == cursor

            cursor = nl + 2
          end
        end

        return false if buffer.bytesize < cursor + size + 2

        cursor += size + 2
      end
    end

    # Read up to READ_CHUNK bytes, returning whatever's available. Unlike
    # IO#read(N) — which blocks until N bytes or EOF — read_nonblock returns
    # as soon as any data arrives, which is what we need for live HTTP
    # clients that send a small request and then wait for a response on
    # the same socket without closing the write half.
    #
    # Phase 8 perf fix: try read_nonblock FIRST, only fall through to IO.select
    # if no data is buffered. wrk and other benchmarkers pre-buffer the entire
    # request so the first readpartial succeeds and we skip the select syscall
    # entirely. The IO.select fallback still gives us a deterministic deadline
    # against stalled peers (SO_RCVTIMEO and IO#timeout= don't reliably trip
    # readpartial on Ruby 3.3).
    def read_chunk(socket)
      result = socket.read_nonblock(READ_CHUNK, exception: false)
      return result if result.is_a?(String) # hot path: data was buffered, return immediately
      return nil if result.nil?             # EOF

      # :wait_readable — fall back to IO.select with a deadline.
      timeout = read_timeout_for(socket)
      ready, = IO.select([socket], nil, nil, timeout)
      return TIMEOUT_SENTINEL if ready.nil?

      retry_read_nonblock(socket)
    rescue EOFError
      nil
    rescue Errno::EAGAIN, Errno::EWOULDBLOCK, IO::TimeoutError
      TIMEOUT_SENTINEL
    end

    def retry_read_nonblock(socket)
      socket.read_nonblock(READ_CHUNK)
    rescue IO::WaitReadable
      TIMEOUT_SENTINEL
    rescue EOFError
      nil
    end

    def read_timeout_for(socket)
      socket.respond_to?(:timeout) && socket.timeout || 30
    rescue StandardError
      30
    end

    def safe_write_error(socket, status, body_text)
      @writer.write(socket, status, { 'content-type' => 'text/plain' }, [body_text])
    rescue StandardError => e
      @logger.error do
        { message: 'failed to write error response', error: e.message, error_class: e.class.name }
      end
    end

    # Emit one structured access-log line per response. Default ON; operator
    # disables via `--no-log-requests`. Routes through Logger#access which
    # uses a hand-rolled single-interpolation builder + per-thread cached
    # timestamp + lock-free emit (no mutex, no flush) — at 16 threads the
    # default-ON path runs within a few percent of the disabled path.
    def log_request(request, status, started_at)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
      @logger.access(
        request.method,
        request.path,
        request.query_string,
        status,
        duration_ms,
        request.peer_address,
        request.http_version
      )
    end

    # 2.4-C — observe one sample on the per-route request-duration
    # histogram. Best-effort: a misbehaving templater or sink degrades
    # silently to no observation. The label tuple Array is fresh per
    # call (3 small Strings) — that's the only allocation cost the
    # observation imposes on the response path. Histogram observation
    # itself reuses the per-(name, labels_tuple) accumulator after the
    # first samples for a given templated path, so steady-state per-
    # route observations are zero-allocation past the tuple Array.
    def observe_request_duration(request, status, started_at)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      method   = request.method
      template = @path_templater.template(request.path)
      class_ = STATUS_CLASS[status / 100] || STATUS_CLASS[0]
      @metrics.observe_histogram(
        REQUEST_DURATION_HISTOGRAM,
        duration,
        [method, template, class_]
      )
    rescue StandardError
      nil
    end
  end
end
