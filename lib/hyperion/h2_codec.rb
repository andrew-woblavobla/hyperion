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

    # Raised when the per-encoder scratch output buffer can't hold a
    # single frame's encoded bytes. fix-B (2.2.x) — the v2 ABI returns
    # -1 on overflow, which the wrapper translates to this.
    class OutputOverflow < StandardError; end

    # Try to load the native cdylib. Sets `@available = true/false`.
    # Idempotent — second call is a no-op.
    def self.available?
      load!
      @available == true
    end

    # 2.4-A — has the C glue (`Hyperion::H2Codec::CGlue`) loaded AND
    # successfully resolved the Rust HPACK symbols via dlopen/dlsym?
    # Distinct from `available?` because CGlue can fail to load (older
    # systems without dlfcn, hardened sandboxes blocking dlopen) while
    # the Fiddle path still works. When this is true the per-call
    # encode/decode hot path bypasses Fiddle entirely.
    def self.cglue_available?
      load!
      @cglue_available == true
    end

    # 2.11-B — operator-controllable gate that overlays CGlue
    # availability. The Encoder/Decoder hot paths probe this (NOT
    # `cglue_available?`) so a `HYPERION_H2_NATIVE_HPACK=v2` boot can
    # force the Fiddle path even on a host where the C glue loaded
    # successfully. This is the bench-isolation knob 2.11-B's
    # `bench/h2_rails_shape.sh` needs to compare native-v2 against
    # native-v3 honestly — without it, "native" and "cglue" variants
    # would always pick the same physical path.
    #
    # `Http2Handler#initialize` writes the gate based on the env var;
    # tests can flip `@cglue_disabled` directly. Default false (i.e.,
    # gate is OPEN — same physical behavior as 2.4-A through 2.10).
    def self.cglue_active?
      cglue_available? && !@cglue_disabled
    end

    def self.cglue_disabled=(value)
      @cglue_disabled = value ? true : false
    end

    def self.cglue_disabled
      @cglue_disabled == true
    end

    # Force a reload (test seam). Unsets the memoized state so the next
    # `available?` call probes the filesystem again.
    def self.reset!
      @available = nil
      @cglue_available = nil
      @cglue_disabled = false
      @lib = nil
    end

    # Ruby-friendly wrapper around the native encoder. Single instance
    # holds an opaque pointer; `#encode([['name','value'], ...])`
    # returns the wire bytes. The dynamic table state is per-instance.
    #
    # fix-B (2.2.x) — per-encoder scratch buffers eliminate per-call
    # FFI marshalling allocations. Each `Encoder` owns:
    #
    #   * `@scratch_out`  — output buffer reused across encode calls,
    #                       grown lazily if a single frame exceeds the
    #                       starting 16 KiB capacity.
    #   * `@scratch_argv` — packed `(name_off, name_len, val_off, val_len)`
    #                       u64-quad buffer (each header is 32 bytes).
    #   * `@scratch_blob` — concatenated header bytes
    #                       (name_1, value_1, name_2, value_2, …).
    #   * `@scratch_*_ptr` — `Fiddle::Pointer`s pre-cached for the three
    #                        scratch strings; recreated only when the
    #                        underlying string is reallocated by `<<`
    #                        crossing the existing capacity.
    #
    # `#encode` clears the three buffers (length 0, capacity preserved),
    # appends offset/length quads + raw bytes, and dispatches one FFI
    # call to `hyperion_h2_codec_encoder_encode_v2`. The only unavoidable
    # allocation per call is `byteslice` to extract the written bytes
    # — that's the contract `protocol-http2`'s `encode_headers` returns
    # under, so it can't move further.
    class Encoder
      SCRATCH_OUT_DEFAULT = 16_384
      SCRATCH_ARGV_DEFAULT = 4_096
      SCRATCH_BLOB_DEFAULT = 4_096
      private_constant :SCRATCH_OUT_DEFAULT, :SCRATCH_ARGV_DEFAULT, :SCRATCH_BLOB_DEFAULT

      def initialize
        raise 'H2Codec native library unavailable' unless H2Codec.available?

        @ptr = H2Codec.encoder_new
        ObjectSpace.define_finalizer(self, self.class.finalizer(@ptr))

        @scratch_out  = String.new(capacity: SCRATCH_OUT_DEFAULT,  encoding: Encoding::ASCII_8BIT)
        @scratch_argv = String.new(capacity: SCRATCH_ARGV_DEFAULT, encoding: Encoding::ASCII_8BIT)
        @scratch_blob = String.new(capacity: SCRATCH_BLOB_DEFAULT, encoding: Encoding::ASCII_8BIT)
        # Pre-cache the Fiddle::Pointer so the per-call hot path
        # doesn't pay a Pointer.new allocation. The pointer's address
        # tracks the underlying String's buffer; if `<<` later reallocates
        # the buffer we refresh the pointer and bump the recorded
        # capacity.
        @scratch_out_ptr  = Fiddle::Pointer[@scratch_out]
        @scratch_argv_ptr = Fiddle::Pointer[@scratch_argv]
        @scratch_blob_ptr = Fiddle::Pointer[@scratch_blob]
        @scratch_out_capacity  = SCRATCH_OUT_DEFAULT
        @scratch_argv_capacity = SCRATCH_ARGV_DEFAULT
        @scratch_blob_capacity = SCRATCH_BLOB_DEFAULT
        # Per-encoder Int array reused for `pack('Q*', buffer:)` calls.
        # `clear` keeps the array but length-zeros it; the underlying
        # storage capacity is retained by MRI for steady-state reuse.
        @scratch_argv_ints = []
      end

      def self.finalizer(ptr)
        proc { H2Codec.encoder_free(ptr) if H2Codec.available? && ptr }
      end

      def encode(headers)
        return ''.b if headers.empty?

        # 2.4-A — fast path: when the C glue loaded successfully,
        # bypass Fiddle entirely. The C ext walks the headers array,
        # builds the argv quad buffer on the C stack, and calls
        # `hyperion_h2_codec_encoder_encode_v2` directly via a cached
        # function pointer. The only Ruby allocation per call is the
        # final `byteslice(0, written)` which copies the encoded bytes
        # into a new owned String — that's the contract callers rely
        # on (`protocol-http2`'s Compressor#encode returns a String,
        # not a slice into shared mutable memory).
        #
        # 2.11-B — probe `cglue_active?` (NOT `cglue_available?`) so an
        # operator-set `HYPERION_H2_NATIVE_HPACK=v2` boot routes through
        # Fiddle even when the C glue is physically present. Same
        # branch shape; one extra ivar read on the hot path which
        # disappears under YJIT inlining.
        if H2Codec.cglue_active?
          # Pad the scratch String with zero bytes so its length matches
          # capacity — the C ext writes into RSTRING_PTR up to RSTRING_LEN
          # and then truncates back via rb_str_set_len after encoding.
          # The first encode pads the full SCRATCH_OUT_DEFAULT (16 KiB);
          # subsequent calls find the length already at capacity and
          # skip the pad entirely. On the rare oversize-frame case we
          # catch OutputOverflow, grow, and retry — much cheaper than
          # paying a per-call worst-case computation.
          if @scratch_out.bytesize < @scratch_out_capacity
            @scratch_out << ("\x00".b * (@scratch_out_capacity - @scratch_out.bytesize))
          end
          written = nil
          loop do
            written = H2Codec::CGlue.encoder_encode_v3(@ptr.to_i, headers, @scratch_out)
            break
          rescue H2Codec::OutputOverflow
            # Frame exceeded the running scratch capacity — double
            # and retry. The grown scratch persists for subsequent
            # calls so this is a one-time tax per encoder lifetime
            # (per oversized frame size class).
            @scratch_out_capacity *= 2
            @scratch_out = String.new(capacity: @scratch_out_capacity, encoding: Encoding::ASCII_8BIT)
            @scratch_out << ("\x00".b * @scratch_out_capacity)
          end
          # Single allocation: copy the encoded bytes out into an owned
          # String. byteslice on a binary String returns a new
          # ASCII-8BIT String of exactly `written` bytes.
          return @scratch_out.byteslice(0, written)
        end

        # v2 (Fiddle) fallback — kept verbatim from fix-B (2.2.x).
        # 1) Reset scratch buffers (length 0, capacity retained).
        @scratch_blob.clear
        argv_ints = @scratch_argv_ints
        argv_ints.clear

        # 2) Concatenate name+value bytes into one blob, recording
        # (name_off, name_len, value_off, value_len) quads as 4 ints.
        # Append to argv_ints in one go via a `pack('Q*')` at the end —
        # one transient String per call instead of per header.
        offset = 0
        headers.each do |name, value|
          # Avoid `.b` if the source is already binary-encoded — saves
          # one transient String per non-binary header. For frozen
          # binary literals (the common case in protocol-http2), this
          # is a near-zero-cost branch.
          ns = name.encoding == Encoding::ASCII_8BIT ? name : name.b
          vs = value.encoding == Encoding::ASCII_8BIT ? value : value.b
          name_len = ns.bytesize
          val_len = vs.bytesize

          argv_ints << offset << name_len << (offset + name_len) << val_len
          offset += name_len + val_len
          @scratch_blob << ns << vs
        end

        # 3) Pack all argv ints into the per-encoder scratch via the
        # `pack(buffer:)` keyword — Ruby reuses the existing String's
        # buffer (length-truncating to 0 first), so this is a zero-alloc
        # path on the steady state. The argv ints array itself reuses
        # the same Array allocation across calls (we `clear`ed it
        # above; capacity is retained by RArray internals).
        @scratch_argv.clear
        argv_ints.pack('Q*', buffer: @scratch_argv)

        argv_bytes = @scratch_argv.bytesize
        blob_bytes = @scratch_blob.bytesize

        # 3) Make sure the output scratch can hold the worst-case
        # encoded size. Reuse the existing buffer when it already fits;
        # only grow when a single frame exceeds the running capacity.
        worst_case = blob_bytes + (headers.length * 8) + 64
        if worst_case > @scratch_out_capacity
          new_cap = @scratch_out_capacity
          new_cap *= 2 while new_cap < worst_case
          @scratch_out = String.new(capacity: new_cap, encoding: Encoding::ASCII_8BIT)
          @scratch_out_capacity = new_cap
        end

        # 4) Refresh Fiddle pointers. `<<` and `clear` may have caused
        # MRI to reallocate the underlying String buffer (different
        # RSTRING_PTR), so the cached pointers can be stale. Refresh
        # them once per encode call — three Pointer wrapper objects vs
        # the v1 path's `2 * headers.length` Pointer wrappers.
        @scratch_blob_ptr = Fiddle::Pointer[@scratch_blob] if blob_bytes.positive?
        @scratch_argv_ptr = Fiddle::Pointer[@scratch_argv] if argv_bytes.positive?
        @scratch_out_ptr  = Fiddle::Pointer[@scratch_out]

        # 5) One FFI call. Returns bytes_written, -1 on overflow, -2 on bad args.
        written = H2Codec.encoder_encode_v2(@ptr,
                                            @scratch_blob_ptr, blob_bytes,
                                            @scratch_argv_ptr, headers.length,
                                            @scratch_out_ptr, @scratch_out_capacity)
        if written == -1
          raise H2Codec::OutputOverflow,
                "H2Codec encoder output buffer overflow (#{worst_case} bytes needed, " \
                "#{@scratch_out_capacity} available)"
        end
        raise "H2Codec encoder failed (rc=#{written})" if written.negative?

        # 6) Read `written` bytes from the C-written scratch into a
        # fresh ASCII-8BIT String. `Fiddle::Pointer#to_str(len)` copies
        # exactly `len` bytes once — this is the ONE unavoidable
        # allocation per encode call (Ruby strings can't alias
        # arbitrary memory, and the caller's contract is to receive an
        # owned String). Cheaper than v1 because we copy exactly
        # `len` bytes here instead of `capacity` bytes during
        # pre-fill + a `byteslice` of the encoded prefix.
        @scratch_out_ptr.to_str(written)
      end
    end

    # Ruby-friendly decoder wrapper. `#decode(bytes)` → array of
    # [name, value] byte pairs.
    class Decoder
      DECODER_SCRATCH_DEFAULT = 16_384
      private_constant :DECODER_SCRATCH_DEFAULT

      def initialize
        raise 'H2Codec native library unavailable' unless H2Codec.available?

        @ptr = H2Codec.decoder_new
        ObjectSpace.define_finalizer(self, self.class.finalizer(@ptr))
        # 2.4-A — per-decoder reusable scratch buffer for the v3 path.
        @scratch_out = String.new(capacity: DECODER_SCRATCH_DEFAULT, encoding: Encoding::ASCII_8BIT)
        @scratch_out_capacity = DECODER_SCRATCH_DEFAULT
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

        # 2.4-A — fast path: reuse a per-decoder scratch and dispatch
        # through the C glue. The Rust ABI writes `[u32 name_len][name]
        # [u32 val_len][val]` repeated; we unpack that in Ruby.
        # 2.11-B — `cglue_active?` overlays an operator-set v2 force.
        if H2Codec.cglue_active?
          if capacity > @scratch_out_capacity
            new_cap = @scratch_out_capacity
            new_cap *= 2 while new_cap < capacity
            @scratch_out = String.new(capacity: new_cap, encoding: Encoding::ASCII_8BIT)
            @scratch_out_capacity = new_cap
          end
          # Pad the scratch to its full capacity so RSTRING_LEN ==
          # @scratch_out_capacity inside the C ext (the ext reads
          # RSTRING_LEN to know the writable region size).
          if @scratch_out.bytesize < @scratch_out_capacity
            @scratch_out << ("\x00".b * (@scratch_out_capacity - @scratch_out.bytesize))
          end
          written = H2Codec::CGlue.decoder_decode_v3(@ptr.to_i, bytes, @scratch_out)
          return [] if written.zero?

          return unpack_headers(@scratch_out.byteslice(0, written))
        end

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
      # fix-B (2.2.x) — v2 flat-blob encode entry.
      # Signature: (handle, blob_ptr, blob_len, argv_ptr, argv_count, out_ptr, out_cap) -> i64
      # Sizes are passed as size_t so Fiddle::TYPE_SIZE_T matches the
      # Rust `usize` exactly on both 64-bit Linux and macOS arm64.
      @encoder_enc_v2_fn = Fiddle::Function.new(@lib['hyperion_h2_codec_encoder_encode_v2'],
                                                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T,
                                                 Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T,
                                                 Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T],
                                                Fiddle::TYPE_LONG_LONG)
      @decoder_new_fn  = Fiddle::Function.new(@lib['hyperion_h2_codec_decoder_new'],
                                              [], Fiddle::TYPE_VOIDP)
      @decoder_free_fn = Fiddle::Function.new(@lib['hyperion_h2_codec_decoder_free'],
                                              [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      @decoder_dec_fn  = Fiddle::Function.new(@lib['hyperion_h2_codec_decoder_decode'],
                                              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT,
                                               Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                                              Fiddle::TYPE_INT)

      @available = true

      # 2.4-A — try to install the C glue with the same path the
      # Fiddle loader just used. CGlue is defined by the bundled C
      # extension (`hyperion_http/hyperion_http.bundle`); if that
      # extension didn't compile or the dlopen fails, `@cglue_available`
      # stays nil and Encoder/Decoder transparently fall back to the
      # v2 (Fiddle) path. No warning on this branch — it's purely a
      # perf optimization, not a correctness gate.
      install_cglue(path)
    rescue Fiddle::DLError, StandardError => e
      warn "[hyperion] H2Codec failed to load (#{e.class}: #{e.message}); using Ruby fallback"
      @lib = nil
      @available = false
      @cglue_available = false
    end
    # rubocop:enable Metrics/MethodLength

    # 2.4-A — wire the C extension's dlopen-based path. We require the
    # bundled C extension (already loaded by `c_parser.rb` at gem boot
    # in normal use, but we guard the constant lookup in case someone
    # required `hyperion/h2_codec` directly without the C ext). Returns
    # true iff CGlue is now installed and `encoder_encode_v3` is safe
    # to call.
    def self.install_cglue(path)
      @cglue_available = false
      return unless defined?(Hyperion::H2Codec::CGlue)
      return unless Hyperion::H2Codec::CGlue.respond_to?(:install)

      @cglue_available = Hyperion::H2Codec::CGlue.install(path) ? true : false
    rescue StandardError
      @cglue_available = false
    end

    def self.candidate_paths
      gem_lib = File.expand_path('../hyperion_h2_codec', __dir__)
      ext_target = File.expand_path('../../ext/hyperion_h2_codec/target/release', __dir__)
      # 2.11-B fix: order suffixes by host OS. Pre-2.11-B this was a
      # static `[dylib, so]` order, which broke on Linux hosts that
      # had a stale macOS `.dylib` on the path (e.g. a developer rsync
      # leaking the `target/release` artifact across platforms). Fiddle
      # would try the `.dylib` first, choke on the Mach-O binary with
      # `ArgumentError: invalid byte sequence in UTF-8` from libffi,
      # and the rescue in `load!` would silently fall back to the Ruby
      # HPACK path with no warning visible to bench harnesses.
      #
      # Ordering by `host_os` makes Linux pick `.so` first and ignore
      # any orphan `.dylib`; macOS keeps the `.dylib`-first behavior
      # for back-compat with existing dev environments.
      suffixes = if /darwin|mac/i.match?(RbConfig::CONFIG['host_os'])
                   %w[libhyperion_h2_codec.dylib libhyperion_h2_codec.so]
                 else
                   %w[libhyperion_h2_codec.so libhyperion_h2_codec.dylib]
                 end
      suffixes.flat_map { |name| [File.join(gem_lib, name), File.join(ext_target, name)] }
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

    # fix-B (2.2.x) — v2 flat-blob encode. See lib.rs:hyperion_h2_codec_encoder_encode_v2.
    def self.encoder_encode_v2(ptr, blob, blob_len, argv, argv_count, out, out_cap)
      @encoder_enc_v2_fn.call(ptr, blob, blob_len, argv, argv_count, out, out_cap)
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
