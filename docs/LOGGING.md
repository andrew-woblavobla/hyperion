# Logging

> See [README.md](../README.md) for the headline overview.

Default behaviour:

- `info` / `debug` → stdout, `warn` / `error` / `fatal` → stderr
  (12-factor).
- One structured access-log line per response, `info` level. Disable
  with `--no-log-requests` or `HYPERION_LOG_REQUESTS=0`.
- Format auto-selects: `RAILS_ENV=production` / `staging` → JSON;
  TTY → coloured text; piped output without env hint → JSON.

---

## Hot-path optimisations

The default access-log writer is the path most production deployments
hit a million times an hour. Hyperion's writer:

- Caches the iso8601 timestamp string per-thread; only re-rendered
  when the second tick changes.
- Hand-rolls the JSON line builder (no `JSON.generate` per request).
- Writes to a lock-free per-thread 4 KiB buffer; flushed on buffer
  full or periodic timer tick.

These together cost roughly 0.1 µs per logged line on the bench host —
negligible vs the per-request body work for any real handler.

## Sample output

Text (TTY default):

```
2026-04-26T18:40:04.112Z INFO  [hyperion] message=request method=GET path=/api/v1/health status=200 duration_ms=46.63 remote_addr=127.0.0.1 http_version=HTTP/1.1
```

JSON (production / piped):

```json
{"ts":"2026-04-26T18:38:49.405Z","level":"info","source":"hyperion","message":"request","method":"GET","path":"/api/v1/health","status":200,"duration_ms":46.63,"remote_addr":"127.0.0.1","http_version":"HTTP/1.1"}
```

## Format selection

| Trigger | Format |
|---|---|
| `HYPERION_LOG_FORMAT=json` (or `text`) | explicit override |
| `RAILS_ENV=production` / `staging` | JSON |
| stdout is a TTY | coloured text |
| stdout is a pipe (no env hint) | JSON |

Override with `--log-format json` / `--log-format text` on the CLI.

## Disabling per-request logs

Some operators run an upstream LB that already logs every request
(nginx, ALB access logs). To avoid duplicate logging:

```sh
bundle exec hyperion --no-log-requests config.ru
# or
HYPERION_LOG_REQUESTS=0 bundle exec hyperion config.ru
```

Boot-time, panic, and error logs always emit; only the per-request
access line is suppressed.

## Custom log fields

Application code can append to the per-request access log via the
Rack env:

```ruby
env['hyperion.log_extras'] = { user_id: 42, plan: 'pro' }
```

These keys merge into the structured line. Reserved keys (`ts`,
`level`, `message`, `method`, `path`, `status`, `duration_ms`,
`remote_addr`, `http_version`) are not overridable.
