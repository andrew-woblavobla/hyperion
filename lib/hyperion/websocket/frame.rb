# frozen_string_literal: true

module Hyperion
  # WS-3 (2.1.0) — RFC 6455 frame ser/de + XOR-unmask primitives.
  #
  # This module is intentionally narrow: it owns "given a buffer of socket
  # bytes, parse one frame" and "given an opcode + payload, build a
  # serialized frame". WS-1 (the hijacked-socket loop) and WS-2 (the
  # handshake) compose these primitives — they don't reach into
  # Hyperion::WebSocket::CFrame directly.
  #
  # Two layers:
  #
  #   * `Hyperion::WebSocket::CFrame` — the C ext singleton (defined by
  #     ext/hyperion_http/websocket.c when the .bundle/.so loads).
  #     Methods: `unmask(payload, key)`, `parse(buf, offset = 0)`,
  #     `build(opcode, payload, fin:, mask:, mask_key:)`.
  #
  #   * `Hyperion::WebSocket::Parser` / `::Builder` — Ruby façades over
  #     the C calls with a more idiomatic API (Frame structs, Symbol
  #     opcodes, ProtocolError on malformed frames).
  #
  # If the C ext is unavailable (JRuby, TruffleRuby, a build where
  # extconf.rb fell back gracefully) the same module names are bound to
  # a pure-Ruby fallback declared at the bottom of this file.  The
  # fallback is correct but slow (≥ 5× slower XOR than C) — it's a
  # safety net so the gem never refuses to require.
  module WebSocket
    # Per-message struct returned by `Parser.parse`.  `opcode` is a
    # Symbol (`:text`, `:binary`, …); `payload` is a freshly-allocated
    # binary String already unmasked. `rsv1` is the per-message-deflate
    # marker (RFC 7692 §6); always false on parsed control frames (the
    # parser would have errored out), only ever true on text/binary/
    # continuation frames when the connection negotiated the extension.
    Frame = Struct.new(:fin, :opcode, :payload, :rsv1, keyword_init: true) do
      # Defaults — keep `Frame.new(fin:, opcode:, payload:)` working for
      # the (overwhelming) majority of call sites that don't care about
      # rsv1. New WS-2.3 callers pass `rsv1:` explicitly when building a
      # compressed frame.
      def initialize(fin:, opcode:, payload:, rsv1: false)
        super(fin: fin, opcode: opcode, payload: payload, rsv1: rsv1)
      end
    end

    # Symbolic opcode table.  Reverse table built lazily for the
    # parse-side lookup. Frozen so accidental mutation can't corrupt
    # the parse hot path.
    OPCODES = {
      continuation: 0x0,
      text: 0x1,
      binary: 0x2,
      close: 0x8,
      ping: 0x9,
      pong: 0xA
    }.freeze
    OPCODE_NAMES = OPCODES.invert.freeze

    class ProtocolError < StandardError; end

    NATIVE_AVAILABLE = defined?(::Hyperion::WebSocket::CFrame) &&
                       ::Hyperion::WebSocket::CFrame.respond_to?(:parse)

    module Parser
      # Parse one frame out of `buf` starting at `offset`. Does NOT mutate
      # or consume `buf` — the caller is responsible for advancing its
      # cursor by `frame_total_len` (see `parse_with_cursor` below).
      #
      # Returns:
      #   * a Hyperion::WebSocket::Frame on success
      #   * `:incomplete` if `buf[offset..]` doesn't yet hold a full frame
      #
      # Raises Hyperion::WebSocket::ProtocolError on malformed frames
      # (RSV bits set without a negotiated extension, unknown opcode,
      # control frame > 125 bytes, fragmented control frame, 64-bit
      # length with high bit set).
      def self.parse(buf, offset = 0)
        result = ::Hyperion::WebSocket::CFrame.parse(buf, offset)
        return result if result == :incomplete

        raise ProtocolError, 'malformed WebSocket frame' if result == :error

        fin, opcode, payload_len, masked, mask_key, payload_offset, _frame_total_len, rsv1 = result

        opcode_sym = OPCODE_NAMES[opcode] ||
                     raise(ProtocolError, "unknown opcode 0x#{opcode.to_s(16)}")

        payload =
          if payload_len.zero?
            (+'').b
          else
            slice = buf.byteslice(payload_offset, payload_len)
            masked ? ::Hyperion::WebSocket::CFrame.unmask(slice, mask_key) : slice.b
          end

        Frame.new(fin: fin, opcode: opcode_sym, payload: payload, rsv1: rsv1 ? true : false)
      end

      # Lower-level variant exposing the raw 7-tuple from the C parser
      # AND the cursor advance the caller should apply. WS-1's read loop
      # uses this form to drain multiple frames out of a single buffer
      # in one pass without re-parsing the leading bytes.
      #
      # Returns `[Frame, frame_total_len]` on success, `:incomplete` if
      # not enough bytes have arrived yet.  Raises ProtocolError on
      # malformed input.
      def self.parse_with_cursor(buf, offset = 0)
        result = ::Hyperion::WebSocket::CFrame.parse(buf, offset)
        return result if result == :incomplete

        raise ProtocolError, 'malformed WebSocket frame' if result == :error

        fin, opcode, payload_len, masked, mask_key, payload_offset, frame_total_len, rsv1 = result

        opcode_sym = OPCODE_NAMES[opcode] ||
                     raise(ProtocolError, "unknown opcode 0x#{opcode.to_s(16)}")

        payload =
          if payload_len.zero?
            (+'').b
          else
            slice = buf.byteslice(payload_offset, payload_len)
            masked ? ::Hyperion::WebSocket::CFrame.unmask(slice, mask_key) : slice.b
          end

        [
          Frame.new(fin: fin, opcode: opcode_sym, payload: payload, rsv1: rsv1 ? true : false),
          frame_total_len
        ]
      end
    end

    module Builder
      # Build a serialized frame ready for `socket.write`.
      #
      #   opcode  — Symbol from OPCODES.keys (`:text`, `:binary`, …)
      #             OR Integer (raw opcode bits).
      #   payload — String. Coerced to ASCII-8BIT internally so callers
      #             may pass UTF-8 text frames without manual conversion.
      #   fin     — true/false. RFC 6455 §5.4 fragmentation: false on all
      #             but the final frame of a multi-frame message.
      #   mask    — server frames are unmasked (default).  Clients MUST
      #             pass mask: true and a 4-byte mask_key.
      #
      # Control frames (close/ping/pong) MUST have payload <= 125 bytes
      # and MUST have fin: true; the C builder raises ArgumentError if
      # those invariants are violated, which we re-raise as-is.
      def self.build(opcode:, payload: '', fin: true, mask: false, mask_key: nil, rsv1: false)
        opcode_int = opcode.is_a?(Symbol) ? OPCODES.fetch(opcode) : Integer(opcode)
        bin_payload = payload.is_a?(String) ? payload.b : payload.to_s.b

        if mask && mask_key.nil?
          # Caller didn't supply a key — generate one with SecureRandom
          # so client-side tests / scripted clients don't have to.
          require 'securerandom'
          mask_key = SecureRandom.bytes(4)
        end

        ::Hyperion::WebSocket::CFrame.build(
          opcode_int,
          bin_payload,
          fin: fin,
          mask: mask,
          mask_key: mask_key,
          rsv1: rsv1
        )
      end
    end

    # Pure-Ruby fallback used when the C ext is missing.  Same public
    # surface as `CFrame` so the Parser / Builder façades above don't
    # need to branch on `NATIVE_AVAILABLE` per call.  Performance is
    # ~5–10× worse on XOR — fine for a safety net, fine for JRuby
    # interop, NOT recommended for the production hot path.
    module RubyFrame
      module_function

      def unmask(payload, key)
        raise ArgumentError, 'mask_key must be 4 bytes' if key.bytesize != 4

        out = String.new(capacity: payload.bytesize, encoding: Encoding::BINARY)
        bytes  = payload.bytes
        kbytes = key.bytes
        bytes.each_with_index do |b, i|
          out << (b ^ kbytes[i & 0x3]).chr
        end
        out
      end

      def parse(buf, offset = 0)
        return :incomplete if offset > buf.bytesize

        avail = buf.bytesize - offset
        return :incomplete if avail < 2

        b0 = buf.getbyte(offset)
        b1 = buf.getbyte(offset + 1)

        fin    = (b0 & 0x80) != 0
        rsv1   = (b0 & 0x40) != 0
        rsv2   = (b0 & 0x20) != 0
        rsv3   = (b0 & 0x10) != 0
        opcode = b0 & 0x0F
        masked = (b1 & 0x80) != 0
        len7   = b1 & 0x7F

        # RFC 7692 §6: RSV1 is the permessage-deflate marker. Allow it
        # through in the parse tuple; the Connection wrapper rejects
        # RSV1 when no extension was negotiated. RSV2/RSV3 are reserved
        # with no defined semantics → reject.
        return :error if rsv2 || rsv3

        return :error unless [0x0, 0x1, 0x2, 0x8, 0x9, 0xA].include?(opcode)

        if opcode >= 0x8
          return :error unless fin
          return :error if len7 > 125
          # RFC 7692 §6.1 — control frames MUST NOT be compressed.
          return :error if rsv1
        end

        header_len = 2
        payload_len =
          case len7
          when 0..125
            len7
          when 126
            return :incomplete if avail < header_len + 2

            v = (buf.getbyte(offset + 2) << 8) | buf.getbyte(offset + 3)
            header_len += 2
            v
          else
            return :incomplete if avail < header_len + 8

            return :error if (buf.getbyte(offset + 2) & 0x80) != 0

            v = 0
            8.times { |i| v = (v << 8) | buf.getbyte(offset + 2 + i) }
            header_len += 8
            v
          end

        mask_key = nil
        if masked
          return :incomplete if avail < header_len + 4

          mask_key = buf.byteslice(offset + header_len, 4)
          header_len += 4
        end

        payload_offset = offset + header_len
        frame_total_len = header_len + payload_len
        return :incomplete if avail < frame_total_len

        [fin, opcode, payload_len, masked, mask_key, payload_offset, frame_total_len, rsv1]
      end

      def build(opcode, payload, fin: true, mask: false, mask_key: nil, rsv1: false)
        raise ArgumentError, "unknown opcode 0x#{opcode.to_s(16)}" unless [0x0, 0x1, 0x2, 0x8, 0x9,
                                                                           0xA].include?(opcode)

        payload_len = payload.bytesize

        if opcode >= 0x8
          raise ArgumentError, 'control frame must have fin=true' unless fin
          raise ArgumentError, 'control frame payload exceeds 125 bytes' if payload_len > 125
          raise ArgumentError, 'control frame must not have rsv1=true' if rsv1
        end

        if mask
          raise ArgumentError, 'mask: true requires a 4-byte mask_key' if mask_key.nil?
          raise ArgumentError, 'mask_key must be 4 bytes' if mask_key.bytesize != 4
        end

        out = String.new(encoding: Encoding::BINARY)
        out << ((fin ? 0x80 : 0x00) | (rsv1 ? 0x40 : 0x00) | (opcode & 0x0F)).chr
        mask_bit = mask ? 0x80 : 0x00

        if payload_len < 126
          out << (mask_bit | payload_len).chr
        elsif payload_len <= 0xFFFF
          out << (mask_bit | 126).chr
          out << ((payload_len >> 8) & 0xFF).chr
          out << (payload_len & 0xFF).chr
        else
          out << (mask_bit | 127).chr
          8.times { |i| out << ((payload_len >> ((7 - i) * 8)) & 0xFF).chr }
        end

        if mask
          out << mask_key.b
          out << unmask(payload.b, mask_key) # XOR is symmetric
        else
          out << payload.b
        end

        out
      end
    end

    # If the C ext didn't load, point CFrame at the Ruby fallback.  We
    # do this AFTER defining the façades above so they can call
    # `CFrame.parse` etc. uniformly.
    unless defined?(::Hyperion::WebSocket::CFrame) &&
           ::Hyperion::WebSocket::CFrame.respond_to?(:parse)
      CFrame = RubyFrame
    end
  end
end
