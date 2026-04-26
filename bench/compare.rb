# frozen_string_literal: true

# Boot hyperion / puma / falcon in turn on local ports, hit each with `wrk`,
# print a comparison report.
#
# Requires `wrk` on PATH (macOS: brew install wrk; Linux: apt install wrk).
# Puma and Falcon must be installed separately if you want them included
# (this harness skips any server whose CLI is missing).
#
# Tunables:
#   BENCH_DURATION (default 10s)
#   BENCH_THREADS  (default 4)
#   BENCH_CONNS    (default 100)
#
# Usage:
#   wrk available + puma + falcon installed:
#     bundle exec ruby bench/compare.rb
#   Only hyperion installed:
#     bundle exec ruby bench/compare.rb   # falcon/puma rows say "skipped"

require 'shellwords'

HYPERION_WORKERS = ENV.fetch('HYPERION_WORKERS', '1').to_i
FALCON_COUNT     = ENV.fetch('FALCON_COUNT',     HYPERION_WORKERS.to_s).to_i
PUMA_WORKERS     = ENV.fetch('PUMA_WORKERS',     HYPERION_WORKERS.to_s).to_i

CASES = {
  'hyperion' => "bundle exec bin/hyperion -w #{HYPERION_WORKERS} -p %<port>d bench/hello.ru",
  'puma' => "bundle exec puma -w #{PUMA_WORKERS} -p %<port>d bench/hello.ru",
  'falcon' => "bundle exec falcon serve --bind http://127.0.0.1:%<port>d --count #{FALCON_COUNT} -c bench/hello.ru"
}.freeze

DURATION = ENV.fetch('BENCH_DURATION', '10s')
THREADS  = ENV.fetch('BENCH_THREADS',  '4')
CONNS    = ENV.fetch('BENCH_CONNS',    '100')

def have?(bin)
  system("command -v #{bin.shellescape} > /dev/null 2>&1")
end

def server_available?(name)
  case name
  when 'hyperion'
    File.executable?(File.expand_path('../bin/hyperion', __dir__))
  when 'puma'
    have?('puma') || system('bundle exec puma --version > /dev/null 2>&1')
  when 'falcon'
    have?('falcon') || system('bundle exec falcon --version > /dev/null 2>&1')
  else
    false
  end
end

abort 'install wrk: brew install wrk (macOS) or apt install wrk (Linux)' unless have?('wrk')

results = {}
port = 19_000

def kill(pid)
  return unless pid

  Process.kill('TERM', pid)
  Process.waitpid(pid, Process::WNOHANG)
rescue StandardError
  # already gone
end

CASES.each do |name, cmd_template|
  port += 1

  unless server_available?(name)
    results[name] = "(skipped — #{name} not installed in this bundle)"
    next
  end

  cmd = format(cmd_template, port: port)
  warn "[bench] starting #{name}: #{cmd}"

  pid = spawn(cmd, out: '/dev/null', err: '/dev/null')
  begin
    # Falcon's boot is heavier than puma/hyperion; wait until the port answers.
    booted = false
    20.times do
      sleep 0.25
      booted = system("nc -z 127.0.0.1 #{port} > /dev/null 2>&1")
      break if booted
    end
    unless booted
      results[name] = "(skipped — #{name} did not bind to port #{port} within 5s)"
      next
    end
    output = `wrk --latency -t#{THREADS} -c#{CONNS} -d#{DURATION} http://127.0.0.1:#{port}/ 2>&1`
    results[name] = output
  ensure
    kill(pid)
  end
end

puts
puts '=' * 72
puts "Hyperion bench — duration=#{DURATION} threads=#{THREADS} conns=#{CONNS}"
puts '=' * 72
puts

results.each do |name, out|
  puts ">>> #{name}"
  puts out
  puts
end

# Parse wrk output for key numbers and print a comparison table.
def parse_wrk(output)
  return nil if output.start_with?('(skipped')

  rps = output[%r{Requests/sec:\s+([\d.]+)}, 1]&.to_f
  p99 = output[/99%\s+([\d.]+)(\w+)/, 1]
  p99_unit = output[/99%\s+([\d.]+)(\w+)/, 2]
  { rps: rps, p99: p99, p99_unit: p99_unit }
end

puts
puts '=' * 72
puts 'SUMMARY'
puts '=' * 72
printf("  %-10s  %12s  %12s\n", 'server', 'req/sec', 'p99 latency')
printf("  %-10s  %12s  %12s\n", '-' * 10, '-' * 12, '-' * 12)
results.each do |name, out|
  parsed = parse_wrk(out)
  if parsed && parsed[:rps]
    printf("  %-10s  %12.1f  %12s\n", name, parsed[:rps], "#{parsed[:p99]}#{parsed[:p99_unit]}")
  else
    printf("  %-10s  %12s  %12s\n", name, '(skipped)', '-')
  end
end
puts
