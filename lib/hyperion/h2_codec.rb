# frozen_string_literal: true

require 'fiddle'
require 'fiddle/import'

module Hyperion
  # Phase 6 (RFC §3 2.0.0) — native HPACK encoder/decoder + frame
  # primitives implemented in Rust. The Ruby side here is a thin
  # Fiddle-based loader; all real work happens in
  # `ext/hyperion_h2_codec`.
  #
  # The integration is OPT-IN at runtime: `Http2Handler` checks
  # `Hyperion::H2Codec.available?` and uses the native path only when
  # the cdylib loaded successfully. Operators on systems without Rust
  # (older Debians, locked-down CI runners, JRuby) get the existing
  # `protocol-http2` Ruby HPACK path automatically — no boot-time
  # error.
  #
  # ABI version: bumped on any breaking C ABI change. Ruby refuses to
  # load a binary that disagrees so a stale on-disk codec from an
  # older gem install can't crash the process.
  module H2Codec
    EXPECTED_ABI = 1

    # Try to load the native cdylib. Sets `@available = true/false`.
    # Idempotent — second call is a no-op.
    def self.available?
      load!
      @available == true
    end

    # Force a reload (test seam). Unsets the memoized state so the next
    # `available?` call probes the filesystem again.
    def self.reset!
      @available = nil
      @lib = nil
    end

    # Ruby-friendly wrapper around the native encoder. Single instance
    # holds an opaque pointer; `#encode([['name','value'], ...])`
    # returns the wire bytes. The dynamic table state is per-instance.
    class Encoder
      def initialize
        raise 'H2Codec native library unavailable' unless H2Codec.available?

        @ptr = H2Codec.encoder_new
        ObjectSpace.define_finalizer(self, self.class.finalizer(@ptr))
      end

      def self.finalizer(ptr)
        proc { H2Codec.encoder_free(ptr) if H2Codec.available? && ptr }
      end

      def encode(headers)
        return ''.b if headers.empty?

        names_ptrs = []
        name_lens = []
        val_ptrs = []
        val_lens = []
        # Hold onto the source strings for the duration of the call so
        # the byte pointers we extract stay valid across the FFI hop.
        keepalive = []
        headers.each do |name, value|
          ns = name.to_s.b
          vs = value.to_s.b
          keepalive << ns << vs
          names_ptrs << Fiddle::Pointer[ns].to_i
          name_lens << ns.bytesize
          val_ptrs << Fiddle::Pointer[vs].to_i
          val_lens << vs.bytesize
        end

        names_buf = names_ptrs.pack('Q*')
        name_lens_buf = name_lens.pack('L*')
        val_buf = val_ptrs.pack('Q*')
        val_lens_buf = val_lens.pack('L*')

        capacity = headers.sum { |n, v| 8 + n.to_s.bytesize + v.to_s.bytesize } + 64
        out = (+'').b
        out.force_encoding(Encoding::ASCII_8BIT)
        out << ("\x00".b * capacity)

        written = H2Codec.encoder_encode(@ptr,
                                         names_buf, name_lens_buf,
                                         val_buf, val_lens_buf,
                                         headers.length,
                                         out, capacity)
        raise "H2Codec encoder failed (rc=#{written})" if written.negative?

        out.byteslice(0, written)
      end
    end

    # Ruby-friendly decoder wrapper. `#decode(bytes)` → array of
    # [name, value] byte pairs.
    class Decoder
      def initialize
        raise 'H2Codec native library unavailable' unless H2Codec.available?

        @ptr = H2Codec.decoder_new
        ObjectSpace.define_finalizer(self, self.class.finalizer(@ptr))
      end

      def self.finalizer(ptr)
        proc { H2Codec.decoder_free(ptr) if H2Codec.available? && ptr }
      end

      def decode(bytes)
        bytes = bytes.to_s.b
        return [] if bytes.empty?

        # Decoded pairs can be ~larger than the wire because Huffman
        # decoding inflates. 8x is a generous upper bound for RFC 7541
        # — a single-bit Huffman input can decode to 8 bits but
        # adding the framing bytes per pair makes 8x conservative.
        capacity = (bytes.bytesize * 8) + 4096
        out = (+'').b
        out.force_encoding(Encoding::ASCII_8BIT)
        out << ("\x00".b * capacity)

        written = H2Codec.decoder_decode(@ptr, bytes, bytes.bytesize, out, capacity)
        raise "H2Codec decoder failed (rc=#{written})" if written.negative?

        unpack_headers(out.byteslice(0, written))
      end

      private

      def unpack_headers(buf)
        result = []
        off = 0
        loop do
          break if off >= buf.bytesize

          name_len = buf.byteslice(off, 4).unpack1('L<')
          off += 4
          name = buf.byteslice(off, name_len)
          off += name_len
          val_len = buf.byteslice(off, 4).unpack1('L<')
          off += 4
          value = buf.byteslice(off, val_len)
          off += val_len
          result << [name, value]
        end
        result
      end
    end

    # ---- Internal: Fiddle binding plumbing.

    # rubocop:disable Metrics/MethodLength
    def self.load!
      return unless @available.nil?

      @available = false

      path = candidate_paths.find { |p| File.exist?(p) }
      unless path
        @lib = nil
        return
      end

      @lib = Fiddle.dlopen(path)

      @abi_fn = Fiddle::Function.new(@lib['hyperion_h2_codec_abi_version'],
                                     [], Fiddle::TYPE_INT)
      abi = @abi_fn.call
      if abi != EXPECTED_ABI
        warn "[hyperion] H2Codec ABI mismatch (got #{abi}, expected #{EXPECTED_ABI}); using Ruby fallback"
        @lib = nil
        return
      end

      @encoder_new_fn  = Fiddle::Function.new(@lib['hyperion_h2_codec_encoder_new'],
                                              [], Fiddle::TYPE_VOIDP)
      @encoder_free_fn = Fiddle::Function.new(@lib['hyperion_h2_codec_encoder_free'],
                                              [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      @encoder_enc_fn  = Fiddle::Function.new(@lib['hyperion_h2_codec_encoder_encode'],
                                              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                               Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT,
                                               Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                                              Fiddle::TYPE_INT)
      @decoder_new_fn  = Fiddle::Function.new(@lib['hyperion_h2_codec_decoder_new'],
                                              [], Fiddle::TYPE_VOIDP)
      @decoder_free_fn = Fiddle::Function.new(@lib['hyperion_h2_codec_decoder_free'],
                                              [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      @decoder_dec_fn  = Fiddle::Function.new(@lib['hyperion_h2_codec_decoder_decode'],
                                              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT,
                                               Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                                              Fiddle::TYPE_INT)

      @available = true
    rescue Fiddle::DLError, StandardError => e
      warn "[hyperion] H2Codec failed to load (#{e.class}: #{e.message}); using Ruby fallback"
      @lib = nil
      @available = false
    end
    # rubocop:enable Metrics/MethodLength

    def self.candidate_paths
      gem_lib = File.expand_path('../hyperion_h2_codec', __dir__)
      ext_target = File.expand_path('../../ext/hyperion_h2_codec/target/release', __dir__)
      %w[libhyperion_h2_codec.dylib libhyperion_h2_codec.so].flat_map do |name|
        [File.join(gem_lib, name), File.join(ext_target, name)]
      end
    end

    # FFI wrappers — kept thin so callers don't see Fiddle::Pointer
    # types. Each method is a one-liner that the Encoder/Decoder
    # classes above invoke.
    def self.encoder_new
      @encoder_new_fn.call
    end

    def self.encoder_free(ptr)
      @encoder_free_fn.call(ptr)
    end

    def self.encoder_encode(ptr, names, name_lens, vals, val_lens, count, out, cap)
      @encoder_enc_fn.call(ptr, names, name_lens, vals, val_lens, count, out, cap)
    end

    def self.decoder_new
      @decoder_new_fn.call
    end

    def self.decoder_free(ptr)
      @decoder_free_fn.call(ptr)
    end

    def self.decoder_decode(ptr, input, in_len, out, cap)
      @decoder_dec_fn.call(ptr, input, in_len, out, cap)
    end
  end
end
