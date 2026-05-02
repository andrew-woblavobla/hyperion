# Server.handle direct routes

> See [README.md](../README.md) for the headline overview.

`Hyperion::Server.handle_static` and `Hyperion::Server.handle` register
direct routes that bypass the Rack adapter for hot paths. Both run on
the C accept loop — no Rack `env` is built, the response either comes
straight from a baked-at-boot byte buffer (`handle_static`) or from a
Ruby block called with the C-side `env` Hash (`handle`).

---

## `handle_static` — pre-baked responses

```ruby
Hyperion::Server.handle_static '/health', body: 'ok'
Hyperion::Server.handle_static '/version',
  body: APP_VERSION,
  status: 200,
  headers: { 'content-type' => 'text/plain' }
```

The response (status line + headers + body) is rendered to bytes at
boot. The C accept loop matches the request path against the
registered table; on a hit, it writes the pre-baked buffer directly
to the socket via `writev(2)`. No Ruby is invoked per-request. With
io_uring the path is one ring submission per write.

**Headline benchmark.** On the 2.15-A bench host (Linux 6.8 / 16 vCPU),
`handle_static` + `HYPERION_IO_URING_ACCEPT=1` + `-w 1 -t 32` hits
the 100k+ r/s range on hello-world. The same rackup with the default
`accept4` path holds in the high-10ks. See the
[bench results doc](BENCH_HYPERION_2_14.md) for medians.

When **not** to use `handle_static`:

- The response varies per request (use `handle` block form instead).
- The body is large (>1 MB). `handle_static` keeps the whole body in
  the per-route buffer; for static files prefer the `Rack::Sendfile`
  path with `static.ru` (sendfile-engaged).

## `handle` block form — dynamic routes on the C loop

```ruby
Hyperion::Server.handle(:GET, '/v1/ping') do |env|
  [200, { 'content-type' => 'text/plain' }, ['pong']]
end

Hyperion::Server.handle(:POST, '/v1/echo') do |env|
  body = env['rack.input'].read
  [200, { 'content-type' => 'application/octet-stream' }, [body]]
end
```

The block runs `app.call(env)`-style on the C accept loop's worker
thread. accept(2), recv(2), parse, and write(2) all release the GVL
— only the block body itself holds it. Multi-threaded workers
parallelise CPU-bound block bodies; `-t N` actually scales.

This is the right answer when:

- The response is dynamic (depends on env / DB / cache).
- You don't need the full Rack middleware stack.
- You want the C-loop fast-path (faster than the Rack adapter, which
  builds a full `env` Hash and walks middleware).

`Server.handle` returns nil; routes are registered globally on the
class. Re-registering a route raises `ArgumentError`. Routes are
matched before the Rack adapter, so `Server.handle '/health'` next to
a Rack `run -> app` will short-circuit `/health` even if the Rack app
also has a `/health` middleware.

## When the Rack adapter is the right answer

For the hot path, `handle_static` and `handle` are 5-30× faster than
the Rack adapter. But:

- Routes that need full Rack middleware (Rack::Auth::Basic, Rails'
  routing tree, etc.) must go through the Rack adapter.
- The Rack adapter is the **default**; you opt **into** the C-side
  fast path one route at a time.
- Mix freely: `Server.handle '/health'` + `run RailsApp` is the
  canonical pattern for production deploys (the health route bypasses
  Rails entirely).

## Reproducing benchmarks

```sh
# handle_static (2.15-A peak: 100k+ r/s with io_uring)
HYPERION_IO_URING_ACCEPT=1 bundle exec hyperion -w 1 -t 32 -p 9292 bench/hello_static.ru &
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9292/

# handle block (2.14-A: ~9k r/s on hello-world, 5-6k r/s on CPU JSON)
bundle exec hyperion -w 1 -t 5 -p 9292 bench/hello_handle_block.ru &
wrk -t4 -c100 -d20s --latency http://127.0.0.1:9292/
```

Each rackup file contains the canonical `Server.handle*` registration
plus a Rack `run` fallback for any path that doesn't match.
