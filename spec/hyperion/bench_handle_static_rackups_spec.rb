# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'rack/builder'
require 'rack/mock_request'
require 'tmpdir'
require 'fileutils'
require 'hyperion'

# 2.12-B — fresh 4-way re-bench. The harness gains a "hyperion_handle_static"
# variant that boots Hyperion against an alternate rackup whose hot path is
# `Hyperion::Server.handle_static` (2.10-D direct route + 2.10-F C-ext fast
# path + 2.10-C PageCache fold).
#
# These specs cover:
#   * bench/hello_static.ru — boots, registers the static route, and serves
#     a 200 / "hello" / text/plain response from the fast path.
#   * bench/static_handle_static.ru — boots only when the asset is on disk,
#     registers the route, and serves the asset bytes verbatim.
#   * bench/4way_compare.sh — the harness's `case "$srv"` switch knows about
#     all five variant labels (hyperion, hyperion_handle_static, puma,
#     falcon, agoo). A typo here would silently regress the bench output.
RSpec.describe '2.12-B — handle_static bench rackups + 4way harness variants' do
  let(:repo_root) { File.expand_path('../..', __dir__) }

  # `Server.handle_static` mutates the process-wide route table; isolate
  # each example so a registration in spec A doesn't leak into spec B.
  around do |example|
    saved_table = Hyperion::Server.route_table
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    example.run
    Hyperion::Server.route_table = saved_table
  end

  describe 'bench/hello_static.ru' do
    let(:rackup_path) { File.join(repo_root, 'bench/hello_static.ru') }

    it 'parses cleanly and registers a / handle_static route' do
      result = ::Rack::Builder.parse_file(rackup_path)
      app = result.is_a?(Array) ? result.first : result

      entry = Hyperion::Server.route_table.lookup(:GET, '/')
      expect(entry).to be_a(Hyperion::Server::RouteTable::StaticEntry)
      expect(entry.response_bytes).to include('HTTP/1.1 200 OK')
      expect(entry.response_bytes).to include('content-type: text/plain')
      expect(entry.response_bytes).to end_with("\r\n\r\nhello")

      # Fallback Rack app still answers (lets wrk hit a 200 even if the
      # handle_static dispatcher is bypassed in some smoke path).
      env = ::Rack::MockRequest.env_for('/anything-else')
      status, _headers, _body = app.call(env)
      expect(status).to eq(404) # rackup falls through to a 404 lambda
    end
  end

  describe 'bench/static_handle_static.ru' do
    let(:rackup_path) { File.join(repo_root, 'bench/static_handle_static.ru') }
    let(:asset_dir) { Dir.mktmpdir('hyperion_bench_static_handle_static') }
    let(:asset_name) { 'hyperion_bench_1k.bin' }
    let(:asset_bytes) { 'x' * 1024 }

    before do
      File.binwrite(File.join(asset_dir, asset_name), asset_bytes)
      ENV['HYPERION_BENCH_ASSET_DIR'] = asset_dir
      ENV['HYPERION_BENCH_ASSET_NAME'] = asset_name
    end

    after do
      ENV.delete('HYPERION_BENCH_ASSET_DIR')
      ENV.delete('HYPERION_BENCH_ASSET_NAME')
      FileUtils.rm_rf(asset_dir)
    end

    it 'preloads the asset and registers a handle_static route at boot' do
      ::Rack::Builder.parse_file(rackup_path)

      entry = Hyperion::Server.route_table.lookup(:GET, "/#{asset_name}")
      expect(entry).to be_a(Hyperion::Server::RouteTable::StaticEntry)
      expect(entry.response_bytes).to include('HTTP/1.1 200 OK')
      expect(entry.response_bytes).to include('content-type: application/octet-stream')
      expect(entry.response_bytes).to include("content-length: #{asset_bytes.bytesize}")
      expect(entry.response_bytes).to end_with(asset_bytes)
    end

    it 'fails fast if the asset is missing rather than booting empty' do
      ENV['HYPERION_BENCH_ASSET_NAME'] = 'definitely-not-there.bin'
      expect do
        ::Rack::Builder.parse_file(rackup_path)
      end.to raise_error(/missing asset/)
    end
  end

  describe 'bench/4way_compare.sh — variant matrix' do
    let(:harness_path) { File.join(repo_root, 'bench/4way_compare.sh') }
    let(:harness_src) { File.read(harness_path) }

    # Every variant the doc describes MUST have a `case` arm; otherwise
    # the harness silently skips the row and the doc lies. Keep this list
    # in lockstep with the doc + the case statement in the harness.
    %w[hyperion hyperion_handle_static puma falcon agoo].each do |variant|
      it "knows how to boot the '#{variant}' variant" do
        # Match e.g. "    hyperion)" or "    hyperion_handle_static)" in the
        # case statement so a typo in either side is caught.
        expect(harness_src).to match(/^\s+#{Regexp.escape(variant)}\)\s*$/),
                               "harness is missing a `#{variant})` case arm"
      end
    end

    it 'documents the new HYPERION_STATIC_RACKUP override env var' do
      expect(harness_src).to include('HYPERION_STATIC_RACKUP'),
                             'harness should source HYPERION_STATIC_RACKUP for the handle_static variant'
    end
  end
end
