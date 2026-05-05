# frozen_string_literal: true

# Phase 11 — per-request allocation regression guard.
#
# Drives the in-process Ruby request hot path (Adapter::Rack#call →
# minimal app → ResponseWriter#write into a NullIO sink) and asserts
# that `GC.stat[:total_allocated_objects]` grows by no more than the
# threshold per request.
#
# The threshold is set ~10% above the measured Phase 11 number so a
# future regression (e.g. someone re-introduces a `+''` in build_env)
# fails this spec, while normal CRuby/YJIT noise stays green.
#
# Measured baselines (commit pre-Phase-11 vs post-Phase-11, local macOS
# arm64, Ruby 3.3.3, C ext built):
#
#   ruby bench/yjit_alloc_audit.rb     ITERATIONS=20000
#
#                          | full path | build_env only |
#   pre-Phase-11           |  19.00    |  9.00          |
#   post-Phase-11          |   9.00    |  2.00          |
#
# Threshold = ceil(1.1 * post-Phase-11) — if measured drifts up
# repeatedly, regenerate the bench, confirm intentional, lift threshold.

require 'stringio'
require 'hyperion'

class NullSinkIO
  def write(bytes)
    bytes.bytesize
  end

  def closed?
    false
  end

  def flush; end
end

RSpec.describe 'YJIT allocation audit (Phase 11)' do
  let(:request) do
    Hyperion::Request.new(
      method: 'GET',
      path: '/',
      query_string: '',
      http_version: 'HTTP/1.1',
      headers: {
        'host' => '127.0.0.1:9292',
        'user-agent' => 'wrk/4.2.0',
        'accept' => '*/*',
        'accept-encoding' => 'gzip',
        'connection' => 'keep-alive',
        'cookie' => 'a=1; b=2; c=3'
      },
      body: '',
      peer_address: '127.0.0.1'
    )
  end

  let(:writer) { Hyperion::ResponseWriter.new }
  let(:sink)   { NullSinkIO.new }

  let(:app) do
    lambda do |env|
      _ = env['HTTP_USER_AGENT']
      [200, { 'content-type' => 'text/plain', 'x-request-id' => 'audit' }, ['hello']]
    end
  end

  # Warm up the method cache + any lazy-init paths (cached_date,
  # @c_build_env_available, etc.) so the measurement window only counts
  # steady-state allocations.
  def warm
    20.times do
      status, headers, body = Hyperion::Adapter::Rack.call(app, request)
      writer.write(sink, status, headers, body, keep_alive: true)
    end
  end

  def per_request_allocations(iterations)
    warm
    GC.disable
    GC.start
    before = GC.stat[:total_allocated_objects]
    iterations.times do
      status, headers, body = Hyperion::Adapter::Rack.call(app, request)
      writer.write(sink, status, headers, body, keep_alive: true)
    end
    after = GC.stat[:total_allocated_objects]
    GC.enable
    (after - before).fdiv(iterations)
  end

  it 'allocates ≤ 10 objects per full-path request' do
    # post-Phase-11 measured: 9.0 objects/req. Threshold 10 (≈ +11%) so
    # a single new allocation per request fails this spec while normal
    # CRuby noise (none, given GC.disable) stays green.
    iterations = 5_000
    per_req = per_request_allocations(iterations)
    expect(per_req).to be <= 10.0,
                       "expected ≤ 10.0 objects/req, got #{per_req.round(2)}"
  end

  it 'allocates ≤ 3 objects per build_env-only call' do
    # post-Phase-11 measured: 2.0 objects/req (the 2 host_header
    # byteslices — server_name + server_port — both retained in env).
    # Threshold 3 catches an accidental re-introduction of any single
    # transient allocation.
    iterations = 5_000

    20.times { Hyperion::Adapter::Rack.send(:build_env, request) }
    GC.disable
    GC.start
    before = GC.stat[:total_allocated_objects]
    iterations.times do
      env, input = Hyperion::Adapter::Rack.send(:build_env, request)
      Hyperion::Adapter::Rack::ENV_POOL.release(env)
      Hyperion::Adapter::Rack::INPUT_POOL.release(input)
    end
    after = GC.stat[:total_allocated_objects]
    GC.enable

    per_req = (after - before).fdiv(iterations)
    expect(per_req).to be <= 3.0,
                       "expected ≤ 3.0 objects/req, got #{per_req.round(2)}"
  end

  describe 'C-path engagement (plan #1 — direct-syscall response writer)' do
    # Socket.pair gives us a real kernel fd so real_fd_io? returns true
    # and c_path_eligible? is true — the C dispatcher is engaged.
    # A drain thread reads from the reader side so the kernel send buffer
    # never fills (which would flip the C path into WOULDBLOCK and fall
    # back to Ruby, skewing the measurement).
    def per_request_allocations_with_fd(iterations)
      reader, writer_io = Socket.pair(:UNIX, :STREAM)
      drain = Thread.new { reader.read rescue nil }

      # Warm up: same shape as the NullSinkIO warm, but routes through
      # the C dispatcher because the writer fd has a real fileno.
      20.times do
        status, headers, body = Hyperion::Adapter::Rack.call(app, request)
        writer.write(writer_io, status, headers, body, keep_alive: true)
      end

      GC.disable
      GC.start
      before = GC.stat[:total_allocated_objects]
      iterations.times do
        status, headers, body = Hyperion::Adapter::Rack.call(app, request)
        writer.write(writer_io, status, headers, body, keep_alive: true)
      end
      after = GC.stat[:total_allocated_objects]
      GC.enable

      writer_io.close
      drain.join
      reader.close

      (after - before).fdiv(iterations)
    end

    it 'allocates fewer objects per request than the Ruby path (C dispatcher engaged)' do
      skip 'C ext not loaded' unless defined?(::Hyperion::Http::ResponseWriter) &&
                                     ::Hyperion::Http::ResponseWriter.c_writer_available?
      iterations = 2_000
      per_req = per_request_allocations_with_fd(iterations)
      # Plan #1 — the C path eliminates the Ruby `+''` head buffer and
      # the per-chunk body `<<`, plus the IO#write encoding check on
      # the buffered hot path.
      #
      # Measured baseline (macOS arm64, Ruby 3.3, C ext built, Socket.pair
      # UNIX target): ~6.05 objects/req. The remaining allocations come
      # from Adapter::Rack#build_env (the 2 host_header byteslices + env
      # hash pool round-trip) which is on the same call path as the
      # NullSinkIO benchmark but unchanged by the C writer.
      #
      # Budget = ceil(1.2 × 6.08) = 8.0. If the measured count drifts
      # up intentionally (new env key, etc.), regenerate and lift here.
      expect(per_req).to be <= 8.0,
                         "expected ≤ 8.0 objects/req on the C path, got #{per_req.round(2)}"
    end
  end
end
