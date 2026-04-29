# frozen_string_literal: true

RSpec.describe 'runtime: kwarg plumbing (RFC A3)' do
  let(:metrics) { Hyperion::Metrics.new }
  let(:logger)  { Hyperion::Logger.new(io: StringIO.new) }
  let(:runtime) { Hyperion::Runtime.new(metrics: metrics, logger: logger) }

  describe 'Hyperion::Connection' do
    it 'uses the explicit Runtime when given' do
      conn = Hyperion::Connection.new(runtime: runtime)
      expect(conn.instance_variable_get(:@metrics)).to be(metrics)
      expect(conn.instance_variable_get(:@logger)).to be(logger)
      expect(conn.instance_variable_get(:@runtime)).to be(runtime)
    end

    it 'falls back to Hyperion.metrics when no runtime: is given' do
      conn = Hyperion::Connection.new
      expect(conn.instance_variable_get(:@metrics)).to be(Hyperion.metrics)
      expect(conn.instance_variable_get(:@logger)).to be(Hyperion.logger)
    end
  end

  describe 'Hyperion::Server' do
    it 'accepts a runtime: kwarg and exposes it via #runtime' do
      server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                    host: '127.0.0.1', port: 0,
                                    runtime: runtime)
      expect(server.runtime).to be(runtime)
    end

    it 'defaults to Runtime.default when no runtime: is given' do
      server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                    host: '127.0.0.1', port: 0)
      expect(server.runtime).to be(Hyperion::Runtime.default)
    end

    it 'isolates explicitly-set runtime from module-level overrides' do
      original_metrics_ivar = Hyperion.instance_variable_get(:@metrics)
      override = Hyperion::Metrics.new
      Hyperion.instance_variable_set(:@metrics, override)
      begin
        server = Hyperion::Server.new(app: ->(_e) { [200, {}, []] },
                                      host: '127.0.0.1', port: 0,
                                      runtime: runtime)
        # When an explicit runtime is given, the module-level override
        # MUST NOT bleed into Server's metrics path.
        expect(server.send(:runtime_metrics)).to be(metrics)
        expect(server.send(:runtime_metrics)).not_to be(override)
      ensure
        Hyperion.instance_variable_set(:@metrics, original_metrics_ivar)
      end
    end
  end

  describe 'Hyperion::Http2Handler' do
    it 'uses the explicit Runtime when given' do
      handler = Hyperion::Http2Handler.new(app: ->(_e) { [200, {}, []] }, runtime: runtime)
      expect(handler.instance_variable_get(:@metrics)).to be(metrics)
      expect(handler.instance_variable_get(:@logger)).to be(logger)
    end

    it 'falls back to Hyperion module-level when no runtime: is given' do
      handler = Hyperion::Http2Handler.new(app: ->(_e) { [200, {}, []] })
      expect(handler.instance_variable_get(:@metrics)).to be(Hyperion.metrics)
    end
  end
end
