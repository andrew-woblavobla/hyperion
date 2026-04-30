# frozen_string_literal: true

# 2.4-B — allocation site attribution via ObjectSpace.allocation_sourcefile.
#
# Drives the four hot paths (HTTP keep-alive, chunked POST parse, WS recv,
# WS send with permessage-deflate) under ObjectSpace.trace_object_allocations
# and reports the top allocation sites by file:line so we can identify the
# concrete sites to fix.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
ENV['HYPERION_LOG_REQUESTS'] ||= '0'
require 'hyperion'
require 'objspace'
require 'socket'

ITERATIONS = (ENV['ITERATIONS'] || '2000').to_i
MODE       = ENV['MODE'] || 'http'

# Use ObjectSpace.trace_object_allocations + take a snapshot DURING tracing
# (vs after-the-fact). We pause GC during the traced block so transients
# stay live and attributable.
def trace_block(&block)
  ObjectSpace.trace_object_allocations_clear
  GC.start
  GC.disable
  ObjectSpace.trace_object_allocations(&block)
  collect_snapshot
ensure
  GC.enable
end

$snapshot_counts = nil
$snapshot_classes = nil

def collect_snapshot
  counts = Hash.new(0)
  classes = Hash.new(0)
  ObjectSpace.each_object do |o|
    file = ObjectSpace.allocation_sourcefile(o)
    line = ObjectSpace.allocation_sourceline(o)
    next unless file
    next if file.end_with?('gc_audit_2_4_b_trace.rb')
    next unless file.include?('/hyperion') || file.include?('hyperion-rb')

    key = "#{file.sub(%r{.*/(?:lib|ext|gems)/}, '')}:#{line}"
    counts[key] += 1
    classes["#{key}\t#{o.class}"] += 1
  rescue StandardError
    next
  end
  $snapshot_counts = counts
  $snapshot_classes = classes
end

def report_top_sites(top_n: 25)
  puts "  Top #{top_n} allocation sites (file:line — count):"
  $snapshot_counts.sort_by { |_, v| -v }.first(top_n).each do |key, n|
    cls_breakdown = $snapshot_classes.select { |k, _| k.start_with?("#{key}\t") }
                                     .sort_by { |_, v| -v }
                                     .first(3)
                                     .map { |k, v| "#{k.split("\t").last}=#{v}" }
                                     .join(' ')
    puts format('    %7d  %s    [%s]', n, key, cls_breakdown)
  end
end

# ---------------------------------------------------------------------------
# HTTP keep-alive path (Connection.serve)
# ---------------------------------------------------------------------------
def trace_http(iterations)
  app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
  tcp_server = TCPServer.new('127.0.0.1', 0)
  port = tcp_server.addr[1]
  done = false
  acceptor = Thread.new do
    until done
      begin
        client = tcp_server.accept_nonblock
      rescue IO::WaitReadable
        IO.select([tcp_server], nil, nil, 0.05)
        next
      rescue IOError
        break
      end
      conn = Hyperion::Connection.new
      Thread.new(client) { |c| conn.serve(c, app) }
    end
  rescue StandardError
    # noop
  end

  request_bytes = "GET /a HTTP/1.1\r\nhost: x\r\nconnection: keep-alive\r\nuser-agent: bench\r\n\r\n"

  socket_count = 50
  per_socket = iterations / socket_count
  sockets = Array.new(socket_count) { TCPSocket.new('127.0.0.1', port) }

  # Warm up
  sockets.each do |s|
    s.write(request_bytes)
    drain(s)
  end

  trace_block do
    per_socket.times do
      sockets.each do |s|
        s.write(request_bytes)
        drain(s)
      end
    end
  end

  puts "[http GET keep-alive — #{iterations} iters]"
  report_top_sites
  puts

  sockets.each(&:close)
  done = true
  begin
    tcp_server.close
  rescue StandardError
    # noop
  end
  acceptor.join(1)
end

def drain(socket)
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
      return data if data.bytesize > 100 && data.include?("\r\n\r\nok")
    end
  end
rescue StandardError
  data
end

# ---------------------------------------------------------------------------
# Chunked-body parser path
# ---------------------------------------------------------------------------
def trace_chunked(iterations)
  parser = Hyperion::Connection.send(:default_parser)
  body = "40\r\n#{'a' * 64}\r\n40\r\n#{'b' * 64}\r\n40\r\n#{'c' * 64}\r\n40\r\n#{'d' * 64}\r\n0\r\n\r\n"
  request = "POST /upload HTTP/1.1\r\nhost: x\r\ntransfer-encoding: chunked\r\n\r\n#{body}"

  100.times { parser.parse(request.dup) }

  trace_block do
    iterations.times { parser.parse(request.dup) }
  end

  puts "[chunked POST parser — #{iterations} iters]"
  report_top_sites
  puts
end

# ---------------------------------------------------------------------------
# WebSocket recv path
# ---------------------------------------------------------------------------
def trace_ws(iterations)
  require 'hyperion/websocket/connection'
  s_server, s_client = Socket.pair(:UNIX, :STREAM)
  ws = Hyperion::WebSocket::Connection.new(s_server, ping_interval: nil, idle_timeout: nil)
  payload = 'hello world this is a sample chat message with normal length'
  client_frame = Hyperion::WebSocket::Builder.build(opcode: :text, payload: payload, mask: true,
                                                    mask_key: "\x01\x02\x03\x04".b)

  100.times do
    s_client.write(client_frame)
    ws.recv
  end

  trace_block do
    iterations.times do
      s_client.write(client_frame)
      ws.recv
    end
  end

  puts "[WebSocket recv — #{iterations} iters]"
  report_top_sites
  puts
ensure
  s_client&.close
  s_server&.close
end

# ---------------------------------------------------------------------------
# WS send with permessage-deflate
# ---------------------------------------------------------------------------
def trace_ws_deflate(iterations)
  require 'hyperion/websocket/connection'
  s_server, s_client = Socket.pair(:UNIX, :STREAM)
  ws = Hyperion::WebSocket::Connection.new(s_server, ping_interval: nil, idle_timeout: nil,
                                                     extensions: { permessage_deflate: {} })
  payload = ('hello world this is a sample chat message with normal length' * 4)

  100.times do
    ws.send(payload, opcode: :text)
    s_client.read_nonblock(65_536, exception: false) while s_client.ready?
  rescue StandardError
    # noop
  end

  trace_block do
    iterations.times do
      ws.send(payload, opcode: :text)
      s_client.read_nonblock(65_536, exception: false) while s_client.ready?
    rescue StandardError
      # noop
    end
  end

  puts "[WS send w/ permessage-deflate — #{iterations} iters]"
  report_top_sites
  puts
ensure
  s_client&.close
  s_server&.close
end

case MODE
when 'http'        then trace_http(ITERATIONS)
when 'chunked'     then trace_chunked(ITERATIONS)
when 'ws'          then trace_ws(ITERATIONS)
when 'ws_deflate'  then trace_ws_deflate(ITERATIONS)
when 'all'
  trace_http(ITERATIONS / 4)
  trace_chunked(ITERATIONS)
  trace_ws(ITERATIONS)
  trace_ws_deflate(ITERATIONS / 2)
else
  warn "unknown MODE=#{MODE}, expected http|chunked|ws|ws_deflate|all"
  exit 1
end
