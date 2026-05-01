# frozen_string_literal: true

# 2.10-A — Agoo boot wrapper.
#
# Agoo's CLI doesn't accept a Rack rackup directly, so the
# 4-way harness shells into this script to get an apples-to-
# apples Rack request flow against the same hello.ru / etc.
# rackups the other three servers run.
#
# Usage:
#   ruby bench/agoo_boot.rb [rackup_path] [port] [thread_count]
#
# Defaults: hello.ru, 9810, 5 threads — matching the harness's
# -t 5 -w 1 budget for the other three servers.
#
# Notes:
# * Agoo::Server.handle_not_found(app) makes the parsed Rack
#   builder the catch-all handler. Agoo will service its own
#   pre-built response cache for any explicitly registered
#   routes (none here), then fall through to the Rack app for
#   everything else — that's exactly the path the harness wants
#   to measure (Agoo's pure-C HTTP core delivering a Rack
#   response back to the client).
# * Agoo logging is silenced (console=false, all states off);
#   we don't want the bench wall-clock to include log churn.

require 'agoo'
require 'rack'

rackup_path  = ARGV[0] || 'bench/hello.ru'
port         = (ARGV[1] || 9810).to_i
thread_count = (ARGV[2] || 5).to_i

Agoo::Log.configure(
  dir: '',
  console: false,
  classic: true,
  colorize: false,
  states: { INFO: false, DEBUG: false, request: false, response: false, error: true }
)

# Agoo's server-thread model:
#   thread_count: 0  -> Server.start blocks on the current thread
#                       (current thread runs the I/O loop directly).
#   thread_count: N  -> Server.start spawns N worker threads and
#                       RETURNS — the caller must keep the main
#                       thread alive itself, otherwise the process
#                       exits and nothing is listening.
#
# To match the harness's -t 5 budget AND keep the process alive,
# we spawn 5 worker threads (thread_count: 5) and then sleep the
# main thread on a Queue#pop. SIGINT / SIGTERM unblock it.
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
