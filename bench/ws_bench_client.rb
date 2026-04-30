# frozen_string_literal: true

# Ruby-only WebSocket bench client for Hyperion's `bench/ws_echo.rb`.
#
# Why Ruby? The gem already owns the WS framing primitives (WS-3:
# `Hyperion::WebSocket::Frame`); a client implemented on top of those
# primitives shares the masking / parsing code with the server side, has
# zero external dependencies, and lets us drop into a Linux CI box
# without dragging in `websocat` / cargo / pip toolchains.
#
# Two scenarios, both 1 KiB messages:
#
#   --conns 10  --msgs 1000     # latency probe: per-conn round-trip percentiles
#   --conns 200 --msgs 1000     # throughput probe: aggregate msg/s
#
# Each connection runs in its own thread on its own TCPSocket. The client
# writes a masked frame and blocks reading the server's unmasked echo
# back; per-message wall time is captured with `Process::CLOCK_MONOTONIC`.
# After all threads finish we aggregate per-message latencies and print
# JSONL + a human summary.
#
# Usage:
#
#   # Server (separate terminal):
#   bundle exec hyperion -t 5 -w 1 -p 9888 bench/ws_echo.rb
#
#   # Client:
#   ruby bench/ws_bench_client.rb --host 127.0.0.1 --port 9888 \
#                                 --conns 10 --msgs 1000 --bytes 1024
#
# The script intentionally lives outside the runtime gem surface — it's
# a developer / bench tool, not loaded by `require 'hyperion'`.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'hyperion/websocket/frame'
require 'socket'
require 'base64'
require 'securerandom'
require 'optparse'
require 'json'

module Hyperion
  module Bench
    # Tight WebSocket client with one TCPSocket + one Ruby thread per
    # connection. Each thread loops `msgs` times, sending a masked text
    # frame of `bytes` bytes and reading the server's unmasked echo back
    # before timing the round-trip.
    #
    # Returns:
    #   {
    #     elapsed: Float seconds,
    #     latencies_ms: [Float, ...]   # one per (conn × msg)
    #   }
    class WsBenchClient
      def initialize(host:, port:, conns:, msgs:, bytes:, path: '/echo')
        @host = host
        @port = Integer(port)
        @conns = Integer(conns)
        @msgs = Integer(msgs)
        @bytes = Integer(bytes)
        @path = path
      end

      def run
        latencies = Array.new(@conns)
        threads = Array.new(@conns) do |i|
          Thread.new do
            latencies[i] = run_one_connection
          rescue StandardError => e
            warn "[ws-bench][conn #{i}] #{e.class}: #{e.message}"
            latencies[i] = []
          end
        end

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        threads.each(&:join)
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        { elapsed: t1 - t0, latencies_ms: latencies.flatten }
      end

      private

      def run_one_connection
        sock = TCPSocket.new(@host, @port)
        upgrade(sock)

        rx_buf = String.new(encoding: Encoding::ASCII_8BIT)
        payload = ('x' * @bytes).b
        latencies = Array.new(@msgs)

        @msgs.times do |i|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          send_masked(sock, :text, payload)
          frame = recv_unmasked(sock, rx_buf)
          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          latencies[i] = (t1 - t0) * 1000.0
          raise "expected text frame, got #{frame.opcode}" unless frame.opcode == :text
          raise "echo mismatch on msg #{i}" if frame.payload.bytesize != @bytes
        end

        # Clean close — send 1000 / done, read the server's echo, then
        # tear the socket down. Avoids RST piling up on the server log.
        send_masked(sock, :close, "\x03\xe8".b + 'done'.b)
        begin
          recv_unmasked(sock, rx_buf, timeout: 1)
        rescue StandardError
          # Server may close before we read its echo; that's fine.
        end

        latencies
      ensure
        sock&.close
      end

      def upgrade(sock)
        key = Base64.strict_encode64(SecureRandom.bytes(16))
        sock.write(
          "GET #{@path} HTTP/1.1\r\n" \
          "Host: #{@host}:#{@port}\r\n" \
          "Upgrade: websocket\r\n" \
          "Connection: Upgrade\r\n" \
          "Sec-WebSocket-Key: #{key}\r\n" \
          "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        response = read_until(sock, "\r\n\r\n")
        return if response.start_with?('HTTP/1.1 101')

        raise "expected 101, got: #{response.lines.first&.strip}"
      end

      def read_until(sock, terminator, timeout: 5)
        buf = +''
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until buf.include?(terminator)
          raise 'timeout waiting for handshake response' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          ready, = IO.select([sock], nil, nil, 0.5)
          next unless ready

          chunk = sock.read_nonblock(4096, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable

          buf << chunk
        end
        buf
      end

      def send_masked(sock, opcode, payload)
        sock.write(
          Hyperion::WebSocket::Builder.build(
            opcode: opcode,
            payload: payload,
            mask: true,
            mask_key: SecureRandom.bytes(4)
          )
        )
      end

      def recv_unmasked(sock, buf, timeout: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          result =
            begin
              Hyperion::WebSocket::Parser.parse_with_cursor(buf, 0)
            rescue Hyperion::WebSocket::ProtocolError
              :error
            end

          if result.is_a?(Array)
            frame, advance = result
            buf.replace(buf.byteslice(advance, buf.bytesize - advance))
            return frame
          end

          raise 'frame parse error' if result == :error

          raise 'timeout reading frame' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          ready, = IO.select([sock], nil, nil, 0.5)
          next unless ready

          chunk = sock.read_nonblock(4096, exception: false)
          raise 'peer EOF before frame complete' if chunk.nil?
          next if chunk == :wait_readable

          buf << chunk
        end
      end
    end

    # Aggregate stats helper — straight-Ruby percentile calc; no
    # external dep on stats / numo / etc.
    module Percentile
      module_function

      def of(sorted_arr, p)
        return nil if sorted_arr.empty?

        idx = ((sorted_arr.size - 1) * p / 100.0).round
        sorted_arr[idx]
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { host: '127.0.0.1', port: 9888, conns: 10, msgs: 1000, bytes: 1024,
           path: '/echo', json: false }

  OptionParser.new do |o|
    o.banner = 'Usage: ruby bench/ws_bench_client.rb [options]'
    o.on('--host HOST')             { |v| opts[:host]  = v }
    o.on('--port PORT', Integer)    { |v| opts[:port]  = v }
    o.on('--conns N', Integer)      { |v| opts[:conns] = v }
    o.on('--msgs N', Integer)       { |v| opts[:msgs]  = v }
    o.on('--bytes N', Integer)      { |v| opts[:bytes] = v }
    o.on('--path PATH')             { |v| opts[:path]  = v }
    o.on('--json', 'Emit results as JSONL') { opts[:json] = true }
  end.parse!

  client = Hyperion::Bench::WsBenchClient.new(**opts.slice(:host, :port, :conns,
                                                           :msgs, :bytes, :path))
  result = client.run

  lats   = result[:latencies_ms].sort
  total  = lats.size
  p50    = Hyperion::Bench::Percentile.of(lats, 50)
  p99    = Hyperion::Bench::Percentile.of(lats, 99)
  pmax   = lats.last
  msg_s  = total / result[:elapsed]

  if opts[:json]
    puts({ host: opts[:host], port: opts[:port],
           conns: opts[:conns], msgs: opts[:msgs], bytes: opts[:bytes],
           total_msgs: total, elapsed_s: result[:elapsed],
           msg_per_s: msg_s, p50_ms: p50, p99_ms: p99, max_ms: pmax }.to_json)
  else
    puts "[ws-bench] conns=#{opts[:conns]} msgs/conn=#{opts[:msgs]} " \
         "bytes=#{opts[:bytes]} total=#{total}"
    puts "[ws-bench] elapsed=#{result[:elapsed].round(3)} s  msg/s=#{msg_s.round(0)}"
    puts "[ws-bench] p50=#{p50.round(3)} ms  p99=#{p99.round(3)} ms  " \
         "max=#{pmax.round(3)} ms"
  end
end
