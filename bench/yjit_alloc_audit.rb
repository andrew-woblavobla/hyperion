# frozen_string_literal: true

# Phase 11 — Per-request allocation audit.
#
# Drives the in-process request hot path (Adapter::Rack.call → app → no-op
# socket write via ResponseWriter#write) for N requests, captures the delta
# in `GC.stat[:total_allocated_objects]` before vs after, and prints the
# per-request allocation count.
#
# Usage:
#   ruby bench/yjit_alloc_audit.rb            # CRuby
#   ruby --yjit bench/yjit_alloc_audit.rb     # YJIT
#   rake bench:yjit_alloc                     # convenience wrapper
#
# Two modes are reported:
#   * full   — Adapter::Rack.call → minimal app → ResponseWriter#write
#              (entire Ruby-side request hot path round-trip)
#   * env    — Adapter::Rack.send(:build_env, ...) only
#              (isolates env-construction cost from response-write cost)

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hyperion'
require 'stringio'

# ---------------------------------------------------------------------------
# Sink IO — answers #write but doesn't allocate; mirrors what the real
# socket would do under wrk-style load (kernel buffer accepts everything).
# ---------------------------------------------------------------------------
class NullIO
  def initialize
    @bytes_written = 0
  end

  def write(bytes)
    @bytes_written += bytes.bytesize
    bytes.bytesize
  end

  def closed?
    false
  end

  def flush; end
end

# ---------------------------------------------------------------------------
# Build a fixed Request fixture mimicking a typical wrk client request:
# 6 common headers, no body. Same payload across all iterations so per-
# request allocation diffs reflect only the server's behavior, not fixture
# regeneration.
# ---------------------------------------------------------------------------
def build_request
  headers = {
    'host' => '127.0.0.1:9292',
    'user-agent' => 'wrk/4.2.0',
    'accept' => '*/*',
    'accept-encoding' => 'gzip',
    'connection' => 'keep-alive',
    'cookie' => 'a=1; b=2; c=3'
  }
  Hyperion::Request.new(
    method: 'GET',
    path: '/',
    query_string: '',
    http_version: 'HTTP/1.1',
    headers: headers,
    body: '',
    peer_address: '127.0.0.1'
  )
end

# Minimal Rack app — same shape as bench/work.ru but skipping the JSON
# work so we measure server-side allocation, not app-side.
APP = lambda do |env|
  _ = env['HTTP_USER_AGENT']
  [
    200,
    { 'content-type' => 'text/plain', 'x-request-id' => 'audit' },
    ['hello world']
  ]
end

def run_full_path(iterations)
  request = build_request
  writer  = Hyperion::ResponseWriter.new
  io      = NullIO.new

  # Warm up so JIT/method-cache fills aren't counted in the measured window.
  10.times do
    status, headers, body = Hyperion::Adapter::Rack.call(APP, request)
    writer.write(io, status, headers, body, keep_alive: true)
  end

  GC.disable
  GC.start
  before = GC.stat[:total_allocated_objects]

  iterations.times do
    status, headers, body = Hyperion::Adapter::Rack.call(APP, request)
    writer.write(io, status, headers, body, keep_alive: true)
  end

  after = GC.stat[:total_allocated_objects]
  GC.enable

  (after - before).fdiv(iterations)
end

def run_env_only(iterations)
  request = build_request

  10.times { Hyperion::Adapter::Rack.send(:build_env, request) }

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

  (after - before).fdiv(iterations)
end

if $PROGRAM_NAME == __FILE__
  iterations = (ENV['ITERATIONS'] || '20000').to_i
  yjit       = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

  puts "Hyperion #{Hyperion::VERSION} per-request allocation audit"
  puts "  ruby:        #{RUBY_DESCRIPTION}"
  puts "  yjit:        #{yjit}"
  puts "  c_build_env: #{Hyperion::Adapter::Rack.c_build_env_available?}"
  puts "  c_upcase:    #{Hyperion::Adapter::Rack.c_upcase_available?}"
  puts "  iterations:  #{iterations}"
  puts

  full = run_full_path(iterations)
  envb = run_env_only(iterations)

  printf "  full path (Adapter#call + ResponseWriter#write): %6.2f objects/req\n", full
  printf "  build_env only:                                   %6.2f objects/req\n", envb
end
