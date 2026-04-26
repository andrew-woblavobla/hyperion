# frozen_string_literal: true

require 'socket'
require 'hyperion/connection'

# Slowloris-style abort tests for Connection#serve. Each test pumps bytes into
# the socket pair very slowly via a feeder thread; the deadline trip is the
# event under test. We pick small budgets (well under a second) so the suite
# stays fast — accuracy is bounded by IO.select granularity, not the budget.
RSpec.describe Hyperion::Connection do
  let(:app) do
    lambda do |env|
      [200, { 'content-type' => 'text/plain' }, ["seen #{env['PATH_INFO']}"]]
    end
  end

  # Drip a string into a socket one byte at a time with a small inter-byte
  # gap. Returns the spawned Thread so the caller can join it on cleanup.
  def drip_into(socket, bytes, gap: 0.05)
    Thread.new do
      bytes.each_char do |c|
        begin
          socket.write(c)
        rescue StandardError
          break
        end
        sleep gap
      end
    end
  end

  before do
    Hyperion.metrics.reset! if Hyperion.metrics.respond_to?(:reset!)
  end

  it 'aborts a slow drip with 408 and bumps :slow_request_aborts when the deadline trips' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    request = "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n"
    feeder = drip_into(a, request, gap: 0.05) # ~1.5s total feed; budget is 0.3s

    described_class.new.serve(b, app, max_request_read_seconds: 0.3)

    response = a.read
    expect(response).to start_with("HTTP/1.1 408 Request Timeout\r\n")
    expect(response).to include('connection: close')
    expect(Hyperion.metrics.snapshot[:slow_request_aborts]).to eq(1)
  ensure
    feeder&.kill
    feeder&.join(1)
    a&.close
    b&.close
  end

  it 'completes the drip when the deadline is disabled (max_request_read_seconds: nil)' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    request = "GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    # Drip slower than the would-be 0.3s budget; this proves the no-deadline
    # path doesn't trip on slow clients (per-recv timeout still protects us).
    feeder = drip_into(a, request, gap: 0.02)

    described_class.new.serve(b, app, max_request_read_seconds: nil)

    response = a.read
    expect(response).to start_with("HTTP/1.1 200 OK\r\n")
    expect(response).to include('seen /ok')
    expect(Hyperion.metrics.snapshot[:slow_request_aborts]).to be_nil
  ensure
    feeder&.kill
    feeder&.join(1)
    a&.close
    b&.close
  end

  it 'resets the deadline between keep-alive requests so a fast first request leaves a fresh budget for the second' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    # First request: fast and complete in one write.
    a.write("GET /first HTTP/1.1\r\nHost: x\r\n\r\n")
    # Second request: slow drip that would trip a connection-wide deadline
    # but should complete within a *fresh* per-request 0.5s budget.
    feeder = Thread.new do
      sleep 0.1 # let the first request land
      "GET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".each_char do |c|
        begin
          a.write(c)
        rescue StandardError
          break
        end
        sleep 0.005
      end
    end

    described_class.new.serve(b, app, max_request_read_seconds: 0.5)

    response = a.read
    # Both requests should have completed normally (200 OK twice). If the
    # deadline had been per-connection (not per-request), the second request
    # would have been aborted with 408.
    expect(response.scan(%r{HTTP/1\.1 200 OK}).size).to eq(2)
    expect(response).to include('seen /first')
    expect(response).to include('seen /second')
    expect(Hyperion.metrics.snapshot[:slow_request_aborts]).to be_nil
  ensure
    feeder&.kill
    feeder&.join(1)
    a&.close
    b&.close
  end

  it 'aborts mid-body when the deadline trips during content-length read' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    # Send the whole header section fast so we get past the header loop, then
    # dribble the body to trip the deadline mid-body.
    a.write("POST /b HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n")
    feeder = drip_into(a, '0123456789' * 2, gap: 0.05) # 20 bytes * 50ms = 1s feed

    described_class.new.serve(b, app, max_request_read_seconds: 0.3)

    response = a.read
    expect(response).to start_with("HTTP/1.1 408 Request Timeout\r\n")
    expect(Hyperion.metrics.snapshot[:slow_request_aborts]).to eq(1)
  ensure
    feeder&.kill
    feeder&.join(1)
    a&.close
    b&.close
  end

  it 'closes the socket after a deadline-driven abort' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    feeder = drip_into(a, "GET /q HTTP/1.1\r\nHost: x\r\n\r\n", gap: 0.05)

    described_class.new.serve(b, app, max_request_read_seconds: 0.2)

    expect(b.closed?).to be(true)
  ensure
    feeder&.kill
    feeder&.join(1)
    a&.close
    b&.close
  end
end
