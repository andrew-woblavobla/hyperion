# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'
require 'hyperion/io_uring'
require 'fiddle'

# Linux 5.19+: submit a send SQE via HotpathRing#submit_send and verify
# the bytes appear at the peer end of a Socket.pair.
#
# The iov (scatter-gather vector) is built as a 2-element C struct array:
#   { iov_base: void*, iov_len: size_t }
# using Fiddle::Pointer arithmetic.  The payload String must outlive the
# iov buffer — it is pinned via a local variable throughout the test.
RSpec.describe 'io_uring hotpath send SQE',
               if: Hyperion::IOUring.linux? &&
                   Hyperion::IOUring.respond_to?(:hotpath_supported?) &&
                   Hyperion::IOUring.hotpath_supported? do

  it 'submits a send SQE and the bytes appear at the peer' do
    r, w = Socket.pair(:UNIX, :STREAM)
    ring = Hyperion::IOUring::HotpathRing.new(queue_depth: 16, n_bufs: 4, buf_size: 4096)

    payload = "hello via io_uring\n"

    # Build a single-element iov array: { iov_base: void*, iov_len: size_t }.
    # On a 64-bit platform both fields are 8 bytes (pointer + size_t).
    # Fiddle::SIZEOF_VOIDP gives the platform pointer size (8 on LP64).
    ptr_size = Fiddle::SIZEOF_VOIDP
    iov_buf  = Fiddle::Pointer.malloc(ptr_size * 2, Fiddle::RUBY_FREE)

    # Write iov_base (pointer to payload bytes) and iov_len.
    # IMPORTANT: payload must stay live until the CQE lands so Ruby GC
    # does not collect the underlying byte buffer.
    payload_ptr = Fiddle::Pointer[payload]
    iov_buf[0,        ptr_size] = [payload_ptr.to_i].pack('Q<')
    iov_buf[ptr_size, ptr_size] = [payload.bytesize].pack('Q<')

    ring.submit_send(w.fileno, iov_buf, 1)

    # Drain the send CQE.
    completed_bytes = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    loop do
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      ring.each_completion(min_complete: 0, timeout_ms: 200) do |cqe|
        next unless cqe[:op_kind] == Hyperion::IOUring::HotpathRing::OP_SEND

        completed_bytes = cqe[:result]
      end
      break unless completed_bytes.nil?
    end

    expect(completed_bytes).to eq(payload.bytesize)

    # Read back from the peer end to confirm the bytes actually arrived.
    received = r.read_nonblock(payload.bytesize + 16, exception: false)
    expect(received).to eq(payload)
    # Keep payload alive until here so GC doesn't collect it early.
    GC.keep_alive(payload) if GC.respond_to?(:keep_alive)
  ensure
    ring&.close
    [r, w].each { |s| s.close unless s.closed? }
  end
end
