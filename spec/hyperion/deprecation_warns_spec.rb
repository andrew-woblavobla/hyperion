# frozen_string_literal: true

require 'tempfile'
require 'stringio'

# 2.0.0: the 1.8.0 deprecation surface (`h2_max_concurrent_streams`,
# `Hyperion.metrics =`, etc.) is removed entirely. This file no longer
# asserts deprecation warns — it asserts the APIs are GONE. The flat
# DSL keys raise `NoMethodError` from the DSL evaluator (unknown
# methods bubble up), and the module-level setters no longer exist.
RSpec.describe 'RFC §3 2.0.0 removed APIs' do
  describe 'flat DSL keys' do
    def write_config(contents)
      Tempfile.create(['hyperion', '.rb']) do |f|
        f.write(contents)
        f.flush
        yield f.path
      end
    end

    it 'raises when a config file uses the removed `h2_max_total_streams` flat key' do
      write_config("h2_max_total_streams 4096\n") do |path|
        expect { Hyperion::Config.load(path) }.to raise_error(NoMethodError, /h2_max_total_streams/)
      end
    end

    it 'raises when a config file uses the removed `admin_token` flat key' do
      write_config("admin_token 'sekrit'\n") do |path|
        expect { Hyperion::Config.load(path) }.to raise_error(NoMethodError, /admin_token/)
      end
    end

    it 'raises when a config file uses the removed `log_format` flat key' do
      write_config("log_format :json\n") do |path|
        expect { Hyperion::Config.load(path) }.to raise_error(NoMethodError, /log_format/)
      end
    end

    it 'still accepts the nested DSL form for the same setting' do
      write_config(<<~RUBY) do |path|
        h2 do
          max_concurrent_streams 64
          max_total_streams 4096
        end
        admin do
          token 'sekrit'
        end
        logging do
          level :info
          format :json
        end
      RUBY
        cfg = Hyperion::Config.load(path)
        expect(cfg.h2.max_concurrent_streams).to eq(64)
        expect(cfg.h2.max_total_streams).to eq(4096)
        expect(cfg.admin.token).to eq('sekrit')
        expect(cfg.logging.level).to eq(:info)
        expect(cfg.logging.format).to eq(:json)
      end
    end

    it 'no longer exposes the FLAT_TO_NESTED forwarder constant' do
      expect(Hyperion::Config.const_defined?(:FLAT_TO_NESTED)).to be(false)
    end

    it 'no longer defines `Config#h2_max_concurrent_streams` etc as instance methods' do
      cfg = Hyperion::Config.new
      %i[h2_max_concurrent_streams h2_max_total_streams admin_token log_format
         log_level log_requests worker_max_rss_mb worker_check_interval].each do |flat|
        expect(cfg).not_to respond_to(flat),
                           "expected Config##{flat} to be removed in 2.0"
      end
    end
  end

  describe 'Hyperion.metrics= / Hyperion.logger= setters' do
    it 'no longer responds to `Hyperion.metrics=`' do
      expect(Hyperion).not_to respond_to(:metrics=)
    end

    it 'no longer responds to `Hyperion.logger=`' do
      expect(Hyperion).not_to respond_to(:logger=)
    end

    it 'still exposes the getters as Runtime.default delegators (REPL convenience)' do
      expect(Hyperion.metrics).to be(Hyperion::Runtime.default.metrics)
      expect(Hyperion.logger).to be(Hyperion::Runtime.default.logger)
    end

    it 'mutating Runtime.default propagates to the module-level getter' do
      prev = Hyperion::Runtime.default.metrics
      new_metrics = Hyperion::Metrics.new
      Hyperion::Runtime.default.metrics = new_metrics
      expect(Hyperion.metrics).to be(new_metrics)
    ensure
      Hyperion::Runtime.default.metrics = prev
    end
  end
end
