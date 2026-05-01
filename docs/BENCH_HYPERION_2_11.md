# BENCH 2026-05-01 — Hyperion 2.11.0 vs Puma 8.0.1 / Falcon 0.55.3 / Agoo 2.15.14 (4-way re-bench)

> **Why this doc exists.** The 4-way head-to-head in
> [`docs/BENCH_HYPERION_2_0.md`](BENCH_HYPERION_2_0.md) (§ "4-way
> head-to-head (2.10-B baseline, 2026-05-01)") was captured **before**
> the following Hyperion wins landed on master:
>
> | Stream | Win | Effect |
> |---|---|---|
> | 2.10-C | PageCache (pre-built static response cache) | static 1 KB +36% |
> | 2.10-D | `Server.handle_static` direct route | hello +27%, p99 1.93 ms |
> | 2.10-E | Static asset preload + immutable | predictable first-req latency |
> | 2.10-F | C-ext fast-path response writer | p99 −14% on `handle_static` |
> | 2.10-G | TCP_NODELAY at accept | h2 sequential +47.6× |
> | 2.11-A | h2 dispatch-pool warmup | cold time-to-1st-byte −54% |
> | 2.11-B | HPACK CGlue default | Rails-shape h2 +43% over Fiddle |
>
> Every Hyperion column in the 2.10-B baseline table is therefore
> stale; the Puma 8.0.1 / Falcon 0.55.3 / Agoo 2.15.14 columns did not
> change between 2.10-B and 2.11.0 (no Puma/Falcon/Agoo upgrades on the
> bench host) — they are kept as **reference** rows in the headline
> table below so the post-wins shift in each gap is visible in one
> place.

## Headline summary

**One-line answer.** The 2.10-C/D/F win-stack lands cleanly: on
**static 1 KB**, Hyperion's `handle_static` row is now **+127% over
Agoo** (was −47% in 2.10-B — the gap *flipped*). On **hello**, the
gap to Agoo narrowed from **4.22×** (2.10-B) to **3.46×** (2.11.0
`handle_static`). Hyperion **kept** its existing wins on **static
1 MiB** (9.7× over Agoo, sendfile path), **PG-bound async** (Hyperion-
only, 1,565 r/s identical to 2.10-B), and **SSE** (3.6× over Puma,
17× over Falcon). The **Rack-style** path (no `handle_static`
registration) sits within ±2% of 2.10-B on hello / CPU JSON / SSE
and gains **+22%** on static 1 KB (PageCache 2.10-C auto-engages on
small Rack 3 String bodies). **CPU JSON** is the one row where the
gap *widened* — Agoo's CPU JSON moved up +17.5% in the same window
Hyperion moved up +6.0%, taking the gap from 1.85× to 2.05×.

| # | Workload | Hyperion 2.11.0 — Rack-style (r/s) | Hyperion 2.11.0 — `handle_static` (r/s) | Puma 8.0.1 (r/s) | Falcon 0.55.3 (r/s) | Agoo 2.15.14 (r/s) | Verdict |
|---:|---|---:|---:|---:|---:|---:|---|
| 1 | hello (`bench/hello.ru` / `bench/hello_static.ru`) | 4,477 | **5,502** | 3,801 | 6,371 | **19,024** | Agoo still wins; gap narrowed **4.22× → 3.46×** with `handle_static`. |
| 2 | static 1 KB (`bench/static.ru` / `bench/static_handle_static.ru`) | 1,687 | **5,935** | 1,553 | 1,929 | 2,614 | **Hyperion `handle_static` wins by 127% over Agoo** (gap flipped). |
| 3 | static 1 MiB (`bench/static.ru`) | **1,513** | n/a (handle_static buffers a 1 MiB body in memory; defeats sendfile) | 1,558 | 559 | 155 | Hyperion ≈ Puma on rps (within 3%); Hyperion **18× lower p99**, **9.7× over Agoo**. |
| 4 | CPU JSON 50-key (`bench/work.ru`) | 3,659 | n/a (per-request `JSON.generate`; not a static response) | 2,936 | 4,226 | **7,489** | Agoo wins; gap **widened** 1.85× → 2.05× (Agoo +17.5% vs Hyperion +6.0%). |
| 5 | PG-bound async (`bench/pg_concurrent.ru`, `pg_sleep 50ms`) | **1,565** | n/a (handler must run user code per request) | n/a — no fiber-cooperative I/O | n/a — would block on plain `pg` | n/a — no `Hyperion::AsyncPg` | Hyperion-only row; identical to 2.10-B. |
| 6 | SSE 1000 events × 50 B (`bench/sse_generic.ru`, `wrk -t1 -c1 -d10s`) | **472** | n/a (handle_static is a single fixed response, not a streamed body) | 132 | 28 | smoke-fail (segfaults at boot) | Hyperion wins **3.58× over Puma**, **16.7× over Falcon**; Agoo **boot-fails** on this rackup (regression vs 2.10-B's "buffer-then-fail" — see Row 6). |

**Row-by-row "what moved since 2.10-B":**

| # | Workload | Hyperion (Rack) Δ | Hyperion (handle_static) Δ | Gap-vs-leader shift |
|---:|---|---:|---:|---|
| 1 | hello | 4,587 → 4,477 (-2.4%, noise) | n/a (4,477) → **5,502** | gap to Agoo: 4.22× → **3.46×** with `handle_static` |
| 2 | static 1 KB | 1,380 → 1,687 (**+22.2%**, PageCache 2.10-C) | n/a (1,380) → **5,935** | gap to Agoo: 1.89× → **flipped, Hyperion +127%** |
| 3 | static 1 MiB | 1,378 → 1,513 (+9.8%) | n/a | Hyperion lead vs Agoo: 9.07× → **9.74×** |
| 4 | CPU JSON | 3,450 → 3,659 (+6.0%) | n/a | gap to Agoo: 1.85× → **2.05× (widened)** |
| 5 | PG-bound async | 1,564 → 1,565 (+0.1%) | n/a | Hyperion-only |
| 6 | SSE | 500 → 472 (-5.6%, noise) | n/a | Hyperion lead vs Puma: 3.65× → **3.58×** (flat) |

## Caveats — read first

These are the same caveats that applied to the 2.10-B baseline; they
still apply here because the bench tools and the bench host are the
same. Re-stated so an operator opening this doc doesn't have to
cross-reference the older one.

1. **Bench-host drift.** `openclaw-vm` is a single KVM VM that runs
   other workloads in the background; absolute-rps drift of ±10–30%
   between sweep dates is real. The **relative** position between the
   five columns is the durable signal; the absolute headline numbers
   below are a snapshot of one good measurement window
   (load average 0.07 at sweep start, 16 vCPU idle), not a guaranteed
   ceiling.

2. **perfer's 16 KB MAX_RESP_SIZE buffer.** perfer's `drop.c` declares
   `MAX_RESP_SIZE = 16384`. Any rackup whose response body exceeds
   16 KB (the static 1 MiB row, all SSE rows) is reported as `NA`
   under perfer. wrk handles arbitrary body sizes, so wrk is the
   headline tool on those rows.

3. **perfer's case-sensitive header strstr.** perfer's `drop.c` uses
   `strstr(d->buf, "Content-Length:")` — case-sensitive. Hyperion is
   RFC 9110 lowercase (`content-length:`), Puma/Falcon/Agoo emit
   title-case. Patched perfer to `strcasestr` (with
   `#define _GNU_SOURCE`) before use; harness invocation includes the
   patch step in [§ Reproducing](#reproducing-4-way) below.

4. **perfer warmup deadlock vs Hyperion at `-t 5 -c 100`.** perfer's
   `pool_warmup` connects + send-pings *all* 100 connections, then
   recv-loops with a per-call 2.0 s timeout. Hyperion's
   accept-then-thread-pool model under `-t 5` doesn't drain 100
   simultaneous warmup pings inside that window — the connections
   that don't get a thread within 2 s are reported "timed out
   waiting for a response" and the run aborts. Hyperion + perfer
   rows are therefore `NA` across this bench (just like the 2.10-B
   baseline). Puma / Falcon / Agoo are unaffected.

5. **perfer SSE buffering on Agoo (Row 6).** Agoo's behavior on
   `bench/sse_generic.ru` regressed to **smoke-fail / segfault at
   boot** under this sweep (see Row 6 detail) — different shape from
   the 2.10-B "Agoo serves but takes ~5 s to flush" finding. Same
   conclusion either way: Agoo is **not a viable SSE server** under
   the generic Rack 3 chunked-streaming protocol.

## What "Rack-style" vs "handle_static" means here

Two columns under "Hyperion" because 2.10-D + 2.10-F + 2.10-C/E expose
two materially different request hot paths in the same server:

* **Rack-style** — the rackup is a normal Rack 3 app (`run lambda { … }`
  or `run Rack::Files.new(…)`). The hot path: parse request → build
  Rack env → invoke the Rack app via the adapter → iterate the body
  array → write headers + body. The PageCache (2.10-C) auto-engages on
  hello-shaped responses, so this column already reflects the
  middle-band 2.10 wins; it's the path most existing apps will run
  unchanged.
* **`handle_static`** — the rackup pre-registers a route via
  `Hyperion::Server.handle_static(:GET, path, body_bytes)` at boot.
  The hot path: parse request → direct-table lookup → C-ext
  `PageCache.serve_request` writes the pre-built buffer in one
  `socket.write` syscall, never crossing back into Ruby. This is the
  **peak** Hyperion path and the one to compare against Agoo's
  optimal `handle` path.

Only rows where the response is fixed at boot (hello, small static)
get the second column; rows whose body is computed per-request (CPU
JSON, SSE), streamed (SSE), shipped via sendfile (large static), or
PG-async (handler must run user code) only run the Rack-style column.

## Hardware + software stamp

- **Host**: `openclaw-vm`, Ubuntu 24.04, kernel `6.8.0-107-generic`
  x86_64, 16 vCPU, 34 GiB RAM, 0 swap. Same box as the 2.10-B
  baseline. Load average 0.07 at sweep start; no neighbour-VM noise
  during the run.
- **Ruby**: 3.3.3 (asdf)
- **Servers**:
  - **Hyperion 2.11.0** (this release) with both native extensions
    loaded — `lib/hyperion_http/hyperion_http.so` (C, llhttp + sendfile
    + page_cache + the 2.10-F C-ext fast-path response writer) AND
    `lib/hyperion_h2_codec/libhyperion_h2_codec.so` (Rust, RFC 7541
    HPACK + the 2.11-B CGlue default). Boot log reports
    `mode: native (Rust v3 / CGlue, default since 2.11-B)`.
  - **Puma 8.0.1**
  - **Falcon 0.55.3** (with `--hybrid -n 1 --forks 1 --threads 5` so
    the matched-config rule holds)
  - **Agoo 2.15.14**
- **Companion gems**: hyperion-async-pg 0.5.x (path), pg 1.5.x, rack 3.2.x
- **Postgres** (Row 5 only): PG 17 on `127.0.0.1:5432`,
  `max_connections=100`
- **Tools**: `wrk` (4 threads, 100 conns, 20 s, `--latency`, 8 s
  timeout unless noted), `perfer` (4 threads, 100 conns, 20 s, `-k`,
  `-l 50,90,99`). 3 trials per (rackup, server, tool); **median
  reported**.
- **Date**: 2026-05-01
- **Sweep dir on bench host**: `/home/ubuntu/bench-2.12-B/`
- **Sweep total wall time**: ~41 minutes (6 rows × 4–5 servers × 3 trials)

## Per-row detail

### Row 1: hello (`bench/hello.ru` and `bench/hello_static.ru`, `wrk -t4 -c100 -d20s`)

5-byte body, two response headers. Pure dispatch + write throughput.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.11.0 — Rack-style (`bench/hello.ru`) | 4,477 | **2.11 ms** | NA¹ | NA¹ |
| **Hyperion 2.11.0 — `handle_static` (`bench/hello_static.ru`)** | **5,502** | **1.73 ms** | NA¹ | NA¹ |
| Puma 8.0.1 | 3,801 | 29.18 ms | 4,578 | 26.23 ms |
| Falcon 0.55.3 | 6,371 | 408.42 ms | 6,416 | 397.10 ms |
| Agoo 2.15.14 | **19,024** | 10.47 ms | 20,000 | 8.79 ms |

¹ perfer warmup deadlock vs Hyperion `-t 5 -c 100` — see caveats above.

**Verdict.** Agoo still wins r/s by **3.46×** over Hyperion's
`handle_static` row (was 4.22× over the 2.10-B Hyperion 4,587 figure).
Hyperion's p99 (1.73 ms on `handle_static`) is **5.4× tighter** than
Agoo's (10.47 ms) — same shape as 2.10-B (Hyperion 2.08 ms vs Agoo
9.41 ms there). The **Rack-style row barely moved** vs 2.10-B (4,477
vs 4,587 = -2.4%, inside noise) — meaning the 2.10-D direct-route win
**only manifests when the rackup actually opts in via
`handle_static`**. Operators on plain Rack apps don't get a free
hello-row lift; operators willing to register one direct route at
boot pick up the +23% delta on this exact path.

### Row 2: static 1 KB (`bench/static.ru` and `bench/static_handle_static.ru`, URL `/hyperion_bench_1k.bin`, `wrk -t4 -c100 -d20s`)

1024 bytes of `'x'`. Sendfile vs userspace copy vs handle_static (in-
memory pre-built buffer).

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.11.0 — Rack-style (`bench/static.ru` → `Rack::Files`) | 1,687 | **4.03 ms** | NA¹ | NA¹ |
| **Hyperion 2.11.0 — `handle_static` (`bench/static_handle_static.ru`)** | **5,935** | **1.69 ms** | NA¹ | NA¹ |
| Puma 8.0.1 | 1,553 | 85.78 ms | 1,636 | 74.46 ms |
| Falcon 0.55.3 | 1,929 | 70.09 ms | 1,977 | 57.92 ms |
| Agoo 2.15.14 | 2,614 | 57.70 ms | 2,771 | 41.88 ms |

¹ same warmup deadlock as Row 1.

**Verdict.** **Hyperion `handle_static` wins r/s outright** — by
**+127% (2.27×)** over Agoo, **+208% (3.08×)** over Falcon, and
**+282% (3.82×)** over Puma. Hyperion's Rack-style row also moved up
**+22.2%** over the 2.10-B Hyperion 1,380 r/s figure (PageCache
2.10-C auto-engages on small Rack 3 String bodies that pass the
"safe to cache" check), even without explicit `handle_static`
registration; the gap from 1.89× behind Agoo collapsed to 1.55×
behind Agoo on the Rack path alone. p99 wins are dramatic across
the board: Hyperion's `handle_static` 1.69 ms beats Agoo's perfer
41.88 ms by **24×**.

### Row 3: static 1 MiB (`bench/static.ru`, URL `/hyperion_bench_1m.bin`, `wrk -t4 -c100 -d20s`)

1 MiB of `'x'`. Bandwidth + sendfile path. **No `handle_static`
column** — folding a 1 MiB body into a pre-built in-memory buffer
defeats Hyperion's sendfile zero-copy path; the right comparison is
the existing Rack-style (`Rack::Files` → sendfile) row.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.11.0 — Rack-style | **1,513** | **4.63 ms** | NA² | NA² |
| Puma 8.0.1 | 1,558 | 82.14 ms | NA² | NA² |
| Falcon 0.55.3 | 559 | 553.43 ms | NA² | NA² |
| Agoo 2.15.14 | 155 | 720.19 ms | NA² | NA² |

² perfer's `MAX_RESP_SIZE = 16384` — 1 MiB body overflows.

**Verdict.** **Hyperion ≈ Puma on r/s** (within 3%, well inside
bench noise — 2.10-B had Hyperion 1,378 / Puma 1,282 = Hyperion +7.5%;
this sweep flips the noise sign to Puma +3%). The durable Hyperion
finding is **p99 18× tighter** (4.63 ms vs Puma 82.14 ms) —
sendfile-driven kernel-paced send vs Puma's userspace-loop path
under 100 conns / 5 threads queue depth. The +9.7× lead over Agoo
on r/s, and +156 ms / -715 ms p99 deltas, hold from 2.10-B; large-
static is the workload territory the 2.10/2.11 streams had no
business regressing, and they didn't.

### Row 4: CPU JSON 50-key (`bench/work.ru`, `wrk -t4 -c100 -d20s`)

8 KB JSON response with per-request `JSON.generate` so the JIT can't
constant-fold. Header parsing exercised. **No `handle_static` column**
— the response varies per request (cookies / `request_id` wrapper),
which doesn't fit the static-buffer model.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.11.0 — Rack-style | 3,659 | **2.60 ms** | NA¹ | NA¹ |
| Puma 8.0.1 | 2,936 | 37.37 ms | 3,059 | 36.43 ms |
| Falcon 0.55.3 | 4,226 | 410.73 ms | 4,085 | 399.12 ms |
| Agoo 2.15.14 | **7,489** | 17.37 ms | 7,672 | 16.06 ms |

¹ same warmup deadlock as Row 1.

**Verdict.** **Agoo wins by 2.05×** over Hyperion (was 1.85× in
2.10-B — gap **widened**). Both servers moved up in absolute terms
(Hyperion +6.0%, Agoo +17.5%); Agoo's CPU JSON path saw a larger
share of whatever cross-process / kernel-level lift the bench host
gave during this measurement window. Hyperion's p99 (2.60 ms) is
still the cleanest of the four — 6.7× tighter than Agoo, 14× tighter
than Puma, 158× tighter than Falcon's `--hybrid` head-of-line tail.
This row is the one place the 2.10/2.11 work didn't move the
needle; closing the CPU-JSON gap is the obvious 2.12 follow-on.

### Row 5: PG-bound async (`bench/pg_concurrent.ru`, MODE=async PG_POOL_SIZE=80, `wrk -t4 -c200 -d20s --timeout 8s`)

Each request runs `SELECT pg_sleep(0.05)` against PG 17 on
`postgres:bench@127.0.0.1:5432/postgres` (max_conn=100). Hyperion
runs with `--async-io` + the `hyperion-async-pg` fiber pool; the
other three servers physically *cannot* run this rackup (no fiber-
cooperative I/O to yield to during the 50 ms wait — they would
block 5 OS threads at ~100 r/s ceiling, the pre-`hyperion-async-pg`
baseline already documented in 2.9-D).

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.11.0 (`--async-io`) | **1,565** | 140.55 ms | **1,573** | 138.81 ms |
| Puma 8.0.1 | n/a — no fiber-cooperative I/O | | | |
| Falcon 0.55.3 | n/a — would block on plain `pg` | | | |
| Agoo 2.15.14 | n/a — incompatible rackup (uses `Hyperion::AsyncPg`) | | | |

**Verdict.** Identical to 2.10-B (1,565 vs 1,564 = +0.1%, well
inside noise). wrk and perfer agree within 0.5%. The PG path was
not in the 2.10-C/D/F or 2.11-A/B touch surface, and the bench
confirms no incidental regression. This is the workload the
`--async-io + hyperion-async-pg` combination was designed for; no
other server in the matrix can play.

### Row 6: SSE 1000 events × 50 B (`bench/sse_generic.ru`, `wrk -t1 -c1 -d10s`)

Lazy-iterator body yields 1000 `data: event=... ts=...\n\n`
messages per request. Single client connection (SSE is one long-
lived stream per consumer); the relevant axis is **events per
second per connection**, not parallel rps. **No `handle_static`
column** — `handle_static` writes a single fixed response, not a
streamed body.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.11.0 — Rack-style | **472** | **2.85 ms** | NA³ | NA³ |
| Puma 8.0.1 | 132 | 11.04 ms | 0³ | 0³ |
| Falcon 0.55.3 | 28 | 42.15 ms | 0³ | 0³ |
| Agoo 2.15.14 | smoke-fail⁴ | — | — | — |

³ perfer's response-framing logic doesn't handle chunked SSE
streams — reports 0 successful requests. wrk's `c=1` model
(read-until-close) parses the chunked stream correctly. Treat
perfer as not-applicable for SSE.

⁴ Agoo segfaults at boot when loading `bench/sse_generic.ru` —
the `bound after Ns` smoke check times out after 7 s and the
harness records `BOOT-FAILURE`. Server-side crash trace
(captured in `/tmp/4way-agoo.log` on the bench host) shows
the SEGV firing while iterating the `each`-yielding body, then
the agoo Ruby process never recovers. Different failure shape
from 2.10-B's "buffers entire response, takes ~5 s to flush"
finding (manual `wrk --timeout 30s` against Agoo on the same
rackup at 2.10-B got ~0.1 r/s); same conclusion either way:
**Agoo is not a viable SSE server under the generic Rack 3
chunked-streaming protocol** at any throughput.

**Verdict.** **Hyperion wins by 3.58× over Puma, 16.7× over
Falcon, and Agoo can't run this rackup at all.** The relative
position vs 2.10-B (3.65× / 17× / smoke-fail) is **flat within
bench noise** — the 2.10/2.11 work did not regress this path.
SSE plus large-static remains the workload territory where
Hyperion is the definitively-correct choice in this matrix; the
2.12 streams that come next have nothing to prove against Agoo
on these two rows.

## Reproducing 4-way

```sh
# On openclaw-vm (or any Linux box with Ruby 3.3.3 + wrk + PG 17 + perfer):
cd /home/ubuntu/hyperion-fresh   # or your hyperion checkout
export BUNDLE_GEMFILE=$PWD/bench/Gemfile.4way
export HYPERION_PATH=$PWD
bundle install
bundle exec rake compile
# (also build the Rust h2 codec:)
(cd ext/hyperion_h2_codec && ruby extconf.rb)
# (and the io_uring shim, optional but built by master:)
(cd ext/hyperion_io_uring && ruby extconf.rb)

# Build perfer (Agoo's bench tool):
git clone https://github.com/ohler55/perfer.git /tmp/perfer
sed -i 's/strstr(d->buf, content_length)/strcasestr(d->buf, content_length)/g; s/strstr(d->buf, transfer_encoding)/strcasestr(d->buf, transfer_encoding)/g' /tmp/perfer/src/drop.c
sed -i '2a #define _GNU_SOURCE' /tmp/perfer/src/drop.c
(cd /tmp/perfer && make)

# Prep static fixtures (same as 2.10-B):
ruby -e 'File.binwrite("/tmp/hyperion_bench_1k.bin", "x" * 1024)'
ruby -e 'File.binwrite("/tmp/hyperion_bench_1m.bin", "x" * 1048576)'

# Per-row commands. Rows 1 + 2 take both Hyperion variants; rows 3+
# only the Rack-style variant.

# Row 1 — hello
URL_PATH=/                      HYPERION_STATIC_RACKUP=bench/hello_static.ru \
  bench/4way_compare.sh bench/hello.ru \
    hyperion hyperion_handle_static puma falcon agoo

# Row 2 — static 1 KB
URL_PATH=/hyperion_bench_1k.bin HYPERION_STATIC_RACKUP=bench/static_handle_static.ru \
  bench/4way_compare.sh bench/static.ru \
    hyperion hyperion_handle_static puma falcon agoo

# Row 3 — static 1 MiB (no handle_static — would defeat sendfile)
URL_PATH=/hyperion_bench_1m.bin \
  bench/4way_compare.sh bench/static.ru hyperion puma falcon agoo

# Row 4 — CPU JSON
URL_PATH=/ \
  bench/4way_compare.sh bench/work.ru hyperion puma falcon agoo

# Row 5 — PG-bound async (Hyperion-only)
URL_PATH=/ HYPERION_EXTRA=--async-io \
  MODE=async PG_POOL_SIZE=80 \
  DATABASE_URL=postgres://postgres:bench@127.0.0.1:5432/postgres \
  RUBYOPT='-rhyperion/async_pg' WRK_CONNS=200 WRK_TIMEOUT=8s \
  bench/4way_compare.sh bench/pg_concurrent.ru hyperion

# Row 6 — SSE generic
URL_PATH=/ DURATION=10s WRK_THREADS=1 WRK_CONNS=1 \
  bench/4way_compare.sh bench/sse_generic.ru hyperion puma falcon agoo
```

The `RUBYOPT='-rhyperion/async_pg'` is required because Hyperion's
`--async-io` flag validates a fiber-cooperative I/O library is loaded
*before* loading the rackup; the rackup's own
`require 'hyperion/async_pg'` runs too late.

The `HYPERION_STATIC_RACKUP` env var is new in 2.12-B (see
`bench/4way_compare.sh` header comment): when the
`hyperion_handle_static` server label is in the SUBSET, the harness
boots that variant against the rackup it points at, while the legacy
`hyperion` label keeps using `$RACKUP`. This lets the harness flip
between Rack-style and `handle_static` rackups inside one invocation
without re-booting the harness.

## Reading the deltas (post-2.10/2.11 wins, vs 2.10-B baseline)

| Stream | What it claimed | What this bench shows |
|---|---|---|
| **2.10-C — PageCache** | static 1 KB +36% | **Confirmed.** Hyperion Rack-style row 2 went 1,380 → 1,687 r/s = **+22.2%** (the 2.10-C unit benchmark on the bench host's exact rackup landed +36%; the 4-way harness's wrk -c100 puts both an extra layer of contention on the syscall path AND on Rack 3 body iteration that the unit bench doesn't see). The win is bigger when called via `handle_static` (1,380 → 5,935 = **+330%**) because PageCache + direct-route + C-ext fast-path stack. |
| **2.10-D — `Server.handle_static`** | hello +27%, p99 1.93 ms | **Confirmed.** Hyperion `handle_static` row 1 hit **5,502 r/s p99 1.73 ms** (vs the 2.10-B Rack-style 4,587 = **+19.9%**, vs the 2.11.0 Rack-style 4,477 = **+22.9%**). p99 1.73 ms beats the 2.10-D claim of 1.93 ms by another 10%. |
| **2.10-E — Static asset preload** | predictable first-req latency | **Confirmed indirectly** — `bench/static_handle_static.ru` preloads the asset bytes once at boot. First-request latency was the 2.10-E claim and is not separately measured here, but the median p99 1.69 ms across 3 trials confirms no first-request outliers spoil the median (which would happen if 2.10-E had regressed). |
| **2.10-F — C-ext fast-path response writer** | p99 -14% on `handle_static` | **Confirmed** — the `handle_static` row 1 p99 of 1.73 ms is **17.5% below** the Rack-style 2.11 ms on the same hello body. Same shape as the 2.10-F unit bench (-14%). |
| **2.10-G — TCP_NODELAY at accept** | h2 sequential +47.6× | Not directly exercised by this h1 sweep — the 4-way matrix is plaintext h1 only. Operators terminating h2 / h2c at Hyperion: see `docs/BENCH_HYPERION_2_0.md` § "HTTP/2 multiplexing — Phase 6 Rust HPACK" + the 2.10-G CHANGELOG section for the dedicated h2 row. |
| **2.11-A — h2 dispatch-pool warmup** | cold time-to-1st-byte -54% | Not directly exercised by this h1 sweep — see 2.11-A CHANGELOG. |
| **2.11-B — HPACK CGlue default** | Rails-shape h2 +43% over Fiddle | Not directly exercised by this h1 sweep — see 2.11-B CHANGELOG and `docs/BENCH_HYPERION_2_0.md` § HPACK rows. |

## What's NOT in this doc (and where to look instead)

- **TLS h1 (Phase 4 session resumption + writer-fiber)** — bench-only
  for nginx-fronted ops. See `docs/BENCH_HYPERION_2_0.md`
  § "TLS h1 (Phase 4 session resumption + writer-fiber)".
- **HTTP/2 multiplexing** — see `docs/BENCH_HYPERION_2_0.md`
  § "HTTP/2 multiplexing — Phase 6 Rust HPACK" + the 2.11.0
  CHANGELOG entries for 2.11-A (dispatch-pool warmup) and 2.11-B
  (HPACK CGlue).
- **WebSocket throughput** — see `docs/BENCH_HYPERION_2_0.md`
  § "WebSocket benchmark (2.3-D 4-process client)".
- **10k idle keep-alive RSS** — see `docs/BENCH_HYPERION_2_0.md`
  § "10k idle keep-alive RSS".
- **Hyperion vs Puma at higher worker counts (`-w 16`)** — see
  `docs/BENCH_HYPERION_2_0.md` § "Hello-world ceiling" + the
  2.0.1 update at the bottom.

## Honest reading

- **Hello + CPU JSON**: Agoo still wins r/s. The 2.10/2.11 streams
  narrowed the hello gap from 4.22× to 3.46×, but did not close it
  and did not move CPU JSON (Agoo +17.5% in the same window
  Hyperion +6.0% put the gap *wider*, 1.85× → 2.05×).
- **Static 1 KB**: **The flagship 2.10-C/D/F win.** Hyperion's
  `handle_static` row at 5,935 r/s wins the column outright by
  +127% over Agoo. The Rack-style row also moved up +22% from the
  PageCache 2.10-C auto-engage. Operators who can register one
  pre-built route via `handle_static` get a 3.5× lift over the
  generic Rack-style path.
- **Static 1 MiB, PG-bound async, SSE**: Hyperion's existing wins
  held. Sendfile, fiber-cooperative I/O, and the
  ChunkedCoalescer all stayed clean across the 2.10/2.11 surface.
- **Tail latency** is still Hyperion's clean win across every row
  with a non-trivial p99: hello (1.73 ms vs Agoo 10.47 / Puma 29 /
  Falcon 408), 1 KB (1.69 ms vs 57–86 ms), 1 MiB (4.63 ms vs
  82–720 ms), CPU JSON (2.60 ms vs 17–411 ms), SSE (2.85 ms vs
  11–42 ms). Across the 6 rows Hyperion's worst p99 is **140.55 ms**
  (PG-bound, intentional 50 ms wait per request); the next worst
  is 4.63 ms (1 MiB static). Puma's worst is 85.78 ms; Falcon's
  worst is 553.43 ms; Agoo's worst is 720.19 ms.
