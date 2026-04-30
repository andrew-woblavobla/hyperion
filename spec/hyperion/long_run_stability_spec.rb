# frozen_string_literal: true

# 2.4-B — long-run stability regression guard.
#
# Drives 10_000 keep-alive HTTP requests over 100 connections through a
# real Hyperion server in a thread, capturing GC.count and
# total_allocated_objects deltas. Asserts:
#
# * Per-request average allocation count stays under threshold (2.4-B
#   target ~55, threshold 65 for headroom).
# * GC frequency over the workload stays under threshold (2.3.0 baseline
#   was ~1 GC per 555 requests on this audit; 2.4-B target is 1/625+;
#   the threshold is set to 1/500 so a regression that re-introduces
#   25% more allocation pressure trips it without flapping on YJIT
#   noise).
#
# Tagged :perf — skipped in CI under default settings; operators run
# this spec explicitly via `bundle exec rspec --tag perf` after
# allocation-related changes to confirm the long-run stability number
# hasn't drifted.

require 'socket'
require 'hyperion'

RSpec.describe '2.4-B long-run stability', :perf do
  it 'sustains 10_000 keep-alive requests with bounded GC frequency + per-req allocations' do
    app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }

    tcp_server = TCPServer.new('127.0.0.1', 0)
    port = tcp_server.addr[1]
    done = false
    workers = []
    server_thread = Thread.new do
      until done
        begin
          client = tcp_server.accept_nonblock
        rescue IO::WaitReadable
          begin
            IO.select([tcp_server], nil, nil, 0.05)
          rescue IOError, Errno::EBADF
            break
          end
          next
        rescue IOError, Errno::EBADF
          break
        end
        conn = Hyperion::Connection.new(log_requests: false)
        workers << Thread.new(client) { |c| conn.serve(c, app) }
      end
    rescue StandardError
      # Server tear-down races the spec body's tcp_server.close —
      # silently swallow once we're shutting down.
    end

    request_bytes = "GET /a HTTP/1.1\r\nhost: x\r\nuser-agent: bench\r\n" \
                    "accept: */*\r\nconnection: keep-alive\r\n\r\n"
    socket_count = 100
    per_socket = 100
    total_requests = socket_count * per_socket

    sockets = Array.new(socket_count) { TCPSocket.new('127.0.0.1', port) }

    # Warm up
    sockets.each do |s|
      s.write(request_bytes)
      drain(s)
    end

    GC.start
    before_alloc = GC.stat(:total_allocated_objects)
    before_gc    = GC.stat(:count)

    per_socket.times do
      sockets.each do |s|
        s.write(request_bytes)
        drain(s)
      end
    end

    after_alloc = GC.stat(:total_allocated_objects)
    after_gc    = GC.stat(:count)

    sockets.each(&:close)
    done = true
    tcp_server.close
    server_thread.join(1)
    workers.each { |w| w.join(0.1) }

    per_req_alloc = (after_alloc - before_alloc).fdiv(total_requests)
    gc_count      = after_gc - before_gc
    gc_per_req    = gc_count.zero? ? Float::INFINITY : total_requests / gc_count.to_f

    # Threshold: 2.4-B measured ~53 obj/req on macOS arm64 Ruby 3.3.3.
    # Threshold 65 is +22% — a fresh +12 obj/req regression trips it
    # while normal noise (Ruby version drift, async-io fiber churn)
    # stays green.
    expect(per_req_alloc).to be <= 65.0,
                             "expected <= 65 obj/req, got #{per_req_alloc.round(2)} " \
                             '(threshold = 2.4-B target +22% headroom)'

    # Threshold: 2.4-B measured 1 GC per 625 requests under this
    # workload. Setting the threshold at 1 GC per 500 requests means
    # a 25% allocation regression trips it — same envelope as the
    # per_req_alloc threshold above, expressed via the GC pressure
    # side instead of the alloc side.
    expect(gc_per_req).to be >= 500.0,
                          'expected >= 500 reqs per GC (lower allocation pressure), ' \
                          "got #{gc_per_req.round(0)} (gc_count=#{gc_count}, " \
                          "total_requests=#{total_requests})"
  end

  # Reuses the small drain pattern from bench/gc_audit_2_4_b.rb without
  # cross-loading the bench file.
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
        return data if data.bytesize > 50 && data.include?("\r\n\r\nok")
      end
    end
  rescue StandardError
    data
  end
end
