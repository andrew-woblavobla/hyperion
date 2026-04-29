# frozen_string_literal: true

require 'etc'
require 'rbconfig'
require 'socket'
require 'openssl'

module Hyperion
  # Pre-fork master process. Owns the supervision loop. Each worker is a
  # full fiber-scheduler `Hyperion::Server` running its own accept loop.
  #
  # rc15 — per-OS worker model. There are two ways to give N children a
  # listening socket on the same port:
  #
  # 1. `:reuseport` (Linux): each worker binds its OWN socket with
  #    SO_REUSEPORT. The kernel hashes incoming connections across the
  #    sibling sockets — no thundering herd, no shared accept lock,
  #    linear scaling with worker count. The master never binds.
  #
  # 2. `:share` (macOS / BSD / everything else): the master binds a
  #    single TCPServer (or SSLServer) BEFORE fork. Children inherit the
  #    fd via fork(2) and race on `accept(2)` — whichever child wins gets
  #    the connection. This is Puma's model. We use it on Darwin because
  #    Darwin's SO_REUSEPORT distributor hashes unevenly: at `-w 4`
  #    against a real Rails app a single curl probe cannot get answered
  #    inside 120s in the worst case, because the kernel keeps routing
  #    to a worker whose accept queue is already full.
  #
  # Detection: `RbConfig::CONFIG['host_os']` matching `linux` picks
  # `:reuseport`; everything else picks `:share`. Operators can pin the
  # mode explicitly with `HYPERION_WORKER_MODEL=share|reuseport` (used by
  # the test suite to exercise both paths on a single host).
  class Master
    DEFAULT_WORKER_COUNT     = nil # nil → Etc.nprocessors
    GRACEFUL_TIMEOUT_SECONDS = 30

    WORKER_MODELS = %i[reuseport share].freeze

    def self.detect_worker_model
      override = ENV['HYPERION_WORKER_MODEL']&.to_sym
      return override if WORKER_MODELS.include?(override)

      host_os = RbConfig::CONFIG['host_os'].to_s
      case host_os
      when /linux/ then :reuseport
      else :share # macOS, BSD, anything else: shared-FD model (Puma-style)
      end
    end

    # Pulls the four configurable HTTP/2 SETTINGS values out of the Config
    # and returns them as a Hash. Nils are stripped so an operator who
    # explicitly sets one to `nil` (meaning "leave protocol-http2 default in
    # place") doesn't accidentally send a SETTINGS entry with a nil value.
    # Empty hash → no override → Http2Handler skips the SETTINGS push.
    def self.build_h2_settings(config)
      # 1.7.0 (RFC A4): read from the nested `H2Settings` subconfig.
      # The flat-name forwarders on `Config` still work for callers
      # holding a 1.6.x reference, but Master is in-tree so we point
      # at the nested object directly to avoid the extra hop.
      h2 = config.h2
      {
        max_concurrent_streams: h2.max_concurrent_streams,
        initial_window_size: h2.initial_window_size,
        max_frame_size: h2.max_frame_size,
        max_header_list_size: h2.max_header_list_size
      }.compact
    end

    def initialize(host:, port:, app:, workers: DEFAULT_WORKER_COUNT,
                   read_timeout: Server::DEFAULT_READ_TIMEOUT_SECONDS, tls: nil,
                   thread_count: Server::DEFAULT_THREAD_COUNT, config: nil)
      @host         = host
      @port         = port
      @app          = app
      @workers      = workers || Etc.nprocessors
      @read_timeout = read_timeout
      @tls          = tls
      @thread_count = thread_count
      @config       = config || Hyperion::Config.new
      # 2.0 default flip (RFC A7): if the operator hasn't already
      # finalized the config (e.g. via the CLI bootstrap path), do it
      # now so the worker count for the auto-cap formula is the one
      # Master actually uses. `finalize!` is idempotent — a config the
      # CLI already finalized passes through unchanged.
      @config.finalize!(workers: @workers || 1)
      @graceful_timeout = @config.graceful_timeout || GRACEFUL_TIMEOUT_SECONDS
      @children     = {} # pid => worker_index
      @next_index   = 0
      @stopping     = false
      @worker_model = self.class.detect_worker_model
      @listener     = nil # populated only in :share mode
      @worker_max_rss_mb     = @config.worker_health.max_rss_mb
      @worker_check_interval = @config.worker_health.check_interval || 30
      @last_health_check     = 0  # monotonic seconds
      @cycling               = {} # pid => true while we wait for it to exit
    end

    def run
      install_signal_handlers
      # Record master PID + export to ENV BEFORE the first fork. Workers
      # inherit the env var via copy-on-write so AdminMiddleware can target
      # the master regardless of whether `Process.ppid` is meaningful in
      # the deployment (containerd / Docker run hyperion as PID 1, where
      # ppid would point at the host's init or 0). See Hyperion.master_pid.
      Hyperion.master_pid!(Process.pid)
      Hyperion.logger.info do
        {
          message: 'master starting',
          pid: Process.pid,
          workers: @workers,
          host: @host,
          port: @port,
          worker_model: @worker_model
        }
      end

      # Pre-allocate Rack env-pool entries and eager-touch lazy constants
      # BEFORE we fork. Children inherit the warm memory via copy-on-write
      # so the first batch of requests on each fresh worker doesn't pay
      # the allocation/autoload tax.
      Hyperion.warmup!

      # `before_fork` runs ONCE in the master before any worker is forked.
      # Operators use it to close shared resources (DB pools, Redis sockets)
      # so each child gets fresh connections rather than inheriting the
      # parent's open fds. Mirrors Puma's hook of the same name.
      #
      # IMPORTANT: must fire BEFORE the master binds its listening socket on
      # `:share` mode. In `:reuseport` mode the master never binds — workers
      # bind their own SO_REUSEPORT sockets after fork — so `before_fork`
      # there trivially runs "before any listener exists." Pre-1.6.3 we
      # bound the master listener first on `:share` and ran `before_fork`
      # afterwards, which made the two worker models hand off the lifecycle
      # asymmetrically: an operator using `before_fork` to mutate listening
      # behaviour saw a different world depending on host OS. Binding here
      # restores symmetry — in both modes `before_fork` precedes any socket.
      @config.before_fork.each(&:call)

      bind_master_listener if @worker_model == :share

      @workers.times { spawn_worker }

      supervise
    ensure
      # The master keeps the listener open across its lifetime so it can
      # respawn workers (the new fork inherits the same fd). It only gets
      # closed here once the master itself is exiting.
      @listener&.close
    end

    private

    def install_signal_handlers
      shutdown_r, shutdown_w = IO.pipe
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          shutdown_w.write_nonblock('!')
        rescue StandardError
          nil
        end
      end
      @shutdown_pipe = shutdown_r
      install_tls_rotation_handler
    end

    # Wire the master-side handler for the configured TLS ticket-key
    # rotation signal (default SIGUSR2). When the operator (or an
    # automated rotation cron) sends SIGUSR2 to the master, we re-emit
    # it to every live child so each worker flushes its session cache
    # and OpenSSL rolls a fresh ticket-encryption key.
    #
    # The master deliberately does NOT mutate its own listener context
    # in `:share` mode — the listening fd is shared across children, so
    # the children's per-context flushes already cover the resumption
    # pool. This keeps the master accept-loop free.
    def install_tls_rotation_handler
      return unless @tls

      sig = @config.tls.ticket_key_rotation_signal
      return if sig.nil? || sig == :NONE

      Signal.trap(sig.to_s) do
        @children.each_key do |pid|
          Process.kill(sig.to_s, pid)
        rescue StandardError
          # Worker already exiting / reaped — the next reap_and_respawn
          # cycle will replace it; rotation does not block on liveness.
          nil
        end
      end
    rescue ArgumentError
      Hyperion.logger.warn do
        {
          message: 'invalid tls.ticket_key_rotation_signal on master; rotation disabled',
          signal: @config.tls.ticket_key_rotation_signal
        }
      end
    end

    # Bind the listening socket in the master so children inherit the fd
    # via fork. Only used in :share mode (macOS / BSD).
    def bind_master_listener
      tcp = ::TCPServer.new(@host, @port)
      # Honour port: 0 (let kernel pick) — propagate the chosen port so
      # log lines and worker args reflect reality.
      @port = tcp.addr[1]

      if @tls
        ctx = TLS.context(cert: @tls[:cert], key: @tls[:key],
                          session_cache_size: @config.tls.session_cache_size)
        ssl_server = ::OpenSSL::SSL::SSLServer.new(tcp, ctx)
        ssl_server.start_immediately = false
        @listener = ssl_server
      else
        @listener = tcp
      end
    end

    def spawn_worker
      worker_index = @next_index
      @next_index += 1
      pid = fork do
        # Inside the child: clean signal traps; the worker installs its own.
        Signal.trap('INT', 'DEFAULT')
        Signal.trap('TERM', 'DEFAULT')
        worker_args = {
          host: @host, port: @port, app: @app,
          read_timeout: @read_timeout, tls: @tls,
          thread_count: @thread_count, config: @config,
          worker_index: worker_index,
          max_pending: @config.max_pending,
          max_request_read_seconds: @config.max_request_read_seconds,
          h2_settings: Master.build_h2_settings(@config),
          async_io: @config.async_io,
          # 1.7.0 RFC additive plumbing — all default to current
          # behaviour when the operator hasn't opted in.
          accept_fibers_per_worker: @config.accept_fibers_per_worker,
          h2_max_total_streams: @config.h2.max_total_streams,
          admin_listener_port: @config.admin.listener_port,
          admin_listener_host: @config.admin.listener_host,
          admin_token: @config.admin.token,
          # 1.8.0 Phase 4 — TLS session resumption knobs.
          tls_session_cache_size: @config.tls.session_cache_size,
          tls_ticket_key_rotation_signal: @config.tls.ticket_key_rotation_signal
        }
        # Hand the inherited socket to the worker in :share mode. In
        # :reuseport mode the worker binds its own with SO_REUSEPORT.
        worker_args[:listener] = @listener if @worker_model == :share
        Worker.new(**worker_args).run
      end
      @children[pid] = worker_index
    end

    def supervise
      until @stopping
        # Block on the shutdown pipe + reap dead children.
        ready, = IO.select([@shutdown_pipe], nil, nil, 1.0)

        if ready
          begin
            @shutdown_pipe.read_nonblock(64)
          rescue StandardError
            nil
          end
          @stopping = true
          break
        end

        reap_and_respawn
        maybe_cycle_workers
      end

      shutdown_children
    end

    def reap_and_respawn
      while (result = Process.waitpid2(-1, Process::WNOHANG))
        pid, _status = result
        next unless @children.key?(pid)

        Hyperion.logger.warn { { message: 'worker died, respawning', worker_pid: pid } }
        @children.delete(pid)
        @cycling.delete(pid)
        spawn_worker unless @stopping
      end
    rescue Errno::ECHILD
      # No children — happens during shutdown.
    end

    # Periodically poll worker RSS and SIGTERM any that exceed the configured
    # cap. The dying worker is reaped by `reap_and_respawn` on the next tick,
    # which also clears the @cycling guard so the slot can be replaced.
    # Skips entirely when no cap is configured — zero overhead by default.
    def maybe_cycle_workers
      return unless @worker_max_rss_mb

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if now - @last_health_check < @worker_check_interval

      @last_health_check = now
      @children.each_key do |pid|
        next if @cycling.key?(pid)

        rss = WorkerHealth.rss_mb(pid)
        next unless rss && rss > @worker_max_rss_mb

        Hyperion.logger.warn do
          {
            message: 'cycling worker for memory',
            worker_pid: pid,
            rss_mb: rss,
            limit_mb: @worker_max_rss_mb
          }
        end
        @cycling[pid] = true
        begin
          Process.kill('TERM', pid)
        rescue StandardError
          # process already gone — reap_and_respawn will handle it
        end
      end
    end

    def shutdown_children
      Hyperion.logger.info do
        { message: 'master draining', graceful_timeout: @graceful_timeout }
      end
      @children.each_key do |pid|
        Process.kill('TERM', pid)
      rescue StandardError
        nil
      end

      deadline = Time.now + @graceful_timeout
      until @children.empty? || Time.now > deadline
        begin
          pid, _status = Process.waitpid2(-1, Process::WNOHANG)
          if pid
            @children.delete(pid)
          else
            sleep 0.1
          end
        rescue Errno::ECHILD
          break
        end
      end

      # Force-kill stragglers.
      @children.each_key do |pid|
        Process.kill('KILL', pid)
      rescue StandardError
        nil
      end
      @children.clear

      Hyperion.logger.info { { message: 'master exiting' } }
      # Drain per-thread access buffers + sync stdio so the 'master draining'
      # / 'master exiting' lines (and any in-flight access-log lines from
      # threads that never reached the 4-KiB flush threshold) actually reach
      # the operator's log file before the process exits on SIGTERM.
      Hyperion.logger.flush_all
    end
  end
end
