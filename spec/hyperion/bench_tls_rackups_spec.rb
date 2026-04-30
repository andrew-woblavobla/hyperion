# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'rack'
require 'rack/builder'
require 'rack/mock_request'
require 'tempfile'
require 'stringio'
require 'fileutils'
require 'hyperion/cli'

# 2.2.x fix-C: bench rackups + env-var plumbing for the large-payload
# TLS bench harness. The Phase 9 (commit 5c00b15) hello-payload bench
# REGRESSED -15% on TLS h1 because at 5-byte response bodies the cipher
# cost is a tiny fraction of per-request overhead. The new rackups
# exercise the workloads where kTLS_TX should actually win
# (50 KB JSON + 1 MiB static), and `HYPERION_TLS_KTLS` lets operators
# A/B kernel-TLS vs userspace SSL_write without rewriting config.
RSpec.describe 'fix-C — bench TLS rackups + HYPERION_TLS_KTLS env-var' do
  let(:repo_root) { File.expand_path('../..', __dir__) }

  describe 'bench/tls_json_50k.ru' do
    let(:rackup_path) { File.join(repo_root, 'bench/tls_json_50k.ru') }
    let(:app) do
      result = ::Rack::Builder.parse_file(rackup_path)
      result.is_a?(Array) ? result.first : result
    end

    it 'parses cleanly and responds 200 with JSON content-type' do
      env = ::Rack::MockRequest.env_for('/')
      status, headers, body = app.call(env)

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/json')
      body_string = +''
      body.each { |chunk| body_string << chunk }
      expect(JSON.parse(body_string)).to be_a(Hash)
    end

    it 'returns a payload in the 30-80 KB sweet-spot range' do
      env = ::Rack::MockRequest.env_for('/')
      _status, _headers, body = app.call(env)
      bytes = +''
      body.each { |chunk| bytes << chunk }

      # Aim is ~50 KB; allow 30-80 KB headroom so an operator can tweak
      # the multiplier without breaking the spec. Anything outside that
      # range is no longer in the kTLS_TX sweet spot.
      expect(bytes.bytesize).to be_between(30_000, 80_000),
                                "expected 30 KB ≤ payload ≤ 80 KB, got #{bytes.bytesize}"
    end
  end

  describe 'bench/tls_static_1m.ru' do
    let(:rackup_path) { File.join(repo_root, 'bench/tls_static_1m.ru') }
    let(:app) do
      result = ::Rack::Builder.parse_file(rackup_path)
      result.is_a?(Array) ? result.first : result
    end
    let(:asset_dir) { Dir.mktmpdir('hyperion_bench_tls_static') }
    let(:asset_name) { 'fixture_1m.bin' }

    before do
      File.binwrite(File.join(asset_dir, asset_name), 'x' * (1024 * 1024))
      ENV['HYPERION_BENCH_ASSET_DIR'] = asset_dir
    end

    after do
      ENV.delete('HYPERION_BENCH_ASSET_DIR')
      FileUtils.rm_rf(asset_dir)
    end

    it 'serves a 1 MiB asset from HYPERION_BENCH_ASSET_DIR' do
      env = ::Rack::MockRequest.env_for("/#{asset_name}")
      status, _headers, body = app.call(env)

      bytes = +''
      body.each { |chunk| bytes << chunk }
      body.close if body.respond_to?(:close)

      expect(status).to eq(200)
      expect(bytes.bytesize).to eq(1024 * 1024)
    end
  end

  describe 'HYPERION_TLS_KTLS env-var → config.tls.ktls' do
    let(:io) { StringIO.new }
    let(:logger) { Hyperion::Logger.new(io: io, level: :warn, format: :text) }
    let(:config) { Hyperion::Config.new }

    before do
      @prev_env = ENV['HYPERION_TLS_KTLS']
      @prev_logger = Hyperion::Runtime.default.logger
      Hyperion::Runtime.default.logger = logger
    end

    after do
      ENV['HYPERION_TLS_KTLS'] = @prev_env # restore (nil-safe)
      Hyperion::Runtime.default.logger = @prev_logger
    end

    def call!
      Hyperion::CLI.send(:apply_ktls_env_override!, config)
    end

    it 'leaves config.tls.ktls untouched when env is unset (default :auto)' do
      ENV.delete('HYPERION_TLS_KTLS')
      call!
      expect(config.tls.ktls).to eq(:auto)
    end

    it 'maps HYPERION_TLS_KTLS=off to :off' do
      ENV['HYPERION_TLS_KTLS'] = 'off'
      call!
      expect(config.tls.ktls).to eq(:off)
    end

    it 'maps HYPERION_TLS_KTLS=on to :on' do
      ENV['HYPERION_TLS_KTLS'] = 'on'
      call!
      expect(config.tls.ktls).to eq(:on)
    end

    it 'maps HYPERION_TLS_KTLS=auto to :auto explicitly' do
      ENV['HYPERION_TLS_KTLS'] = 'auto'
      config.tls.ktls = :off # prove the env var actually overrides a prior setting
      call!
      expect(config.tls.ktls).to eq(:auto)
    end

    it 'warns and leaves the value untouched on an unknown setting' do
      ENV['HYPERION_TLS_KTLS'] = 'kernel'
      config.tls.ktls = :auto
      call!
      expect(config.tls.ktls).to eq(:auto)
      expect(io.string).to include('HYPERION_TLS_KTLS ignored')
    end

    it 'is a no-op when the env var is set to the empty string' do
      ENV['HYPERION_TLS_KTLS'] = ''
      config.tls.ktls = :auto
      call!
      expect(config.tls.ktls).to eq(:auto)
    end
  end
end
