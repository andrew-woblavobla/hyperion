# frozen_string_literal: true

# Multi-process WS bench client for Hyperion's `bench/ws_echo.ru`.
#
# Why this exists. The single-process `bench/ws_bench_client.rb` (added
# in 2.2.x fix-E) drives all N WebSocket connections from a single Ruby
# process. With Ruby's GVL the per-message work (mask/unmask, frame
# parse, JSON copy, IO.select) serialises through one interpreter, so
# at 200 concurrent connections the *client* runs out of CPU before
# the server does. fix-E's openclaw-vm 200-conn row landed at
# 1,766 msg/s with p99 134 ms — the long tail there is client-side
# scheduler queueing, not server-side latency.
#
# This script forks N child processes and gives each a slice of the
# total connection count. Each child runs the existing
# `bench/ws_bench_client.rb` in `--json` mode (single JSON line on
# stdout) and the parent aggregates the results.
#
#   total_conns = procs * (conns_per_proc)
#
# Aggregation rules:
#
#   * total_msgs       = Σ child[total_msgs]
#   * elapsed_s        = max(child[elapsed_s])     # wall-clock; clients run in parallel
#   * msg_per_s        = total_msgs / elapsed_s    # honest aggregate throughput
#   * p50_ms / p99_ms  = max across children       # conservative — the slowest
#                                                  # child sets the published tail
#   * max_ms           = max across children
#
# Aggregating percentiles by "max across children" is the conservative
# choice — a sample-weighted average would smear a slow child against a
# fast one and hide tail latency. Operators looking at the published
# p99 want the *worst* observed p99, not the average.
#
# Usage:
#
#   # Server (separate terminal, 4 workers + permessage-deflate):
#   HYPERION_WS_DEFLATE=on bundle exec hyperion -t 64 -w 4 -p 9888 bench/ws_echo.ru
#
#   # Client — 4 procs × 50 conns each = 200 total conns:
#   ruby bench/ws_bench_client_multi.rb \
#     --host 127.0.0.1 --port 9888 \
#     --procs 4 --conns 200 --msgs 1000 --bytes 1024
#
# Notes:
#
#   * `--conns N` is the *total* across all procs, matching the
#     single-process script's semantics. The per-process slice is
#     `(N / procs)`, with the remainder distributed over the first few
#     children so totals stay exact (200 / 3 = 66, 67, 67).
#
#   * Uses `Process.spawn` with stdout pipes — no fork()-after-load
#     of the Hyperion gem in the parent, so this runs cleanly even
#     if the parent's Ruby has touched the C extension. (The child
#     `ws_bench_client.rb` does load the extension via the WS frame
#     primitives — that load happens after spawn(), per-child.)
#
#   * Each child runs in --json mode and prints exactly one JSON line
#     on stdout. The parent reads that line with `File.read(child_pipe)`
#     after `Process.wait`, parses, and merges.

require 'optparse'
require 'json'

module Hyperion
  module Bench
    # Forks N children of `ws_bench_client.rb`, each driving a slice
    # of the total connection count, and aggregates per-child JSON
    # output into a single summary.
    class WsBenchClientMulti
      CHILD_SCRIPT = File.expand_path('ws_bench_client.rb', __dir__).freeze

      def initialize(host:, port:, procs:, conns:, msgs:, bytes:, path: '/echo')
        @host  = host
        @port  = Integer(port)
        @procs = Integer(procs)
        @conns = Integer(conns)
        @msgs  = Integer(msgs)
        @bytes = Integer(bytes)
        @path  = path

        raise ArgumentError, "procs must be >= 1, got #{@procs}" if @procs < 1
        raise ArgumentError, "conns (#{@conns}) must be >= procs (#{@procs})" if @conns < @procs
      end

      # @return [Hash] aggregated stats (see file header for shape)
      def run
        slices = split_conns(@conns, @procs)

        children = slices.each_with_index.map do |slice, idx|
          spawn_child(slice, idx)
        end

        results = collect(children)
        aggregate(results)
      end

      private

      # Distribute `total` across `n` buckets. Remainder lands on the
      # first `total % n` buckets so each bucket size is `floor` or
      # `floor + 1` and the sum is exactly `total`.
      def split_conns(total, n)
        base = total / n
        rem  = total % n
        Array.new(n) { |i| base + (i < rem ? 1 : 0) }
      end

      # Spawn one child with its own stdout pipe. Returns
      # `{ pid:, slice:, idx:, read_io:, write_io: }`.
      def spawn_child(slice, idx)
        read_io, write_io = IO.pipe

        argv = [
          'ruby', CHILD_SCRIPT,
          '--host',  @host,
          '--port',  @port.to_s,
          '--conns', slice.to_s,
          '--msgs',  @msgs.to_s,
          '--bytes', @bytes.to_s,
          '--path',  @path,
          '--json'
        ]

        pid = Process.spawn(*argv, out: write_io, err: $stderr)
        write_io.close

        { pid: pid, slice: slice, idx: idx, read_io: read_io }
      end

      # Wait for every child and parse its JSON line. Children that
      # exit non-zero or print no JSON are reported and dropped.
      def collect(children)
        children.map do |child|
          stdout = child[:read_io].read
          child[:read_io].close
          _, status = Process.wait2(child[:pid])

          unless status.success?
            warn "[ws-bench-multi][child #{child[:idx]}] " \
                 "exited #{status.exitstatus.inspect}: #{stdout.inspect}"
            next nil
          end

          line = stdout.lines.find { |l| l.strip.start_with?('{') }
          unless line
            warn "[ws-bench-multi][child #{child[:idx]}] " \
                 "no JSON line in stdout: #{stdout.inspect}"
            next nil
          end

          JSON.parse(line, symbolize_names: true)
        end.compact
      end

      def aggregate(results)
        if results.empty?
          return {
            host: @host, port: @port,
            procs: @procs, conns: @conns, msgs: @msgs, bytes: @bytes,
            total_msgs: 0, elapsed_s: 0.0,
            msg_per_s: 0.0, p50_ms: nil, p99_ms: nil, max_ms: nil,
            children: 0, error: 'all children failed'
          }
        end

        total_msgs = results.sum { |r| r[:total_msgs] }
        elapsed_s  = results.map { |r| r[:elapsed_s] }.max
        # Defensive: avoid div-by-zero if every child finished in 0s
        msg_per_s  = elapsed_s.positive? ? total_msgs / elapsed_s : 0.0
        p50_ms     = results.map { |r| r[:p50_ms] }.compact.max
        p99_ms     = results.map { |r| r[:p99_ms] }.compact.max
        max_ms     = results.map { |r| r[:max_ms] }.compact.max

        {
          host: @host, port: @port,
          procs: @procs, conns: @conns, msgs: @msgs, bytes: @bytes,
          total_msgs: total_msgs,
          elapsed_s: elapsed_s,
          msg_per_s: msg_per_s,
          p50_ms: p50_ms,
          p99_ms: p99_ms,
          max_ms: max_ms,
          children: results.size,
          per_child: results
        }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { host: '127.0.0.1', port: 9888, procs: 4, conns: 200,
           msgs: 1000, bytes: 1024, path: '/echo', json: false }

  OptionParser.new do |o|
    o.banner = 'Usage: ruby bench/ws_bench_client_multi.rb [options]'
    o.on('--host HOST')          { |v| opts[:host]  = v }
    o.on('--port PORT', Integer) { |v| opts[:port]  = v }
    o.on('--procs N', Integer)   { |v| opts[:procs] = v }
    o.on('--conns N', Integer)   { |v| opts[:conns] = v }
    o.on('--msgs N',  Integer)   { |v| opts[:msgs]  = v }
    o.on('--bytes N', Integer)   { |v| opts[:bytes] = v }
    o.on('--path PATH')          { |v| opts[:path]  = v }
    o.on('--json', 'Emit aggregate result as a single JSON line') { opts[:json] = true }
  end.parse!

  client = Hyperion::Bench::WsBenchClientMulti.new(
    **opts.slice(:host, :port, :procs, :conns, :msgs, :bytes, :path)
  )
  result = client.run

  if opts[:json]
    # Drop per_child to keep the line short; full data is on stderr below.
    puts result.except(:per_child).to_json
  else
    puts "[ws-bench-multi] procs=#{result[:procs]} conns=#{result[:conns]} " \
         "msgs/conn=#{result[:msgs]} bytes=#{result[:bytes]} " \
         "children_ok=#{result[:children]}/#{result[:procs]}"
    puts "[ws-bench-multi] total_msgs=#{result[:total_msgs]} " \
         "elapsed=#{result[:elapsed_s].round(3)} s  " \
         "msg/s=#{result[:msg_per_s].round(0)}"
    if result[:p50_ms]
      puts "[ws-bench-multi] p50=#{result[:p50_ms].round(3)} ms  " \
           "p99=#{result[:p99_ms].round(3)} ms  " \
           "max=#{result[:max_ms].round(3)} ms  (max across children)"
    end
    puts '[ws-bench-multi] per-child:'
    result[:per_child].each do |r|
      puts "  conns=#{r[:conns]} msg/s=#{r[:msg_per_s].round(0)} " \
           "p50=#{r[:p50_ms]&.round(3)} p99=#{r[:p99_ms]&.round(3)} " \
           "max=#{r[:max_ms]&.round(3)}"
    end
  end
end
