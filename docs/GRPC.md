# gRPC on Hyperion (2.12-F+)

> See [README.md](../README.md) for the headline overview.

Hyperion's HTTP/2 path supports gRPC unary, server-streaming,
client-streaming, and bidirectional RPCs over the **Rack 3 trailers
contract**. Any response body that responds to `#trailers` gets a
final `HEADERS` frame (with `END_STREAM=1`) carrying the trailer map
after the DATA frames.

Plain HTTP/2 traffic without the gRPC content-type keeps the unary
buffered semantics — no behaviour change for non-gRPC clients.

---

## Why Rack 3 trailers

The gRPC wire protocol expects status to come **after** the body, in
trailers. Rack 3.0 standardised `Response#trailers` for exactly this
case. Hyperion's `Http2Handler` checks for the method on the response
body; if present, it flushes DATA frames first, then a HEADERS frame
with the trailer map (`grpc-status`, `grpc-message`, …), then sets
`END_STREAM`.

Most non-gRPC apps will never define `#trailers`; the check is a
single `respond_to?` call on the response body and adds zero
measurable overhead to the non-gRPC path.

## Minimal unary handler

```ruby
class GrpcBody
  def initialize(reply)
    @reply = reply
  end

  def each
    yield @reply
  end

  def trailers
    { 'grpc-status' => '0', 'grpc-message' => 'OK' }
  end

  def close
    # release any per-RPC resources
  end
end

run lambda do |env|
  request = env['rack.input'].read
  reply   = handle(request)
  [200, { 'content-type' => 'application/grpc' }, GrpcBody.new(reply)]
end
```

Boot with:

```sh
bundle exec hyperion --tls-cert config/cert.pem --tls-key config/key.pem \
  -p 9443 bench/grpc_stream.ru
```

ALPN on the TLS handshake will select `h2`, the request will arrive
on a fresh stream, and the response writer will emit DATA + trailers
+ END_STREAM in that order. `grpcurl` and `ghz` both consume this
shape transparently.

## Streaming RPCs

- **Server-streaming.** `each` yields one DATA frame per call. The
  Http2Handler flushes between yields; the client sees back-pressure
  via the h2 flow-control window, identical to a long-running unary
  body.
- **Client-streaming.** `env['rack.input']` is a streaming IO that
  blocks on `read` until the next DATA frame lands on the stream.
  Read-side back-pressure also goes through h2 flow control.
- **Bidirectional.** Both halves run concurrently on independent
  fibers within the same h2 stream's task. The handler can `read`
  and `yield` interleaved.

## Reproducible benchmark

```sh
GHZ=/path/to/ghz TRIALS=3 DURATION=15s WARMUP_DURATION=3s \
  bash bench/grpc_stream_bench.sh
```

Three trials on the bench host's 16-vCPU box (2.14-D, ghz `--insecure
-c50 -n50000` against `bench/grpc_stream.ru`):

| Workload | Hyperion median r/s | Falcon `async-grpc` median r/s | Δ |
|---|---:|---:|---:|
| Unary | 1,618 | 1,512 | +7% |
| Server-streaming (100 replies/RPC) | 138 | n/a | Hyperion-only |

`bench/grpc_stream_falcon_bench.sh` runs the same shape against
Falcon's `async-grpc` (Falcon's own gRPC server, not Rack-shaped). It
fails closed if `async-grpc` isn't reachable; the Hyperion harness
runs independently of it.

`grpc_stream.proto` is the canonical proto file consumed by both
harnesses. Add new RPCs there and re-bench both servers from one
schema.
