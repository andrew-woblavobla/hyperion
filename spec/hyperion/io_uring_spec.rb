# frozen_string_literal: true

require 'socket'
require 'hyperion/cli'

# 2.3-A — io_uring accept (Linux 5.6+, opt-in).
#
# These specs cover the platform-gated entry points of
# `Hyperion::IOUring`. The Linux-only assertions are gated via
# `if: described_class.supported?` so the suite passes on the dev
# host (Darwin) and on Linux runners alike.
RSpec.describe Hyperion::IOUring do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe '.supported?' do
    it 'returns false on Darwin' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
      expect(described_class.supported?).to be(false)
    end

    it 'returns false when the kernel is older than 5.6' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '5.4.0-foo' })
      expect(described_class.supported?).to be(false)
    end

    it 'caches the probe result across calls' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
      described_class.supported?
      # Second call should not re-stat or re-probe.
      expect(Etc).not_to receive(:uname)
      described_class.supported?
    end
  end

  describe '.kernel_supports_io_uring?' do
    it 'parses kernel release' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '5.6.0-amd64' })
      expect(described_class.kernel_supports_io_uring?).to be(true)
    end

    it 'rejects 5.5 and older' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '5.5.19-foo' })
      expect(described_class.kernel_supports_io_uring?).to be(false)
    end

    it 'accepts 6.x' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '6.8.0-bar' })
      expect(described_class.kernel_supports_io_uring?).to be(true)
    end
  end

  describe '.resolve_policy!' do
    it ':off returns false unconditionally' do
      expect(described_class.resolve_policy!(:off)).to be(false)
    end

    it ':auto returns false on macOS (no kernel support)' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
      expect(described_class.resolve_policy!(:auto)).to be(false)
    end

    it ':on raises a clear UnsupportedError on macOS' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
      expect { described_class.resolve_policy!(:on) }.to raise_error(
        described_class::Unsupported, /io_uring required/
      )
    end

    it 'rejects unknown policy values' do
      expect { described_class.resolve_policy!(:bogus) }.to raise_error(ArgumentError)
    end
  end

  describe 'Server boot integration (cross-platform)' do
    it 'boots cleanly with io_uring: :off' do
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0,
                                    app: ->(_env) { [200, {}, ['ok']] },
                                    io_uring: :off)
      expect { server.listen }.not_to raise_error
      server.stop
    end

    it 'boots cleanly with io_uring: :auto on macOS (falls back silently)' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
      Hyperion::IOUring.reset!
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0,
                                    app: ->(_env) { [200, {}, ['ok']] },
                                    io_uring: :auto)
      expect { server.listen }.not_to raise_error
      server.stop
    end

    it 'raises with io_uring: :on on macOS' do
      allow(Etc).to receive(:uname).and_return({ sysname: 'Darwin', release: '24.0.0' })
      Hyperion::IOUring.reset!
      expect do
        Hyperion::Server.new(host: '127.0.0.1', port: 0,
                             app: ->(_env) { [200, {}, ['ok']] },
                             io_uring: :on)
      end.to raise_error(Hyperion::IOUring::Unsupported, /io_uring not supported|io_uring required/)
    end
  end

  describe 'CLI env-var override' do
    around do |ex|
      original = ENV.fetch('HYPERION_IO_URING', nil)
      ex.run
    ensure
      ENV['HYPERION_IO_URING'] = original
    end

    it 'maps off/on/auto to the policy symbol' do
      cfg = Hyperion::Config.new
      ENV['HYPERION_IO_URING'] = 'on'
      Hyperion::CLI.send(:apply_io_uring_env_override!, cfg)
      expect(cfg.io_uring).to eq(:on)

      ENV['HYPERION_IO_URING'] = 'auto'
      Hyperion::CLI.send(:apply_io_uring_env_override!, cfg)
      expect(cfg.io_uring).to eq(:auto)

      ENV['HYPERION_IO_URING'] = 'off'
      Hyperion::CLI.send(:apply_io_uring_env_override!, cfg)
      expect(cfg.io_uring).to eq(:off)
    end

    it 'ignores unknown values with a warn' do
      cfg = Hyperion::Config.new
      ENV['HYPERION_IO_URING'] = 'bogus'
      cfg.io_uring = :auto
      expect(Hyperion.logger).to receive(:warn)
      Hyperion::CLI.send(:apply_io_uring_env_override!, cfg)
      expect(cfg.io_uring).to eq(:auto)
    end

    it 'is a no-op when the env var is unset' do
      cfg = Hyperion::Config.new
      ENV.delete('HYPERION_IO_URING')
      Hyperion::CLI.send(:apply_io_uring_env_override!, cfg)
      expect(cfg.io_uring).to eq(:off)
    end
  end

  # ---- Linux-only behavioural specs ----
  #
  # Gate via `if: described_class.supported?`. On Darwin (or a Linux
  # runner where the cdylib didn't build) the whole context is skipped
  # — no false failures.
  context 'on Linux 5.6+ with the cdylib loaded', if: described_class.supported? do
    it 'opens and closes a ring without leaking fds' do
      before_count = Dir["/proc/#{Process.pid}/fd/*"].count
      ring = described_class::Ring.new(queue_depth: 64)
      expect(ring).not_to be_closed
      ring.close
      expect(ring).to be_closed
      after_count = Dir["/proc/#{Process.pid}/fd/*"].count
      # A ring opens 2 ring fds + 2 mmap pages worth of bookkeeping;
      # close MUST reclaim them. Allow 0 delta but no growth.
      expect(after_count).to be <= before_count
    end

    it 'accepts via io_uring matches accept_nonblock byte-for-byte' do
      server = ::TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]

      ring = described_class::Ring.new(queue_depth: 16)

      # Spawn a client side in a thread so the accept can fire.
      client_thread = Thread.new do
        sock = ::TCPSocket.new('127.0.0.1', port)
        sock.write('hello-uring')
        sock.close
      end

      client_fd = ring.accept(server.fileno)
      expect(client_fd).to be_a(Integer)
      expect(client_fd).to be > 0

      sock = ::IO.for_fd(client_fd)
      sock.autoclose = true
      data = sock.read
      expect(data).to eq('hello-uring')

      sock.close
      ring.close
      server.close
      client_thread.join
    end

    it 'survives 1000 sequential accepts without leaking fds' do
      server = ::TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      ring = described_class::Ring.new(queue_depth: 64)

      before_count = Dir["/proc/#{Process.pid}/fd/*"].count

      1000.times do
        Thread.new do
          ::TCPSocket.new('127.0.0.1', port).close
        end
        client_fd = ring.accept(server.fileno)
        ::IO.for_fd(client_fd).close
      end

      after_count = Dir["/proc/#{Process.pid}/fd/*"].count
      # Allow a small slack for thread bookkeeping; assert no large leak.
      expect(after_count - before_count).to be < 20

      ring.close
      server.close
    end
  end
end
