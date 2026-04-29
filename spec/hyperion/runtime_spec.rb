# frozen_string_literal: true

RSpec.describe Hyperion::Runtime do
  after { described_class.reset_default! }

  describe '.default' do
    it 'returns a singleton across calls' do
      a = described_class.default
      b = described_class.default
      expect(a).to be(b)
    end

    it 'is NOT frozen after first read (RFC §5 Q4)' do
      r = described_class.default
      expect(r).not_to be_frozen
      expect { r.metrics = Hyperion::Metrics.new }.not_to raise_error
    end

    it 'survives metrics swap on the default runtime' do
      original = described_class.default.metrics
      replacement = Hyperion::Metrics.new
      described_class.default.metrics = replacement
      expect(described_class.default.metrics).to be(replacement)
      expect(described_class.default.metrics).not_to be(original)
    end
  end

  describe '.default=' do
    it 'replaces the singleton with a known instance' do
      replacement = described_class.new(metrics: Hyperion::Metrics.new,
                                        logger: Hyperion::Logger.new)
      described_class.default = replacement
      expect(described_class.default).to be(replacement)
    end

    it 'rejects non-Runtime arguments' do
      expect { described_class.default = :nope }.to raise_error(ArgumentError, /expected/)
    end
  end

  describe '.reset_default!' do
    it 'forces the next .default call to allocate fresh' do
      a = described_class.default
      described_class.reset_default!
      b = described_class.default
      expect(a).not_to be(b)
    end
  end

  describe '#initialize' do
    it 'accepts custom metrics and logger' do
      metrics = Hyperion::Metrics.new
      logger  = Hyperion::Logger.new
      runtime = described_class.new(metrics: metrics, logger: logger)
      expect(runtime.metrics).to be(metrics)
      expect(runtime.logger).to be(logger)
    end

    it 'defaults metrics + logger to fresh instances when not given' do
      runtime = described_class.new
      expect(runtime.metrics).to be_a(Hyperion::Metrics)
      expect(runtime.logger).to be_a(Hyperion::Logger)
    end
  end

  describe '#default?' do
    it 'is true for Runtime.default' do
      expect(described_class.default.default?).to be(true)
    end

    it 'is false for runtimes constructed with Runtime.new' do
      expect(described_class.new.default?).to be(false)
    end
  end

  describe 'legacy module-level overrides' do
    around do |ex|
      prev_metrics = Hyperion.instance_variable_get(:@metrics)
      prev_logger  = Hyperion.instance_variable_get(:@logger)
      ex.run
    ensure
      Hyperion.instance_variable_set(:@metrics, prev_metrics)
      Hyperion.instance_variable_set(:@logger, prev_logger)
    end

    it 'honours Hyperion.@metrics override on Runtime.default reads' do
      override = Hyperion::Metrics.new
      Hyperion.instance_variable_set(:@metrics, override)
      expect(described_class.default.metrics).to be(override)
    end

    it 'honours Hyperion.@logger override on Runtime.default reads' do
      override = Hyperion::Logger.new
      Hyperion.instance_variable_set(:@logger, override)
      expect(described_class.default.logger).to be(override)
    end

    it 'does NOT honour Hyperion.@metrics override on a custom Runtime' do
      override = Hyperion::Metrics.new
      Hyperion.instance_variable_set(:@metrics, override)
      custom = described_class.new
      expect(custom.metrics).not_to be(override)
    end
  end
end
