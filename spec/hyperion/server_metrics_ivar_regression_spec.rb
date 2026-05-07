# frozen_string_literal: true

require 'spec_helper'
require 'hyperion'

# Regression for the row-19 BOOT-FAIL on the 2026-05-07 bench run.
#
# `Server#run_accept_fiber_io_uring_hotpath` (server.rb) used to call
# `@metrics.increment(:connections_accepted)` and
# `@metrics.increment(:connections_active)` on every accept completion.
# `Server` has no `@metrics` ivar — sibling write paths use `runtime_metrics`
# (which routes to `@runtime.metrics` or `Hyperion.metrics`). Reading the
# unset ivar evaluates to `nil`, so the first OP_ACCEPT completion raised
# `NoMethodError: undefined method 'increment' for nil`.
#
# The error is caught one level up and logged as
#   "io_uring hotpath accept fiber error; falling back to epoll"
# but the fallback only manifested for the `--async-io + hotpath=on + 1w`
# combination (start_async_loop is the only call path that actually drives
# run_accept_fiber_io_uring_hotpath; start_raw_loop short-circuits to the
# C accept loop). The regression hid behind a `pending` rescue in
# spec/hyperion/connection_io_uring_hotpath_spec.rb, which masked the
# NoMethodError as "in-process boot is fragile".
#
# This spec runs cross-platform (no io_uring needed) so any future
# re-introduction of an `@metrics`-style ivar reference inside Server
# trips on macOS / Linux CI before it can sneak past the bench gate again.
RSpec.describe 'Hyperion::Server @metrics ivar regression (row-19 BOOT-FAIL)' do
  let(:app) { ->(_env) { [200, {}, []] } }

  it 'never reads an undefined @metrics ivar — uses runtime_metrics' do
    src = File.read(File.expand_path('../../lib/hyperion/server.rb', __dir__))
    # Strip comments + string literals so a doc reference to "@metrics"
    # in a code comment doesn't trip the assertion.
    code = src.lines.reject { |l| l.lstrip.start_with?('#') }.join
    offending = code.scan(/@metrics(?!\w)/)
    expect(offending).to be_empty,
                         "Server should route metrics writes through runtime_metrics, not @metrics " \
                         "(found #{offending.size} occurrence(s)). See server.rb run_accept_fiber_io_uring_hotpath " \
                         "for the row-19 BOOT-FAIL precedent."
  end

  it 'has nil @metrics on a freshly-built Server (proves runtime_metrics is the canonical accessor)' do
    server = Hyperion::Server.new(app: app)
    expect(server.instance_variable_get(:@metrics)).to be_nil
    # And runtime_metrics returns a usable counter sink.
    expect(server.send(:runtime_metrics)).to respond_to(:increment)
  end
end
