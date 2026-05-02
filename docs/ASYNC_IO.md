# Async I/O (PG-bound apps)

> See [README.md](../README.md) for the headline overview.

`--async-io` runs plain HTTP/1.1 connections under `Async::Scheduler`.
One OS thread serves thousands of in-flight handler invocations as
fibers, each free to yield on I/O without blocking siblings.

This is the architecture that lets PG-bound Rails apps see
**dozens-of-times throughput** vs Puma's thread-pool model — but only
if the entire I/O stack is fiber-cooperative. Skip any one element
and you get parity with Puma (or worse).

---

## When `--async-io` actually helps

Three things must all be true:

1. `--async-io` on the CLI (or `async_io true` in `config/hyperion.rb`).
2. [`hyperion-async-pg`](https://github.com/andrew-woblavobla/hyperion-async-pg)
   loaded. Replaces the `pg` gem's blocking `PQexec` with an
   async-aware variant that yields on `IO.select` while the query is
   in flight.
3. A fiber-aware connection pool. `Hyperion::AsyncPg::FiberPool`,
   `async-pool`, or `Async::Semaphore` all work. **`connection_pool`
   does not** — its `Mutex` blocks the OS thread, defeating the
   point of fiber concurrency.

## Architectural ceiling

Without async I/O the throughput ceiling is `thread_count`. With it,
the ceiling is `connection_pool_size`. Hyperion's hyperion-async-pg
companion benchmarks single-worker `pool=200` at **2,381 r/s** on a
`pg_sleep(50ms)` workload, vs Puma `-t 5` at **56 r/s** on the same
hardware. The gap is `pool / threads = 40×` — exactly the ceiling
predicted by the model.

## Default vs opt-in

| Configuration | Default behaviour | Notes |
|---|---|---|
| `async_io: nil` (default) | Plain HTTP/1.1: thread-pool dispatch. TLS / h2: inline-on-fiber. | Best perf for the common case. |
| `async_io: false` | Force thread-pool everywhere, including TLS / h2. | Rare; most users don't want this. |
| `async_io: true` | Inline-on-fiber everywhere, including plain HTTP/1.1. | Required for `hyperion-async-pg`. |

The default is **deliberately not** `async_io: true`: Rails apps that
don't have a fiber-cooperative I/O stack are slower under Async (see
the [bench against `redis-rb`](BENCH_2026_04_27.md) for the real-app
numbers). Don't enable until your stack is end-to-end fiber-aware.

## Why TLS / h2 are always inline-on-fiber

The TLS handshake yields cooperatively via the scheduler — kept in
the Async wrap regardless of `async_io`. HTTP/2 streams spawn one
fiber per stream inside `Http2Handler`; those fibers need a current
scheduler. Forcing thread-pool dispatch on TLS / h2 would break both.

The 2.10-G dispatch-mode resolver in `lib/hyperion/server.rb`
encodes this matrix end-to-end; see `Hyperion::DispatchMode` for the
full state machine.

## Ruby version support

Async I/O requires Ruby 3.3+ for the `Fiber.scheduler` interface to
behave correctly under WebSocket hijack, and `async ~> 2.39` for the
scheduler-close-time fd lifecycle that 2.15-A's `start_async_loop`
outer rescue depends on.

## Reproduction

```sh
# PG-bound async (requires hyperion-async-pg + a running Postgres on 5432)
bundle exec hyperion --async-io -w 1 -t 1 -p 9810 bench/pg_concurrent.ru &
wrk -t4 -c200 -d20s --latency http://127.0.0.1:9810/

# Compare against Puma at the same -t (will be ~40× slower)
bundle exec puma -t 5:5 -w 1 -b tcp://127.0.0.1:9811 bench/pg_concurrent.ru &
wrk -t4 -c200 -d20s --latency http://127.0.0.1:9811/
```

The `pg_concurrent.ru` rackup, the connection pool sizing, and the
hyperion-async-pg gem all live in the
[hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg)
repo (deliberately decoupled from this repo so a `gem install
hyperion-rb` doesn't drag in the pg dependency).
