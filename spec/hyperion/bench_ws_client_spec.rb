# frozen_string_literal: true

# Smoke for `bench/ws_bench_client.rb` — the Ruby WS bench client added
# in 2.2.x fix-E. Boots a real Hyperion server with the same WS echo
# rackup the bench uses (`bench/ws_echo.ru`-style app inlined here for
# spec hermeticity), runs 5 echo round-trips through `WsBenchClient`,
# and asserts the latencies vector + msg/s came out shaped right.
#
# No perf assertion — bench-host concerns belong on the bench host.
# This spec just guards "the client tool still composes against the
# server's full hijack + handshake + frame pipeline".

require 'hyperion'
require 'hyperion/websocket/connection'
require 'socket'

# Load the bench client without `-r`-style argv-running; the script
# guards on `$PROGRAM_NAME == __FILE__` so requiring it just defines
# the classes.
require_relative '../../bench/ws_bench_client'

RSpec.describe Hyperion::Bench::WsBenchClient do
  ECHO_APP_FOR_BENCH_SPEC = lambda do |env|
    result = env['hyperion.websocket.handshake']
    raise 'expected ws upgrade' unless result&.first == :ok

    socket = env['rack.hijack'].call
    socket.write(
      Hyperion::WebSocket::Handshake.build_101_response(result[1], result[2])
    )
    ws = Hyperion::WebSocket::Connection.new(
      socket,
      buffered: env['hyperion.hijack_buffered'],
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
  end

  def boot_server(app)
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app)
    server.listen
    port = server.port
    thread = Thread.new { server.start }

    deadline = Time.now + 2
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise "server didn't bind within 2s" if Time.now > deadline

      sleep 0.01
    end

    [server, port, thread]
  end

  def stop_server(server, thread)
    server&.stop
    thread&.join(2)
  end

  it 'exchanges 5 messages over 1 connection and reports latencies + msg/s' do
    server, port, thread = boot_server(ECHO_APP_FOR_BENCH_SPEC)

    client = described_class.new(host: '127.0.0.1', port: port,
                                 conns: 1, msgs: 5, bytes: 64)
    result = client.run

    expect(result[:latencies_ms].size).to eq(5)
    expect(result[:latencies_ms]).to all(be > 0)
    expect(result[:elapsed]).to be > 0

    msg_s = result[:latencies_ms].size / result[:elapsed]
    expect(msg_s).to be > 0
  ensure
    stop_server(server, thread)
  end

  it 'completes 2 concurrent connections cleanly' do
    server, port, thread = boot_server(ECHO_APP_FOR_BENCH_SPEC)

    client = described_class.new(host: '127.0.0.1', port: port,
                                 conns: 2, msgs: 3, bytes: 16)
    result = client.run

    # 2 conns × 3 msgs = 6 latency samples, all > 0.
    expect(result[:latencies_ms].size).to eq(6)
    expect(result[:latencies_ms]).to all(be > 0)
  ensure
    stop_server(server, thread)
  end
end

RSpec.describe Hyperion::Bench::Percentile do
  # The bench client uses round-half-up nearest-rank indexing
  # (`((n - 1) * p / 100.0).round`); for a 100-element array
  # 1..100 that puts p50 at index 50 (= value 51) and p99 at
  # index 98 (= value 99).
  it 'computes p50 / p99 / p100 with nearest-rank rounding' do
    sorted = (1..100).to_a
    expect(described_class.of(sorted, 50)).to eq(51)
    expect(described_class.of(sorted, 99)).to eq(99)
    expect(described_class.of(sorted, 100)).to eq(100)
  end

  it 'returns nil for an empty array' do
    expect(described_class.of([], 50)).to be_nil
  end

  it 'handles single-element arrays' do
    expect(described_class.of([42], 50)).to eq(42)
    expect(described_class.of([42], 99)).to eq(42)
  end
end
