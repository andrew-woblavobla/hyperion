# frozen_string_literal: true

require 'tempfile'

RSpec.describe 'Config nested DSL (RFC A4)' do
  # 1.8.0: flat DSL emits deprecation warns. Silence them in this file so
  # the existing nested/flat-parity assertions don't drown in stderr noise;
  # the dedicated `deprecation_warns_spec` exercises the warn behaviour.
  before { Hyperion::Deprecations.silence! }
  after { Hyperion::Deprecations.unsilence! }

  def write_config(contents)
    Tempfile.create(['hyperion', '.rb']) do |f|
      f.write(contents)
      f.flush
      yield f.path
    end
  end

  describe 'h2 block (no-arg form)' do
    it 'sets nested fields via bareword setters' do
      write_config(<<~RUBY) do |path|
        h2 do
          max_concurrent_streams 256
          initial_window_size 2_097_152
          max_total_streams 4_096
        end
      RUBY
        cfg = Hyperion::Config.load(path)
        expect(cfg.h2.max_concurrent_streams).to eq(256)
        expect(cfg.h2.initial_window_size).to eq(2_097_152)
        expect(cfg.h2.max_total_streams).to eq(4_096)
      end
    end
  end

  describe 'h2 block (explicit-arg form)' do
    it 'yields a proxy that responds to setters' do
      write_config(<<~RUBY) do |path|
        h2 do |h|
          h.max_concurrent_streams 64
          h.max_frame_size 32_768
        end
      RUBY
        cfg = Hyperion::Config.load(path)
        expect(cfg.h2.max_concurrent_streams).to eq(64)
        expect(cfg.h2.max_frame_size).to eq(32_768)
      end
    end
  end

  describe 'admin / worker_health / logging blocks' do
    it 'wires all three subconfigs' do
      write_config(<<~RUBY) do |path|
        admin do
          token 'sekrit'
          listener_port 9293
          listener_host '0.0.0.0'
        end
        worker_health do
          max_rss_mb 1024
          check_interval 60
        end
        logging do
          level :debug
          format :json
          requests false
        end
      RUBY
        cfg = Hyperion::Config.load(path)
        expect(cfg.admin.token).to eq('sekrit')
        expect(cfg.admin.listener_port).to eq(9293)
        expect(cfg.admin.listener_host).to eq('0.0.0.0')
        expect(cfg.worker_health.max_rss_mb).to eq(1024)
        expect(cfg.worker_health.check_interval).to eq(60)
        expect(cfg.logging.level).to eq(:debug)
        expect(cfg.logging.format).to eq(:json)
        expect(cfg.logging.requests).to be(false)
      end
    end
  end

  describe 'flat-form DSL is removed in 2.0' do
    it 'flat keys raise NoMethodError from the DSL evaluator' do
      write_config(<<~RUBY) do |path|
        h2_max_concurrent_streams 256
      RUBY
        expect { Hyperion::Config.load(path) }
          .to raise_error(NoMethodError, /h2_max_concurrent_streams/)
      end
    end

    it 'flat-keyed Config setters no longer exist on the instance' do
      cfg = Hyperion::Config.new
      expect(cfg).not_to respond_to(:h2_max_concurrent_streams)
      expect(cfg).not_to respond_to(:h2_max_concurrent_streams=)
      expect(cfg).not_to respond_to(:admin_token)
      expect(cfg).not_to respond_to(:log_format=)
    end
  end

  describe 'Master.build_h2_settings' do
    it 'reads from the nested H2Settings object' do
      cfg = Hyperion::Config.new
      cfg.h2.max_concurrent_streams = 64
      cfg.h2.initial_window_size = 524_288
      h = Hyperion::Master.build_h2_settings(cfg)
      expect(h[:max_concurrent_streams]).to eq(64)
      expect(h[:initial_window_size]).to eq(524_288)
    end
  end

  describe 'BlockProxy' do
    it 'forwards settable attributes' do
      target = Hyperion::Config::H2Settings.new
      proxy = Hyperion::Config::BlockProxy.new(target)
      proxy.max_concurrent_streams 42
      expect(target.max_concurrent_streams).to eq(42)
    end

    it 'reads attributes back via bareword' do
      target = Hyperion::Config::H2Settings.new
      target.max_concurrent_streams = 99
      proxy = Hyperion::Config::BlockProxy.new(target)
      expect(proxy.max_concurrent_streams).to eq(99)
    end

    it 'raises NoMethodError on unknown attributes (typos surface immediately)' do
      target = Hyperion::Config::H2Settings.new
      proxy = Hyperion::Config::BlockProxy.new(target)
      expect { proxy.bogus_key 1 }.to raise_error(NoMethodError)
    end
  end
end
