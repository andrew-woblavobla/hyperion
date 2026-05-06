# frozen_string_literal: true

require 'spec_helper'
require 'hyperion/io_uring'

# Cross-platform ABI guard: when an old (v1) cdylib lands on disk while
# the Ruby side expects v2, the loader must warn + return nil, NOT crash.
# This catches the "operator forgot to gem pristine after upgrade" case.
RSpec.describe 'io_uring hotpath ABI guard' do
  before do
    Hyperion::IOUring.reset!
    @warns = []
    allow(Hyperion::IOUring).to receive(:warn) { |m| @warns << m }
  end
  after { Hyperion::IOUring.reset! }

  it 'falls back when the cdylib reports an older ABI (v1 vs expected v2)' do
    # Fake function whose .call returns 1 (old ABI).
    abi_fn = Object.new
    def abi_fn.call; 1; end

    # fake_lib must respond to [] (Fiddle::Handle#[]) and return something
    # Fiddle::Function.new can be given; we intercept that call anyway.
    fake_lib = Object.new
    fake_sym = Object.new
    allow(fake_lib).to receive(:[]).and_return(fake_sym)

    # Intercept Fiddle::Function.new — only the first call (abi_version probe)
    # is reached; the ABI mismatch short-circuits before any other Function
    # is constructed.
    allow(Fiddle::Function).to receive(:new).and_return(abi_fn)

    # Force a Linux-like environment so we proceed past the OS gate.
    allow(Etc).to receive(:uname).and_return({ sysname: 'Linux', release: '5.19.0' })
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(/libhyperion_io_uring/).and_return(true)
    allow(Fiddle).to receive(:dlopen).and_return(fake_lib)

    # The mismatched-ABI path must be a clean fallback, not a crash.
    result = Hyperion::IOUring.send(:load!)
    expect(result).to be_nil
    expect(@warns.join("\n")).to include('ABI mismatch')
    expect(Hyperion::IOUring.hotpath_supported?).to eq(false)
  end
end
