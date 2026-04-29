# frozen_string_literal: true

RSpec.describe Hyperion::DispatchMode do
  describe '.resolve' do
    it 'returns :tls_h2 for TLS + h2 ALPN' do
      mode = described_class.resolve(tls: true, async_io: nil, thread_count: 5, alpn: 'h2')
      expect(mode.name).to eq(:tls_h2)
    end

    it 'returns :tls_h1_inline for TLS + http/1.1 ALPN with default async_io' do
      mode = described_class.resolve(tls: true, async_io: nil, thread_count: 5, alpn: 'http/1.1')
      expect(mode.name).to eq(:tls_h1_inline)
    end

    it 'returns :async_io_h1_inline for plain HTTP + async_io: true' do
      mode = described_class.resolve(tls: false, async_io: true, thread_count: 5, alpn: nil)
      expect(mode.name).to eq(:async_io_h1_inline)
    end

    it 'returns :threadpool_h1 for plain HTTP + default async_io with positive thread_count' do
      mode = described_class.resolve(tls: false, async_io: nil, thread_count: 5, alpn: nil)
      expect(mode.name).to eq(:threadpool_h1)
    end

    it 'returns :threadpool_h1 for TLS + async_io: false (explicit pool opt-out)' do
      mode = described_class.resolve(tls: true, async_io: false, thread_count: 5, alpn: 'http/1.1')
      expect(mode.name).to eq(:threadpool_h1)
    end

    it 'returns :inline_h1_no_pool for thread_count: 0 + plain HTTP' do
      mode = described_class.resolve(tls: false, async_io: nil, thread_count: 0, alpn: nil)
      expect(mode.name).to eq(:inline_h1_no_pool)
    end

    it 'returns :async_io_h1_inline for --async-io -t 0 (RFC §5 Q3)' do
      mode = described_class.resolve(tls: false, async_io: true, thread_count: 0, alpn: nil)
      expect(mode.name).to eq(:async_io_h1_inline)
    end
  end

  describe 'predicates' do
    it 'inline? is true for tls_h1_inline / async_io_h1_inline / inline_h1_no_pool' do
      expect(described_class.new(:tls_h1_inline).inline?).to be(true)
      expect(described_class.new(:async_io_h1_inline).inline?).to be(true)
      expect(described_class.new(:inline_h1_no_pool).inline?).to be(true)
    end

    it 'inline? is false for threadpool / h2' do
      expect(described_class.new(:threadpool_h1).inline?).to be(false)
      expect(described_class.new(:tls_h2).inline?).to be(false)
    end

    it 'threadpool? is true only for threadpool_h1' do
      expect(described_class.new(:threadpool_h1).threadpool?).to be(true)
      described_class::MODES.reject { |m| m == :threadpool_h1 }.each do |m|
        expect(described_class.new(m).threadpool?).to be(false)
      end
    end

    it 'h2? is true only for tls_h2' do
      expect(described_class.new(:tls_h2).h2?).to be(true)
      expect(described_class.new(:threadpool_h1).h2?).to be(false)
    end

    it 'async? matches the cooperative-scheduler set' do
      %i[tls_h2 tls_h1_inline async_io_h1_inline].each do |m|
        expect(described_class.new(m).async?).to be(true)
      end
      %i[threadpool_h1 inline_h1_no_pool].each do |m|
        expect(described_class.new(m).async?).to be(false)
      end
    end

    it 'pooled? is true only for threadpool_h1' do
      expect(described_class.new(:threadpool_h1).pooled?).to be(true)
      expect(described_class.new(:inline_h1_no_pool).pooled?).to be(false)
    end
  end

  describe 'value-object semantics' do
    it 'is frozen after construction' do
      expect(described_class.new(:tls_h2)).to be_frozen
    end

    it 'compares equal by name' do
      a = described_class.new(:tls_h2)
      b = described_class.new(:tls_h2)
      expect(a).to eq(b)
      expect(a).to eql(b)
      expect(a.hash).to eq(b.hash)
    end

    it 'compares unequal across different names' do
      expect(described_class.new(:tls_h2)).not_to eq(described_class.new(:threadpool_h1))
    end

    it 'rejects unknown mode names' do
      expect { described_class.new(:bogus) }.to raise_error(ArgumentError, /unknown DispatchMode/)
    end

    it 'metric_key follows the :requests_dispatch_<mode> convention' do
      expect(described_class.new(:tls_h2).metric_key).to eq(:requests_dispatch_tls_h2)
      expect(described_class.new(:threadpool_h1).metric_key).to eq(:requests_dispatch_threadpool_h1)
    end
  end
end
