# frozen_string_literal: true

# bench/keepalive_memory.rb — measures server RSS at N idle keep-alive
# connections to expose the fiber-vs-thread memory delta at high
# concurrency. Throughput is irrelevant here; what matters is whether
# the server can hold N idle conns without OOMing or dropping.
#
# Usage:
#   SERVER=hyperion N=10000 RACKUP=bench/hello.ru ruby bench/keepalive_memory.rb
#   SERVER=puma N=10000 ...
#   SERVER=falcon N=10000 ...
#
# ENV:
#   SERVER       - hyperion | puma | falcon
#   N            - target idle connection count (default 10000)
#   PORT         - server port (default 19990)
#   RACKUP       - path to rackup file (default bench/hello.ru)
#   HOLD_SEC     - how long to hold idle conns (default 30)
#   THREADS      - server thread count for puma/hyperion (hyperion default 5, puma default 100)
#   FALCON_COUNT - falcon --count (default 1)
#
# Linux only — uses /proc/<pid>/status for RSS.

require 'socket'
require 'shellwords'
require 'json'
require 'timeout'

SERVER       = ENV.fetch('SERVER',       'hyperion')
N_TARGET     = ENV.fetch('N',            '10000').to_i
PORT         = ENV.fetch('PORT',         '19990').to_i
RACKUP       = ENV.fetch('RACKUP',       'bench/hello.ru')
HOLD_SEC     = ENV.fetch('HOLD_SEC',     '30').to_i
# Server-side concurrency knob. With --async-io, Hyperion's thread pool only
# matters for CPU-bound handlers; for hello-world idle keep-alive 5 is fine.
# Puma needs many more threads to actually accept N conns past the first
# `max_threads` (everything beyond it sits in the kernel listen queue and
# can never have its initial GET answered).
HYPERION_T   = ENV.fetch('HYPERION_THREADS', '5').to_i
PUMA_T       = ENV.fetch('PUMA_THREADS',     '100').to_i
FALCON_COUNT = ENV.fetch('FALCON_COUNT',     '1').to_i

OPENER_THREADS = ENV.fetch('OPENER_THREADS', '50').to_i
HOST           = '127.0.0.1'

IDLE_KEEPALIVE_BUDGET = HOLD_SEC + 120 # plenty of slack vs default 5/20/30s timeouts

# Write per-server config files so we can extend the idle keep-alive timeout
# above each server's default (hyperion 5s, puma 20s, falcon 30s). Without
# this, idle sockets die mid-bench and the RSS sample reflects post-close
# state instead of "N idle conns held."
def write_configs!(port)
  File.write('/tmp/hyperion_keepalive.rb', <<~CONFIG)
    bind '#{HOST}'
    port #{port}
    workers 1
    thread_count #{HYPERION_T}
    idle_keepalive #{IDLE_KEEPALIVE_BUDGET}
    read_timeout #{IDLE_KEEPALIVE_BUDGET}
    log_requests false
    async_io true
  CONFIG

  File.write('/tmp/puma_keepalive.rb', <<~CONFIG)
    bind 'tcp://#{HOST}:#{port}'
    threads #{PUMA_T}, #{PUMA_T}
    workers 0
    persistent_timeout #{IDLE_KEEPALIVE_BUDGET}
    first_data_timeout #{IDLE_KEEPALIVE_BUDGET}
    quiet
  CONFIG
end

# Returns [cmd_string, ready_check_proc, label] for the chosen server.
def server_command(server, port, rackup)
  case server
  when 'hyperion'
    # --async-io forces fiber-per-connection on plain HTTP/1.1 — the path that
    # holds N idle conns on N fibers (~1-4 KB each), not N OS threads.
    "hyperion -C /tmp/hyperion_keepalive.rb -p #{port} #{rackup}"
  when 'puma'
    "puma -C /tmp/puma_keepalive.rb #{rackup}"
  when 'falcon'
    # --timeout bumps the per-IO operation deadline; also extends idle keep-alive.
    "falcon serve --bind http://#{HOST}:#{port} --count #{FALCON_COUNT} " \
      "--timeout #{IDLE_KEEPALIVE_BUDGET} -c #{rackup}"
  else
    abort "unknown SERVER=#{server} (expected hyperion|puma|falcon)"
  end
end

# Read VmRSS in KB for a pid; returns nil if pid is gone or not on Linux.
def rss_kb(pid)
  status = File.read("/proc/#{pid}/status")
  m = status[/^VmRSS:\s+(\d+)\s+kB/]
  Regexp.last_match(1).to_i if m
rescue Errno::ENOENT, Errno::EACCES
  nil
end

# Walk /proc to find descendant PIDs of root_pid (so we capture worker procs
# too — Puma and Falcon both fork). Returns root_pid plus all descendants.
def descendant_pids(root_pid)
  parent_of = {}
  Dir.glob('/proc/[0-9]*').each do |dir|
    pid = File.basename(dir).to_i
    next if pid.zero?

    begin
      stat = File.read("#{dir}/stat")
      # comm field is in parens and may contain spaces — strip from end.
      after_comm = stat.sub(/\A\d+\s+\(.*?\)\s+\S+\s+/, '')
      ppid = after_comm.split(/\s+/, 2).first.to_i
      parent_of[pid] = ppid
    rescue Errno::ENOENT, Errno::EACCES
      next
    end
  end

  result = [root_pid]
  changed = true
  while changed
    changed = false
    parent_of.each do |child, parent|
      if result.include?(parent) && !result.include?(child)
        result << child
        changed = true
      end
    end
  end
  result
end

# Sum RSS across the whole process tree.
def rss_tree_kb(root_pid)
  total = 0
  any = false
  descendant_pids(root_pid).each do |pid|
    kb = rss_kb(pid)
    if kb
      total += kb
      any = true
    end
  end
  any ? total : nil
end

# Wait until the server answers an HTTP GET on PORT, or timeout.
def wait_for_server(port, timeout: 30)
  deadline = Time.now + timeout
  while Time.now < deadline
    begin
      Timeout.timeout(1) do
        s = TCPSocket.new(HOST, port)
        s.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        line = s.gets
        s.close
        return true if line && line.start_with?('HTTP/1.')
      end
    rescue StandardError
      # not ready yet
    end
    sleep 0.25
  end
  false
end

REQUEST_BYTES = "GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n".b
CONNECT_DEADLINE  = 2  # s; SYN→SYN-ACK ceiling. Defends against full listen queues.
RESPONSE_DEADLINE = 5  # s; per-connection ceiling for first response.

# Read up to `n` bytes (or until EOF) using IO.select for a wallclock deadline.
# Returns whatever was read (possibly empty); nil only if the deadline fires
# before any data arrives. Avoids the per-call Timeout-thread overhead that
# stalls when 1000 opener invocations spin up 1000 supervisor threads.
def read_with_deadline(sock, deadline_at, max: nil)
  buf = +''
  loop do
    remaining = deadline_at - Time.now
    return nil if remaining <= 0

    ready = IO.select([sock], nil, nil, remaining)
    return nil unless ready

    begin
      chunk = sock.read_nonblock(max ? [max - buf.bytesize, 65_536].min : 65_536)
    rescue IO::WaitReadable
      next
    rescue EOFError
      return buf
    end
    buf << chunk
    return buf if max && buf.bytesize >= max

    return buf if block_given? && block_given? && yield(buf)
  end
end

# Open a single keep-alive socket: send one GET, drain the response, return the
# socket without closing it. Returns nil on failure.
def open_idle_keepalive(port)
  sock = Socket.tcp(HOST, port, connect_timeout: CONNECT_DEADLINE)
  sock.sync = true
  sock.write(REQUEST_BYTES)

  deadline = Time.now + RESPONSE_DEADLINE

  # Read until headers end (CRLFCRLF). Use IO.select for the deadline.
  headers = +''
  done_headers = false
  loop do
    remaining = deadline - Time.now
    raise 'response timeout (headers)' if remaining <= 0

    ready = IO.select([sock], nil, nil, remaining)
    raise 'response timeout (headers/select)' unless ready

    begin
      chunk = sock.read_nonblock(4096)
    rescue IO::WaitReadable
      next
    rescue EOFError
      raise 'EOF in headers'
    end
    headers << chunk
    if headers.include?("\r\n\r\n")
      done_headers = true
      break
    end
  end
  raise 'no header terminator' unless done_headers

  cl = headers[/^Content-Length:\s*(\d+)/i, 1]&.to_i
  transfer_chunked = headers =~ /^Transfer-Encoding:\s*chunked/i
  body_already = headers[(headers.index("\r\n\r\n") + 4)..].bytesize

  if cl && cl.positive?
    remaining_bytes = cl - body_already
    while remaining_bytes.positive?
      slice = read_with_deadline(sock, deadline, max: remaining_bytes)
      raise 'response timeout (body)' if slice.nil?

      remaining_bytes -= slice.bytesize
    end
  elsif transfer_chunked
    # Best-effort drain; hello-world responses use Content-Length so this is
    # a safety branch — we ignore the timeout intricacies here.
    loop do
      size_line = +''
      until size_line.end_with?("\r\n")
        c = sock.read(1)
        break if c.nil?

        size_line << c
      end
      size = size_line.strip.to_i(16)
      break if size.zero?

      sock.read(size + 2)
    end
  end

  sock
rescue StandardError
  begin
    sock&.close
  rescue StandardError
    nil
  end
  nil
end

def open_connections(port, n)
  per_thread = (n.to_f / OPENER_THREADS).ceil
  sockets = []
  mutex = Mutex.new
  drops = 0

  threads = Array.new(OPENER_THREADS) do |i|
    Thread.new do
      slice_count = [per_thread, n - (i * per_thread)].min
      next if slice_count <= 0

      slice_count.times do
        s = open_idle_keepalive(port)
        if s
          mutex.synchronize { sockets << s }
        else
          mutex.synchronize { drops += 1 }
        end
      end
    end
  end
  threads.each(&:join)

  [sockets, drops]
end

def close_all(sockets)
  closed = 0
  sockets.each do |s|
    s.close
    closed += 1
  rescue StandardError
    # already broken — count as closed so we don't loop
    closed += 1
  end
  closed
end

write_configs!(PORT)
cmd = server_command(SERVER, PORT, RACKUP)
warn "[bench] starting #{SERVER}: #{cmd}"
warn "[bench] target N=#{N_TARGET}, hold=#{HOLD_SEC}s, idle_budget=#{IDLE_KEEPALIVE_BUDGET}s"

server_pid = Process.spawn(cmd, out: '/dev/null', err: '/dev/null', pgroup: true)

trap_handler = proc do
  begin
    Process.kill('-TERM', server_pid)
  rescue StandardError
    nil
  end
  exit 130
end
trap('INT',  &trap_handler)
trap('TERM', &trap_handler)

begin
  unless wait_for_server(PORT, timeout: 30)
    warn "[bench] #{SERVER} failed to bind on #{PORT}"
    exit 2
  end
  warn "[bench] #{SERVER} ready (pid=#{server_pid})"
  sleep 1 # let any post-boot allocations settle

  baseline_rss_kb = rss_tree_kb(server_pid)
  warn "[bench] baseline RSS: #{baseline_rss_kb} kB"

  open_t0 = Time.now
  sockets, drops = open_connections(PORT, N_TARGET)
  open_dt = Time.now - open_t0
  warn format('[bench] opened %<got>d/%<want>d sockets in %<dt>.2fs (drops=%<drops>d)',
              got: sockets.size, want: N_TARGET, dt: open_dt, drops: drops)

  # Sample RSS for HOLD_SEC seconds while connections are idle.
  samples = []
  HOLD_SEC.times do
    sleep 1
    kb = rss_tree_kb(server_pid)
    samples << kb if kb
  end
  peak_rss_kb = samples.max
  warn format('[bench] peak RSS during idle hold: %<kb>d kB (samples=%<n>d)',
              kb: peak_rss_kb || 0, n: samples.size)

  # Drain.
  closed = close_all(sockets)
  warn "[bench] closed #{closed} sockets"
  sleep 2
  drained_rss_kb = rss_tree_kb(server_pid)
  warn "[bench] post-drain RSS: #{drained_rss_kb} kB"

  summary = {
    server: SERVER,
    target_n: N_TARGET,
    succeeded: sockets.size,
    dropped: drops,
    open_seconds: open_dt.round(2),
    hold_seconds: HOLD_SEC,
    baseline_rss_kb: baseline_rss_kb,
    peak_rss_kb: peak_rss_kb,
    drained_rss_kb: drained_rss_kb,
    rss_samples_kb: samples
  }

  puts
  puts '=' * 72
  puts format('SERVER=%-9s  N=%-6d  held=%-6d  dropped=%-6d',
              SERVER, N_TARGET, sockets.size, drops)
  puts format('  baseline_rss = %d MB', ((baseline_rss_kb || 0) / 1024.0).round(1))
  puts format('  peak_rss     = %d MB', ((peak_rss_kb || 0) / 1024.0).round(1))
  puts format('  drained_rss  = %d MB', ((drained_rss_kb || 0) / 1024.0).round(1))
  puts '=' * 72
  puts JSON.generate(summary)
ensure
  begin
    Process.kill('-TERM', server_pid)
  rescue StandardError
    nil
  end
  begin
    Timeout.timeout(5) { Process.waitpid(server_pid) }
  rescue Timeout::Error
    begin
      Process.kill('-KILL', server_pid)
    rescue StandardError
      nil
    end
    begin
      Process.waitpid(server_pid)
    rescue StandardError
      nil
    end
  rescue Errno::ECHILD
    nil
  end
end
