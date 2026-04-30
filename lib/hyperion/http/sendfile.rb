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
    # (`copy`, `copy_small`, `copy_splice`, `supported?`, `splice_supported?`,
    # `small_file_threshold`, `platform_tag`) survive the re-open untouched.
    #
    # 2.0.1 Phase 8 — close static-file rps gaps
    # -------------------------------------------
    # The 2.0.0 BENCH report had two rows where Hyperion still lost Puma on
    # rps:
    #
    #   * 8 KB static at -t 5 (-w 1)  — 121 r/s vs Puma 1,246 r/s (10× loss)
    #   * 1 MiB static at -t 5 (-w 1) — 1,809 r/s vs Puma 2,139 r/s (-15%)
    #
    # Diagnosis (see ext/hyperion_http/sendfile.c header):
    #
    #   8 KB row: every request paid ~40 ms in EAGAIN-yield-retry cycles
    #     because sendfile against an 8 KB file routinely hits EAGAIN once
    #     before the kernel TCP send buffer accepts it; with -t 5 only 5
    #     fibers can be in-flight, and 4 sleeping in EAGAIN-yield-retry
    #     starves the wrk loop.
    #
    #   1 MiB row: sendfile(2) re-derives some bookkeeping per call that
    #     splice(2) through a pipe-tee avoids.
    #
    # Fixes:
    #
    #   8a. Small-file fast path. If file_size <= 64 KiB we use the new
    #       `copy_small` C primitive: heap-buffered read + write under the
    #       GVL released, EAGAIN polled with a short select() instead of
    #       fiber-yielding. The transfer completes in microseconds rather
    #       than dancing with the fiber scheduler.
    #
    #   8b. Linux splice path (2.0.1 / disabled / re-enabled in 2.2.0). For
    #       files > 64 KiB on Linux we try `copy_splice` first (file_fd ->
    #       fresh pipe -> sock_fd with SPLICE_F_MOVE | SPLICE_F_MORE).
    #       Falls back to plain `copy` (sendfile) if the runtime kernel
    #       returns :unsupported, if `splice_supported?` is false (non-
    #       Linux builds), or if any SystemCallError surfaces from the
    #       primitive.
    #
    # 2.2.0 — splice path re-enabled with fresh per-request pipe pair
    # ---------------------------------------------------------------
    # 2.0.1 disabled the splice route from copy_to_socket because the
    # cached per-thread pipe pair leaked residual bytes between requests:
    # if `splice(file -> pipe)` succeeded but `splice(pipe -> socket)`
    # failed mid-transfer (peer closed), the unread bytes stayed in the
    # pipe and went out on the NEXT connection's socket.  2.2.0 fixes
    # this at the lifecycle layer rather than abandoning the path —
    # `copy_splice` now opens a fresh `pipe2(O_CLOEXEC | O_NONBLOCK)`
    # pair on every call and closes both fds on every exit path.  Two
    # extra syscalls per call vs the cached layout, but correctness is
    # unconditional: a pipe never carries bytes for more than one
    # transfer.
    module Sendfile
      # Maximum bytes per IO.copy_stream call on the userspace fallback. 64 KiB
      # matches the kernel TCP send buffer's typical sweet spot on Linux and
      # mirrors what Puma uses internally — large enough to amortize syscall
      # cost, small enough that a single iteration won't hold the GVL for
      # tens of milliseconds on a slow client.
      USERSPACE_CHUNK = 64 * 1024

      # 2.0.1 Phase 8a small-file threshold. Files <= this size take the
      # synchronous read+write path with no fiber-yield. Mirrors the C
      # constant `HYP_SMALL_FILE_THRESHOLD` — kept in sync via the
      # `small_file_threshold` introspection method on hosts where the
      # native ext is loaded.
      SMALL_FILE_THRESHOLD = 64 * 1024

      # 2.2.0 — splice fires for files strictly larger than this many
      # bytes.  Below the threshold the small-file synchronous path
      # (`copy_small`) wins outright; between the small-file ceiling
      # and this constant plain sendfile(2) is fast enough that the
      # extra pipe2 + 2× close round-trip isn't worth it.  Set equal
      # to SMALL_FILE_THRESHOLD so anything above the small-file path
      # gets the splice attempt.
      SPLICE_THRESHOLD = SMALL_FILE_THRESHOLD

      class << self
        # 2.2.0 — runtime probe for the splice path.  `splice_supported?`
        # in the C ext only reports compile-time availability (true on
        # Linux builds, false elsewhere).  At runtime an old kernel can
        # still reject splice(2) with ENOSYS / EINVAL the first time we
        # call it; once observed, we cache the answer for the lifetime
        # of the process so subsequent requests don't pay the failed-
        # syscall round-trip.  Default value tracks the C ext flag so
        # specs that assert `splice_supported? == true` on Linux still
        # pass without an explicit probe; `mark_splice_unsupported!` is
        # called by `native_copy_loop` when copy_splice surfaces
        # :unsupported, transitioning the cached flag to false for the
        # rest of the process.
        def splice_runtime_supported?
          # Memoize the boot-time C ext flag.  We deliberately don't
          # run a live pipe2+splice probe here — the production path
          # is the runtime probe: copy_splice's :unsupported return is
          # cheap (one pipe2 + one close pair on the first request)
          # and authoritative.
          return @splice_runtime_supported if defined?(@splice_runtime_supported)

          @splice_runtime_supported =
            respond_to?(:splice_supported?) && splice_supported?
        end

        # Called by native_copy_loop when copy_splice reports
        # :unsupported at runtime (very old kernel without splice(2),
        # sandboxed environment that blocks pipe2, etc.).  Flips the
        # cached flag to false so we stop attempting splice on this
        # process for the rest of its lifetime — falling all the way
        # through to plain sendfile(2).
        def mark_splice_unsupported!
          @splice_runtime_supported = false
        end

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

          kind = fast_path_kind(out_io)

          # Phase 8a: small-file synchronous fast path.  Only fires on the
          # native branch (we need a real socket fd to issue write(2)
          # against) AND when the source side is also a real fd (pread(2)
          # against an Integer fd).  The C ext is only loaded on native
          # builds.  This MUST come BEFORE the :native streaming branch —
          # it's the whole point of Phase 8a: skip the fiber-yield
          # round-trip for the 8 KB row.
          if kind == :native && len <= SMALL_FILE_THRESHOLD &&
             respond_to?(:copy_small) && real_fd?(file_io)
            return copy_small(out_io, file_io, offset, len)
          end

          case kind
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

        # Native streaming loop for files > SMALL_FILE_THRESHOLD.
        #
        # 2.2.0 — on Linux, files above SPLICE_THRESHOLD are routed
        # through `copy_splice` first.  That primitive opens a fresh
        # pipe2(O_CLOEXEC | O_NONBLOCK) pair on every call, splices
        # file -> pipe -> socket fully kernel-side, and closes both
        # fds before returning.  The two extra syscalls per call buy
        # us correctness against the bytes-leak window the cached
        # per-thread pipe layout suffered in 2.0.1, and the splice
        # copies stay zero-copy through the page cache so the net
        # win on 1 MiB+ assets is 5-10% over plain sendfile.
        #
        # On non-Linux hosts (`splice_supported?` == false) we go
        # straight to the plain sendfile(2) path via `copy`.  On
        # Linux hosts where the runtime kernel rejects splice (very
        # old kernels return ENOSYS / EINVAL) we mark the path
        # unsupported for the rest of the process and fall through
        # to plain sendfile.
        def native_copy_loop(out_io, file_io, offset, len)
          remaining = len
          cursor    = offset
          total     = 0
          use_splice = splice_runtime_supported? && len > SPLICE_THRESHOLD &&
                       respond_to?(:copy_splice)

          while remaining.positive?
            bytes, status =
              if use_splice
                begin
                  copy_splice(out_io, file_io, cursor, remaining)
                rescue NotImplementedError
                  mark_splice_unsupported!
                  use_splice = false
                  next
                end
              else
                copy(out_io, file_io, cursor, remaining)
              end

            case status
            when :done
              total += bytes
              return total
            when :partial
              total     += bytes
              cursor    += bytes
              remaining -= bytes
            when :eagain
              # Both `copy` and `copy_splice` return :eagain only
              # when zero bytes left for the wire (the C ext maps
              # bytes>0 + EAGAIN to :partial), so cursor / remaining
              # don't move here — we just yield to the scheduler.
              wait_writable(out_io)
            when :unsupported
              if use_splice
                # Runtime kernel rejected splice but plain sendfile
                # may still work.  Cache the negative answer and
                # retry from the same cursor through plain sendfile.
                mark_splice_unsupported!
                use_splice = false
              else
                # Kernel said this fd pair doesn't support sendfile.
                # Drop to userspace.  The file's read offset is still
                # untouched (we've been passing absolute offsets
                # through to the kernel), so rewind via offset arg
                # into the userspace path.
                file_io.seek(cursor) if file_io.respond_to?(:seek)
                return total + userspace_copy_loop(out_io, file_io, cursor, remaining)
              end
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
