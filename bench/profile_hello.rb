# frozen_string_literal: true

# Profile harness for the bench/hello.ru workload. Boots Hyperion under
# stackprof control via signals: send SIGUSR1 to start sampling, SIGUSR2
# to stop and dump.
#
# Usage:
#   bundle exec ruby bench/profile_hello.rb [output.dump]
#
# After the run:
#   bundle exec stackprof --text /tmp/profile.dump | head -30
#   bundle exec stackprof --method 'Hyperion::Adapter::Rack#call' /tmp/profile.dump
#
# Mode selection via STACKPROF_MODE env (default: cpu):
#   :cpu    - CPU samples (best for hot-path attribution)
#   :wall   - wallclock samples (good for I/O-heavy paths)
#   :object - allocation samples (count of allocs per method)
#
# Workflow:
#   1. Start the harness:    bundle exec ruby bench/profile_hello.rb /tmp/p.dump
#   2. Wait for "READY" line, note the PID
#   3. Send SIGUSR1 to start: kill -USR1 <pid>
#   4. Drive load:           wrk -t4 -c100 -d30s http://127.0.0.1:9810/
#   5. Send SIGUSR2 to dump: kill -USR2 <pid>
#   6. Stop the server:      kill <pid>
#   7. Inspect:              bundle exec stackprof --text /tmp/p.dump | head -30

require 'stackprof'

out_path = ARGV[0] || '/tmp/profile.dump'
mode     = (ENV['STACKPROF_MODE'] || 'cpu').to_sym

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'hyperion'
require 'rack'
require 'rack/builder'

app, _ = Rack::Builder.parse_file(File.expand_path('hello.ru', __dir__))

pid = Process.pid
$stdout.sync = true
puts "READY pid=#{pid} mode=#{mode} out=#{out_path}"
puts "  start sampling: kill -USR1 #{pid}"
puts "  stop+dump:      kill -USR2 #{pid}"

trap('USR1') do
  StackProf.start(mode: mode, raw: true, interval: 1000)
  puts "[#{Time.now}] stackprof START"
end

trap('USR2') do
  StackProf.stop
  StackProf.results(out_path)
  puts "[#{Time.now}] stackprof STOP -> dumped to #{out_path}"
end

server_thread = Thread.new { Hyperion::Server.new(app: app, host: '127.0.0.1', port: 9810).start }
server_thread.join
