# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Hyperion::WorkerHealth do
  describe '.rss_mb' do
    it 'returns a positive Integer for the current process' do
      rss = described_class.rss_mb(Process.pid)
      expect(rss).to be_a(Integer)
      expect(rss).to be > 0
      # Sanity bound — even the noisiest Ruby suite shouldn't be using
      # 100 GiB of RSS. If it is, something is very wrong.
      expect(rss).to be < 100_000
    end

    it 'returns nil for a non-existent PID' do
      # macOS `ps -o rss= -p <pid>` exits non-zero with empty stdout for
      # unknown PIDs, which trips the `kib.zero?` branch and returns nil.
      # Linux /proc lookup falls back to the same code path because
      # /proc/99999999/statm doesn't exist (File.readable? → false → ps).
      expect(described_class.rss_mb(99_999_999)).to be_nil
    end

    it 'reads /proc/<pid>/statm without shelling out when /proc is available' do
      pid = 4242
      allow(File).to receive(:readable?).with("/proc/#{pid}/statm").and_return(true)
      allow(File).to receive(:read).with("/proc/#{pid}/statm").and_return("12345 8192 1024 0 0 0 0\n")

      # Guard: assert no `ps` subprocess is launched. We stub Kernel#`
      # on the receiver used by WorkerHealth — module_function methods
      # use `self`'s backtick, which here is the module itself.
      expect(described_class).not_to receive(:`) # rubocop:disable RSpec/MessageSpies

      rss = described_class.rss_mb(pid)
      # 8192 pages * 4096 bytes / (1024 * 1024) = 32 MiB.
      expect(rss).to eq(32)
    end

    it 'returns nil if reading /proc raises' do
      pid = 4243
      allow(File).to receive(:readable?).with("/proc/#{pid}/statm").and_return(true)
      allow(File).to receive(:read).with("/proc/#{pid}/statm").and_raise(Errno::ENOENT)

      expect(described_class.rss_mb(pid)).to be_nil
    end
  end
end
