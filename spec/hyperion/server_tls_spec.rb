# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'socket'

RSpec.describe 'Hyperion::Server (TLS)' do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['secure']] } }

  it 'serves an HTTPS request over TLS with ALPN-selected http/1.1' do
    cert, key = TLSHelper.self_signed
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app,
                                  tls: { cert: cert, key: key })
    server.listen
    port = server.port

    serve_thread = Thread.new { server.start }

    deadline = Time.now + 5
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didnt bind' if Time.now > deadline

      sleep 0.01
    end

    http = Net::HTTP.new('127.0.0.1', port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    response = http.get('/')

    expect(response.code).to eq('200')
    expect(response.body).to eq('secure')
  ensure
    server&.stop
    serve_thread&.join(2)
  end
end
