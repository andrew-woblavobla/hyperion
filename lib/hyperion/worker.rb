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
                   config: nil, worker_index: 0, listener: nil,
                   max_pending: nil, max_request_read_seconds: 60,
                   h2_settings: nil, async_io: nil, runtime: nil,
                   accept_fibers_per_worker: 1, h2_max_total_streams: nil,
                   admin_listener_port: nil, admin_listener_host: '127.0.0.1',
                   admin_token: nil,
                   tls_session_cache_size: TLS::DEFAULT_SESSION_CACHE_SIZE,
                   tls_ticket_key_rotation_signal: :USR2,
                   tls_ktls: :auto)
      @host                     = host
      @port                     = port
      @app                      = app
      @read_timeout             = read_timeout
      @tls                      = tls
      @thread_count             = thread_count
      @config                   = config || Hyperion::Config.new
      @worker_index             = worker_index
      @listener                 = listener
      @max_pending              = max_pending
      @max_request_read_seconds = max_request_read_seconds
      @h2_settings              = h2_settings
      @async_io                 = async_io
      @runtime                  = runtime
      @accept_fibers_per_worker = accept_fibers_per_worker
      @h2_max_total_streams     = h2_max_total_streams
      @admin_listener_port      = admin_listener_port
      @admin_listener_host      = admin_listener_host
      @admin_token              = admin_token
      @tls_session_cache_size            = tls_session_cache_size
      @tls_ticket_key_rotation_signal    = tls_ticket_key_rotation_signal
      @tls_ktls                          = tls_ktls
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
                          thread_count: @thread_count,
                          max_pending: @max_pending,
                          max_request_read_seconds: @max_request_read_seconds,
                          h2_settings: @h2_settings,
                          async_io: @async_io,
                          runtime: @runtime,
                          accept_fibers_per_worker: @accept_fibers_per_worker,
                          h2_max_total_streams: @h2_max_total_streams,
                          admin_listener_port: @admin_listener_port,
                          admin_listener_host: @admin_listener_host,
                          admin_token: @admin_token,
                          tls_session_cache_size: @tls_session_cache_size,
                          tls_ktls: @tls_ktls)

      # `on_worker_boot` runs in the child after fork, BEFORE the worker
      # adopts/binds its listener and before any accept. App code reconnects
      # DB/Redis pools here so each worker has its own. Index identifies the
      # slot (0..workers-1) so apps can shard background work if they want.
      #
      # Pre-1.6.3 this hook fired AFTER the listener was adopted (`:share`)
      # or freshly bound with SO_REUSEPORT (`:reuseport`). On `:reuseport`
      # that meant the kernel could queue inbound connections to the
      # worker's listen socket while the operator's hook was still warming
      # up DB pools — observable as first-request latency spikes against
      # an unready handler. Firing the hook before listener setup makes the
      # two worker models behave identically: no socket exists for this
      # worker until the boot hook has returned.
      @config.on_worker_boot.each { |h| h.call(@worker_index) }

      tcp_server = @listener || build_reuseport_listener
      server.adopt_listener(tcp_server)

      Signal.trap('TERM') { server.stop }
      Signal.trap('INT')  { server.stop }
      install_tls_rotation_signal_handler(server)

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
        ctx = Hyperion::TLS.context(cert: @tls[:cert], key: @tls[:key], chain: @tls[:chain],
                                    session_cache_size: @tls_session_cache_size,
                                    ktls: @tls_ktls)
        ssl = ::OpenSSL::SSL::SSLServer.new(sock, ctx)
        ssl.start_immediately = false
        ssl
      else
        # Hyperion::Server#adopt_listener accepts any object responding to
        # #accept_nonblock, #accept, #close — which Socket does.
        sock
      end
    end

    # Wire the TLS ticket-key rotation signal (default SIGUSR2) to call
    # `Hyperion::TLS.rotate!` against the per-worker SSLContext. The
    # signal is broadcast by the master on operator demand or on the
    # worker's own initiative; either way the receiving worker flushes
    # its session cache so subsequent connections can no longer resume
    # against pre-rotation entries.
    #
    # When the operator picks `:NONE` the trap is skipped — the default
    # SIG_DFL handler stays in place and the worker keeps the original
    # session cache for its full lifetime.
    def install_tls_rotation_signal_handler(server)
      return unless @tls
      return if @tls_ticket_key_rotation_signal.nil?
      return if @tls_ticket_key_rotation_signal == :NONE

      sig = @tls_ticket_key_rotation_signal.to_s
      Signal.trap(sig) do
        ctx = server.ssl_ctx
        ::Hyperion::TLS.rotate!(ctx) if ctx
      rescue StandardError
        # Signal handlers run in the main thread context; swallowing
        # here avoids a corrupted-trap state if `flush_sessions` raises
        # against an in-progress flush from a previous signal.
        nil
      end
    rescue ArgumentError
      # Operator passed a bogus signal name (`:DOES_NOT_EXIST`). Log
      # and continue — rotation off is acceptable, the worker should
      # not refuse to boot over a knob typo.
      Hyperion.logger.warn do
        {
          message: 'invalid tls_ticket_key_rotation_signal; rotation disabled',
          signal: @tls_ticket_key_rotation_signal
        }
      end
    end
  end
end
