# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Hyperion::Server do
  describe '#reject_connection (backpressure 503 path)' do
    # Reach into the private helper directly — the public API is the
    # accept loop, which is harder to corral deterministically. The
    # helper's contract is small and stable: write the constant, bump
    # the metric, close. Test that.
    let(:server) { described_class.new(app: ->(_e) { [200, {}, []] }) }

    let(:fake_socket) do
      Class.new do
        attr_reader :written, :closed

        def initialize
          @written = +''
          @closed = false
        end

        def write(bytes)
          @written << bytes
          bytes.bytesize
        end

        def close
          @closed = true
        end
      end.new
    end

    it 'writes the pre-built 503 wire payload to the socket' do
      server.send(:reject_connection, fake_socket)
      expect(fake_socket.written).to start_with('HTTP/1.1 503 Service Unavailable')
    end

    it 'includes Retry-After: 1 so clients back off before retrying' do
      server.send(:reject_connection, fake_socket)
      expect(fake_socket.written).to include("retry-after: 1\r\n")
    end

    it 'declares a JSON body matching the advertised content-length' do
      server.send(:reject_connection, fake_socket)
      head, body = fake_socket.written.split("\r\n\r\n", 2)
      cl_match = head.match(/content-length: (\d+)/)
      expect(cl_match).not_to be_nil
      expect(body.bytesize).to eq(cl_match[1].to_i)
      expect(body).to include('server_busy')
    end

    it 'closes the socket after writing' do
      server.send(:reject_connection, fake_socket)
      expect(fake_socket.closed).to be(true)
    end

    it 'increments :rejected_connections on Hyperion.metrics' do
      before_count = Hyperion.metrics.snapshot[:rejected_connections] || 0
      server.send(:reject_connection, fake_socket)
      after_count = Hyperion.metrics.snapshot[:rejected_connections]
      expect(after_count - before_count).to eq(1)
    end

    it 'still closes the socket when write raises (client hung up)' do
      raising_socket = Class.new do
        attr_reader :closed

        def initialize
          @closed = false
        end

        def write(_bytes)
          raise Errno::EPIPE, 'broken pipe'
        end

        def close
          @closed = true
        end
      end.new

      expect { server.send(:reject_connection, raising_socket) }.not_to raise_error
      expect(raising_socket.closed).to be(true)
    end
  end

  describe 'REJECT_503 wire payload' do
    it 'is a frozen String so the overload path stays allocation-free' do
      expect(described_class::REJECT_503).to be_frozen
    end

    it 'declares connection: close' do
      expect(described_class::REJECT_503).to include("connection: close\r\n")
    end
  end
end
