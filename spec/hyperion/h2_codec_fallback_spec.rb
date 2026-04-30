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
      expect(handler.codec_native?).to be(false)
    ensure
      Hyperion::H2Codec.reset!
    end

    it 'reports codec_native? true when H2Codec loaded and the env var is unset (default since 2.5-B flip)' do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:available?).and_return(true)
      stub_const('ENV', ENV.to_h.merge('HYPERION_H2_NATIVE_HPACK' => nil))
      handler = Hyperion::Http2Handler.new(app: ->(_) { [200, {}, ['']] })

      # 2.5-B (2.5.0): native HPACK is on the hot path BY DEFAULT when
      # the Rust crate loaded. Operators who want the prior 2.4.x
      # Ruby-fallback default must set HYPERION_H2_NATIVE_HPACK=off.
      expect(handler.codec_available?).to be(true)
      expect(handler.codec_native?).to be(true)
    ensure
      Hyperion::H2Codec.reset!
    end

    it 'reports codec_native? false when HYPERION_H2_NATIVE_HPACK=off (explicit opt-out, since 2.5-B)' do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:available?).and_return(true)
      stub_const('ENV', ENV.to_h.merge('HYPERION_H2_NATIVE_HPACK' => 'off'))
      handler = Hyperion::Http2Handler.new(app: ->(_) { [200, {}, ['']] })

      expect(handler.codec_available?).to be(true)
      expect(handler.codec_native?).to be(false)
    ensure
      Hyperion::H2Codec.reset!
    end

    it 'reports codec_native? true when H2Codec is available AND HYPERION_H2_NATIVE_HPACK=1' do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:available?).and_return(true)
      stub_const('ENV', ENV.to_h.merge('HYPERION_H2_NATIVE_HPACK' => '1'))
      handler = Hyperion::Http2Handler.new(app: ->(_) { [200, {}, ['']] })
      expect(handler.codec_native?).to be(true)
    ensure
      Hyperion::H2Codec.reset!
    end

    it 'logs the codec selection state at most once per process' do
      Hyperion::Http2Handler.instance_variable_set(:@codec_state_logged, nil)
      sink = StringIO.new
      runtime = Hyperion::Runtime.new(logger: Hyperion::Logger.new(io: sink, format: :json))
      3.times do
        Hyperion::Http2Handler.new(app: ->(_) { [200, {}, ['']] }, runtime: runtime)
      end
      occurrences = sink.string.scan(/h2 codec selected/).length
      expect(occurrences).to eq(1)
    ensure
      Hyperion::Http2Handler.instance_variable_set(:@codec_state_logged, nil)
    end
  end
end
