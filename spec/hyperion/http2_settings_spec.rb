# frozen_string_literal: true

require 'protocol/http2/server'
require 'protocol/http2/framer'
require 'protocol/http2/settings_frame'

# Unit tests for HTTP/2 SETTINGS plumbing: configured Hyperion settings must
# end up in the [setting_id, value] payload that goes into the connection's
# initial SETTINGS frame, and out-of-range values must be clamped (not left
# to crash protocol-http2's setter at handshake time).
RSpec.describe Hyperion::Http2Handler do
  describe '#initial_settings_payload' do
    let(:app) { ->(_) { [200, {}, ['ok']] } }

    def handler_with(settings)
      described_class.new(app: app, h2_settings: settings)
    end

    # Look up the encoded value for a given symbolic key in the wire payload.
    # The payload is an Array of [setting_id, value] pairs; we map back via
    # SETTINGS_KEY_MAP for readable assertions.
    def value_for(payload, key)
      setting_id = described_class::SETTINGS_KEY_MAP[key]
      pair = payload.find { |id, _| id == setting_id }
      pair && pair[1]
    end

    it 'returns an empty payload when no settings are configured (preserves protocol-http2 defaults)' do
      handler = described_class.new(app: app)
      expect(handler.send(:initial_settings_payload)).to eq([])
    end

    it 'plumbs configured values into [setting_id, value] pairs' do
      handler = handler_with(
        max_concurrent_streams: 128,
        initial_window_size: 1_048_576,
        max_frame_size: 1_048_576,
        max_header_list_size: 65_536
      )
      payload = handler.send(:initial_settings_payload)

      expect(value_for(payload, :max_concurrent_streams)).to eq(128)
      expect(value_for(payload, :initial_window_size)).to eq(1_048_576)
      expect(value_for(payload, :max_frame_size)).to eq(1_048_576)
      expect(value_for(payload, :max_header_list_size)).to eq(65_536)
    end

    it 'skips nil values rather than emitting a malformed entry' do
      handler = handler_with(max_concurrent_streams: 64, initial_window_size: nil)
      payload = handler.send(:initial_settings_payload)

      expect(value_for(payload, :max_concurrent_streams)).to eq(64)
      expect(value_for(payload, :initial_window_size)).to be_nil # absent → no entry
    end

    it 'clamps max_frame_size below the spec floor (16384) and warns' do
      logger = instance_double(Hyperion::Logger)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:info) # Phase 6b: Http2Handler#initialize logs codec boot state
      allow(Hyperion).to receive(:logger).and_return(logger)

      handler = handler_with(max_frame_size: 100)
      payload = handler.send(:initial_settings_payload)

      expect(value_for(payload, :max_frame_size)).to eq(16_384)
      expect(logger).to have_received(:warn).at_least(:once)
    end

    it 'clamps max_frame_size above the spec ceiling (16777215)' do
      handler = handler_with(max_frame_size: 99_999_999)
      payload = handler.send(:initial_settings_payload)

      expect(value_for(payload, :max_frame_size)).to eq(0xFFFFFF)
    end

    it 'clamps initial_window_size above the 31-bit max' do
      handler = handler_with(initial_window_size: 0x80000000)
      payload = handler.send(:initial_settings_payload)

      expect(value_for(payload, :initial_window_size)).to eq(0x7FFFFFFF)
    end

    it 'logs a warning and skips unknown setting keys' do
      logger = instance_double(Hyperion::Logger)
      allow(logger).to receive(:warn)
      allow(Hyperion).to receive(:logger).and_return(logger)

      handler = handler_with(bogus_setting: 42, max_concurrent_streams: 128)
      payload = handler.send(:initial_settings_payload)

      expect(payload.size).to eq(1)
      expect(value_for(payload, :max_concurrent_streams)).to eq(128)
      expect(logger).to have_received(:warn).at_least(:once)
    end
  end

  describe 'Master.build_h2_settings (CLI plumbing)' do
    it 'pulls h2_* keys out of Config into the hash that Server expects' do
      cfg = Hyperion::Config.new
      h = Hyperion::Master.build_h2_settings(cfg)

      expect(h[:max_concurrent_streams]).to eq(128)
      expect(h[:initial_window_size]).to eq(1_048_576)
      expect(h[:max_frame_size]).to eq(1_048_576)
      expect(h[:max_header_list_size]).to eq(65_536)
    end

    it 'omits keys whose config value is nil so operators can disable individual overrides' do
      cfg = Hyperion::Config.new
      cfg.h2.max_concurrent_streams = nil
      cfg.h2.initial_window_size = nil

      h = Hyperion::Master.build_h2_settings(cfg)

      expect(h).not_to have_key(:max_concurrent_streams)
      expect(h).not_to have_key(:initial_window_size)
      expect(h[:max_frame_size]).to eq(1_048_576)
      expect(h[:max_header_list_size]).to eq(65_536)
    end
  end

  describe 'wire encoding through protocol-http2' do
    it 'sends the configured SETTINGS values to a peer driving Server.new directly' do
      # Build a minimal in-memory pipe and run protocol-http2's Server through
      # our handler's payload helper. We never read the preface back — just
      # verify the [id, value] tuples we hand to read_connection_preface go
      # into the ASSIGN-mapped attributes on the local pending settings.
      handler = described_class.new(
        app: ->(_) { [200, {}, ['']] },
        h2_settings: { max_concurrent_streams: 96, max_header_list_size: 32_768 }
      )
      payload = handler.send(:initial_settings_payload)

      # Apply via the gem's own machinery — this is exactly what
      # Server#read_connection_preface ultimately invokes via send_settings.
      pending = Protocol::HTTP2::PendingSettings.new
      pending.append(payload.to_h)

      # PendingSettings#append updates @pending; only #acknowledge moves
      # values into @current (after the peer ACKs the SETTINGS frame).
      expect(pending.pending.maximum_concurrent_streams).to eq(96)
      expect(pending.pending.maximum_header_list_size).to eq(32_768)
    end
  end
end
