# Hyperion observability

The `/-/metrics` endpoint exposes Prometheus text format on the same listener as
the application (or on the dedicated admin sidecar listener configured via
`admin.listener_port`). Auth is the same `X-Hyperion-Admin-Token` header used
for `/-/quit`. Scrape every 15-30s; metrics are cumulative and operator-time-
diffable.

This document covers the **2.4-C metric surface**: counters carried over from
1.x continue to emit unchanged; the new families below give operators
visibility into the 2.x knobs (permessage-deflate, fairness, kTLS, io_uring,
ThreadPool queue).

A pre-built Grafana dashboard is checked in at
[`docs/grafana/hyperion-2.4-dashboard.json`](grafana/hyperion-2.4-dashboard.json).
Import it via Grafana → Dashboards → New → Import.

## Metric reference

### `hyperion_request_duration_seconds` — histogram

Per-route HTTP request duration, in seconds.

* **Buckets:** `0.001, 0.005, 0.025, 0.1, 0.5, 2.5, 10` seconds (plus implicit
  `+Inf`).
* **Labels:** `method`, `path`, `status` (`2xx` / `4xx` / `5xx` / etc).
* **Path templating:** dynamic segments are coalesced via
  `Hyperion::Config#metrics.path_templater`. The default templater replaces
  integer segments with `:id` and UUIDs with `:uuid`. Operators with
  Rails-style routes plug in their own:

  ```ruby
  # config.rb
  metrics do
    path_templater Hyperion::Metrics::PathTemplater.new(rules: [
      [/\b\d+\b/, ':id'],
      [/\b[0-9a-f-]{36}\b/i, ':uuid'],
      [/\/[a-z][a-z0-9-]+/, '/:slug']
    ])
  end
  ```

* **Sample query (p99 by route):**
  ```promql
  histogram_quantile(0.99,
    sum by (le, method, path) (
      rate(hyperion_request_duration_seconds_bucket[5m])
    )
  )
  ```
* **Operator action:** alert on p99 > SLO target. Use the heatmap variant in
  the dashboard to spot bimodal distributions (e.g., a slow path hidden inside
  a generally-fast route).

### `hyperion_per_conn_rejections_total` — counter

Per-connection in-flight cap rejections (the 503 + Retry-After path on the
`max_in_flight_per_conn` knob from 2.3-B).

* **Labels:** `worker_id` (process pid).
* **Sample query:**
  ```promql
  sum by (worker_id) (rate(hyperion_per_conn_rejections_total[5m]))
  ```
* **Operator action:** non-zero rate means a single upstream connection is
  pipelining requests faster than the worker can drain them. Either:
  - Raise `max_in_flight_per_conn` (lets one upstream conn use more workers).
  - Lower it on the upstream (more even fan-out across upstream conns).
  - Add workers / threads to absorb the burst.

### `hyperion_websocket_deflate_ratio` — histogram

Per-message permessage-deflate compression ratio (`original_bytes /
compressed_bytes`).

* **Buckets:** `1.5, 2, 5, 10, 20, 50` (× compression).
* **No labels** — this is a process-wide effectiveness gauge, not a per-route
  one. WS per-route observability is a separate follow-up.
* **Sample query:**
  ```promql
  histogram_quantile(0.50,
    sum by (le) (rate(hyperion_websocket_deflate_ratio_bucket[5m]))
  )
  ```
* **Operator action:** if the p50 ratio is < 2× over a 24h window, the CPU
  spent on Zlib is not worth the bandwidth saving — switch
  `websocket.permessage_deflate` to `:off`. Below 1.5× the bucket count drops
  off the bottom, which itself is the signal.

### `hyperion_tls_ktls_active_connections` — gauge

Per-worker count of currently-active TLS connections whose `TLS_TX` is being
driven by the kernel module (kTLS).

* **Labels:** `worker_id`.
* **Sample query:**
  ```promql
  sum by (worker_id) (hyperion_tls_ktls_active_connections)
  ```
* **Operator action:** if `tls.ktls = :auto/:on` is configured but this gauge
  is consistently zero, kTLS isn't engaging — check the kernel module is
  loaded (`lsmod | grep tls`), the negotiated cipher is one of
  `AES-128-GCM`/`AES-256-GCM`/`CHACHA20-POLY1305`, and the OpenSSL build
  exposes `OP_ENABLE_KTLS`. A non-zero gauge confirms the boot-log line, which
  fires only on the first handshake per worker.

### `hyperion_io_uring_workers_active` — gauge

Whether this worker is using the io_uring accept policy (1 = yes, 0 = epoll).

* **Labels:** `worker_id`.
* **Sample query:**
  ```promql
  sum(hyperion_io_uring_workers_active)
  ```
* **Operator action:** confirms `io_uring: :auto/:on` is engaging on Linux ≥
  5.6. Mismatch with worker count (sum < `workers`) means the runtime probe
  failed on some workers — check kernel `sysctl kernel.io_uring_disabled`
  and seccomp policy.

### `hyperion_threadpool_queue_depth` — gauge

Snapshot of the worker ThreadPool inbox depth as of the last scrape.

* **Labels:** `worker_id`.
* **Sample query:**
  ```promql
  max by (worker_id) (hyperion_threadpool_queue_depth)
  ```
* **Operator action:** sustained non-zero queue depth = thread pool is
  saturated and connections / requests are queueing. Either bump
  `thread_count`, or check the app for blocking I/O that should be moved to a
  background job.

## Wire format

Hyperion's exporter renders the standard Prometheus text format v0.0.4. Each
metric family gets a `# HELP` and `# TYPE` line; histograms emit
`_bucket{le="..."}` lines per cumulative bucket plus `_sum` and `_count`
lines; gauges and counters emit one line per label tuple. The body is
content-typed `text/plain; version=0.0.4; charset=utf-8`, so any standard
Prometheus exporter or Grafana data source consumes it directly.

## Cardinality note

The default path templater is enough for REST-shape APIs. The histogram label
combinations are bounded to `methods × routes × status_classes` — usually
under a thousand series per worker. If your operator has cardinality alerts,
tune `path_templater` to be more aggressive (collapse all dynamic segments to
`:dyn`, etc.) or set `metrics.enabled = false` to opt out.

## Disabling the new surface

If the metric volume is unwanted (CI runs, ephemeral workers), turn the new
surface off:

```ruby
metrics do
  enabled false
end
```

The legacy unlabeled counters (`hyperion_requests_total`, status family,
…) keep emitting — that surface predates 2.4-C and is operator-immutable.

## Custom request lifecycle hooks (2.5-C)

Most production Rails apps wire their own APM agent — NewRelic,
AppSignal, DataDog, OpenTelemetry — and need a callback at the
request boundary to start/finish a transaction or span. Pre-2.5-C the
only seam was a monkey-patch on `Hyperion::Adapter::Rack#call`. 2.5-C
exposes the lifecycle as a first-class API on `Hyperion::Runtime`:

```ruby
runtime = Hyperion::Runtime.default        # or Server.new(runtime: …)

runtime.on_request_start do |request, env|
  # fires AFTER env is built, BEFORE app.call
  # `env` is the live Rack env Hash — middleware can stash anything
  # the app or the after-hook needs to read.
end

runtime.on_request_end do |request, env, response, error|
  # fires AFTER app.call returns or raises
  #   * `response`  — [status, headers, body] tuple, or nil if app raised
  #   * `error`     — the StandardError the app raised, or nil on success
end
```

Hooks fire in registration order (FIFO). Hook errors are caught and
logged with the block's `source_location` — they do **not** break the
dispatch chain or the response. When **no hooks are registered** the
adapter skips dispatch entirely (one `Array#empty?` check); per-request
allocation count stays at the 2.5-B baseline.

### NewRelic

```ruby
require 'newrelic_rpm'

runtime.on_request_start do |request, env|
  env['nr.tx'] = NewRelic::Agent::Tracer
                   .start_transaction(name: "Controller/#{request.path}",
                                      category: :web)
end

runtime.on_request_end do |_request, env, response, error|
  tx = env['nr.tx']
  next unless tx

  if error
    NewRelic::Agent.notice_error(error)
  elsif response
    NewRelic::Agent.add_custom_attributes(http_status: response[0])
  end
  tx.finish
end
```

### AppSignal

```ruby
runtime.on_request_start do |request, env|
  env['appsignal.tx'] = Appsignal::Transaction.create(
    SecureRandom.uuid, Appsignal::Transaction::HTTP_REQUEST, request
  )
end

runtime.on_request_end do |_request, env, response, error|
  tx = env['appsignal.tx']
  next unless tx

  tx.set_error(error) if error
  tx.set_metadata('status', response[0].to_s) if response
  Appsignal::Transaction.complete_current!
end
```

### OpenTelemetry

```ruby
tracer = OpenTelemetry.tracer_provider.tracer('hyperion')

runtime.on_request_start do |request, env|
  env['otel.span'] = tracer.start_span(
    "HTTP #{request.method} #{request.path}",
    attributes: {
      'http.method' => request.method,
      'http.target' => request.path,
      'http.host'   => request.header('host')
    },
    kind: :server
  )
end

runtime.on_request_end do |_request, env, response, error|
  span = env['otel.span']
  next unless span

  if error
    span.record_exception(error)
    span.status = OpenTelemetry::Trace::Status.error(error.message)
  elsif response
    span.set_attribute('http.status_code', response[0])
  end
  span.finish
end
```

### DataDog

```ruby
runtime.on_request_start do |request, env|
  env['dd.span'] = Datadog::Tracing.trace(
    'rack.request',
    service: 'web',
    resource: "#{request.method} #{request.path}",
    span_type: 'web'
  )
end

runtime.on_request_end do |_request, env, response, error|
  span = env['dd.span']
  next unless span

  if error
    span.set_error(error)
  elsif response
    span.set_tag('http.status_code', response[0])
  end
  span.finish
end
```

### Plain Prometheus — per-route counters

The built-in `hyperion_request_duration_seconds` histogram covers
status × method × route templates registered via the path templater. To
add **custom** labels (tenant, plan, feature flag) not covered by the
built-in surface, hook in:

```ruby
require 'prometheus/client'

ROUTE_HITS = Prometheus::Client.registry.counter(
  :app_route_hits_total,
  docstring: 'Per-route hits with custom labels',
  labels: %i[route tenant plan]
)

runtime.on_request_end do |request, env, response, _error|
  next unless response

  ROUTE_HITS.increment(labels: {
    route:  env['hyperion.route_template'] || request.path,
    tenant: env['HTTP_X_TENANT_ID'] || 'unknown',
    plan:   env['app.current_plan']  || 'free'
  })
end
```

Keep label cardinality bounded — Prometheus flat-files one time series
per `(metric, label-tuple)`; an unbounded user-id label here is a fast
path to OOM in your scrape target.

### Multi-tenant isolation

Each `Hyperion::Server` can carry its own Runtime — the hook registry
is per-Runtime, not process-global:

```ruby
tenant_a_runtime = Hyperion::Runtime.new
tenant_b_runtime = Hyperion::Runtime.new
tenant_a_runtime.on_request_start { |req, env| TenantA::Tracer.start(req, env) }
tenant_b_runtime.on_request_start { |req, env| TenantB::Tracer.start(req, env) }

Hyperion::Server.new(app: tenant_a_app, runtime: tenant_a_runtime, ...)
Hyperion::Server.new(app: tenant_b_app, runtime: tenant_b_runtime, ...)
```

`Runtime.default` is the back-compat path — calls to `Hyperion.metrics`,
`Hyperion.logger`, and (now) on-request hooks registered against
`Runtime.default` apply to every Server that does **not** pass an
explicit `runtime:` kwarg.
