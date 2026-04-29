# frozen_string_literal: true

require 'openssl'

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
  module TLS
    SUPPORTED_PROTOCOLS = %w[h2 http/1.1].freeze

    PEM_CERT_RE = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m

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
    def context(cert:, key:, chain: nil, session_cache_size: DEFAULT_SESSION_CACHE_SIZE)
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
      ctx
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
  end
end
