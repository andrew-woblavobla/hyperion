# frozen_string_literal: true

require 'stringio'
require 'hyperion/cli'

# 2.2.x fix-D: --h2-max-total-streams CLI flag + HYPERION_H2_MAX_TOTAL_STREAMS
# env-var. Both bridge the existing 1.7.0 DSL knob (`h2.max_total_streams`)
# without forcing operators to write a config file just to lift the 2.0.0
# default cap (`max_concurrent_streams × workers × 4` = 512 streams at -w 1).
#
# This spec exercises the parsing branch directly (no server boot) plus the
# env-var override end-to-end via `apply_h2_max_total_streams_env_override!`.
RSpec.describe 'Hyperion::CLI --h2-max-total-streams (fix-D)' do
  def parse(argv)
    # parse_argv! mutates argv in place; dup so the spec's argv stays intact.
    Hyperion::CLI.parse_argv!(argv.dup)
  end

  describe '--h2-max-total-streams CLI flag' do
    it 'parses an integer literal and lands it on Config via merge_cli!' do
      cli_opts, = parse(%w[--h2-max-total-streams 2048])
      expect(cli_opts[:h2_max_total_streams]).to eq(2048)

      config = Hyperion::Config.new
      config.merge_cli!(cli_opts)
      expect(config.h2.max_total_streams).to eq(2048)
    end

    it 'parses `unbounded` to the H2Settings::UNBOUNDED sentinel' do
      cli_opts, = parse(%w[--h2-max-total-streams unbounded])
      expect(cli_opts[:h2_max_total_streams]).to eq(Hyperion::Config::H2Settings::UNBOUNDED)

      config = Hyperion::Config.new
      config.merge_cli!(cli_opts)
      # Before finalize! the sentinel is preserved on the config.
      expect(config.h2.max_total_streams).to eq(Hyperion::Config::H2Settings::UNBOUNDED)

      # finalize! resolves :unbounded → nil (no cap), matching pre-2.0 behaviour.
      config.finalize!(workers: 1)
      expect(config.h2.max_total_streams).to be_nil
    end

    it 'accepts `:unbounded` (with the leading colon) as an alias' do
      cli_opts, = parse(['--h2-max-total-streams', ':unbounded'])
      expect(cli_opts[:h2_max_total_streams]).to eq(Hyperion::Config::H2Settings::UNBOUNDED)
    end

    it 'raises OptionParser::InvalidArgument on a non-integer non-`unbounded` value' do
      expect { parse(%w[--h2-max-total-streams notanumber]) }
        .to raise_error(OptionParser::InvalidArgument, /h2-max-total-streams/)
    end

    it 'raises on a non-positive integer (zero / negative)' do
      expect { parse(%w[--h2-max-total-streams 0]) }
        .to raise_error(OptionParser::InvalidArgument, /h2-max-total-streams/)
      # Negative values trip the regex (no `\A-?\d+\z`) — they fall into the
      # "not an integer" branch, which is the same error class.
      expect { parse(%w[--h2-max-total-streams -10]) }
        .to raise_error(OptionParser::InvalidArgument)
    end
  end

  describe 'HYPERION_H2_MAX_TOTAL_STREAMS env-var → config.h2.max_total_streams' do
    let(:io) { StringIO.new }
    let(:logger) { Hyperion::Logger.new(io: io, level: :warn, format: :text) }
    let(:config) { Hyperion::Config.new }

    before do
      @prev_env = ENV['HYPERION_H2_MAX_TOTAL_STREAMS']
      @prev_logger = Hyperion::Runtime.default.logger
      Hyperion::Runtime.default.logger = logger
    end

    after do
      ENV['HYPERION_H2_MAX_TOTAL_STREAMS'] = @prev_env # nil-safe restore
      Hyperion::Runtime.default.logger = @prev_logger
    end

    def call!
      Hyperion::CLI.send(:apply_h2_max_total_streams_env_override!, config)
    end

    it 'leaves config.h2.max_total_streams untouched when env is unset (default :auto)' do
      ENV.delete('HYPERION_H2_MAX_TOTAL_STREAMS')
      call!
      # Default sentinel — finalize! later resolves it to the integer cap.
      expect(config.h2.max_total_streams).to eq(Hyperion::Config::H2Settings::AUTO)
    end

    it 'maps HYPERION_H2_MAX_TOTAL_STREAMS=10000 to the integer cap' do
      ENV['HYPERION_H2_MAX_TOTAL_STREAMS'] = '10000'
      call!
      expect(config.h2.max_total_streams).to eq(10_000)
    end

    it 'maps HYPERION_H2_MAX_TOTAL_STREAMS=unbounded to the UNBOUNDED sentinel (→ nil after finalize)' do
      ENV['HYPERION_H2_MAX_TOTAL_STREAMS'] = 'unbounded'
      call!
      expect(config.h2.max_total_streams).to eq(Hyperion::Config::H2Settings::UNBOUNDED)
      config.finalize!(workers: 1)
      expect(config.h2.max_total_streams).to be_nil
    end

    it 'is a no-op when the env var is the empty string' do
      ENV['HYPERION_H2_MAX_TOTAL_STREAMS'] = ''
      call!
      expect(config.h2.max_total_streams).to eq(Hyperion::Config::H2Settings::AUTO)
    end

    it 'warns and leaves the value untouched on an unknown setting' do
      ENV['HYPERION_H2_MAX_TOTAL_STREAMS'] = 'notanumber'
      config.h2.max_total_streams = 4096 # prove env-var typo doesn't clobber an explicit setting
      call!
      expect(config.h2.max_total_streams).to eq(4096)
      expect(io.string).to include('HYPERION_H2_MAX_TOTAL_STREAMS ignored')
    end

    it 'env-var overrides a prior CLI flag value (env var is the outer knob)' do
      # Simulate the run order: merge_cli! writes from the flag, then env
      # override runs and overwrites with the operator's bench setting.
      cli_opts, = Hyperion::CLI.parse_argv!(%w[--h2-max-total-streams 2048])
      config.merge_cli!(cli_opts)
      expect(config.h2.max_total_streams).to eq(2048)

      ENV['HYPERION_H2_MAX_TOTAL_STREAMS'] = 'unbounded'
      call!
      expect(config.h2.max_total_streams).to eq(Hyperion::Config::H2Settings::UNBOUNDED)
    end
  end
end
