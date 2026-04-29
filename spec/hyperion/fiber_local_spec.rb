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
    it 'is idempotent under async_io: true' do
      described_class.install!(async_io: true)
      expect(described_class.installed?).to be(true)
      expect { described_class.install!(async_io: true) }.not_to raise_error
      expect(described_class.installed?).to be(true)
    end

    it 'routes thread_variable_set to fiber storage when async_io: true' do
      described_class.install!(async_io: true)

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
      described_class.install!(async_io: true)
      described_class.uninstall!
      expect(described_class.installed?).to be(false)

      # After uninstall, thread_variable_set must work without raising.
      expect { Thread.current.thread_variable_set(:after, 'x') }.not_to raise_error
      expect(Thread.current.thread_variable_get(:after)).to eq('x')
    end
  end

  # Regression coverage for hotfix C1 (1.6.3).
  #
  # 1.4.x switched Hyperion's Logger access buffer + Metrics counters to
  # `Thread#thread_variable_*` because `Thread.current[:k]` is fiber-local
  # in Ruby 3.2+ and was stranding state across the Async scheduler. The
  # FiberLocal shim, introduced for Rails compat, originally re-routed
  # `thread_variable_*` to fiber storage unconditionally — which restaged
  # the exact 1.4.x bug. The fix:
  #
  #   1. With async_io off, install! is a no-op (warns, returns early).
  #      thread_variable_* keeps its TRUE thread-local semantics, so two
  #      threads see independent state — the 1.4.x guarantee.
  #   2. With async_io on, the shim installs but reserves the
  #      `__hyperion_*` symbol prefix for true thread-local storage so
  #      Hyperion's own Logger/Metrics keep aggregating correctly. User
  #      keys route to fiber storage so two fibers on the same thread are
  #      isolated.
  describe '1.4.x compat — async_io gating' do
    describe 'when async_io is off' do
      it 'is a no-op — install! returns without patching' do
        described_class.install!(async_io: false)
        expect(described_class.installed?).to be(false)
      end

      it 'logs a warning explaining why install! was ignored' do
        captured = []
        original = Hyperion.logger
        fake = Object.new
        fake.define_singleton_method(:warn) { |&blk| captured << blk.call }
        # Logger#info is also called by the CLI on success — stub it harmlessly.
        fake.define_singleton_method(:info) { |&_blk| nil }
        Hyperion::Runtime.default.logger = fake
        begin
          described_class.install!(async_io: false)
        ensure
          Hyperion::Runtime.default.logger = original
        end
        expect(captured).not_to be_empty
        expect(captured.first[:message]).to match(/ignored/i)
      end

      it 'preserves true thread-local isolation for thread_variable_set across two threads' do
        described_class.install!(async_io: false)

        ready = Queue.new
        observed_a = nil
        observed_b = nil

        thread_a = Thread.new do
          Thread.current.thread_variable_set(:job_id, 'A')
          ready << :ready
          # Block until thread_b has finished writing so the read happens
          # after both threads have set their own value.
          sleep 0.05
          observed_a = Thread.current.thread_variable_get(:job_id)
        end

        ready.pop
        thread_b = Thread.new do
          Thread.current.thread_variable_set(:job_id, 'B')
          observed_b = Thread.current.thread_variable_get(:job_id)
        end

        thread_a.join
        thread_b.join

        expect(observed_a).to eq('A')
        expect(observed_b).to eq('B')
      end
    end

    describe 'when async_io is on' do
      it 'isolates state between two fibers on the same thread' do
        described_class.install!(async_io: true)

        observed_f1 = nil
        observed_f2 = nil

        # Two fibers on the SAME OS thread with isolated storage. With the
        # shim active each fiber's thread_variable_set lands in
        # Fiber.current.storage, so neither fiber sees the other's value.
        Fiber.new(storage: {}) do
          Thread.current.thread_variable_set(:rails_isolated_state, 'fiber-1')
          observed_f1 = Thread.current.thread_variable_get(:rails_isolated_state)
        end.resume

        Fiber.new(storage: {}) do
          observed_f2 = Thread.current.thread_variable_get(:rails_isolated_state)
        end.resume

        expect(observed_f1).to eq('fiber-1')
        expect(observed_f2).to be_nil
      end

      it 'keeps __hyperion_ keys on TRUE thread-local storage so Logger/Metrics still aggregate across fibers' do
        described_class.install!(async_io: true)

        # Hyperion-internal keys must survive the fiber boundary — Logger
        # access buffer + Metrics counters depend on true thread-local
        # storage. Set on the outer (root) fiber, observe from a child
        # fiber on the same OS thread; both must see the same value.
        Thread.current.thread_variable_set(:__hyperion_test_counter__, 42)

        observed = nil
        Fiber.new(storage: {}) do
          observed = Thread.current.thread_variable_get(:__hyperion_test_counter__)
        end.resume

        expect(observed).to eq(42)
      ensure
        # Clean up via the original (unpatched) path.
        Thread.current.send(:__hyperion_orig_tvar_set, :__hyperion_test_counter__, nil) if described_class.installed?
      end
    end
  end
end
