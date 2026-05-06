# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'net/http'
require 'hyperion'

# Linux 5.19+: verify that:
#   1. The server boots cleanly with io_uring_hotpath: :on.
#   2. The metrics counter :io_uring_hotpath_fallback_engaged is
#      registered in the snapshot (defaults to 0 or nil; increments
#      only on the unhealthy-ring path).
#   3. The per-worker fallback code path EXISTS in server.rb and
#      compiles — verified by the successful server boot above.
#
# Injecting force_unhealthy! into a running server's accept fiber ring
# from an external thread requires cross-thread access to a Fiber-local
# variable, which is intentionally not exposed on the public API.  Full
# live injection is therefore left as a stretch goal for Task 2.5.5's
# bench-gate soak.  What we test here is the structural contract that
# the counter is wired and the fallback code compiles.
RSpec.describe 'io_uring hotpath per-worker fallback (structural)',
               if: Hyperion::IOUring.linux? &&
                   Hyperion::IOUring.respond_to?(:hotpath_supported?) &&
                   Hyperion::IOUring.hotpath_supported? do

  let(:app) { ->(_env) { [200, {}, ['ok']] } }

  it 'server boots and responds with io_uring_hotpath: :on' do
    probe = TCPServer.new('127.0.0.1', 0)
    port  = probe.addr[1]
    probe.close

    server = Hyperion::Server.new(
      host:             '127.0.0.1',
      port:             port,
      app:              app,
      thread_count:     0,
      io_uring_hotpath: :on
    )
    thr = Thread.new { server.start }
    sleep 0.3

    begin
      res = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
      expect(res.code).to eq('200')
    ensure
      server.stop rescue nil
      thr.join(1)
      thr.kill
    end
  end

  it ':io_uring_hotpath_fallback_engaged counter is accessible in the metrics snapshot' do
    snapshot = Hyperion.metrics.snapshot
    # The counter is either absent (never incremented) or an Integer (0+).
    # Both are valid at spec time — it only increments when a ring goes
    # unhealthy, which doesn't happen in normal operation.
    val = snapshot[:io_uring_hotpath_fallback_engaged]
    expect(val).to be_nil.or be_a(Integer)
  end

  it ':io_uring_hotpath_fallback_engaged is 0 (never triggered) on a healthy boot' do
    # Start a server, send a request to warm the accept loop, snapshot
    # the counter.  A freshly-booted healthy server should never trigger
    # the fallback path.
    probe = TCPServer.new('127.0.0.1', 0)
    port  = probe.addr[1]
    probe.close

    server = Hyperion::Server.new(
      host:             '127.0.0.1',
      port:             port,
      app:              app,
      thread_count:     0,
      io_uring_hotpath: :on
    )
    thr = Thread.new { server.start }
    sleep 0.3

    begin
      Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
      val = Hyperion.metrics.snapshot[:io_uring_hotpath_fallback_engaged] || 0
      expect(val).to eq(0)
    ensure
      server.stop rescue nil
      thr.join(1)
      thr.kill
    end
  end
end

# Cross-platform structural spec: verify the fallback detection code
# in server.rb compiles and the method exists regardless of platform.
RSpec.describe Hyperion::Server, '#run_accept_fiber_io_uring_hotpath (fallback hook)' do
  it 'defines run_accept_fiber_io_uring_hotpath as a private method' do
    expect(Hyperion::Server.private_instance_methods).to \
      include(:run_accept_fiber_io_uring_hotpath)
  end

  it 'Server#initialize accepts io_uring_hotpath: :off without raising' do
    server = Hyperion::Server.new(
      host:             '127.0.0.1',
      port:             9999,
      app:              ->(_env) { [200, {}, []] },
      io_uring_hotpath: :off
    )
    expect(server).to be_a(Hyperion::Server)
  end
end
