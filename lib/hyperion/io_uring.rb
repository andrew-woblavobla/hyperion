# frozen_string_literal: true

require 'etc'
require 'fiddle'
require 'fiddle/import'

module Hyperion
  # 2.3-A — io_uring accept on Linux 5.6+ (opt-in).
  #
  # The biggest unmovable bottleneck below the GVL on the plaintext h1
  # path is the kernel accept loop: every accept costs accept_nonblock +
  # IO.select on the EAGAIN edge (two syscalls per accepted connection
  # under burst). io_uring lets us submit accept SQEs and reap CQEs in
  # one syscall, with the kernel batching multiple accepts in a single
  # CQE drain when connections arrive faster than the fiber can consume
  # them.
  #
  # ## Surface
  #
  #   Hyperion::IOUring.supported?   # bool — Linux ≥ 5.6 + cdylib loaded
  #                                  #        + runtime probe succeeds
  #   Hyperion::IOUring::Ring.new(queue_depth: 256)
  #                                  # per-fiber ring; #accept(fd) → fd
  #                                  # or :wouldblock; #close releases
  #                                  # the ring's SQ/CQ memory.
  #
  # ## Per-fiber, NEVER per-process or per-thread
  #
  # io_uring under fork+threads has known sharp edges:
  #
  #   * Submission queue is process-shared by default — under fork, the
  #     parent's outstanding SQEs leak into the child's CQ.
  #   * IORING_SETUP_SQPOLL kernel thread does not survive fork.
  #   * Threads sharing a ring need IORING_SETUP_SINGLE_ISSUER + careful
  #     submission discipline.
  #
  # Hyperion's safe pattern, matching the fiber-per-conn architecture:
  #
  #   * One ring per fiber that needs it (the accept fiber, optionally
  #     per-connection read fibers in a future phase).
  #   * Ring is opened lazily on first use:
  #       Fiber.current[:hyperion_io_uring] ||=
  #         Hyperion::IOUring::Ring.new(queue_depth: 256)
  #   * Ring is closed when the fiber exits.
  #   * Workers don't share rings across fork — each child opens its own.
  #
  # ## Default off in 2.3.0
  #
  # Mirrors the 2.2.0 fix-B HYPERION_H2_NATIVE_HPACK pattern: ship the
  # plumbing in 2.3.0 with the default OFF, give operators an env-var to
  # A/B (HYPERION_IO_URING={on,auto}), flip the default to :auto in
  # 2.4 only after 6 months of soak. io_uring code in production has
  # too many sharp edges to default-on without field validation.
  module IOUring
    EXPECTED_ABI = 1
    # Linux 5.6 stabilized IORING_OP_ACCEPT (commit 17f2fe35d080,
    # mainlined Mar 2020). 5.5 had a buggy precursor that the io-uring
    # crate refuses to use. We gate on 5.6 to match the crate's stance.
    MIN_LINUX_KERNEL = [5, 6].freeze

    class Unsupported < StandardError; end

    # Per-Ring instance. Wraps the opaque pointer returned by
    # `hyperion_io_uring_ring_new` and exposes the accept / read
    # primitives over Fiddle.
    class Ring
      DEFAULT_QUEUE_DEPTH = 256

      def initialize(queue_depth: DEFAULT_QUEUE_DEPTH)
        raise Unsupported, 'io_uring not supported on this platform' unless IOUring.supported?

        @ptr = IOUring.ring_new(queue_depth.to_i)
        raise Unsupported, 'io_uring_setup failed at ring allocation' if @ptr.nil? || @ptr.null?

        # `errno` scratch — reused across calls. Fiddle::Pointer to a
        # 4-byte buffer that the C side writes into on error. Saves
        # one Pointer allocation per accept.
        @errno_buf = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
        @closed = false
      end

      # Accept one connection on `listener_fd`. Returns the integer
      # client fd, or `:wouldblock` on EAGAIN. Raises on hard errors.
      #
      # The ring's submit_and_wait drives io_uring_enter with
      # min_complete=1, so this fiber parks here until the kernel
      # delivers the matching CQE. Under Async, the Ruby side calls
      # this from a Fiber — the fiber is logically blocked but the
      # OS thread keeps running other fibers via the scheduler ONLY
      # if `submit_and_wait` itself yields. It does not yield (it's
      # a syscall under FFI), so the accept fiber must be the only
      # fiber with work-pending on its OS thread. In Hyperion's
      # default 1-accept-fiber-per-worker shape that's always true.
      def accept(listener_fd)
        raise IOError, 'ring closed' if @closed

        rc = IOUring.ring_accept(@ptr, listener_fd.to_i, @errno_buf)
        return rc if rc.positive? || rc.zero?
        return :wouldblock if rc == -1

        errno = @errno_buf.to_str(4).unpack1('l<')
        # ECANCELED / EBADF / EINTR → caller treats as wouldblock and
        # loops. Anything else is a hard error.
        return :wouldblock if [4, 9, 103, 125].include?(errno) # EINTR / EBADF / ECONNABORTED / ECANCELED

        raise SystemCallError.new('io_uring accept failed', errno)
      end

      # Read up to `max` bytes from `fd` into a fresh ASCII-8BIT
      # String. 2.3-A ships this for the accept-only path's sibling
      # use (per-connection short reads); the connection layer keeps
      # using regular `read_nonblock` until a future 2.3-x round wires
      # io_uring reads into the request-line + header parse.
      def read(fd, max: 4096)
        raise IOError, 'ring closed' if @closed

        buf = Fiddle::Pointer.malloc(max, Fiddle::RUBY_FREE)
        rc = IOUring.ring_read(@ptr, fd.to_i, buf, max.to_i, @errno_buf)
        return buf.to_str(rc) if rc >= 0
        return :wouldblock if rc == -1

        errno = @errno_buf.to_str(4).unpack1('l<')
        raise SystemCallError.new('io_uring read failed', errno)
      end

      # Close the ring + free its SQ/CQ memory. Idempotent — calling
      # twice is a no-op (we null-out @ptr after the first free). Must
      # be called from the same fiber that opened the ring.
      def close
        return if @closed

        @closed = true
        IOUring.ring_free(@ptr) if @ptr && !@ptr.null?
        @ptr = nil
      end

      def closed?
        @closed
      end
    end

    class << self
      # Cached three-state result: nil = not-yet-probed, true/false = result.
      #
      # The probe is intentionally process-local (not Fiber-local) — the
      # answer is the same for every fiber in this process, and probing
      # once at boot avoids per-request syscall overhead.
      def supported?
        return @supported unless @supported.nil?

        @supported = compute_supported
      end

      # Test seam: clear cached probe so `supported?` re-runs. Used by
      # specs that stub Etc.uname or RbConfig.
      def reset!
        @supported = nil
        @lib = nil
      end

      # ---- Internal: feature gate ----

      def compute_supported
        # Gate 1: Linux only. macOS/BSD don't have io_uring.
        return false unless linux?

        # Gate 2: Kernel ≥ 5.6.
        return false unless kernel_supports_io_uring?

        # Gate 3: cdylib loaded.
        load!
        return false unless @lib

        # Gate 4: runtime probe — try to set up a tiny ring. Catches
        # sandboxed containers (seccomp blocking io_uring_setup,
        # locked-down environments returning -EPERM, kernels with
        # io_uring disabled via /proc/sys/kernel/io_uring_disabled).
        rc = @probe_fn.call
        rc.zero?
      rescue StandardError
        false
      end

      def linux?
        Etc.uname[:sysname] == 'Linux'
      rescue StandardError
        false
      end

      def kernel_supports_io_uring?
        return false unless linux?

        release = parse_kernel_release
        return false unless release

        major, minor = release
        min_major, min_minor = MIN_LINUX_KERNEL
        major > min_major || (major == min_major && minor >= min_minor)
      end

      # `Etc.uname[:release]` is the canonical source. Falls back to
      # `/proc/sys/kernel/osrelease` when uname isn't available (e.g.
      # specs that stub Etc.uname[:sysname] but leave release alone).
      def parse_kernel_release
        release = Etc.uname[:release].to_s
        if release.empty? && File.exist?('/proc/sys/kernel/osrelease')
          release = File.read('/proc/sys/kernel/osrelease').strip
        end
        m = release.match(/\A(\d+)\.(\d+)/)
        return nil unless m

        [m[1].to_i, m[2].to_i]
      rescue StandardError
        nil
      end

      # ---- Internal: Fiddle loader ----

      def load!
        return @lib if defined?(@lib) && !@lib.nil?

        path = candidate_paths.find { |p| File.exist?(p) }
        unless path
          @lib = nil
          return nil
        end

        @lib = Fiddle.dlopen(path)
        @abi_fn = Fiddle::Function.new(@lib['hyperion_io_uring_abi_version'],
                                       [], Fiddle::TYPE_INT)
        abi = @abi_fn.call
        if abi != EXPECTED_ABI
          warn "[hyperion] IOUring ABI mismatch (got #{abi}, expected #{EXPECTED_ABI}); falling back"
          @lib = nil
          return nil
        end

        @probe_fn = Fiddle::Function.new(@lib['hyperion_io_uring_probe'],
                                         [], Fiddle::TYPE_INT)
        @ring_new_fn = Fiddle::Function.new(@lib['hyperion_io_uring_ring_new'],
                                            [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
        @ring_free_fn = Fiddle::Function.new(@lib['hyperion_io_uring_ring_free'],
                                             [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
        @accept_fn = Fiddle::Function.new(@lib['hyperion_io_uring_accept'],
                                          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP],
                                          Fiddle::TYPE_INT)
        @read_fn = Fiddle::Function.new(@lib['hyperion_io_uring_read'],
                                        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT,
                                         Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT,
                                         Fiddle::TYPE_VOIDP],
                                        Fiddle::TYPE_INT)
        @lib
      rescue Fiddle::DLError, StandardError => e
        warn "[hyperion] IOUring failed to load (#{e.class}: #{e.message}); falling back to epoll"
        @lib = nil
        nil
      end

      def candidate_paths
        gem_lib = File.expand_path('../hyperion_io_uring', __dir__)
        ext_target = File.expand_path('../../ext/hyperion_io_uring/target/release', __dir__)
        %w[libhyperion_io_uring.dylib libhyperion_io_uring.so].flat_map do |name|
          [File.join(gem_lib, name), File.join(ext_target, name)]
        end
      end

      # ---- FFI wrappers ----

      def ring_new(depth)
        ptr = @ring_new_fn.call(depth)
        ptr.null? ? nil : ptr
      end

      def ring_free(ptr)
        @ring_free_fn.call(ptr)
      end

      def ring_accept(ptr, fd, errno_buf)
        @accept_fn.call(ptr, fd, errno_buf)
      end

      def ring_read(ptr, fd, buf, max, errno_buf)
        @read_fn.call(ptr, fd, buf, max, errno_buf)
      end
    end

    # ---- Server-side helpers ----

    # Resolve the operator's `io_uring` policy + the runtime gate
    # into a boolean "use io_uring on this server". Called by Server
    # at boot.
    #
    # Policy values:
    #   :off  → never. Returns false. Used for the 2.3.0 default.
    #   :auto → use it when supported; quietly fall back otherwise.
    #   :on   → demand it. Raise UnsupportedError if not available
    #           so the operator's misconfig surfaces at boot, not as
    #           a slow-fallback mystery hours later.
    def self.resolve_policy!(policy)
      case policy
      when :off, nil, false
        false
      when :auto
        supported?
      when :on, true
        unless supported?
          raise Unsupported,
                'io_uring required (io_uring: :on) but not supported on this host ' \
                "(linux=#{linux?}, kernel_ok=#{kernel_supports_io_uring?}, lib_loaded=#{!@lib.nil?})"
        end
        true
      else
        raise ArgumentError, "io_uring must be :off, :auto, or :on (got #{policy.inspect})"
      end
    end
  end
end
