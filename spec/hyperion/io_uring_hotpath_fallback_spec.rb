# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/io_uring'

# Cross-platform fallback / policy spec for the hotpath gate. Runs on
# every CI matrix entry — verifies that hotpath_supported? returns
# false in all the documented "not available" cases without crashing.
RSpec.describe Hyperion::IOUring, '.hotpath_supported?' do
  before { described_class.reset! }
  after  { described_class.reset! }

  it 'returns false on Darwin' do
    allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
    expect(described_class.hotpath_supported?).to eq(false)
  end

  it 'returns false when the kernel is older than 5.6 (accept-only baseline absent)' do
    allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '5.4.0' })
    expect(described_class.hotpath_supported?).to eq(false)
  end

  it 'caches the probe result across calls' do
    allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
    described_class.hotpath_supported?
    expect(Etc).not_to receive(:uname)
    described_class.hotpath_supported?
  end
end

RSpec.describe Hyperion::IOUring, '.resolve_hotpath_policy!' do
  before { described_class.reset! }
  after  { described_class.reset! }

  it 'returns false for :off' do
    expect(described_class.resolve_hotpath_policy!(:off)).to eq(false)
  end

  it 'returns false for nil' do
    expect(described_class.resolve_hotpath_policy!(nil)).to eq(false)
  end

  it 'returns false for false' do
    expect(described_class.resolve_hotpath_policy!(false)).to eq(false)
  end

  it 'raises Unsupported for :on on hosts where hotpath_supported? is false' do
    allow(described_class).to receive(:hotpath_supported?).and_return(false)
    expect {
      described_class.resolve_hotpath_policy!(:on)
    }.to raise_error(described_class::Unsupported, /unsupported on this host/)
  end

  it ':auto returns false on hosts where hotpath_supported? is false' do
    allow(described_class).to receive(:hotpath_supported?).and_return(false)
    expect(described_class.resolve_hotpath_policy!(:auto)).to eq(false)
  end

  it ':auto returns true on hosts where hotpath_supported? is true' do
    allow(described_class).to receive(:hotpath_supported?).and_return(true)
    expect(described_class.resolve_hotpath_policy!(:auto)).to eq(true)
  end

  it ':on returns true on hosts where hotpath_supported? is true' do
    allow(described_class).to receive(:hotpath_supported?).and_return(true)
    expect(described_class.resolve_hotpath_policy!(:on)).to eq(true)
  end

  it 'raises ArgumentError on unknown values' do
    expect {
      described_class.resolve_hotpath_policy!('bogus')
    }.to raise_error(ArgumentError, /must be :off, :auto, or :on/)
  end
end
