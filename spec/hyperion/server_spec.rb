# frozen_string_literal: true

require 'net/http'
require 'socket'

RSpec.describe Hyperion::Server do
  let(:app) { ->(env) { [200, { 'content-type' => 'text/plain' }, ["hi #{env['PATH_INFO']}"]] } }

  it 'binds to a port and reports it via #port' do
    server = described_class.new(host: '127.0.0.1', port: 0, app: app)
    server.listen

    expect(server.port).to be_a(Integer)
    expect(server.port).to be > 0
  ensure
    server&.stop
  end

  it 'serves a Rack app over a real TCP socket' do
    server = described_class.new(host: '127.0.0.1', port: 0, app: app)
    server.listen

    actual_port = server.port
    accept_thread = Thread.new { server.run_one }

    response = Net::HTTP.get(URI("http://127.0.0.1:#{actual_port}/world"))
    accept_thread.join(2)

    expect(response).to eq('hi /world')
  ensure
    server&.stop
  end

  it 'serves multiple sequential requests via #start until #stop' do
    server = described_class.new(host: '127.0.0.1', port: 0, app: app)
    server.listen
    actual_port = server.port

    serve_thread = Thread.new { server.start }

    # Wait until the listener actually accepts (poll up to 2s).
    deadline = Time.now + 2
    loop do
      s = TCPSocket.new('127.0.0.1', actual_port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise "server didn't bind within 2s" if Time.now > deadline

      sleep 0.01
    end

    r1 = Net::HTTP.get(URI("http://127.0.0.1:#{actual_port}/one"))
    r2 = Net::HTTP.get(URI("http://127.0.0.1:#{actual_port}/two"))

    expect(r1).to eq('hi /one')
    expect(r2).to eq('hi /two')
  ensure
    server&.stop
    serve_thread&.join(2)
  end

  it 'serves multiple concurrent requests' do
    slow_app = lambda do |env|
      sleep 0.1 # simulate slow IO
      [200, { 'content-type' => 'text/plain' }, ["served #{env['PATH_INFO']}"]]
    end

    server = described_class.new(host: '127.0.0.1', port: 0, app: slow_app)
    server.listen
    actual_port = server.port

    serve_thread = Thread.new { server.start }

    # Wait until the server is bound.
    deadline = Time.now + 2
    loop do
      s = TCPSocket.new('127.0.0.1', actual_port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise "server didn't bind within 2s" if Time.now > deadline

      sleep 0.01
    end

    # Fire 5 concurrent requests via separate threads.
    started = Time.now
    responses = 5.times.map do |i|
      Thread.new do
        Net::HTTP.get(URI("http://127.0.0.1:#{actual_port}/req#{i}"))
      end
    end.map(&:value)
    elapsed = Time.now - started

    expect(responses.uniq.size).to eq(5)
    responses.each_with_index do |body, i|
      expect(body).to eq("served /req#{i}")
    end
    # If serial: ~0.5s. If concurrent: ~0.1s + overhead. Allow 0.4s as the cutoff.
    expect(elapsed).to be < 0.4
  ensure
    server&.stop
    serve_thread&.join(2)
  end
end
