# frozen_string_literal: true

require 'async'
require 'async/notification'
require 'protocol/http2/server'
require 'protocol/http2/framer'
require 'protocol/http2/stream'

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
  # All framer writes (HEADERS, DATA, RST_STREAM) are serialized through a
  # single connection-scoped Mutex (`@send_mutex`). The OpenSSL::SSL::SSLSocket
  # underneath is not safe to drive from two fibers concurrently, and
  # protocol-http2's HPACK encoder is also stateful across HEADERS frames,
  # so all sends must be serialized.
  #
  # Flow control: `RequestStream#window_updated` overrides the protocol-http2
  # default to fan a notification out to any fiber blocked in `send_body`
  # waiting for the remote peer's flow-control window to grow. The body
  # writer chunks the response payload by the per-stream available frame
  # size and yields on the notification when the window is exhausted, so
  # large bodies never trip a FlowControlError.
  class Http2Handler
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
        @request_body = +''
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

    def initialize(app:, thread_pool: nil, h2_settings: nil)
      @app         = app
      @thread_pool = thread_pool
      @h2_settings = h2_settings
      @metrics     = Hyperion.metrics
      @logger      = Hyperion.logger
    end

    def serve(socket)
      @metrics.increment(:connections_accepted)
      @metrics.increment(:connections_active)
      framer = ::Protocol::HTTP2::Framer.new(socket)
      server = build_server(framer)
      server.read_connection_preface(initial_settings_payload)

      # Extract once — the same TCP peer drives every stream on this conn.
      peer_addr = peer_address(socket)

      # All framer writes (HEADERS / DATA / RST_STREAM / GOAWAY) must be
      # serialized: the underlying SSLSocket is not safe across fibers, and
      # the HPACK encoder is also stateful. The connection's own frame loop
      # uses this mutex too — see `dispatch_stream` and `send_body`.
      send_mutex = ::Mutex.new

      task = ::Async::Task.current

      # Track in-flight per-stream dispatch fibers so we can drain them on
      # connection close.
      stream_tasks = []

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

          stream_tasks << task.async do
            dispatch_stream(stream, send_mutex, peer_addr)
          end
        end
      end

      # Drain in-flight stream dispatches before we close the socket.
      stream_tasks.each do |t|
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
      @metrics.decrement(:connections_active)
      socket.close unless socket.closed?
    end

    private

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

    def dispatch_stream(stream, send_mutex, peer_addr = nil)
      # RFC 7540 §8.1.2 — header validation flagged this stream as malformed.
      # Send RST_STREAM PROTOCOL_ERROR instead of invoking the app.
      if stream.protocol_error?
        @logger.debug do
          { message: 'h2 request rejected', reason: stream.protocol_error_reason, stream_id: stream.id }
        end
        @metrics.increment(:requests_rejected)
        begin
          send_mutex.synchronize do
            stream.send_reset_stream(::Protocol::HTTP2::Error::PROTOCOL_ERROR) unless stream.closed?
          end
        rescue StandardError
          nil
        end
        return
      end

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
      status, response_headers, body_chunks = begin
        if @thread_pool
          @thread_pool.call(@app, request)
        else
          Hyperion::Adapter::Rack.call(@app, request)
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

      payload = +''
      body_chunks.each { |c| payload << c.to_s }
      body_chunks.close if body_chunks.respond_to?(:close)

      send_mutex.synchronize { stream.send_headers(out_headers) }
      send_body(stream, payload, send_mutex)
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
        send_mutex.synchronize { stream.send_reset_stream(::Protocol::HTTP2::Error::INTERNAL_ERROR) }
      rescue StandardError
        nil
      end
    end

    # Send the response body, respecting the peer's max frame size and
    # per-stream flow-control window. When the window is exhausted, we
    # block the dispatch fiber on the stream's `window_available`
    # notification — protocol-http2 calls `window_updated` on every active
    # stream when WINDOW_UPDATE frames arrive (either stream- or
    # connection-scoped), which signals the notification.
    def send_body(stream, payload, send_mutex)
      if payload.empty?
        send_mutex.synchronize { stream.send_data('', ::Protocol::HTTP2::END_STREAM) }
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
        flags = offset >= bytesize ? ::Protocol::HTTP2::END_STREAM : 0

        send_mutex.synchronize { stream.send_data(chunk, flags) }
      end
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
