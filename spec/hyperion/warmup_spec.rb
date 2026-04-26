# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Hyperion.warmup!' do
  before do
    # Reset the idempotency flag so each example exercises a fresh boot.
    # The instance variable is private to the singleton; reach in via
    # remove_instance_variable to avoid leaving stale state across runs.
    Hyperion.remove_instance_variable(:@warmed) if Hyperion.instance_variable_defined?(:@warmed)
  end

  after do
    Hyperion.remove_instance_variable(:@warmed) if Hyperion.instance_variable_defined?(:@warmed)
  end

  it 'pre-allocates the Rack env pool by calling Adapter::Rack.warmup_pool' do
    allow(::Hyperion::Adapter::Rack).to receive(:warmup_pool).and_call_original
    Hyperion.warmup!
    expect(::Hyperion::Adapter::Rack).to have_received(:warmup_pool).with(8)
  end

  it 'is idempotent — second call is a no-op' do
    allow(::Hyperion::Adapter::Rack).to receive(:warmup_pool).and_call_original
    Hyperion.warmup!
    Hyperion.warmup!
    Hyperion.warmup!
    expect(::Hyperion::Adapter::Rack).to have_received(:warmup_pool).once
  end

  it 'does not raise when Adapter::Rack does not respond to warmup_pool' do
    # Older Adapter::Rack (or a future stripped-down build) may not expose
    # warmup_pool — Hyperion.warmup! must degrade silently in that case
    # rather than turning every boot into a hard failure.
    allow(::Hyperion::Adapter::Rack).to receive(:respond_to?).and_call_original
    allow(::Hyperion::Adapter::Rack).to receive(:respond_to?).with(:warmup_pool).and_return(false)
    expect { Hyperion.warmup! }.not_to raise_error
  end

  it 'returns nil from the first call' do
    expect(Hyperion.warmup!).to be_nil
  end

  it 'returns nil from subsequent (no-op) calls' do
    Hyperion.warmup!
    expect(Hyperion.warmup!).to be_nil
  end

  it 'logs a warn and swallows StandardError raised by an internal step' do
    allow(::Hyperion::Adapter::Rack).to receive(:warmup_pool).and_raise(StandardError, 'boom')
    expect(Hyperion.logger).to receive(:warn) do |&block|
      payload = block.call
      expect(payload[:message]).to include('warmup failed')
      expect(payload[:error]).to eq('boom')
    end
    expect { Hyperion.warmup! }.not_to raise_error
  end
end

RSpec.describe Hyperion::Adapter::Rack do
  describe '.warmup_pool' do
    it 'releases pre-allocated env hashes back to ENV_POOL' do
      # After warmup, the pool's free-list size should reflect the warmup
      # count (capped at the pool's max_size). Acquire a few and verify
      # they come back populated rather than freshly allocated.
      described_class.warmup_pool(4)
      pool = described_class.const_get(:ENV_POOL)
      expect(pool.size).to be >= 4
    end

    it 'is safe to call repeatedly without exceeding pool max_size' do
      pool = described_class.const_get(:ENV_POOL)
      described_class.warmup_pool(4)
      described_class.warmup_pool(4)
      # Pool is bounded — the second call's release ops are absorbed when
      # the free-list is full. No exception, no unbounded growth.
      expect(pool.size).to be <= 256
    end
  end
end
