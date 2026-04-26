# frozen_string_literal: true

RSpec.describe Hyperion::FiberLocal do
  before { described_class.uninstall! if described_class.installed? }
  after  { described_class.uninstall! if described_class.installed? }

  describe '.verify_environment!' do
    it 'returns true on Ruby 3.2+ where Thread.current[:k] is fiber-local' do
      expect(described_class.verify_environment!).to be(true)
    end

    it 'leaves no marker behind' do
      described_class.verify_environment!
      expect(Thread.current[:__hyperion_fiber_isolation_check__]).to be_nil
    end
  end

  # Ruby 3.2+ already isolates Thread.current[:k] per fiber. This spec pins
  # that contract — if it ever fails, Hyperion's safety guarantee is broken.
  describe 'Ruby 3.2+ baseline' do
    it 'isolates Thread.current[:symbol] across fibers without Hyperion needing to patch anything' do
      Thread.current[:base_marker] = 'main'

      observed_in_fiber = nil
      Fiber.new { observed_in_fiber = Thread.current[:base_marker] }.resume

      # Child fiber sees nil — Ruby keeps Thread.current[:k] fiber-local.
      expect(observed_in_fiber).to be_nil
      # Main fiber's value is untouched.
      expect(Thread.current[:base_marker]).to eq('main')
    ensure
      Thread.current[:base_marker] = nil
    end
  end

  describe '.install!' do
    it 'is idempotent' do
      described_class.install!
      expect(described_class.installed?).to be(true)
      expect { described_class.install! }.not_to raise_error
      expect(described_class.installed?).to be(true)
    end

    it 'routes thread_variable_set to fiber storage' do
      described_class.install!

      Thread.current.thread_variable_set(:patched, 'request-A')

      observed = nil
      Fiber.new(storage: {}) do
        observed = Thread.current.thread_variable_get(:patched)
      end.resume

      # Without the patch, the fiber would see 'request-A' (genuinely thread-shared).
      # With the patch, thread variables route to Fiber.current.storage and are isolated.
      expect(observed).to be_nil
    end
  end

  describe '.uninstall!' do
    it 'restores the original thread_variable_get/set' do
      described_class.install!
      described_class.uninstall!
      expect(described_class.installed?).to be(false)

      # After uninstall, thread_variable_set must work without raising.
      expect { Thread.current.thread_variable_set(:after, 'x') }.not_to raise_error
      expect(Thread.current.thread_variable_get(:after)).to eq('x')
    end
  end
end
