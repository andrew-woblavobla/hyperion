# frozen_string_literal: true

require 'socket'
require 'openssl'

module Hyperion
  # Worker process. Receives a listening socket and runs a
  # `Hyperion::Server` (fiber accept loop) until SIGTERM.
  #
  # Two listener sources, picked by the master per-OS:
  #
  # - `:share` mode (macOS / BSD): the master forwards a pre-bound
  #   `TCPServer` / `OpenSSL::SSL::SSLServer` via the `listener:` kwarg.
  #   The worker uses it as-is — the fd was inherited across fork.
  # - `:reuseport` mode (Linux): no listener is passed. The worker binds
  #   its own `Socket` with `SO_REUSEPORT` set so the kernel can hash
  #   incoming connections across the sibling sockets.
  class Worker
    def initialize(host:, port:, app:, read_timeout:, tls: nil,
                   thread_count: Server::DEFAULT_THREAD_COUNT,
                   config: nil, worker_index: 0, listener: nil)
      @host         = host
      @port         = port
      @app          = app
      @read_timeout = read_timeout
      @tls          = tls
      @thread_count = thread_count
      @config       = config || Hyperion::Config.new
      @worker_index = worker_index
      @listener     = listener
    end

    def run
      scheme = @tls ? 'https' : 'http'
      Hyperion.logger.info do
        {
          message: 'worker listening',
          pid: Process.pid,
          worker_index: @worker_index,
          url: "#{scheme}://#{@host}:#{@port}"
        }
      end

      server = Server.new(host: @host, port: @port, app: @app,
                          read_timeout: @read_timeout, tls: @tls,
                          thread_count: @thread_count)
      tcp_server = @listener || build_reuseport_listener
      server.adopt_listener(tcp_server)

      Signal.trap('TERM') { server.stop }
      Signal.trap('INT')  { server.stop }

      # `on_worker_boot` runs in the child after fork, after the listener is
      # ready, and before we start accepting. App code reconnects DB/Redis
      # pools here so each worker has its own. Index identifies the slot
      # (0..workers-1) so apps can shard background work if they want.
      @config.on_worker_boot.each { |h| h.call(@worker_index) }

      begin
        server.start
      ensure
        # `on_worker_shutdown` fires when the accept loop exits — either
        # due to graceful SIGTERM or a hard error. Use it to flush metrics,
        # close DB connections cleanly, etc.
        @config.on_worker_shutdown.each { |h| h.call(@worker_index) }
      end
    end

    private

    def build_reuseport_listener
      addr = ::Socket.getaddrinfo(@host, @port, nil, :STREAM).first
      sock = ::Socket.new(addr[4], ::Socket::SOCK_STREAM, 0)
      sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_REUSEADDR, 1)
      sock.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_REUSEPORT, 1)
      sock.bind(::Socket.pack_sockaddr_in(@port, addr[3]))
      sock.listen(::Socket::SOMAXCONN)

      if @tls
        ctx = Hyperion::TLS.context(cert: @tls[:cert], key: @tls[:key])
        ssl = ::OpenSSL::SSL::SSLServer.new(sock, ctx)
        ssl.start_immediately = false
        ssl
      else
        # Hyperion::Server#adopt_listener accepts any object responding to
        # #accept_nonblock, #accept, #close — which Socket does.
        sock
      end
    end
  end
end
