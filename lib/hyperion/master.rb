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
      @graceful_timeout = @config.graceful_timeout || GRACEFUL_TIMEOUT_SECONDS
      @children     = {} # pid => worker_index
      @next_index   = 0
      @stopping     = false
      @worker_model = self.class.detect_worker_model
      @listener     = nil # populated only in :share mode
      @worker_max_rss_mb     = @config.worker_max_rss_mb
      @worker_check_interval = @config.worker_check_interval || 30
      @last_health_check     = 0  # monotonic seconds
      @cycling               = {} # pid => true while we wait for it to exit
    end

    def run
      install_signal_handlers
      bind_master_listener if @worker_model == :share
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
      @config.before_fork.each(&:call)

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
    end

    # Bind the listening socket in the master so children inherit the fd
    # via fork. Only used in :share mode (macOS / BSD).
    def bind_master_listener
      tcp = ::TCPServer.new(@host, @port)
      # Honour port: 0 (let kernel pick) — propagate the chosen port so
      # log lines and worker args reflect reality.
      @port = tcp.addr[1]

      if @tls
        ctx = TLS.context(cert: @tls[:cert], key: @tls[:key])
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
          max_pending: @config.max_pending
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
