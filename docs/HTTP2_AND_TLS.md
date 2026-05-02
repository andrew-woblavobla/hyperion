# HTTP/2 + TLS on Hyperion

> See [README.md](../README.md) for the headline overview.

Hyperion serves HTTP/1.1 and HTTP/2 on the same listener via ALPN.
TLS terminates at the worker; cluster-mode TLS works (`-w N` paired
with `--tls-cert` / `--tls-key`).

---

## ALPN negotiation

When a client opens a TLS connection and advertises `h2` in its ALPN
list, Hyperion accepts and dispatches the rest of the connection on
the HTTP/2 path. Clients without `h2` (or any ALPN) fall through to
HTTP/1.1 over TLS.

The HTTP/2 path multiplexes streams within a single connection onto
fibers via `Async::Scheduler`. A slow handler on stream 7 does
**not** head-of-line-block stream 11; the response writer interleaves
DATA frames as each stream becomes ready.

## CLI / config knobs

| Flag | Default | Notes |
|---|---|---|
| `--tls-cert PATH` | nil | PEM-encoded server certificate. |
| `--tls-key PATH` | nil | PEM-encoded private key (matching `--tls-cert`). |
| `--tls-ciphers STR` | OpenSSL default | Comma-separated cipher suite list. |
| `--tls-handshake-rate-limit N` | unset | Throttle handshakes/sec to defend against TLS-renegotiation flood. |

```sh
bundle exec hyperion --tls-cert config/cert.pem --tls-key config/key.pem -p 9443 config.ru
```

## HTTP/2 settings

`--h2-max-total-streams N` caps a single connection's lifetime stream
count (defence against unbounded stream-id growth on long-lived h2
sessions). `--max-in-flight-per-conn N` rejects new streams when a
connection has too many in-flight requests; rejection is an h2
RST_STREAM with `REFUSED_STREAM`.

The HPACK encoder defaults to the C-glue path
(`HYPERION_H2_NATIVE_HPACK=v2`); set `=ruby` for the pure-Ruby
fallback or `=off` to force protocol-http2's reference encoder.

## kTLS (Linux 5.x+)

When the kernel has `tls.ko` loaded, Hyperion offloads bulk encrypt
to kernel TLS for non-AEAD cipher suites. `Hyperion.stats[:active_ktls_connections]`
is the live gauge. The handoff happens in `OpenSSL::SSL::SSLSocket`
hooks; if the kernel rejects the offload (unsupported cipher), the
connection silently keeps userspace TLS.

## HTTP/1.1 smuggling defences

- `Content-Length` AND `Transfer-Encoding: chunked` in the same
  request → 400 Bad Request (request-smuggling guard).
- `Transfer-Encoding` value ≠ `chunked` → 501 Not Implemented.
- Response header values containing CRLF → `ArgumentError` raised
  before the bytes reach the wire (response-splitting guard).

These behaviours are enforced inline in the Ruby header writer and
mirrored in the C-ext fast-path response builder — neither path can
emit a smuggled or split response.

## Reproduction

The 4-way TLS / h2 head-to-head lives at
[`bench/h2_falcon_compare.sh`](../bench/h2_falcon_compare.sh) and
[`bench/h2_rails_shape.sh`](../bench/h2_rails_shape.sh).

```sh
# h2 + TLS, hello-world Rack handler
bundle exec hyperion --tls-cert config/cert.pem --tls-key config/key.pem -p 9443 bench/hello.ru
h2load -c50 -m100 -n100000 https://127.0.0.1:9443/
```
