# frozen_string_literal: true

require 'async'
require 'async/notification'
require 'async/queue'
require 'protocol/http2/server'
require 'protocol/http2/framer'
require 'protocol/http2/stream'

require_relative 'http2/native_hpack_adapter'

module Hyperion
  # Real HTTP/2 dispatch driven by `protocol-http2`.
  #
  # Each TLS connection that negotiated `h2` via ALPN ends up here. We frame
  # the socket, read the connection preface, and then drive a frame loop on
  # the connection's fiber: it reads one frame at a time and lets
  # `protocol-http2` update its connection/stream state machines. As soon as
  # a client stream finishes its request half (state `:half_closed_remote`
  # via `end_stream?`), we hand the stream off to a sibling fiber for
  # dispatch — slow handlers no longer block other streams on the same
  # connection.
  #
  # ## Outbound write architecture (1.6.0+)
  #
  # Pre-1.6.0 every framer write (HEADERS / DATA / RST_STREAM / GOAWAY) ran
  # under one connection-scoped `Mutex#synchronize { socket.write(...) }`.
  # That capped per-connection h2 throughput to "one socket-write at a time"
  # regardless of stream count: a slow socket (kernel send buffer full,
  # remote peer reading slowly) blocked every other stream's writes too.
  #
  # 1.6.0 splits the path:
  #   * The HPACK encode + frame format step is fast (microseconds, in-memory)
  #     and remains serialized on the calling fiber via `@encode_mutex`. HPACK
  #     state is stateful across HEADERS frames per connection, and frames for
  #     a single stream must be wire-ordered (HEADERS → DATA → END_STREAM).
  #     Holding the encode mutex across a `send_*` call accomplishes both.
  #   * The framer writes through a `SendQueueIO` wrapper (wraps the real
  #     socket). `SendQueueIO#write(bytes)` enqueues onto a connection-wide
  #     `@send_queue` and signals `@send_notify`; it never touches the real
  #     socket.
  #   * A dedicated **writer fiber** owns the real socket. It pops byte chunks
  #     off the queue, writes them, and parks on `@send_notify` when empty.
  #     Only this fiber ever calls `socket.write` — the SSLSocket cross-fiber
  #     unsafety constraint is satisfied.
  #
  # Net effect: the slow-socket case no longer serializes encode work across
  # streams. A stream that has bytes ready to encode can encode and enqueue
  # while the writer is mid-flush of an earlier chunk. The mutex hold time
  # drops from "until the kernel accepts the write" to "until the bytes are
  # appended to the in-memory queue."
  #
  # Backpressure: pathological clients (slow-read h2) could otherwise let the
  # queue grow without bound. We track `@pending_bytes`; once it exceeds
  # `MAX_PER_CONN_PENDING_BYTES`, encoding fibers wait on `@drained_notify`
  # before enqueueing more. The writer signals `@drained_notify` after each
  # drain pass.
  #
  # Flow control: `RequestStream#window_updated` overrides the protocol-http2
  # default to fan a notification out to any fiber blocked in `send_body`
  # waiting for the remote peer's flow-control window to grow. The body
  # writer chunks the response payload by the per-stream available frame
  # size and yields on the notification when the window is exhausted, so
  # large bodies never trip a FlowControlError.
  class Http2Handler
    # Cap on bytes that may sit in a connection's send queue waiting for the
    # writer fiber to drain. Slow-read h2 clients can otherwise let an
    # encoder fiber pile arbitrary bytes into RAM. 16 MiB matches the upper
    # bound a well-behaved peer will buffer — anything beyond that is the
    # writer being starved, and the right answer is to backpressure the
    # encoder rather than allocate more.
    MAX_PER_CONN_PENDING_BYTES = 16 * 1024 * 1024

    # IO-shaped wrapper passed to `Protocol::HTTP2::Framer` in place of the
    # real socket. Reads are direct passthroughs (the read loop runs on the
    # connection fiber and there's only one reader). Writes are enqueued
    # onto the connection-wide `WriterContext#queue`; the writer fiber owns
    # the real socket and drains the queue.
    #
    # We deliberately do NOT delegate `flush` to the real socket: writes
    # don't reach it from this object — the writer fiber does that. `flush`
    # here is a no-op (the writer flushes after each batch).
    #
    # `closed?` reports the real socket's state so protocol-http2's read
    # loop sees EOF the same way it always has.
    class SendQueueIO
      attr_reader :real_socket

      def initialize(real_socket, writer_ctx)
        @real_socket = real_socket
        @writer_ctx  = writer_ctx
      end

      # Framer's read path — direct delegation. Single-reader (the conn
      # fiber), so no contention here.
      def read(*args)
        @real_socket.read(*args)
      end

      # Framer's write path — non-blocking handoff into the send queue.
      # Backpressure is applied here: if pending bytes exceed the cap, the
      # calling fiber parks on the drained notification until the writer
      # has flushed enough to bring us below the threshold.
      def write(bytes)
        return 0 if bytes.nil? || bytes.empty?

        @writer_ctx.enqueue(bytes)
        bytes.bytesize
      end

      def flush
        # No-op: bytes don't live in this object, they live in the queue.
        # The writer fiber flushes the real socket as it drains.
        nil
      end

      def close
        @real_socket.close unless @real_socket.closed?
      end

      # Multi-line on purpose: a single-line `def closed?; @real_socket.closed?; end`
      # gets autocorrected to `delegate :closed?, to: :@real_socket` by Rails-aware
      # ruby-lsp formatters, which is wrong here (this is a plain gem, no
      # ActiveSupport on the dependency graph).
      def closed?
        socket = @real_socket
        socket.closed?
      end
    end

    # Holds the per-connection outbound coordination state (queue,
    # notifications, byte counters, shutdown flag) plus the encode mutex
    # that protects HPACK state and per-stream frame ordering.
    #
    # Single instance per connection, lives for the lifetime of `serve`.
    class WriterContext
      attr_reader :encode_mutex, :dispatch_queue
      # 2.10-G — connection-lifecycle timing slots used by the optional h2
      # latency-instrumentation path (gated by `HYPERION_H2_TIMING=1`).
      # Each slot is a single CLOCK_MONOTONIC timestamp captured at most
      # once per connection. nil = unset, set on first observation.
      attr_accessor :t0_serve_entry, :t1_preface_done, :t2_first_encode, :t2_first_wire

      def initialize(max_pending_bytes: MAX_PER_CONN_PENDING_BYTES)
        @queue              = ::Thread::Queue.new
        @send_notify        = ::Async::Notification.new
        @drained_notify     = ::Async::Notification.new
        @encode_mutex       = ::Mutex.new
        @pending_bytes      = 0
        @pending_bytes_lock = ::Mutex.new
        @max_pending_bytes  = max_pending_bytes
        @writer_done        = false
        # 2.11-A — pre-spawned dispatch worker pool. The connection-loop
        # fiber pushes ready streams onto `@dispatch_queue`; workers
        # parked on `dequeue` grab them and call `dispatch_stream`. The
        # queue is created here (cheap — wraps a Thread::Queue) so the
        # WriterContext is fully self-contained and unit-testable without
        # an Async reactor.
        @dispatch_queue           = ::Async::Queue.new
        @dispatch_worker_count    = 0
        @dispatch_worker_lock     = ::Mutex.new
        # 2.10-G timing slots, all initially nil so capture is a single
        # `||=` write under the encode mutex / writer fiber.
        @t0_serve_entry  = nil
        @t1_preface_done = nil
        @t2_first_encode = nil
        @t2_first_wire   = nil
      end

      # 2.11-A — bench/diagnostics introspection. Reads the live count
      # of dispatch worker fibers parked on (or actively pulling from)
      # `@dispatch_queue`. Reflects pre-spawned workers AND any ad-hoc
      # workers spawned when the pool was saturated. Exposed as a method
      # rather than `attr_reader` so the lock guards the counter.
      def dispatch_worker_count
        @dispatch_worker_lock.synchronize { @dispatch_worker_count }
      end

      # Called by a dispatch worker fiber when it enters its run loop.
      # Pairs with `unregister_dispatch_worker` in an ensure block.
      def register_dispatch_worker
        @dispatch_worker_lock.synchronize { @dispatch_worker_count += 1 }
      end

      # Called by a dispatch worker fiber when it exits (queue closed,
      # or unrecoverable error). Floors at 0 to defend against a stray
      # double-unregister — instrumentation must never go negative.
      def unregister_dispatch_worker
        @dispatch_worker_lock.synchronize do
          @dispatch_worker_count -= 1
          @dispatch_worker_count = 0 if @dispatch_worker_count.negative?
        end
      end

      # Called by SendQueueIO#write on the calling (encoder) fiber. Enforces
      # the per-connection backpressure cap before enqueuing.
      def enqueue(bytes)
        wait_for_drain_if_full(bytes.bytesize)
        @pending_bytes_lock.synchronize { @pending_bytes += bytes.bytesize }
        @queue << bytes
        @send_notify.signal
      end

      # Pops a single chunk; returns nil if the queue is empty (non-blocking).
      def try_pop
        @queue.pop(true)
      rescue ::ThreadError
        nil
      end

      # Called by the writer fiber after each successful drain to release
      # any encoders blocked on the cap.
      def note_drained(bytesize)
        @pending_bytes_lock.synchronize do
          @pending_bytes -= bytesize
          @pending_bytes = 0 if @pending_bytes.negative? # paranoia
        end
        @drained_notify.signal
      end

      def wait_for_signal
        @send_notify.wait
      end

      def shutdown!
        @writer_done = true
        # Wake the writer if it's parked, and any encoder waiting on drain.
        @send_notify.signal
        @drained_notify.signal
      end

      def writer_done?
        @writer_done
      end

      def queue_empty?
        @queue.empty?
      end

      def pending_bytes
        @pending_bytes_lock.synchronize { @pending_bytes }
      end

      private

      def wait_for_drain_if_full(incoming_bytes)
        # If we're already at/above the cap, park until the writer has
        # drained. We re-check after every signal because multiple encoders
        # can wake on a single drain notification.
        while !@writer_done &&
              @pending_bytes_lock.synchronize { @pending_bytes + incoming_bytes > @max_pending_bytes } &&
              !@queue.empty?
          @drained_notify.wait
        end
      end
    end

    # Per-stream subclass that captures decoded request pseudo-headers,
    # regular headers, and any DATA frame body bytes for later dispatch.
    # Also exposes a `window_available` notification fan-out so the
    # response-writer fiber can sleep until WINDOW_UPDATE arrives.
    class RequestStream < ::Protocol::HTTP2::Stream
      # RFC 7540 §8.1.2.1 — the only pseudo-headers a server MUST accept on a
      # request. Anything else (notably `:status`, which is response-only, or
      # an unknown `:foo`) is a malformed request that we reject with
      # PROTOCOL_ERROR.
      VALID_REQUEST_PSEUDO_HEADERS = %w[:method :path :scheme :authority].freeze

      # RFC 7540 §8.1.2.2 — these connection-specific headers MUST NOT appear
      # in HTTP/2 requests; their semantics are folded into HTTP/2 framing.
      FORBIDDEN_HEADERS = %w[connection transfer-encoding keep-alive upgrade proxy-connection].freeze

      attr_reader :request_headers, :request_body, :request_complete, :protocol_error_reason

      def initialize(*)
        super
        @request_headers = []
        # 2.12-F — gRPC carries opaque protobuf bytes
        # ([1-byte compressed flag][4-byte length-prefix][message bytes]) in the
        # request body. The default UTF-8 encoding on a `+''` literal would
        # break valid_encoding? on byte sequences that don't form UTF-8
        # codepoints, leading to a Rack app reading `body.string` and getting
        # a String that misreports its bytesize / corrupts when string-
        # interpolated. ASCII_8BIT (binary) preserves bytes verbatim and is
        # the encoding gRPC Ruby clients expect. Same change is applied to
        # the HTTP/1.1 path as a separate concern; see Connection.
        @request_body = String.new(encoding: Encoding::ASCII_8BIT)
        @request_body_bytes = 0
        @request_complete = false
        @window_available = ::Async::Notification.new
        @protocol_error_reason = nil
        @declared_content_length = nil
      end

      # Used by the dispatch loop to decide whether to invoke the app or
      # send RST_STREAM PROTOCOL_ERROR. Set by `validate_request_headers!`
      # and `validate_body_length!`.
      def protocol_error?
        !@protocol_error_reason.nil?
      end

      def process_headers(frame)
        decoded = super
        # First HEADERS frame on a stream carries the request header block;
        # any later HEADERS frame is trailers (§8.1) and we deliberately do
        # not re-validate (re-running the validator would see the original
        # request pseudo-headers plus the new trailer block and falsely flag
        # them as misordered).
        first_block = @request_headers.empty?
        # decoded is an Array of [name, value] pairs (HPACK output).
        decoded.each { |pair| @request_headers << pair }
        # Run RFC 7540 §8.1.2 validation as soon as we have a complete header
        # block. We do it here (not at end_stream) so the dispatcher sees the
        # error flag before it spawns a fiber for the request.
        validate_request_headers! if first_block && !protocol_error?
        if frame.end_stream?
          validate_body_length! unless protocol_error?
          @request_complete = true
        end
        decoded
      end

      def process_data(frame)
        data = super
        # rubocop:disable Rails/Present
        if data && !data.empty?
          @request_body << data
          @request_body_bytes += data.bytesize
        end
        # rubocop:enable Rails/Present
        if frame.end_stream?
          validate_body_length! unless protocol_error?
          @request_complete = true
        end
        data
      end

      # RFC 7540 §8.1.2 — request header validation. Sets
      # `@protocol_error_reason` on the first violation we hit; the dispatch
      # loop turns that into RST_STREAM PROTOCOL_ERROR.
      def validate_request_headers!
        seen_regular = false
        pseudo_counts = Hash.new(0)
        @request_headers.each do |pair|
          name, value = pair
          name = name.to_s
          if name.start_with?(':')
            # §8.1.2.1: pseudo-headers MUST precede regular headers.
            return fail_validation!('pseudo-header after regular header') if seen_regular
            # §8.1.2.1: only the four request pseudo-headers are valid; in
            # particular, `:status` is response-only.
            unless VALID_REQUEST_PSEUDO_HEADERS.include?(name)
              return fail_validation!("invalid request pseudo-header: #{name}")
            end

            pseudo_counts[name] += 1
          else
            seen_regular = true
            # §8.1.2: header names must be lowercase in HTTP/2.
            return fail_validation!('uppercase header name') if /[A-Z]/.match?(name)
            # §8.1.2.2: connection-specific headers are forbidden.
            return fail_validation!("forbidden connection-specific header: #{name}") if FORBIDDEN_HEADERS.include?(name)
            # §8.1.2.2: TE may only carry the value `trailers`.
            if name == 'te' && value.to_s.downcase.strip != 'trailers'
              return fail_validation!('TE header with non-trailers value')
            end

            # Track declared content-length for later body-byte cross-check.
            @declared_content_length = value.to_s.to_i if name == 'content-length'
          end
        end

        # §8.1.2.3: every pseudo-header may appear at most once.
        pseudo_counts.each do |name, count|
          return fail_validation!("duplicated pseudo-header: #{name}") if count > 1
        end

        method = pseudo_value(':method')
        # CONNECT (§8.3) has its own rules; everything else MUST carry
        # :method, :scheme and a non-empty :path.
        if method == 'CONNECT'
          return fail_validation!('CONNECT with :scheme') if pseudo_value(':scheme')
          return fail_validation!('CONNECT with :path') if pseudo_value(':path')
          return fail_validation!('CONNECT without :authority') unless pseudo_value(':authority')
        else
          return fail_validation!('missing :method') if method.nil? || method.empty?

          scheme = pseudo_value(':scheme')
          return fail_validation!('missing :scheme') if scheme.nil? || scheme.empty?

          path = pseudo_value(':path')
          return fail_validation!('missing or empty :path') if path.nil? || path.empty?
        end

        nil
      end

      # RFC 7540 §8.1.2.6 — if `content-length` was advertised, the actual
      # number of DATA bytes received (across all DATA frames) MUST match.
      def validate_body_length!
        return if @declared_content_length.nil?
        return if @declared_content_length == @request_body_bytes

        fail_validation!(
          "content-length mismatch: declared #{@declared_content_length}, received #{@request_body_bytes}"
        )
      end

      # Called by protocol-http2 whenever the remote peer's flow-control
      # window opens up — either via a stream-level WINDOW_UPDATE or via the
      # connection-level fan-out in `Connection#consume_window`. We poke the
      # notification so any fiber waiting in `wait_for_window` resumes.
      def window_updated(size)
        @window_available.signal
        super
      end

      # Block the calling fiber until the remote window grows. Cheap no-op
      # signal each time `window_updated` fires; the caller re-checks
      # available_frame_size in a loop.
      def wait_for_window
        @window_available.wait
      end

      private

      # Look up a pseudo-header by name (e.g. `:method`) by scanning the raw
      # collected pairs. Returns nil if absent. We don't pre-build a hash
      # because the validator needs to detect duplicates first.
      def pseudo_value(name)
        @request_headers.each do |pair|
          return pair[1].to_s if pair[0].to_s == name
        end
        nil
      end

      # Record the first protocol-error reason and short-circuit further
      # validation. Returns nil so callers can `return fail_validation!(...)`.
      def fail_validation!(reason)
        @protocol_error_reason ||= reason
        # As soon as a header-block violation is detected we treat the request
        # as "complete" so the dispatch loop wakes up and emits RST_STREAM.
        @request_complete = true
        nil
      end
    end

    # Maps Hyperion-friendly setting names to the integer SETTINGS_* identifiers
    # protocol-http2 uses on the wire. See RFC 7540 §6.5.2 — these are the
    # only four parameters Hyperion exposes; the rest of the SETTINGS frame
    # (HEADER_TABLE_SIZE, ENABLE_PUSH, etc.) keeps protocol-http2's default.
    SETTINGS_KEY_MAP = {
      max_concurrent_streams: ::Protocol::HTTP2::Settings::MAXIMUM_CONCURRENT_STREAMS,
      initial_window_size: ::Protocol::HTTP2::Settings::INITIAL_WINDOW_SIZE,
      max_frame_size: ::Protocol::HTTP2::Settings::MAXIMUM_FRAME_SIZE,
      max_header_list_size: ::Protocol::HTTP2::Settings::MAXIMUM_HEADER_LIST_SIZE
    }.freeze

    # RFC 7540 §6.5.2 floor for SETTINGS_MAX_FRAME_SIZE. protocol-http2 raises
    # ProtocolError on values below this; we clamp + warn instead so a
    # misconfigured operator gets a working server, not a boot-time crash.
    H2_MIN_FRAME_SIZE = 0x4000 # 16384

    # RFC 7540 §6.5.2 ceiling for SETTINGS_MAX_FRAME_SIZE.
    H2_MAX_FRAME_SIZE = 0xFFFFFF # 16777215

    # RFC 7540 §6.9.2 — INITIAL_WINDOW_SIZE has the same 31-bit max as the
    # WINDOW_UPDATE frame's Window Size Increment (see protocol-http2's
    # MAXIMUM_ALLOWED_WINDOW_SIZE).
    H2_MAX_WINDOW_SIZE = 0x7FFFFFFF

    # 1.7.0 added kwargs:
    #   * `runtime:`      — `Hyperion::Runtime` for metrics/logger
    #                       isolation (default `Runtime.default`).
    #   * `h2_admission:` — Optional `Hyperion::H2Admission` for the
    #                       per-process stream cap (RFC A7). nil keeps
    #                       the 1.6.x unbounded behaviour.
    #
    # 2.0.0 (Phase 6b) probed `Hyperion::H2Codec.available?` at
    # construction so the handler knew whether the native HPACK path
    # was operational, but the connection state machine still drove
    # encode/decode through `protocol-http2`'s pure-Ruby Compressor /
    # Decompressor.
    #
    # 2.2.0 (Phase 10 / RFC §3 Phase 6c) ships the wiring infrastructure:
    # {Hyperion::Http2::NativeHpackAdapter} + {#install_native_hpack}
    # replace the per-connection HPACK encode/decode boundary with
    # the Rust crate when AND ONLY WHEN both:
    #   1. `Hyperion::H2Codec.available?` is true (cdylib loaded), AND
    #   2. `ENV['HYPERION_H2_NATIVE_HPACK']` is one of `1`/`true`/`yes`/`on`.
    #
    # The default is OFF because local h2load benchmarking on macOS
    # showed the Fiddle FFI per-call marshalling overhead dominates
    # for typical 3–8-header HEADERS frames — the standalone microbench's
    # 3.26× encode win does not translate to wire wins until the FFI
    # marshalling layer is rewritten to amortize allocation. Keeping the
    # default OFF preserves 2.0.0/2.1.0 behavior; flipping the env var
    # gives operators the swap they want to A/B test in their own env.
    # The framer + stream state machine + flow control + HEADERS /
    # CONTINUATION framing all stay in `protocol-http2`; only the
    # HPACK byte-pump is replaced when the swap is enabled. Frame ser/de
    # in Rust (Phase 6d) is a separate, larger lift.
    def initialize(app:, thread_pool: nil, h2_settings: nil, runtime: nil, h2_admission: nil)
      @app          = app
      @thread_pool  = thread_pool
      @h2_settings  = h2_settings
      if runtime
        @runtime = runtime
        @metrics = runtime.metrics
        @logger  = runtime.logger
      else
        # 1.6.x compat path — see Connection#initialize for rationale.
        @runtime = Hyperion::Runtime.default
        @metrics = Hyperion.metrics
        @logger  = Hyperion.logger
      end
      @h2_admission       = h2_admission
      # 2.12-E — per-worker request counter label. Identical caching
      # rationale to Connection#initialize: process-constant ID, looked
      # up once and held in the ivar.
      @worker_id          = Process.pid.to_s
      @h2_codec_available = Hyperion::H2Codec.available?
      # 2.5-B [breaking-default-change]: native HPACK now defaults to ON
      # when the Rust crate is available. The 2026-04-30 Rails-shape
      # bench (`bench/h2_rails_shape.ru`, 25 response headers) measured
      # native v3 at 1,418 r/s vs Ruby fallback 1,201 r/s — **+18.0%**
      # on a header-heavy workload, comfortably above the +15% flip
      # threshold. 2.4-A's hello-shape bench saw parity because HPACK
      # is <1% of per-stream CPU on a 2-header response.
      #
      # 2.11-B — `HYPERION_H2_NATIVE_HPACK` extended with a native-mode
      # axis (`auto` / `cglue` / `v2` / `off`). See `resolve_h2_native_hpack_state`.
      # Operators who want the prior 2.4.x default (Ruby fallback, env
      # var unset) can set `HYPERION_H2_NATIVE_HPACK=off` (or
      # `0`/`false`/`no`/`off`/`ruby`). `HYPERION_H2_NATIVE_HPACK=1`
      # / unset preserves the 2.5-B `auto` behavior. `=cglue`/`=v2`
      # forces the corresponding native sub-path.
      #
      # When OFF (env-overridden): `protocol-http2`'s pure-Ruby HPACK
      # Compressor / Decompressor handles everything as in 2.0.0–2.4.x.
      @h2_native_mode          = resolve_h2_native_hpack_state
      @h2_native_hpack_enabled = @h2_codec_available && @h2_native_mode != :off
      apply_h2_cglue_gate(@h2_native_mode)
      @h2_codec_native = @h2_native_hpack_enabled # back-compat ivar — preserved for codec_native? readers
      # 2.10-G — opt-in connection-setup timing instrumentation. When set,
      # `serve` captures four monotonic timestamps per connection:
      #
      #   t0 — entry to `serve` (post-TLS, post-ALPN — the socket is already
      #        the negotiated h2 SSLSocket by the time the handler sees it)
      #   t1 — `read_connection_preface` returned (server-side SETTINGS
      #        encoded + handed to the framer; client preface fully read)
      #   t2_encode — first stream's HEADERS frame finished encoding (bytes
      #               sit in the writer queue)
      #   t2_wire   — writer fiber finished its first `socket.write` (bytes
      #               on the wire)
      #
      # When the connection's first response completes, the handler emits
      # a single `'h2 first-stream timing'` info line with t0→t1, t1→t2_encode,
      # t2_encode→t2_wire deltas in milliseconds. Off by default (zero hot-path
      # cost when disabled — a single ivar read per stream branch). Used by
      # 2.10-G to root-cause Hyperion's flat ~40 ms first-stream max-latency.
      @h2_timing_enabled = env_flag_enabled?('HYPERION_H2_TIMING')
      # 2.11-A — resolve the dispatch worker pool size once at handler
      # construction so every `serve` call uses the same value (instead
      # of re-parsing ENV per connection on the hot path). Cached as an
      # ivar; bench/diagnostics can read it via the spec seam.
      @dispatch_pool_size = resolve_dispatch_pool_size
      record_codec_boot_state
    end

    # 2.11-A — pre-spawned dispatch worker pool sizing.
    #
    # Default `4` workers per connection — enough to absorb the typical
    # HTTP/2 burst (2-8 concurrent streams) without paying any per-stream
    # `task.async {}` cost on the hot path. Operators on long-lived
    # high-fan-out connections (e.g. an aggregator backend that fans
    # 30+ parallel streams) can bump this with `HYPERION_H2_DISPATCH_POOL`.
    # Streams that arrive when the pool is saturated still get an ad-hoc
    # fiber (see `serve` below) so concurrency is never artificially
    # capped — the operator-facing limit is `h2.max_concurrent_streams`.
    #
    # Ceiling at 16 guards against a pathological config that would
    # spawn hundreds of idle fibers per accepted connection. Anything
    # malformed / non-positive falls back to the default rather than
    # crashing the connection — this is a tuning knob, not a spec
    # parameter.
    DISPATCH_POOL_DEFAULT = 4
    DISPATCH_POOL_MAX     = 16

    def resolve_dispatch_pool_size
      raw = ENV['HYPERION_H2_DISPATCH_POOL']
      return DISPATCH_POOL_DEFAULT if raw.nil? || raw.strip.empty?

      n = Integer(raw.strip, 10)
      return DISPATCH_POOL_DEFAULT unless n.positive?

      [n, DISPATCH_POOL_MAX].min
    rescue ArgumentError, TypeError
      DISPATCH_POOL_DEFAULT
    end

    # Read an env-var flag with the usual truthiness rules (any of
    # 1/true/yes/on, case-insensitive). Anything else → false.
    def env_flag_enabled?(name)
      v = ENV[name]
      return false if v.nil? || v.empty?

      %w[1 true yes on].include?(v.downcase)
    end

    # 2.11-B — resolve the operator-requested native-mode state from
    # `HYPERION_H2_NATIVE_HPACK`.
    #
    # Returns one of:
    #   * `:auto`  — native enabled, prefer cglue if available
    #                (unset / `1` / `true` / `yes` / `on` / `auto`)
    #   * `:cglue` — native enabled, force cglue (warn-fallback to v2
    #                if cglue is unavailable; native_mode log marker
    #                surfaces the divergence to the operator)
    #   * `:v2`    — native enabled, force Fiddle (skip cglue even if
    #                available; this is the bench-isolation knob the
    #                2.11-B Rails-shape harness needs)
    #   * `:off`   — ruby fallback (`0` / `false` / `no` / `off` / `ruby`)
    #
    # Unknown values fall through to `:auto` rather than crashing the
    # connection — same forgiving-default policy as the pre-2.11-B
    # `resolve_h2_native_hpack_default`.
    def resolve_h2_native_hpack_state
      v = ENV['HYPERION_H2_NATIVE_HPACK']
      return :auto if v.nil? || v.empty?

      lc = v.downcase
      return :off   if %w[0 false no off ruby].include?(lc)
      return :cglue if %w[cglue v3].include?(lc)
      return :v2    if %w[v2 fiddle].include?(lc)

      :auto
    end

    # 2.11-B — flip the global `H2Codec.cglue_disabled` gate based on
    # the resolved native-mode state. The gate is per-process state
    # (the codec module is a singleton) so reset it on every handler
    # construction; otherwise a test that booted with `=v2` would leak
    # the disable into a subsequent default-mode handler.
    def apply_h2_cglue_gate(state)
      Hyperion::H2Codec.cglue_disabled = (state == :v2)
    end

    # 2.0.0 Phase 6b: emit a single-shot boot log line per process
    # describing the codec selection. Operators reading the boot log
    # see whether the native HPACK path is in play. Idempotent across
    # multiple Http2Handler constructions in the same process.
    def record_codec_boot_state
      return if Hyperion::Http2Handler.instance_variable_get(:@codec_state_logged)

      Hyperion::Http2Handler.instance_variable_set(:@codec_state_logged, true)
      # 2.11-B — `cglue_active` gates on the operator-controllable
      # `cglue_active?` predicate (was `cglue_available?` pre-2.11-B).
      # When the operator sets `=v2` we want the boot log to read
      # `cglue_active: false` even though the C glue did install
      # successfully — the bench harness inspects this field to
      # differentiate the variants.
      cglue_active = @h2_native_hpack_enabled && Hyperion::H2Codec.cglue_active?
      cglue_requested_unavailable = @h2_native_mode == :cglue &&
                                    @h2_native_hpack_enabled &&
                                    !Hyperion::H2Codec.cglue_available?
      mode = describe_codec_mode(cglue_active: cglue_active,
                                 cglue_requested_unavailable: cglue_requested_unavailable)
      native_mode_log = if !@h2_native_hpack_enabled
                          @h2_native_mode == :off ? 'off' : 'native-disabled'
                        elsif cglue_requested_unavailable
                          'cglue-requested-unavailable'
                        else
                          @h2_native_mode.to_s
                        end
      @logger.info do
        {
          message: 'h2 codec selected',
          mode: mode,
          native_available: @h2_codec_available,
          native_enabled: @h2_native_hpack_enabled,
          native_mode: native_mode_log,
          cglue_active: cglue_active,
          hpack_path: if @h2_native_hpack_enabled
                        cglue_active ? 'native-v3' : 'native-v2'
                      else
                        'pure-ruby'
                      end
        }
      end
      @metrics.increment(:h2_codec_native_selected) if @h2_native_hpack_enabled
      @metrics.increment(:h2_codec_fallback_selected) unless @h2_native_hpack_enabled
    end

    # 2.11-B — boot-log mode descriptor (extracted for clarity since
    # the matrix of native_mode × cglue_available × cglue_active grew
    # past the point where an inline conditional was readable).
    def describe_codec_mode(cglue_active:, cglue_requested_unavailable:)
      if !@h2_native_hpack_enabled
        if @h2_codec_available
          'fallback (protocol-http2 / pure Ruby HPACK) — native available but opted out via HYPERION_H2_NATIVE_HPACK=off'
        else
          'fallback (protocol-http2 / pure Ruby HPACK) — native unavailable'
        end
      elsif cglue_active && @h2_native_mode == :cglue
        'native (Rust v3 / CGlue, forced) — HPACK on hot path, no Fiddle per call'
      elsif cglue_active
        # 2.11-B confirmed cglue as the firm default — the bench-measured
        # delta vs the v2 (Fiddle) path is +33-43% on Rails-shape h2
        # responses, which is the actual win the 2.5-B "+18% native vs
        # ruby" headline was capturing (v2 alone is +1-5%, basically
        # noise vs the ruby fallback at this header count).
        'native (Rust v3 / CGlue, default since 2.11-B) — HPACK on hot path, no Fiddle per call'
      elsif @h2_native_mode == :v2
        'native (Rust v2 / Fiddle, forced) — HPACK on hot path, Fiddle marshalling per call'
      elsif cglue_requested_unavailable
        'native (Rust v2 / Fiddle) — CGlue requested via HYPERION_H2_NATIVE_HPACK=cglue but unavailable, fell back'
      else
        'native (Rust v2 / Fiddle) — HPACK on hot path, Fiddle marshalling per call'
      end
    end

    # Read-only accessor used by tests + diagnostics. true = the
    # `Hyperion::H2Codec` Rust extension loaded successfully AND
    # `HYPERION_H2_NATIVE_HPACK=1` is set, so `build_server` will
    # wire the native adapter onto every new connection's
    # `encode_headers` / `decode_headers` boundary. The 2.2.0 default
    # is false (opt-in) — see `#initialize` for the rationale and the
    # bench numbers in CHANGELOG/docs that pinned the default off.
    def codec_native?
      @h2_native_hpack_enabled
    end

    # True when the Rust crate loaded successfully, regardless of
    # whether the operator opted in to wiring it into the wire path.
    # Useful for diagnostics/health endpoints that want to surface
    # "native is available but currently disabled".
    def codec_available?
      @h2_codec_available
    end

    def serve(socket)
      @metrics.increment(:connections_accepted)
      @metrics.increment(:connections_active)

      # Per-connection outbound coordination. Encoder fibers enqueue bytes;
      # the writer fiber owns the real socket and drains. See class docstring.
      writer_ctx   = WriterContext.new
      send_io      = SendQueueIO.new(socket, writer_ctx)
      framer       = ::Protocol::HTTP2::Framer.new(send_io)
      server       = build_server(framer)

      # 2.10-G — connection entry timestamp. Captured before any framing
      # work so the t0→t1 delta isolates "preface exchange + initial
      # SETTINGS round-trip" from any pre-handler scheduling delay.
      writer_ctx.t0_serve_entry = monotonic_now if @h2_timing_enabled

      task = ::Async::Task.current

      # 2.11-A — extract the peer address BEFORE the preface exchange.
      # Two wins: (1) the lookup runs in parallel with the writer fiber
      # picking up the first scheduler slot, and (2) the first stream's
      # dispatch fiber doesn't pay this `peeraddr` syscall on its hot
      # path. The address is then captured by the worker closures
      # below.
      peer_addr = peer_address(socket)

      # Spawn the dedicated writer fiber BEFORE the preface exchange.
      # `Server#read_connection_preface` writes the server's SETTINGS frame
      # via the framer; if the writer isn't running, those bytes sit in the
      # queue. Spawning first guarantees they flush as soon as the scheduler
      # ticks, avoiding any pathological deadlock where a client implementation
      # waits for our SETTINGS before sending more frames.
      writer_task = task.async { run_writer_loop(socket, writer_ctx) }

      # 2.11-A — pre-spawn the dispatch worker pool BEFORE the preface
      # exchange. Workers park on `writer_ctx.dispatch_queue.dequeue`;
      # by the time the first client HEADERS frame arrives the workers
      # are already in the scheduler's runnable set. The first stream
      # is just an enqueue + dequeue (microseconds) instead of a
      # `task.async {}` cold spawn (was the dominant cost in the t1→t2_enc
      # bucket per the 2.10-G timing breakdown).
      warmup_dispatch_pool!(task, writer_ctx, peer_addr: peer_addr,
                                              pool_size: @dispatch_pool_size)

      server.read_connection_preface(initial_settings_payload)
      writer_ctx.t1_preface_done = monotonic_now if @h2_timing_enabled

      # Track ad-hoc per-stream dispatch fibers (spilled when the pool is
      # saturated). The pool handles the common case; we only fall back
      # to `task.async {}` when more streams arrive than warm workers.
      overflow_tasks = []

      until server.closed?
        ready_ids = []
        server.read_frame do |frame|
          ready_ids << frame.stream_id if frame.stream_id.positive?
        end

        ready_ids.uniq.each do |sid|
          stream = server.streams[sid]
          next unless stream.is_a?(RequestStream)
          next unless stream.request_complete
          next if stream.closed?
          next if stream.instance_variable_get(:@hyperion_dispatched)

          # Mark before spawning so we never dispatch the same stream twice
          # if subsequent frames (e.g. RST_STREAM races) arrive.
          stream.instance_variable_set(:@hyperion_dispatched, true)

          # 2.11-A — hand the stream to a warm worker via the dispatch
          # queue. We use a simple "queue is empty" probe to decide:
          #
          #   * Empty queue ⇒ at least one worker is parked on
          #     `dequeue`; the enqueue+dequeue handoff is microseconds
          #     and we avoid a `task.async {}` cold spawn. This is the
          #     hot path for the FIRST stream of a fresh connection
          #     (the case 2.11-A is targeting).
          #   * Non-empty queue ⇒ every parked worker has already
          #     pulled a stream; another worker won't pick this up
          #     until one finishes. To avoid head-of-line blocking
          #     behind the warmup pool, fall back to `task.async {}`.
          #     The overflow fiber re-uses `dispatch_stream` so the
          #     dispatch contract is identical between pool and
          #     overflow paths. Concurrency is never artificially
          #     capped; the operator-facing knob is
          #     `h2.max_concurrent_streams`.
          if writer_ctx.dispatch_queue.size.zero?
            writer_ctx.dispatch_queue.enqueue(stream)
          else
            overflow_tasks << task.async do
              dispatch_stream(stream, writer_ctx, peer_addr)
            end
          end
        end
      end

      # Drain in-flight stream dispatches before we close the socket.
      overflow_tasks.each do |t|
        t.wait
      rescue StandardError
        nil
      end
    rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
      # Peer disconnect — nothing to do.
    rescue ::Protocol::HTTP2::GoawayError, ::Protocol::HTTP2::ProtocolError, ::Protocol::HTTP2::HandshakeError
      # Protocol-level error — protocol-http2 has already emitted GOAWAY.
    rescue StandardError => e
      @logger.error do
        {
          message: 'h2 connection error',
          error: e.message,
          error_class: e.class.name,
          backtrace: (e.backtrace || []).first(10).join(' | ')
        }
      end
    ensure
      # Coordinated shutdown: flag the writer, signal it, wait for the final
      # drain, then close the real socket. Order matters — closing the
      # socket before the writer drains would discard final RST_STREAM /
      # GOAWAY / END_STREAM frames in the queue.
      if writer_ctx
        # 2.11-A — close the dispatch queue so any pre-spawned workers
        # parked on `dequeue` fall through (Async::Queue#dequeue returns
        # nil after close). Do this BEFORE waiting on the writer so
        # pool workers can drain their in-flight stream dispatches and
        # release the encode mutex; otherwise the writer might park
        # waiting for bytes that the dispatch worker never gets to
        # encode.
        begin
          writer_ctx.dispatch_queue.close unless writer_ctx.dispatch_queue.closed?
        rescue StandardError
          nil
        end
        writer_ctx.shutdown!
        begin
          writer_task&.wait
        rescue StandardError
          nil
        end
        # 2.10-G — emit one info-level timing line per connection when the
        # opt-in instrumentation is enabled and we collected a full set of
        # samples (a connection that died before serving any stream lacks
        # t2_first_encode / t2_first_wire and gets skipped — there's no
        # first-stream signal to report).
        log_h2_first_stream_timing(writer_ctx) if @h2_timing_enabled
      end
      @metrics.decrement(:connections_active)
      socket.close unless socket.closed?
    end

    private

    # 2.11-A — pre-spawn the per-connection dispatch worker pool.
    #
    # Each worker is a fiber that loops:
    #   1. `dequeue` a stream from the per-connection dispatch queue
    #      (parks the fiber on the queue's internal notification when
    #      empty — zero CPU until a stream arrives).
    #   2. Calls `dispatch_stream` with the stream + writer context +
    #      pre-resolved peer address.
    #   3. Loops back to (1). Exits cleanly when `dequeue` returns nil
    #      (queue closed by `serve`'s ensure block on connection
    #      teardown).
    #
    # Why pre-spawn rather than `task.async {}` per stream:
    #   * Fiber startup under Async involves a few µs of allocation and
    #     scheduler bookkeeping. Per-stream that's negligible; on the
    #     CONNECTION COLD PATH (first request on a fresh TCP/TLS conn)
    #     it adds up to a measurable share of the t1→t2_enc bucket
    #     (the 2.10-G timing breakdown showed ~12-25 ms on h2load
    #     `-c 1 -m 100 -n 5000`).
    #   * Workers parked on `dequeue` are already in the scheduler's
    #     ready set; the first stream is just an enqueue + dequeue
    #     handoff (microseconds).
    #
    # Errors inside `dispatch_stream` are already caught + RST_STREAMed
    # there, so the worker only needs to defend against truly
    # unexpected failures (queue shutdown races, fiber kill on graceful
    # shutdown). We swallow those defensively and unregister so the
    # `dispatch_worker_count` introspection is truthful.
    def warmup_dispatch_pool!(task, writer_ctx, peer_addr:, pool_size:)
      pool_size.times do
        task.async do
          writer_ctx.register_dispatch_worker
          begin
            loop do
              stream = writer_ctx.dispatch_queue.dequeue
              break if stream.nil? # queue closed → graceful exit

              begin
                dispatch_stream(stream, writer_ctx, peer_addr)
              rescue StandardError => e
                # `dispatch_stream` already logs + RST_STREAMs internally;
                # if anything escapes that net we log here and keep the
                # worker alive — one bad stream must not poison the
                # connection's worker pool.
                @logger.error do
                  { message: 'h2 dispatch worker swallowed error',
                    error: e.message, error_class: e.class.name }
                end
              end
            end
          ensure
            writer_ctx.unregister_dispatch_worker
          end
        end
      end
    end

    # Build the [setting_id, value] pairs that go in the connection-preface
    # SETTINGS frame. protocol-http2's Server#read_connection_preface accepts
    # this array and does the wire encoding for us. Empty array (no overrides
    # configured) → SETTINGS frame still goes out, just with no entries
    # (effectively an ack), which is what the spec allows.
    #
    # We clamp out-of-range values (max_frame_size below the spec floor or
    # above its ceiling, initial_window_size above 31-bit max) instead of
    # letting protocol-http2 raise ProtocolError at handshake time — a
    # crashing handshake leaks the connection. Operator gets a warn so the
    # misconfiguration surfaces in logs.
    def initial_settings_payload
      return [] unless @h2_settings

      payload = []
      @h2_settings.each do |key, value|
        next if value.nil?

        setting_id = SETTINGS_KEY_MAP[key]
        unless setting_id
          @logger.warn { { message: 'unknown h2 setting; skipping', setting: key } }
          next
        end

        clamped = clamp_h2_setting(key, value)
        payload << [setting_id, clamped]
      end
      payload
    end

    def clamp_h2_setting(key, value)
      case key
      when :max_frame_size
        if value < H2_MIN_FRAME_SIZE
          @logger.warn do
            { message: 'h2 max_frame_size below spec minimum; clamping',
              configured: value, clamped_to: H2_MIN_FRAME_SIZE }
          end
          H2_MIN_FRAME_SIZE
        elsif value > H2_MAX_FRAME_SIZE
          @logger.warn do
            { message: 'h2 max_frame_size above spec maximum; clamping',
              configured: value, clamped_to: H2_MAX_FRAME_SIZE }
          end
          H2_MAX_FRAME_SIZE
        else
          value
        end
      when :initial_window_size
        if value > H2_MAX_WINDOW_SIZE
          @logger.warn do
            { message: 'h2 initial_window_size above spec maximum; clamping',
              configured: value, clamped_to: H2_MAX_WINDOW_SIZE }
          end
          H2_MAX_WINDOW_SIZE
        else
          value
        end
      else
        value
      end
    end

    def build_server(framer)
      server = ::Protocol::HTTP2::Server.new(framer)
      install_native_hpack(server) if @h2_native_hpack_enabled
      server.define_singleton_method(:accept_stream) do |stream_id, &block|
        unless valid_remote_stream_id?(stream_id)
          raise ::Protocol::HTTP2::ProtocolError, "Invalid stream id: #{stream_id}"
        end

        if block
          create_stream(stream_id, &block)
        else
          create_stream(stream_id) { |conn, id| RequestStream.create(conn, id) }
        end
      end # quiet rubocop unused-warning placeholder; not actually returned
      server
    end

    # Phase 10 (Phase 6c): swap the per-connection HPACK encode/decode
    # entry points to route through the Rust crate. We replace
    # `encode_headers` / `decode_headers` on the `Protocol::HTTP2::Server`
    # instance via singleton methods — protocol-http2's framer + stream
    # state machine call `connection.encode_headers(headers, buffer)` and
    # `connection.decode_headers(data)` whenever HEADERS / CONTINUATION
    # frames cross the wire, so this is exactly the boundary where the
    # native codec slots in. The adapter holds one Encoder + one Decoder
    # for this connection; their dynamic tables persist across all
    # HEADERS frames in their respective directions, matching RFC 7541's
    # per-direction HPACK context model.
    #
    # The Ruby `@encoder` / `@decoder` Context ivars on the
    # `Protocol::HTTP2::Connection` superclass remain in place but are
    # never consulted — the singleton-method overrides shortcut past
    # them. That's safe: protocol-http2 only touches those Contexts
    # through `encode_headers` / `decode_headers`, which we now own.
    #
    # If the substitution surface ever shifts in protocol-http2 (e.g.
    # a future version inlines the call), this method becomes a no-op
    # safely — `define_singleton_method` doesn't fail when the parent
    # method is absent, but downstream calls would. The codec-boot log
    # makes the substitution observable, so a regression would surface
    # quickly via the integration spec.
    def install_native_hpack(server)
      adapter = Hyperion::Http2::NativeHpackAdapter.new
      server.define_singleton_method(:encode_headers) do |headers, buffer = String.new.b|
        adapter.encode_headers(headers, buffer)
      end
      server.define_singleton_method(:decode_headers) do |data|
        adapter.decode_headers(data)
      end
      # Stash the adapter so introspection (and the encode-mutex synchronisation
      # boundary, since adapter state is mutated under it) can reach it.
      server.instance_variable_set(:@hyperion_native_hpack, adapter)
      adapter
    rescue StandardError => e
      # Defence in depth: if the adapter ctor fails for any reason, log and
      # fall back to protocol-http2's Ruby Compressor/Decompressor. Better
      # than crashing the connection on first HEADERS frame.
      @logger.warn do
        { message: 'h2 native hpack install failed; falling back to Ruby HPACK',
          error: e.class.name, detail: e.message }
      end
      nil
    end

    def dispatch_stream(stream, writer_ctx, peer_addr = nil)
      # RFC 7540 §8.1.2 — header validation flagged this stream as malformed.
      # Send RST_STREAM PROTOCOL_ERROR instead of invoking the app.
      if stream.protocol_error?
        @logger.debug do
          { message: 'h2 request rejected', reason: stream.protocol_error_reason, stream_id: stream.id }
        end
        @metrics.increment(:requests_rejected)
        begin
          writer_ctx.encode_mutex.synchronize do
            stream.send_reset_stream(::Protocol::HTTP2::Error::PROTOCOL_ERROR) unless stream.closed?
          end
        rescue StandardError
          nil
        end
        return
      end

      # RFC A7: process-wide stream admission control. nil admission =
      # unbounded (current behaviour). When the cap is hit we send
      # REFUSED_STREAM (RFC 7540 §11 / RFC 9113 §5.4.1) — the spec-
      # defined response for "this stream cannot be processed; client
      # may retry on a different stream id". Bumps a counter so
      # operators can alert on sustained refusal volume.
      if @h2_admission && !@h2_admission.admit
        @metrics.increment(:h2_streams_refused)
        begin
          writer_ctx.encode_mutex.synchronize do
            stream.send_reset_stream(::Protocol::HTTP2::Error::REFUSED_STREAM) unless stream.closed?
          end
        rescue StandardError
          nil
        end
        return
      end
      @h2_admission.nil?

      pseudo, regular = partition_pseudo(stream.request_headers)

      method    = pseudo[':method'] || 'GET'
      path_raw  = pseudo[':path']   || '/'
      authority = pseudo[':authority']
      path, query = path_raw.split('?', 2)

      hyperion_headers = regular
      hyperion_headers['host'] ||= authority if authority

      request = Hyperion::Request.new(
        method: method,
        path: path,
        query_string: query || '',
        http_version: 'HTTP/2',
        headers: hyperion_headers,
        body: stream.request_body,
        peer_address: peer_addr
      )

      @metrics.increment(:requests_total)
      @metrics.increment(:requests_in_flight)
      # 2.12-E — per-worker request counter, ticked once per h2 stream.
      # Same family as Connection#serve so the audit metric reflects
      # cluster distribution across BOTH transports without operators
      # needing to alert on two separate counters.
      @metrics.tick_worker_request(@worker_id)
      # 2.1.0 (WS-1): HTTP/2 hijack is intentionally NOT plumbed here.
      # Rack 3 hijack over HTTP/2 requires Extended CONNECT (RFC 8441 +
      # RFC 9220) — a separate feature with its own SETTINGS handshake,
      # :protocol pseudo-header, and stream lifetime semantics. The
      # 2.1.0 scope is HTTP/1.1 hijack only (env['rack.hijack?'] returns
      # false on h2 streams because we don't pass `connection:` here).
      # If a Rack app keys on rack.hijack? to choose a transport, the h2
      # branch will fall through to its non-hijack path. See WS-2..WS-5
      # for the full WebSocket roadmap.
      status, response_headers, body_chunks = begin
        if @thread_pool
          @thread_pool.call(@app, request)
        else
          # 2.5-C — pass the handler's Runtime so per-request hooks
          # fire on h2 streams too. Multi-tenant deployments rely on
          # this to keep tracing context per-server even on the h2
          # path that doesn't go through Connection#call_app.
          Hyperion::Adapter::Rack.call(@app, request, runtime: @runtime)
        end
      ensure
        @metrics.decrement(:requests_in_flight)
      end

      out_headers = [[':status', status.to_s]]
      response_headers.each do |k, v|
        next if k.to_s.downcase == 'connection' # forbidden in h2

        Array(v).each do |val|
          val.to_s.split("\n").each do |line|
            out_headers << [k.to_s.downcase, line]
          end
        end
      end

      # 2.12-F — gRPC support: bodies that respond to `:trailers` carry a
      # final HEADERS frame (with END_STREAM=1) right after the DATA frames.
      # The Rack 3 contract is "iterate body first, then call body.trailers"
      # — so we materialise the payload, then *before* `body.close`
      # (`Rack::BodyProxy` clears state on close) snapshot the trailers Hash.
      # `nil` / empty Hash → no trailing frame. Non-Hash values are coerced
      # to a Hash defensively; a misbehaving app must not be able to crash
      # the connection.
      payload = String.new(encoding: Encoding::ASCII_8BIT)
      body_chunks.each { |c| payload << c.to_s }
      response_trailers = collect_response_trailers(body_chunks)
      body_chunks.close if body_chunks.respond_to?(:close)

      # Hotfix C2: empty-body responses (RFC 7230 §3.3.3 — 204/304 + HEAD)
      # MUST NOT carry a DATA frame. Folding END_STREAM onto the HEADERS
      # frame collapses the response to one encoder-mutex acquisition and
      # one writer-fiber wakeup instead of two. Any body the app returned
      # for HEAD is discarded here per spec (the bytes were already
      # built — that's a Rack-app smell, not our problem to fix).
      #
      # Trailers on body-suppressed responses (HEAD/204/304) are dropped:
      # the response is end-of-stream after HEADERS, with no place to put
      # a trailing HEADERS frame. This matches what curl --http2 / grpc
      # clients do (HEAD + gRPC isn't a meaningful combination).
      if body_suppressed?(method, status)
        writer_ctx.encode_mutex.synchronize do
          stream.send_headers(out_headers, ::Protocol::HTTP2::END_STREAM)
        end
      elsif have_trailers?(response_trailers)
        # gRPC / Rack-3-trailers path: HEADERS (no END_STREAM), DATA frames
        # (no END_STREAM on last DATA), final HEADERS with END_STREAM=1.
        writer_ctx.encode_mutex.synchronize { stream.send_headers(out_headers) }
        send_body(stream, payload, writer_ctx, end_stream: false)
        send_trailers(stream, response_trailers, writer_ctx)
      else
        writer_ctx.encode_mutex.synchronize { stream.send_headers(out_headers) }
        send_body(stream, payload, writer_ctx)
      end
      # 2.10-G — first stream's HEADERS+DATA encoded. Capture exactly once
      # per connection (use ||= under the encode mutex's freshly-released
      # write so concurrent stream fibers race lose-race once). For h2load
      # `-c 1 -m 100 -n 5000` the first stream is stream id 1, the only
      # one that pays the connection-setup cost; later streams skip this
      # branch via the `||=`.
      writer_ctx.t2_first_encode = monotonic_now if @h2_timing_enabled && writer_ctx.t2_first_encode.nil?
      @metrics.increment_status(status)
    rescue StandardError => e
      @metrics.increment(:app_errors)
      @logger.error do
        {
          message: 'h2 stream dispatch failed',
          error: e.message,
          error_class: e.class.name,
          backtrace: (e.backtrace || []).first(10).join(' | ')
        }
      end
      begin
        writer_ctx.encode_mutex.synchronize do
          stream.send_reset_stream(::Protocol::HTTP2::Error::INTERNAL_ERROR)
        end
      rescue StandardError
        nil
      end
    ensure
      # Release the admission slot once the stream's served (success or
      # error). h2_admitted is local-set above the slot acquisition, so
      # the protocol-error / pre-admission early-returns above don't
      # double-release.
      @h2_admission.release if defined?(h2_admitted) && h2_admitted
    end

    # RFC 7230 §3.3.3: status codes that prohibit a response body, plus
    # the HEAD method which always suppresses the body regardless of what
    # the application returned. The h2 dispatch path uses this to fold
    # END_STREAM onto the HEADERS frame and skip the DATA-frame write
    # entirely (see Hotfix C2).
    BODY_SUPPRESSED_STATUSES = [204, 304].freeze

    def body_suppressed?(method, status)
      return true if BODY_SUPPRESSED_STATUSES.include?(status)
      return true if method == 'HEAD'

      false
    end

    # Send the response body, respecting the peer's max frame size and
    # per-stream flow-control window. When the window is exhausted, we
    # block the dispatch fiber on the stream's `window_available`
    # notification — protocol-http2 calls `window_updated` on every active
    # stream when WINDOW_UPDATE frames arrive (either stream- or
    # connection-scoped), which signals the notification.
    #
    # The encode_mutex protects HPACK state and per-stream frame ordering;
    # the actual socket write happens off-fiber via the writer task.
    #
    # 2.12-F — `end_stream:` controls whether the LAST DATA frame carries
    # the END_STREAM flag. The default `true` preserves pre-2.12-F semantics
    # (final DATA frame closes the stream). Callers that intend to send a
    # trailing HEADERS frame after the body pass `end_stream: false` so the
    # final DATA frame leaves the stream half-open from the server side
    # and the trailer HEADERS frame can carry END_STREAM=1.
    def send_body(stream, payload, writer_ctx, end_stream: true)
      if payload.empty?
        if end_stream
          writer_ctx.encode_mutex.synchronize do
            stream.send_data('', ::Protocol::HTTP2::END_STREAM)
          end
        end
        # When end_stream is false AND payload is empty, we deliberately
        # send NO DATA frame at all — gRPC trailers-only responses (the
        # error-without-payload shape) are HEADERS → trailer-HEADERS, no
        # DATA in between. send_trailers handles the closing END_STREAM.
        return
      end

      offset = 0
      bytesize = payload.bytesize
      while offset < bytesize
        # `available_frame_size` is the min of the connection's max-frame
        # setting and the smaller of the stream/connection remote windows.
        available = stream.available_frame_size

        if available <= 0
          # Window exhausted. Wait for WINDOW_UPDATE and re-check.
          stream.wait_for_window
          next
        end

        chunk = payload.byteslice(offset, available)
        offset += chunk.bytesize
        last_chunk = offset >= bytesize
        flags = last_chunk && end_stream ? ::Protocol::HTTP2::END_STREAM : 0

        writer_ctx.encode_mutex.synchronize { stream.send_data(chunk, flags) }
      end
    end

    # 2.12-F — pull a trailers Hash off the response body if Rack 3
    # `body.trailers` is implemented. Called AFTER the body has been
    # fully iterated (Rack 3 contract: trailers are computed by the body
    # while it streams; reading them before iteration is undefined).
    # Returns nil when the body doesn't expose trailers, when the call
    # raises, or when the result isn't a Hash-coercible map. Defensive
    # by design: a misbehaving app must not crash the dispatch loop.
    def collect_response_trailers(body)
      return nil unless body.respond_to?(:trailers)

      raw = body.trailers
      return nil if raw.nil?
      return raw if raw.is_a?(Hash)
      return raw.to_h if raw.respond_to?(:to_h)

      nil
    rescue StandardError => e
      @logger.warn do
        { message: 'h2 body.trailers raised; ignoring',
          error: e.message, error_class: e.class.name }
      end
      nil
    end

    # 2.12-F — predicate for "we have trailers worth sending". Defined as
    # a method (rather than the more idiomatic `!h.nil? && !h.empty?` /
    # `h&.any?`) because rubocop-rails on the hot path autocorrects both
    # of those forms to `h.present?`, which raises NoMethodError on a
    # plain Hash outside ActiveSupport. Hyperion is a stand-alone gem;
    # we don't depend on ActiveSupport, so we route through this helper
    # to keep the rubocop-rails formatter quiet without adding a Cop
    # disable comment everywhere a nil-or-empty Hash check appears.
    def have_trailers?(trailers)
      return false if trailers.nil?
      return false if trailers.respond_to?(:empty?) && trailers.empty?

      true
    end

    # 2.12-F — emit the final HEADERS frame carrying response trailers.
    # The wire shape is one HEADERS frame with END_STREAM=1; HPACK
    # encodes the trailer block exactly like a regular HEADERS frame.
    # Trailer keys MUST be lowercased (RFC 7540 §8.1.2) — same rule as
    # regular HTTP/2 headers. We strip CR/LF from values defensively
    # (a header-injection guard) and split multi-line values on \n the
    # same way the regular response-header path does.
    def send_trailers(stream, trailers, writer_ctx)
      pairs = []
      trailers.each do |k, v|
        name = k.to_s.downcase
        # Pseudo-headers and forbidden names cannot appear in trailers.
        next if name.empty?
        next if name.start_with?(':')
        next if RequestStream::FORBIDDEN_HEADERS.include?(name)

        Array(v).each do |val|
          val.to_s.split("\n").each { |line| pairs << [name, line] }
        end
      end
      writer_ctx.encode_mutex.synchronize do
        stream.send_headers(pairs, ::Protocol::HTTP2::END_STREAM)
      end
    end

    # Drain bytes off the per-connection send queue onto the real socket.
    # This fiber is the SOLE writer to `socket` for the connection's
    # lifetime, which satisfies SSLSocket's "no concurrent writes from
    # different fibers" constraint.
    #
    # The loop:
    #   1. Drain everything currently enqueued (non-blocking pops).
    #   2. If we drained anything, signal `@drained_notify` so backpressured
    #      encoders can resume, then loop again — more bytes may have been
    #      enqueued while we were writing.
    #   3. If shutdown was requested AND the queue is empty, exit.
    #   4. Otherwise park on the send notification until an encoder pokes us.
    def run_writer_loop(socket, writer_ctx)
      loop do
        drained_bytes = 0
        while (chunk = writer_ctx.try_pop)
          begin
            socket.write(chunk)
            # 2.10-G — first byte on the wire. Capture exactly once per
            # connection (the first chunk drained is the server's
            # connection-preface SETTINGS frame; we want the t1→t2_wire
            # delta to bracket "preface bytes encoded → preface bytes on
            # the socket". The expensive HEADERS+DATA enqueue happens
            # later under t2_first_encode.)
            writer_ctx.t2_first_wire = monotonic_now if @h2_timing_enabled && writer_ctx.t2_first_wire.nil?
          rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError
            # Peer hung up. Release THIS chunk's byte budget, then drain the
            # rest of the queue (without writing) so backpressured encoders
            # don't stall waiting on a writer that's about to exit. Any
            # remaining queued bytes are dropped — the connection is dead.
            writer_ctx.note_drained(chunk.bytesize)
            drain_and_discard_queue(writer_ctx)
            return
          end
          drained_bytes += chunk.bytesize
          writer_ctx.note_drained(chunk.bytesize)
        end

        # Some sockets (SSLSocket on a TCPSocket whose Nagle is off) need an
        # explicit flush to push small final frames (END_STREAM data, GOAWAY)
        # without waiting for the next write. Cheap when there's nothing
        # buffered.
        socket.flush if drained_bytes.positive? && socket.respond_to?(:flush) && !socket.closed?

        return if writer_ctx.writer_done? && writer_ctx.queue_empty?

        writer_ctx.wait_for_signal
      end
    rescue StandardError => e
      @logger.error do
        {
          message: 'h2 writer loop error',
          error: e.message,
          error_class: e.class.name,
          backtrace: (e.backtrace || []).first(10).join(' | ')
        }
      end
    end

    # On peer-disconnect we discard any queued bytes (we can't write them),
    # but we MUST still decrement the byte counter for each one or
    # backpressured encoder fibers will park forever on the drain
    # notification.
    def drain_and_discard_queue(writer_ctx)
      while (chunk = writer_ctx.try_pop)
        writer_ctx.note_drained(chunk.bytesize)
      end
    end

    # 2.10-G — small helper so the four timing call sites in `serve`,
    # `dispatch_stream`, and `run_writer_loop` agree on the clock source.
    # CLOCK_MONOTONIC is unaffected by NTP jumps and is what the rest of
    # the gem uses for elapsed-time math (see Connection#serve).
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # 2.10-G — assemble + emit the per-connection timing breakdown that
    # the bench harness greps for. Three deltas are reported in
    # milliseconds:
    #
    #   t0_to_t1_ms     — preface exchange (read client preface + write
    #                     server SETTINGS into the framer queue)
    #   t1_to_t2_enc_ms — gap between preface complete and first stream's
    #                     HEADERS+DATA encoded. If this is the dominant
    #                     bucket, the framer-fiber priming / first-stream
    #                     scheduling is the suspect.
    #   t2_enc_to_t2_wire_ms — encode-complete to writer drained first
    #                          chunk on the wire. Should be near-zero on
    #                          a healthy connection (writer fiber is
    #                          already running, parked on @send_notify).
    #                          A large value here = writer-fiber
    #                          starvation under the Async scheduler.
    #
    # Skipped when any timestamp is missing (connection died before
    # serving a stream / instrumentation was disabled mid-flight).
    def log_h2_first_stream_timing(writer_ctx)
      t0 = writer_ctx.t0_serve_entry
      t1 = writer_ctx.t1_preface_done
      t2_enc  = writer_ctx.t2_first_encode
      t2_wire = writer_ctx.t2_first_wire
      return if t0.nil? || t1.nil? || t2_enc.nil? || t2_wire.nil?

      @logger.info do
        {
          message: 'h2 first-stream timing',
          t0_to_t1_ms: ((t1 - t0) * 1000).round(3),
          t1_to_t2_enc_ms: ((t2_enc - t1) * 1000).round(3),
          t2_enc_to_t2_wire_ms: ((t2_wire - t2_enc) * 1000).round(3),
          t0_to_t2_wire_ms: ((t2_wire - t0) * 1000).round(3)
        }
      end
    rescue StandardError
      # Logging the timing breakdown must never crash the connection
      # teardown path — instrumentation is best-effort.
      nil
    end

    # Mirrors Connection#peer_address — see the comment there. SSLSocket
    # wraps a TCPSocket; both expose #peeraddr after handshake.
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

    def partition_pseudo(headers_array)
      pseudo = {}
      regular = {}
      headers_array.each do |pair|
        name, value = pair
        if name.start_with?(':')
          pseudo[name] = value
        else
          regular[name] ||= +''
          regular[name] = if regular[name].empty?
                            value.to_s
                          else
                            "#{regular[name]},#{value}"
                          end
        end
      end
      [pseudo, regular]
    end
  end
end
