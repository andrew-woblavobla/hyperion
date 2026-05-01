# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'hyperion'

# 2.10-E — Server boot calls `Hyperion::StaticPreload.run` for the
# resolved preload list right after `listen` configures the listener
# but BEFORE the accept loop starts.  The page cache must be populated
# (PageCache.size > 0) before the worker takes the first request, so
# the first cache hit is a warm cache hit, not a cold cache miss.
#
# This spec drives the boot pipeline through `Server#preload_static!`
# which `start` invokes once. We call it directly so the spec doesn't
# need to spin up a TCP server.
RSpec.describe 'Hyperion::Server static preload (2.10-E)' do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }

  before { Hyperion::Http::PageCache.clear }
  after  { Hyperion::Http::PageCache.clear }

  it 'warms the cache from a configured directory at boot' do
    Dir.mktmpdir('hyperion-srv-pre') do |dir|
      File.binwrite(File.join(dir, 'a.html'), 'AAA')
      File.binwrite(File.join(dir, 'b.css'), 'BBBB')

      server = Hyperion::Server.new(
        host: '127.0.0.1', port: 0, app: app,
        preload_static_dirs: [{ path: dir, immutable: true }]
      )

      io = StringIO.new
      server.preload_static!(logger: Hyperion::Logger.new(io: io, level: :info, format: :text))

      expect(Hyperion::Http::PageCache.size).to eq(2)
      expect(Hyperion::Http::PageCache.fetch(File.join(dir, 'a.html'))).to eq(:ok)
      expect(io.string).to include('static preload complete')
    end
  end

  it 'is a no-op when preload_static_dirs is empty' do
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app)
    io = StringIO.new
    server.preload_static!(logger: Hyperion::Logger.new(io: io, level: :info, format: :text))

    expect(Hyperion::Http::PageCache.size).to eq(0)
    expect(io.string).not_to include('static preload complete')
  end

  it 'marks every entry immutable so subsequent file changes are ignored' do
    Dir.mktmpdir('hyperion-srv-immut') do |dir|
      path = File.join(dir, 'logo.svg')
      File.binwrite(path, '<svg>v1</svg>')
      File.utime(Time.now - 60, Time.now - 60, path)

      prev = Hyperion::Http::PageCache.recheck_seconds
      Hyperion::Http::PageCache.recheck_seconds = 0.0
      begin
        server = Hyperion::Server.new(
          host: '127.0.0.1', port: 0, app: app,
          preload_static_dirs: [{ path: dir, immutable: true }]
        )
        io = StringIO.new
        server.preload_static!(logger: Hyperion::Logger.new(io: io, level: :info, format: :text))

        File.binwrite(path, '<svg>v2-newbytes</svg>')
        File.utime(Time.now, Time.now, path)

        expect(Hyperion::Http::PageCache.fetch(path)).to eq(:ok)
        expect(Hyperion::Http::PageCache.response_bytes(path)).to include('<svg>v1</svg>')
      ensure
        Hyperion::Http::PageCache.recheck_seconds = prev
      end
    end
  end
end
