# frozen_string_literal: true

require 'socket'
require 'timeout'

# 2.12-C — Connection lifecycle in C.
#
# `Hyperion::Http::PageCache.run_static_accept_loop` runs the entire
# accept-and-serve loop in C for routes registered via
# `Server.handle_static`. Ruby is re-entered only for lifecycle hooks
# and for the connection handoff path.
#
# These specs cover:
#
#   * smoke: a registered `/hello` route is served from C; the served
#     count grows with each successful GET.
#   * mixed registered + unregistered: registered paths are served
#     from C, unregistered ones are handed off to a Ruby callback
#     (we assert via a spy callback that the handoff fired with the
#     expected fd + partial buffer).
#   * GVL release: while a slow client is mid-request on the C loop,
#     a Ruby fiber on the same thread can still make progress.
#   * lifecycle hooks: when `set_lifecycle_active(true)`, the
#     registered callback fires once per request with `(method, path)`.
RSpec.describe 'Hyperion::Http::PageCache.run_static_accept_loop (2.12-C)' do
  before do
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    Hyperion::Http::PageCache.clear
    # Each example starts with hooks off.
    Hyperion::Http::PageCache.set_lifecycle_active(false)
    Hyperion::Http::PageCache.set_lifecycle_callback(nil)
    Hyperion::Http::PageCache.set_handoff_callback(nil)
  end

  after do
    Hyperion::Http::PageCache.stop_accept_loop
    # Give any in-flight accept-loop thread a moment to observe the
    # stop flag + listener-close racy exit path before the next
    # example's `run_static_accept_loop` re-enters and zeros the flag.
    # Without this, the new loop's hyp_cl_stop=0 may race the
    # previous loop's accept(EBADF) and serve a small number of
    # spurious connections from the prior test's listener fd.
    sleep 0.02
    Hyperion::Http::PageCache.set_lifecycle_active(false)
    Hyperion::Http::PageCache.set_lifecycle_callback(nil)
    Hyperion::Http::PageCache.set_handoff_callback(nil)
    Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
    Hyperion::Http::PageCache.clear
  end

  def open_listener
    server = TCPServer.new('127.0.0.1', 0)
    [server, server.addr[1]]
  end

  # 2.13-C — Tear down the C accept loop hermetically.
  #
  # On Linux ≥ 6.x, `close()` on a listener fd from one thread does
  # NOT interrupt another thread parked in `accept(2)` on that same
  # fd (the kernel drops the close-during-blocked-accept wake guarantee
  # the spec previously relied on). Without an extra wake, the C
  # accept loop stays blocked until the next connection arrives —
  # which in a test is "never", so `thread.join(5)` hits the timeout
  # and `result` is left at its initial nil while the worker thread
  # is still alive.
  #
  # The fix is structural: flip the stop flag, then dial one throwaway
  # TCP connection at the listener so accept(2) returns. The C loop
  # services that fd (it carries no data, so it falls off as a 0-byte
  # read) and then re-checks `hyp_cl_stop` between accepts and exits
  # cleanly. Closing the listener happens last as a belt-and-braces
  # measure for the case where the wake-connect raced ahead and the
  # loop was about to re-enter accept anyway.
  def stop_loop_and_wake(listener, thread, timeout: 5)
    Hyperion::Http::PageCache.stop_accept_loop
    port = listener.addr[1] if listener && !listener.closed?
    if port
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        # Listener gone; the close-race already happened.
      end
    end
    listener.close unless listener.closed?
    thread.join(timeout)
  end

  def http_get(port, path, host: '127.0.0.1', extra_headers: '', read_response: true)
    sock = TCPSocket.new(host, port)
    sock.write("GET #{path} HTTP/1.1\r\nhost: #{host}\r\nconnection: close\r\n#{extra_headers}\r\n")
    return sock unless read_response

    data = +''
    begin
      Timeout.timeout(5) do
        loop do
          chunk = sock.read(4096)
          break if chunk.nil? || chunk.empty?

          data << chunk
        end
      end
    rescue Timeout::Error
      # Treat as failure — caller asserts on `data` being empty.
    end
    sock.close
    data
  end

  describe 'smoke: registered route served from C' do
    it 'returns served count > 0 after multiple GETs' do
      Hyperion::Server.handle_static(:GET, '/hello', "hello\n")
      listener, port = open_listener

      result = nil
      thread = Thread.new { result = Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      requests = 5
      requests.times do
        response = http_get(port, '/hello')
        expect(response).to include('200 OK')
        expect(response).to end_with("hello\n")
      end

      stop_loop_and_wake(listener, thread)

      expect(result).to be_a(Integer)
      expect(result).to be >= requests
    end
  end

  describe 'mixed registered + unregistered routes' do
    it 'hands off unregistered paths to the Ruby callback' do
      Hyperion::Server.handle_static(:GET, '/hello', "hello\n")
      listener, port = open_listener

      handed_off = []
      Hyperion::Http::PageCache.set_handoff_callback(lambda do |fd, partial|
        handed_off << { fd: fd, partial: partial.dup }
        # Be a good citizen — close the fd so the test doesn't leak.
        begin
          ::Socket.for_fd(fd).close
        rescue StandardError
          nil
        end
      end)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      # Hit a registered route once.
      hit_response = http_get(port, '/hello')
      expect(hit_response).to include('200 OK')

      # Then hit an unregistered route. The C loop should hand off.
      http_get(port, '/missing', read_response: false).close

      # Give the handoff time to fire.
      sleep 0.1

      stop_loop_and_wake(listener, thread)

      expect(handed_off.size).to be >= 1
      partial = handed_off.first[:partial]
      expect(partial).to include('GET /missing')
      expect(handed_off.first[:fd]).to be_a(Integer)
    end

    it 'hands off requests with a body to Ruby' do
      Hyperion::Server.handle_static(:GET, '/hello', "hello\n")
      listener, port = open_listener

      handed_off = []
      Hyperion::Http::PageCache.set_handoff_callback(lambda do |fd, partial|
        handed_off << { fd: fd, partial: partial }
        begin
          ::Socket.for_fd(fd).close
        rescue StandardError
          nil
        end
      end)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      sock = TCPSocket.new('127.0.0.1', port)
      # POST with a body — must hand off.
      sock.write("POST /hello HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n" \
                 "connection: close\r\n\r\n")
      begin
        sock.read(4096)
      rescue StandardError
        nil
      end
      sock.close

      sleep 0.1
      stop_loop_and_wake(listener, thread)

      expect(handed_off.size).to be >= 1
      expect(handed_off.first[:partial]).to include('POST /hello')
    end
  end

  describe 'lifecycle hooks fire from the C loop' do
    it 'invokes the lifecycle callback once per served request' do
      Hyperion::Server.handle_static(:GET, '/hooked', "hooked\n")
      listener, port = open_listener

      hook_calls = []
      Hyperion::Http::PageCache.set_lifecycle_callback(lambda do |method, path|
        hook_calls << [method, path]
      end)
      Hyperion::Http::PageCache.set_lifecycle_active(true)
      expect(Hyperion::Http::PageCache.lifecycle_active?).to be(true)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      3.times { http_get(port, '/hooked') }

      stop_loop_and_wake(listener, thread)

      expect(hook_calls.size).to eq(3)
      expect(hook_calls).to all eq(['GET', '/hooked'])
    end

    it 'never invokes the callback when lifecycle_active is false (no-hook hot path)' do
      Hyperion::Server.handle_static(:GET, '/quiet', "q\n")
      listener, port = open_listener

      hook_calls = 0
      Hyperion::Http::PageCache.set_lifecycle_callback(->(_method, _path) { hook_calls += 1 })
      Hyperion::Http::PageCache.set_lifecycle_active(false)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      3.times { http_get(port, '/quiet') }

      stop_loop_and_wake(listener, thread)

      expect(hook_calls).to eq(0)
    end

    it 'survives a misbehaving lifecycle hook (rb_protect contract)' do
      Hyperion::Server.handle_static(:GET, '/chaos', "c\n")
      listener, port = open_listener

      Hyperion::Http::PageCache.set_lifecycle_callback(->(_m, _p) { raise 'bang' })
      Hyperion::Http::PageCache.set_lifecycle_active(true)

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      response = http_get(port, '/chaos')
      expect(response).to include('200 OK')
      expect(response).to end_with("c\n")

      stop_loop_and_wake(listener, thread)
    end
  end

  describe 'GVL release during accept and write' do
    it 'allows another Ruby thread to run while the C loop blocks on accept' do
      Hyperion::Server.handle_static(:GET, '/g', "g\n")
      listener, _port = open_listener

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      # While the C loop is parked on `accept`, this thread can still
      # do Ruby-side computation. If the GVL was held, the loop thread
      # would never let us run; we'd time out.
      computation_thread = Thread.new do
        # 100k Ruby-level method calls — well under a second normally
        # but unbounded if the GVL is held.
        sum = 0
        100_000.times { |i| sum += i }
        sum
      end

      result = nil
      Timeout.timeout(5) { result = computation_thread.value }
      expect(result).to eq(100_000 * 99_999 / 2)

      stop_loop_and_wake(listener, thread)
    end
  end

  describe 'keep-alive on the same connection' do
    it 'serves multiple pipelined requests on a single connection' do
      Hyperion::Server.handle_static(:GET, '/k', "k\n")
      listener, port = open_listener

      thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
      sleep 0.05 # let the loop reach accept(2)

      sock = TCPSocket.new('127.0.0.1', port)
      sock.write("GET /k HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")
      sock.write("GET /k HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")

      data = +''
      Timeout.timeout(5) do
        loop do
          chunk = sock.read(4096)
          break if chunk.nil? || chunk.empty?

          data << chunk
        end
      end
      sock.close

      # Two complete responses should appear back-to-back.
      expect(data.scan(%r{HTTP/1\.1 200 OK}).size).to eq(2)
      expect(data.scan("k\n").size).to eq(2)

      stop_loop_and_wake(listener, thread)
    end
  end

  describe 'Server-level engagement of the C loop' do
    around do |ex|
      Hyperion::Runtime.reset_default!
      ex.run
      Hyperion::Runtime.reset_default!
    end

    it 'engages the C loop when only static routes are registered' do
      Hyperion::Server.handle_static(:GET, '/s', "s\n")

      app = ->(_env) { [404, { 'content-type' => 'text/plain' }, ['no']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port

      thread = Thread.new { server.start }
      sleep 0.1

      response = http_get(port, '/s')
      expect(response).to include('200 OK')
      expect(response).to end_with("s\n")

      # 2.13-C — flip the stop flag, then send one wake-connect so the
      # parked accept(2) returns; finally close the listener via
      # server.stop. See `stop_loop_and_wake` for the long-form
      # rationale; same Linux 6.x close()-doesn't-interrupt-accept
      # behaviour applies through the Server wrapper.
      Hyperion::Http::PageCache.stop_accept_loop
      begin
        TCPSocket.new('127.0.0.1', port).close
      rescue StandardError
        nil
      end
      server.stop
      thread.join(5)
    end

    it 'falls back to the Ruby loop when a dynamic handler is registered alongside' do
      Hyperion::Server.handle_static(:GET, '/static', "s\n")
      Hyperion::Server.handle(:GET, '/dynamic', ->(_req) { [200, {}, ['dynamic']] })

      app = ->(_env) { [404, { 'content-type' => 'text/plain' }, ['no']] }
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app, thread_count: 0)
      server.listen
      port = server.port

      # The C-loop engagement check should refuse: dynamic handler
      # present.
      expect(server.send(:engage_c_accept_loop?)).to be(false)

      thread = Thread.new { server.start }
      sleep 0.1

      static_response = http_get(port, '/static')
      expect(static_response).to include('200 OK')
      dynamic_response = http_get(port, '/dynamic')
      expect(dynamic_response).to end_with('dynamic')

      server.stop
      thread.join(5)
    end
  end

  # 2.13-C — Regression: serial accept-loop teardown.
  #
  # Catches the original flake (`thread.join(5)` exhausting its timeout
  # because Linux's `close()`-on-listener didn't wake another thread's
  # parked `accept(2)`) by spinning the full bring-up + serve + tear-
  # down cycle multiple times in ONE process. Prior to the
  # `stop_loop_and_wake` helper this loop would have slept for
  # 5 × N seconds; with the wake fix each iteration completes in
  # under 100 ms, so a 3-iteration run finishing inside the 10 s
  # outer timeout is the meaningful assertion.
  describe 'teardown is hermetic across repeated bring-ups' do
    it 'each iteration tears down in well under a second' do
      iterations = 3
      total = 0.0
      iterations.times do
        Hyperion::Server.handle_static(:GET, '/r', "r\n")
        listener, port = open_listener
        thread = Thread.new { Hyperion::Http::PageCache.run_static_accept_loop(listener.fileno) }
        sleep 0.05

        response = http_get(port, '/r')
        expect(response).to include('200 OK')

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stop_loop_and_wake(listener, thread)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        total += elapsed

        # Each teardown must be fast — anything close to the 5 s
        # join timeout means the wake-connect didn't reach the
        # parked accept(2) and the loop sat blocked.
        expect(elapsed).to be < 1.0
        expect(thread.alive?).to be(false)

        # Reset between iterations so the next bring-up starts clean.
        Hyperion::Http::PageCache.set_handoff_callback(nil)
        Hyperion::Http::PageCache.set_lifecycle_callback(nil)
        Hyperion::Server.route_table = Hyperion::Server::RouteTable.new
        Hyperion::Http::PageCache.clear
      end

      # Sanity: 3 iterations should not approach the 5 s join window.
      expect(total).to be < (iterations * 1.0)
    end
  end
end
