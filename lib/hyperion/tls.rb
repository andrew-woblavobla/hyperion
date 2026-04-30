# frozen_string_literal: true

require 'openssl'
require 'etc'

module Hyperion
  # TLS context builder with ALPN configured for HTTP/2 + HTTP/1.1.
  #
  # Phase 7: TLS is opt-in via Server's `tls:` kwarg. ALPN lets the client
  # negotiate `h2` (HTTP/2) or `http/1.1` during the handshake; the server
  # then dispatches to either Http2Handler or Connection accordingly.
  #
  # 1.8.0 (Phase 4): server-side session resumption is on by default. The
  # context enables `SESSION_CACHE_SERVER` mode and clears `OP_NO_TICKET`
  # so OpenSSL's auto-rolled session-ticket key handles short-circuited
  # handshakes for returning clients. `session_id_context` is set to a
  # stable per-process value so cache lookups cross worker boundaries when
  # the master inherits a single listener fd (`:share` mode); on Linux
  # `:reuseport` workers, the kernel pins client → worker by tuple hash so
  # each worker's local cache covers its own returning clients.
  #
  # Cross-worker ticket-key sharing requires `SSL_CTX_set_tlsext_ticket_keys`
  # which Ruby's stdlib OpenSSL does not bind today (3.3.x). When that
  # binding lands we'll thread the master-generated key through to each
  # worker; until then resumption works inside a single worker's session
  # cache. RFC §4 documents this trade-off.
  #
  # 2.2.0 (Phase 9): kernel TLS transmit (KTLS_TX) on Linux ≥ 4.13 +
  # OpenSSL ≥ 3.0. After the userspace handshake completes, the symmetric
  # session key is handed to the kernel and subsequent SSL_write calls go
  # through kernel sendfile/write paths, bypassing the userspace cipher
  # loop. Pairs with — does not replace — Phase 4 session resumption.
  # macOS / BSD have no kTLS support; the probe returns false and the
  # context falls back to plain userspace SSL_write transparently.
  module TLS
    SUPPORTED_PROTOCOLS = %w[h2 http/1.1].freeze

    PEM_CERT_RE = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m

    # OpenSSL 3.0+ added SSL_OP_ENABLE_KTLS (= 0x00000008 in openssl/ssl.h).
    # Most Ruby openssl bindings expose it as `OpenSSL::SSL::OP_ENABLE_KTLS`;
    # fall back to the literal constant value on builds that don't.
    OP_ENABLE_KTLS_VALUE = if OpenSSL::SSL.const_defined?(:OP_ENABLE_KTLS)
                             OpenSSL::SSL::OP_ENABLE_KTLS
                           else
                             0x00000008
                           end

    # OpenSSL 3.0 cuts the line for kTLS support — earlier 1.1.x builds
    # accept the option flag but silently no-op. Compare against the
    # numeric `OPENSSL_VERSION_NUMBER` (Mmnnffpps form) so the check works
    # with stdlib bindings that don't expose every symbolic constant.
    MIN_OPENSSL_VERSION_FOR_KTLS = 0x30000000 # 3.0.0

    # Linux added kTLS_TX in 4.13 (commit d3b18ad31f91e). Earlier kernels
    # don't expose the AF_ALG TLS ULP. Probe via Etc.uname[:release].
    MIN_LINUX_KERNEL_FOR_KTLS = [4, 13].freeze

    require 'securerandom'

    # Stable per-process session_id_context. Sized at the OpenSSL hard
    # cap (32 bytes); randomized once at process boot so two unrelated
    # Hyperion processes on the same host don't share session caches by
    # accident, but consistent across forks via copy-on-write so workers
    # all advertise the same context id.
    SESSION_ID_CONTEXT = SecureRandom.bytes(32).freeze

    DEFAULT_SESSION_CACHE_SIZE = 20_480

    module_function

    # Builds the OpenSSL::SSL::SSLContext used to wrap TLS listening
    # sockets. `session_cache_size` (default 20_480) is the in-process
    # server-side cache budget. Setting `0` disables the cache entirely
    # (every connection pays the full handshake cost — useful for tests
    # of the cache-eviction path).
    #
    # 2.2.0 (Phase 9): `ktls` selects the kernel-TLS transmit policy.
    #   * `:auto` (default) — enable on Linux when the kernel + OpenSSL
    #                          combo supports it; off elsewhere.
    #   * `:on`             — force-enable; raise at boot if not supported.
    #   * `:off`            — never enable, even if supported.
    def context(cert:, key:, chain: nil, session_cache_size: DEFAULT_SESSION_CACHE_SIZE,
                ktls: :auto)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = cert
      ctx.key = key
      # NB: do NOT switch to `chain.present?` — that's ActiveSupport, which
      # this gem does not depend on (would NameError at runtime). The
      # explicit guard below is the plain-Ruby equivalent.
      ctx.extra_chain_cert = chain unless chain.nil? || chain.empty?
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ctx.alpn_protocols = SUPPORTED_PROTOCOLS
      ctx.alpn_select_cb = lambda do |client_protocols|
        # Prefer h2 if the client offered it; else fall back to http/1.1.
        SUPPORTED_PROTOCOLS.find { |p| client_protocols.include?(p) }
      end

      configure_session_resumption!(ctx, session_cache_size)
      configure_ktls!(ctx, ktls)
      ctx
    end

    # Whether this Ruby + kernel combination can host kTLS_TX. Cached
    # per-process: the answer can't change without a process restart.
    # Three gates: Linux kernel ≥ 4.13, OpenSSL ≥ 3.0, and the openssl
    # gem actually exposing the flag (sanity-check, since we fall back
    # to the literal value when the constant is missing).
    def ktls_supported?
      return @ktls_supported if defined?(@ktls_supported)

      @ktls_supported = linux_ktls_kernel? && openssl_ktls_capable?
    end

    # Test seam: clear the cached probe result so a stubbed Etc.uname /
    # OpenSSL version can drive the spec matrix. Production code never
    # calls this — `ktls_supported?` is idempotent across the process
    # lifetime once memoized.
    def reset_ktls_probe!
      remove_instance_variable(:@ktls_supported) if defined?(@ktls_supported)
    end

    # Apply the operator-supplied kTLS policy onto an already-built
    # SSLContext. Split out so it can be re-applied after a SIGUSR2
    # rotation (parallels `configure_session_resumption!`).
    #
    # OpenSSL drives the actual promotion: when OP_ENABLE_KTLS is set on
    # the context and the negotiated cipher is one the kernel supports
    # (currently AES-128-GCM, AES-256-GCM, and CHACHA20-POLY1305 on newer
    # kernels), `SSL_write` on the post-handshake socket goes through
    # the kernel TLS path. We just opt in here.
    def configure_ktls!(ctx, mode)
      case mode
      when :off, false
        return ctx
      when :on, true
        unless ktls_supported?
          raise Hyperion::UnsupportedError,
                'kTLS not supported on this platform (need Linux >= 4.13 + OpenSSL >= 3.0); ' \
                'set tls.ktls = :off or :auto to fall back to userspace SSL_write'
        end
      when :auto, nil
        return ctx unless ktls_supported?
      else
        raise ArgumentError, "tls.ktls must be :auto, :on, or :off (got #{mode.inspect})"
      end

      ctx.options |= OP_ENABLE_KTLS_VALUE
      ctx
    rescue NoMethodError
      # Some openssl bindings expose `#options` as read-only. Treat as a
      # silent no-op rather than crashing the boot — kTLS is an
      # optimization, the request path keeps working without it.
      ctx
    end

    # Whether kernel TLS_TX is currently active on the supplied
    # SSLSocket. Used in tests + the once-per-worker boot log to confirm
    # the kernel actually accepted the cipher. Returns `nil` when the
    # answer can't be determined (no FFI access to libssl, or this build
    # of OpenSSL doesn't expose `SSL_get_KTLS_send`) — callers must
    # distinguish nil ("don't know") from false ("definitely not active").
    #
    # Implementation note: Ruby's stdlib openssl does not expose the
    # underlying `SSL*` pointer, so a direct `SSL_get_KTLS_send` call is
    # not reliably reachable from Ruby. We approximate with a kernel-
    # module probe: on Linux, the `tls` module is loaded into the kernel
    # the first time any process opens a socket with `setsockopt(...,
    # TCP_ULP, "tls")`. After OpenSSL promotes the connection to KTLS,
    # `/proc/modules` contains `tls` with a positive refcount. This is a
    # process-global signal — adequate for the boot-log assertion (one-
    # shot at first connection) and for the spec's "did kTLS engage on
    # this host" check, but not a per-socket guarantee.
    def ktls_active?(_ssl_socket = nil)
      return nil unless ktls_supported?

      File.foreach('/proc/modules') do |line|
        next unless line.start_with?('tls ')

        # Format: `tls 155648 3 - Live ...` — third column is refcount.
        refcount = line.split(' ', 4)[2].to_i
        return refcount.positive?
      end
      false
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    private_class_method def linux_ktls_kernel?
      sysname = Etc.uname[:sysname]
      return false unless sysname == 'Linux'

      release = Etc.uname[:release].to_s
      major, minor = release.split('.', 3).first(2).map(&:to_i)
      return false unless major

      min_major, min_minor = MIN_LINUX_KERNEL_FOR_KTLS
      major > min_major || (major == min_major && minor >= min_minor)
    end

    private_class_method def openssl_ktls_capable?
      OpenSSL::OPENSSL_VERSION_NUMBER >= MIN_OPENSSL_VERSION_FOR_KTLS
    end

    # Wire up the in-process server-side session cache + tickets. Split
    # out of `context` so it can be re-applied after a SIGUSR2 rotation
    # call to `flush_sessions` without rebuilding the whole context.
    #
    # `session_cache_size` follows the OpenSSL convention: zero or
    # negative disables the cache; positive sets the LRU cap. We do NOT
    # set `OP_NO_TICKET` — its absence is what enables RFC 5077 session
    # tickets (resumption with no server-side state).
    def configure_session_resumption!(ctx, session_cache_size)
      ctx.session_id_context = SESSION_ID_CONTEXT[0, 32]
      if session_cache_size.to_i.positive?
        ctx.session_cache_mode = OpenSSL::SSL::SSLContext::SESSION_CACHE_SERVER
        ctx.session_cache_size = session_cache_size.to_i
      else
        ctx.session_cache_mode = OpenSSL::SSL::SSLContext::SESSION_CACHE_OFF
      end
      # Explicitly clear OP_NO_TICKET if a default-params layer set it.
      # OpenSSL's default is tickets ON, but a host app that mutates
      # SSLContext::DEFAULT_PARAMS could add it; defend by clearing.
      ctx.options &= ~OpenSSL::SSL::OP_NO_TICKET if ctx.options
      ctx
    end

    # SIGUSR2 hook: flush the in-process session cache so subsequent
    # connections cannot resume against entries the master has decided
    # are stale. OpenSSL auto-generates a fresh session-ticket key when
    # the previous one's lifetime elapses; calling `flush_sessions` here
    # narrows the resumption window so an exfiltrated cache entry is
    # invalidated within one rotation cycle.
    def rotate!(ctx)
      ctx.flush_sessions
      ctx
    end

    # Split a PEM blob into one OpenSSL::X509::Certificate per BEGIN/END
    # block. Production cert files commonly bundle leaf + intermediate(s) in
    # a single file, but `OpenSSL::X509::Certificate.new(pem)` only parses
    # the FIRST block — so if we don't split here the intermediates are
    # silently dropped and clients see an incomplete chain.
    def parse_pem_chain(pem)
      pem.scan(PEM_CERT_RE).map { |block| OpenSSL::X509::Certificate.new(block) }
    end

    # 2.3-B: TLS handshake CPU throttle. Per-worker token bucket sized
    # at the operator's `tls.handshake_rate_limit` (handshakes/sec).
    # Capacity == rate so a steady-state handshake stream of `rate`
    # handshakes/sec passes cleanly while a burst above the rate is
    # rate-limited; tokens refill at `rate` per second uniformly.
    #
    # **When this fires.** A flood of new TLS handshakes (e.g., during
    # a deployment when nginx restarts and reconnects everything) can
    # starve regular requests of CPU — RSA/ECDHE handshakes are the
    # most expensive op the server does. The bucket caps that
    # starvation by closing the TCP connection at the listener edge
    # before SSL_accept runs; clients see a clean TCP RST/FIN and
    # retry. Default `:unlimited` keeps 2.2.0 behaviour.
    #
    # **For nginx-fronted topologies** this is mostly defensive: nginx
    # keeps long-lived upstream connections, so handshake rate is
    # normally near-zero. Real value is for direct-exposure operators
    # or staging environments where misconfiguration causes a
    # handshake storm.
    #
    # **Concurrency.** A Mutex-guarded refill+take. Hold time is one
    # `Process.clock_gettime` + a couple of arithmetic ops — tens of
    # nanoseconds. Contention is bounded by handshake rate (orders
    # of magnitude lower than request rate), so the mutex is never on
    # the hot per-request path.
    class HandshakeRateLimiter
      attr_reader :rate, :capacity

      # Build a limiter for `rate` handshakes/sec/worker, or `:unlimited`
      # to short-circuit every `acquire_token!` to true (no throttle).
      # Anything else raises ArgumentError so config typos surface at
      # boot.
      def initialize(rate)
        if rate == :unlimited || rate.nil?
          @rate     = :unlimited
          @capacity = nil
          @tokens   = nil
          @last_refill_at = nil
          @mutex    = nil
        elsif rate.is_a?(Integer) && rate.positive?
          @rate     = rate
          @capacity = rate.to_f
          @tokens   = @capacity
          @last_refill_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @mutex = Mutex.new
        else
          raise ArgumentError,
                "tls.handshake_rate_limit must be a positive integer or :unlimited (got #{rate.inspect})"
        end
        @rejected = 0
      end

      # True when the bucket had a token to spend (handshake proceeds).
      # False when the bucket is empty (caller should close the TCP
      # connection without running SSL_accept — saves the CPU cost of
      # the asymmetric crypto under handshake-storm conditions).
      def acquire_token!
        return true if @rate == :unlimited

        @mutex.synchronize do
          refill_locked!
          if @tokens >= 1.0
            @tokens -= 1.0
            true
          else
            @rejected += 1
            false
          end
        end
      end

      # Snapshot for stats / logging. `tokens` is the current bucket
      # level (float), `rejected` is the cumulative count of denied
      # handshake attempts since limiter construction.
      def stats
        return { rate: :unlimited, rejected: 0 } if @rate == :unlimited

        @mutex.synchronize do
          refill_locked!
          { rate: @rate, capacity: @capacity, tokens: @tokens, rejected: @rejected }
        end
      end

      private

      # Refill must be called with @mutex held.
      def refill_locked!
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = now - @last_refill_at
        return if elapsed <= 0

        @tokens = [@tokens + (elapsed * @rate), @capacity].min
        @last_refill_at = now
      end
    end
  end
end
