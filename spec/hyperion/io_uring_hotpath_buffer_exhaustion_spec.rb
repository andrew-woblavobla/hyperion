# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'
require 'hyperion/io_uring'

# Linux 5.19+: drive a HotpathRing with a tiny buffer pool until it
# approaches exhaustion; verify the ring stays healthy under more-
# concurrent-clients-than-buffers load and that we receive at least
# some recv CQEs.
#
# The ENOBUFS detection (result == -ENOBUFS) is racy: whether the
# kernel actually exhausts the buffer ring depends on scheduling
# timing between the test thread pumping clients and the ring draining
# CQEs.  The primary assertion is therefore the health invariant
# (ring.healthy? == true), not a hard count of ENOBUFS CQEs — that
# would be an inherently flaky number.  The secondary assertion
# (recv_count >= 1) verifies the ring is actually processing data.
RSpec.describe 'io_uring hotpath buffer exhaustion',
               if: Hyperion::IOUring.linux? &&
                   Hyperion::IOUring.respond_to?(:hotpath_supported?) &&
                   Hyperion::IOUring.hotpath_supported? do

  # ENOBUFS on Linux is errno 105.  See include/uapi/asm-generic/errno.h.
  ENOBUFS_NEGATED = -105

  it 'ring stays healthy under more-clients-than-buffers load and receives some data' do
    # Tiny ring: 4 buffers of 256 bytes each — small enough that 8
    # concurrent senders should saturate it under reasonable timing.
    ring = Hyperion::IOUring::HotpathRing.new(queue_depth: 32, n_bufs: 4, buf_size: 256)

    listener = TCPServer.new('127.0.0.1', 0)
    port     = listener.addr[1]
    ring.submit_accept_multishot(listener.fileno)

    # Open more concurrent clients than the buffer count.
    n_clients = 8
    clients = Array.new(n_clients) { TCPSocket.new('127.0.0.1', port) }

    # Drain the accept CQEs so the ring has accepted all clients, then
    # submit multishot-recv on each.
    accepted_fds = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
    until accepted_fds.length >= n_clients ||
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      ring.each_completion(min_complete: 1, timeout_ms: 200) do |cqe|
        next unless cqe[:op_kind] == Hyperion::IOUring::HotpathRing::OP_ACCEPT

        fd = cqe[:result]
        if fd >= 0
          accepted_fds << fd
          ring.submit_recv_multishot(fd)
        end
      end
    end

    # All clients write data — drives recv CQEs.  With 8 senders sharing
    # 4 buffers the kernel may produce ENOBUFS-tagged CQEs.
    clients.each_with_index { |c, i| c.write("ping#{i}\r\n") }
    sleep 0.15

    enobufs_count = 0
    recv_count    = 0

    deadline2 = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    loop do
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline2

      n = ring.each_completion(min_complete: 0, timeout_ms: 100) do |cqe|
        next unless cqe[:op_kind] == Hyperion::IOUring::HotpathRing::OP_RECV

        if cqe[:result] == ENOBUFS_NEGATED
          enobufs_count += 1
        elsif cqe[:result].positive?
          recv_count += 1
          ring.release_buffer(cqe[:buf_id]) if cqe[:buf_id] >= 0
        end
      end
      break if n.zero? && recv_count >= 1
    end

    # Primary invariant: ring remains healthy regardless of ENOBUFS CQEs.
    expect(ring.healthy?).to eq(true)
    # Secondary: we received at least one data CQE (proves the ring is
    # processing and not silently stuck).
    expect(recv_count).to be >= 1
    # Informational — not asserted hard because it's scheduling-dependent.
    warn "[buffer_exhaustion_spec] enobufs_count=#{enobufs_count} recv_count=#{recv_count}" \
         " accepted=#{accepted_fds.length}"
  ensure
    ring&.close
    clients&.each { |c| c.close unless c.closed? }
    listener&.close
  end
end
