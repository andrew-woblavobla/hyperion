# frozen_string_literal: true

require 'tempfile'
require 'hyperion'

# 2.10-E — `preload_static "/path"` DSL key + Rails auto-detect.
#
# DSL form:
#
#   preload_static "/srv/app/public"               # immutable: true (default)
#   preload_static "/srv/app/public/uploads", immutable: false
#
# Multiple calls accumulate into `Config#preload_static_dirs`.  When the
# operator hasn't called `preload_static` and `--no-preload-static` wasn't
# passed, `Config#resolved_preload_static_dirs` walks Rails' assets paths
# (via `Hyperion::StaticPreload.detect_rails_paths`) and synthesises an
# entry per detected path.  Operator-supplied dirs always win — auto-detect
# is OFF the moment they call `preload_static` even once.
RSpec.describe Hyperion::Config do
  describe '#preload_static_dirs (DSL key)' do
    it 'defaults to an empty array' do
      cfg = described_class.new
      expect(cfg.preload_static_dirs).to eq([])
    end

    it 'accumulates via the DSL with default immutable: true' do
      file = Tempfile.new(['hyperion-preload', '.rb'])
      file.write(<<~RUBY)
        preload_static '/srv/app/public'
        preload_static '/srv/app/public/uploads', immutable: false
      RUBY
      file.close

      cfg = described_class.load(file.path)
      expect(cfg.preload_static_dirs).to eq(
        [{ path: '/srv/app/public', immutable: true },
         { path: '/srv/app/public/uploads', immutable: false }]
      )
    ensure
      file.unlink
    end

    it 'auto_preload_static_disabled defaults to false' do
      expect(described_class.new.auto_preload_static_disabled).to be(false)
    end
  end

  describe '#resolved_preload_static_dirs' do
    let(:cfg) { described_class.new }

    it 'returns the operator-supplied list verbatim when set' do
      cfg.preload_static_dirs << { path: '/explicit', immutable: true }
      expect(cfg.resolved_preload_static_dirs).to eq(
        [{ path: '/explicit', immutable: true }]
      )
    end

    it 'falls through to Rails auto-detect when no dirs are configured' do
      allow(Hyperion::StaticPreload).to receive(:detect_rails_paths)
        .and_return(['/app/assets/builds', '/app/javascript/packs'])

      expect(cfg.resolved_preload_static_dirs).to eq(
        [{ path: '/app/assets/builds', immutable: true },
         { path: '/app/javascript/packs', immutable: true }]
      )
    end

    it 'skips Rails auto-detect when auto_preload_static_disabled is true' do
      cfg.auto_preload_static_disabled = true
      expect(Hyperion::StaticPreload).not_to receive(:detect_rails_paths)
      expect(cfg.resolved_preload_static_dirs).to eq([])
    end

    it 'when operator supplied dirs, auto-detect is NOT consulted' do
      cfg.preload_static_dirs << { path: '/explicit', immutable: true }
      expect(Hyperion::StaticPreload).not_to receive(:detect_rails_paths)
      expect(cfg.resolved_preload_static_dirs).to eq(
        [{ path: '/explicit', immutable: true }]
      )
    end
  end
end
