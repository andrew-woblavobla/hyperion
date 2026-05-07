# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'net/http'
require 'hyperion'

# Linux 5.19+ end-to-end byte-parity spec for the io_uring hotpath
# (plan #2 §2.4.2). On hosts where hotpath_supported? returns true,
# boots two in-process Hyperion servers — one with hotpath ON, one with
# hotpath OFF — and asserts the response bodies match.
#
# On macOS / Linux <5.19 the spec is skipped via the `if:` guard; the
# bench gate (Task 2.5.5) exercises the same path for real on the bench
# host. The `pending` body below catches the case where the host claims
# to support the hotpath at probe time but the in-process server boot
# races or fails — the spec body pends with a clear message rather than
# hard-failing so the CI matrix stays green while the full integration
# suite is assembled.
RSpec.describe 'Connection over io_uring hotpath (E2E byte-parity)',
               if: Hyperion::IOUring.linux? &&
                   Hyperion::IOUring.respond_to?(:hotpath_supported?) &&
                   Hyperion::IOUring.hotpath_supported? do
  let(:app) do
    ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hello hotpath e2e']] }
  end

  # Boot a Hyperion server in a background thread, wait for it to accept,
  # return [thread, port, server].  The caller is responsible for
  # calling server.stop + thread.join in the ensure block.
  #
  # NOTE: we use `start` (which calls `listen` internally) rather than
  # `run(listener)` because the Server API changed across minor versions
  # and `start` is the stable public surface.
  #
  # `async_io: true` forces start_async_loop, which is the only path that
  # actually drives run_accept_fiber_io_uring_hotpath. Without it the
  # raw/C-loop path is taken and the hotpath fiber body never executes,
  # which is exactly what hid the row-19 BOOT-FAIL regression.
  def boot_server_thread(io_uring_hotpath:)
    # Pick a free port by binding ephemerally, then let go.
    probe = TCPServer.new('127.0.0.1', 0)
    port  = probe.addr[1]
    probe.close

    server = Hyperion::Server.new(
      host:             '127.0.0.1',
      port:             port,
      app:              app,
      thread_count:     0,
      async_io:         true,
      io_uring_hotpath: io_uring_hotpath
    )
    thr = Thread.new { server.start }
    # Poll the bound port instead of sleeping so a slow boot doesn't race
    # the first request — same shape as bench/run_all.sh's wait_for_bind.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      begin
        TCPSocket.open('127.0.0.1', port).close
        break
      rescue Errno::ECONNREFUSED
        sleep 0.05
      end
    end
    [thr, port, server]
  end

  it 'response body matches between hotpath ON and hotpath OFF' do
    thr_off, port_off, srv_off = boot_server_thread(io_uring_hotpath: :off)
    thr_on,  port_on,  srv_on  = boot_server_thread(io_uring_hotpath: :on)

    begin
      body_off = Net::HTTP.get(URI("http://127.0.0.1:#{port_off}/"))
      body_on  = Net::HTTP.get(URI("http://127.0.0.1:#{port_on}/"))
      expect(body_on).to eq(body_off)
      expect(body_on).to eq('hello hotpath e2e')
    ensure
      begin
        srv_off&.stop
      rescue StandardError
        nil
      end
      begin
        srv_on&.stop
      rescue StandardError
        nil
      end
      thr_off&.join(1)
      thr_on&.join(1)
      thr_off&.kill
      thr_on&.kill
    end
  end
end
