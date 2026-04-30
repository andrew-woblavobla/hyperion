# frozen_string_literal: true

# 2.3-C bench harness — measures wire bytes per message and msg/s for
# Hyperion::WebSocket::Connection with and without permessage-deflate.
#
# Why a local harness? The win for permessage-deflate is wire-bytes,
# not msg/s — and the msg/s number is dominated by the bench client's
# own framing cost and the loopback round-trip latency, both of which
# are unaffected by compression. So the smallest, most accurate
# measurement is to run the encode side directly with a controlled
# input shape (chat-style JSON, 1 KB random text, etc.) and read off
# what hits the socket.
#
# Run:
#
#   ruby bench/ws_deflate_bench.rb
#
# Reports: bytes_per_msg (uncompressed) vs bytes_per_msg (deflated).

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'hyperion'
require 'hyperion/websocket/connection'
require 'socket'
require 'json'
require 'benchmark'

CHAT_LIKE = lambda do |i|
  {
    type: 'message',
    user_id: 12_345 + (i % 100),
    chat_id: 'general',
    nick: 'jordan',
    body: "hey! how's it going? this is message #{i} of the bench. " \
          'I am sending normal chatty text here so the deflate dictionary ' \
          'has plenty of repeated tokens to compress. user-id and chat-id ' \
          'recur, "type":"message" recurs, the JSON braces and quotes ' \
          'recur — typical pubsub shape.',
    timestamp: Time.now.utc.iso8601(3) + i.to_s
  }.to_json
end

def measure(label, extensions, count: 1000)
  server, client = UNIXSocket.pair
  ws = Hyperion::WebSocket::Connection.new(
    server, ping_interval: nil, idle_timeout: nil,
            extensions: extensions
  )

  bytes = 0
  reader = Thread.new do
    buf = +''
    drained = 0
    while drained < count
      chunk = client.read_nonblock(64 * 1024, exception: false)
      if chunk == :wait_readable
        IO.select([client], nil, nil, 0.1)
        next
      end
      break if chunk.nil?

      buf << chunk.b
      bytes += chunk.bytesize
      offset = 0
      loop do
        result = Hyperion::WebSocket::Parser.parse_with_cursor(buf, offset)
        break if result == :incomplete

        _frame, advance = result
        offset += advance
        drained += 1
        break if drained >= count
      end
      buf = buf.byteslice(offset, buf.bytesize - offset).b
    end
  end

  total_payload = 0
  elapsed = Benchmark.realtime do
    count.times do |i|
      msg = CHAT_LIKE.call(i)
      total_payload += msg.bytesize
      ws.send(msg)
    end
    reader.join(5)
  end
  payload_bytes = total_payload

  ws.close(drain_timeout: 0)
  client.close
  reader.kill if reader.alive?

  per_msg = bytes.to_f / count
  msg_s = count / elapsed
  puts "[#{label}] count=#{count} elapsed=#{elapsed.round(3)}s msg/s=#{msg_s.round(0)} " \
       "wire_bytes=#{bytes} bytes/msg=#{per_msg.round(1)} app_bytes/msg=#{(payload_bytes / count.to_f).round(1)}"
  { count: count, elapsed_s: elapsed, msg_per_s: msg_s, wire_bytes: bytes,
    bytes_per_msg: per_msg, payload_bytes_per_msg: payload_bytes / count.to_f }
end

baseline = measure('plain (no deflate)', {})

deflated = measure('permessage-deflate', {
                     permessage_deflate: {
                       server_no_context_takeover: false,
                       client_no_context_takeover: false,
                       server_max_window_bits: 15,
                       client_max_window_bits: 15
                     }
                   })

ratio = baseline[:bytes_per_msg] / deflated[:bytes_per_msg]
puts ''
puts "Wire bytes saved: #{baseline[:bytes_per_msg].round(1)} → " \
     "#{deflated[:bytes_per_msg].round(1)} bytes/msg (#{ratio.round(2)}× smaller)"
puts "msg/s: #{baseline[:msg_per_s].round(0)} → #{deflated[:msg_per_s].round(0)} " \
     "(#{(deflated[:msg_per_s] / baseline[:msg_per_s] * 100).round(1)}% of baseline)"
