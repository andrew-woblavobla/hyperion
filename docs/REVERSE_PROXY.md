# Hyperion behind a reverse proxy

Most production deployments front Hyperion with nginx, an AWS ALB, or
similar. This guide covers the headers, config, and gotchas that matter.

## Why this matters

Hyperion can serve TLS + HTTP/2 directly, but in practice operators put it
behind a proxy for cert renewal, WAF, geo-blocking, request mirroring, and
shared infra. When you do, four things change:

- `REMOTE_ADDR` is the **proxy IP**, not the client IP
- Hyperion does NOT auto-promote `https://` based on `X-Forwarded-Proto`
- The admin endpoints (`/-/quit`, `/-/metrics`) are still reachable through
  the proxy unless you block them at the edge
- ALB → target HTTP/2 silently breaks WebSocket upgrades

## Client IP (`REMOTE_ADDR` semantics)

Hyperion sets `REMOTE_ADDR` from the actual TCP peer. Behind a proxy that
peer is the proxy itself, not the end user. To reach the real client IP:

**Rails apps** — use `request.remote_ip`. Rails consults
`config.action_dispatch.trusted_proxies` and walks `X-Forwarded-For` past
trusted hops:

```ruby
# config/application.rb
config.action_dispatch.trusted_proxies = [
  IPAddr.new('10.0.0.0/8'),    # ALB / nginx subnet
  IPAddr.new('127.0.0.1')
]
```

**Rack apps** — use `Rack::Request#ip` (same logic, smaller surface). Or
mount `Rack::Attack`/`Rack::Deflater`-style middleware that rewrites
`REMOTE_ADDR` from `X-Forwarded-For` once you've validated the source.

Do NOT trust `X-Forwarded-For` blindly — anyone can send it. Trust only
hops you control.

## TLS termination + URL scheme

When the proxy terminates TLS and forwards plain HTTP, Hyperion sees
`http://` and Rails will generate `http://` URLs unless told otherwise.

Three options, in order of preference:

1. **Rails: `config.force_ssl = true`** — generates `https://` URLs and
   issues a 301 for `http://` requests. Honours `X-Forwarded-Proto`
   automatically when the request comes from a trusted proxy.
2. **Rack: `use Rack::SSL`** — same idea for non-Rails apps.
3. **App-level read of `HTTP_X_FORWARDED_PROTO`** — only as a last resort.

Hyperion does not rewrite `env['rack.url_scheme']` itself. Schema promotion
is the app's call (it's a security decision: lying about scheme can mask
mixed-content bugs in dev).

## Other forwarded headers

| Header               | Hyperion sees it as           | Who consumes it          |
|----------------------|-------------------------------|--------------------------|
| `X-Forwarded-Host`   | `HTTP_X_FORWARDED_HOST`       | Rails (when trusted)     |
| `X-Forwarded-Port`   | `HTTP_X_FORWARDED_PORT`       | Rails (when trusted)     |
| `X-Forwarded-Proto`  | `HTTP_X_FORWARDED_PROTO`      | Rails / `force_ssl`      |
| `X-Forwarded-For`    | `HTTP_X_FORWARDED_FOR`        | `Rack::Request#ip`       |
| `X-Real-IP`          | `HTTP_X_REAL_IP`              | App-specific (nginx idiom) |

Hyperion does not strip incoming forwarded headers — apps + the proxy
must agree on which ones to trust.

## Sample: nginx

Bare-bones reverse proxy with Unix-socket upstream, h2 to client,
HTTP/1.1 to Hyperion:

```nginx
upstream hyperion_app {
  server unix:/var/run/hyperion.sock;
  # Or for TCP: server 127.0.0.1:9292;
  keepalive 64;  # reuse upstream connections — big throughput win
}

server {
  listen 443 ssl http2;
  server_name app.example.com;
  ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;

  # Block Hyperion's admin surface at the edge.
  location /-/ { return 404; }

  location / {
    proxy_pass http://hyperion_app;
    proxy_http_version 1.1;
    proxy_set_header Connection "";          # required with `keepalive`
    proxy_set_header Host              $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $http_host;

    proxy_buffering    off;   # critical for SSE / streaming bodies
    proxy_read_timeout 60s;
  }
}
```

Notes:
- `proxy_http_version 1.1` + `proxy_set_header Connection ""` enables
  HTTP keep-alive to upstream. Without these, every request opens a fresh
  TCP+ HTTP handshake to Hyperion.
- `proxy_buffering off` is required if your app emits Server-Sent Events,
  large file streams, or any body that should reach the client as it's
  written. Default-on buffering will collect the whole response first.

## Sample: AWS ALB

ALB target group settings that work with Hyperion:

| Setting               | Value                                               |
|-----------------------|-----------------------------------------------------|
| Protocol              | **HTTP/1.1** (not HTTP/2 — see below)               |
| Port                  | 9292 (or whatever Hyperion binds)                   |
| Target type           | `instance` or `ip` (both fine)                      |
| Health-check path     | `/` or a dedicated `/up` route                      |
| Health-check protocol | HTTP                                                |
| Stickiness            | usually off; enable only if your app requires it    |
| Deregistration delay  | ≥ `graceful_timeout` (default 30s) so drain finishes |

**Critical**: ALB target-group `ProtocolVersion` MUST be `HTTP1`, not
`HTTP2`. ALB-to-target HTTP/2 strips the WebSocket upgrade headers, so
Action Cable / any WS client that touches the same hostname will fail with
`426 Upgrade Required` from the ALB. Client-side h2 (browser ↔ ALB) is
fine — that's terminated on the listener, not the target.

ALB injects `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Port`
automatically. Trust the VPC subnet ranges in
`config.action_dispatch.trusted_proxies`.

## Hyperion-specific gotchas

### `--bind 0.0.0.0` for cross-host proxies

The default `--bind 127.0.0.1` only accepts localhost connections. If
nginx runs on the same box (Unix socket or `127.0.0.1:9292`) the default
is fine. If the proxy lives on another host (ALB, dedicated nginx box),
bind to `0.0.0.0` and rely on security groups / iptables for isolation:

```sh
bundle exec hyperion --bind 0.0.0.0 --port 9292 config.ru
```

### Lock down admin endpoints at the edge

`AdminMiddleware` is token-protected when enabled, but the safer default
is to make `/-/quit` and `/-/metrics` simply unreachable from the public
internet. The nginx sample above does this with `location /-/ { return 404; }`.
For ALB, add a listener rule that returns 404 for path `/-/*` (or use a
separate target group that the public listener doesn't route to).

For Prometheus scraping, the usual pattern is one of:
- Scrape Hyperion directly over the private network (proxy doesn't see it)
- Expose `/-/metrics` on a separate listener bound to the management
  subnet only
- Allow `/-/metrics` through the proxy but require the bearer token AND
  source-IP allowlist

### HTTP/2 chaining is not a problem

If you serve h2 to clients via the proxy AND the proxy speaks h2 to
Hyperion, you'll multiplex twice. In practice this never happens — nginx
and ALB both default to HTTP/1.1 on the upstream/target leg, even when
they accept h2 from clients. No action needed.

### Keep `read_timeout` longer than the proxy's idle timeout

Both nginx (`proxy_read_timeout`) and ALB (idle timeout, default 60s)
will close idle upstream connections. If Hyperion's `read_timeout` is
shorter, Hyperion closes first and the proxy retries on a fresh
connection — wasting the keep-alive savings. Set Hyperion's
`read_timeout` to match or exceed the proxy's idle timeout.

## TLS direct (no proxy)

Hyperion serves TLS natively:

```sh
bundle exec hyperion --tls-cert config/certs/fullchain.pem \
                     --tls-key  config/certs/privkey.pem \
                     --port 9443 config.ru
```

This works for small / single-tenant deployments. Going proxyless means
the operator owns: cert renewal, OCSP stapling, cipher updates, h2 perf
tuning, and DDoS absorption. Most production teams put nginx or an ALB
in front anyway — Hyperion is happy either way.

## Troubleshooting

**Clients see `REMOTE_ADDR` as the proxy IP** — expected. Use
`request.remote_ip` (Rails) or trust `X-Forwarded-For` via `Rack::Request#ip`.

**Rails generates `http://` URLs in production** — set `force_ssl = true`,
add the proxy subnet to `trusted_proxies`.

**WebSocket / Action Cable fails through ALB with 426** — switch the
target-group `ProtocolVersion` from HTTP2 to HTTP1.

**SSE / streaming responses arrive in one chunk** — set `proxy_buffering off`
in nginx, or use ALB (which doesn't buffer).

**Public traffic can hit `/-/quit`** — block `/-/*` at the proxy with the
`location /-/ { return 404; }` snippet above.
