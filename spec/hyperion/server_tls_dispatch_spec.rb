# frozen_string_literal: true

require 'spec_helper'
require 'net/http'
require 'openssl'
require 'socket'

# 1.4.0 default-behaviour change: post-handshake `app.call` for HTTP/1.1-over-TLS
# now dispatches inline on the calling fiber by default (instead of hopping
# through the worker thread pool). Rationale: the TLS path always runs the
# Async accept loop for ALPN handshake + h2 streams, so the scheduler is
# already current — handing the socket to a worker thread strips the scheduler
# context and defeats fiber-cooperative libraries (hyperion-async-pg, async-redis)
# on the TLS h1 path. Operators who specifically want TLS+threadpool can pass
# `async_io: false` to force the pool branch.
#
# Matrix (covered below):
#   async_io: nil  + TLS  -> inline (new default)
#   async_io: true + TLS  -> inline (force-on)
#   async_io: false + TLS -> pool   (explicit opt-out)
RSpec.describe Hyperion::Server, 'TLS h1 dispatch' do
  def free_port
    s = ::TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  let(:port) { free_port }
  let(:cert_and_key) { TLSHelper.self_signed }
  let(:tls_opts) { { cert: cert_and_key[0], key: cert_and_key[1] } }
  let(:probe) { { saw_scheduler: nil, thread: nil } }

  let(:probe_app) do
    captured = probe
    lambda do |_env|
      captured[:saw_scheduler] = !Fiber.scheduler.nil?
      captured[:thread] = Thread.current
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
  end

  def tls_get(server_port)
    http = Net::HTTP.new('127.0.0.1', server_port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.get('/')
  end

  def until_listening(server_port, timeout: 5)
    deadline = Time.now + timeout
    loop do
      socket = ::TCPSocket.new('127.0.0.1', server_port)
      socket.close
      return
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      raise 'server never listened' if Time.now > deadline

      sleep 0.05
    end
  end

  def serve_one_tls_request(server)
    server.listen
    bound_port = server.port
    accept_thread = nil
    server_thread = Thread.new do
      accept_thread = Thread.current
      server.start
    end
    until_listening(bound_port)
    response = tls_get(bound_port)
    [response, accept_thread]
  ensure
    server.stop
    server_thread&.join(2)
  end

  # Behavioural proof of dispatch routing: we observe (a) whether the
  # handler ran under a Fiber.scheduler, and (b) whether it ran on the
  # accept-loop OS thread or a different one. The thread-pool path runs
  # on a worker thread with no scheduler; the inline path runs on the
  # accept-loop thread under Async::Scheduler. The metrics counters
  # (:requests_async_dispatched / :requests_threadpool_dispatched) are
  # bumped on the same paths but `Hyperion::Metrics` keys per-fiber storage
  # which can't be observed from the spec's main fiber, so we lean on the
  # behavioural probe.

  context 'with default async_io: nil + TLS' do
    it 'serves the request inline on the accept fiber under Fiber.scheduler' do
      server = described_class.new(app: probe_app, host: '127.0.0.1', port: port,
                                   tls: tls_opts, thread_count: 5)
      response, accept_thread = serve_one_tls_request(server)

      expect(response.code).to eq('200')
      expect(response.body).to eq('ok')
      # Scheduler must be visible to the handler (proves we ran under Async).
      expect(probe[:saw_scheduler]).to be(true)
      # And we ran on the accept-loop OS thread, not a worker pool thread.
      expect(probe[:thread]).to eq(accept_thread)
    end
  end

  context 'with explicit async_io: false + TLS (forced threadpool opt-out)' do
    it 'hands the connection to the worker thread pool (no scheduler in handler)' do
      server = described_class.new(app: probe_app, host: '127.0.0.1', port: port,
                                   tls: tls_opts, thread_count: 5, async_io: false)
      response, accept_thread = serve_one_tls_request(server)

      expect(response.code).to eq('200')
      expect(response.body).to eq('ok')
      # Pool path: the worker thread runs the handler outside Async::Scheduler,
      # so Fiber.scheduler must be nil on the handler thread.
      expect(probe[:saw_scheduler]).to be(false)
      expect(probe[:thread]).not_to eq(accept_thread)
    end
  end

  context 'with explicit async_io: true + TLS' do
    it 'serves the request inline on the accept fiber under Fiber.scheduler' do
      server = described_class.new(app: probe_app, host: '127.0.0.1', port: port,
                                   tls: tls_opts, thread_count: 5, async_io: true)
      response, accept_thread = serve_one_tls_request(server)

      expect(response.code).to eq('200')
      expect(response.body).to eq('ok')
      expect(probe[:saw_scheduler]).to be(true)
      expect(probe[:thread]).to eq(accept_thread)
    end
  end
end
