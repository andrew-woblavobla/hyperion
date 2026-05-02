# Configuration

> See [README.md](../README.md) for the headline overview.

Three layers, in precedence order:

1. Explicit CLI flag (highest).
2. Environment variable.
3. `config/hyperion.rb` (Ruby DSL).
4. Built-in default (lowest).

---

## CLI flags (most-used)

| Flag | Default | Notes |
|---|---|---|
| `-b, --bind HOST` | `127.0.0.1` | |
| `-p, --port PORT` | `9292` | |
| `-w, --workers N` | `1` | `0` → `Etc.nprocessors`. |
| `-t, --threads N` | `5` | OS-thread Rack handler pool per worker. `0` → run inline (debugging only). |
| `-C, --config PATH` | `config/hyperion.rb` if present | Ruby DSL file. |
| `--tls-cert PATH` / `--tls-key PATH` | nil | PEM cert + key for HTTPS. |
| `--[no-]async-io` | off | Run plain HTTP/1.1 under `Async::Scheduler`. Required for `hyperion-async-pg` on plain HTTP. |
| `--preload-static DIR` | nil | Preload static assets at boot (repeatable, immutable). Rails apps auto-detect from `Rails.configuration.assets.paths`. |
| `--admin-token-file PATH` | unset | Auth file for `/-/quit` and `/-/metrics`. Refuses world-readable files. |
| `--worker-max-rss-mb MB` | unset | Master gracefully recycles a worker exceeding MB RSS. |
| `--max-pending COUNT` | unbounded | Per-worker accept-queue cap before HTTP 503 + `Retry-After: 1`. |
| `--idle-keepalive SECONDS` | `5` | Keep-alive idle timeout. |
| `--graceful-timeout SECONDS` | `30` | Shutdown deadline before SIGKILL. |

Run `bin/hyperion --help` for the full set including:
`--max-body-bytes`, `--max-header-bytes`, `--max-request-read-seconds`
(slowloris defence), `--h2-max-total-streams`,
`--max-in-flight-per-conn`, `--tls-handshake-rate-limit`, and the
`--[no-]yjit` / `--[no-]log-requests` toggles.

## Environment variables

`HYPERION_LOG_LEVEL`, `HYPERION_LOG_FORMAT`, `HYPERION_LOG_REQUESTS`
(`0|1|true|false|yes|no|on|off`), `HYPERION_ENV`,
`HYPERION_WORKER_MODEL` (`share|reuseport`),
`HYPERION_IO_URING_ACCEPT` (`0|1`), `HYPERION_H2_DISPATCH_POOL`,
`HYPERION_H2_NATIVE_HPACK` (`v2|ruby|off`), `HYPERION_H2_TIMING`.

## Config file (`config/hyperion.rb`)

Same shape as Puma's `puma.rb`. Auto-loaded if present. Strict DSL:
unknown methods raise `NoMethodError` at boot — typos surface
immediately, not silently.

```ruby
# config/hyperion.rb
bind '0.0.0.0'
port 9292

workers      4
thread_count 10

# tls_cert_path 'config/cert.pem'
# tls_key_path  'config/key.pem'

read_timeout      30
idle_keepalive     5
graceful_timeout  30

log_level    :info
log_format   :auto
log_requests true

# nil = auto (1.4.0+), true = inline-on-fiber everywhere,
# false = pool everywhere
async_io nil

before_fork do
  ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord)
end

on_worker_boot do |worker_index|
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
end
```

A documented sample lives at
[`config/hyperion.example.rb`](../config/hyperion.example.rb).

## Optional io_uring accept loop

Linux 5.x+, opt-in via `HYPERION_IO_URING_ACCEPT=1`. Multishot accept
+ per-conn RECV/WRITE/CLOSE state machine on top of liburing. One
`io_uring_enter` per N requests instead of N×3 syscalls. Compiles
out cleanly without liburing — the `accept4` path stays the
fallback. macOS keeps using `accept4`. Default-flip to **on** moves
to 2.15 with a fresh 24h soak.

## Compatibility

| Component | Version |
|---|---|
| Ruby | 3.3+ (transitive `protocol-http2 ~> 0.26` floor) |
| Rack | 3.x |
| Rails | verified up to 8.1 |
| Linux kernel | 5.x+ for io_uring opt-in; 4.x+ otherwise |
| macOS | works (TLS, h2, WebSockets, `accept4` fallback path) |

Per-Rack-3-spec: auto-sets `SERVER_SOFTWARE`, `rack.version`,
`REMOTE_ADDR`, IPv6-safe `Host` parsing, CRLF guard. The
`Hyperion::FiberLocal.install!` opt-in shim handles the residual
`Thread.current.thread_variable_*` footgun in older Rails idioms;
modern Rails 7.1+ already uses Fiber storage natively.
