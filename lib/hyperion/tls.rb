# frozen_string_literal: true

require 'openssl'

module Hyperion
  # TLS context builder with ALPN configured for HTTP/2 + HTTP/1.1.
  #
  # Phase 7: TLS is opt-in via Server's `tls:` kwarg. ALPN lets the client
  # negotiate `h2` (HTTP/2) or `http/1.1` during the handshake; the server
  # then dispatches to either Http2Handler or Connection accordingly.
  module TLS
    SUPPORTED_PROTOCOLS = %w[h2 http/1.1].freeze

    PEM_CERT_RE = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m

    module_function

    def context(cert:, key:, chain: nil)
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
