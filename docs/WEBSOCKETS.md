# WebSockets on Hyperion (2.1.0+)

Hyperion 2.1.0 adds first-class WebSocket support to the same single-binary
server you use for HTTP/1.1 + HTTP/2 + TLS. ActionCable, faye-websocket, and
hand-rolled Rack apps all work without an extra reverse proxy or sidecar.

This page describes the surface, the limits, and the recipes.

---

## What you get

- **RFC 6455 baseline** — full HTTP/1.1 → WebSocket upgrade handshake,
  intercepted transparently by the Rack adapter before the app sees `env`.
  Validates method, version, `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`,
  optional `Origin` allow-list, optional subprotocol selection.
- **Rack 3 full hijack** — `env['rack.hijack?']` returns `true` on a valid
  upgrade; the app calls `env['rack.hijack'].call` to detach the socket from
  Hyperion's request lifecycle. Hyperion then ignores the Rack tuple, removes
  the connection from keep-alive accounting, and never touches the socket
  again — the application owns it.
- **Text + binary messages** — `recv` returns `[:text, "..."]` or
  `[:binary, "..."]` after reassembling fragments. UTF-8 validation on text
  frames per RFC 6455 §8.1.
- **Ping / pong** — auto-pong with the ping payload per §5.5.2; observable
  via `on_ping` / `on_pong` hooks but not suppressible (compliance-by-default).
- **Close handshake with code + reason** — peer-initiated close returns
  `[:close, code, reason]` from `recv` and writes a close echo. Locally
  initiated `ws.close(code: 1000, reason: …, drain_timeout: 5)` writes our
  close, drains for the peer's matching close, then tears the socket down.
- **Configurable per-message size cap** — `max_message_bytes:` (default 1 MiB)
  bounds reassembly; over-cap continuations trigger close 1009.
- **Server-side unmasked frames + GVL-releasing C unmask** — outbound frames
  are unmasked per RFC 6455 §5.1; inbound mask XOR runs in
  `ext/hyperion_http/websocket.c` with the GVL released on payloads large
  enough to amortise the release cost. JRuby / TruffleRuby fall back to a
  pure-Ruby XOR with the same surface.
- **Idle / keepalive supervision** — `idle_timeout:` (default 60 s) emits
  close 1001 after no traffic; `ping_interval:` (default 30 s) sends
  proactive pings to keep NAT mappings warm. Both kwargs accept `nil` to
  disable. Implemented via `IO.select`, so it cooperates with the fiber
  scheduler under `--async-io`.

## What you DON'T get (2.1.0 limits)

These are intentionally out of scope for 2.1.0:

- **WebSocket over HTTP/2 (RFC 8441 Extended CONNECT)** — h2 streams continue
  to see `env['rack.hijack?'] == false`. Plumbing Extended CONNECT through
  the h2 stream multiplexer is its own work item; clients that need
  WebSockets get HTTP/1.1 today. ALPN auto-falls-back, so this is invisible
  to browsers.
- **permessage-deflate compression (RFC 7692)** — added in 2.3.0; see
  ["permessage-deflate (2.3.0)"](#permessage-deflate-230) below.
- **Send-side fragmentation** — `Connection#send` writes a single `FIN=1`
  frame regardless of payload size. Browsers and well-behaved clients
  handle multi-MB single frames; if a use case for opt-in
  `fragment_threshold:` shows up, we'll add it later.

If you need any of the above today, terminate WS at nginx / haproxy in front
of Hyperion. The above will land in 2.2.x as use cases accumulate.

---

## Quickstart — minimal Rack echo app

Five-message echo, raw on the public surface. The app reads
`env['hyperion.websocket.handshake']` (the validated handshake tuple from
WS-2), takes the socket via `env['rack.hijack']`, writes the 101 response,
and hands the socket to `Hyperion::WebSocket::Connection`.

```ruby
# config.ru
require 'hyperion'
require 'hyperion/websocket/connection'

run lambda { |env|
  result = env['hyperion.websocket.handshake']
  if result.nil? || result.first != :ok
    return [400, { 'content-type' => 'text/plain' }, ['expected ws upgrade']]
  end

  socket = env['rack.hijack'].call
  socket.write(
    Hyperion::WebSocket::Handshake.build_101_response(result[1], result[2])
  )

  ws = Hyperion::WebSocket::Connection.new(
    socket,
    buffered: env['hyperion.hijack_buffered'],
    subprotocol: result[2]
  )

  5.times do
    type, payload = ws.recv
    break if type == :close || type.nil?
    ws.send(payload, opcode: type)
  end

  ws.close(code: 1000, reason: 'bye')
  [-1, {}, []]   # Rack tuple ignored after hijack — convention is [-1, {}, []]
}
```

Run it:

```sh
bundle exec hyperion -p 9292 config.ru
# Then connect with any WS client:
websocat ws://127.0.0.1:9292/echo
```

`Hyperion::WebSocket::Handshake.build_101_response` builds the canonical
101 response (per RFC 6455 §4.2.2): status line, `Upgrade: websocket`,
`Connection: Upgrade`, `Sec-WebSocket-Accept`, optional
`Sec-WebSocket-Protocol`. You don't have to roll your own.

---

## ActionCable recipe

ActionCable speaks RFC 6455 over `env['rack.hijack']`, which Hyperion now
provides. **No sidecar, no separate Action Cable process, no nginx WS
upgrade** — your Rails app's existing `/cable` mount works on a single-binary
Hyperion deploy.

`config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount ActionCable.server => '/cable'
  # ... rest of your app
end
```

`config/cable.yml` and channel files unchanged from a Puma-or-Falcon-with-
bundled-cable deploy.

`config/hyperion.rb` — no special config required, but if you want clean
worker shutdown:

```ruby
on_worker_shutdown do
  ActionCable.server.restart if defined?(ActionCable)
end
```

Action Cable ships its own driver on top of Rack hijack (via
`websocket-driver` / `nio4r`), so it does not need
`Hyperion::WebSocket::Connection` directly. If you'd rather use Hyperion's
wrapper for a custom Cable-style server, see the next recipe.

**Single-binary deploy:** one `hyperion -w 4 -t 10 config.ru` process serves
HTTP, HTTP/2, TLS, **and** ActionCable from the same listener. The Rails-on-
Puma split-deploy ("puma for HTTP, separate cable container for WS") is no
longer required.

---

## faye-websocket recipe

`faye-websocket-ruby` reads `env['rack.hijack?']` and takes the socket via
`env['rack.hijack']`. The Hyperion adapter satisfies both — no Hyperion-
specific changes are needed.

```ruby
require 'faye/websocket'

run lambda { |env|
  if Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)

    ws.on(:message) { |event| ws.send(event.data) }
    ws.on(:close)   { |event| ws = nil }

    ws.rack_response   # the [-1, {}, []] sentinel; Hyperion already detached the socket
  else
    [200, { 'content-type' => 'text/plain' }, ['hello']]
  end
}
```

Same single-binary deploy story as ActionCable.

---

## Configuration

Per-connection knobs are kwargs on `Hyperion::WebSocket::Connection.new`:

```ruby
Hyperion::WebSocket::Connection.new(
  socket,
  buffered: env['hyperion.hijack_buffered'],   # carry-over bytes from Hyperion's read buffer
  subprotocol: env['hyperion.websocket.handshake'][2],
  max_message_bytes: 1 * 1024 * 1024,           # default 1 MiB; over-cap → close 1009
  ping_interval: 30,                            # seconds; nil to disable
  idle_timeout: 60                              # seconds of no traffic before close 1001; nil to disable
)
```

Handshake-time knobs sit on `Hyperion::WebSocket::Handshake.validate`:

```ruby
Hyperion::WebSocket::Handshake.validate(
  env,
  origin_allow_list: %w[https://example.com https://app.example.com],
  subprotocol_selector: ->(offers) { offers.find { |s| %w[json.v1 binary.v1].include?(s) } }
)
```

You don't normally call `validate` yourself — the Rack adapter does it for
you and stashes the result in `env['hyperion.websocket.handshake']`. The
exception is if you're writing a middleware that wants to reject the upgrade
before the app sees it; in that case, call `validate` and write your own
4xx response.

`HYPERION_WS_ORIGIN_ALLOW_LIST` (comma-separated) is a process-wide env-var
fallback for the origin allow-list, intended as an operator escape hatch.
Per-app config via the full `Hyperion::Config` DSL is on the 2.2.x roadmap.

---

## permessage-deflate (2.3.0)

Hyperion 2.3.0 adds RFC 7692 [permessage-deflate](https://datatracker.ietf.org/doc/html/rfc7692):
per-message DEFLATE compression for WebSocket payloads. Chat / pubsub /
ActionCable workloads see **5–20× wire-bandwidth reduction** with a small
CPU cost on each side; for nginx-fronted deployments the saving lands
straight on the egress bill.

### How to enable

```ruby
# config/hyperion.rb
Hyperion::Config.load do
  websocket do
    permessage_deflate :auto   # default — accept if the client offers
    # permessage_deflate :on   # require it; reject the handshake otherwise
    # permessage_deflate :off  # never advertise; keep 2.2.x behaviour
  end
end
```

The default is `:auto`. Hyperion advertises permessage-deflate only when
the client's request carries a usable
`Sec-WebSocket-Extensions: permessage-deflate` offer; clients that don't
offer it (older Safari, hand-rolled clients) keep getting plain frames.

The Connection wrapper picks up the negotiated parameter set from the 4th
slot of `env['hyperion.websocket.handshake']`:

```ruby
result = env['hyperion.websocket.handshake']  # [:ok, accept, sub, ext]
ws = Hyperion::WebSocket::Connection.new(
  socket,
  buffered: env['hyperion.hijack_buffered'],
  subprotocol: result[2],
  extensions: result[3]   # {} when no extension was negotiated
)
```

If you build the 101 response by hand, render the negotiated extension
parameters with `Handshake.format_extensions_header`:

```ruby
ext_value = Hyperion::WebSocket::Handshake.format_extensions_header(result[3])
extras = ext_value ? { 'sec-websocket-extensions' => ext_value } : {}
socket.write(Hyperion::WebSocket::Handshake.build_101_response(result[1], result[2], extras))
```

### Negotiated parameters (RFC 7692 §7.1.1)

| Parameter | Meaning | Default |
|---|---|---|
| `server_max_window_bits` | LZ77 window for server→client. Smaller = less memory, less compression. | 15 |
| `client_max_window_bits` | LZ77 window for client→server. | 15 |
| `server_no_context_takeover` | Reset the deflate dictionary between messages on the server side. Lower compression but bounded memory per connection. | false |
| `client_no_context_takeover` | Same, for client→server messages. | false |

Hyperion accepts any combination the client offers; with multiple
parameter sets in the request, the first usable one wins per RFC 7692 §5.1.

### Compression-bomb defense (RFC 7692 §8.1)

A malicious client can ship a tiny compressed payload that decompresses
to gigabytes. Hyperion applies the connection's `max_message_bytes` cap
(default 1 MiB) **after** decompression — the decompressor streams output
in 16 KiB chunks and short-circuits the moment the running total would
exceed the cap. The connection then closes 1009 (Message Too Big) and
the next `recv` raises `StateError`. The wire-side cap is a loose
multiple of `max_message_bytes` (8×) so legitimate compressible messages
still squeeze through.

### Bandwidth savings (chat workload, local UNIXSocket bench)

`bench/ws_deflate_bench.rb` sends 1000 chat-style JSON messages (typical
shape: `{type:"message",user_id:…,body:"…"}`, ~400 B uncompressed each)
through one Connection and measures wire bytes leaving the server:

| Mode | Bytes per message | Wire reduction |
|---:|---:|---:|
| Plain (no deflate) | 400.8 B | — |
| permessage-deflate | 19.7 B | **20.4× smaller** |

The 20× number is upper-bound — chat-style JSON has very repetitive
field names which the shared deflate dictionary picks up immediately.
For random binary or already-compressed payloads (images, h.264) the
saving is near-zero and you should leave the extension off (`:off` on
those routes) so the CPU cycles aren't wasted.

The msg/s drop on the bench (~40%) is the cost of deflate CPU on the
encode side; in production with multiple workers and the GVL released
on the surrounding C unmask path, the per-worker throughput drop is
smaller. The bandwidth saving is the headline win — bandwidth costs
move with bytes, not with dispatches.

### Operator notes

- Default `:auto` is backwards-compatible: clients that don't offer
  permessage-deflate keep getting plain frames. Flipping `:auto → :on`
  is a hardening lever for environments where you control the client
  population (mobile app, internal service mesh).
- Per-connection memory cost: ~256 KB for the deflate context (15-bit
  window × 8 buffers × overhead). For a 10k-conn idle ActionCable
  worker, that's ~2.5 GB resident — size your worker RSS cap accordingly,
  or pass `client_no_context_takeover` / `server_no_context_takeover`
  in the negotiated params to drop memory at the cost of compression.
- Control frames (ping / pong / close) are NEVER compressed (RFC 7692
  §6.1). Hyperion enforces this on both encode and decode paths; a
  ping-with-RSV1 from the client closes the connection 1002.

---

## Performance

The 2.1.0 e2e smoke test (`spec/hyperion/websocket_e2e_spec.rb`) runs a
real Hyperion server and a raw-TCP WS client through 100 echo round-trips.
On developer hardware (Apple Silicon, dev build) p50 echo round-trip lands
at **~0.18 ms** end-to-end (handshake → mask → server unmask → reassemble →
Rack app echo → server frame build → client unmask → parse). That's a
sanity benchmark, not a published number.

**Published bench numbers — 2.2.x fix-E (2026-04-30):**

| Workload | msg/s | p50 | p99 |
|---|---:|---:|---:|
| 10 conns × 1000 msgs × 1 KiB (`-t 5 -w 1`) | 6,463 | 0.76 ms | 1.03 ms |
| 200 conns × 1000 msgs × 1 KiB (`-t 256 -w 1`) | 5,346 | 37.19 ms | 43.12 ms |

Median of 3 runs each. **Dev-hardware floor — Apple Silicon dev box, NOT
openclaw-vm.** The 16-vCPU openclaw-vm bench host was unreachable this
session (SSH refused); the 50,000+ msg/s target shape from the 2.1.0
brief is the Linux + 16-vCPU number to publish, queued behind the next
openclaw window. See [`docs/BENCH_HYPERION_2_0.md`](BENCH_HYPERION_2_0.md#websocket-echo-210--22x-fix-e-bench-numbers)
for the full table + reproduction recipe.

**Multi-process bench — 2.3-D (2026-04-29):**

| Workload | msg/s | p50 | p99 |
|---|---:|---:|---:|
| 4 procs × 50 conns × 1000 msgs × 1 KiB (`-t 256 -w 1`) | 14,757 | 13.01 ms | 21.75 ms |
| 4 procs × 10 conns × 1000 msgs × 1 KiB (`-t 256 -w 1`) | 13,594 | 2.49 ms | 7.75 ms |

vs fix-E single-process baseline: **+176% msg/s on the 200-conn
throughput row, p99 cut in half** (43.12 ms → 21.75 ms). The fix-E
long tail at 200 conns was client-side GVL serialisation, not
server-side latency — splitting the client into 4 OS processes via
`bench/ws_bench_client_multi.rb` removes that bottleneck. Same
Apple Silicon dev box as the fix-E numbers above; openclaw-vm
rerun deferred (host SSH unavailable this session — recipe in
`docs/BENCH_HYPERION_2_0.md`).

**Operator note — published msg/s requires the multi-process bench.**
The single-process Ruby client tops out at ~5–6k msg/s on macOS and
~1.7k msg/s on Linux 16-vCPU before becoming client-CPU-bound. To
characterise Hyperion's *server* throughput, drive load with
`bench/ws_bench_client_multi.rb --procs N` (N = 4 is sufficient on a
laptop; size to vCPU count on a bench host).

Two operator notes from the bench:

- **`-t` is a hard cap on concurrent connections per worker.** Each
  WebSocket connection permanently hijacks a worker thread for its
  lifetime — once `-t` workers are holding sockets, additional
  upgrade attempts queue behind them. Size `-t` to expected
  concurrent-connection count + headroom.
- **Don't over-provision threads** for low-concurrency latency
  paths. The 10-conn / `-t 5` row above runs 2× faster on per-
  message latency than the same workload on `-t 256` — extra
  threads cost GVL contention without adding parallelism on a
  scheduler-bound shape.

The benchmark rackup itself lives at `bench/ws_echo.ru` (note the
`.ru` extension — the original `bench/ws_echo.rb` from 2.1.0 was
broken under `Rack::Builder.parse_file` because of the file
extension, fix-E added the `.ru` variant alongside it):

```sh
bundle exec hyperion -t 5 -w 1 -p 9888 bench/ws_echo.ru
ruby bench/ws_bench_client.rb --port 9888 --conns 10 --msgs 1000 \
                              --bytes 1024 --json
```

The wrapper's hot path is intentionally short — the `recv` loop spends most
of its time in the C `parse` + `unmask` primitives with the GVL released,
so YJIT and additional fiber concurrency both compound. The 2.3 follow-up
will add the openclaw-vm rerun + autobahn-testsuite RFC 6455 conformance
pass.

---

## RFC 6455 conformance — autobahn-testsuite

Hyperion ships an autobahn-testsuite fuzzingclient config so any
maintainer can run the canonical RFC 6455 conformance fuzzer against
the WS echo rackup. The config lives at
[`autobahn-config/fuzzingclient.json`](../autobahn-config/fuzzingclient.json);
reports drop into `./autobahn-reports/` (gitignored).

### How to run

```sh
# Terminal 1 — boot Hyperion's WS echo on :9888
bundle exec hyperion -t 64 -w 1 -p 9888 bench/ws_echo.ru

# Terminal 2 — run the fuzzer (requires Docker daemon)
docker run --rm \
  -v $PWD/autobahn-config:/config \
  -v $PWD/autobahn-reports:/reports \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/fuzzingclient.json

# Then open ./autobahn-reports/index.html in a browser.
```

The pip-install path (`pip install autobahntestsuite`) is Python-2
only and is no longer maintainable; Docker is the supported recipe.
On macOS dev boxes you'll need Docker Desktop running; on Linux
bench hosts the `crossbario/autobahn-testsuite` image (~280 MB)
ships pre-pulled if you've run autobahn before.

### Expected pass matrix (for reproducibility checks)

| Section | Coverage | Hyperion expectation |
|---|---|---|
| 1 — Framing | Basic frame layouts | 100% pass |
| 2 — Pings | Ping/pong correctness | 100% pass |
| 3 — Reserved bits | RSV1/2/3 validation | 100% pass *(2.3-C teaches RSV1=deflate; RSV2/3 still close 1002)* |
| 4 — Opcodes | Reserved opcode rejection | 100% pass |
| 5 — Fragmentation | Continuation frames, control frames mid-fragment | ≥ 95% pass |
| 6 — UTF-8 | Strict UTF-8 validation on text frames | 100% pass *(2.1.0 spec)* |
| 7 — Close handling | Close codes, payload validation | 100% pass |
| 9 — Limits / perf | Multi-MB messages | Excluded from default config (very long runtime; uncomment in `fuzzingclient.json` for a soak run) |
| 10 — Auto-fragmentation | Server-side fragmenting of large messages | 100% pass |
| 12 — permessage-deflate | Compressed echo round-trips | 100% pass *(2.3-C — first run after 2.3-C ship)* |
| 13 — permessage-deflate edge cases | Fragmented + compressed, sliding-window edges | ≥ 95% pass *(2.3-C)* |

### 2.3-D run status

**Deferred — Docker daemon not running this session, openclaw-vm
SSH unavailable.** The fuzzingclient config file is in place; a
maintainer with Docker can produce the report in ~5 minutes. Any
FAILED categories beyond the matrix above are 2.4 follow-ups —
2.3-D was scoped to land the recipe and run it where possible, not
to fix RFC violations the fuzzer might surface.

---

## See also

- [`CHANGELOG.md`](../CHANGELOG.md) — full per-stream notes for WS-1
  (Rack hijack), WS-2 (handshake), WS-3 (frame codec), WS-4 (connection
  wrapper).
- [`docs/RFC_2_0_DESIGN.md`](RFC_2_0_DESIGN.md) — original RFC; §6
  ("Out of scope for 2.0") now points here.
- [`spec/hyperion/websocket_e2e_spec.rb`](../spec/hyperion/websocket_e2e_spec.rb)
  — runnable smoke test, also serves as a worked example of the full stack.
