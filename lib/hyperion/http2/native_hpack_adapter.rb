# frozen_string_literal: true

require_relative '../h2_codec'

module Hyperion
  module Http2
    # Phase 10 (RFC §3 Phase 6c, 2.2.0) — adapter shim that exposes the
    # Rust HPACK encoder/decoder behind the same call surface
    # `protocol-http2`'s connection uses today (`#encode_headers(headers)`
    # → bytes, `#decode_headers(bytes)` → array of [name, value]).
    #
    # The adapter is constructed once per HTTP/2 connection, holds an
    # `Hyperion::H2Codec::Encoder` and `Decoder` (each owns its own RFC 7541
    # dynamic table), and is consulted only from the encode/decode
    # serialization point inside `protocol-http2::Connection`. The framer,
    # stream state machine, flow control, and HEADERS/CONTINUATION
    # framing all stay in `protocol-http2` — Phase 10's scope is the
    # HPACK byte-pump only. Replacing the framer in Rust is left for a
    # future Phase 6d.
    #
    # When `Hyperion::H2Codec.available?` is false (no Rust toolchain at
    # gem install, ABI mismatch, JRuby, etc.) callers MUST NOT
    # construct `NativeHpackAdapter` — the substitution layer in
    # `Http2Handler#build_server` skips installation in that case and
    # the connection keeps using `protocol-http2`'s pure-Ruby
    # Compressor/Decompressor.
    #
    # Headers are passed in/returned as `[[name_string, value_string], …]`
    # — the same shape `protocol-http2` already uses internally, so the
    # substitution is byte-for-byte transparent at the protocol-http2
    # boundary.
    class NativeHpackAdapter
      # @raise [RuntimeError] if the native codec isn't loaded.
      def initialize
        unless Hyperion::H2Codec.available?
          raise 'NativeHpackAdapter requires Hyperion::H2Codec.available? — guard at the call site'
        end

        @encoder = Hyperion::H2Codec::Encoder.new
        @decoder = Hyperion::H2Codec::Decoder.new
      end

      # Encode a header block via the native HPACK encoder. The
      # encoder's dynamic table persists across calls (HPACK is
      # stateful per direction per connection), so two HEADERS frames
      # encoded back-to-back on the same adapter share table state
      # exactly as RFC 7541 requires.
      #
      # @param headers [Array<Array(String, String)>]
      # @param buffer [String] optional output buffer; bytes are
      #   appended so the Rust encoder's output appends to whatever
      #   the caller already accumulated. Returned for chaining.
      # @return [String] the buffer (with newly-encoded bytes appended).
      def encode_headers(headers, buffer = String.new.b)
        bytes = @encoder.encode(headers)
        buffer << bytes
        buffer
      end

      # Decode a HEADERS/CONTINUATION block via the native HPACK
      # decoder. Updates the decoder's dynamic table.
      #
      # @param data [String] the wire bytes for one header block.
      # @return [Array<Array(String, String)>]
      def decode_headers(data)
        @decoder.decode(data)
      end
    end
  end
end
