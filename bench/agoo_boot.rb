# frozen_string_literal: true

# 2.10-A — Agoo boot wrapper, with SO_REUSEPORT multi-worker mode.
#
# Usage:
#   ruby bench/agoo_boot.rb [rackup] [port] [thread_count] [workers]
#
# Defaults: bench/hello.ru, 9810, 5 threads, 1 worker.
#
# When workers > 1, the main process forks `workers` children. Each
# child runs in single-worker mode and binds the same port via
# Linux SO_REUSEPORT (Agoo enables this by default on Linux). On
# macOS the kernel only delivers connections to the most-recently-
# bound socket, so the multi-worker mode is Linux-only practically;
# on macOS the children will start but only one will receive load.
#
# The parent forwards SIGINT/SIGTERM to the children and waits for
# them to exit so a single Ctrl-C / `kill PID` cleans the whole
# process group.

require 'agoo'
require 'rack'

rackup_path  = ARGV[0] || 'bench/hello.ru'
port         = (ARGV[1] || 9810).to_i
thread_count = (ARGV[2] || 5).to_i
workers      = (ARGV[3] || 1).to_i

if workers > 1
  child_pids = []
  workers.times do
    pid = fork do
      # Re-exec ourselves in single-worker mode. Easier than re-binding
      # the listener inside the same process.
      exec RbConfig.ruby, __FILE__, rackup_path, port.to_s, thread_count.to_s, '1'
    end
    child_pids << pid
  end
  shutdown = false
  %w[INT TERM].each do |sig|
    trap(sig) do
      shutdown = true
      child_pids.each { |pid| Process.kill(sig, pid) rescue nil }
    end
  end
  child_pids.each { |pid| Process.waitpid(pid) rescue nil }
  exit 0
end

Agoo::Log.configure(
  dir: '',
  console: false,
  classic: true,
  colorize: false,
  states: { INFO: false, DEBUG: false, request: false, response: false, error: true }
)

Agoo::Server.init(port, '.', thread_count: thread_count)

app, _options = Rack::Builder.parse_file(rackup_path)

Agoo::Server.handle_not_found(app)

Agoo::Server.start

shutdown = Queue.new
%w[INT TERM].each do |sig|
  trap(sig) { shutdown << sig }
end

shutdown.pop
begin
  Agoo.shutdown
rescue StandardError
  nil
end
