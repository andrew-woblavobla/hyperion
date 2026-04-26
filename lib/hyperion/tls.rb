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

    module_function

    def context(cert:, key:)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = cert
      ctx.key = key
      ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ctx.alpn_protocols = SUPPORTED_PROTOCOLS
      ctx.alpn_select_cb = lambda do |client_protocols|
        # Prefer h2 if the client offered it; else fall back to http/1.1.
        SUPPORTED_PROTOCOLS.find { |p| client_protocols.include?(p) }
      end
      ctx
    end
  end
end
