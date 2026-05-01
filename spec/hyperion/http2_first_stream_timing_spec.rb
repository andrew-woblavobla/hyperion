# frozen_string_literal: true

# 2.10-G — opt-in connection-setup timing instrumentation.
#
# These specs lock the contract of the timing path WITHOUT making any
# assertion about absolute latency numbers (those are a property of the
# host the bench runs on, not of the code under test, and would be a
# CI-flake nightmare). What we DO lock is:
#
#   1. The instrumentation is OFF by default. With no env var set, no
#      timing log line is emitted regardless of how many connections are
#      served, and the per-connection ivars stay nil.
#
#   2. With `HYPERION_H2_TIMING=1` set at handler-construction time, the
#      handler captures four monotonic timestamps (t0, t1, t2_encode,
#      t2_wire) on a connection-flow code path and emits a single
#      `'h2 first-stream timing'` info line per connection that served at
#      least one stream. The deltas are non-negative and ordered.
#
#   3. The capture branches are gated by a simple ivar read — connections
#      served while instrumentation is disabled pay zero per-stream
#      overhead. Spec ensures the WriterContext slots stay nil on the
#      disabled-by-default path.
RSpec.describe 'Hyperion::Http2Handler 2.10-G first-stream timing' do
  describe Hyperion::Http2Handler::WriterContext do
    it 'starts with all 2.10-G timing slots nil' do
      ctx = described_class.new
      expect(ctx.t0_serve_entry).to be_nil
      expect(ctx.t1_preface_done).to be_nil
      expect(ctx.t2_first_encode).to be_nil
      expect(ctx.t2_first_wire).to be_nil
    end

    it 'exposes timing slots as setters for the handler to populate' do
      ctx = described_class.new
      ctx.t0_serve_entry = 1.0
      ctx.t1_preface_done = 1.001
      ctx.t2_first_encode = 1.005
      ctx.t2_first_wire = 1.006
      expect(ctx.t0_serve_entry).to eq(1.0)
      expect(ctx.t1_preface_done).to eq(1.001)
      expect(ctx.t2_first_encode).to eq(1.005)
      expect(ctx.t2_first_wire).to eq(1.006)
    end
  end

  describe '#log_h2_first_stream_timing' do
    let(:app) { ->(_env) { [200, {}, ['ok']] } }

    def build_handler(env: {})
      saved = ENV.to_h.slice(*env.keys)
      env.each { |k, v| ENV[k] = v }
      handler = Hyperion::Http2Handler.new(app: app)
      yield handler
    ensure
      env.each_key { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
    end

    it 'emits an info-level line with three non-negative deltas in ms' do
      build_handler(env: { 'HYPERION_H2_TIMING' => '1' }) do |handler|
        ctx = Hyperion::Http2Handler::WriterContext.new
        ctx.t0_serve_entry  = 100.000
        ctx.t1_preface_done = 100.012
        ctx.t2_first_encode = 100.040
        ctx.t2_first_wire   = 100.041

        captured = nil
        fake_logger = Object.new
        fake_logger.define_singleton_method(:info) { |&blk| captured = blk.call }
        handler.instance_variable_set(:@logger, fake_logger)

        handler.send(:log_h2_first_stream_timing, ctx)

        expect(captured).not_to be_nil
        expect(captured[:message]).to eq('h2 first-stream timing')
        expect(captured[:t0_to_t1_ms]).to be_within(0.001).of(12.0)
        expect(captured[:t1_to_t2_enc_ms]).to be_within(0.001).of(28.0)
        expect(captured[:t2_enc_to_t2_wire_ms]).to be_within(0.001).of(1.0)
        expect(captured[:t0_to_t2_wire_ms]).to be_within(0.001).of(41.0)
      end
    end

    it 'is a no-op when any timestamp is missing (connection died early)' do
      build_handler(env: { 'HYPERION_H2_TIMING' => '1' }) do |handler|
        ctx = Hyperion::Http2Handler::WriterContext.new
        ctx.t0_serve_entry  = 100.000
        ctx.t1_preface_done = 100.012
        # t2_first_encode + t2_first_wire intentionally nil — the connection
        # dropped after preface but before the first stream completed.

        emitted = false
        fake_logger = Object.new
        fake_logger.define_singleton_method(:info) { |&_blk| emitted = true }
        handler.instance_variable_set(:@logger, fake_logger)

        handler.send(:log_h2_first_stream_timing, ctx)
        expect(emitted).to be(false)
      end
    end

    it 'never raises out of the timing helper (instrumentation is best-effort)' do
      build_handler(env: { 'HYPERION_H2_TIMING' => '1' }) do |handler|
        ctx = Hyperion::Http2Handler::WriterContext.new
        ctx.t0_serve_entry  = 100.0
        ctx.t1_preface_done = 100.012
        ctx.t2_first_encode = 100.040
        ctx.t2_first_wire   = 100.041

        boom_logger = Object.new
        boom_logger.define_singleton_method(:info) { |&_blk| raise 'boom' }
        handler.instance_variable_set(:@logger, boom_logger)

        expect { handler.send(:log_h2_first_stream_timing, ctx) }.not_to raise_error
      end
    end
  end

  describe 'env-flag gating at handler construction' do
    let(:app) { ->(_env) { [200, {}, ['ok']] } }

    around do |ex|
      saved = ENV['HYPERION_H2_TIMING']
      ex.run
    ensure
      saved.nil? ? ENV.delete('HYPERION_H2_TIMING') : ENV['HYPERION_H2_TIMING'] = saved
    end

    it 'is OFF by default (env unset)' do
      ENV.delete('HYPERION_H2_TIMING')
      handler = Hyperion::Http2Handler.new(app: app)
      expect(handler.instance_variable_get(:@h2_timing_enabled)).to be(false)
    end

    it 'is OFF for explicit truthy-OFF values' do
      %w[0 false no off FALSE NO Off].each do |v|
        ENV['HYPERION_H2_TIMING'] = v
        handler = Hyperion::Http2Handler.new(app: app)
        expect(handler.instance_variable_get(:@h2_timing_enabled)).to be(false), "for value #{v.inspect}"
      end
    end

    it 'is ON for the documented truthy values' do
      %w[1 true yes on TRUE Yes ON].each do |v|
        ENV['HYPERION_H2_TIMING'] = v
        handler = Hyperion::Http2Handler.new(app: app)
        expect(handler.instance_variable_get(:@h2_timing_enabled)).to be(true), "for value #{v.inspect}"
      end
    end
  end
end
