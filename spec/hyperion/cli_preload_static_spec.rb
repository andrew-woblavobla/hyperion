# frozen_string_literal: true

require 'hyperion/cli'

# 2.10-E — `--preload-static <dir>` (repeatable) and `--no-preload-static`.
#
# Flag values land on the cli_opts hash as `:preload_static` (Array of dir
# strings) and `:auto_preload_static_disabled` (Boolean).  `Config#merge_cli!`
# routes `:preload_static` into `config.preload_static_dirs` (an Array of
# `{path:, immutable:}` hashes) and `:auto_preload_static_disabled` into
# `config.auto_preload_static_disabled`.
#
# This spec exercises the parsing branch directly, no server boot.
RSpec.describe 'Hyperion::CLI --preload-static (2.10-E)' do
  def parse(argv)
    Hyperion::CLI.parse_argv!(argv.dup)
  end

  describe '--preload-static' do
    it 'collects a single dir into an Array' do
      cli_opts, = parse(%w[--preload-static /app/public])
      expect(cli_opts[:preload_static]).to eq(['/app/public'])
    end

    it 'is repeatable — multiple flags accumulate' do
      cli_opts, = parse(%w[--preload-static /a/public --preload-static /b/public])
      expect(cli_opts[:preload_static]).to eq(['/a/public', '/b/public'])
    end

    it 'lands the array on Config via merge_cli! as preload_static_dirs (immutable: true default)' do
      cli_opts, = parse(%w[--preload-static /a --preload-static /b])
      config = Hyperion::Config.new
      config.merge_cli!(cli_opts)

      expect(config.preload_static_dirs).to eq(
        [{ path: '/a', immutable: true }, { path: '/b', immutable: true }]
      )
    end

    it 'merges flag-supplied dirs after config-file dirs (CLI wins by appending)' do
      config = Hyperion::Config.new
      config.preload_static_dirs << { path: '/from-config', immutable: true }

      cli_opts, = parse(%w[--preload-static /from-cli])
      config.merge_cli!(cli_opts)

      paths = config.preload_static_dirs.map { |h| h[:path] }
      expect(paths).to include('/from-config', '/from-cli')
    end
  end

  describe '--no-preload-static' do
    it 'sets auto_preload_static_disabled on cli_opts and Config' do
      cli_opts, = parse(%w[--no-preload-static])
      expect(cli_opts[:auto_preload_static_disabled]).to be(true)

      config = Hyperion::Config.new
      config.merge_cli!(cli_opts)
      expect(config.auto_preload_static_disabled).to be(true)
    end

    it 'is independent of --preload-static (operator can disable Rails auto-detect '\
       'while keeping explicit dirs)' do
      cli_opts, = parse(%w[--no-preload-static --preload-static /explicit])
      expect(cli_opts[:auto_preload_static_disabled]).to be(true)
      expect(cli_opts[:preload_static]).to eq(['/explicit'])
    end
  end
end
