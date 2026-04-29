# frozen_string_literal: true

RSpec.describe Hyperion::H2Admission do
  describe '#admit / #release' do
    it 'returns true unconditionally when max_total_streams is nil' do
      gate = described_class.new(max_total_streams: nil)
      100.times { expect(gate.admit).to be(true) }
    end

    it 'admits up to the cap, refuses beyond, then admits again after release' do
      gate = described_class.new(max_total_streams: 2)
      expect(gate.admit).to be(true)  # 1
      expect(gate.admit).to be(true)  # 2
      expect(gate.admit).to be(false) # 3 — refused
      expect(gate.admit).to be(false) # 4 — still refused
      gate.release
      expect(gate.admit).to be(true)
      expect(gate.admit).to be(false)
    end

    it 'tracks the rejected counter across calls' do
      gate = described_class.new(max_total_streams: 1)
      gate.admit
      3.times { gate.admit }
      expect(gate.stats[:rejected]).to eq(3)
      expect(gate.stats[:in_flight]).to eq(1)
      expect(gate.stats[:max]).to eq(1)
    end

    it 'release on a count of zero is a no-op (paranoia)' do
      gate = described_class.new(max_total_streams: 5)
      gate.release
      gate.release
      expect(gate.stats[:in_flight]).to eq(0)
    end

    it 'is mutex-safe under concurrent admit/release' do
      gate = described_class.new(max_total_streams: 50)
      threads = 10.times.map do
        Thread.new do
          100.times do
            if gate.admit
              Thread.pass
              gate.release
            end
          end
        end
      end
      threads.each(&:join)
      expect(gate.stats[:in_flight]).to eq(0)
    end
  end

  describe 'integration: Server with h2_max_total_streams' do
    it 'constructs an admission gate when set' do
      server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                    host: '127.0.0.1', port: 0,
                                    h2_max_total_streams: 16)
      gate = server.instance_variable_get(:@h2_admission)
      expect(gate).to be_a(described_class)
      expect(gate.stats[:max]).to eq(16)
    end

    it 'leaves @h2_admission nil when h2_max_total_streams is nil (operator opt-out)' do
      server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                    host: '127.0.0.1', port: 0)
      expect(server.instance_variable_get(:@h2_admission)).to be_nil
    end

    it 'leaves @h2_admission nil when an unfinalized auto-sentinel leaks through' do
      # `Config#finalize!` resolves the sentinel to a positive integer
      # before reaching Server in the regular CLI / Master path. If a
      # caller sidesteps that and constructs Server directly with the
      # raw Config sentinel, fail open (no admission) rather than
      # crashing.
      server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                    host: '127.0.0.1', port: 0,
                                    h2_max_total_streams: Hyperion::Config::H2Settings::AUTO)
      expect(server.instance_variable_get(:@h2_admission)).to be_nil
    end
  end

  describe 'Config#finalize! default flip (RFC §3 2.0.0)' do
    it 'h2.max_total_streams defaults to the AUTO sentinel before finalize' do
      cfg = Hyperion::Config.new
      expect(cfg.h2.max_total_streams).to eq(Hyperion::Config::H2Settings::AUTO)
    end

    it 'finalize!(workers: 4) resolves AUTO to max_concurrent_streams × workers × 4' do
      cfg = Hyperion::Config.new
      cfg.finalize!(workers: 4)
      # 128 (per-conn cap) × 4 workers × 4 (headroom) = 2048.
      expect(cfg.h2.max_total_streams).to eq(2048)
    end

    it 'finalize!(workers: 1) resolves AUTO to 128 × 1 × 4 = 512' do
      cfg = Hyperion::Config.new
      cfg.finalize!(workers: 1)
      expect(cfg.h2.max_total_streams).to eq(512)
    end

    it 'finalize! honours an operator-set integer cap (no overwrite)' do
      cfg = Hyperion::Config.new
      cfg.h2.max_total_streams = 4096
      cfg.finalize!(workers: 8)
      expect(cfg.h2.max_total_streams).to eq(4096)
    end

    it 'finalize! resolves :unbounded → nil (operator opt-out)' do
      cfg = Hyperion::Config.new
      cfg.h2.max_total_streams = Hyperion::Config::H2Settings::UNBOUNDED
      cfg.finalize!(workers: 4)
      expect(cfg.h2.max_total_streams).to be_nil
    end

    it 'finalize! is idempotent (re-finalizing a finalized config does nothing)' do
      cfg = Hyperion::Config.new
      cfg.finalize!(workers: 2)
      first_value = cfg.h2.max_total_streams
      cfg.finalize!(workers: 999)
      expect(cfg.h2.max_total_streams).to eq(first_value)
    end

    it 'reflects a custom max_concurrent_streams in the formula' do
      cfg = Hyperion::Config.new
      cfg.h2.max_concurrent_streams = 256
      cfg.finalize!(workers: 2)
      # 256 × 2 × 4 = 2048
      expect(cfg.h2.max_total_streams).to eq(2048)
    end
  end
end
