# frozen_string_literal: true

require 'socket'
require 'hyperion/connection'

# Hotfix S2: cap declared Content-Length at max_body_bytes BEFORE reading
# any body bytes off the socket. An attacker advertising a huge length
# (e.g. `Content-Length: 99999999999`) must get a 413 + close back without
# us pre-allocating buffers or sitting in a drain loop.
RSpec.describe Hyperion::Connection do
  let(:app) do
    lambda do |_env|
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
  end

  before do
    Hyperion.metrics.reset! if Hyperion.metrics.respond_to?(:reset!)
  end

  it 'returns 413 + Connection: close on absurdly large declared Content-Length' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    # 99_999_999_999 is comfortably above any reasonable body budget but
    # well within Integer::MAX, so to_i parses it cleanly.
    a.write("POST /huge HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999\r\n\r\n")
    a.close_write

    body_reads = 0
    counting_app = lambda do |env|
      body_reads += env['rack.input'].read.bytesize
      [200, {}, ['unreachable']]
    end

    described_class.new.serve(b, counting_app)

    response = a.read
    expect(response).to start_with("HTTP/1.1 413 Payload Too Large\r\n")
    expect(response.downcase).to include('connection: close')
    # The whole point of the cap: we must NOT have read any body bytes.
    # The app handler should never have been invoked at all.
    expect(body_reads).to eq(0)
  ensure
    a&.close
    b&.close
  end

  it 'returns 413 when Content-Length exceeds the configured max_body_bytes' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    # Body would be 100 bytes; cap is 50. We never read them.
    a.write("POST /e HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n#{'x' * 100}")
    a.close_write

    described_class.new(max_body_bytes: 50).serve(b, app)

    response = a.read
    expect(response).to start_with("HTTP/1.1 413 Payload Too Large\r\n")
  ensure
    a&.close
    b&.close
  end

  it 'proceeds normally when Content-Length is within max_body_bytes (no regression)' do
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("POST /ok HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nConnection: close\r\n\r\n#{'x' * 100}")
    a.close_write

    captured = nil
    echo_app = lambda do |env|
      captured = env['rack.input'].read
      [200, { 'content-type' => 'text/plain' }, ['got it']]
    end

    described_class.new(max_body_bytes: 1000).serve(b, echo_app)

    response = a.read
    expect(response).to start_with("HTTP/1.1 200 OK\r\n")
    expect(response).to include('got it')
    expect(captured.bytesize).to eq(100)
  ensure
    a&.close
    b&.close
  end

  it 'preserves the existing 400 Bad Request behaviour for negative Content-Length' do
    # `Content-Length: -1` doesn't match the digits-only regex used by
    # read_request, so the read loop is a no-op and the parser sees the
    # buffer as-is. The pure-Ruby Parser then rejects on the -1 → bytesize
    # mismatch; the C parser rejects via llhttp's own validation. Either
    # way we want a 400 — NOT a 413, because the value is malformed
    # rather than oversized.
    a, b = ::Socket.pair(:UNIX, :STREAM)
    a.write("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n")
    a.close_write

    described_class.new.serve(b, app)

    response = a.read
    expect(response).to start_with("HTTP/1.1 400 Bad Request\r\n")
  ensure
    a&.close
    b&.close
  end
end
