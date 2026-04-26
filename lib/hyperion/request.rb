# frozen_string_literal: true

module Hyperion
  # Immutable parsed-request value object.
  # Phase 5 (object pooling) will redesign this with explicit reset semantics;
  # for Phase 1 we freeze on construction to prevent accidental mutation.
  class Request
    attr_reader :method, :path, :query_string, :http_version, :headers, :body, :peer_address

    def initialize(method:, path:, query_string:, http_version:, headers:, body:, peer_address: nil)
      @method       = method
      @path         = path
      @query_string = query_string
      @http_version = http_version
      @headers      = headers.freeze
      @body         = body
      @peer_address = peer_address
      freeze
    end

    def header(name)
      @headers[name.downcase]
    end
  end
end
