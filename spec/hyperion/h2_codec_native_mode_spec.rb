# frozen_string_literal: true

# 2.11-B — `HYPERION_H2_NATIVE_HPACK` native-mode axis.
#
# Pre-2.11-B the env var was a Boolean (truthy → native, off → ruby).
# Since the 2.5-B default flip operators couldn't *force* the v2 (Fiddle)
# path on a host where CGlue happened to be available — `=1` would
# silently pick v3. That made the 2.11-B Fiddle-marshalling round-2
# bench impossible to run honestly: the "native" variant the bench
# wanted to compare against `cglue` was always the same physical path.
#
# 2.11-B extends the env var with explicit native-mode tokens:
#
#   * unset / `1` / `true` / `yes` / `on` / `auto` → native, prefer cglue
#     (current default — unchanged for ops upgrading from 2.5..2.10)
#   * `cglue` / `v3`                              → native, force cglue
#                                                   (warn-fallback to v2
#                                                   if cglue unavailable)
#   * `v2` / `fiddle`                             → native, force Fiddle
#                                                   (skip cglue even if
#                                                   available — this is
#                                                   the bench-isolation
#                                                   knob round-2 needs)
#   * `0` / `false` / `no` / `off` / `ruby`       → ruby fallback
#
# The boot log's `hpack_path` field continues to be one of
# `pure-ruby` / `native-v2` / `native-v3`. A new `native_mode`
# field surfaces the operator-requested mode separately so a
# diagnostic ("you set =cglue but cglue isn't available") is still
# visible in the boot log.
RSpec.describe 'Http2Handler — HYPERION_H2_NATIVE_HPACK native-mode axis (2.11-B)' do
  let(:app) { ->(_env) { [200, {}, ['']] } }

  def boot_handler_and_capture_log(env_value)
    Hyperion::Http2Handler.instance_variable_set(:@codec_state_logged, nil)
    sink = StringIO.new
    runtime = Hyperion::Runtime.new(logger: Hyperion::Logger.new(io: sink, format: :json))

    original = ENV.fetch('HYPERION_H2_NATIVE_HPACK', nil)
    if env_value.nil?
      ENV.delete('HYPERION_H2_NATIVE_HPACK')
    else
      ENV['HYPERION_H2_NATIVE_HPACK'] = env_value
    end
    Hyperion::Http2Handler.new(app: app, runtime: runtime)
    sink.string
  ensure
    if original.nil?
      ENV.delete('HYPERION_H2_NATIVE_HPACK')
    else
      ENV['HYPERION_H2_NATIVE_HPACK'] = original
    end
    Hyperion::Http2Handler.instance_variable_set(:@codec_state_logged, nil)
  end

  def parse_codec_log(log_text)
    line = log_text.lines.find { |l| l.include?('"h2 codec selected"') }
    raise "no codec-selected log line in:\n#{log_text}" unless line

    JSON.parse(line)
  end

  context 'when H2Codec is unavailable (no Rust crate)' do
    before do
      Hyperion::H2Codec.reset!
      allow(Hyperion::H2Codec).to receive(:available?).and_return(false)
    end

    after { Hyperion::H2Codec.reset! }

    it 'logs hpack_path=pure-ruby regardless of the env var (native unavailable wins)' do
      log = boot_handler_and_capture_log(nil)
      entry = parse_codec_log(log)
      expect(entry['hpack_path']).to eq('pure-ruby')
      expect(entry['native_available']).to be(false)
      expect(entry['native_enabled']).to be(false)
    end

    it 'forces ruby fallback when HYPERION_H2_NATIVE_HPACK=cglue but the crate is missing' do
      log = boot_handler_and_capture_log('cglue')
      entry = parse_codec_log(log)
      expect(entry['hpack_path']).to eq('pure-ruby')
    end
  end

  describe 'H2Codec.candidate_paths host-os ordering (2.11-B portability fix)' do
    # Regression: pre-2.11-B `candidate_paths` returned `[dylib, so]`
    # in a fixed order. On a Linux bench host that had a stale macOS
    # `.dylib` sitting in `target/release/` (typical of rsync-based
    # cross-platform dev workflows), Fiddle.dlopen would pick up the
    # Mach-O binary first and raise
    # `ArgumentError: invalid byte sequence in UTF-8` from libffi.
    # The `load!` rescue would silently fall back to the pure-Ruby
    # HPACK path with no operator-visible signal beyond a one-line
    # warning that bench harnesses don't grep for. The 2.11-B bench
    # rig hit exactly this on the openclaw-vm bench host.
    it 'orders .so before .dylib on Linux hosts' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      paths = Hyperion::H2Codec.candidate_paths
      first_so    = paths.index { |p| p.end_with?('.so') }
      first_dylib = paths.index { |p| p.end_with?('.dylib') }
      expect(first_so).not_to be_nil
      expect(first_so).to be < first_dylib
    end

    it 'orders .dylib before .so on macOS hosts' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'darwin23'))
      paths = Hyperion::H2Codec.candidate_paths
      first_so    = paths.index { |p| p.end_with?('.so') }
      first_dylib = paths.index { |p| p.end_with?('.dylib') }
      expect(first_dylib).not_to be_nil
      expect(first_dylib).to be < first_so
    end

    it 'returns the same total count of candidates on every host (no platform-conditional drop)' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'darwin23'))
      mac_count = Hyperion::H2Codec.candidate_paths.length
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      linux_count = Hyperion::H2Codec.candidate_paths.length
      expect(mac_count).to eq(linux_count)
      expect(mac_count).to be >= 4 # both gem_lib and ext_target × both suffixes
    end
  end

  context 'when H2Codec is available (real cdylib loaded)', if: Hyperion::H2Codec.available? do
    after do
      # Restore any test-time override on the cglue gate.
      Hyperion::H2Codec.instance_variable_set(:@cglue_disabled, false)
    end

    describe 'unset env var (default since 2.5-B, cglue confirmed default since 2.11-B)' do
      it 'reports hpack_path=native-v3 when cglue is available, native-v2 otherwise' do
        log = boot_handler_and_capture_log(nil)
        entry = parse_codec_log(log)
        expected = Hyperion::H2Codec.cglue_available? ? 'native-v3' : 'native-v2'
        expect(entry['hpack_path']).to eq(expected)
        expect(entry['native_enabled']).to be(true)
        expect(entry['native_mode']).to eq('auto')
      end

      it 'mode string advertises cglue as the default since 2.11-B (confirmed by bench)',
         if: Hyperion::H2Codec.cglue_available? do
        log = boot_handler_and_capture_log(nil)
        entry = parse_codec_log(log)
        expect(entry['mode']).to include('default since 2.11-B')
      end
    end

    describe 'HYPERION_H2_NATIVE_HPACK=1 (legacy opt-in alias)' do
      it 'is treated identically to unset (auto — prefer cglue if available)' do
        log = boot_handler_and_capture_log('1')
        entry = parse_codec_log(log)
        expected = Hyperion::H2Codec.cglue_available? ? 'native-v3' : 'native-v2'
        expect(entry['hpack_path']).to eq(expected)
        expect(entry['native_mode']).to eq('auto')
      end
    end

    describe 'HYPERION_H2_NATIVE_HPACK=cglue (force v3)' do
      it 'logs hpack_path=native-v3 when cglue is available', if: Hyperion::H2Codec.cglue_available? do
        log = boot_handler_and_capture_log('cglue')
        entry = parse_codec_log(log)
        expect(entry['hpack_path']).to eq('native-v3')
        expect(entry['cglue_active']).to be(true)
        expect(entry['native_mode']).to eq('cglue')
      end

      it 'falls back to native-v2 with a clear native_mode marker when cglue unavailable' do
        Hyperion::H2Codec.instance_variable_set(:@cglue_available, false)
        log = boot_handler_and_capture_log('cglue')
        entry = parse_codec_log(log)
        expect(entry['hpack_path']).to eq('native-v2')
        expect(entry['cglue_active']).to be(false)
        expect(entry['native_mode']).to eq('cglue-requested-unavailable')
      ensure
        Hyperion::H2Codec.reset!
        Hyperion::H2Codec.available? # rewarm memo against real filesystem
      end
    end

    describe 'HYPERION_H2_NATIVE_HPACK=v2 / =fiddle (force v2 / Fiddle)' do
      %w[v2 fiddle V2 FIDDLE].each do |val|
        it "logs hpack_path=native-v2 (cglue suppressed by force) for env=#{val.inspect}" do
          log = boot_handler_and_capture_log(val)
          entry = parse_codec_log(log)
          expect(entry['hpack_path']).to eq('native-v2')
          expect(entry['cglue_active']).to be(false)
          expect(entry['native_mode']).to eq('v2')
        end
      end

      it 'sets H2Codec.cglue_disabled so the Encoder hot path goes through Fiddle' do
        boot_handler_and_capture_log('v2')
        expect(Hyperion::H2Codec.cglue_active?).to be(false)
        # Encoder must agree (this is the actual bench contract — the
        # hot path probes `cglue_active?`, not `cglue_available?`).
        expect(Hyperion::H2Codec.cglue_available? && Hyperion::H2Codec.cglue_active?).to be(false)
      end
    end

    describe 'HYPERION_H2_NATIVE_HPACK=off / =0 (ruby fallback opt-out)' do
      %w[off 0 false no ruby].each do |val|
        it "logs hpack_path=pure-ruby for env=#{val.inspect}" do
          log = boot_handler_and_capture_log(val)
          entry = parse_codec_log(log)
          expect(entry['hpack_path']).to eq('pure-ruby')
          expect(entry['native_enabled']).to be(false)
        end
      end
    end

    describe 'three-variant bench contract — the matrix bench/h2_rails_shape.sh now runs' do
      # Lock in that the env-var values the harness relies on actually
      # produce the three distinct hpack_path strings the bench is
      # comparing. If a future maintainer renames a token, the bench
      # script + this spec move together.
      it 'maps {ruby,native,cglue} bench variants to {pure-ruby,native-v2,native-v3}',
         if: Hyperion::H2Codec.available? && Hyperion::H2Codec.cglue_available? do
        ruby_log   = boot_handler_and_capture_log('off')
        native_log = boot_handler_and_capture_log('v2')
        cglue_log  = boot_handler_and_capture_log('cglue')

        expect(parse_codec_log(ruby_log)['hpack_path']).to eq('pure-ruby')
        expect(parse_codec_log(native_log)['hpack_path']).to eq('native-v2')
        expect(parse_codec_log(cglue_log)['hpack_path']).to eq('native-v3')
      end
    end
  end
end
