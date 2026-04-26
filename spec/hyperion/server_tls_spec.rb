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

  it 'presents the full chain when chain: is supplied (intermediate + leaf)' do
    ca_key  = OpenSSL::PKey::RSA.new(2048)
    ca_cert = OpenSSL::X509::Certificate.new
    ca_cert.version    = 2
    ca_cert.serial     = 1
    ca_cert.subject    = OpenSSL::X509::Name.parse('/CN=hyperion-test-ca')
    ca_cert.issuer     = ca_cert.subject
    ca_cert.public_key = ca_key.public_key
    ca_cert.not_before = Time.now
    ca_cert.not_after  = Time.now + 3600
    ca_cert.add_extension(OpenSSL::X509::Extension.new('basicConstraints', 'CA:TRUE', true))
    ca_cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))

    leaf_key  = OpenSSL::PKey::RSA.new(2048)
    leaf_cert = OpenSSL::X509::Certificate.new
    leaf_cert.version    = 2
    leaf_cert.serial     = 2
    leaf_cert.subject    = OpenSSL::X509::Name.parse('/CN=localhost')
    leaf_cert.issuer     = ca_cert.subject
    leaf_cert.public_key = leaf_key.public_key
    leaf_cert.not_before = Time.now
    leaf_cert.not_after  = Time.now + 3600
    leaf_cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))

    server = Hyperion::Server.new(host: '127.0.0.1', port: 0,
                                  app: ->(_e) { [200, {}, ['ok']] },
                                  tls: { cert: leaf_cert, chain: [ca_cert], key: leaf_key })
    server.listen
    port = server.port
    serve_thread = Thread.new { server.start }

    deadline = Time.now + 3
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didnt bind' if Time.now > deadline

      sleep 0.01
    end

    raw = TCPSocket.new('127.0.0.1', port)
    ssl = OpenSSL::SSL::SSLSocket.new(raw)
    ssl.sync_close = true
    ssl.connect

    chain = ssl.peer_cert_chain
    expect(chain.size).to eq(2)
    expect(chain[0].subject.to_s).to include('CN=localhost')
    expect(chain[1].subject.to_s).to include('CN=hyperion-test-ca')

    ssl.close
  ensure
    server&.stop
    serve_thread&.join(2)
  end
end
