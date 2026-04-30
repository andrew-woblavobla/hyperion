# frozen_string_literal: true

require 'fcntl'

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
    #
    # 2.2.x fix-A — pipe-hoist out of the chunk loop
    # ----------------------------------------------
    # The 2026-04-30 bench sweep showed 2.2.0's per-call pipe2 cost a
    # -23% rps regression on the static 1 MiB row (1,697 → 1,312 r/s)
    # because `native_copy_loop` invokes the splice primitive ONCE PER
    # CHUNK in a `while remaining.positive?` loop.  For a 1 MiB asset
    # at 64 KiB chunks that's 16 calls × 3 syscalls of pipe overhead =
    # 48 wasted syscalls per request.  Fix-A pushes the pipe lifecycle
    # up one level: `native_copy_loop` now opens a single
    # pipe2(O_CLOEXEC | O_NONBLOCK) pair per RESPONSE, hands it to the
    # new `copy_splice_into_pipe` primitive for every chunk, and
    # closes both fds in an ensure block when the response loop
    # unwinds (success, EAGAIN-retry-loop exit, raised exception).
    # Same correctness window as 2.2.0 — a pipe pair never outlives
    # one response, so EPIPE mid-transfer cannot leak residual bytes
    # onto the next request's socket — at 1/16th the syscall cost.
    module Sendfile
      # Maximum bytes per IO.copy_stream call on the userspace fallback, and
      # per-call cap on the native sendfile / splice loops. 2.6-A bumped this
      # from 64 KiB to 256 KiB.
      #
      # 64 KiB was the original "kernel TCP send buffer's typical sweet spot"
      # value — small enough to bound a single syscall's GVL hold-time, large
      # enough to amortize the syscall cost. 2.6-A measurements on
      # openclaw-vm (Linux 6.x, 1 MiB warm-cache static asset) showed the
      # kernel happily accepts 256 KiB per sendfile(2) / splice(2) call —
      # the kernel TCP send buffer auto-tunes upward under sustained load,
      # and modern NICs+TSO segment 256 KiB-1 MiB chunks at line rate. At
      # 256 KiB we issue 4× fewer syscalls per 1 MiB response (4 calls vs
      # 16) while keeping the GVL hold-time well under 1 ms even on a slow
      # client.
      #
      # Reference: nginx (`sendfile_max_chunk` default 0 = unlimited, but
      # most distros ship with `2m` overrides), Apache (`SendBufferSize`
      # 128k–256k), Caddy (256 KiB hard-coded). Hyperion sits in the
      # middle of that field.
      USERSPACE_CHUNK = 256 * 1024

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
          # is the runtime probe: copy_splice_into_pipe's :unsupported
          # return is cheap (one pipe2 + one close pair on the first
          # request) and authoritative.
          return @splice_runtime_supported if defined?(@splice_runtime_supported)

          # 2.2.x fix-A — pipe2 has been hoisted out of the chunk
          # loop (one pipe pair per response, reused across every
          # chunk via `copy_splice_into_pipe`).  The syscall-count
          # math (64 → 19 syscalls per 1 MiB request) makes the
          # 2.2.0 env-var gate obsolete in principle, but we leave
          # the gate in place until the openclaw-vm bench
          # re-confirms splice ≥ plain sendfile baseline on Linux.
          # The fix-A landing session couldn't reach openclaw-vm
          # (SSH auth gap, see CHANGELOG); the maintainer is
          # expected to drop the gate in a follow-up commit once
          # the bench is re-run from a session with working SSH.
          # Operators wanting to A/B test on other kernels can
          # flip HYPERION_HTTP_SPLICE=1.
          enabled =
            ENV['HYPERION_HTTP_SPLICE'] == '1' &&
            respond_to?(:splice_supported?) &&
            splice_supported?

          @splice_runtime_supported = enabled
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
        # 2.2.x fix-A — on Linux, files above SPLICE_THRESHOLD route
        # through `copy_splice_into_pipe`.  That primitive splices
        # file -> pipe -> socket for ONE chunk against a pipe pair
        # owned by THIS METHOD: one `IO.pipe` (binmode, non-blocking)
        # at the top, both fds closed in the ensure block at the
        # bottom.  For a 1 MiB asset at 64 KiB chunks that drops the
        # pipe overhead from 16 × pipe2 + 32 × close (one set per
        # chunk in the 2.2.0 layout) to 1 × pipe2 + 2 × close per
        # response — a 3.4× syscall-count reduction.  The
        # correctness window (no cross-request byte leak) stays
        # closed: a pipe pair still never outlives a single
        # response.
        #
        # On non-Linux hosts (`splice_supported?` == false) we go
        # straight to the plain sendfile(2) path via `copy`.  On
        # Linux hosts where the runtime kernel rejects splice (very
        # old kernels return ENOSYS / EINVAL) we mark the path
        # unsupported for the rest of the process and fall through
        # to plain sendfile.
        def native_copy_loop(out_io, file_io, offset, len)
          use_splice = splice_runtime_supported? && len > SPLICE_THRESHOLD &&
                       respond_to?(:copy_splice_into_pipe)

          if use_splice
            splice_copy_loop(out_io, file_io, offset, len)
          else
            plain_sendfile_loop(out_io, file_io, offset, len)
          end
        end

        # 2.2.x fix-A — splice path with one pipe pair per response.
        # Opens the pipe at entry, hands the same fds to
        # `copy_splice_into_pipe` for every chunk of the response,
        # and closes both fds in the ensure block on every exit
        # path (return, raise, throw).  If the runtime kernel
        # rejects splice (:unsupported on the first chunk), we tear
        # the pipe down immediately and recurse through
        # `plain_sendfile_loop` for the remainder of the response.
        def splice_copy_loop(out_io, file_io, offset, len)
          remaining = len
          cursor    = offset
          total     = 0
          pipe_r, pipe_w = open_splice_pipe!

          begin
            while remaining.positive?
              # 2.6-A — cap each splice round at USERSPACE_CHUNK
              # (256 KiB) so the kernel doesn't get an arbitrarily
              # large `count` arg on huge responses.  At 256 KiB a
              # 1 MiB asset moves in 4 splice rounds vs 16 at the
              # legacy 64 KiB kernel-TCP-send-buffer ceiling.
              chunk = remaining < USERSPACE_CHUNK ? remaining : USERSPACE_CHUNK
              bytes, status =
                begin
                  copy_splice_into_pipe(out_io, file_io, cursor, chunk, pipe_r, pipe_w)
                rescue NotImplementedError
                  mark_splice_unsupported!
                  return total + plain_sendfile_loop(out_io, file_io, cursor, remaining)
                end

              case status
              when :done
                # 2.6-A — `:done` from the C ext means the kernel
                # accepted the FULL `chunk` we asked for, not the
                # full response.  Advance cursor / remaining and
                # loop; the while-condition exits when the response
                # is fully drained.
                total     += bytes
                cursor    += bytes
                remaining -= bytes
              when :partial
                total     += bytes
                cursor    += bytes
                remaining -= bytes
              when :eagain
                # `copy_splice_into_pipe` only returns :eagain when
                # zero bytes hit the wire (bytes>0 + EAGAIN maps to
                # :partial in the C ext), so cursor / remaining
                # don't move here — we just yield to the scheduler.
                wait_writable(out_io)
              when :unsupported
                # Runtime kernel rejected splice but plain sendfile
                # may still work.  Cache the negative answer and
                # finish this response through plain sendfile from
                # the same cursor.
                mark_splice_unsupported!
                return total + plain_sendfile_loop(out_io, file_io, cursor, remaining)
              else
                raise "Hyperion::Http::Sendfile: unexpected status #{status.inspect}"
              end
            end

            total
          ensure
            # Close both fds on every exit path — success, EAGAIN
            # retry-loop exit, raised exception, mid-transfer
            # EPIPE.  This is the whole point of fix-A's per-
            # response pipe lifecycle: the pipe never outlives the
            # response, so residual bytes from a partial transfer
            # cannot leak onto the next request's socket.
            close_splice_pipe(pipe_r, pipe_w)
          end
        end

        # Plain sendfile(2) loop — used on non-Linux hosts, on
        # hosts where splice is unavailable at runtime, and as the
        # tail of a splice run that hit :unsupported mid-response.
        #
        # 2.6-A — each kernel call is capped at USERSPACE_CHUNK
        # (256 KiB) so a 1 MiB response moves in 4 sendfile rounds
        # vs 16 at the legacy 64 KiB ceiling.  The kernel happily
        # accepts the larger count arg on Linux 4.x+ and Darwin /
        # *BSD; partial returns still fall through the :partial
        # branch unchanged.
        def plain_sendfile_loop(out_io, file_io, offset, len)
          remaining = len
          cursor    = offset
          total     = 0

          while remaining.positive?
            chunk = remaining < USERSPACE_CHUNK ? remaining : USERSPACE_CHUNK
            bytes, status = copy(out_io, file_io, cursor, chunk)

            case status
            when :done
              # 2.6-A — `:done` means the kernel wrote the FULL
              # `chunk` we asked for, not the full response.
              # Advance and loop; the while-condition exits when
              # remaining hits zero.
              total     += bytes
              cursor    += bytes
              remaining -= bytes
            when :partial
              total     += bytes
              cursor    += bytes
              remaining -= bytes
            when :eagain
              wait_writable(out_io)
            when :unsupported
              # Kernel said this fd pair doesn't support sendfile.
              # Drop to userspace.  The file's read offset is still
              # untouched (we've been passing absolute offsets
              # through to the kernel), so rewind via offset arg
              # into the userspace path.
              file_io.seek(cursor) if file_io.respond_to?(:seek)
              return total + userspace_copy_loop(out_io, file_io, cursor, remaining)
            else
              raise "Hyperion::Http::Sendfile: unexpected status #{status.inspect}"
            end
          end

          total
        end

        # Open a pipe pair sized for the splice response loop.
        # Returns [pipe_r, pipe_w] as Ruby IO objects so the ensure
        # block can `.close` them via the standard IO protocol — no
        # stale-fd risk if the C ext closed the underlying fd
        # during a runtime-:unsupported teardown.  Both ends are
        # set non-blocking (matches the C ext's pipe2 fallback for
        # `copy_splice`) so a wedged splice can't block a worker
        # thread.
        def open_splice_pipe!
          pipe_r, pipe_w = IO.pipe
          set_nonblock!(pipe_r)
          set_nonblock!(pipe_w)
          [pipe_r, pipe_w]
        end

        def set_nonblock!(io)
          flags = io.fcntl(Fcntl::F_GETFL)
          io.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)
        rescue StandardError
          # F_SETFL is best-effort; the splice ladder copes with
          # blocking pipe ends just fine, the non-blocking flag is
          # a defense-in-depth knob.  Older Ruby builds without
          # Fcntl loaded fall through silently.
        end

        def close_splice_pipe(pipe_r, pipe_w)
          pipe_r.close unless pipe_r.nil? || pipe_r.closed?
          pipe_w.close unless pipe_w.nil? || pipe_w.closed?
        rescue StandardError
          # We're typically in an ensure block; never let close
          # bubble up over the original exception (or success
          # return).
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
