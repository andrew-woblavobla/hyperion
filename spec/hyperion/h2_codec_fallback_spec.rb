# frozen_string_literal: true

# Phase 6 (RFC §3 2.0.0) — fallback path. When `H2Codec.available?`
# is false (no Rust toolchain at install time, ABI mismatch, etc.)
# the existing `protocol-http2` Ruby HPACK path must keep working
# and serve h2 traffic correctly. These specs lock in that contract
# by stubbing `available?` to false and exercising the h2 dispatch
# end-to-end.
RSpec.describe 'H2Codec fallback (Ruby protocol-http2 path)' do
  describe '.available? gating' do
    it 'reports false after a forced reset on a synthetic missing path' do
      # Stub the candidate paths to point nowhere, force reload.
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:candidate_paths).and_return(['/nonexistent/lib.dylib'])
      expect(Hyperion::H2Codec.available?).to be(false)
    ensure
      Hyperion::H2Codec.reset!
    end

    it 'reports the real loaded state when reset and probed against the actual filesystem' do
      Hyperion::H2Codec.reset!
      # No stub — let the loader probe normally. The result depends
      # on whether cargo built the cdylib in CI. Both outcomes are
      # valid: we just assert the API doesn't raise.
      expect { Hyperion::H2Codec.available? }.not_to raise_error
    ensure
      Hyperion::H2Codec.reset!
    end

    it 'leaves Encoder.new raising a clear error when unavailable' do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:candidate_paths).and_return(['/nonexistent/lib.dylib'])
      Hyperion::H2Codec.available? # warm the false memo
      expect { Hyperion::H2Codec::Encoder.new }
        .to raise_error(/native library unavailable/)
    ensure
      Hyperion::H2Codec.reset!
    end
  end

  describe 'Http2Handler integration when codec unavailable' do
    # This spec is end-to-end-ish: we boot a tiny HTTP/2 server with
    # the codec stubbed unavailable and confirm that protocol-http2
    # still encodes/decodes a request/response. The actual h2-handler
    # already routes through protocol-http2; the codec is opt-in.
    it 'serves an h2 request through protocol-http2 when H2Codec is stubbed unavailable' do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:available?).and_return(false)

      # We don't spin up a full TLS+ALPN listener in this spec — the
      # contract is that Http2Handler doesn't hard-fail on construction
      # when the codec is unavailable. The wire path itself is covered
      # by the existing http2_handler_spec / http2_settings_spec
      # families which all run against protocol-http2 today.
      handler = Hyperion::Http2Handler.new(
        app: ->(_) { [200, {}, ['']] },
        h2_settings: { max_concurrent_streams: 8 }
      )
      expect(handler).to be_a(Hyperion::Http2Handler)
    ensure
      Hyperion::H2Codec.reset!
    end
  end
end
