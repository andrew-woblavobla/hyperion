# frozen_string_literal: true

require 'zlib'
require_relative 'frame'

module Hyperion
  # WS-4 (2.1.0) — per-connection WebSocket wrapper.
  #
  # Sits on top of WS-1 (the hijacked socket), WS-2 (the validated handshake),
  # and WS-3 (frame ser/de) and exposes a simple message-oriented API:
  #
  #   ws = Hyperion::WebSocket::Connection.new(socket,
  #                                            buffered: env['hyperion.hijack_buffered'],
  #                                            subprotocol: env['hyperion.websocket.handshake'][2])
  #
  #   loop do
  #     type, payload = ws.recv
  #     break if type == :close || type.nil?
  #     ws.send(payload, opcode: type)         # echo
  #   end
  #
  # Responsibilities:
  #
  # * Continuation reassembly. The peer can split a single application
  #   message across many frames (`text` + `continuation`* + final `FIN=1`);
  #   `recv` only returns when the message is complete. Control frames
  #   (`ping`, `pong`, `close`) MAY be interleaved between fragments per
  #   RFC 6455 §5.4 — we handle them inline without disrupting the
  #   reassembly buffer.
  #
  # * Auto-pong. RFC 6455 §5.5.2 — server SHOULD reply to a ping with a
  #   pong carrying the same payload. The default behaviour fires the
  #   pong before returning control to the caller; `on_ping` lets the app
  #   observe the event but does NOT replace the auto-response (the
  #   server stays compliant even if the app's hook does nothing).
  #
  # * Close handshake. Either side initiating a close gets the
  #   bidirectional shutdown right: an inbound close triggers an outbound
  #   close echo (RFC 6455 §5.5.1) and `recv` returns
  #   `[:close, code, reason]`; calling `close(code: 1000)` writes our
  #   close frame and waits up to `drain_timeout` seconds for the peer's
  #   matching close before tearing down the socket.
  #
  # * Per-message size cap. `max_message_bytes` (default 1 MiB) bounds
  #   the reassembly buffer; the moment a continuation frame would push
  #   the running total past the cap we send close 1009 (Message Too Big)
  #   and surface the close to the caller.
  #
  # * UTF-8 validation. Text frames whose payload isn't valid UTF-8 trip
  #   close 1007 (Invalid Frame Payload Data) per RFC 6455 §8.1.
  #
  # Things deliberately NOT in this class (deferred to 2.1.x):
  #
  # * permessage-deflate (RFC 7692). The handshake-time negotiation
  #   would live in WS-2 and the per-frame compression here; out of scope
  #   for 2.1.0.
  # * Send-side fragmentation. `send` writes a single FIN=1 frame
  #   regardless of payload size. Browsers / well-behaved clients have
  #   no trouble with multi-MB single frames; if a use case shows up we
  #   can add an opt-in `fragment_threshold:` later.
  # * Backpressure / outbound queueing. Writes are synchronous on the
  #   caller's thread; `socket.write` blocks if the kernel buffer is full.
  #   The `IO.select`-based read loop already cooperates with async-io
  #   when a fiber scheduler is installed (Ruby 3.3 redirects `select`
  #   automatically), so the recv side is fiber-friendly out of the box.
  module WebSocket
    # Raised when the peer (or our own code) does something the protocol
    # forbids. Translated to a close frame with the right RFC 6455 §7.4
    # code before the recv loop tears the connection down.
    class StateError < StandardError; end

    # The 16 KB read chunk size matches what Hyperion::Connection uses
    # for HTTP/1.1 — small enough to keep memory pressure low under
    # many idle WS connections, big enough that a 1 MiB message
    # arrives in ~64 syscalls.
    READ_CHUNK_BYTES = 16 * 1024

    # 2.3-C — RFC 7692 §7.2.1 sync trailer. The 4-byte deflate-block
    # terminator that the deflater emits between messages and the
    # inflater needs prepended back. Frozen so the per-frame strip /
    # append paths share one constant rather than allocating a fresh
    # Array of bytes each time.
    DEFLATE_SYNC_TRAILER = "\x00\x00\xff\xff".b.freeze

    # RFC 6455 §7.4.1 close codes we emit. The peer is free to send any
    # registered code; we surface their integer verbatim in `recv`.
    CLOSE_NORMAL          = 1000
    CLOSE_GOING_AWAY      = 1001
    CLOSE_PROTOCOL_ERROR  = 1002
    CLOSE_UNSUPPORTED     = 1003
    CLOSE_INVALID_PAYLOAD = 1007
    CLOSE_POLICY          = 1008
    CLOSE_MESSAGE_TOO_BIG = 1009
    CLOSE_INTERNAL_ERROR  = 1011

    class Connection
      attr_reader :subprotocol, :max_message_bytes, :state, :close_code, :close_reason

      # socket           — IO returned by env['rack.hijack'].call. The
      #                    connection assumes ownership; closing the
      #                    Hyperion::WebSocket::Connection closes the
      #                    underlying socket.
      # buffered         — bytes already pulled off the socket by the
      #                    HTTP parser past the request boundary
      #                    (env['hyperion.hijack_buffered']). Prepended
      #                    to the read buffer before the first syscall.
      # subprotocol      — the negotiated subprotocol from the handshake
      #                    (slot 2 of the [:ok, accept, sub] tuple) or nil.
      # max_message_bytes — cap on a single reassembled message. Default 1 MiB.
      #                     For permessage-deflate the cap is applied to the
      #                     DECOMPRESSED size — a tiny compressed payload that
      #                     inflates beyond the cap closes 1009 (compression
      #                     bomb defense, RFC 7692 §8.1).
      # ping_interval    — seconds between proactive server pings. nil = off.
      # idle_timeout     — seconds of no traffic before we send a close.
      #                    nil = off. Defaults to 60s; set higher for
      #                    long-lived idle clients (chat presence, etc.).
      # extensions       — Hash from `Handshake.validate`'s 4th slot. When
      #                    `permessage_deflate:` is present the connection
      #                    instantiates a per-conn Zlib::Deflate / Inflate
      #                    pair sized to the negotiated window bits, and
      #                    sets RSV1 on outbound text/binary frames. `{}`
      #                    (default) means no compression.
      def initialize(socket, buffered: '', subprotocol: nil,
                     max_message_bytes: 1_048_576,
                     ping_interval: 30, idle_timeout: 60,
                     extensions: {})
        @socket = socket
        @subprotocol = subprotocol
        @max_message_bytes = max_message_bytes
        @ping_interval = ping_interval
        @idle_timeout = idle_timeout

        configure_permessage_deflate(extensions[:permessage_deflate])

        @inbuf = String.new(capacity: READ_CHUNK_BYTES, encoding: Encoding::ASCII_8BIT)
        @inbuf << buffered.to_s.b unless buffered.nil? || buffered.empty?
        @offset = 0

        # Reassembly state. @msg_opcode is the first frame's opcode (text
        # or binary); @msg_buffer accumulates payload bytes across
        # continuation frames until FIN=1.
        @msg_opcode = nil
        @msg_buffer = nil

        @state = :open
        @close_code = nil
        @close_reason = nil

        @on_ping = nil
        @on_pong = nil
        @on_close = nil

        @last_traffic_at = monotonic_now
      end

      # Block until the next complete *application* message arrives.
      # Returns:
      #   [:text, String]                — opcode 0x1, UTF-8 validated
      #   [:binary, String]              — opcode 0x2, binary
      #   [:close, Integer|nil, String|nil] — peer initiated close
      #   nil                            — socket EOF before a frame
      #
      # Raises StateError if called after a close has already been
      # observed (the connection is single-shot for close-detection).
      def recv
        raise StateError, 'connection is closed' if @state == :closed
        # If we've already observed a close frame, the next recv must
        # raise — callers that want to clean up should check the
        # previous return value.
        raise StateError, 'close already received' if @state == :closing && @close_observed_by_caller

        loop do
          frame = next_frame
          if frame.nil?
            # Socket EOF without a clean close — treat as best-effort
            # disconnect. The caller sees nil and stops looping.
            mark_closed
            return nil
          end

          # RFC 7692 §6.1: control frames MUST NOT have RSV1 set. The
          # parser already errored on this case, but defense-in-depth
          # — keeps us safe if someone hands us a custom frame source.
          if frame.rsv1 && %i[ping pong close].include?(frame.opcode)
            fail_close(CLOSE_PROTOCOL_ERROR, 'RSV1 set on control frame')
            raise StateError, 'RSV1 set on control frame'
          end

          # RFC 7692 §6: RSV1 only allowed on data frames when the
          # extension was negotiated. Without negotiation, any RSV1 is
          # a protocol error — close 1002 and bail.
          if frame.rsv1 && @inflater.nil?
            fail_close(CLOSE_PROTOCOL_ERROR, 'RSV1 set without negotiated extension')
            raise StateError, 'RSV1 set without negotiated extension'
          end

          case frame.opcode
          when :ping
            handle_ping(frame)
            next
          when :pong
            handle_pong(frame)
            next
          when :close
            return handle_close_frame(frame)
          when :text, :binary
            return nil if (msg = collect_data_frame(frame))&.then { return msg }
          when :continuation
            return nil if (msg = collect_data_frame(frame))&.then { return msg }
          end
        end
      end

      # Send an application message. opcode: :text (default) or :binary.
      # Single-frame, FIN=1, server-side (unmasked). When permessage-
      # deflate is active the payload is DEFLATE-compressed inline and
      # the RSV1 bit is set on the frame; control frames (close/ping/
      # pong) are NEVER compressed per RFC 7692 §6.1, even when the
      # extension is active.
      def send(payload, opcode: :text)
        raise StateError, 'connection is closed' if @state == :closed
        raise StateError, "cannot send while #{@state}" if @state != :open
        unless %i[text binary].include?(opcode)
          raise ArgumentError, "send opcode must be :text or :binary (got #{opcode.inspect})"
        end

        bin = opcode == :text ? payload.to_s.encode(Encoding::UTF_8).b : payload.to_s.b
        rsv1 = false
        if @deflater
          bin = deflate_message(bin)
          rsv1 = true
        end
        wire = Hyperion::WebSocket::Builder.build(opcode: opcode, payload: bin, rsv1: rsv1)
        write_wire(wire)
        @last_traffic_at = monotonic_now
        true
      end

      # Hooks fired AFTER the built-in protocol behaviour. Auto-pong
      # still happens regardless of whether on_ping is registered;
      # close-frame echo still happens regardless of on_close. The hooks
      # are observation points, not behaviour overrides.
      def on_ping(&block) = @on_ping = block
      def on_pong(&block) = @on_pong = block
      def on_close(&block) = @on_close = block

      # Initiate a graceful close. Sends a close frame with the given
      # code (default 1000) and reason, then drains until either the
      # peer's close arrives or `drain_timeout` seconds pass. Closes
      # the socket either way. Idempotent — calling close twice is a
      # no-op on the second call.
      def close(code: CLOSE_NORMAL, reason: '', drain_timeout: 5)
        return if @state == :closed

        if @state == :open
          send_close_frame(code, reason)
          @state = :closing
        end

        # Drain inbound until we see the peer's close (or timeout).
        drain_for_close(drain_timeout)
        mark_closed
      end

      def open? = @state == :open
      def closing? = @state == :closing
      def closed? = @state == :closed

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Return a parsed Hyperion::WebSocket::Frame, or nil on socket EOF.
      # Reads from the socket into @inbuf as needed; the frame parser
      # advances @offset by frame_total_len when a complete frame is
      # available. Compacts @inbuf when @offset gets large to keep
      # memory bounded under long-lived connections.
      def next_frame
        loop do
          if @offset >= @inbuf.bytesize
            # Cheap path — buffer fully consumed, no need to keep the
            # spent prefix around.
            @inbuf.clear
            @offset = 0
          end

          if @inbuf.bytesize > @offset
            begin
              result = Hyperion::WebSocket::Parser.parse_with_cursor(@inbuf, @offset)
            rescue Hyperion::WebSocket::ProtocolError => e
              # RFC 6455 §7.4.1 — 1002 covers protocol-level errors
              # (bad opcode, RSV bits set, fragmented control, etc.).
              fail_close(CLOSE_PROTOCOL_ERROR, e.message)
              raise StateError, "protocol error: #{e.message}"
            end

            if result != :incomplete
              frame, advance = result
              @offset += advance
              @last_traffic_at = monotonic_now
              # Compact the buffer if we've accumulated a lot of
              # consumed bytes. Threshold: half the message cap is a
              # reasonable wash between "compact too often" and
              # "carry too much".
              compact_inbuf_if_needed
              return frame
            end
          end

          # Need more bytes. Block on the socket with idle/ping
          # supervision.
          got = read_more
          return nil if got.nil?
        end
      end

      def compact_inbuf_if_needed
        return if @offset.zero?
        return if @offset < (@max_message_bytes / 2) && @offset < (READ_CHUNK_BYTES * 4)

        @inbuf = @inbuf.byteslice(@offset, @inbuf.bytesize - @offset).b
        @offset = 0
      end

      # Read up to READ_CHUNK_BYTES more bytes into @inbuf. Returns the
      # number of bytes appended, or nil on EOF/idle-timeout. Blocks
      # cooperatively (IO.select redirects to the fiber scheduler under
      # async-io).
      def read_more
        timeout = next_read_timeout
        ready, = IO.select([@socket], nil, nil, timeout)
        if ready.nil?
          # Timeout fired. Decide whether to ping or to close-1001.
          handle_idle_timeout
          return 0 if @state == :open

          return nil
        end

        chunk =
          begin
            @socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
          rescue EOFError, Errno::ECONNRESET, IOError
            nil
          end

        case chunk
        when nil
          nil
        when :wait_readable
          # Spurious wakeup from select — try again next loop.
          0
        else
          @inbuf << chunk.b
          chunk.bytesize
        end
      end

      # Smaller of (idle_timeout - elapsed) and (ping_interval - elapsed).
      # Returns nil to mean "no timeout" when both are nil.
      def next_read_timeout
        candidates = []
        candidates << [@idle_timeout - (monotonic_now - @last_traffic_at), 0].max if @idle_timeout
        if @ping_interval
          @last_proactive_ping_at ||= @last_traffic_at
          candidates << [@ping_interval - (monotonic_now - @last_proactive_ping_at), 0].max
        end
        return nil if candidates.empty?

        candidates.min
      end

      def handle_idle_timeout
        return unless @state == :open

        elapsed = monotonic_now - @last_traffic_at
        if @idle_timeout && elapsed >= @idle_timeout
          # No traffic in idle_timeout seconds — close 1001 (going
          # away) and let the recv loop unwind.
          send_close_frame(CLOSE_GOING_AWAY, 'idle timeout')
          @state = :closing
          @close_code = CLOSE_GOING_AWAY
          @close_reason = 'idle timeout'
          return
        end

        return unless @ping_interval && (monotonic_now - (@last_proactive_ping_at || 0)) >= @ping_interval

        # Proactive keep-alive ping. The peer's pong refreshes
        # @last_traffic_at and resets the idle countdown.
        send_ping_frame('hyperion-keepalive'.b)
        @last_proactive_ping_at = monotonic_now
      end

      def handle_ping(frame)
        # RFC 6455 §5.5.2 — server SHOULD reply with pong carrying the
        # ping's payload (control frame, ≤125 bytes by §5.5).
        wire = Hyperion::WebSocket::Builder.build(opcode: :pong, payload: frame.payload)
        write_wire(wire)
        @on_ping&.call(frame.payload)
      end

      def handle_pong(frame)
        @on_pong&.call(frame.payload)
      end

      # Decode the close frame body — RFC 6455 §5.5.1 — and return
      # `[:close, code, reason]`. Echoes a close back if we haven't
      # initiated one already, then leaves the socket alive for the
      # caller to call `close` (which is a no-op once @state moves to
      # :closing). Subsequent recv raises StateError.
      def handle_close_frame(frame)
        code, reason = parse_close_payload(frame.payload)
        @close_code = code
        @close_reason = reason

        if @state == :open
          # Echo the close back to the peer (RFC §5.5.1).
          send_close_frame(code || CLOSE_NORMAL, '')
          @state = :closing
        end
        @on_close&.call(code, reason)

        @close_observed_by_caller = true
        [:close, code, reason]
      end

      def parse_close_payload(payload)
        bin = payload.b
        return [nil, nil] if bin.bytesize.zero?
        return [CLOSE_PROTOCOL_ERROR, ''] if bin.bytesize == 1

        code = (bin.getbyte(0) << 8) | bin.getbyte(1)
        reason = bin.bytesize > 2 ? bin.byteslice(2, bin.bytesize - 2).force_encoding(Encoding::UTF_8) : ''
        # If reason isn't valid UTF-8 leave the bytes as-is — the
        # caller can do their own decoding; we don't want to swallow
        # information in a debugging path.
        reason = reason.scrub('?') unless reason.valid_encoding?
        [code, reason]
      end

      # Accumulate a data frame into @msg_buffer. Returns the
      # `[type, payload]` 2-tuple when the message completes (FIN=1),
      # otherwise returns `nil` so the recv loop continues.
      def collect_data_frame(frame)
        if frame.opcode == :continuation
          if @msg_opcode.nil?
            fail_close(CLOSE_PROTOCOL_ERROR, 'continuation without start')
            raise StateError, 'continuation without start'
          end
          # RFC 7692 §6: RSV1 must be 0 on continuation frames; the
          # compressed marker only sits on the first fragment.
          if frame.rsv1
            fail_close(CLOSE_PROTOCOL_ERROR, 'RSV1 set on continuation frame')
            raise StateError, 'RSV1 set on continuation frame'
          end
        else
          if @msg_opcode
            fail_close(CLOSE_PROTOCOL_ERROR, 'new data frame mid-message')
            raise StateError, 'new data frame mid-message'
          end
          @msg_opcode = frame.opcode
          @msg_compressed = frame.rsv1
          @msg_buffer = String.new(capacity: frame.payload.bytesize, encoding: Encoding::ASCII_8BIT)
        end

        # Wire-side cap. For uncompressed messages the wire size IS the
        # message size; the same cap applies. For compressed messages we
        # apply a generous separate cap (8× max_message_bytes) so a
        # legitimate compressible message still squeezes through; the
        # post-decompress cap below is the real defense.
        wire_cap = @msg_compressed ? @max_message_bytes * 8 : @max_message_bytes
        new_total = @msg_buffer.bytesize + frame.payload.bytesize
        if new_total > wire_cap
          fail_close(CLOSE_MESSAGE_TOO_BIG, "message exceeds #{@max_message_bytes} bytes")
          @close_code = CLOSE_MESSAGE_TOO_BIG
          @close_reason = 'message too big'
          @close_observed_by_caller = true
          return [:close, CLOSE_MESSAGE_TOO_BIG, 'message too big']
        end

        @msg_buffer << frame.payload.b

        return nil unless frame.fin

        type = @msg_opcode
        payload = @msg_buffer
        compressed = @msg_compressed
        @msg_opcode = nil
        @msg_compressed = false
        @msg_buffer = nil

        if compressed
          payload = inflate_message(payload)
          # Compression-bomb defense: the inflated size is the actual
          # application payload size, and that's what `max_message_bytes`
          # bounds. RFC 7692 §8.1 — implementations MUST defend against
          # malicious senders that compress to a tiny wire payload that
          # explodes on decompression.
          if payload.is_a?(Symbol) && payload == :too_big
            fail_close(CLOSE_MESSAGE_TOO_BIG,
                       "decompressed message exceeds #{@max_message_bytes} bytes")
            @close_code = CLOSE_MESSAGE_TOO_BIG
            @close_reason = 'compressed bomb'
            @close_observed_by_caller = true
            return [:close, CLOSE_MESSAGE_TOO_BIG, 'compressed bomb']
          end
          if payload.is_a?(Symbol) && payload == :inflate_error
            fail_close(CLOSE_INVALID_PAYLOAD, 'invalid deflate payload')
            @close_code = CLOSE_INVALID_PAYLOAD
            @close_reason = 'inflate error'
            @close_observed_by_caller = true
            return [:close, CLOSE_INVALID_PAYLOAD, 'inflate error']
          end
        end

        if type == :text
          payload.force_encoding(Encoding::UTF_8)
          unless payload.valid_encoding?
            fail_close(CLOSE_INVALID_PAYLOAD, 'invalid UTF-8 in text frame')
            @close_code = CLOSE_INVALID_PAYLOAD
            @close_reason = 'invalid utf-8'
            @close_observed_by_caller = true
            return [:close, CLOSE_INVALID_PAYLOAD, 'invalid utf-8']
          end
        end

        [type, payload]
      end

      def send_close_frame(code, reason)
        body = String.new(encoding: Encoding::ASCII_8BIT)
        if code
          body << ((code >> 8) & 0xFF).chr
          body << (code & 0xFF).chr
          body << reason.to_s.b unless reason.nil? || reason.empty?
        end
        # Control-frame cap: 125 bytes. Truncate the reason rather than
        # raise — operators don't want a long error message to take
        # down a close path.
        body = body.byteslice(0, 125) if body.bytesize > 125
        wire = Hyperion::WebSocket::Builder.build(opcode: :close, payload: body)
        write_wire(wire)
      end

      def send_ping_frame(payload)
        wire = Hyperion::WebSocket::Builder.build(opcode: :ping, payload: payload)
        write_wire(wire)
      end

      # Used after we detected a fatal protocol error — write a close
      # frame, mark the connection :closing, but DON'T tear down the
      # socket here. The recv loop already raises StateError; the
      # caller's ensure block can `close` to flush.
      def fail_close(code, reason)
        send_close_frame(code, reason) if @state == :open
        @state = :closing
        @close_code = code
        @close_reason = reason
      end

      def drain_for_close(drain_timeout)
        deadline = monotonic_now + (drain_timeout || 0)
        while @state == :closing && (drain_timeout.nil? || monotonic_now < deadline)
          remaining = drain_timeout ? [deadline - monotonic_now, 0].max : nil
          ready, = IO.select([@socket], nil, nil, remaining)
          break unless ready

          chunk =
            begin
              @socket.read_nonblock(READ_CHUNK_BYTES, exception: false)
            rescue EOFError, Errno::ECONNRESET, IOError
              nil
            end
          break if chunk.nil?
          next if chunk == :wait_readable

          @inbuf << chunk.b
          # Drain any whole frames available; we're looking for the
          # peer's close ack.
          loop do
            break if @offset >= @inbuf.bytesize

            result =
              begin
                Hyperion::WebSocket::Parser.parse_with_cursor(@inbuf, @offset)
              rescue Hyperion::WebSocket::ProtocolError
                # Bail on protocol error during drain — we're closing anyway.
                @offset = @inbuf.bytesize
                break
              end
            break if result == :incomplete

            frame, advance = result
            @offset += advance
            next unless frame.opcode == :close

            code, reason = parse_close_payload(frame.payload)
            @close_code ||= code
            @close_reason ||= reason
            return
          end
        end
      end

      def write_wire(wire)
        @socket.write(wire)
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        mark_closed
      end

      def mark_closed
        return if @state == :closed

        begin
          @socket.close
        rescue IOError, Errno::EBADF
          # Already closed; that's fine.
        end
        @state = :closed
      end

      # ---- 2.3-C permessage-deflate helpers ---------------------------

      # Set up the per-connection deflater + inflater pair when the
      # handshake negotiated permessage-deflate. With no params hash
      # (extension not negotiated) this is a no-op and the connection
      # behaves identically to 2.2.0.
      def configure_permessage_deflate(params)
        @deflater = nil
        @inflater = nil
        @server_no_takeover = false
        @client_no_takeover = false
        return if params.nil?

        # RFC 7692 §7.1.2 — server-side deflater uses
        # server_max_window_bits; inflater (decompressing client→server)
        # uses client_max_window_bits.
        server_bits = params[:server_max_window_bits] || 15
        client_bits = params[:client_max_window_bits] || 15
        @server_no_takeover = !!params[:server_no_context_takeover]
        @client_no_takeover = !!params[:client_no_context_takeover]

        # Negative window_bits → raw deflate (no zlib header). RFC 7692
        # is built on raw DEFLATE per §7.2.1.
        @deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -server_bits)
        @inflater = Zlib::Inflate.new(-client_bits)
      end

      # Compress one message with SYNC_FLUSH and strip the trailing
      # `\x00\x00\xff\xff` per RFC 7692 §7.2.1. Resets the deflater
      # context if `server_no_context_takeover` was negotiated.
      def deflate_message(bin)
        original_size = bin.bytesize
        compressed = @deflater.deflate(bin, Zlib::SYNC_FLUSH)
        # The 4-byte trailer is the last 4 bytes of every SYNC_FLUSH
        # output; strip exactly once. If the deflater somehow produced
        # output shorter than 4 bytes (degenerate empty-message case),
        # leave it alone — the inflater appends the trailer back so a
        # missing one would just be re-added.
        if compressed.bytesize >= 4 && compressed.byteslice(-4, 4) == DEFLATE_SYNC_TRAILER
          compressed = compressed.byteslice(0, compressed.bytesize - 4)
        end
        @deflater.reset if @server_no_takeover
        # 2.4-C: observe the compression ratio so operators can confirm
        # permessage-deflate is worth its CPU cost on real chat traffic.
        # Skip the observation when the compressed payload is too small
        # to give a meaningful ratio (degenerate empty-message case) —
        # the histogram bucket layout starts at 1.5×, anything below
        # that is noise.
        observe_deflate_ratio(original_size, compressed.bytesize)
        compressed
      end

      DEFLATE_RATIO_HISTOGRAM = :hyperion_websocket_deflate_ratio
      DEFLATE_RATIO_BUCKETS   = [1.5, 2.0, 5.0, 10.0, 20.0, 50.0].freeze

      def observe_deflate_ratio(original_size, compressed_size)
        return if compressed_size <= 0 || original_size <= 0

        # Lazy-register the family on the active runtime's metrics sink.
        # Idempotent — re-registration with the same shape is a no-op.
        metrics = Hyperion.metrics
        metrics.register_histogram(DEFLATE_RATIO_HISTOGRAM,
                                   buckets: DEFLATE_RATIO_BUCKETS,
                                   label_keys: [])
        ratio = original_size.to_f / compressed_size
        metrics.observe_histogram(DEFLATE_RATIO_HISTOGRAM, ratio)
      rescue StandardError
        nil
      end

      # Inflate a compressed message. Appends the 4-byte sync trailer
      # back per RFC 7692 §7.2.1 then runs `Zlib::Inflate#inflate`.
      # Streams output in chunks bounded by `@max_message_bytes` so a
      # 1 KB compressed payload that decompresses to 100 MB stops at
      # the cap and returns `:too_big`. On Zlib::DataError returns
      # `:inflate_error`.
      def inflate_message(payload)
        framed = String.new(capacity: payload.bytesize + 4, encoding: Encoding::ASCII_8BIT)
        framed << payload.b
        framed << DEFLATE_SYNC_TRAILER

        out = String.new(encoding: Encoding::ASCII_8BIT)
        cap = @max_message_bytes
        too_big = false

        begin
          # Stream in 16 KB chunks so we can short-circuit a compression
          # bomb without materializing the full inflated buffer first.
          # Zlib::Inflate#inflate accepts a single full input; we feed
          # the input in slices and read back after each — same effect.
          offset = 0
          chunk_size = 16 * 1024
          while offset < framed.bytesize
            slice = framed.byteslice(offset, chunk_size)
            offset += slice.bytesize
            piece = @inflater.inflate(slice)
            next if piece.empty?

            if out.bytesize + piece.bytesize > cap
              too_big = true
              break
            end
            out << piece
          end

          # Drain any remaining output Zlib has buffered.
          unless too_big
            tail = @inflater.flush_next_out
            unless tail.nil? || tail.empty?
              if out.bytesize + tail.bytesize > cap
                too_big = true
              else
                out << tail
              end
            end
          end
        rescue Zlib::DataError, Zlib::BufError
          @inflater.reset if @client_no_takeover
          return :inflate_error
        end

        @inflater.reset if @client_no_takeover

        return :too_big if too_big

        out
      end
    end
  end
end
