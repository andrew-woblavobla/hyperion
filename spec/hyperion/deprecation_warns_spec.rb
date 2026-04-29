# frozen_string_literal: true

require 'tempfile'
require 'stringio'

RSpec.describe 'RFC §3 1.8.0 deprecation warns' do
  # Baseline specs run with `Deprecations.silence!` set in spec_helper —
  # this file is the one place we turn it back on so we can assert on
  # the warns. Every example resets the dedup table so warns can fire
  # again, and we capture them via a fresh in-memory Logger swapped onto
  # the default Runtime. Restore the silence state on exit so order-
  # randomized runs can't bleed.
  around do |example|
    # Snapshot the legacy override seam (`Hyperion.@metrics` / `@logger`)
    # AND `Runtime.default`'s own ivars so each example starts from the
    # same vantage and any `Hyperion.metrics =` write performed below
    # gets fully unwound — without this, mutations leak into siblings
    # like `runtime_spec` under random ordering.
    original_module_metrics = Hyperion.instance_variable_get(:@metrics)
    original_module_logger  = Hyperion.instance_variable_get(:@logger)
    original_default_metrics = Hyperion::Runtime.default.metrics
    original_default_logger  = Hyperion::Runtime.default.logger

    sink = StringIO.new
    sink_logger = Hyperion::Logger.new(io: sink, format: :json)
    # Clear the legacy module-level override so `Runtime#logger` resolves
    # to our sink instead of whatever a sibling spec wrote into
    # `Hyperion.@logger`. Restored in the ensure below.
    Hyperion.instance_variable_set(:@logger, nil)
    Hyperion::Runtime.default.logger = sink_logger
    Hyperion::Deprecations.reset!
    Hyperion::Deprecations.unsilence!
    @sink = sink
    begin
      example.run
    ensure
      Hyperion::Deprecations.silence!
      Hyperion::Deprecations.reset!
      Hyperion.instance_variable_set(:@metrics, original_module_metrics)
      Hyperion.instance_variable_set(:@logger,  original_module_logger)
      Hyperion::Runtime.default.metrics = original_default_metrics
      Hyperion::Runtime.default.logger  = original_default_logger
    end
  end

  def captured
    @sink.string
  end

  def write_config(contents)
    Tempfile.create(['hyperion', '.rb']) do |f|
      f.write(contents)
      f.flush
      yield f.path
    end
  end

  describe 'flat DSL keys' do
    it 'warns on `h2_max_total_streams`' do
      write_config(<<~RUBY) do |path|
        h2_max_total_streams 4096
      RUBY
        Hyperion::Config.load(path)
      end

      expect(captured).to match(/DEPRECATION/i)
      expect(captured).to match(/h2_max_total_streams/)
      expect(captured).to match(/2\.0/)
    end

    it 'fires the warn at most once per process even with multiple loads' do
      2.times do
        write_config(<<~RUBY) do |path|
          h2_max_concurrent_streams 256
        RUBY
          Hyperion::Config.load(path)
        end
      end

      occurrences = captured.scan(/h2_max_concurrent_streams/).length
      # 1 occurrence in the deprecation warn line; the message is
      # emitted exactly once even though the DSL ran twice.
      expect(occurrences).to eq(1)
    end

    it 'still applies the value after warning (behaviour unchanged)' do
      write_config(<<~RUBY) do |path|
        h2_max_concurrent_streams 64
        admin_token 'sekrit'
        log_format :json
      RUBY
        cfg = Hyperion::Config.load(path)
        expect(cfg.h2.max_concurrent_streams).to eq(64)
        expect(cfg.admin.token).to eq('sekrit')
        expect(cfg.logging.format).to eq(:json)
      end
    end

    it 'covers all 13 flat DSL keys' do
      Hyperion::Config::FLAT_TO_NESTED.each_key do |flat|
        Hyperion::Deprecations.reset!
        @sink.truncate(0)
        @sink.rewind
        write_config(<<~RUBY) do |path|
          #{flat} #{if flat == :admin_token
                      "'x'"
                    else
                      (if flat == :admin_listener_host
                         "'127.0.0.1'"
                       else
                         (if %i[log_level log_format].include?(flat)
                            ':info'
                          else
                            (flat == :log_requests ? 'true' : '1')
                          end)
                       end)
                    end}
        RUBY
          Hyperion::Config.load(path)
        end

        expect(captured).to match(/DEPRECATION/i),
                            "expected DEPRECATION warn for #{flat}, got: #{captured.inspect}"
        expect(captured).to match(Regexp.new(Regexp.escape(flat.to_s))),
                            "expected warn message to mention #{flat}"
      end
    end

    it 'does NOT warn when the operator uses the nested DSL' do
      write_config(<<~RUBY) do |path|
        h2 do |h|
          h.max_concurrent_streams = 256
          h.max_total_streams = 4096
        end
        admin do |a|
          a.token = 'x'
        end
        logging do |l|
          l.level = :info
          l.format = :json
        end
      RUBY
        Hyperion::Config.load(path)
      end

      expect(captured).not_to match(/DEPRECATION/i)
    end

    it 'does NOT warn when CLI-style flat setters are called on Config directly (CLI flag path)' do
      cfg = Hyperion::Config.new
      cfg.merge_cli!(log_level: :info, admin_token: 'x', worker_max_rss_mb: 1024)

      # `Config#log_level=` is the back-end forwarder shared with the DSL,
      # but the warn lives on the DSL surface — `merge_cli!` writing a
      # value from `--log-level` must not deprecation-warn the operator.
      expect(captured).not_to match(/DEPRECATION/i)
      expect(cfg.logging.level).to eq(:info)
      expect(cfg.admin.token).to eq('x')
      expect(cfg.worker_health.max_rss_mb).to eq(1024)
    end
  end

  describe 'Hyperion.metrics= / Hyperion.logger= setters' do
    it 'warns on `Hyperion.metrics =`' do
      Hyperion.metrics = Hyperion::Metrics.new
      expect(captured).to match(/DEPRECATION/i)
      expect(captured).to match(/Hyperion\.metrics/)
      expect(captured).to match(/Runtime/)
    end

    it 'warns on `Hyperion.logger =` (and writes through behaviour preserved)' do
      new_logger = Hyperion::Logger.new(io: StringIO.new)
      Hyperion.logger = new_logger
      expect(captured).to match(/DEPRECATION/i)
      expect(captured).to match(/Hyperion\.logger/)
      # Behaviour: the new logger must reach Runtime.default (legacy contract).
      expect(Hyperion::Runtime.default.logger).to be(new_logger)
    end

    it 'does NOT warn when writing to `Hyperion::Runtime.default.metrics =` directly' do
      Hyperion::Runtime.default.metrics = Hyperion::Metrics.new
      expect(captured).not_to match(/DEPRECATION/i)
    end

    it 'fires `Hyperion.metrics=` warn at most once per process' do
      3.times { Hyperion.metrics = Hyperion::Metrics.new }
      # Captured stream contains exactly one occurrence of the dedup key.
      expect(captured.scan(/Hyperion\.metrics = \.\.\./).length).to eq(1)
    end
  end

  describe 'Deprecations module' do
    it 'is silenced under the suite-default and all warns become no-ops' do
      Hyperion::Deprecations.silence!
      Hyperion::Deprecations.reset!

      Hyperion.metrics = Hyperion::Metrics.new
      expect(captured).not_to match(/DEPRECATION/i)
    ensure
      Hyperion::Deprecations.unsilence!
    end

    it 'has dedup state visible via `warned?`' do
      expect(Hyperion::Deprecations.warned?(:hyperion_metrics_setter)).to be(false)
      Hyperion.metrics = Hyperion::Metrics.new
      expect(Hyperion::Deprecations.warned?(:hyperion_metrics_setter)).to be(true)
    end
  end
end
