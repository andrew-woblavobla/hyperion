# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'hyperion'
require 'hyperion/static_preload'

# 2.10-E — Boot-time static-asset preload.
#
# `Hyperion::StaticPreload` walks one or more directory trees, populates
# the `Hyperion::Http::PageCache` from the files inside, and (by default)
# marks every cached entry immutable so subsequent serves never re-stat.
# The CLI / config DSL surfaces (`--preload-static`, `preload_static`)
# bridge into this module; the Server boot path invokes it once per
# worker before `listen` so the first request lands on a warm cache.
#
# Specs cover:
#   * Walking + caching of regular files (recursive).
#   * The immutable kwarg actually marks entries (observable through
#     PageCache state — a freshly-rewritten file does NOT re-stat).
#   * The summary log line carries dir / files / bytes / ms.
#   * Missing or empty dirs don't blow up boot — they emit a warn and
#     skip.
#   * `Rails.configuration.assets.paths` auto-detection picks up the
#     first N (default 8) paths only when the operator hasn't already
#     configured `preload_static`, and only when auto-detect isn't
#     disabled. Rails is NOT loaded — we stub the constant.
RSpec.describe Hyperion::StaticPreload do
  before { Hyperion::Http::PageCache.clear }
  after  { Hyperion::Http::PageCache.clear }

  # Capture log lines emitted via `Hyperion::Logger#info` without
  # disturbing the global Runtime logger for other specs.
  def with_capturing_logger
    io = StringIO.new
    logger = Hyperion::Logger.new(io: io, level: :info, format: :text)
    yield logger, io
  end

  describe '.run' do
    it 'walks every regular file in the directory and caches it' do
      Dir.mktmpdir('hyperion-sp-walk') do |dir|
        File.binwrite(File.join(dir, 'index.html'), '<h1>i</h1>')
        File.binwrite(File.join(dir, 'app.css'), '.a{}')
        FileUtils.mkdir_p(File.join(dir, 'sub'))
        File.binwrite(File.join(dir, 'sub/app.js'), 'alert(1)')

        with_capturing_logger do |logger, _|
          described_class.run([{ path: dir, immutable: true }], logger: logger)
        end

        expect(Hyperion::Http::PageCache.size).to eq(3)
        expect(Hyperion::Http::PageCache.fetch(File.join(dir, 'index.html'))).to eq(:ok)
        expect(Hyperion::Http::PageCache.fetch(File.join(dir, 'sub/app.js'))).to eq(:ok)
      end
    end

    it 'emits a summary log line per directory (dir, files, bytes, ms)' do
      Dir.mktmpdir('hyperion-sp-log') do |dir|
        File.binwrite(File.join(dir, 'a.html'), 'aaa')
        File.binwrite(File.join(dir, 'b.html'), 'bbbb')

        with_capturing_logger do |logger, io|
          described_class.run([{ path: dir, immutable: true }], logger: logger)
          line = io.string
          expect(line).to include('static preload complete')
          expect(line).to match(/dir=#{Regexp.escape(dir)}/)
          expect(line).to include('files=2')
          expect(line).to include('bytes=7')
          expect(line).to match(/ms=\d/)
        end
      end
    end

    it 'marks entries immutable when immutable: true (no re-stat on later writes)' do
      Dir.mktmpdir('hyperion-sp-immut') do |dir|
        path = File.join(dir, 'asset-abc.svg')
        File.binwrite(path, '<svg/>')
        # Stamp v1 well in the past so a fresh File.utime below produces
        # an mtime that differs at second resolution on coarse-mtime FSes.
        File.utime(Time.now - 60, Time.now - 60, path)

        prev_recheck = Hyperion::Http::PageCache.recheck_seconds
        Hyperion::Http::PageCache.recheck_seconds = 0.0
        begin
          with_capturing_logger do |logger, _|
            described_class.run([{ path: dir, immutable: true }], logger: logger)
          end

          File.binwrite(path, '<svg>v2</svg>')
          File.utime(Time.now, Time.now, path)

          # Immutable entry: fetch returns :ok and the cached body is v1.
          expect(Hyperion::Http::PageCache.fetch(path)).to eq(:ok)
          expect(Hyperion::Http::PageCache.response_bytes(path)).to include('<svg/>')
        ensure
          Hyperion::Http::PageCache.recheck_seconds = prev_recheck
        end
      end
    end

    it 'leaves entries mutable when immutable: false' do
      Dir.mktmpdir('hyperion-sp-mut') do |dir|
        path = File.join(dir, 'live.html')
        File.binwrite(path, 'v1')
        File.utime(Time.now - 60, Time.now - 60, path)

        prev_recheck = Hyperion::Http::PageCache.recheck_seconds
        Hyperion::Http::PageCache.recheck_seconds = 0.0
        begin
          with_capturing_logger do |logger, _|
            described_class.run([{ path: dir, immutable: false }], logger: logger)
          end

          File.binwrite(path, 'v2-newbytes')
          File.utime(Time.now, Time.now, path)

          # Mutable entry: fetch reports :stale, cache rebuilds on next read.
          expect(Hyperion::Http::PageCache.fetch(path)).to eq(:stale)
          expect(Hyperion::Http::PageCache.response_bytes(path)).to include('v2-newbytes')
        ensure
          Hyperion::Http::PageCache.recheck_seconds = prev_recheck
        end
      end
    end

    it 'warns and continues on a missing directory' do
      with_capturing_logger do |logger, io|
        described_class.run([{ path: '/nope/does/not/exist', immutable: true }], logger: logger)
        expect(io.string).to include('static preload skipped')
        expect(io.string).to include('/nope/does/not/exist')
      end
      expect(Hyperion::Http::PageCache.size).to eq(0)
    end

    it 'accumulates across multiple directory entries' do
      Dir.mktmpdir('hyperion-sp-multi-a') do |a|
        Dir.mktmpdir('hyperion-sp-multi-b') do |b|
          File.binwrite(File.join(a, 'one.html'), '1')
          File.binwrite(File.join(b, 'two.css'), '2')

          with_capturing_logger do |logger, io|
            described_class.run(
              [{ path: a, immutable: true }, { path: b, immutable: true }],
              logger: logger
            )
            # Two summary lines, one per dir.
            expect(io.string.scan('static preload complete').size).to eq(2)
          end

          expect(Hyperion::Http::PageCache.size).to eq(2)
        end
      end
    end
  end

  describe '.detect_rails_paths' do
    # Stub a minimal Rails.configuration.assets.paths surface without
    # actually loading the rails gem. The CLI must NOT require Rails;
    # auto-detection has to be defensive.
    let(:rails_double) { Module.new }
    let(:configuration) { Struct.new(:assets).new(Struct.new(:paths).new([])) }

    before do
      cfg = configuration # capture in closure to avoid #configuration recursion
      rails_double.define_singleton_method(:configuration) { cfg }
      stub_const('Rails', rails_double)
    end

    it 'returns the first N detected paths (default cap 8)' do
      paths = (1..12).map { |i| "/app/assets/path_#{i}" }
      configuration.assets.paths = paths

      result = described_class.detect_rails_paths
      expect(result).to be_an(Array)
      expect(result.length).to eq(8)
      expect(result).to eq(paths.first(8))
    end

    it 'honours the cap kwarg' do
      paths = (1..6).map { |i| "/app/assets/path_#{i}" }
      configuration.assets.paths = paths

      expect(described_class.detect_rails_paths(cap: 3)).to eq(paths.first(3))
    end

    it 'returns [] when the assets path list is empty' do
      configuration.assets.paths = []
      expect(described_class.detect_rails_paths).to eq([])
    end

    it 'returns [] when Rails is undefined' do
      hide_const('Rails')
      expect(described_class.detect_rails_paths).to eq([])
    end

    it 'returns [] when Rails.configuration.assets.paths is non-Array' do
      configuration.assets.paths = 'not-an-array'
      expect(described_class.detect_rails_paths).to eq([])
    end
  end
end
