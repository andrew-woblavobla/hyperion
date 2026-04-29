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

    it 'leaves @h2_admission nil when unset (default 1.7 behaviour)' do
      server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                    host: '127.0.0.1', port: 0)
      expect(server.instance_variable_get(:@h2_admission)).to be_nil
    end
  end
end
