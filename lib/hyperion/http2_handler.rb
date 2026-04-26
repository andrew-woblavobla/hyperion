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
      attr_reader :request_headers, :request_body, :request_complete

      def initialize(*)
        super
        @request_headers = []
        @request_body = +''
        @request_complete = false
        @window_available = ::Async::Notification.new
      end

      def process_headers(frame)
        decoded = super
        # decoded is an Array of [name, value] pairs (HPACK output).
        decoded.each { |pair| @request_headers << pair }
        @request_complete = true if frame.end_stream?
        decoded
      end

      def process_data(frame)
        data = super
        # rubocop:disable Rails/Present
        @request_body << data if data && !data.empty?
        # rubocop:enable Rails/Present
        @request_complete = true if frame.end_stream?
        data
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
    end

    def initialize(app:, thread_pool: nil)
      @app         = app
      @thread_pool = thread_pool
      @metrics     = Hyperion.metrics
      @logger      = Hyperion.logger
    end

    def serve(socket)
      @metrics.increment(:connections_accepted)
      @metrics.increment(:connections_active)
      framer = ::Protocol::HTTP2::Framer.new(socket)
      server = build_server(framer)
      server.read_connection_preface

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
