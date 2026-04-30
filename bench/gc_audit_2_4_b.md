# 2.4-B GC pressure audit (baseline against 2.3.0)

## Methodology

`bench/gc_audit_2_4_b.rb` drives four sustained workloads with `GC.disable`
during the measurement window so per-iter allocation deltas attribute
directly to the workload (not to GC noise):

* **http**       — 100 keep-alive TCP conns × 50 GETs = 5000 reqs through
                   `Hyperion::Connection.serve` with the C parser hot path
* **chunked**    — 10000 in-memory `parser.parse(request)` calls on a
                   4-chunk POST request (no socket overhead, isolates the
                   chunked body parse path)
* **ws**         — 10000 masked text frames recv'd through
                   `Hyperion::WebSocket::Connection#recv` (C frame parser +
                   reassembly + Frame Struct alloc)
* **ws_deflate** — 10000 server-side sends with permessage-deflate active
                   (Zlib::Deflate + sync-trailer strip + Builder)

Site attribution: `bench/gc_audit_2_4_b_trace.rb` runs the same workloads
under `ObjectSpace.trace_object_allocations` with `GC.disable` so live-
object scanning attributes Strings/Arrays/Hashes back to file:line. Most
short-lived (and therefore truly hot) Ruby allocations show up in
`GC.stat[:total_allocated_objects]` deltas; the C-ext allocations show up
attributed to `parser.c` / `websocket.c` callsites.

## 2.3.0 baseline (Ruby 3.3.3, no YJIT, macOS arm64, C ext built)

| workload     | total/iter | GC.count/iter | T_STRING delta | T_HASH delta | T_ARRAY delta |
|--------------|-----------:|--------------:|---------------:|-------------:|--------------:|
| http         |       67.0 |        1/555  |             33 |            3 |             6 |
| chunked      |       28.0 |        1/1428 |             39 |            4 |             1 |
| ws           |       28.0 |        1/476  |             30 |            0 |             2 |
| ws_deflate   |       13.0 |        1/2000 |             25 |            2 |             0 |

The "total/iter" includes Symbols/Range/MatchData/Float etc. which don't
break out into the count_objects deltas. The chunked & WS rows are the
true per-message numbers — http includes the dispatch + ResponseWriter
round-trip on top.

## Top 5 allocation sites (with hypothesis)

### S1 — `parser.c:140-146` `state_init` empty-String preallocation

Every `parse()` call unconditionally allocates **6 empty Strings**:
`path`, `query_string`, `http_version`, `body`, `current_header_name`,
`current_header_value`. They're rb_str_cat'd into later, but the body
string is left empty for GET requests, http_version is always overwritten
("HTTP/" + at), and the current_header_* pair is reset to fresh empty
Strings after every header (lines 185-186) — so every header in a
request adds 2 more empty allocations.

A typical GET with 6 headers therefore burns **6 + 2×6 = 18 Strings on
empty placeholders**, of which only 2-3 actually accumulate any data
(method, path, http_version → 3 used; the 6 stash strings are 12 alloc
where 6 are reused).

**Hypothesis (S1):** Initialise to Qnil, allocate the field String in the
relevant `on_*` callback's first call. Reset to Qnil (not a fresh empty
String) after `stash_pending_header`. Saves ~12 String allocations per
6-header request, ~2-3 per chunked POST (no headers in body chunks).

### S2 — `parser.c:259-260` per-parse `cl_key`/`te_key` lookup strings

Every `parse()` call allocates **two literal Strings** ("content-length",
"transfer-encoding") for `rb_hash_aref` lookups at the smuggling defense
check. These are constant inputs — should be pre-interned at module init
once.

**Hypothesis (S2):** Promote to static `rb_obj_freeze`'d VALUEs at
`Init_hyperion_http`, register with `rb_gc_register_mark_object`. Saves
2 String allocations per parse — a fixed win, not message-rate scaling.

### S3 — `parser.c:379-388` `kwargs` Hash + funcallv_kw for Request build

Every `parse()` returns a `Hyperion::Request` built via
`rb_funcallv_kw(rb_cRequest, id_new, ...)` with a freshly-allocated
`kwargs` Hash containing 6 Symbol keys. The Hash is thrown away by
Ruby's kw arg unpacking inside `Request#initialize`.

**Hypothesis (S3):** Bypass kwargs by calling
`rb_struct_new(rb_cRequest, ...)` directly. Hyperion::Request is a Data
class (frozen value object) with positional new. Saves 1 Hash alloc per
parse.  *Risk:* Request might be a regular class, not Data — will check
the lib/hyperion/request.rb shape before applying. If we can't call
`.new` positionally, we keep `kwargs` but reuse a per-thread Hash.

### S4 — `frame.rb:149` `Builder.build` `.b` re-encoding allocation

`bin_payload = payload.is_a?(String) ? payload.b : payload.to_s.b` —
`.b` ALWAYS allocates a fresh String, even when the input is already
ASCII-8BIT. Hot for WS chat / ActionCable workloads where every send()
goes through here.

**Hypothesis (S4):** Skip `.b` when `payload.encoding == Encoding::BINARY`.
Saves 1 String per send() on workloads that pre-encode (which is what
most WS apps do — inbound frames arrive binary, server echoes binary).

### S5 — `frame.rb:91-92` `Parser.parse` byteslice + `.b`

Per parsed frame: `slice = buf.byteslice(payload_offset, payload_len)`
allocates 1 String (the slice itself), then `slice.b` allocates a
SECOND String when the frame isn't masked. (Masked frames go through
`CFrame.unmask` which already returns binary — no `.b` needed.)

**Hypothesis (S5):** Drop the redundant `slice.b` — `byteslice` on an
ASCII-8BIT-encoded `@inbuf` already returns ASCII-8BIT (verified in WS
Connection#initialize: `@inbuf = String.new(capacity: ..., encoding:
ASCII_8BIT)`). The `.b` call is paranoid and never changes encoding;
strip it. Saves 1 String per unmasked frame parse.

## Sites considered & deferred

* **WS frame parse 8-element Array (websocket.c:293).** Allocated per
  parsed frame, immediately destructured by Ruby. Could become a per-
  parse Struct with positional accessors, but that's an API break for
  the Ruby façade & tests. Deferred — site is fixed-size, doesn't grow
  with payload.
* **Connection `@inbuf` initial capacity (8 KiB → 16 KiB).**
  Verified: 95th-percentile request lines + headers fit comfortably in
  4 KB; 8 KB is correct. A 10k-keep-alive RSS regression isn't worth
  the rare doubled-realloc on >8 KB headers. **NO CHANGE.**
* **`Connection.enrich_with_peer` allocates a fresh Request once per
  connection.** Per-conn, not per-message. Already cheap. Defer.
* **WS Connection's deflater (`@deflater` per conn).** Verified: one
  Zlib::Deflate per connection, lifecycle correct. The
  `Zlib::Deflate.deflate(payload, SYNC_FLUSH)` does allocate one
  intermediate String per call — that's a Zlib internal we can't avoid
  cheaply. The post-strip `byteslice(0, len-4)` is unavoidable per RFC
  7692. Defer.
* **Per-conn Hash for headers / env reuse.** Phase 11 already pools
  env Hashes via `Hyperion::Adapter::Rack::ENV_POOL`. Headers Hash is
  built fresh by C parser into the Request. No additional pool
  warranted on this audit's evidence.

## Expected post-fix per-iter

| workload     | 2.3.0 | est 2.4-B | source                                |
|--------------|------:|----------:|---------------------------------------|
| http (GET)   |  67.0 |    50-55  | S1 (-15) + S2 (-2) + S3 (-1) on parser|
| chunked      |  28.0 |    18-22  | S1 (-6) + S2 (-2) + S3 (-1)           |
| ws           |  28.0 |    25-26  | S5 (-1) per frame; small win          |
| ws_deflate   |  13.0 |    11-12  | S4 (-1) per send                      |

GC frequency under sustained load is a function of *total* allocation
rate, so a 25% per-iter reduction translates to ~25% fewer GC events
for the same workload — call it **GC frequency -25 to -30%** as the
sustained-load target.

## Measured post-fix (Linux x86_64, openclaw-vm, Ruby 3.3.3, no YJIT)

| workload     | 2.3.0 | 2.4-B | delta | GC freq 2.3.0 | GC freq 2.4-B | freq delta |
|--------------|------:|------:|------:|---------------|---------------|-----------:|
| chunked      |  28.0 |  17.0 | -39%  | 1/689         | 1/952         | -28%       |
| ws (masked)  |  28.0 |  28.0 |   0%  | 1/625         | 1/625         |   0%       |

Per-parse on macOS arm64 (Ruby 3.3.3, no YJIT, 5000-iter steady-state):

| case                          | 2.3.0 | 2.4-B | delta |
|-------------------------------|------:|------:|------:|
| GET /, 1 header               | 19.00 |  9.00 | -53%  |
| GET /a?q=1, 5 headers         | 36.00 | 18.00 | -50%  |
| POST chunked, 4 chunks        | 27.00 | 16.00 | -41%  |

WS recv is unchanged on the *masked* path (the audit's default
scenario): masked frames go through `CFrame.unmask` regardless of S5,
which already returns a fresh binary String. S5's win shows up on the
*unmasked* path that the regression spec covers (Builder.build chains).

## wrk validation (openclaw-vm, 30s, -t4 -c200, hyperion -w4 -t5)

| build     | req/s   | p50    | p99    | std-dev |
|-----------|--------:|-------:|-------:|--------:|
| 2.3.0     | 14833   | 1.27ms | 2.64ms | 329µs   |
| 2.4-B     | 14985   | 1.26ms | 2.61ms | 330µs   |
| delta     |  +1%    | -1%    | -1%    |  ~0%    |

Throughput was already adapter-bound; the win is GC pressure. p99 and
std-dev are within noise on a 30s run — the long-run-stability spec
(spec/hyperion/long_run_stability_spec.rb) is the regression guard
that would catch a re-introduction of the GC pressure.
