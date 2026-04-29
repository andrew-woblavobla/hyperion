# frozen_string_literal: true

RSpec.describe 'async_io strict validation (RFC A9)' do
  describe 'Server constructor' do
    it 'accepts nil / true / false' do
      [nil, true, false].each do |v|
        expect do
          Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                               host: '127.0.0.1', port: 0, async_io: v)
        end.not_to raise_error
      end
    end

    it 'raises ArgumentError on string "true"' do
      expect do
        Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                             host: '127.0.0.1', port: 0, async_io: 'true')
      end.to raise_error(ArgumentError, /async_io must be nil, true, or false/)
    end

    it 'raises on integer 1' do
      expect do
        Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                             host: '127.0.0.1', port: 0, async_io: 1)
      end.to raise_error(ArgumentError, /async_io must be nil, true, or false/)
    end

    it 'raises on symbol :yes' do
      expect do
        Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                             host: '127.0.0.1', port: 0, async_io: :yes)
      end.to raise_error(ArgumentError, /async_io must be nil, true, or false/)
    end
  end

  describe 'Hyperion.validate_async_io_loaded_libs!' do
    it 'is a no-op for nil (default — soft warn handled elsewhere)' do
      expect { Hyperion.validate_async_io_loaded_libs!(nil) }.not_to raise_error
    end

    it 'raises for true when no fiber-IO library is loaded' do
      stub_const('Hyperion::FIBER_IO_PROBES', {
                   'hyperion-async-pg' => -> { false },
                   'async-redis' => -> { false }
                 })
      expect { Hyperion.validate_async_io_loaded_libs!(true) }
        .to raise_error(ArgumentError, %r{requires a fiber-cooperative I/O library})
    end

    it 'passes for true when at least one fiber-IO library is loaded' do
      stub_const('Hyperion::FIBER_IO_PROBES', {
                   'hyperion-async-pg' => -> { true },
                   'async-redis' => -> { false }
                 })
      expect { Hyperion.validate_async_io_loaded_libs!(true) }.not_to raise_error
    end

    it 'warns (does not raise) for false when a fiber-IO library is loaded' do
      stub_const('Hyperion::FIBER_IO_PROBES', {
                   'hyperion-async-pg' => -> { true }
                 })
      logger = instance_double(Hyperion::Logger)
      allow(logger).to receive(:warn)
      allow(Hyperion).to receive(:logger).and_return(logger)
      expect { Hyperion.validate_async_io_loaded_libs!(false) }.not_to raise_error
      expect(logger).to have_received(:warn).at_least(:once)
    end

    it 'is silent for false when no fiber-IO library is loaded' do
      stub_const('Hyperion::FIBER_IO_PROBES', { 'async-redis' => -> { false } })
      expect { Hyperion.validate_async_io_loaded_libs!(false) }.not_to raise_error
    end
  end

  describe 'Config setter' do
    it 'accepts the tri-state values via the DSL' do
      cfg = Hyperion::Config.new
      [nil, true, false].each do |v|
        expect { cfg.async_io = v }.not_to raise_error
      end
    end
  end
end
