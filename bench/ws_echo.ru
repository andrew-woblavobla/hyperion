# frozen_string_literal: true

# Minimal WebSocket echo server for benchmarking Hyperion's WS wrapper.
#
#   Run:   bundle exec hyperion --async-io -t 5 -w 1 -p 9888 bench/ws_echo.rb
#   Bench: see docs/WEBSOCKETS.md "Performance note" — target shape on the
#          openclaw-vm 16 vCPU bench host is 50,000+ msg/s on 1 worker
#          with p99 < 5 ms for 1 KB messages, driven via websocat or
#          autobahn-testsuite. Local dev hardware p50 round-trip ~0.18 ms
#          per the WS-4 e2e smoke (spec/hyperion/websocket_e2e_spec.rb).
#
# Same shape as the e2e smoke test app from the WS-4 spec, hardened for
# long bench runs:
#
#   - ping_interval: nil + idle_timeout: nil      (don't fight the bench client)
#   - infinite recv loop                          (bench drives connection lifetime)
#   - close echo handled by the wrapper           (clean disconnects on Ctrl-C)
#   - max_message_bytes: 16 KiB                   (bench payloads are 1 KiB
#                                                  worst case; cap defends
#                                                  against accidental floods)
#
# This file is intentionally narrow — it boots a WS server and echoes
# messages back. Anything else (TLS, multi-route dispatch, framing
# customisation) belongs in your own app.

require 'hyperion'
require 'hyperion/websocket/connection'

# 2.3-C: when HYPERION_WS_DEFLATE=on, the bench app advertises
# permessage-deflate in its 101 response (via the negotiated extensions
# slot from `Hyperion::WebSocket::Handshake.validate`) and instructs the
# Connection to deflate outbound frames. The bench client must also
# negotiate the extension (Sec-WebSocket-Extensions request header) for
# the wire-bytes saving to materialize.
DEFLATE_BENCH = ENV.fetch('HYPERION_WS_DEFLATE', 'off') != 'off'

run lambda { |env|
  result = env['hyperion.websocket.handshake']
  return [400, { 'content-type' => 'text/plain' }, ['expected ws upgrade']] unless result && result.first == :ok

  accept_value = result[1]
  subprotocol = result[2]
  extensions = result[3] || {}
  ext_header = Hyperion::WebSocket::Handshake.format_extensions_header(extensions)
  extra_headers = ext_header ? { 'sec-websocket-extensions' => ext_header } : {}

  socket = env['rack.hijack'].call
  socket.write(
    Hyperion::WebSocket::Handshake.build_101_response(accept_value, subprotocol, extra_headers)
  )

  ws = Hyperion::WebSocket::Connection.new(
    socket,
    buffered: env['hyperion.hijack_buffered'],
    subprotocol: subprotocol,
    max_message_bytes: 16 * 1024,
    ping_interval: nil,
    idle_timeout: nil,
    extensions: DEFLATE_BENCH ? extensions : {}
  )

  loop do
    type, payload = ws.recv
    break if type.nil? || type == :close

    ws.send(payload, opcode: type)
  end

  ws.close(code: 1000, drain_timeout: 1) unless ws.closed?
  [-1, {}, []]
}
