# frozen_string_literal: true

module Hyperion
  module WebSocket
    # 2.5-A — RFC 6455 §7.4.1 close-code validation.
    #
    # The close-frame status code is a 16-bit unsigned integer at the
    # start of the close-frame payload. Only specific ranges are valid
    # on the wire, and a server that sees an invalid one MUST respond
    # with close 1002 (Protocol Error) per RFC 6455 §7.4 + §7.4.1
    # rather than echoing the bad code back.
    #
    # The IANA-assigned ranges as of RFC 6455:
    #
    #   1000–1003   Defined          (Normal, Going Away, Protocol Error,
    #                                Unsupported Data)
    #   1004        Reserved          (no defined meaning — not on wire)
    #   1005        No Status Recv'd  (synthetic — MUST NOT appear on wire)
    #   1006        Abnormal Closure  (synthetic — MUST NOT appear on wire)
    #   1007–1015   Defined           (Invalid Frame Payload, Policy
    #                                  Violation, Message Too Big,
    #                                  Mandatory Ext, Internal Error,
    #                                  Service Restart, Try Again Later,
    #                                  Bad Gateway, TLS handshake)
    #   1016–2999   Reserved for IETF future use (not on wire)
    #   3000–3999   Registered library / framework codes
    #   4000–4999   Application-private codes
    #   <1000, >=5000  Invalid (out of any defined range)
    module CloseCodes
      # Whitelisted code ranges that MAY appear on the wire from a peer.
      VALID_RANGES = [
        (1000..1003),
        (1007..1015),
        (3000..3999),
        (4000..4999)
      ].freeze

      # Reserved-for-IETF range — not currently assigned, MUST NOT appear
      # on the wire, MUST be rejected with 1002.
      RESERVED_RANGE = (1016..2999)

      # Synthetic codes that MUST NOT appear on the wire (RFC 6455 §7.4.1).
      # 1005 = "No Status Received", 1006 = "Abnormal Closure". Both are
      # produced internally by an endpoint when no close code was carried
      # by the close frame, never sent by an endpoint.
      NO_STATUS_ON_WIRE = [1005, 1006].freeze

      # Validate a peer-supplied close code.
      #
      # @param code [Integer]
      # @return [Symbol] one of:
      #   :ok                 — code is in a valid wire range, accept it
      #   :no_status_on_wire  — code is 1005 / 1006 (synthetic only)
      #   :reserved           — code is in 1016–2999 (IETF reserved)
      #   :invalid            — code is outside every defined range
      def self.validate(code)
        return :no_status_on_wire if NO_STATUS_ON_WIRE.include?(code)
        return :ok if VALID_RANGES.any? { |r| r.cover?(code) }
        return :reserved if RESERVED_RANGE.cover?(code)

        :invalid
      end

      # Convenience predicate — true if the peer's close code violates
      # RFC 6455 §7.4.1 in any way.
      def self.invalid?(code)
        validate(code) != :ok
      end
    end
  end
end
