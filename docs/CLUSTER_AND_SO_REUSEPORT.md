# Cluster mode + SO_REUSEPORT

> See [README.md](../README.md) for the headline overview.

`hyperion -w N` boots a master process that forks N workers. Workers
share the listener via the OS-appropriate mechanism: SO_REUSEPORT on
Linux (kernel-balanced accept), or master-bind + worker-fd-share on
macOS / BSD (where SO_REUSEPORT exists but doesn't load-balance).

---

## Worker model selection

Hyperion picks the worker model automatically:

| OS | Default model | Why |
|---|---|---|
| Linux 3.9+ | `:reuseport` | Each worker binds the same `(host, port)` with `SO_REUSEPORT`; the kernel hashes incoming SYNs across workers using a 4-tuple hash. |
| macOS / BSD | `:share` | `SO_REUSEPORT` on Darwin allows the bind but pins all accepts to the first listener. Hyperion master binds once and dups the fd to children. |
| Linux without `SO_REUSEPORT` (kernel < 3.9) | `:share` | Fallback. |

Override with `HYPERION_WORKER_MODEL=share|reuseport`. The `share`
model works everywhere; `reuseport` requires kernel + libc support.

## Fairness

The 2.12-E SO_REUSEPORT audit measured worker accept distribution on
Linux 6.8 under steady-state load: max-to-min ratio across 4 / 8 / 16
workers stayed within **1.004 – 1.011** (i.e. < 1.1% imbalance) for
runs of 200,000+ requests each. The kernel's hash distributes
roughly evenly even when individual flows are long-lived (HTTP/2
keep-alive).

Audit re-runnable via `bench/cluster_distribution.sh`.

## Lifecycle hooks

Inside `config/hyperion.rb`:

```ruby
before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
  Rails.cache.reset if defined?(Rails) && Rails.cache.respond_to?(:reset)
end

on_worker_boot do |worker_index|
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  $redis = Redis.new(pool_size: ENV.fetch('REDIS_POOL', 10).to_i)
  STDOUT.puts "[hyperion] worker #{worker_index} ready"
end

on_worker_shutdown do |worker_index|
  $redis&.disconnect!
end
```

`before_fork` runs in the master, **once** before any fork. It is the
right place to release any fd that should not be shared with workers
(Postgres connections, Redis sockets). `on_worker_boot` runs in each
child after fork; this is where you re-open the fds that were
released in `before_fork`. `on_worker_shutdown` runs at graceful
shutdown.

## RSS guard

`--worker-max-rss-mb MB` lets the master gracefully recycle a worker
that exceeds MB resident set size (kills it after the next idle
window, master immediately respawns). Useful for long-tail leaks in
gems you don't control.

## Graceful shutdown

`SIGTERM` → master signals workers to drain. Workers stop accepting,
finish in-flight responses, and exit. `--graceful-timeout SECONDS`
(default 30) is the deadline before SIGKILL. `POST /-/quit` (with
`X-Hyperion-Admin-Token`) is the equivalent over HTTP.

## Reproducing balance audit

```sh
# Boot 4 workers, hit the admin endpoint to dump per-worker counters.
bundle exec hyperion -w 4 -t 5 \
  --admin-token-file /tmp/hyperion-admin-token \
  -p 9810 bench/hello_static.ru &
wrk -t4 -c200 -d60s http://127.0.0.1:9810/
curl -H "X-Hyperion-Admin-Token: $(cat /tmp/hyperion-admin-token)" \
  http://127.0.0.1:9810/-/metrics | grep hyperion_c_loop_requests_per_worker
```

The `hyperion_c_loop_requests_per_worker_total{worker="N"}` series
gives the per-worker accept count. Compute max/min ratio to verify
balance.
