# frozen_string_literal: true

module Hyperion
  module Http
    # Sendfile — Ruby-side façade over the C-extension Hyperion::Http::Sendfile
    # native helper. Handles the portable concerns the C ext deliberately leaves
    # to userspace:
    #
    #   * Looping on :partial returns from the kernel (short writes).
    #   * Yielding to the fiber scheduler / IO.select on :eagain.
    #   * Falling back to IO.copy_stream when:
    #       - native zero-copy isn't compiled (non-Linux, non-BSD/Darwin host),
    #       - the kernel returned :unsupported (this fd pair can't sendfile),
    #       - the destination IO is a TLS-wrapped socket (kernel can't encrypt).
    #
    # The C ext defines `Hyperion::Http::Sendfile` as a module too — when the
    # extension loads first it pre-creates the constant and we re-open it
    # here to add the higher-level helpers. The native singleton methods
    # (`copy`, `supported?`, `platform_tag`) survive the re-open untouched.
    module Sendfile
      # Maximum bytes per IO.copy_stream call on the userspace fallback. 64 KiB
      # matches the kernel TCP send buffer's typical sweet spot on Linux and
      # mirrors what Puma uses internally — large enough to amortize syscall
      # cost, small enough that a single iteration won't hold the GVL for
      # tens of milliseconds on a slow client.
      USERSPACE_CHUNK = 64 * 1024

      class << self
        # Returns true when the Ruby-side helper can take the fast path for
        # `out_io`. Two conditions:
        #
        #   1. The C ext was compiled with native zero-copy (Linux / BSD /
        #      Darwin). On other hosts `Sendfile.supported?` returns false
        #      (defined in C); we still have a userspace fallback that's
        #      faster than the per-chunk fiber hop, so we report :userspace
        #      from #fast_path_kind in that case.
        #
        #   2. `out_io` is NOT a TLS socket. SSL sockets would need kernel-
        #      TLS support to sendfile, which is rarely enabled.
        def fast_path_kind(out_io)
          return :tls_userspace if tls_socket?(out_io)
          # Native sendfile needs a kernel fd on BOTH ends. StringIO and
          # other userspace-only IOs (custom buffer adapters in specs,
          # `Rack::MockResponse`, …) don't expose one — drop straight to
          # the userspace `IO.copy_stream` loop, which handles those.
          return :userspace unless real_fd?(out_io)
          return :native if respond_to?(:supported?) && supported?

          :userspace
        end

        # High-level helper: copy `len` bytes from `file_io` (regular file)
        # starting at `offset` into `out_io` (TCP socket or other writable
        # IO). Loops on partial writes; yields on EAGAIN.
        #
        # Returns the total number of bytes written. Raises Errno::* on real
        # socket errors (EPIPE, ECONNRESET, …) — same shape as a raw
        # `socket.write` call. The caller's existing rescue handlers (slow-
        # client cleanup, metrics, body#close) keep working unchanged.
        def copy_to_socket(out_io, file_io, offset, len)
          return 0 if len.zero?

          case fast_path_kind(out_io)
          when :native
            native_copy_loop(out_io, file_io, offset, len)
          when :userspace, :tls_userspace
            userspace_copy_loop(out_io, file_io, offset, len)
          end
        end

        private

        def tls_socket?(io)
          defined?(::OpenSSL::SSL::SSLSocket) && io.is_a?(::OpenSSL::SSL::SSLSocket)
        end

        # Does `io` expose a real kernel fd we can hand to sendfile(2)?
        # `IO#fileno` raises NotImplementedError on StringIO / Tempfile-
        # before-flush / custom IO-shaped objects, and TCPSocket wraps a
        # T_FILE so `RB_TYPE_P(obj, T_FILE)` returns true. We probe by
        # calling `fileno` inside a forgiving rescue — anything that
        # answers a non-negative Integer is good enough; everything else
        # routes through the userspace fallback.
        def real_fd?(io)
          return true if io.is_a?(::IO) && !io.closed?

          if io.respond_to?(:to_io)
            inner = io.to_io
            return inner.is_a?(::IO) && !inner.closed?
          end

          if io.respond_to?(:fileno)
            fd = io.fileno
            return fd.is_a?(Integer) && fd >= 0
          end

          false
        rescue StandardError
          false
        end

        # Native loop. The C ext returns [bytes, status] each call; we advance
        # the cursor on :partial / :done and yield on :eagain. :unsupported
        # bails out into the userspace path so the response still completes.
        def native_copy_loop(out_io, file_io, offset, len)
          remaining = len
          cursor    = offset
          total     = 0

          while remaining.positive?
            bytes, status = copy(out_io, file_io, cursor, remaining)

            case status
            when :done
              total += bytes
              return total
            when :partial
              total     += bytes
              cursor    += bytes
              remaining -= bytes
            when :eagain
              wait_writable(out_io)
            when :unsupported
              # Kernel said this fd pair doesn't support sendfile. Fall back
              # mid-stream — the file's read offset is still untouched (we've
              # been passing absolute offsets through to the kernel), so
              # rewind via offset arg into the userspace path.
              file_io.seek(cursor) if file_io.respond_to?(:seek)
              return total + userspace_copy_loop(out_io, file_io, cursor, remaining)
            else
              raise "Hyperion::Http::Sendfile: unexpected status #{status.inspect}"
            end
          end

          total
        end

        # Userspace fallback. Bypasses the per-chunk fiber-hop in
        # WriterContext-style writers by issuing a single IO.copy_stream call
        # with USERSPACE_CHUNK at a time. IO.copy_stream itself handles the
        # internal read+write loop and (on Linux plain TCP) will pick
        # sendfile(2) under the hood; we keep it as a defensive fallback for
        # TLS sockets and non-sendfile-capable hosts.
        def userspace_copy_loop(out_io, file_io, offset, len)
          file_io.seek(offset) if file_io.respond_to?(:seek)
          remaining = len
          total     = 0
          while remaining.positive?
            chunk = remaining < USERSPACE_CHUNK ? remaining : USERSPACE_CHUNK
            written = IO.copy_stream(file_io, out_io, chunk)
            break if written.nil? || written.zero?

            total     += written
            remaining -= written
          end
          total
        end

        # Yield the fiber until `out_io` is writable. Under Async, the
        # scheduler's `io_wait` is invoked transparently by IO#wait_writable.
        # Outside Async we fall back to IO.select. We tolerate IOs that
        # don't expose `wait_writable` (e.g. plain Integer fd, StringIO in
        # tests) by spinning a single CPU yield — those paths are rare in
        # production and the bookkeeping isn't worth a custom waiter.
        def wait_writable(out_io)
          if out_io.respond_to?(:wait_writable)
            out_io.wait_writable
          elsif out_io.respond_to?(:to_io)
            IO.select(nil, [out_io.to_io], nil, 1.0)
          else
            Thread.pass
          end
        end
      end
    end
  end
end
