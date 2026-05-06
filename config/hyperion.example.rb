# frozen_string_literal: true

# Example Hyperion config. Copy to config/hyperion.rb and customize.
# Auto-loaded by `bundle exec hyperion config.ru` if present.
# Override with `bundle exec hyperion -C path/to/hyperion.rb config.ru`.

# Bind + listen
bind '0.0.0.0'
port 9292

# Concurrency
workers 4         # process count; 0 = Etc.nprocessors
thread_count 16   # OS-thread Rack handler pool per worker

# TLS (uncomment + point at your PEM files)
# tls_cert_path 'config/cert.pem'
# tls_key_path  'config/key.pem'

# Timeouts (seconds)
read_timeout      30 # per-connection read deadline
idle_keepalive 5 # keep-alive idle close
graceful_timeout  30 # SIGTERM drain window before SIGKILL

# Limits
max_header_bytes  64 * 1024
max_body_bytes    16 * 1024 * 1024

# Logging
log_level    :info     # :debug | :info | :warn | :error | :fatal
log_format   :auto     # :text | :json | :auto
log_requests true      # per-request access log (default ON)

# Compatibility
fiber_local_shim false # set true for Rails apps using Thread.current.thread_variable_*

# io_uring accept loop (Linux 5.6+ only). Default :off. Set :auto to
# enable when the runtime probe succeeds, or :on to require it.
# io_uring :off

# Hot-path io_uring (Linux 5.19+ only). Independent of `io_uring`
# above. Enables multishot accept + multishot recv + send SQEs on a
# single unified ring per worker. Default :off. See docs/IO_URING_HOTPATH.md.
# io_uring_hotpath :off

# Lifecycle hooks — mirror Puma's API.
before_fork do
  # Runs ONCE in the master before any worker forks.
  # Close shared resources (DB pool, Redis, file handles) so children get fresh ones.
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end

on_worker_boot do |_worker_index|
  # Runs in each worker after fork, before serving.
  # Reconnect the resources you closed in before_fork.
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end

on_worker_shutdown do |_worker_index|
  # Runs in each worker on graceful SIGTERM, after the server stops accepting.
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end
