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

    # Case-insensitive header lookup. Phase 11 — Hyperion's parser stores
    # header names lowercased (the parser's normalisation contract), and
    # the in-tree hot-path callers (Adapter::Rack#build_env,
    # Connection#should_keep_alive?, Handshake#validate) all pass frozen
    # lowercase literals. Pre-Phase-11 the unconditional `name.downcase`
    # allocated a redundant copy per call. Fast-path direct hash lookup;
    # only fall through to `downcase` when the literal lookup misses,
    # which preserves the case-insensitive contract for mixed-case callers
    # (specs, third-party middleware) without paying the allocation on
    # every request.
    def header(name)
      v = @headers[name]
      return v unless v.nil?

      @headers[name.downcase]
    end
  end
end
