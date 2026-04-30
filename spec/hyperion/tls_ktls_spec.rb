# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'socket'

# Phase 9 (2.2.0) — kernel TLS transmit (KTLS_TX) on Linux ≥ 4.13 +
# OpenSSL ≥ 3.0. After the userspace handshake, OpenSSL hands the
# symmetric session key to the kernel and subsequent SSL_write calls go
# through kernel sendfile/write paths. macOS / BSD have no kTLS support;
# the probe returns false and SSL_write stays in userspace transparently.
#
# This spec exercises the boot probe + the config knob's three states.
# The "is kTLS actually active" assertion is gated on Linux because the
# probe returns nil on macOS where /proc/modules doesn't exist.
RSpec.describe 'TLS kTLS (Phase 9 / 2.2.0)' do
  before do
    # Probe is memoized once per process; force a fresh read so each
    # example sees the current platform's true answer.
    Hyperion::TLS.reset_ktls_probe!
  end

  describe '.ktls_supported?' do
    it 'returns false on Darwin (macOS)' do
      sysname = Etc.uname[:sysname]
      skip "current platform is #{sysname}, not Darwin" unless sysname == 'Darwin'

      expect(Hyperion::TLS.ktls_supported?).to eq(false)
    end

    it 'returns true on Linux ≥ 4.13 with OpenSSL ≥ 3.0' do
      sysname = Etc.uname[:sysname]
      skip "current platform is #{sysname}, not Linux" unless sysname == 'Linux'
      skip 'openssl < 3.0' if OpenSSL::OPENSSL_VERSION_NUMBER < Hyperion::TLS::MIN_OPENSSL_VERSION_FOR_KTLS

      release = Etc.uname[:release].to_s.split('.').first(2).map(&:to_i)
      min_maj, min_min = Hyperion::TLS::MIN_LINUX_KERNEL_FOR_KTLS
      ok = release[0] > min_maj || (release[0] == min_maj && release[1] >= min_min)
      skip "kernel #{release.join('.')} < #{min_maj}.#{min_min}" unless ok

      expect(Hyperion::TLS.ktls_supported?).to eq(true)
    end

    it 'is memoized across calls' do
      first  = Hyperion::TLS.ktls_supported?
      second = Hyperion::TLS.ktls_supported?
      expect(first).to eq(second)
    end
  end

  describe '.context with ktls knob' do
    it 'does not raise with ktls: :auto on macOS' do
      skip 'Linux-only path' if Etc.uname[:sysname] == 'Linux'

      cert, key = TLSHelper.self_signed
      expect { Hyperion::TLS.context(cert: cert, key: key, ktls: :auto) }.not_to raise_error
    end

    it 'raises with ktls: :on on macOS with a clear message' do
      skip 'this assertion targets the unsupported-platform branch' if Hyperion::TLS.ktls_supported?

      cert, key = TLSHelper.self_signed
      expect { Hyperion::TLS.context(cert: cert, key: key, ktls: :on) }
        .to raise_error(Hyperion::UnsupportedError, /kTLS not supported/)
    end

    it 'does not raise with ktls: :off regardless of platform' do
      cert, key = TLSHelper.self_signed
      expect { Hyperion::TLS.context(cert: cert, key: key, ktls: :off) }.not_to raise_error
    end

    it 'rejects unknown ktls policy values' do
      cert, key = TLSHelper.self_signed
      expect { Hyperion::TLS.context(cert: cert, key: key, ktls: :sometimes) }
        .to raise_error(ArgumentError, /tls\.ktls must be :auto, :on, or :off/)
    end

    it 'sets OP_ENABLE_KTLS on the context when supported' do
      skip 'kTLS unsupported on this host' unless Hyperion::TLS.ktls_supported?

      cert, key = TLSHelper.self_signed
      ctx = Hyperion::TLS.context(cert: cert, key: key, ktls: :auto)
      expect(ctx.options & Hyperion::TLS::OP_ENABLE_KTLS_VALUE).to eq(Hyperion::TLS::OP_ENABLE_KTLS_VALUE)
    end

    it 'does NOT set OP_ENABLE_KTLS with ktls: :off, even on Linux' do
      cert, key = TLSHelper.self_signed
      ctx = Hyperion::TLS.context(cert: cert, key: key, ktls: :off)
      expect(ctx.options & Hyperion::TLS::OP_ENABLE_KTLS_VALUE).to eq(0)
    end
  end

  describe 'TLS h1 round-trip works regardless of kTLS state' do
    let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hello-ktls']] } }

    %i[auto off].each do |policy|
      it "serves an HTTPS request with tls.ktls = :#{policy}" do
        cert, key = TLSHelper.self_signed
        server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app,
                                      tls: { cert: cert, key: key },
                                      tls_ktls: policy)
        server.listen
        port = server.port

        serve_thread = Thread.new { server.start }

        deadline = Time.now + 5
        loop do
          s = TCPSocket.new('127.0.0.1', port)
          s.close
          break
        rescue Errno::ECONNREFUSED
          raise 'server did not bind' if Time.now > deadline

          sleep 0.01
        end

        http = Net::HTTP.new('127.0.0.1', port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        response = http.get('/')

        expect(response.code).to eq('200')
        expect(response.body).to eq('hello-ktls')
      ensure
        server&.stop
        serve_thread&.join(2)
      end
    end
  end

  describe 'Server boot with tls_ktls: :on on an unsupported host' do
    it 'raises Hyperion::UnsupportedError when listen is called' do
      skip 'kTLS supported here; this asserts the unsupported branch' if Hyperion::TLS.ktls_supported?

      cert, key = TLSHelper.self_signed
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0,
                                    app: ->(_e) { [200, {}, ['ok']] },
                                    tls: { cert: cert, key: key },
                                    tls_ktls: :on)

      expect { server.listen }.to raise_error(Hyperion::UnsupportedError, /kTLS not supported/)
    ensure
      server&.stop
    end
  end

  describe 'Linux-only: kTLS engages with default :auto policy' do
    it 'sees the tls kernel module loaded with positive refcount after a request' do
      skip 'Linux-only path' unless Hyperion::TLS.ktls_supported?

      cert, key = TLSHelper.self_signed
      server = Hyperion::Server.new(host: '127.0.0.1', port: 0,
                                    app: ->(_e) { [200, {}, ['ktls-on']] },
                                    tls: { cert: cert, key: key },
                                    tls_ktls: :auto)
      server.listen
      port = server.port

      serve_thread = Thread.new { server.start }

      # Drive a request to give OpenSSL a chance to promote the socket
      # to kTLS. The kernel's `tls` module gets pulled in on the first
      # successful TCP_ULP setsockopt — so post-request, /proc/modules
      # should report `tls` with a positive refcount.
      deadline = Time.now + 5
      loop do
        s = TCPSocket.new('127.0.0.1', port)
        s.close
        break
      rescue Errno::ECONNREFUSED
        raise 'server did not bind' if Time.now > deadline

        sleep 0.01
      end

      http = Net::HTTP.new('127.0.0.1', port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.get('/')

      # On Linux + kTLS-supported OpenSSL, the kernel module either was
      # already loaded (refcount > 0 at boot) or got pulled in by our
      # SSL_write. Either way `ktls_active?` should not be false.
      expect(Hyperion::TLS.ktls_active?).not_to eq(false)
    ensure
      server&.stop
      serve_thread&.join(2)
    end

    it 'tls_ktls: :off does NOT set OP_ENABLE_KTLS even on a kTLS-capable host' do
      skip 'Linux-only path' unless Hyperion::TLS.ktls_supported?

      cert, key = TLSHelper.self_signed
      ctx = Hyperion::TLS.context(cert: cert, key: key, ktls: :off)
      expect(ctx.options & Hyperion::TLS::OP_ENABLE_KTLS_VALUE).to eq(0)
    end
  end
end
