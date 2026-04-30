# Migrating from Puma to Hyperion

A practical guide for Rails operators. Most apps need ~10 lines of config changes.

## TL;DR

```diff
# Gemfile
- gem 'puma'
+ gem 'hyperion-rb'

# Procfile (or systemd unit, or Dockerfile CMD)
- web: bundle exec puma -C config/puma.rb
+ web: bundle exec hyperion -C config/hyperion.rb config.ru
```

Then translate `config/puma.rb` → `config/hyperion.rb` per the table below.

## Fiber-cooperative I/O for PG-bound apps

If your app is bottlenecked on Postgres / external HTTP / Redis (not CPU), Hyperion 1.3.0 ships an opt-in mode that decouples concurrency from threads. Set `async_io: true` in your config (or pass `--async-io` on the CLI) and pair with the [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg) companion gem.

The bench picture (Ubuntu 24.04, 50 ms `pg_sleep`, 200 concurrent wrk conns):

- Puma `-t 5` + plain pg pool=5: 56 r/s, p99 3.88 s
- Puma `-t 30` + plain pg pool=30: 402 r/s, p99 880 ms
- Puma `-t 100` + plain pg pool=100: 1067 r/s, p99 557 ms
- Hyperion `--async-io -t 5` + hyperion-async-pg pool=200: **2381 r/s, p99 471 ms**

That's 5.9× Puma's tuned `-t 30` config. The trick: under `--async-io`, the OS-thread count is decoupled from in-flight-query count. Each fiber yields the OS thread on `recv()`; one accept-loop thread serves N concurrent in-flight queries (capped by your DB pool, not by `max_threads`).

Default is **off** so fiber-unaware apps keep 1.2.0's raw-loop fast path. Flip it on only when you've installed `hyperion-async-pg` (or another Async-aware driver) AND a fiber-aware connection pool — see the companion gem's README for the full matrix.

## Why migrate

- **ActionCable now works on a single-binary Hyperion deploy** (2.1.0+) — `mount ActionCable.server => '/cable'` runs in the same `hyperion` process as your HTTP/1.1, HTTP/2, and TLS traffic; no separate cable container, no nginx WS upgrade. See [`WEBSOCKETS.md`](WEBSOCKETS.md).
- **Same throughput or better** at parity threads on every Rails workload tested. With access logs default-ON, Hyperion still beats Puma on hello-world (1.27×), production-cluster (1.17×), and Linux DB-backed (~1.02×). With `--no-log-requests` the lead widens.
- **Structured access logs out of the box** — every request gets a JSON line with method/path/status/duration_ms/remote_addr. No `Rails::Rack::Logger` or `lograge` needed for basic operability.
- **HTTP/2 + TLS native** — no nginx required just to talk h2 to browsers.
- **Fiber-per-stream HTTP/2 multiplexing** — slow handlers don't head-of-line-block other streams on the same h2 connection.
- **Lifecycle hooks identical to Puma** (`before_fork`, `on_worker_boot`, `on_worker_shutdown`) — copy-paste from `puma.rb`.

## Why NOT migrate (yet)

- Hyperion requires **Ruby 3.3+** (transitively, via `protocol-http2`). Puma supports older.
- HTTP/2 semantic validation is over-permissive (h2spec ~77% conformance) — the wire layer is solid, but malformed h2 requests that strict servers reject are accepted by Hyperion. Most real clients never produce these. *(Tracked for 1.1.0.)*
- No native `daemonize` mode — use systemd, Foreman, or a process manager.
- No `Capistrano hot-restart` integration. Hyperion supports SIGTERM graceful shutdown; rolling restarts are the operator's job.
- No `phased restart` / `pumactl restart` (yet).

## Configuration mapping

| Puma DSL                                    | Hyperion equivalent                          | Notes |
|---------------------------------------------|----------------------------------------------|-------|
| `port 9292`                                 | `port 9292`                                  | identical |
| `bind 'tcp://0.0.0.0:9292'`                 | `bind '0.0.0.0'` + `port 9292`               | Hyperion separates host + port |
| `workers ENV.fetch('WEB_CONCURRENCY', 2)`   | `workers ENV.fetch('WEB_CONCURRENCY', 2).to_i` | identical (`workers 0` → CPU count) |
| `threads ENV.fetch('RAILS_MAX_THREADS', 5), ENV.fetch('RAILS_MAX_THREADS', 5)` | `thread_count ENV.fetch('RAILS_MAX_THREADS', 5).to_i` | Hyperion uses a single value (no min/max range) |
| `preload_app!`                              | always preloaded (no flag needed)            | Hyperion master loads the app once before forking |
| `before_fork { ... }`                       | `before_fork { ... }`                        | identical API |
| `on_worker_boot { |idx| ... }`              | `on_worker_boot { |idx| ... }`               | identical API; idx is the worker slot 0..N-1 |
| `on_worker_shutdown { |idx| ... }`          | `on_worker_shutdown { |idx| ... }`           | identical API |
| `worker_timeout 60`                         | `read_timeout 60`                            | per-connection read deadline |
| `worker_shutdown_timeout 30`                | `graceful_timeout 30`                        | drain window before SIGKILL |
| `ssl_bind '0.0.0.0', 9443, cert_path: ..., key_path: ...` | `port 9443` + `tls_cert_path` + `tls_key_path` | Hyperion accepts both leaf-only and chain PEM in `tls_cert_path` |
| `daemonize true`                            | (none — use systemd / Docker)                | |
| `pidfile '/var/run/puma.pid'`               | (none — use systemd `PIDFile=` or process supervisor) | |
| `state_path '/var/run/puma.state'`          | (none — `pumactl` not supported) | |
| `log_requests true`                         | `log_requests true` (default)                 | identical; default ON |
| `quiet true`                                | `log_requests false` + `log_level :warn`     | |

## Lifecycle hooks (copy-paste safe from Puma)

```ruby
# config/hyperion.rb
before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
  Sidekiq.configure_client { |c| c.redis = ... } if defined?(Sidekiq)
end

on_worker_boot do |worker_index|
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end

on_worker_shutdown do |worker_index|
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end
```

## Behavioural differences to know

### 1. Default-ON access logs go to stdout

Every request emits a structured JSON line (in production env auto-detect; coloured text on TTY). Format:

```json
{"ts":"...","level":"info","source":"hyperion","message":"request","method":"GET","path":"/api/v1/health","status":200,"duration_ms":46.63,"remote_addr":"127.0.0.1","http_version":"HTTP/1.1"}
```

If your app has `config.middleware.use Rails::Rack::Logger` or `lograge`, you'll get duplicate logs. Either:
- Disable Hyperion's: `--no-log-requests` flag or `log_requests false` in config.
- Disable Rails-side: remove the middleware or set `Rails.logger.level = :warn`.

Most operators prefer Hyperion's structured JSON (one schema, one source) and disable Rails-side request logging.

### 2. stdout is the canonical log destination

Logs go to **stdout** for info/debug, **stderr** for warn/error/fatal (12-factor convention). Puma defaults vary; if you redirected to files (`stdout_redirect '/var/log/puma.out'`), use shell redirect:

```sh
bundle exec hyperion config.ru >> /var/log/hyperion.out 2>> /var/log/hyperion.err
```

Better — use systemd or Docker's journald-style log handling.

### 3. `pumactl` has no analogue

Operations:

| Puma                        | Hyperion equivalent |
|-----------------------------|---------------------|
| `pumactl phased-restart`    | (manual rolling: spin up new master, drain old via SIGTERM) |
| `pumactl status`            | `Hyperion.stats` (in-process) |
| `pumactl stats`             | `Hyperion.stats` (in-process) |
| `pumactl reload`            | (none — restart) |

If you use Capistrano, replace `pumactl` calls with `kill -TERM <master_pid>` and `bundle exec hyperion -C config/hyperion.rb config.ru` to start fresh.

### 4. Per-OS worker model

- **Linux**: Hyperion uses `SO_REUSEPORT` (each worker independently binds; kernel hashes connections fairly). Same as Puma's default.
- **macOS / BSD**: Hyperion uses master-bind + worker-fd-share (Puma's pattern). Darwin's `SO_REUSEPORT` doesn't load-balance fairly, so Hyperion auto-selects the safer pattern.

Override with `HYPERION_WORKER_MODEL=share|reuseport` if needed.

### 5. HTTP/2 + TLS

Provide `tls_cert_path` + `tls_key_path` and Hyperion serves HTTPS. ALPN negotiates `h2` for clients that ask. Cluster-mode TLS works out of the box. The cert PEM may contain a chain (intermediate + leaf); Hyperion presents the full chain.

```ruby
# config/hyperion.rb
tls_cert_path 'config/certs/fullchain.pem'  # leaf + any intermediates
tls_key_path  'config/certs/privkey.pem'
port          9443
```

#### Operating Hyperion's HTTP/2 path — `h2.max_total_streams`

Hyperion 2.0.0 ships a per-process HTTP/2 admission cap that defaults to
`max_concurrent_streams × workers × 4` (= 512 streams on a single-worker
default config). The cap is sized for normal browser traffic — each browser
connection rarely opens more than ~50–100 multiplexed streams, and the 4×
headroom factor leaves room for legitimate fan-out.

Operators running **h2load benchmarks** (`h2load -c 1 -m 100 -n 5000` opens
5,000 streams on a single connection — well past the 512 default) or
**services with very heavy h2 fan-out** (e.g., gRPC servers with thousands
of long-lived RPCs over a small pool of connections) should set the knob
explicitly. Three knobs ship, in increasing precedence:

```ruby
# config/hyperion.rb — innermost, baked into the deploy
h2 do
  max_total_streams 8192        # explicit cap
  # max_total_streams :unbounded  # disable entirely (matches 1.x behaviour)
end
```

```sh
# CLI flag — per-invocation override (introduced in 2.2.x fix-D)
hyperion --h2-max-total-streams 8192 config.ru
hyperion --h2-max-total-streams unbounded config.ru   # restore 1.x behaviour

# Env var — outermost knob, useful for CI / bench harnesses
HYPERION_H2_MAX_TOTAL_STREAMS=unbounded hyperion config.ru
HYPERION_H2_MAX_TOTAL_STREAMS=10000 bundle exec hyperion config.ru
```

Precedence: env var > CLI flag > config file > built-in default. Use
`:unbounded` (DSL) / `unbounded` (CLI / env) to fully disable the cap;
typos in the env var warn and leave the resolved setting untouched (it
is a convenience knob, not a security boundary).

## Rolling out — recommended sequence

1. **Add hyperion-rb to your Gemfile alongside puma**, both versions present:
   ```ruby
   gem 'puma'
   gem 'hyperion-rb'
   ```

2. **Translate `config/puma.rb` → `config/hyperion.rb`** using the table above. Keep both files for the duration of rollout.

3. **Smoke locally**:
   ```sh
   bundle exec hyperion -C config/hyperion.rb config.ru
   curl http://localhost:9292/up
   ```
   Verify access logs appear, error responses look right, and your test suite passes against Hyperion.

4. **Deploy to one canary host** running Hyperion; keep the rest on Puma. Watch metrics + error rate for a day.

5. **Roll out cluster-wide** if canary is clean.

6. **Remove `gem 'puma'`** from the Gemfile.

## Troubleshooting

**`hyperion: command not found`** — `bundle exec hyperion`, not `hyperion` directly (unless your gem path is on `$PATH`).

**`bundle install` fails on Ruby 3.2** — Hyperion requires Ruby ≥ 3.3 (transitive `protocol-http2 ~> 0.26` constraint). Upgrade Ruby.

**Logs not visible when piped to a file** — should work as of 1.0.1 (`@out.sync = true`). If not, file an issue.

**TLS handshake failures with intermediate CA** — make sure your `tls_cert_path` PEM contains both leaf + intermediate(s) concatenated, not just the leaf. Hyperion auto-detects chain certs in the PEM.

**Higher memory than Puma** — Hyperion ships per-thread caches (timestamp, write buffer, metrics). Steady-state RSS is typically within 20% of Puma at the same `-w N -t M` config. If RSS keeps growing, file an issue with `Hyperion.stats` snapshots.

## Found a bug?

Open an issue at https://github.com/andrew-woblavobla/hyperion/issues with:
- Hyperion version (`Hyperion::VERSION`)
- Ruby version (`ruby -v`)
- Reproducer (Rack app + curl/wrk command)
- Relevant log lines (Hyperion's structured JSON makes this easy — `grep '"level":"error"'`)
