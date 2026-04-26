# frozen_string_literal: true

require 'tempfile'

RSpec.describe Hyperion::Config do
  it 'has sane defaults' do
    cfg = described_class.new
    expect(cfg.host).to eq('127.0.0.1')
    expect(cfg.port).to eq(9292)
    expect(cfg.workers).to eq(1)
    expect(cfg.thread_count).to eq(5)
    expect(cfg.read_timeout).to eq(30)
    expect(cfg.idle_keepalive).to eq(5)
    expect(cfg.graceful_timeout).to eq(30)
    expect(cfg.max_header_bytes).to eq(64 * 1024)
    expect(cfg.max_body_bytes).to eq(16 * 1024 * 1024)
    expect(cfg.fiber_local_shim).to be(false)
    expect(cfg.before_fork).to eq([])
    expect(cfg.on_worker_boot).to eq([])
    expect(cfg.on_worker_shutdown).to eq([])
  end

  describe '.load' do
    it 'evaluates a Ruby DSL file' do
      file = Tempfile.new(['hyperion', '.rb'])
      file.write(<<~RUBY)
        bind '0.0.0.0'
        port 19200
        workers 4
        thread_count 16
        log_level :debug
        log_format :json
      RUBY
      file.close

      cfg = described_class.load(file.path)
      expect(cfg.host).to eq('0.0.0.0')
      expect(cfg.port).to eq(19_200)
      expect(cfg.workers).to eq(4)
      expect(cfg.thread_count).to eq(16)
      expect(cfg.log_level).to eq(:debug)
      expect(cfg.log_format).to eq(:json)
    ensure
      file.unlink
    end

    it 'registers lifecycle hooks' do
      file = Tempfile.new(['hyperion', '.rb'])
      file.write(<<~RUBY)
        before_fork { :master_close }
        on_worker_boot { |idx| [:worker_boot, idx] }
        on_worker_shutdown { |idx| [:worker_shutdown, idx] }
      RUBY
      file.close

      cfg = described_class.load(file.path)
      expect(cfg.before_fork.size).to eq(1)
      expect(cfg.before_fork.first.call).to eq(:master_close)
      expect(cfg.on_worker_boot.size).to eq(1)
      expect(cfg.on_worker_boot.first.call(2)).to eq([:worker_boot, 2])
      expect(cfg.on_worker_shutdown.first.call(0)).to eq([:worker_shutdown, 0])
    ensure
      file.unlink
    end

    it 'raises on unknown DSL methods so typos surface at boot' do
      file = Tempfile.new(['hyperion', '.rb'])
      file.write("threads_typo 5\n")
      file.close

      expect { described_class.load(file.path) }.to raise_error(NoMethodError)
    ensure
      file.unlink
    end
  end

  describe '#merge_cli!' do
    it 'overrides config values from CLI hash, ignoring nils' do
      cfg = described_class.new
      cfg.port = 9000
      cfg.workers = 4

      cfg.merge_cli!(port: 9100, workers: nil, thread_count: 8)

      expect(cfg.port).to eq(9100) # CLI override applied
      expect(cfg.workers).to eq(4) # CLI value was nil → kept
      expect(cfg.thread_count).to eq(8)
    end
  end
end
