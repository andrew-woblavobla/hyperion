# frozen_string_literal: true

RSpec.describe Hyperion::Metrics do
  subject(:metrics) { described_class.new }

  it 'tracks counter increments' do
    metrics.increment(:requests_total)
    metrics.increment(:requests_total, 4)
    expect(metrics.snapshot[:requests_total]).to eq(5)
  end

  it 'tracks decrements' do
    metrics.increment(:in_flight, 3)
    metrics.decrement(:in_flight)
    expect(metrics.snapshot[:in_flight]).to eq(2)
  end

  it 'tracks per-status response counts' do
    metrics.increment_status(200)
    metrics.increment_status(200)
    metrics.increment_status(404)
    snap = metrics.snapshot
    expect(snap[:responses_200]).to eq(2)
    expect(snap[:responses_404]).to eq(1)
  end
end
