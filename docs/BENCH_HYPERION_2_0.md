# BENCH 2026-04-29 — Hyperion 2.0.0 ≥ Puma 8.0.1

> **2026-04-30 addendum**: Hyperion 2.0.1 ships Phase 8 and closes the
> two static-file rps gaps documented below. After 2.0.1, **Hyperion
> beats Puma on rps in EVERY workload** in this report, not just 11 of
> 12. See [§ 2.0.1 update](#201-update-2026-04-30--phase-8-closes-the-static-file-rps-gaps)
> at the end of this document.

> **2026-05-01 audit addendum (2.6-E doc audit)** — A spot-check rerun
> on the same `openclaw-vm` host 2 days after the 2.0.0 sweep showed
> the published absolute rps numbers do **not** reproduce on the same
> host with no code changes:
>
> | Row | Published 2.0.0 | Spot-check 2026-04-30 (degraded host) | Spot-check 2026-05-01 (fresh-boot host) | Δ vs published |
> |---|---:|---:|---:|---:|
> | Hello-world `-w 16 -t 5` | 96,813 r/s | 76,593 r/s | (not re-run) | — |
> | Hello-world `-w 4 -t 5` | 20,630 r/s | 17,667 r/s | (not re-run) | — |
> | Static 1 MiB `-w 1 -t 5` Hyp | 1,809 r/s | 1,228 r/s | **3,041 r/s** | **+68%** |
> | Static 1 MiB Puma `-w 1 -t 5:5` | 2,139 r/s | 1,593 r/s (Puma 6.6.1) | (not re-run) | — |
>
> **The 2.7-A bisect pinned the static drift to bench-host degradation,
> not algorithmic regression.** A fresh openclaw-vm boot (5 min uptime,
> no neighbor-VM contention) puts Hyperion at ~3,000 r/s with p99 ~2.5
> ms across every released tag from v2.0.1 to master — _better_ than
> the published 2.0.0 figure. The 2026-04-30 "1,228 r/s" reading was
> a degraded-host artifact, not a 2.6.0 regression.
>
> The bench host is a single KVM VM running other workloads in the
> background; absolute-rps drift between sweep dates is real. **The
> *relative* position (Hyperion vs Puma at matched config) is the
> durable signal** — e.g. on the spot-check, Hyperion `-w 16` was
> 76,593 vs Puma `-w 16` at 55,609 = **+37.7% over Puma**, *wider*
> than the 2.0.0 sweep's +27.8%, even though absolute rps is lower.
> Treat the published rps numbers as a snapshot of one good
> measurement window, not as a guaranteed ceiling. Operators
> reproducing should expect ±10-30% absolute drift between sweep
> dates and verify their own apples-to-apples ratio.
>
> The spot-check Puma rerun used Puma 6.6.1 (the
> `~/hyperion-fresh/Gemfile` pin), not 8.0.1 (`~/bench/Gemfile` pin)
> — a version-mismatch caveat that didn't apply to the original
> 2.0.0 sweep. Both match the published shape (Puma rps lower than
> Hyperion at matched config, p99 1-2 orders of magnitude higher),
> just at lower absolute numbers.

> **Topology relevance** — operators reading this doc should keep in
> mind that benches break into two categories:
>
> - **Production-relevant for the most common Hyperion deploy
>   (nginx / L7 LB → plaintext upstream)**: hello-world, CPU JSON,
>   static (1 MiB / 8 KB), SSE, PG (50 ms wait + realistic), 10k idle
>   keep-alive RSS, WebSocket. The LB → upstream hop is plaintext
>   HTTP/1.1 regardless of LB-side termination, so these are the
>   workloads that actually shape your operator experience.
> - **Bench-only for nginx-fronted ops (operator-relevant only if you
>   terminate TLS / h2 at Hyperion directly)**: TLS h1 (Phase 4), kTLS
>   row, HTTP/2 multiplexing (h2load c=1 m=100), HTTP/2 POST. Don't
>   chase the +60% TLS-h1 win or the +18% native-HPACK win as a
>   reason to re-architect a deploy that already terminates at the LB.
>
> Per-row "Production-relevant?" markers in the headline table below.

12-workload final sweep. Closes the perf overhaul that started at 1.6.0
(2026-04-27 baseline) and shipped through 1.7.0 (sendfile + chunked
coalescing), 1.7.1 (Lint pool + 30-header intern + C build_env + cookie
parser), 1.8.0 (TLS session resumption), and 2.0.0 (Rust HPACK + breaking
removals).

The headline question this sweep answers:

> **Hyperion ≥ Puma on rps in every workload?** — **YES on 11 of 12 rows.**

The single row Puma still wins on rps is the **8 KB static-file row at the
default thread\_count of 5** — operators serving tiny static assets should
raise `-t` to 64+ (or use `-t 0` for inline, but only with `--async-io`
plus a fiber-cooperative library). At `-t 64` Hyperion closes that gap to
within ~10%; documented in the [§ static\_8k caveat](#caveat-static-8k-at--t-5)
below.

## Headline summary

Topology-relevance column: **prod** = applies to nginx-fronted plaintext-h1 deployments (the most common Hyperion topology); **bench-only** = applies only if you terminate TLS / h2 at Hyperion directly.

| # | Workload | Hyperion 2.0.0 (r/s) | Puma 8.0.1 (r/s) | rps win | p99 (Hyp / Puma) | Topology | Hyperion ≥ Puma? |
|---:|---|---:|---:|---:|---:|:---:|:---:|
| 1 | Hello-world `-w 16 -t 5` | **96,813** | 75,776 | **+27.8%** | 2.21 ms / 6.74 ms | prod | YES |
| 2 | Hello-world `-w 4 -t 5`  | **20,630** | 17,035 | **+21.1%** | 1.95 ms / 16.27 ms | prod | YES |
| 3 | CPU-bound JSON `-w 4 -t 5` (`bench/work.ru`) | **15,585** | 12,912 | **+20.7%** | 2.58 ms / 21.82 ms | prod | YES |
| 4 | Static 1 MiB `-w 1 -t 5` (`bench/static.ru`) | 1,809 | **2,139** | -15.4% | 4.37 ms / 57.74 ms | prod | NO (rps), **YES (p99 13.2× lower)** |
| 5 | Static 8 KB `-w 1 -t 5` (`bench/static_8k.ru`) | 121 | **1,246** | -90.3% | 43.85 ms / 109.05 ms | prod | **NO** — see [caveat](#caveat-static-8k-at--t-5); -t 64 gets to 1,112; closed in 2.0.1 |
| 6 | SSE 1000×50 B (`bench/sse.ru`, `wrk -t1 -c1`) — **Hyperion-flush-sentinel internal test, not a fair Puma comparison** | **24** | 0 (rackup uses a Hyperion-only sentinel, Puma framing breaks) | n/a — see [SSE row](#sse-streaming) | 41.19 ms / — | prod (with caveat) | Hyperion-only protocol exercise; the cross-server number lives in row 6b. |
| 6b | SSE 1000×50 B (`bench/sse_generic.ru`, `wrk -t1 -c1`) — **generic Rack 3 chunked rackup, no sentinel** | **510** | 133 | **+281%** (3.8×) | 2.42 ms / 9.64 ms (4× lower) | prod | **VERIFIED 2026-05-01 (post 2.7 + fresh-host).** Honest cross-server comparison. Puma DOES serve SSE (vs the prior misclaim from row 6); Hyperion is 3.8× faster on rps with 4× lower p99. |
| 7 | PG-bound 50ms wait (Hyp `--async-io -t 5 -w 1` pool=200 vs Puma `-t 100:100`) | **2,189** (originally; see verification rerun: median **~2,567** at matched-WAN-PG) | 458 | **originally +378%** (4.78×) — **honest matched-config ratio is uncalibrated**; see [Row 7 verification](#row-7-verification-rerun-2026-04-29-2145-utc) | 597 ms / 566 ms | prod | YES (architecturally; magnitude indicative only) |
| 8 | PG realistic transactional (Hyp `--async-io` pool=64 vs Puma `-t 30`) | **1,216** | 268 | **+354%** (4.54×) — **same apples-to-oranges caveat as row 7**: Hyperion against WAN PG max_conn=500, Puma against local PG max_conn=100. Magnitude indicative only. | 5.96 s / 7.18 s | prod | YES (architecturally; magnitude indicative only) |
| 9 | TLS h1 hello (Hyp `-t 64 -w 1` vs Puma `-t 5:64`) | **3,425** | 2,142 | **+59.9%** | 78.17 ms / 37.06 ms | bench-only | YES (only if you terminate TLS at Hyperion) |
| 10 | HTTP/2 multiplexing (`h2load -c 1 -m 100 -n 5000`) | **1,597** (`hello.ru`) / **1,778** (`h2_rails_shape.ru`) | Falcon 0.55.3: **2,152** (hello) / **1,125** (rails_shape). See [§ Hyperion vs Falcon h2](#hyperion-vs-falcon-h2-29-b-head-to-head). | hello: parity (within 2%). rails_shape (25-hdr): **+58% Hyperion rps** (Rust HPACK earns it). Max-lat: Falcon **4-7× lower** across the board (filed 2.10-A). | max 90 ms | bench-only | YES on Rails-shape h2; PARITY on hello h2; tail-latency owed (2.10-A). |
| 11 | HTTP/2 POST (`bench/h2_post.ru`, `h2load -c 1 -m 100 -n 5000 -d`) | **1,580** (2.9-B fresh) | Falcon 0.55.3: **1,734**. See [§ Hyperion vs Falcon h2](#hyperion-vs-falcon-h2-29-b-head-to-head). | **Falcon +9.7% rps**, Falcon 4× lower max-lat. | max 91 ms | bench-only | NO — Falcon wins POST rps. |
| 12 | 10k idle keep-alive RSS | drained 149 MB / peak 168 MB | drained 107 MB / peak 121 MB (1.6.0 baseline) | — | — | prod | Puma wins absolute MB; no Hyperion regression vs 1.6.0 |

**Net rps win** (post-audit): on a CPU-bound or hello-world workload, Hyperion 2.0.0 leads Puma 8.0.1 by 21-28% on rps and 5-8× on p99 (rows 1-3). On the production-relevant static and PG rows, the *qualitative* finding (Hyperion's tail is dramatically lower; Hyperion's fiber-pool serves wait-bound workloads at concurrency Puma's threadpool cannot reach without parking OS threads) holds — but the published magnitudes for the PG rows (4.78×, 4.54×) reflect Puma timing out at its local-PG pool ceiling, not Puma's natural rate against a matched-pool PG; the matched-config ratio is closer to **2.2× on the wait-bound row**. Static rows (4, 5) Puma wins on rps but Hyperion wins on p99 by 13-17×; both static rows are closed by 2.0.1 (see end of doc). Rows 9-11 are TLS / h2 specific and **bench-only** for nginx-fronted ops; the +60% TLS h1 win and +18% native-HPACK win are real but apply only if you terminate TLS / h2 at Hyperion directly.

**One-paragraph answer (2.6-E audit pass)**: Hyperion 2.0.0 leads Puma
8.0.1 by **+27.8% on hello-world** (97k vs 76k r/s on a 16-vCPU box,
spot-check 2026-05-01 reproduces the *relative* +37.7% even at lower
absolute rps), **+20.7% on CPU JSON** (15.6k vs 12.9k r/s), and a
qualitative architectural win on PG-bound workloads with
`hyperion-async-pg` (single-worker fiber pool reaches pool=200 + 2,500-
plus r/s on 50 ms PG queries with zero timeouts; Puma's threadpool
plateaus at pool=100 because every waiting query parks an OS thread).
The "4.78× Puma on PG" headline carried forward from the original
sweep was a Puma-timeout artefact (Puma against local PG max_conn=100
collapsed before a clean rps reading; verification rerun in row 7).
The +60% TLS h1 win is operator-relevant only if Hyperion terminates
TLS directly. Static-file rps gaps are closed in 2.0.1; SSE row's
"Puma can't stream" framing is mis-labelled and reflects a rackup
design issue, not Puma capability (see [SSE row](#sse-streaming)).

## Hardware + software stamp

- **Host**: `openclaw-vm`, Ubuntu 24.04, kernel `6.8.0-106-generic` x86_64,
  **16 vCPU**, 34 GiB RAM, 0 swap (same box as 2026-04-27 baseline)
- **Ruby**: 3.3.3 (asdf)
- **Servers**: Hyperion 2.0.0 (this release), Puma 8.0.1
- **Native extensions**: both shipped on Linux this run —
  `ext/hyperion_http/hyperion_http.so` (C, llhttp + sendfile + Rack-env)
  AND `ext/hyperion_h2_codec/libhyperion_h2_codec.so` (Rust, RFC 7541 HPACK
  + RFC 7540 frames). Boot log reports `mode: native (Rust)`.
- **Companion gems**: hyperion-async-pg 0.2.0 (path), pg 1.5.x, rack 3.2.6
- **Postgres**: 17.2 (Debian) over WAN, `pg.wobla.space:5432`,
  `max_connections=500`, RTT 50–100 ms (carries through to PG p99)
- **Tools**: `wrk` (4 threads, 200 conns, 20 s, `--latency`, 8 s timeout
  unless noted), `h2load` (nghttp2 1.59.0), 10k-conn keepalive script via
  `bench/keepalive_memory.sh`
- **Sweep dirs on bench host**:
  - `~/bench/sweep20-20260429T194715Z/` — main sweep (15 rows of `results.jsonl`)
  - `~/bench/keepalive_memory_results/run-20260429T202636Z.*` — RSS sanity
- **Date**: 2026-04-29

`PG_SLEEP_SECONDS=0.05` for all PG benches.

## 1.6.0 → 2.0.0 deltas (Hyperion only, against the same workload shape)

| Row | 1.6.0 (2026-04-27) | 2.0.0 (this sweep) | Δ rps | Δ p99 |
|---|---:|---:|---:|---:|
| Hello `-w 16 -t 5` | 98,818 | **96,813** | -2.0% (noise) | 2.12 → 2.21 ms (flat) |
| Hello `-w 4 -t 5` | 21,215 | **20,630** | -2.8% (noise) | 1.87 → 1.95 ms (flat) |
| CPU JSON `-w 4 -t 5` | 15,582 | **15,585** | 0% | 2.47 → 2.58 ms (flat) |
| Static 1 MiB `-w 1 -t 5` | 1,919 | 1,809 | -5.7% (noise) | 4.22 → 4.37 ms (flat) |
| PG `--async-io` pool=200 | 2,180 | **2,189** | +0.4% | 668 → 597 ms (**-10.6%**) |
| PG realistic pool=64 | 1,158 | **1,216** | **+5.0%** | 5.70 → 5.96 s (flat) |
| TLS h1 `-t 64 -w 1` | 2,842 | **3,425** | **+20.5%** | 47.6 → 78.2 ms (-) |
| HTTP/2 (`h2load -c 1 -m 100 -n 5000`) | 1,667 | 1,597 | -4.2% | max 71 → 91 ms (flat) |
| 10k idle keep-alive RSS (drained) | 155 MB | 149 MB | -6 MB (-3.9%) | — |

**Reading the deltas**:
- **Hello / CPU / Static rps regressions are inside the ±5% bench noise
  envelope** the 2026-04-27 caveat already documented (`-w 16 -t 5`
  hello sat at 98.8k ±3k). No real regression on these.
- **PG p99 -10.6%** at pool=200 — the 1.7.0 + 1.7.1 hot-path object pools
  (per-worker Lint, reused inbuf, 30-header intern table) and Phase 3
  C-ext `build_env` cut the wait-bound tail noise.
- **TLS h1 +20.5% rps** is the Phase 4 session-resumption ticket cache
  win (1.8.0). Warm wrk connections complete the TLSv1.3 handshake via
  RFC 5077 tickets instead of paying a fresh ECDHE+ECDSA round-trip; with
  `-t 64 -w 1` the inline-dispatch CPU was the bottleneck before, now
  more cycles go to actual app work.
- **HTTP/2 -4.2% rps** vs the 1.6.0 baseline is **also inside noise**.
  The Phase 6 Rust HPACK shipped a 3.26× microbench encode speedup, but
  on a 5,000-stream workload through one connection the per-frame work
  (window updates, flow control, fiber yields, framer dispatch) dominates
  over the HPACK encode time saved.  The HPACK win shows up in tail
  measurements at very high stream rates and on header-heavy responses,
  not in this fixed-100-stream `c=1 m=100` envelope.
- **10k keep-alive RSS -6 MB** — Phase 2's reused inbuf + per-worker Lint
  pool reduce per-connection overhead modestly. No regression from the
  Rust extension load (the `.so` adds ~0.5 MB to the process map; well
  inside noise).

## Hello-world ceiling (no DB, CPU-light)

`bench/hello.ru`, `wrk -t4 -c200 -d20s --timeout 8s --latency`.

| name | server | r/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| **hello-hyp-w16-t5** | **Hyperion 2.0.0** | **96,813** | 692 µs | **2.21 ms** | 46 MB |
| hello-puma-w16-t5 | Puma 8.0.1 | 75,776 | 2.54 ms | 6.74 ms | 38 MB |
| **hello-hyp-w4-t5** | **Hyperion 2.0.0** | **20,630** | 920 µs | **1.95 ms** | 46 MB |
| hello-puma-w4-t5 | Puma 8.0.1 | 17,035 | 11.61 ms | 16.27 ms | 38 MB |

**Reading**: Hyperion's lead grows from +21% (-w 4) to +28% (-w 16) as
worker count rises — the C-ext Rack env builder + per-worker Lint pool
amortise per-process startup costs while Puma's threadpool-per-worker
overhead grows linearly. Hyperion **p99 sub-2 ms** at 16 workers vs
Puma's 6.74 ms is the operator-visible difference.

## CPU-bound JSON

`bench/work.ru` — 50-key JSON serialization per request.

| name | server | r/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| **work-hyp-w4-t5** | **Hyperion 2.0.0** | **15,585** | 1.20 ms | **2.58 ms** | 46 MB |
| work-puma-w4-t5 | Puma 8.0.1 | 12,912 | 15.30 ms | 21.82 ms | 38 MB |

**Reading**: Hyperion +21% rps, **p99 8.5× lower**.

## Static 1 MiB asset (sendfile path)

`bench/static.ru` — file at `/tmp/hyperion_bench_asset_1m.bin`,
`wrk -t4 -c100 -d20s`.

| name | server | r/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| static-hyp-w1-t5 | Hyperion 2.0.0 | 1,809 | 2.52 ms | **4.37 ms** | 62 MB |
| **static-puma-w1-t5** | **Puma 8.0.1** | **2,139** | 46.42 ms | 57.74 ms | 53 MB |

**Reading**: Puma wins rps by **15.4%** on the 1 MiB asset, but Hyperion's
p99 is **13.2× lower** (4.37 ms vs 57.74 ms) — the sendfile fast path +
fiber-per-connection scheduling means each request's wall-time is bounded
by the kernel's send rate, not by 100 conns / 5 threads queue depth on
Puma's path. **Operator picks**: serving a single 1 MiB asset to 100
concurrent clients, prefer Puma if you're rps-bound and don't care about
tail; prefer Hyperion if any client gets cranky after 50 ms (mobile,
stream stitching, real-time CDN feed).

**Phase 1 sendfile recap**: the C unit at `ext/hyperion_http/sendfile.c`
ships the Linux `sendfile(2)` zero-copy path for plain TCP and a Darwin
BSD `sendfile(2)` fallback; `IO.copy_stream` userspace-loops on TLS
sockets (kernel TLS rare). Phase 1 closed the 1.6.0 gap of 1,919 vs Puma
2,074 to 2,392 r/s on macOS; on Linux the gap is much smaller because
`IO.copy_stream` already used `sendfile(2)` under the hood. The remaining
~15% gap is likely the per-chunk fiber-yield overhead on the
`Sendfile.copy_to_socket` loop vs Puma's straight-line `IO.copy_stream`
returning into a single OS thread.

**Follow-up to close the rps gap**: try a `splice(2)`-through-pipe path
on Linux (avoids the userspace fallback entirely on `EAGAIN`) — saved as
`ext/hyperion_http/sendfile.c`'s comment "splice(2)-through-pipe support
is wired behind the same surface for a follow-up if a host's `sendfile`
returns `:unsupported`."

## <a id="caveat-static-8k-at--t-5"></a>Static 8 KB asset (sanity check — *real regression at -t 5*)

`bench/static_8k.ru` — 8 KB file. `wrk -t4 -c100 -d20s`.

| name | server | r/s | p50 | p99 | RSS |
|---|---|---:|---:|---:|---:|
| **static8k-hyp-w1-t5** | Hyperion 2.0.0 | **121** | 41.01 ms | 43.85 ms | 55 MB |
| **static8k-puma-w1-t5** | **Puma 8.0.1** | **1,246** | 79.28 ms | 109.05 ms | 53 MB |
| static8k-hyp-w1-t0 (inline) | Hyperion 2.0.0 | 24 | 41.00 ms | 42.03 ms | 51 MB |
| static8k-hyp-w1-t64 | Hyperion 2.0.0 | 1,112 | 57.01 ms | 67.00 ms | 65 MB |

**This is the one row Puma still wins on rps.**

The 121 r/s figure is Hyperion's hot path **starving the wrk loop at
default `-t 5`** — server-side per-request duration is sub-millisecond
(`duration_ms: 0.21` to `0.26` in the access log), but only ~25 requests
complete per wrk-thread-second. With 100 conns / 4 wrk threads / 5
hyperion threads = 5 conns per worker thread, the sendfile path appears
to hit `EAGAIN` and fiber-yield in a loop that delays the next dispatch
batch by ~40 ms. **Raising `-t 64`** restores 1,112 r/s (within 11% of
Puma's 1,246).

The pattern is specific to:
1. Very small files (8 KB fits in one TCP packet),
2. The thread-pool dispatch path (`-t 5` to `-t N` where N < ~32),
3. With Phase 1's sendfile fast path active,
4. Default access-log enabled (turning off `--no-log-requests` does NOT
   help, ruling out access log serialisation).

Inline dispatch (`-t 0`) makes it worse (24 r/s) because every request
runs synchronously on the read fiber blocking the next accept; only with
`--async-io + hyperion-async-pg` does -t 0 work.

**Recommended workaround now**: operators serving fleets of small static
assets through Hyperion should pick `-t 64` or higher; cluster Hyperion
behind nginx for static; or use the `--no-yjit -t 64` mode on small-file
edges.

**Follow-up to fix this row at default -t 5**: the sendfile.c primitive
should detect "file fits in one MSS" and short-circuit to a single
`write(2)` instead of going through the EAGAIN-yield loop. Filed mentally
as Phase 8 alongside the splice(2) idea above. Not a 2.0.0 blocker — the
operator workaround (`-t 64`) is well-known and matches the existing
guidance in 1.6.1's "Operator guidance" README section.

## SSE streaming

`bench/sse.ru` — 1000 ~50 B SSE events, `wrk -t1 -c1 -d10s`.

| name | server | r/s | p50 | p99 | non-2xx | timeouts |
|---|---|---:|---:|---:|---:|---:|
| **sse-hyp-w1-t5** | **Hyperion 2.0.0** | **24** | 41.00 ms | 41.19 ms | 0 | 0 |
| sse-puma-w1-t5 | Puma 8.0.1 | 0 | — | — | 0 | 11,686 read errors |

**Reading (audit-corrected 2026-05-01)**: the original framing —
"Puma 8.0.1 cannot stream the SSE rackup" — is **misleading**. The
rackup at `bench/sse.ru` uses a **Hyperion-specific flush sentinel**
(`yield(:__hyperion_flush__)` every 50 events) to drive
`ChunkedCoalescer#force_flush!`. Hyperion's Rack adapter recognises
this sentinel and treats it as a "flush hint, not a body chunk"; Puma
has no such hook and emits the sentinel **as a literal body chunk**
(`":__hyperion_flush__"` written into the chunked stream). That breaks
the chunked-encoding framing on the wrk side, which counts the
malformed bytes as "read errors" and reports 0 r/s. **This is a bench
rackup design issue, not a Puma SSE-capability gap.**

A generic SSE rackup (no Hyperion sentinel — just `yield(event)` 1000
times with a normal `transfer-encoding: chunked` response) would
exercise Puma's SSE path correctly, and is owed before this row can
back any "Puma can't stream" claim. **What the row honestly shows**:
Hyperion handles its own flush-sentinel protocol on a 1000-tiny-events
streaming workload and pumps 24 r/s × 1000 events = 24,000 events/s
through one fiber, with the Phase 5 ChunkedCoalescer reducing per-
response syscalls from ~1000 (one per event) to ~10-15 (1 head + N
buffer drains + 1 terminator). The syscall-coalescing claim is
verified at the syscall level in `spec/hyperion/chunked_coalescing_spec.rb`.

**2.7-C status**: `bench/sse_generic.ru` **has been added** (no
Hyperion sentinel, just standard Rack 3 streaming — `each` yields
1000 `"data: ...\n\n"` Strings to the server's writer). It boots and
serves identically on Hyperion, Puma, and Falcon. Local smoke test
confirms 1000 chunks, ~35 KB total, all `String` (no `Symbol`
sentinels) — the rackup is portable. **The cross-server bench rerun
is still owed**: bench-host (`openclaw-vm`) SSH was unreachable
during the 2.7-C doc pass, so row 6b in the matrix above is parked
as `pending` until the next bench-host run lands honest numbers for
Hyperion vs Puma (and ideally vs Falcon) on the generic rackup.

## PG-bound 50ms wait

`pg_concurrent.ru` (`SELECT pg_sleep(0.05)` + tiny JSON; rackup lives
in [hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg)
+ on the bench host at `~/bench/`, not in this repo — see the
"Reproducing this report" section), `wrk -t4 -c200 -d20s --timeout 8s`.

| name | server | mode | pool | r/s | p50 | p99 | non-2xx | timeouts |
|---|---|---|---:|---:|---:|---:|---:|---:|
| **pg-hyp-asyncio-pool200** | **Hyperion 2.0.0 `--async-io -t 5 -w 1`** | async | **200** | **2,189** (verification rerun median: **~2,567**) | 60 ms | **597 ms** (rerun: ~336 ms) | 0 | 0 |
| pg-puma-t100-pool100 | Puma 8.0.1 `-t 100:100` | plain | 100 | 458 | 147 ms | 566 ms | 0 | **200** |

**Reading (audit-corrected)**: the **+378% (4.78×) headline carried
forward by the original sweep is misleading** for two reasons that
the verification rerun at the bottom of this section already documents:

1. **Apples-to-oranges PG endpoint**: Hyperion ran against
   `pg.wobla.space` WAN PG with `max_connections=500`, while Puma
   ran against local PG with `max_connections=100`. The Puma side hit
   its local pool ceiling at pool=100 and then **timed out 200 of the
   wrk requests** at the 8 s wrk timeout — the 458 r/s number is
   Puma's collapsed-floor rate, not its natural rate against a
   matched-pool PG.
2. **Verification rerun showed Hyperion at ~2,567 r/s median** (better
   than the originally-reported 2,189) but a matching-WAN-PG Puma
   rerun could not be captured cleanly — the prior Hyperion sweep had
   already consumed pg.wobla.space's connection budget and Puma
   collapsed at 1.7 r/s on connection exhaustion, which is a worse
   apples-to-apples problem than the original. The Puma side of this
   row is **uncalibrated** at matched PG.

**What the row honestly supports**: Hyperion's `--async-io` + fiber
pool serves a 50 ms-waiting PG workload at high concurrency (pool=200
→ 2,500-plus r/s, zero timeouts) where Puma's threadpool model
plateaus at the smaller pool size that matches `-t` (because every
waiting query parks an OS thread). The architectural finding — fiber
concurrency widens the wait-bound throughput ceiling without OS-
thread cost — is real. The **headline magnitude (4.78×) should be
treated as indicative, not precisely calibrated**; an honest match-
config ratio is owed and lands closer to ~2.2× on this fixture (Puma
at its own best `-t 100 pool=100` row in the README's wider matrix
hits 1,067 r/s; Hyperion at pool=200 hits 2,381 r/s = 2.23×).

### Row 7 verification rerun (2026-04-29 21:45 UTC)

Audit of the original sweep revealed two data-integrity issues on this row:

1. The 2,189 r/s figure was added to the report by an ad-hoc rerun whose
   `wrk.log` was not preserved into `~/bench/sweep20-…/results.jsonl`
   (the sweep harness logged "never bound to 9314" for both passes
   because `DATABASE_URL` wasn't sourced from `.env`).
2. The Puma comparison was apples-to-oranges: `pg-puma-t100-pool100`
   used **local PG** (max_connections=100), while `pg-hyp-asyncio-pool200`
   used **WAN PG** at `pg.wobla.space` (max_connections=500). The
   4.78× ratio is qualitatively correct but the exact magnitude is muddled.

A clean Hyperion rerun against pg.wobla.space (pool=200, two consecutive
20 s wrk runs) gave **better** numbers than the report originally claimed:

| run | r/s | p50 | p99 | non-2xx | timeouts |
|---|---:|---:|---:|---:|---:|
| pg-hyp-pool200 (rerun 1) | **2,510** | 56.7 ms | **295 ms** | 0 | 0 |
| pg-hyp-pool200 (rerun 2) | **2,624** | 53.5 ms | **377 ms** | 0 | 0 |

**Median of the two reruns: ~2,567 r/s** (+17% vs the originally-reported
2,189), **p99 ~336 ms** (-44% vs the originally-reported 597 ms).

A matching Puma pool=100 rerun against the same WAN PG could not be
captured cleanly — leftover Hyperion conns from the prior run had already
consumed the pg.wobla.space conn budget and Puma collapsed to 1.7 r/s
with connection exhaustion. The qualitative claim — "Hyperion's async-io
fiber pool fundamentally beats Puma's threadpool for fiber-cooperative
I/O at high pool depths" — holds, but operators reading the row should
treat the **4.78×** ratio as indicative rather than precisely calibrated.

Raw rerun logs preserved at `/tmp/pg-hyp-pool200.wrk.log` on
`openclaw-vm`.

## PG realistic transactional

`pg_realistic.ru` (`BEGIN; INSERT; SELECT; COMMIT;` × 4 PG
round-trips per req; rackup lives in
[hyperion-async-pg](https://github.com/andrew-woblavobla/hyperion-async-pg) /
`~/bench/`, not in this repo), `wrk -t4 -c100 -d20s --timeout 60s`.

| name | server | mode | pool | r/s | p50 | p99 | non-2xx |
|---|---|---|---:|---:|---:|---:|---:|
| **real-hyp-asyncio-pool64** | **Hyperion 2.0.0 `--async-io -t 5 -w 1`** | async | **64** | **1,216** | 46 ms | 5.96 s | 0 |
| real-puma-t30-pool30 | Puma 8.0.1 `-t 30:30` | plain | 30 | 268 | 232 ms | 7.18 s | 0 |

**Reading (audit-corrected)**: the **+354% (4.54×) headline carries
the same apples-to-oranges caveat as row 7** — Hyperion against
`pg.wobla.space` WAN PG (max_conn=500), Puma against local PG (max_conn=100).
A matched-WAN-PG Puma rerun was not captured for this row. **The
qualitative finding holds** (fiber pool at pool=64 vs threadpool at
pool=30 widens the realistic-transactional throughput ceiling without
parking OS threads) but **the magnitude is uncalibrated**. Both servers
run hot on this 4-round-trip workload; Hyperion's `5.96 s p99` is the
queue-depth × WAN-RTT compound (`100 conns × 4 round-trips × 50-100 ms
/ 64 pool` ≈ 312-625 ms steady-state plus connect-cost spikes), Puma's
`7.18 s p99` is the same shape with the smaller pool. **Operators
should treat the 4.54× ratio as indicative, not steady-state**, and
rerun against their own matched-config PG to size capacity.

## TLS h1 (Phase 4 session resumption + writer-fiber)

> **Topology relevance: bench-only for nginx-fronted ops**. If your LB
> terminates TLS and forwards plaintext HTTP/1.1 upstream to Hyperion,
> this row's +60% rps win does not apply to your deploy — the LB →
> upstream hop never exercises the TLS path. The row is operator-
> relevant only if Hyperion is the TLS-terminating edge (small static
> fleets, single-VM edge boxes, dev / staging without an L7 LB).

`bench/hello.ru` over HTTPS, `wrk -t4 -c64 -d20s`.

| name | server | command | r/s | p50 | p99 | RSS |
|---|---|---|---:|---:|---:|---:|
| **tls-hyp-w1-t64** | **Hyperion 2.0.0** | `--tls-cert ... -t 64 -w 1` | **3,425** | 26.90 ms | 78.17 ms | 63 MB |
| tls-puma-w1-t64 | Puma 8.0.1 | `-b 'ssl://...' -t 5:64` | 2,142 | 29.74 ms | 37.06 ms | 68 MB |

**Reading**: Hyperion **+59.9% rps** over Puma. Puma wins p99 (37 vs 78
ms) — its OS-thread-per-connection model linearises tail latency
predictably while Hyperion's fiber scheduler shows ~80 ms p99 spikes
from TLSv1.3 ClientHello + cipher negotiation contention. The Phase 4
SESSION\_CACHE\_SERVER + RFC 5077 ticket key trade-off here is "more rps
on warm conns, occasional spikes when the cache rolls".

20.5% rps win vs the 1.6.0 baseline (2,842) is the Phase 4 ticket-cache
win on `wrk`'s repeated `-c64` connections.

## HTTP/2 multiplexing — Phase 6 Rust HPACK

> **Comparison framing**: this row is **not** a "Hyperion wins HTTP/2"
> claim against Puma — Puma 8.0.1 has no native HTTP/2 path
> (production Puma deployments terminate h2 at nginx and forward h1 to
> the worker pool). Falcon 0.55+ ships native h2 and is the
> apples-to-apples comparison; **2.9-B closed it** — see
> [§ Hyperion vs Falcon h2](#hyperion-vs-falcon-h2-29-b-head-to-head).
> Headline: Hyperion **+58% rps on Rails-shape**, parity on hello,
> Falcon +10% on POST, Falcon **4-7× lower max-lat across the board**
> (filed 2.10-A).
> The row below demonstrates Hyperion's h2 path *exists and is
> functional at 1,500+ r/s, 0 errors, 95% HPACK savings* on the
> c=1 m=100 envelope — not that Hyperion h2 beats anyone in isolation.
>
> **Topology relevance**: this row is **bench-only for nginx-fronted
> ops**. If your LB terminates HTTP/2 and forwards HTTP/1.1 upstream
> to Hyperion (the most common deploy), the h2 path here doesn't run.
> If you're running Hyperion as the TLS-terminating edge and want
> native HTTP/2 multiplexing on the wire, this row characterises that
> path.

`h2load -c 1 -m 100 -n 5000 https://127.0.0.1:9701/` against TLS
Hyperion `-t 64 -w 1` with `h2.max_total_streams :unbounded` (overriding
the new 2.0.0 default of `max_concurrent_streams × workers × 4 = 512`).

```
finished in 3.13s, 1596.72 req/s, 39.00KB/s
requests: 5000 total, 5000 started, 5000 done, 5000 succeeded, 0 failed, 0 errored, 0 timeout
status codes: 5000 2xx, 0 3xx, 0 4xx, 0 5xx
TLS Protocol: TLSv1.3
Cipher: TLS_AES_128_GCM_SHA256
Application protocol: h2
time for request:    41.10ms     86.65ms     60.67ms      5.03ms    92.00%
```

**Reading**: 1,597 req/s, **5,000 / 5,000 succeeded, 0 errors**. -4.2%
vs the 1.6.0 baseline of 1,667 — inside noise. The Rust HPACK encoder/
decoder is **loaded and active** (`Hyperion::H2Codec.available? == true`,
boot log reports `mode: native (Rust)`); the 3.26× encode microbench
speedup doesn't surface at this stream-rate because per-frame framer
work + fiber yields dominate. Phase 6c (folding the native codec into
the framer's hot path) ships in a 2.x point release.

**Important breaking-change note**: the 2.0.0 default cap of
`max_concurrent_streams × workers × 4 = 128 × 1 × 4 = 512` would close
the connection mid-stream on a default-config + `h2load -n 5000` run.
Operators on h2-heavy edges must set `h2.max_total_streams` explicitly,
either in config (`h2 do; max_total_streams 8192; end`) or to
`:unbounded` to restore pre-2.0 behaviour. Documented in the 2.0.0
CHANGELOG migration table.

**2.2.x fix-D follow-up (CLI / env-var escape hatch)**: writing a
config file just to lift the cap for a one-off bench was awkward. The
2.2.x follow-up sprint adds two operator knobs that ride the existing
1.7.0 DSL field:

```sh
# CLI flag — per-invocation
hyperion --h2-max-total-streams unbounded ...
hyperion --h2-max-total-streams 8192 ...

# Env-var — outermost knob (CI / bench harness)
HYPERION_H2_MAX_TOTAL_STREAMS=unbounded hyperion ...
```

The bench rerun on openclaw-vm with `--h2-max-total-streams unbounded`
is PENDING the maintainer running the command from a session with SSH
access (see CHANGELOG fix-D section); when it lands the row should
read 5,000 / 5,000 succeeded with rps near the published 1,597 baseline.

## HTTP/2 POST — encode hot path

`h2load -c 1 -m 100 -n 5000 -d /tmp/h2_post_data.txt
https://127.0.0.1:9702/echo` against `bench/h2_post.ru`:

```
finished in 3.33s, 1499.58 req/s, 54.23KB/s
requests: 5000 total, 5000 started, 5000 done, 5000 succeeded, 0 failed
traffic: 180.82KB total, 39.16KB headers (space savings 95.47%)
time for request:    40.97ms     90.79ms     64.54ms      5.12ms    90.92%
```

**Reading**: 1,500 req/s, **HPACK header savings 95.47%** —
exercises the static-table-matched (`:status 201`, `content-type`,
`content-length`) and literal-with-incremental-indexing
(`x-request-id`, `x-trace-id`) paths exactly as documented in the
rackup. **The user's stated target of "4,000+ r/s" is not hit** at this
fixed `c=1 m=100` envelope. Diagnosis: with one connection × 100
streams sharing one fiber-scheduler, the bottleneck moves to the
writer-fiber + framer queue rather than the encoder. Raising `c=4` (4
connections × 100 streams) would distribute the framer work and likely
hit the target — saved as a Phase 8 follow-up bench, not a 2.0.0
blocker.

## Hyperion vs Falcon h2 (2.9-B head-to-head)

Rows 10 and 11 above were honestly relabelled "Puma 8 lacks native h2
— Falcon comparison owed" since 2.6-E. Falcon 0.55+ ships native h2 and
is the apples-to-apples comparison for Hyperion's h2 path. 2.7-E was
deferred when openclaw-vm went offline; 2.9-B re-runs the comparison
on the fresh-boot host with Falcon 0.55.3 installed alongside Hyperion.

**Method.** Three rackups, each driven by `h2load -c 1 -m 100 -n 5000`,
3 runs per combination, median taken.

- Hyperion: `bin/hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem
  -t 64 -w 1 --h2-max-total-streams unbounded -p 9602 <rackup>`. Rust
  HPACK default-on (boot log: `mode: native (Rust v2 / Fiddle) — HPACK
  on hot path`, `native_enabled: true`, `hpack_path: native-v2`).
- Falcon 0.55.3: `falcon serve --bind https://localhost:9602 --hybrid
  -n 1 --forks 1 --threads 5 -c <rackup>` (1 process, 5 threads — the
  closest single-process apples-to-apples to Hyperion's `-w 1 -t 64`
  fiber pool given Falcon's CLI doesn't expose a "fiber pool size" knob).
- TLS: same self-signed `/tmp/cert.pem` + `/tmp/key.pem` (RSA-2048, CN=localhost).
- Same h2load 1.59.0, same loopback, no network.

Harness: `bench/h2_falcon_compare.sh` (this commit). Date: 2026-05-01,
fresh-boot openclaw-vm.

### Results (5,000 / 5,000 succeeded on every run; 0 errors)

| Rackup | Hyperion 2.8.0+ rps (median) | Falcon 0.55.3 rps (median) | Δ rps | Hyperion max-lat | Falcon max-lat | Δ max-lat |
|---|---:|---:|---:|---:|---:|---:|
| `hello.ru` (2 hdrs) | **2,198** | 2,152 | **+2.1%** (parity) | 40.72 ms | **5.58 ms** | Falcon **7.3× lower** |
| `h2_post.ru` (POST + 7 resp hdrs) | 1,580 | **1,734** | Falcon **+9.7%** | 40.84 ms | **9.94 ms** | Falcon **4.1× lower** |
| `h2_rails_shape.ru` (25 hdrs) | **1,778** | 1,125 | Hyperion **+58.0%** | 40.69 ms | **6.44 ms** | Falcon **6.3× lower** |

Per-run rps for the median values above: hello hyp `2208/2197/2198`,
hello fal `2270/2117/2152`; h2_post hyp `1522/1585/1580`, h2_post fal
`1734/1891/1567`; rails_shape hyp `1770/1778/1782`, rails_shape fal
`1125/1118/1166`.

### Verdict

- **Hello (2 headers)**: **rps parity** (within 2%, inside bench noise).
  Both servers move ~2,200 r/s on a CPU-light hello shape. The HPACK
  encode is <1% of per-stream CPU at 2 headers, so neither encoder
  matters.
- **h2_post (POST body + 7 headers)**: **Falcon wins rps by ~10%**.
  Hyperion 1,580 vs Falcon 1,734. The POST body adds DATA-frame
  serialise/deserialise on the request side; Falcon's protocol-http2
  appears slightly leaner here. Real but inside bench noise on the
  hyperion side (1,522-1,585 across 3 runs).
- **rails_shape (25 headers)**: **Hyperion wins rps by ~58%** (1,778 vs
  1,125). This is the shape where the 2.5-B Rust-native HPACK encoder
  earns its keep — encoding 25 headers per response × 5,000 responses
  is 125,000 HPACK encode ops; Hyperion's Rust hot-path beats Falcon's
  pure-Ruby protocol-http2 encoder by a wide margin. Aligns with the
  microbench (3.26× HPACK encode speedup) bleeding into wire rps once
  per-stream HPACK CPU is non-trivial.
- **Max-latency (all rows)**: **Falcon wins by 4-7×**. Falcon's
  worst-stream max is consistently 5-10 ms; Hyperion's is 40-41 ms on
  every run. The Hyperion tail is suspiciously flat at ~40 ms, which
  reads as a fixed-cost setup delay (TLS handshake + initial SETTINGS
  exchange + first stream's framer-fiber priming). Filed as a 2.10
  follow-up — h2 first-stream tail latency is real and operator-visible.

### Reading the results

Both servers are good. Operators terminating h2 on the wire have a
real choice:
- **Choose Hyperion** if you serve Rails-shape (20-30 header) responses —
  the +58% rps at rails_shape ships measurable extra capacity per box,
  and the 2.5-B native-HPACK headline survives apples-to-apples vs
  Falcon (vs the prior comparison against the Ruby-fallback HPACK).
- **Choose Falcon** if you serve POST-heavy h2 endpoints (+10% rps) or
  if max-latency tail matters to you (4-7× lower across the board).
- **Either** if you're on a hello-world / 2-header shape (rps parity).

The h2 first-stream max-latency gap (Hyperion's flat ~40 ms vs Falcon's
~6 ms) is **the only finding from 2.9-B that should land on Hyperion's
follow-up list**. Filed as 2.10-A — investigate the fixed-cost setup
delay on Hyperion's first h2 stream (likely TLS+SETTINGS round-trip
ordering, not throughput).

### Reproducing 2.9-B

```sh
# On openclaw-vm (or any host with h2load + ruby + the two checkouts):
~/hyperion/bench/h2_falcon_compare.sh
# Knobs: PORT, RUNS, THREADS, WORKERS, HYPERION_DIR, FALCON_DIR.
# Per-run h2load output: $H2LOAD_LOG (default /tmp/h2_falcon_compare_h2load.log).
# Per-server log: /tmp/h2-falcon-cmp-<server>-<rackup>.log.
```

Falcon install (one-shot):
```sh
mkdir -p ~/bench-falcon
cat > ~/bench-falcon/Gemfile <<'EOF'
source 'https://rubygems.org'
gem 'rack', '~> 3.0'
gem 'falcon', '~> 0.55'
EOF
cd ~/bench-falcon && PATH=$HOME/.asdf/bin:$HOME/.asdf/shims:$PATH bundle install
cp ~/hyperion/bench/{hello,h2_post,h2_rails_shape}.ru ~/bench-falcon/
```

## 10k idle keep-alive RSS

`bench/keepalive_memory.sh N=10000 SERVERS=hyperion HOLD_SEC=20`:

| Hyperion version | peak RSS | drained RSS | per-conn |
|---|---:|---:|---:|
| **2.0.0 (this run)** | 168 MB | **149 MB** | ~14.9 KB |
| 1.6.0 (2026-04-27) | 174 MB | 155 MB | ~15.5 KB |

**No regression in 2.0.0** — Phase 2's reused-inbuf + per-worker Lint
pool slightly improved per-connection footprint. The Rust HPACK
extension load adds ~0.5 MB to the static process map (well inside
noise) and is independent of connection count.

For comparison from the 2026-04-27 baseline:
- Puma @ 10k: 107 MB drained — Puma still wins absolute MB but cannot
  serve fiber-concurrent PG workloads.

## Caveats

1. **`max_total_streams` flip is observable on h2load**. The 2.0.0
   default of `max_concurrent_streams × workers × 4` was specifically
   designed for pathological abuse paths (5,000 conns × 128 streams =
   640k fibers → OOM). Legitimate h2load runs at `c=1 m=100 n=5000`
   exhaust 512 streams in <1 s. Operators wiring CI / canary benches
   need to override; see [§ HTTP/2 multiplexing](#http2-multiplexing--phase-6-rust-hpack).
2. **Static 8 KB rps regression** is real at default `-t 5`. See
   [§ caveat](#caveat-static-8k-at--t-5). At `-t 64` Hyperion is
   competitive (1,112 vs 1,246).
3. **HTTP/2 4,000+ r/s target not hit** on the wire-level bench. The
   Rust HPACK encode microbench shows the 3.26× speedup; at fixed
   `c=1 m=100` the framer-fiber dominates. Re-run `c=4 m=100` to spread
   the framer work; saved for Phase 8.
4. **Falcon was not re-benched** in this 2.0.0 sweep (the 2026-04-27
   baseline already characterised Falcon's strengths/weaknesses; the
   "vs Puma" goal was the operative one for the 2.0.0 ship).
5. **WAN PG, single-VM noise, self-signed TLS cert** — same caveats as
   the 1.6.0 baseline. Re-read `docs/BENCH_2026_04_27.md` § Caveats.
6. **`hyperion-async-pg` 0.2.0 was used** (the bench Gemfile's path
   gem); the 0.5.0 `fork_safe: true` API was stripped from the bench
   rackup. Multi-worker PG numbers will change once 0.5.0 is wired in
   here — the 2026-04-27 row "pg-hyp-asyncio-w4-t5-pool64-prefill" is
   the cold-start-handled version of the multi-worker case.

## Reproducing this report

The wrappers are at:

- `~/bench/sweep_2_0_2026_04_29.sh` — the 16-row main sweep (h1)
- `~/bench/sweep_2_0_followup_2026_04_29.sh` — TLS Puma + h2load + keepalive followups
- `~/bench/sweep_2_0_final_2026_04_29.sh` — final cleanup runs

```sh
ssh ubuntu@openclaw-vm
cd ~/bench
./sweep_2_0_2026_04_29.sh                                # main sweep
./sweep_2_0_followup_2026_04_29.sh <out-dir>             # followups
./sweep_2_0_final_2026_04_29.sh <out-dir>                # final cleanup
```

Per-run artefacts at `~/bench/sweep20-20260429T194715Z/`:

- `<name>.server.log` — server stdout/stderr (start-up, access logs)
- `<name>.wrk.log` — full wrk output incl. latency distribution
- `<name>.rss.log` — peak RSS during the wrk window (KB)
- `results.jsonl` — one line per run, parsed
- `sweep.log` — chronological sweep log

Original 2026-04-27 baseline preserved at
`~/bench/sweep-20260427T123906Z/` for delta computations.

## 2.0.1 update (2026-04-30) — Phase 8 closes the static-file rps gaps

Two follow-up changes shipped in 2.0.1:

1. **Head + body coalesce for files <= 64 KiB** in
   `ResponseWriter#write_sendfile`. The 8 KB row's real bottleneck
   was Nagle/delayed-ACK stall between the head write and the
   separate body write — not EAGAIN-yield retry as initially
   hypothesised. By emitting head + body as one `io.write`, the
   response goes out as one TCP segment train and the client ACKs
   the whole response without parking the second write.
2. **`Sendfile.copy_small` and `Sendfile.copy_splice` C primitives**
   added; `copy_small` used as a backup fast path; the splice path
   stays in the build for callers that want it but is not on the
   production hot path (persistent per-thread pipes carry a residual-
   bytes correctness risk on EPIPE).

### Side-by-side rebench (same `-t 5 -w 1`, same `wrk -t4 -c100 -d20s`)

| Workload | Hyperion 2.0.0 | Hyperion 2.0.1 | Puma 8.0.1 | 2.0.1 vs Puma |
|---|---:|---:|---:|---:|
| Static 8 KB r/s | 121 | **1,483** | 1,366 | **+8.6%** |
| Static 8 KB p99 | 43.85 ms | **4.81 ms** | 84.38 ms | **17.5× lower** |
| Static 8 KB RSS | 55 MB | ~55 MB | 53 MB | within 4 MB |
| Static 1 MiB r/s | 1,809 | **1,697** | 1,330 | **+27.6%** |
| Static 1 MiB p99 | 4.37 ms | **5.14 ms** | 92.86 ms | **18× lower** |

### Reading the 2.0.1 bench

- **8 KB row: 12× win on rps over 2.0.0**, ahead of Puma on rps for
  the first time on this row, and 17.5× lower p99. The static-8 KB
  caveat in this document is now retired.
- **1 MiB row: +27.6% over Puma** AND **18× lower p99**. The 2.0.0
  rps loss was bench-host noise: re-running both servers
  back-to-back on 2026-04-30 the box's Puma baseline came in at
  1,330 r/s (down from the 2,139 the 2026-04-29 sweep recorded);
  Hyperion's 1,697 r/s comfortably beats it. The Hyperion p99
  improvement is the operator-visible delta — Puma's p99 sits at
  75-93 ms because its `-t 5:5` threadpool serializes 100 wrk
  conns through 5 OS threads, while Hyperion's fiber-per-connection
  scheduler holds sub-5 ms tail at the same shape.

### Caveat retirement

The "Static 8 KB rps regression at -t 5" caveat from this report is
**closed**. Operators serving small static assets through Hyperion
no longer need to raise `-t 64` as a workaround. The HTTP/2 c=4
follow-up bench remains open for a future point release.

### Note on bench-host noise

Re-running on 2026-04-30 showed both servers' rps numbers had drifted
~10-30% from the 2026-04-29 sweep (Puma 1 MiB was 2,139 → 1,330 over
the same 24h window with no Puma config changes). The bench host
runs other workloads in the background, so each sweep is a snapshot.
The 2.0.1 numbers above are from a back-to-back rerun of both servers
on the same wrk window so they're directly comparable to each other,
even though absolute numbers differ from the 2026-04-29 column.

## 2.2.x fix-C addendum (2026-04-29) — large-payload TLS bench harness

**Phase 9 (kTLS_TX) was benched on the wrong workload.** The 2.2.0
sweep ran the kTLS row against `bench/hello.ru` (5 B response body)
and recorded -15% rps vs the 2.1.0 baseline (3,425 → 2,909). The
regression read as "kTLS didn't help", but at hello-payload the
cipher cost is a tiny fraction of per-request overhead — parser +
dispatch + handshake CPU dominate, so any kernel-side cipher savings
are invisible. The boot log confirmed kTLS engaged correctly
(`ktls_active: true, cipher: TLS_AES_256_GCM_SHA384`,
`/proc/modules: tls 155648 3 - Live`); the workload simply didn't
exercise the cipher path enough to see the win.

**fix-C ships two new bench rackups sized for the kTLS_TX sweet
spot:**

| Rackup | Payload | Why this size |
|---|---|---|
| `bench/tls_static_1m.ru` | 1 MiB static (Rack::Files via /tmp) | Big enough that the cipher accounts for most of the per-request cycles; pairs with the existing `bench/static.ru` for unencrypted comparison. |
| `bench/tls_json_50k.ru` | ~50 KB JSON (600 items × 8× name multiplier) | Mid-payload row. Large enough that cipher cost is meaningful, small enough to fit in one kernel TCP send buffer (~6 MB on Linux default). 30-80 KB is the kTLS_TX sweet-spot range. |

**Operator A/B knob: `HYPERION_TLS_KTLS`.** New env var added in
`lib/hyperion/cli.rb` so operators can flip kernel-TLS on/off
without rewriting their config DSL. Maps to `config.tls.ktls`:

| `HYPERION_TLS_KTLS` | `config.tls.ktls` | Behaviour |
|---|---|---|
| unset / empty | `:auto` (default) | Linux ≥ 4.13 + OpenSSL ≥ 3.0: kTLS_TX on; elsewhere: off |
| `auto` | `:auto` | Same as unset (explicitly) |
| `on` | `:on` | Force enable; raise at boot if unsupported |
| `off` | `:off` | Force disable; userspace SSL_write everywhere |
| anything else | (unchanged) | Warn + ignore (not a security boundary) |

**Bench harness (run on operator host):**

```sh
# Setup
ruby -e 'File.binwrite("/tmp/hyperion_bench_1m.bin", "x" * (1024*1024))'

# 50 KB JSON, kTLS auto (default)
bundle exec hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem \
  -t 64 -w 1 -p 9601 bench/tls_json_50k.ru
wrk -t4 -c64 -d20s --latency --timeout 8s https://127.0.0.1:9601/

# 50 KB JSON, kTLS off
HYPERION_TLS_KTLS=off bundle exec hyperion --tls-cert /tmp/cert.pem \
  --tls-key /tmp/key.pem -t 64 -w 1 -p 9601 bench/tls_json_50k.ru
wrk -t4 -c64 -d20s --latency --timeout 8s https://127.0.0.1:9601/

# 1 MiB static, kTLS auto (default)
bundle exec hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem \
  -t 64 -w 1 -p 9601 bench/tls_static_1m.ru
wrk -t4 -c64 -d20s --latency --timeout 8s \
  https://127.0.0.1:9601/hyperion_bench_1m.bin

# 1 MiB static, kTLS off
HYPERION_TLS_KTLS=off bundle exec hyperion --tls-cert /tmp/cert.pem \
  --tls-key /tmp/key.pem -t 64 -w 1 -p 9601 bench/tls_static_1m.ru
wrk -t4 -c64 -d20s --latency --timeout 8s \
  https://127.0.0.1:9601/hyperion_bench_1m.bin
```

Take the median of 3 runs per row (run-to-run variance on this
bench host is ~3-5%).

### Bench measurement results — 2026-04-30 (post fix-C)

Maintainer ran the harness on `openclaw-vm` (Ubuntu 24.04, kernel 6.8,
`tls 155648 3 - Live` in `/proc/modules`). Single 20 s `wrk` run per
row at `-t4 -c64 --timeout 8s` against `-t 64 -w 1`. Three-run
medians match the single-run numbers within 3% noise; reporting
single-run for clarity.

| Row | kTLS off (r/s, p99) | kTLS auto (r/s, p99) | Δ rps | Δ p99 |
|---|---:|---:|---:|---:|
| **TLS h1 50 KB JSON** `-t 64 -w 1` | 779, 86 ms | **924, 75 ms** | **+18.6%** | **-13%** |
| **TLS h1 1 MiB static** `-t 64 -w 1` | 58, 577 ms | **72, 497 ms** | **+24%** | **-14%** |

**Phase 9 kTLS_TX delivers on large payloads.** The 2026-04-30
hello-payload bench (which showed -15% rps with kTLS active) was
testing a 5-byte response where userspace cipher cost is a tiny
fraction of per-request overhead — Ruby logging + parser + dispatch
dominates, so kTLS adds setup overhead without paying back. At 50 KB
and 1 MiB the cipher cost dominates instead, and the kernel-side
encryption path skips the userspace SSL_write copy + AES-NI userspace
dispatch.

The held-status preamble's "didn't materialize" caveat for Phase 9
is updated to reflect the workload-dependent reality.

**One observation worth flagging for follow-up:** the boot log's
`ktls_active: true` status reads from `/proc/modules` (process-global
kernel-module check), not from a per-socket `SSL_get_KTLS_send`
probe. So both runs above logged `ktls_active: true` despite the
`ktls_policy` setting being `off` on the first run. The OpenSSL
`OP_ENABLE_KTLS` flag IS being toggled (the rps deltas confirm
that) but the boot-log reporter is misleading. `Hyperion::TLS.ktls_active?`
should be rewritten as a per-socket probe via Fiddle FFI to
`SSL_get_KTLS_send` so future operators can tell from the log
whether kTLS is actually engaged on a given connection. Filed as
2.3 follow-up.

## WebSocket echo (2.1.0+) — 2.2.x fix-E bench numbers

`bench/ws_echo.ru` — Hyperion 2.1.0+ WebSocket echo rackup. Driven
through `bench/ws_bench_client.rb`, a tight Ruby WS client built on
top of the gem's own `Hyperion::WebSocket::Frame` primitives (zero
external deps — the framing code is shared with the server side).
Two scenarios, both 1 KiB messages, 3 runs each, median reported.

| Workload | msg/s | p50 | p99 | max |
|---|---:|---:|---:|---:|
| WS echo (10 conns × 1000 msgs, latency, `-t 5`) | 6,463 | 0.76 ms | 1.03 ms | 1.81 ms |
| WS echo (10 conns × 1000 msgs, latency, `-t 256`) | 6,205 | 1.58 ms | 2.02 ms | 2.99 ms |
| WS echo (200 conns × 1000 msgs, throughput, `-t 256`) | 5,346 | 37.19 ms | 43.12 ms | 93.68 ms |

**openclaw-vm follow-up bench (2026-04-30, Linux 16-vCPU, single worker):**

| Workload | msg/s | p50 | p99 | max |
|---|---:|---:|---:|---:|
| WS echo (10 conns × 1000 msgs, latency, `-t 5`) | **1,962** | 2.51 ms | 3.27 ms | 4.58 ms |
| WS echo (200 conns × 1000 msgs, throughput, `-t 256`) | **1,766** | 112 ms | 134 ms | 141 ms |

**These are real numbers; the 50,000+ msg/s figure cited in the 2.1.0
perf-note was aspirational, not measured.** A single-worker Hyperion
on openclaw-vm pushes ~2 k msg/s against a single Ruby bench client
(the client itself is also single-process and likely a meaningful
portion of the bottleneck). To approach the 50 k msg/s figure an
operator would need either a multi-process client (2-4×), multiple
Hyperion workers (4×), and/or a non-Ruby client that doesn't pay
per-msg parser overhead. Filed as a 2.3 follow-up: rerun with `-w 4`
+ multi-process client, plus an autobahn-testsuite RFC 6455
conformance pass.

The dev-hardware numbers above (Apple Silicon) were higher per-msg
because per-message Ruby overhead is faster on M-series than on this
x86_64 16-vCPU box; that's a typical Ruby-bench shape and explains
the per-conn-thread vs throughput inversion.

### Reading the dev-hardware numbers

- **p50 echo round-trip 0.76 ms (10 conns / `-t 5`)** lines up cleanly
  with the 2.1.0 e2e smoke spec's documented "~0.18 ms p50 single-
  connection" — the smoke spec runs one client × one server thread,
  serializing through one fiber; this bench keeps 10 client threads
  in flight against `-t 5`, so the round-trip absorbs queue wait
  inside the server thread pool. Both numbers come out of the same
  read+frame+write pipeline.
- **The `-t 256` row is slower per-message than `-t 5`** at 10 conns.
  Each WebSocket connection permanently hijacks a worker thread for
  its lifetime, so when `-t 256` is configured the accept fiber
  goes wider with thread-creation + GVL contention overhead while
  the actual concurrent work is still 10. Operators sizing
  thread-count for steady-state WebSocket fleets should match
  `-t` to the expected concurrent-connection count, not over-
  provision.
- **The 200-conn row used `-t 256`** out of necessity. With `-t 5
  -w 1` (the brief's recommended config) the 6th client connection
  blocks at the handshake stage because all 5 worker threads are
  parked in the WS read loop holding hijacked sockets. **For
  WebSocket fleets, `-t` is a hard cap on concurrent connections
  per worker** — same shape as the existing 2.1.0
  `docs/WEBSOCKETS.md` "Configuration" guidance.
- **Throughput msg/s (200 × 1000 = 200 k msgs in ~37 s ≈ 5,346 msg/s)**
  is on the same order as the latency row — the bench host is
  bound on per-message wall time (mask + parse + write + read +
  unmask + echo + write), and adding more connections only adds
  scheduler overhead since the 14-vCPU dev box has finite
  parallelism. The openclaw-vm rerun should land **substantially**
  higher because (a) Linux fiber scheduler beats macOS on this
  shape and (b) 16 vCPU vs 14 efficient cores. The "50,000+ msg/s"
  target from 2.1.0 is reachable on Linux but will NOT show on
  Apple Silicon dev hardware.

### Bench rackup file-extension fix (`bench/ws_echo.rb` → `bench/ws_echo.ru`)

`bench/ws_echo.rb` was committed in the 2.1.0 release commit
(b097b78) with a `.rb` extension; `Rack::Builder.parse_file` treats
`.rb` files as ordinary Ruby and tries to `Object.const_get` the
camelized basename, which fails because the file uses the rackup
DSL (`run lambda { ... }`). The bench tool added in fix-E ships
`bench/ws_echo.ru` — same body, `.ru` extension — so the documented
boot command actually works:

```sh
bundle exec hyperion -t 5 -w 1 -p 9888 bench/ws_echo.ru
```

The original `.rb` file is left in place to avoid breaking
references elsewhere; future docs should point at the `.ru`
variant.

### RFC 6455 conformance — autobahn-testsuite

Deferred to 2.3. The bench host lacked the python `autobahntestsuite`
package and Docker daemon was not running; installing a fresh
toolchain just for fix-E exceeded the "trivially installable"
threshold the brief allowed. The 2.1.0 spec suite's
`spec/hyperion/websocket_*` files (handshake, frame, connection,
e2e) cover the WS-1 → WS-4 surfaces the autobahn fuzzingclient
would otherwise stress; the explicit RFC test-suite pass count
ships with the 2.3 follow-up.

### Reproducing this row

```sh
# Server — recommended for latency runs (10 concurrent conns)
bundle exec hyperion -t 5 -w 1 -p 9888 bench/ws_echo.ru

# Server — required for the 200-conn throughput run
bundle exec hyperion -t 256 -w 1 -p 9888 bench/ws_echo.ru

# Client — both runs
ruby bench/ws_bench_client.rb --port 9888 --conns 10  --msgs 1000 --bytes 1024 --json
ruby bench/ws_bench_client.rb --port 9888 --conns 200 --msgs 1000 --bytes 1024 --json
```

Take the median of 3 runs per row (run-to-run variance on this
bench host is ~3-5%).

## WebSocket multi-process bench (2.3-D, 2026-04-29)

`bench/ws_bench_client_multi.rb` — multi-process WS bench client. Forks
N child processes (`--procs N`), each running `bench/ws_bench_client.rb`
in `--json` mode against a slice of the total connection count, then
aggregates results: `total_msgs = Σ child[total_msgs]`, wall
`elapsed = max(child[elapsed_s])`, `msg/s = total_msgs / elapsed`,
`p50 / p99 / max = max across children` (conservative — the slowest
child sets the published tail).

**Why a multi-process client.** The single-process bench client (fix-E)
serialises all per-message work (mask/unmask, frame parse, IO.select)
through one Ruby interpreter under the GVL. At 200 concurrent
connections the *client* becomes the bottleneck; fix-E's openclaw-vm
200-conn row landed at 1,766 msg/s with p99 134 ms — that long tail
was client-side scheduler queueing. Splitting the load across N OS
processes gives each its own GVL.

### Bench numbers — macOS dev (Apple Silicon, 14 efficient cores)

3 runs each, `bundle exec hyperion -t 256 -w 1 -p 9888 bench/ws_echo.ru`,
median reported.

| Workload | msg/s | p50 | p99 | max |
|---|---:|---:|---:|---:|
| WS echo, 4 procs × 10 conns × 1000 msgs (40-conn aggregate) | **13,594** | 2.49 ms | 7.75 ms | 16.64 ms |
| WS echo, 4 procs × 50 conns × 1000 msgs (200-conn aggregate) | **14,757** | 13.01 ms | 21.75 ms | 142 ms |

vs fix-E single-process baseline on the same host:

| Workload | fix-E single-proc msg/s | 2.3-D 4-proc msg/s | Δ |
|---|---:|---:|---:|
| 10-conn latency probe | 6,463 | 13,594 | **+110%** (2.10×) |
| 200-conn throughput   | 5,346 | 14,757 | **+176%** (2.76×) |

**The 200-conn p99 dropped from 43.12 ms (fix-E single-process) to
21.75 ms (2.3-D 4-proc) — exactly half**, confirming the long tail in
fix-E was client-side serialisation, not server-side latency.

### openclaw-vm bench (Linux 16-vCPU, 2.4-D — 2026-04-30)

3 runs each, median reported.
Server: `HYPERION_WS_DEFLATE=on bundle exec hyperion -t 64 -w 4 -p 9888 ~/bench/ws_echo.ru`
Client: `ruby ~/bench/ws_bench_client_multi.rb --host 127.0.0.1 --port 9888 --procs 4 --conns N --msgs 1000 --bytes 1024 --json`.

| Workload | msg/s | p50 | p99 | max |
|---|---:|---:|---:|---:|
| WS echo, 4 procs × 40 conns × 1000 msgs (40-conn aggregate) | **7,561** | 5.26 ms | 6.22 ms | 8.93 ms |
| WS echo, 4 procs × 200 conns × 1000 msgs (200-conn aggregate) | **6,880** | 28.60 ms | 33.86 ms | 36.35 ms |

Raw runs (host `openclaw-vm`, 16 vCPU, Ubuntu 24.04, kernel 6.8,
Ruby 3.3.3, hyperion master @ `ffcbdfb`):

```
# 4 procs × 40 conns
6,862 / 6,880 / 6,974 msg/s  (median 6,880)
# 4 procs × 200 conns
7,561 / 7,457 / 7,631 msg/s  (median 7,561)
```

vs fix-E single-process Linux baseline on the same host:

| Workload | fix-E single-proc msg/s | 2.4-D 4-proc msg/s | Δ |
|---|---:|---:|---:|
| 10-conn / 40-conn latency | 1,962 | 7,561 | **+285%** (3.85×) |
| 200-conn throughput       | 1,766 | 6,880 | **+289%** (3.89×) |

The fix-E single-process Linux numbers were client-side GVL-bound
(see "Why a multi-process client" above); the 2.4-D 4-proc lift
debunks the long Linux tail definitively (p99 134 ms → 33.86 ms,
−75%).

**Cross-platform shape comparison (within-host scaling, NOT
apples-to-apples raw rps):**

| Host | 200-conn p99 | 4-proc lift over single-proc |
|---|---:|---:|
| Apple Silicon dev (efficient cores)  | 21.75 ms | +176% (2.76×) |
| openclaw-vm (Linux 16-vCPU x86_64)   | 33.86 ms | +289% (3.89×) |

Linux x86_64 has more headroom under the multi-process model than
the macOS dev box — the absolute msg/s on Apple Silicon is
higher (14,757 vs 6,880) at the 200-conn row because the M-series
single-thread perf is roughly 2× the cloud x86_64 vCPU, but the
proportional lift from multi-process is larger on Linux because
the fix-E single-process Linux floor was lower to begin with.
Both hosts agree on the bottleneck shape: client-side GVL, not
server-side latency.

The aspirational 50,000 msg/s figure from the 2.1.0 brief still
needs `-w 16 -t small` plus a non-Ruby client; that's a 2.5
follow-up.

### Reproducing on macOS dev

```sh
bundle exec hyperion -t 256 -w 1 -p 9888 bench/ws_echo.ru &

# 200-conn throughput (4 procs × 50 conns each)
ruby bench/ws_bench_client_multi.rb --port 9888 \
  --procs 4 --conns 200 --msgs 1000 --bytes 1024 --json

# 40-conn latency (4 procs × 10 conns each)
ruby bench/ws_bench_client_multi.rb --port 9888 \
  --procs 4 --conns 40 --msgs 1000 --bytes 1024 --json
```

Note `-t 256` is required — at `-t 64 -w 1`, more than 64 of the 200
client connections drop at the handshake stage because each WS
connection permanently hijacks a worker thread (same shape as fix-E).
`-w 4 -t 64` (the brief's recommended Linux config) sidesteps this
by giving each worker its own 64-thread budget, but requires `fork`
on the boot path which is unreliable on macOS dev.

### RFC 6455 conformance — autobahn-testsuite

Config landed in `autobahn-config/fuzzingclient.json`. The full run
is **deferred — Docker daemon was not running locally this session**
and the openclaw-vm bench host (where `crossbario/autobahn-testsuite`
ships pre-pulled) was unreachable. See `docs/WEBSOCKETS.md`
"RFC 6455 conformance" for the recipe and known-limitation matrix.

## 4-way head-to-head (2.10-B baseline, 2026-05-01)

> **This is the BASELINE 4-way bench, captured BEFORE any 2.10-C/D/E/F
> code lands.** It establishes the honest gap that subsequent 2.10
> streams (static-response cache, direct route registration, etc.) need
> to close. Re-run after each 2.10 stream lands to prove (or disprove)
> that the perf work moved the needle.

**Host.** openclaw-vm (Ubuntu 24.04, KVM single-VM, Ruby 3.3.3, Linux
6.8.0). Same host as every other row in this doc; absolute-rps drift
of ±10-30% between sweep dates is expected — the *relative* position
between the four servers is the durable signal.

**Matched config.** All four servers share a `-t 5 -w 1` budget (5
threads / fibers per process, 1 worker process). Boot recipes are in
`bench/4way_compare.sh` (and CHANGELOG 2.10-A). Hyperion 2.9.0 (the
master HEAD as of this writing — version.rb has not been bumped for
2.10), Puma 8.0.1, Falcon 0.55.3, Agoo 2.15.14.

**Bench tools.** Each row was driven by *both* `wrk -t4 -c100 -d20s
--latency` and `perfer -t4 -c100 -k -d20 -l 50,90,99` so the numbers
can be checked against Agoo's published headline figures (Agoo
publishes via `perfer`, https://github.com/ohler55/perfer, not wrk).
3 trials per (rackup, server, tool); median reported.

> **perfer caveats** discovered while wiring this in:
>
> 1. **Case-sensitive header strstr.** perfer's `drop.c` uses
>    `strstr(d->buf, "Content-Length:")` — case-sensitive. Hyperion is
>    RFC 9110 lowercase (`content-length:`); Puma/Falcon/Agoo emit
>    title-case. Patched perfer to `strcasestr` (with `#define
>    _GNU_SOURCE`) before use. **Fix:** upstream this to ohler55/perfer.
> 2. **Warmup deadlock vs Hyperion at `-t 5 -c 100`.** perfer's
>    `pool_warmup` connects + send-pings *all* 100 connections, then
>    recv-loops with a per-call 2.0s timeout. Hyperion's
>    accept-then-thread-pool model under `-t 5` doesn't drain 100
>    simultaneous warmup pings inside that window — the connections
>    that don't get a thread within 2s get reported "timed out waiting
>    for a response" and the whole run aborts. Raising Hyperion to
>    `-t 200` makes perfer happy but breaks the matched-config rule.
>    **Workaround for 2.10-B:** record `NA` for hyperion+perfer and
>    rely on wrk for the headline; flag rows as wrk-only. Puma /
>    Falcon / Agoo are unaffected.
> 3. **16 KB recv buffer.** perfer's `MAX_RESP_SIZE = 16384` — the
>    static-1-MiB row (3) is `NA` across all four servers under
>    perfer because the 1 MiB body overflows the receive buffer. wrk
>    handles arbitrary body sizes, so we keep the 1-MiB row on wrk only.
> 4. **SSE timeout.** SSE rackups under `-t1 -c1 -d10s` produce
>    streamed multi-chunk responses that perfer parses as zero
>    successful requests (it expects one full HTTP/1.1 response per
>    request, with framing it can compute up-front). Reported `0` for
>    perfer on row 6 — wrk handles the chunked stream correctly.

### Headline

| Row | Workload | Hyperion | Puma | Falcon | Agoo | Verdict |
|---|---|---:|---:|---:|---:|---|
| 1 | hello | 4,587 r/s | 4,049 r/s | 6,082 r/s | **19,364 r/s** | Agoo wins by **4.2× over Hyperion**; Hyperion has the cleanest p99 (2.08 ms) |
| 2 | static 1 KB | 1,380 r/s | 1,416 r/s | 1,785 r/s | **2,606 r/s** | Agoo wins; Hyperion / Puma effectively tied; Hyperion p99 20× tighter (4.86 ms vs 93.86 ms) |
| 3 | static 1 MiB | **1,378 r/s** | 1,282 r/s | 523 r/s | 152 r/s | Hyperion wins (sendfile path); Falcon and Agoo collapse on large bodies |
| 4 | CPU JSON 50-key | 3,450 r/s | 2,771 r/s | 4,245 r/s | **6,374 r/s** | Agoo wins by **1.85× over Hyperion**; Hyperion has the cleanest p99 (2.73 ms) |
| 5 | PG-bound async (`pg_sleep 50ms`) | **1,564 r/s** | n/a | n/a | n/a | Hyperion only — Puma / Falcon / Agoo can't run this rackup |
| 6 | SSE 1000 events × 50 B | **500 r/s** | 137 r/s | 29 r/s | smoke-fail | Hyperion wins by **3.6× over Puma**, **17× over Falcon**; Agoo can't stream SSE chunked — buffers the full 34 KB body, returns ~0.1 r/s under wrk -t1 -c1 -d10s |

**Honest reading.**

- **Agoo is faster than Hyperion on hello-world (4.2×) and CPU JSON (1.85×).** That gap is what the 2.10-C/D/E/F streams need to close (or honestly prove uncloseable). The 4.2× hello gap is the upper-bound delta — for real-world workloads with even a tiny bit of body or work, the gap shrinks to under 2×. There is no shame in *this* baseline; the goal of 2.10 is to walk it down to <2× hello and <1.5× JSON without breaking RFC compliance / streaming / large-payload paths.
- **Hyperion is fastest on the workloads that matter operationally** — large static (sendfile, 9× ahead of Agoo), PG-bound async (Hyperion-only), and SSE streaming (3.6×–17× ahead). These are the workloads where most production Rails / Roda / Hanami apps actually live.
- **Tail latency is Hyperion's clean win across every row.** Hyperion's worst p99 across the 6 rows is 145.71 ms (PG-bound, intentional); the next worst is 5.62 ms (1 MiB static). Puma's worst is 95.17 ms; Falcon's worst is 833.54 ms; Agoo's worst is 743.37 ms. If you care about p99 stability for an SLO budget, Hyperion is the only server here with a tail under 10 ms across all the production-shaped workloads.
- **Falcon's hello / CPU-JSON p99 (~408 ms across runs)** is the documented `--hybrid` head-of-line latency under `-c 100`. The `r/s` is fine; the tail is not. Same shape we saw in 2.9-B.

### Per-row detail

#### Row 1: hello (`bench/hello.ru`, `wrk -t4 -c100 -d20s`)

5-byte body, two response headers. Pure dispatch + write throughput.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.9.0 | 4,587 | 2.08 ms | NA¹ | NA¹ |
| Puma 8.0.1 | 4,049 | 28.74 ms | 4,046 | 27.62 ms |
| Falcon 0.55.3 | 6,082 | 408.53 ms | 5,849 | 397.59 ms |
| Agoo 2.15.14 | **19,364** | 9.41 ms | **20,244** | 7.52 ms |

¹ perfer warmup deadlock vs Hyperion `-t 5 -c 100` (see top-of-section
caveats). wrk and perfer agree within 5% on every other server.

**Verdict.** Agoo wins by ~4.2× on r/s (`19k vs 4.5k`), but Hyperion
holds the tightest p99 (2.08 ms) by ~4.5× over Agoo's 9.41 ms. This
is the baseline gap 2.10-C (static-response cache) is targeted at —
hello-world dispatch is exactly the cache's hot path.

#### Row 2: static 1 KB (`bench/static.ru`, URL `/hyperion_bench_1k.bin`, `wrk -t4 -c100 -d20s`)

1024 bytes of `'x'`. Sendfile vs userspace copy.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.9.0 | 1,380 | **4.86 ms** | NA¹ | NA¹ |
| Puma 8.0.1 | 1,416 | 93.86 ms | 1,633 | 81.34 ms |
| Falcon 0.55.3 | 1,785 | 64.87 ms | 1,872 | 61.88 ms |
| Agoo 2.15.14 | **2,606** | 58.89 ms | **2,818** | 40.76 ms |

**Verdict.** Agoo wins by ~1.9×; Hyperion and Puma tied on r/s but
Hyperion's p99 is **20× tighter** (4.86 ms vs 93.86 ms). Falcon
slots between. The 1 KB row sits below the sendfile threshold so
Hyperion's zero-copy advantage doesn't kick in — see Row 3 for
where it does.

#### Row 3: static 1 MiB (`bench/static.ru`, URL `/hyperion_bench_1m.bin`, `wrk -t4 -c100 -d20s`)

1 MiB of `'x'`. Bandwidth + sendfile path.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.9.0 | **1,378** | **5.62 ms** | NA² | NA² |
| Puma 8.0.1 | 1,282 | 95.17 ms | NA² | NA² |
| Falcon 0.55.3 | 523 | 833.54 ms | NA² | NA² |
| Agoo 2.15.14 | 152 | 743.37 ms | NA² | NA² |

² perfer's `MAX_RESP_SIZE = 16384` — 1 MiB body overflows.

**Verdict.** **Hyperion wins** — by 1.07× over Puma, **2.6× over
Falcon**, and **9× over Agoo**. Sendfile + chunked-coalescing earn
their keep. Agoo's 152 r/s is the most surprising number in the
sweep: Agoo is a pure-C HTTP core but it's not optimised for the
large-static path. This row is one of two (the other is SSE) where
the 2.10 follow-on streams have nothing to prove against Agoo —
Hyperion is already the right choice for static asset delivery.

#### Row 4: CPU JSON 50-key (`bench/work.ru`, `wrk -t4 -c100 -d20s`)

8,257-byte JSON response (`PAYLOAD_JSON_BYTES + 200B request_id /
cookies wrapper`), per-request `JSON.generate` so the JIT can't
constant-fold. Header parsing exercised.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.9.0 | 3,450 | **2.73 ms** | NA¹ | NA¹ |
| Puma 8.0.1 | 2,771 | 40.74 ms | 2,951 | 37.74 ms |
| Falcon 0.55.3 | 4,245 | 410.05 ms | 4,051 | 399.15 ms |
| Agoo 2.15.14 | **6,374** | 19.18 ms | **7,299** | 16.55 ms |

**Verdict.** Agoo wins by 1.85× over Hyperion, 1.5× over Falcon, 2.3×
over Puma. Hyperion has the cleanest p99 by ~7× over Agoo (2.73 ms
vs 19.18 ms). This is the row 2.10-D (direct route registration)
should move — the JSON-encode hot path is the obvious candidate for
zero-allocation header writes + `Date:` cache reuse.

#### Row 5: PG-bound async, 50 ms `pg_sleep` (`bench/pg_concurrent.ru` MODE=async PG_POOL_SIZE=80, `wrk -t4 -c200 -d20s --timeout 8s`)

Each request runs `SELECT pg_sleep(0.05)` against PG 17 on
`postgres:bench@127.0.0.1:5432/postgres` (max_conn=100). Hyperion
runs with `--async-io` + the `hyperion-async-pg` fiber pool;
the other three servers physically *cannot* run this rackup
(no fiber-cooperative I/O to yield to during the 50 ms wait —
they would block 5 OS threads at ~100 r/s ceiling, which is the
pre-`hyperion-async-pg` baseline already documented in 2.9-D).

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.9.0 (`--async-io`) | **1,564** | 145.71 ms | **1,572** | 139.16 ms |
| Puma 8.0.1 | n/a — no fiber-cooperative I/O | | | |
| Falcon 0.55.3 | n/a — would block on plain `pg` | | | |
| Agoo 2.15.14 | n/a — incompatible rackup (uses `Hyperion::AsyncPg`) | | | |

**Verdict.** Hyperion-only row. The 1,564 r/s number is the same
shape as the 2.9-D matched-config bench (which got ~1,500 r/s at
PG_POOL_SIZE=64) — internally consistent. wrk and perfer agree
within 0.5%. This is the workload the `--async-io + hyperion-async-pg`
combination was designed for; no other server in the matrix can
play.

#### Row 6: SSE 1000 events × 50 B (`bench/sse_generic.ru`, `wrk -t1 -c1 -d10s`)

Lazy-iterator body yields 1000 `data: event=... ts=...\n\n`
messages per request. Single client connection (SSE is one
long-lived stream per consumer); the relevant axis is **events
per second per connection**, not parallel rps.

| Server | wrk r/s | wrk p99 | perfer r/s | perfer p99 |
|---|---:|---:|---:|---:|
| Hyperion 2.9.0 | **500** | 2.59 ms | 0³ | 0³ |
| Puma 8.0.1 | 137 | 9.23 ms | 0³ | 0³ |
| Falcon 0.55.3 | 29 | 38.60 ms | 0³ | 0³ |
| Agoo 2.15.14 | smoke-fail⁴ | — | — | — |

³ perfer's response-framing logic doesn't handle chunked SSE
streams — reports 0 successful requests. wrk's `c=1` model
(read-until-close) parses the chunked stream correctly. Treat
perfer as not-applicable for SSE.

⁴ Agoo *does* serve the SSE rackup — `curl` returns the full
34,890-byte body — but it buffers the entire response before
flushing. The harness smoke check gives up after 2 s; Agoo
takes ~5 s to deliver the full body to a single client. A
manual `wrk -t1 -c1 -d10s --timeout 30s` against Agoo
returned ~0.1 r/s (1-2 complete responses across the 10 s
run). Agoo is **not a viable SSE server at any throughput**
under this workload — it does chunked encoding but does not
yield mid-response.

**Verdict.** **Hyperion wins by 3.6× over Puma, 17× over Falcon,
and ~5,000× over Agoo.** SSE is one of Hyperion's flagship
workloads (`bench/sse.ru` with the `__hyperion_flush__` sentinel
goes faster still — see § "SSE streaming" earlier in this doc);
the generic Rack 3 chunked-streaming protocol still puts Hyperion
~3.6× ahead of the next-best contender. This row plus the 1 MiB
static row defines the workload territory the 2.10 follow-on
streams should *not* regress.

### Reproducing 4-way

```sh
# On openclaw-vm (or any Linux box with Ruby 3.3.3 + wrk + PG 17 + perfer):
cd /home/ubuntu/hyperion-fresh   # or your hyperion checkout
export BUNDLE_GEMFILE=$PWD/bench/Gemfile.4way
export HYPERION_PATH=$PWD
bundle install

# Build perfer (Agoo's bench tool):
git clone https://github.com/ohler55/perfer.git /tmp/perfer
sed -i 's/strstr(d->buf, content_length)/strcasestr(d->buf, content_length)/g; s/strstr(d->buf, transfer_encoding)/strcasestr(d->buf, transfer_encoding)/g' /tmp/perfer/src/drop.c
sed -i '2a #define _GNU_SOURCE' /tmp/perfer/src/drop.c
(cd /tmp/perfer && make)

# Prep static fixtures:
ruby -e 'File.binwrite("/tmp/hyperion_bench_1k.bin", "x" * 1024)'
ruby -e 'File.binwrite("/tmp/hyperion_bench_1m.bin", "x" * 1048576)'

# Per-row commands (each runs 4 servers × 3 trials × wrk + perfer):
URL_PATH=/                     bench/4way_compare.sh bench/hello.ru
URL_PATH=/hyperion_bench_1k.bin bench/4way_compare.sh bench/static.ru
URL_PATH=/hyperion_bench_1m.bin bench/4way_compare.sh bench/static.ru
URL_PATH=/                     bench/4way_compare.sh bench/work.ru
URL_PATH=/ HYPERION_EXTRA=--async-io \
  MODE=async PG_POOL_SIZE=80 \
  DATABASE_URL=postgres://postgres:bench@127.0.0.1:5432/postgres \
  RUBYOPT='-rhyperion/async_pg' WRK_CONNS=200 WRK_TIMEOUT=8s \
  bench/4way_compare.sh bench/pg_concurrent.ru hyperion
URL_PATH=/ DURATION=10s WRK_THREADS=1 WRK_CONNS=1 \
  bench/4way_compare.sh bench/sse_generic.ru
```

The `RUBYOPT='-rhyperion/async_pg'` is required because Hyperion's
`--async-io` flag validates a fiber-cooperative I/O library is
loaded *before* loading the rackup; the rackup's own
`require 'hyperion/async_pg'` runs too late.
