# frozen_string_literal: true

require 'base64'
require 'digest/sha1'

module Hyperion
  # WS-2 (2.1.0) — RFC 6455 §1.3 / §4.2 HTTP/1.1 → WebSocket handshake.
  #
  # This module is intentionally narrow: given a Rack env (Hyperion's adapter
  # has just built it from the parsed Hyperion::Request), validate that the
  # request is a well-formed WebSocket upgrade attempt and compute the
  # `Sec-WebSocket-Accept` header value the client expects to see in the
  # 101 response. Hyperion does NOT write the 101 itself — that's the
  # application's responsibility (faye-websocket / ActionCable convention,
  # Option B in the WS-2 plan). All Hyperion does is:
  #
  #   1. Detect upgrade requests (Connection: upgrade + Upgrade: websocket)
  #   2. Validate them per RFC 6455 §4.2.1
  #   3. Stash the result in env['hyperion.websocket.handshake'] so the app
  #      (or a middleware like rack-websocket) can echo the right
  #      Sec-WebSocket-Accept header without re-doing the SHA-1/base64 dance
  #   4. Short-circuit a 400 / 426 on validation failure BEFORE the app
  #      sees the env (the app shouldn't have to know about malformed
  #      WS handshake attempts — that's protocol-level)
  #
  # WS-1 supplies the hijack primitive (env['rack.hijack'].call → live
  # socket); WS-3 supplies frame ser/de (Hyperion::WebSocket::Parser /
  # ::Builder); WS-4 will compose all three into a Hyperion::WebSocket::Connection
  # wrapper. WS-2 owns ONLY the HTTP-side handshake.
  module WebSocket
    # GUID from RFC 6455 §1.3 — concatenated with the client's
    # Sec-WebSocket-Key, SHA-1'd, base64'd to compute the accept value.
    GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

    # RFC 6455 §4.2.1: only protocol version 13 is supported. The handshake
    # responds 426 Upgrade Required + `Sec-WebSocket-Version: 13` so the
    # client knows the right version to retry with.
    SUPPORTED_VERSION = '13'

    # Public end-user API: applications / middleware can `rescue` this to
    # know "this was a WS upgrade attempt that failed at validation, NOT
    # an unrelated 4xx". WS-2 itself doesn't raise this — it's supplied
    # for downstream consumers who want to build their own WS facade on
    # top of `Handshake.validate`.
    class HandshakeError < StandardError
      attr_reader :status, :extra_headers

      def initialize(status, message, extra_headers = {})
        super(message)
        @status = status
        @extra_headers = extra_headers
      end
    end

    module Handshake
      # Common-case header keys looked up in env. All UPPER_SNAKE; values
      # come from the Rack adapter's HTTP_KEY_CACHE (frozen) so straight
      # `env[KEY]` is cheaper than building the key per call.
      UPGRADE_KEY    = 'HTTP_UPGRADE'
      CONNECTION_KEY = 'HTTP_CONNECTION'
      WS_KEY_KEY     = 'HTTP_SEC_WEBSOCKET_KEY'
      WS_VERSION_KEY = 'HTTP_SEC_WEBSOCKET_VERSION'
      WS_PROTO_KEY   = 'HTTP_SEC_WEBSOCKET_PROTOCOL'
      ORIGIN_KEY     = 'HTTP_ORIGIN'
      HOST_KEY       = 'HTTP_HOST'
      METHOD_KEY     = 'REQUEST_METHOD'
      PROTO_KEY      = 'SERVER_PROTOCOL'

      # Validate WS-upgrade preconditions on a Rack env.
      #
      # Returns a 3-tuple. The first slot is a Symbol tag the caller
      # branches on:
      #
      #   [:ok, accept_header_value, selected_subprotocol_or_nil]
      #     — request is a valid RFC 6455 §4.2.1 handshake. Caller should
      #     stash the tuple in env and let the app handle the 101.
      #
      #   [:bad_request, body, extra_headers]
      #     — request is a WS upgrade attempt with a protocol error
      #     (missing/invalid Sec-WebSocket-Key, wrong method, etc.).
      #     Caller short-circuits a 400.
      #
      #   [:upgrade_required, body, extra_headers]
      #     — Sec-WebSocket-Version is missing or not 13.
      #     `extra_headers` always includes `'sec-websocket-version' => '13'`
      #     so the client sees the version Hyperion supports.
      #     Caller short-circuits a 426 (RFC 6455 §4.4).
      #
      #   [:not_websocket, nil, nil]
      #     — request is not a WS upgrade (no Upgrade header, or Upgrade:
      #     value other than `websocket`). Caller proceeds with the
      #     normal HTTP flow. We don't trip on h2c / other Upgrade
      #     variants — only `websocket` is intercepted.
      #
      # Optional kwargs:
      #
      #   subprotocol_selector — a Proc that receives the array of
      #   client-offered subprotocols (parsed from
      #   Sec-WebSocket-Protocol). Returns:
      #     * a String matching one of the offers → echoed back in the
      #       Sec-WebSocket-Protocol response header
      #     * nil → no Sec-WebSocket-Protocol header (server silently
      #       declines, RFC 6455 §4.2.2)
      #     * a String NOT matching any offer → treated as nil (server
      #       MUST NOT pick a protocol the client didn't offer)
      #
      #   origin_allow_list — an Array of allowed Origin header values.
      #   When nil (default), any Origin (including missing) is accepted
      #   — browsers enforce CORS-style restrictions on the WS upgrade
      #   independently. Pass [] to reject all browser-originated WS,
      #   pass ['https://example.com'] to allow only that origin.
      def self.validate(env, subprotocol_selector: nil, origin_allow_list: default_origin_allow_list)
        return [:not_websocket, nil, nil] unless websocket_upgrade?(env)

        # Once we've decided this IS a WS attempt, every subsequent
        # validation failure is a 4xx, NOT a passthrough. The order
        # below mirrors RFC 6455 §4.2.1's MUST list.

        return bad_request('WebSocket upgrade requires GET') unless env[METHOD_KEY] == 'GET'

        proto = env[PROTO_KEY].to_s
        unless proto.start_with?('HTTP/') &&
               http_version_at_least_1_1?(proto)
          return bad_request('WebSocket upgrade requires HTTP/1.1+')
        end

        host = env[HOST_KEY]
        return bad_request('Host header required') if host.nil? || host.empty?

        # Sec-WebSocket-Version check before Sec-WebSocket-Key so a
        # client speaking the old hixie-76 / draft-08 dialect gets the
        # 426 hint to upgrade rather than a generic 400 on the missing
        # key (the old dialect uses different key headers).
        version = env[WS_VERSION_KEY]
        unless version == SUPPORTED_VERSION
          return [
            :upgrade_required,
            "Unsupported Sec-WebSocket-Version (need #{SUPPORTED_VERSION})",
            { 'sec-websocket-version' => SUPPORTED_VERSION }
          ]
        end

        client_key = env[WS_KEY_KEY]
        return bad_request('Sec-WebSocket-Key required') if client_key.nil? || client_key.empty?

        return bad_request('Sec-WebSocket-Key must decode to 16 bytes') unless valid_client_key?(client_key)

        if origin_allow_list && !origin_allowed?(env[ORIGIN_KEY], origin_allow_list)
          return bad_request('Origin not in allow-list')
        end

        accept = accept_value(client_key)
        subprotocol = pick_subprotocol(env[WS_PROTO_KEY], subprotocol_selector)

        [:ok, accept, subprotocol]
      end

      # Compute the Sec-WebSocket-Accept value per RFC 6455 §4.2.2:
      # base64( SHA1( client_key + GUID ) ).
      #
      # Test vector: key="dGhlIHNhbXBsZSBub25jZQ==" → "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      def self.accept_value(client_key)
        Base64.strict_encode64(Digest::SHA1.digest("#{client_key}#{GUID}"))
      end

      # Build the wire bytes of the 101 Switching Protocols response.
      # Apps that don't want to hand-roll headers can call this and write
      # the result to `env['rack.hijack'].call` (the raw socket) before
      # sending any frames. Header keys are lowercased (RFC 7230 says
      # field names are case-insensitive; lowercasing matches what every
      # other Hyperion writer does).
      #
      #   accept_value    — String, the value of Sec-WebSocket-Accept
      #   subprotocol     — String or nil, echoed back in
      #                     Sec-WebSocket-Protocol when non-nil
      #   extra_headers   — Hash<String,String>, any additional 101
      #                     headers (e.g. Sec-WebSocket-Extensions for
      #                     permessage-deflate, when negotiated by the app)
      def self.build_101_response(accept_value, subprotocol = nil, extra_headers = {})
        lines = String.new(encoding: Encoding::ASCII_8BIT)
        lines << "HTTP/1.1 101 Switching Protocols\r\n"
        lines << "upgrade: websocket\r\n"
        lines << "connection: Upgrade\r\n"
        lines << "sec-websocket-accept: #{accept_value}\r\n"
        lines << "sec-websocket-protocol: #{subprotocol}\r\n" if subprotocol
        extra_headers.each do |k, v|
          lines << "#{k.to_s.downcase}: #{v}\r\n"
        end
        lines << "\r\n"
        lines
      end

      # Default origin allow-list. nil = accept any origin (the safe
      # default for backend services where browsers enforce CORS-style
      # restrictions independently). Operators can override via the env
      # var fallback `HYPERION_WS_ORIGIN_ALLOW_LIST` (comma-separated)
      # without needing to thread a Hyperion::Config DSL change in.
      def self.default_origin_allow_list
        raw = ENV.fetch('HYPERION_WS_ORIGIN_ALLOW_LIST', nil)
        return nil if raw.nil? || raw.empty?

        raw.split(',').map(&:strip).reject(&:empty?)
      end

      # --- internals below ---------------------------------------------

      def self.websocket_upgrade?(env)
        upgrade = env[UPGRADE_KEY]
        return false if upgrade.nil? || upgrade.empty?

        # RFC 6455 §4.1: Upgrade may carry a comma-separated token list
        # in theory, but in practice browsers always send a single
        # token. Accept either; we just need `websocket` to appear.
        return false unless tokenize(upgrade).any? { |t| t.casecmp?('websocket') }

        # Connection MUST contain `upgrade` (case-insensitive) but the
        # full value can be a token list like `keep-alive, Upgrade` —
        # particularly common from older Firefox + some proxy chains.
        connection = env[CONNECTION_KEY]
        return false if connection.nil? || connection.empty?

        tokenize(connection).any? { |t| t.casecmp?('upgrade') }
      end
      private_class_method :websocket_upgrade?

      def self.tokenize(header_value)
        header_value.to_s.split(',').map(&:strip)
      end
      private_class_method :tokenize

      def self.http_version_at_least_1_1?(proto)
        # proto is like "HTTP/1.1" or "HTTP/2.0" — split off the version
        # tail and compare numerically. RFC 6455 says "HTTP/1.1 or higher".
        version = proto.sub('HTTP/', '')
        major_s, minor_s = version.split('.', 2)
        major = major_s.to_i
        minor = minor_s.to_i
        return true if major > 1
        return false if major < 1

        minor >= 1
      end
      private_class_method :http_version_at_least_1_1?

      # RFC 6455 §4.1: client key MUST be a base64-encoded random nonce of
      # 16 bytes. Validate by decoding strictly (no newlines, no padding
      # tolerance) and asserting decoded length. A key like
      # `not-base64!!` decodes to garbage of arbitrary length, so we
      # rescue ArgumentError from strict_decode64 and treat it as invalid.
      def self.valid_client_key?(client_key)
        decoded = Base64.strict_decode64(client_key)
        decoded.bytesize == 16
      rescue ArgumentError
        false
      end
      private_class_method :valid_client_key?

      def self.origin_allowed?(origin, allow_list)
        # An empty / missing Origin is allowed only if the allow-list
        # explicitly includes nil or the empty string. This matches the
        # principle of "browsers send Origin, non-browsers may not — if
        # you've configured an allow-list, you've decided non-browsers
        # don't get a free pass".
        return true if allow_list.nil?

        allow_list.any? { |allowed| allowed == origin }
      end
      private_class_method :origin_allowed?

      def self.pick_subprotocol(header_value, selector)
        return nil if selector.nil?
        return nil if header_value.nil? || header_value.empty?

        offered = tokenize(header_value)
        return nil if offered.empty?

        chosen = selector.call(offered)
        return nil unless chosen.is_a?(String)
        return nil unless offered.include?(chosen)

        chosen
      end
      private_class_method :pick_subprotocol

      def self.bad_request(message)
        [:bad_request, message, {}]
      end
      private_class_method :bad_request
    end
  end
end
