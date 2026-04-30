# frozen_string_literal: true

# Autobahn-testsuite-friendly variant of `bench/ws_echo.ru`.
#
# Differences from `ws_echo.ru` (the plain bench rackup):
#
#   1. `max_message_bytes: 1 MiB` instead of 16 KiB. Autobahn cases
#      4.x / 5.x / 6.x / 12.x / 13.x ship payloads that comfortably
#      fit inside 1 MiB but exceed the bench's 16 KiB defensive cap.
#      Cases 9.* (16+ MiB) are still excluded via the fuzzingclient.
#
#   2. Renders the negotiated `Sec-WebSocket-Extensions` header into
#      the 101 response and passes the negotiated extension hash into
#      `Connection.new(extensions: ...)`. Without these two changes
#      the fuzzer marks every section-12/13 case as UNIMPLEMENTED
#      because the server never advertises permessage-deflate.
#
# Run (paired with `autobahn-config/fuzzingclient.json`):
#
#   HYPERION_WS_DEFLATE=on bundle exec hyperion -t 64 -w 1 -p 9888 \
#     bench/ws_echo_autobahn.ru
#
# See `docs/WEBSOCKETS.md` "RFC 6455 conformance — autobahn-testsuite"
# for the full recipe and last-run results.

require 'hyperion'
require 'hyperion/websocket/connection'

run lambda { |env|
  result = env['hyperion.websocket.handshake']
  unless result && result.first == :ok
    return [400, { 'content-type' => 'text/plain' }, ['expected ws upgrade']]
  end

  socket = env['rack.hijack'].call

  ext_value = Hyperion::WebSocket::Handshake.format_extensions_header(result[3])
  extras = ext_value ? { 'sec-websocket-extensions' => ext_value } : {}
  socket.write(
    Hyperion::WebSocket::Handshake.build_101_response(result[1], result[2], extras)
  )

  ws = Hyperion::WebSocket::Connection.new(
    socket,
    buffered: env['hyperion.hijack_buffered'],
    subprotocol: result[2],
    extensions: result[3],
    max_message_bytes: 1 * 1024 * 1024,
    ping_interval: nil,
    idle_timeout: nil
  )

  loop do
    type, payload = ws.recv
    break if type.nil? || type == :close

    ws.send(payload, opcode: type)
  end

  ws.close(code: 1000, drain_timeout: 1) unless ws.closed?
  [-1, {}, []]
}
