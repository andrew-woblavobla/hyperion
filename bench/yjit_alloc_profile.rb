# frozen_string_literal: true

# memory_profiler-driven top-N allocation site report on the request hot path.
# Usage: ruby bench/yjit_alloc_profile.rb [iterations]

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hyperion'
require 'memory_profiler'
require_relative 'yjit_alloc_audit'

iterations = (ARGV[0] || '5000').to_i
request    = build_request
writer     = Hyperion::ResponseWriter.new
io         = NullIO.new

# Warmup
50.times do
  status, headers, body = Hyperion::Adapter::Rack.call(APP, request)
  writer.write(io, status, headers, body, keep_alive: true)
end

report = MemoryProfiler.report do
  iterations.times do
    status, headers, body = Hyperion::Adapter::Rack.call(APP, request)
    writer.write(io, status, headers, body, keep_alive: true)
  end
end

report.pretty_print(scale_bytes: true,
                    detailed_report: true,
                    allocated_strings: 25,
                    retained_strings: 25,
                    to_file: nil)
