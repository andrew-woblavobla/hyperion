# frozen_string_literal: true

# 2.4-B — long-run GC pressure audit.
#
# The Phase 11 audit (bench/yjit_alloc_audit.rb) measures per-request
# Adapter::Rack hot path allocations. That number is locked at 9 obj/req
# by yjit_alloc_audit_spec. But the *server* hot path includes more than
# the adapter — the Connection read loop, parser, and (for WS workloads)
# the frame ser/de + permessage-deflate path. This harness drives those
# end-to-end at sustained rate over many keep-alive connections so we
# can spot allocation sites that scale with **message rate**, not just
# request count.
#
# Reports:
#   * total_allocated_objects delta / total messages → avg per message
#   * GC.stat[:count]/[:major_gc_count] over the window
#   * ObjectSpace.count_objects deltas (T_STRING / T_HASH / T_ARRAY)
#
# Usage:
#   ruby bench/gc_audit_2_4_b.rb                     # default 10k req
#   ITERATIONS=50000 ruby bench/gc_audit_2_4_b.rb
#   MODE=ws ruby bench/gc_audit_2_4_b.rb             # WebSocket workload
#   MODE=chunked ruby bench/gc_audit_2_4_b.rb        # chunked-body POST

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
ENV['HYPERION_LOG_REQUESTS'] ||= '0'
require 'hyperion'
require 'socket'
require 'objspace'

# Silence anything that may have already initialized
Hyperion.logger.instance_variable_set(:@level, ::Logger::ERROR) if Hyperion.respond_to?(:logger)

ITERATIONS = (ENV['ITERATIONS'] || '10000').to_i
MODE       = ENV['MODE'] || 'http'

# ---------------------------------------------------------------------------
# Capture all GC.stat / ObjectSpace.count_objects fields we care about.
# ---------------------------------------------------------------------------
def snapshot
  GC.start
  {
    total_allocated: GC.stat(:total_allocated_objects),
    gc_count: GC.stat(:count),
    major_gc_count: GC.stat(:major_gc_count),
    objects: ObjectSpace.count_objects.dup
  }
end

def diff(before, after, iterations)
  obj_keys = %i[T_STRING T_HASH T_ARRAY T_OBJECT]
  obj_diff = obj_keys.each_with_object({}) do |k, acc|
    acc[k] = (after[:objects][k] || 0) - (before[:objects][k] || 0)
  end
  {
    total_allocated: after[:total_allocated] - before[:total_allocated],
    avg_per_iter: (after[:total_allocated] - before[:total_allocated]).fdiv(iterations),
    gc_count: after[:gc_count] - before[:gc_count],
    major_gc_count: after[:major_gc_count] - before[:major_gc_count],
    object_deltas: obj_diff
  }
end

def print_report(label, before, after, iterations)
  d = diff(before, after, iterations)
  puts "[#{label}]"
  puts "  iterations:                      #{iterations}"
  puts "  total_allocated_objects delta:   #{d[:total_allocated]}"
  puts "  avg objects/iter:                #{d[:avg_per_iter].round(3)}"
  puts "  GC.count delta:                  #{d[:gc_count]} (one GC per ~#{iterations / [d[:gc_count], 1].max} iters)"
  puts "  GC.major_gc_count delta:         #{d[:major_gc_count]}"
  puts '  ObjectSpace.count_objects delta:'
  d[:object_deltas].each { |k, v| puts "    #{k.to_s.ljust(10)} #{v}" }
  puts
end

# =========================================================================
# MODE: http — drives Hyperion::Connection over a Socket.pair across
# many keep-alive requests, with two scenarios:
#   * Small GET (typical wrk hello) — measures the steady-state hot path
#   * Chunked POST with 4 chunks — exercises the chunked-body parser path
# =========================================================================
def run_http_audit(iterations)
  app = lambda do |_env|
    [200, { 'content-type' => 'text/plain' }, ['ok']]
  end

  tcp_server = TCPServer.new('127.0.0.1', 0)
  port = tcp_server.addr[1]
  done = false
  server_thread = Thread.new do
    until done
      begin
        client = tcp_server.accept_nonblock
      rescue IO::WaitReadable
        IO.select([tcp_server], nil, nil, 0.05)
        next
      end
      conn = Hyperion::Connection.new
      Thread.new(client) { |c| conn.serve(c, app) }
    end
  end

  request_bytes = "GET /a HTTP/1.1\r\nhost: x\r\nconnection: keep-alive\r\nuser-agent: bench\r\n\r\n"

  socket_count = 100
  per_socket = iterations / socket_count
  sockets = Array.new(socket_count) { TCPSocket.new('127.0.0.1', port) }

  # Warm up — fill caches, lazy paths
  sockets.each do |s|
    s.write(request_bytes)
    drain_response(s)
  end

  before = snapshot
  per_socket.times do
    sockets.each do |s|
      s.write(request_bytes)
      drain_response(s)
    end
  end
  after = snapshot

  print_report("http GET keep-alive (#{socket_count} conns × #{per_socket} req)",
               before, after, iterations)

  sockets.each(&:close)
  done = true
  begin
    tcp_server.close
  rescue StandardError
    # noop
  end
  server_thread.join(1)
end

def drain_response(socket)
  data = +''
  loop do
    chunk = socket.read_nonblock(4096, exception: false)
    case chunk
    when :wait_readable
      IO.select([socket], nil, nil, 0.5)
      next
    when nil
      return data
    else
      data << chunk
      return data if data.include?("\r\n\r\n") && (data.include?("\r\nok") || data.bytesize > 200)
    end
  end
rescue StandardError
  data
end

# =========================================================================
# MODE: chunked — drives chunked-body POST at the parser level (no socket).
# This isolates the chunked_body_complete? + parser allocations.
# =========================================================================
def run_chunked_audit(iterations)
  parser = Hyperion::Connection.send(:default_parser)

  # 4-chunk request body, each chunk 64 bytes.
  body = "40\r\n#{'a' * 64}\r\n40\r\n#{'b' * 64}\r\n40\r\n#{'c' * 64}\r\n40\r\n#{'d' * 64}\r\n0\r\n\r\n"
  request = "POST /upload HTTP/1.1\r\nhost: x\r\ntransfer-encoding: chunked\r\n\r\n#{body}"

  # warmup
  100.times { parser.parse(request.dup) }

  before = snapshot
  iterations.times { parser.parse(request.dup) }
  after = snapshot

  print_report("chunked POST parse (#{iterations} parses)", before, after, iterations)
end

# =========================================================================
# MODE: ws — drives WebSocket frame parse + send through a real
# Hyperion::WebSocket::Connection over a socket pair, simulating a chat-
# style burst at high message rate.
# =========================================================================
def run_ws_audit(iterations)
  require 'hyperion/websocket/connection'

  s_server, s_client = Socket.pair(:UNIX, :STREAM)
  ws = Hyperion::WebSocket::Connection.new(s_server, ping_interval: nil, idle_timeout: nil)

  # Build the wire bytes for a single masked text frame from client → server.
  payload = 'hello world this is a sample chat message with normal length'

  # Pre-build a masked client frame.
  mask_key = "\x01\x02\x03\x04".b
  client_frame = Hyperion::WebSocket::Builder.build(opcode: :text, payload: payload, mask: true,
                                                    mask_key: mask_key)

  # Warmup
  100.times do
    s_client.write(client_frame)
    type, msg = ws.recv
    raise unless type == :text && msg == payload
  end

  before = snapshot
  iterations.times do
    s_client.write(client_frame)
    type, _msg = ws.recv
    raise 'unexpected close' if type != :text
  end
  after = snapshot

  print_report("WebSocket recv (text, #{payload.bytesize}B payload, #{iterations} msgs)",
               before, after, iterations)

  # Also exercise the send path (server → client compressed)
  Hyperion::WebSocket::Builder.build(opcode: :text, payload: payload)
ensure
  s_client&.close
  s_server&.close
end

# =========================================================================
# MODE: ws_deflate — same as ws but with permessage-deflate active.
# =========================================================================
def run_ws_deflate_audit(iterations)
  require 'hyperion/websocket/connection'

  s_server, s_client = Socket.pair(:UNIX, :STREAM)

  # Server-side deflate: client sends UNCOMPRESSED frames (RFC 7692 lets
  # either side opt out per direction). For a fair audit we mostly care
  # about the SEND side allocation, since the C ext drives recv.
  ws = Hyperion::WebSocket::Connection.new(s_server, ping_interval: nil, idle_timeout: nil,
                                                     extensions: { permessage_deflate: {} })

  payload = 'hello world this is a sample chat message with normal length' * 4

  before = snapshot
  iterations.times do
    ws.send(payload, opcode: :text)
    # Drain client side so the kernel buffer doesn't fill.
    s_client.read_nonblock(65_536, exception: false) while s_client.ready?
  rescue StandardError
    # noop
  end
  after = snapshot

  print_report("WebSocket send w/ permessage-deflate (#{iterations} msgs)",
               before, after, iterations)
ensure
  s_client&.close
  s_server&.close
end

# =========================================================================
# Driver
# =========================================================================
puts "Hyperion #{Hyperion::VERSION} 2.4-B GC audit"
puts "  ruby:        #{RUBY_DESCRIPTION}"
puts "  yjit:        #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}"
puts "  iterations:  #{ITERATIONS}"
puts "  mode:        #{MODE}"
puts

case MODE
when 'http'      then run_http_audit(ITERATIONS)
when 'chunked'   then run_chunked_audit(ITERATIONS)
when 'ws'        then run_ws_audit(ITERATIONS)
when 'ws_deflate' then run_ws_deflate_audit(ITERATIONS)
when 'all'
  run_http_audit(ITERATIONS / 2)
  run_chunked_audit(ITERATIONS)
  run_ws_audit(ITERATIONS)
  run_ws_deflate_audit(ITERATIONS / 2)
else
  warn "unknown MODE=#{MODE}, expected http|chunked|ws|ws_deflate|all"
  exit 1
end
