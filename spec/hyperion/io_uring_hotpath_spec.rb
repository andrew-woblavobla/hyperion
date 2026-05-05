# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/io_uring'
require 'fiddle'

# Linux 5.19+ smoke test for the hotpath FFI surface (plan #2 §2.1.4).
# Skips on platforms / kernels where the hotpath isn't available.
RSpec.describe 'io_uring hotpath FFI', if: Hyperion::IOUring.linux? do
  before do
    Hyperion::IOUring.reset!
    skip 'io_uring accept-only path not supported (kernel < 5.6)' \
      unless Hyperion::IOUring.supported?

    lib = Hyperion::IOUring.send(:load!)
    skip 'io_uring cdylib not loaded' unless lib

    @lib = lib
    probe_fn = Fiddle::Function.new(
      @lib['hyperion_io_uring_hotpath_supported'],
      [],
      Fiddle::TYPE_INT
    )
    rc = probe_fn.call
    skip "hotpath_supported returned #{rc} (kernel < 5.19 or PBUF_RING unavailable)" if rc.negative?
  end

  it 'probes successfully when the kernel supports PBUF_RING' do
    probe_fn = Fiddle::Function.new(
      @lib['hyperion_io_uring_hotpath_supported'],
      [],
      Fiddle::TYPE_INT
    )
    expect(probe_fn.call).to eq(0)
  end

  it 'allocates and frees a hotpath ring' do
    new_fn = Fiddle::Function.new(
      @lib['hyperion_io_uring_hotpath_ring_new'],
      [Fiddle::TYPE_INT, Fiddle::TYPE_SHORT, Fiddle::TYPE_INT],
      Fiddle::TYPE_VOIDP
    )
    free_fn = Fiddle::Function.new(
      @lib['hyperion_io_uring_hotpath_ring_free'],
      [Fiddle::TYPE_VOIDP],
      Fiddle::TYPE_VOID
    )

    ptr = new_fn.call(64, 32, 4096)
    expect(ptr).not_to be_null
    free_fn.call(ptr)
  end

  it 'rejects ring_new with zero queue depth (kernel error path)' do
    new_fn = Fiddle::Function.new(
      @lib['hyperion_io_uring_hotpath_ring_new'],
      [Fiddle::TYPE_INT, Fiddle::TYPE_SHORT, Fiddle::TYPE_INT],
      Fiddle::TYPE_VOIDP
    )
    ptr = new_fn.call(0, 32, 4096)
    expect(ptr).to be_null
  end

  it 'rejects ring_new with non-power-of-two n_bufs (PBUF_RING constraint)' do
    new_fn = Fiddle::Function.new(
      @lib['hyperion_io_uring_hotpath_ring_new'],
      [Fiddle::TYPE_INT, Fiddle::TYPE_SHORT, Fiddle::TYPE_INT],
      Fiddle::TYPE_VOIDP
    )
    ptr = new_fn.call(64, 33, 4096)  # 33 is not a power of 2
    expect(ptr).to be_null
  end
end
