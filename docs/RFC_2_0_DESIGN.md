# RFC: Hyperion 2.0 design

Status: DRAFT — locks architectural direction before 1.6.3 hotfixes ship. Audit cycle source: 4-pass review of 1.6.x. Companion gem `hyperion-async-pg` is in scope where the two interact.

---

## 1. Goals & non-goals

### Goals

- **Untangle the dispatch matrix** (A2). 4 flags, 5 valid cells, 24 total — currently no enum, no boot validation. Lock behind an internal value object.
- **Make runtime services swappable** (A3). `Hyperion.metrics=` only reaches new connections; long-lived keep-alives keep the old object. Promote to constructor injection via `Hyperion::Runtime`; singleton becomes the *default*.
- **Group config** (A4). Flat 25-field `DEFAULTS` with telegraphing prefixes (`h2_*`, `worker_*`, `log_*`, `admin_*`) → nested subconfigs without changing top-level DSL.
- **Replace global side-effects with Rails idioms** (A5). `ActiveRecordAdapter.install!` flips `AS::IsolatedExecutionState.isolation_level` process-globally with no production rollback. Move into a Railtie at the right initializer position.
- **Headroom for accept-loop scaling** (A6). Single accept fiber hits ~25–50 k accept/s/worker. Add opt-in multi-fiber accept under SO_REUSEPORT.
- **Close the H2 abuse window** (A7). Per-connection stream cap doesn't bound per-process fibers; 5,000 connections × 128 streams → OOM. Add process-wide H2 admission control.
- **Defense-in-depth for admin endpoints** (A8). In-app middleware leaks bearer tokens through request-headers loggers and is mis-orderable. Add opt-in sibling listener.
- **Tighten `async_io` validation** (A9). Constructor accepts any object; `1`, `:yes`, `'true'` silently land in the auto branch.

### Non-goals

- **No throughput regressions** vs the 1.6.0 baseline (`README.md` + `docs/BENCH_2026_04_27.md`). 2.0 RC re-runs the headline configs.
- **No language-version bumps.** Stay on Ruby ≥ 3.3.
- **No HTTP/2 multiplexing redesign.** 1.6.0 writer-fiber architecture stays.
- **No new wire features** (no HTTP/3, no h2c upgrade, no WebSocket).
- **No `DispatchMode` public surface.** Operators read modes via `Hyperion.stats[:requests_dispatch_<mode>]` counters, not via the class.
- **JRuby / TruffleRuby** stays "should boot via pure-Ruby parser fallback"; not "primary target."

---

## 2. Per-feature design

### A2 — `DispatchMode` value object replaces 5-mode `Server#dispatch` if/elsif chain

**Problem.** `Server#dispatch` and `Server#inline_h1_dispatch?` together form a 4-flag, 5-output state machine: `@tls`, `@async_io ∈ {nil, true, false}`, `@thread_count`, ALPN. The 1.4.0 changelog spells out the matrix in prose because there's no enum to look at. No spec catches `async_io: true + thread_count: 0 + plain HTTP` at boot — it works (inline, no pool, no scheduler) but operators don't know that's a supported combination. No central place to add per-mode metrics tags or tracing.

**Proposed shape.** Internal value object built once per dispatch (or cached at `Server#start` and re-resolved on the per-socket ALPN-discriminated branch):

```ruby
# lib/hyperion/dispatch_mode.rb
class Hyperion::DispatchMode
  MODES = %i[tls_h2 tls_h1_inline async_io_h1_inline threadpool_h1 inline_h1_no_pool].freeze

  attr_reader :name

  def self.resolve(tls:, async_io:, thread_count:, alpn:)
    return new(:tls_h2)             if tls && alpn == 'h2'
    return new(:tls_h1_inline)      if tls && async_io != false
    return new(:async_io_h1_inline) if !tls && async_io == true
    return new(:threadpool_h1)      if thread_count.positive?
    new(:inline_h1_no_pool)
  end

  def initialize(name)
    raise ArgumentError, "unknown DispatchMode #{name.inspect}" unless MODES.include?(name)
    @name = name
  end

  def inline?;     %i[tls_h1_inline async_io_h1_inline inline_h1_no_pool].include?(@name); end
  def threadpool?; @name == :threadpool_h1; end
  def h2?;         @name == :tls_h2; end
end
```

`Server#dispatch` collapses to a `case mode.name`. Boot validation moves into `Config#validate!` (already needed for A9). Per-mode metrics keys (`:requests_dispatch_<mode>`) replace the current `:requests_async_dispatched` / `:requests_threadpool_dispatched` pair.

**Public API impact.** Additive. `DispatchMode` is internal; the constant lives under `Hyperion::DispatchMode` but is not documented as public. The mode name is exposed via `Hyperion.stats` so operators can see it without reflection (`stats[:dispatch_mode]` → `:threadpool_h1`).

**1.x vs 2.0 split.**
- 1.7.0 ships `DispatchMode` internally + `Server#dispatch` switch refactor + `Hyperion.stats[:dispatch_mode]` exposure. No operator-visible change.
- 2.0.0 turns `Config#validate!` into a hard error for the combos that currently silently work-by-accident. Specifically, any non-tri-state value for `async_io` raises (see A9 — that piece is additive in 1.7). 2.0 doesn't add new unsupported-combo errors beyond what A9 already covers, because every cell in the 4-flag matrix maps cleanly to one of the 5 modes once `async_io` is locked tri-state.

**Migration sketch.** No DSL change. Internal callers of `Server#dispatch` (test suite only) continue to work; method signature unchanged.

---

### A3 — `Hyperion.metrics` / `Hyperion.logger` singletons → `Hyperion::Runtime` constructor injection

**Problem.** `Connection#initialize` caches `Hyperion.metrics` and `Hyperion.logger` in ivars (lines 38-39 in `lib/hyperion/connection.rb`). Long-lived keep-alive connections never see a runtime swap. `ResponseWriter` reads `Hyperion.metrics` directly at every write (lines 80, 108, 126, 128 in `lib/hyperion/response_writer.rb`) so it sometimes notices the swap mid-connection — inconsistent. `Http2Handler` caches at construction. Multi-tenant apps that want different metrics sinks per server instance can't have them: the singleton is process-global.

**Proposed shape.** A value object holds the runtime services. Constructed once at `Server#start`, threaded through.

```ruby
# lib/hyperion/runtime.rb
class Hyperion::Runtime
  attr_reader :metrics, :logger, :clock

  def self.default
    @default ||= new
  end

  def initialize(metrics: nil, logger: nil, clock: Process)
    @metrics = metrics || Hyperion::Metrics.new
    @logger  = logger  || Hyperion::Logger.new
    @clock   = clock
  end
end
```

Constructors take a `runtime:` kwarg defaulted to `Runtime.default`: `Server`, `Connection`, `ResponseWriter`, `Http2Handler`. Each reads `runtime.metrics` / `runtime.logger` instead of the module-level accessors. Module-level `Hyperion.metrics` / `Hyperion.logger` stay as delegators **to `Runtime.default`** for back-compat — including the `=` setter (mutates `Runtime.default`, not all Runtimes).

**Public API impact.** Additive in 1.7 (new `runtime:` kwarg, default keeps current behavior). 2.0 drops `Hyperion.metrics=` / `Hyperion.logger=` setters; `Hyperion.metrics` getter stays as a `Runtime.default` delegator (REPL convenience). `Connection.new`'s `parser:` / `writer:` / `thread_pool:` kwargs unchanged.

**1.x vs 2.0 split.** 1.7 introduces `Runtime` + kwarg defaults. 1.8 deprecation-warns the setters (once per call site). 2.0 drops the setters.

**Migration sketch.** CLI users see no change. Library users:

```ruby
# Before (1.6.x): process-global, racy mid-connection
Hyperion.metrics = StatsdMetricsAdapter.new

# After (1.7+): explicit per-Server
runtime = Hyperion::Runtime.new(metrics: StatsdMetricsAdapter.new, logger: MyLogger.new)
Hyperion::Server.new(app: my_rack_app, runtime: runtime).start
```

---

### A4 — `Config::DEFAULTS` flat 25-field hash → nested config classes

**Problem.** `Config::DEFAULTS` is a flat 25-field hash (lines 12-39 in `lib/hyperion/config.rb`). Field names already telegraph the grouping: `h2_*` (4 fields), `worker_*` (2), `log_*` (3), `admin_*` (1). Operators reading the DSL see no structure. Each new H2 or admin setting accretes another flat prefix.

**Proposed shape.** Four subconfigs as plain Ruby classes; `Config` exposes them as readers; DSL gains nested blocks (Puma/Sidekiq pattern).

```ruby
# lib/hyperion/config/h2_settings.rb
class Hyperion::Config::H2Settings
  ATTRS = %i[max_concurrent_streams initial_window_size max_frame_size
             max_header_list_size max_total_streams].freeze
  attr_accessor(*ATTRS)
  def initialize
    @max_concurrent_streams = 128
    @initial_window_size    = 1_048_576
    @max_frame_size         = 1_048_576
    @max_header_list_size   = 65_536
    @max_total_streams      = nil # see A7
  end
end

# Sibling files, same shape:
#   AdminConfig         (token, listener_port, listener_host) — listener fields see A8
#   WorkerHealthConfig  (max_rss_mb, check_interval)
#   LoggingConfig       (level, format, requests)
```

`Config` retains the flat top-level fields (`host`, `port`, `workers`, `thread_count`, `tls_cert`, `tls_key`, `async_io`, `read_timeout`, `idle_keepalive`, `graceful_timeout`, `max_header_bytes`, `max_body_bytes`, `max_pending`, `max_request_read_seconds`, `fiber_local_shim`, `yjit`) and gains four readers `:h2`, `:admin`, `:worker_health`, `:logging`. The DSL gets a `BlockProxy.new(subconfig).instance_eval(&blk)` shim per subconfig and deprecated flat-name forwarders for the 8 affected DSL methods (`h2_max_concurrent_streams`, `h2_initial_window_size`, `h2_max_frame_size`, `h2_max_header_list_size`, `admin_token`, `worker_max_rss_mb`, `worker_check_interval`, `log_level`, `log_format`, `log_requests`). Forwarders log a one-shot deprecation per `Config.load`.

`Master.build_h2_settings` reads from `config.h2`. CLI flags (`--admin-token`, `--worker-max-rss-mb`, `--log-level`, `--log-format`, `--log-requests`, `--max-body-bytes`, etc.) keep their current spellings and write into the nested subconfig — these are operator-facing, not DSL-facing, and don't need the prefix split.

**Public API impact.** Breaking-with-deprecation. The `attr_accessor`-generated `Config#h2_max_concurrent_streams` etc. are removed in 2.0. The DSL aliases stay through 1.7 with no warns and through 1.8 with deprecation warns; 2.0 removes them. `Config::DEFAULTS` becomes documentation; initialization moves into the subconfig constructors.

**1.x vs 2.0 split.** 1.7: subconfigs + nested DSL blocks; flat keys still work silently. 1.8: deprecation warns on flat keys (once-per-load). 2.0: flat keys removed.

**Migration sketch.**

Before (1.6.x):
```ruby
# config/hyperion.rb
h2_max_concurrent_streams 256
h2_initial_window_size    2_097_152
admin_token               ENV.fetch('HYPERION_ADMIN_TOKEN')
worker_max_rss_mb         1024
log_level                 :info
log_format                :json
log_requests              true
```

After (1.7+):
```ruby
# config/hyperion.rb
h2 do
  max_concurrent_streams 256
  initial_window_size    2_097_152
end
admin do
  token ENV.fetch('HYPERION_ADMIN_TOKEN')
end
worker_health do
  max_rss_mb 1024
end
logging do
  level    :info
  format   :json
  requests true
end
```

CHANGELOG ships a verbatim before/after table for the 8 affected DSL methods.

---

### A5 — `Hyperion::AsyncPg::ActiveRecordAdapter` → Railtie

**Problem.** `Hyperion::AsyncPg::ActiveRecordAdapter.install!` flips `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` (line 105). Process-global, initializer-order-dependent: any AS init that runs after `install!` and re-flips the state silently breaks fiber-based AR pooling. The 0.5.x experience of "you have to remember to call `install!(activerecord: true)` at the right initializer position" is a pure footgun for Rails operators.

**Proposed shape.** Ship a Railtie that auto-installs at `before_configuration` (after Rails.application is created but before `config/application.rb`'s body runs and before AS initializers run). Non-Rails callers keep the current `install!(activerecord: true)` API for one minor.

```ruby
# lib/hyperion/async_pg/railtie.rb
require 'rails/railtie'

class Hyperion::AsyncPg::Railtie < ::Rails::Railtie
  config.before_configuration do
    Hyperion::AsyncPg::ActiveRecordAdapter.install! if Hyperion::AsyncPg::Railtie.auto_install?
  end

  def self.auto_install?
    case ENV['HYPERION_ASYNC_PG_AUTOINSTALL']
    when '0', 'false', 'off', 'no' then false
    else true
    end
  end
end
```

`hyperion-async-pg.rb` requires the Railtie when `Rails::Railtie` is defined. The PG monkey-patch (`Patches.new(methods)` prepended onto `PG::Connection`) stays in `Hyperion::AsyncPg.install!`, separate from the AR flip — Sequel/ROM users want the patch without the AR isolation change.

**Decision (open in section 5): always-on with env-var opt-out** (`HYPERION_ASYNC_PG_AUTOINSTALL=0`). Operators wanting PG patches + ForkSafe but not AR flip set the env var. Strong-opinion operators already have `gem 'hyperion-async-pg', require: false`.

**Public API impact.** Additive in async-pg 0.6.0; `install!(activerecord: true)` stays valid (idempotency guard handles re-entry against the Railtie). Async-pg 1.0 deprecates the kwarg; 1.1 removes it.

**Migration sketch.**

```ruby
# Before (async-pg 0.5.1): explicit initializer
Hyperion::AsyncPg.install!(activerecord: true, fork_safe: true)

# After (0.6.0+): Gemfile alone is enough for AR; PG/ForkSafe still explicit
require 'hyperion/async_pg'
Hyperion::AsyncPg.install!(fork_safe: true) # AR auto-installed by Railtie
```

Opt out of auto-AR flip via `HYPERION_ASYNC_PG_AUTOINSTALL=0`.

---

### A6 — Multi-fiber accept per worker

**Problem.** `Server#accept_or_nil` (line 269 in `lib/hyperion/server.rb`) runs one `IO.select` on the listening fd. At very high accept rates (~25–50 k accept/s/worker on Linux) the single accept loop becomes the bottleneck. This isn't a current production bottleneck — GVL contention and PG-pool ceilings hit first on real Rails — but it's a future scalability ceiling we should give operators a knob for.

**Proposed shape.** Under `:reuseport` worker model, spawn N "accept fibers" that each `IO.select` on the same listening fd. Kernel hashes connections across siblings — same mechanism Hyperion uses across worker processes, applied within one worker across fibers.

`:share` mode (macOS/BSD) keeps a single accept fiber: shared FDs across fibers don't get the same kernel-side balancing, and Darwin's `SO_REUSEPORT` is known to misbehave (see master.rb commentary).

Per-connection writer fiber (1.6.0) is orthogonal: writer fibers are per-connection; accept fibers are per-listener. Topology: `accept-fiber-N → dispatch → per-conn-fiber → (writer-fiber for h2)`.

```ruby
# lib/hyperion/server.rb
def start_async_loop
  Async do |task|
    n = accept_fibers_per_worker
    n.times { task.async { run_accept_fiber(task) } }
    task.children.each(&:wait)
  end
end

def run_accept_fiber(task)
  until @stopped
    socket = accept_or_nil
    next unless socket
    apply_timeout(socket)
    task.async { dispatch(socket) }
  end
end
```

`Config` adds top-level `accept_fibers_per_worker` (Integer, default 1). Documented as "leave at 1 unless you've measured an accept-rate ceiling." `start_raw_loop` (plain h1, no async wrap) silently caps at 1 — no scheduler means no fiber concurrency to gain. Documented; no boot-time error.

**Public API impact.** Additive. New `accept_fibers_per_worker` field (default 1). New `Hyperion.stats[:accept_fibers]` reading.

**1.x vs 2.0 split.** 1.7 ships impl with default 1. 2.0 keeps default 1 — flipping needs a bench showing it pays off on Hyperion-shaped workloads, which we don't have yet.

**Migration sketch.** None for default users. Opt-in via DSL `accept_fibers_per_worker 4` or CLI `--accept-fibers 4`.

---

### A7 — HTTP/2 admission control (per-process stream cap)

**Problem.** `h2_max_concurrent_streams` (default 128) caps streams **per connection**. An abuser opens 5,000 connections × 128 streams = 640 k fibers → OOM → master respawns → abuser reconnects. The 1.6.0 backpressure change capped per-connection bytes-in-queue (16 MiB) but doesn't bound connection count or cross-connection stream count. Real DoS vector, no built-in defense.

**Proposed shape.** A process-wide atomic counter with a soft cap. Above the cap, new streams get `RST_STREAM REFUSED_STREAM` (RFC 7540 §11 / RFC 9113 §5.4.1).

```ruby
# lib/hyperion/h2_admission.rb
class Hyperion::H2Admission
  def initialize(max_total_streams:)
    @max = max_total_streams; @count = 0; @rejected = 0
    @mutex = Mutex.new
  end

  # O(1), short critical section. Per-process counter.
  def admit
    return true if @max.nil?
    @mutex.synchronize do
      if @count >= @max then @rejected += 1; false
      else @count += 1; true
      end
    end
  end

  def release
    return if @max.nil?
    @mutex.synchronize { @count -= 1 if @count.positive? }
  end

  def stats
    @mutex.synchronize { { in_flight: @count, rejected: @rejected, max: @max } }
  end
end
```

Held on `Server`, shared across all `Http2Handler` instances within a worker. Acquired in `Http2Handler#dispatch_stream` before existing dispatch; released in the `ensure`. Bumps `:h2_streams_refused` metric.

Default cap formula: `h2.max_concurrent_streams × workers × 4`. Operator override: `config.h2.max_total_streams`. `nil` = no cap (current behavior). The 4× multiplier is comfortable headroom assuming average connection holds 25% of the per-conn cap — well clear of legitimate multi-tenant fan-out.

`GOAWAY ENHANCE_YOUR_CALM` (per-connection escalation when one connection accumulates more than K refused streams in a window) is a 2.x follow-up — needs production signal on real abuse patterns first.

**Public API impact.** Additive. New `Config#h2.max_total_streams` field. New `:h2_streams_refused` counter.

**1.x vs 2.0 split.** 1.7 ships the impl with default `nil` (no cap). 2.0 flips default to `h2.max_concurrent_streams × workers × 4`. Justification: the `nil` default has no bench upside (it exists only because we hadn't built admission control); the new default headroom doesn't trip any realistic legitimate workload; the abuse path (640 k fiber OOM) is a real risk every Hyperion+H2 deploy carries today. This is the only 2.0 default flip; everything else is opt-in.

**Migration sketch.** 1.7 explicit opt-in (`h2 do; max_total_streams 16_384; end`); 2.0 default ON. To restore 1.x unbounded: `h2 do; max_total_streams nil; end`.

---

### A8 — `AdminMiddleware` sibling listener

**Problem.** `/-/quit` and `/-/metrics` mount INSIDE the Rack app via `AdminMiddleware`. Three real-world failure modes:

1. **Misordered `Rack::Builder` middleware** can disable admin (an app `use`s a custom 404 middleware before Hyperion's admin wrapper).
2. **Request-headers-logging middleware** (`Rack::CommonLogger` derivatives, OpenTelemetry HTTP instrumentation, app-level header dumpers) logs the bearer token to access logs.
3. **Operators must manually 404 the path at the edge proxy.** `docs/REVERSE_PROXY.md` exists for exactly this — it's a known footgun.

**Proposed shape.** Optional sibling listener bound to localhost on a separate port. `Config#admin.listener_port` (default `nil` = mounted-in-app, current behavior). When set, Hyperion spawns a small dedicated HTTP server (single accept thread, no Rack pipeline) that handles only `/-/quit` and `/-/metrics`.

```ruby
# lib/hyperion/admin_listener.rb
class Hyperion::AdminListener
  def initialize(host:, port:, token:, runtime:, signal_target:)
    @host, @port, @token, @runtime, @signal_target = host, port, token, runtime, signal_target
  end

  def start
    tcp = TCPServer.new(@host, @port)
    Thread.new do
      loop do
        client = tcp.accept
        handle(client) # parse request line + Authorization, dispatch /-/quit or /-/metrics
      rescue StandardError => e
        @runtime.logger.warn { { message: 'admin listener error', error: e.message } }
      end
    end
  end
end
```

**Where it runs.** In the master, before fork. `/-/quit` already signals the master (`Process.kill('TERM', ppid)` from worker today); running the listener in master means `signal_target == Process.pid`, no cross-process plumbing. Master is single-process so no port conflict; master is largely idle so the extra accept thread doesn't compete with worker accept loops. Trade-off: master holds a listening port — operators with port-sandboxing need to allow it. Documented.

**Token handling.** Same `secure_match?` from `AdminMiddleware`. The single biggest win: the listener never sees the bearer header in the request-logging path that the app itself runs through, so the header-leak vector goes away.

**Public API impact.** Additive. New `admin.listener_port` (default `nil` = mount-in-app), `admin.listener_host` (default `127.0.0.1`).

**1.x vs 2.0 split.** 1.7 ships sibling-listener; default stays mount-in-app. 2.0 keeps the default mount-in-app; no port flip — there's no obvious "free port" to pick (conflicts with whoever already binds 9293), and the right default is "explicit opt-in once the operator decides." Recommended pattern documented in `docs/REVERSE_PROXY.md`.

**Migration sketch.** Migrate from in-app: `admin do; token ENV['T']; listener_port 9293; end`. Endpoints move from `:9292/-/*` to `127.0.0.1:9293/-/*`; app port no longer responds to `/-/*`. Edge proxy can drop the `/-/*` block.

---

### A9 — Tri-state `async_io` validation

**Problem.** `async_io: nil/true/false` is documented as a 3-state value. The Server constructor accepts any object. `1` lands in the auto branch (because `@async_io == true` is strict equality, line 238 in server.rb), `:yes` likewise — silently. Operator types `async_io 'true'` in the DSL → string lands in the "explicit pool" branch.

**Proposed shape.** `Config#async_io=` validates at assignment.

```ruby
class Hyperion::Config
  ALLOWED_ASYNC_IO = [nil, true, false].freeze

  def async_io=(value)
    return @async_io = value if ALLOWED_ASYNC_IO.include?(value)
    raise ArgumentError, "async_io must be nil, true, or false (got #{value.inspect})"
  end
end
```

`Server#initialize` adds the same guard for callers who construct Server directly bypassing Config.

**Public API impact.** Additive in 1.7. Breaking-clean-cut for the tiny set of operators who pass `1`, `'true'`, `:yes` etc. — but those operators are silently broken today anyway, so the raise is strictly more helpful.

**1.x vs 2.0 split.** All in 1.7.0. No 2.0 follow-up needed.

**Migration sketch.** None for correct users. Operators with bad input get a boot-time `ArgumentError` pointing at the line:
```
ArgumentError: async_io must be nil, true, or false (got "true")
```

---

## 3. Release order

### 1.6.3 — hotfix only
Already-scoped C1 / A1 / S1 / S2 / C2 hotfixes from the audit. **No RFC items.** 1.6.3 must be revertable without entangling architectural changes.

### 1.7.0 — first wave of additive RFC ships

- New `runtime:` kwarg on `Server`, `Connection`, `ResponseWriter`, `Http2Handler` (default `Runtime.default`).
- New nested config DSL blocks (`h2`, `admin`, `worker_health`, `logging`); flat keys still work.
- New `accept_fibers_per_worker`, `h2.max_total_streams`, `admin.listener_port` (all default to current behavior).
- `async_io` validates input strictly; `1`, `'true'`, `:yes` raise.
- Internal: `DispatchMode` value object; per-mode dispatch counters in `Hyperion.stats`.

### 1.8.0 — deprecation wave

- Deprecation warns at boot for flat-name DSL methods (8 total) and `Hyperion.metrics=` / `Hyperion.logger=` setters. Once-per-load, not once-per-call.
- `hyperion-async-pg 0.6.0` ships the Railtie; `install!(activerecord: true)` warns if Railtie already auto-installed.
- No behavior changes.

### 2.0.0 — breaking removals + default flip

- Removed: 8 flat-named Config setters → use nested DSL.
- Removed: `Hyperion.metrics=` / `Hyperion.logger=` setters → use `Runtime`.
- Default flip: `h2.max_total_streams = h2.max_concurrent_streams × workers × 4`. Operators wanting unbounded set `nil`.
- `Connection` reads metrics/logger from `runtime` only.
- `hyperion-async-pg 1.0`: Railtie is the canonical install. `install!(activerecord: true)` deprecated, removed in 1.1.

---

## 4. Migration guide skeleton (1.x → 2.0)

### 4.1 Config DSL

| Before (1.6.x) | After (2.0) |
|---|---|
| `h2_max_concurrent_streams 256` | `h2 do; max_concurrent_streams 256; end` |
| `h2_initial_window_size 2_097_152` | `h2 do; initial_window_size 2_097_152; end` |
| `h2_max_frame_size 1_048_576` | `h2 do; max_frame_size 1_048_576; end` |
| `h2_max_header_list_size 65_536` | `h2 do; max_header_list_size 65_536; end` |
| `admin_token ENV['T']` | `admin do; token ENV['T']; end` |
| `worker_max_rss_mb 1024` | `worker_health do; max_rss_mb 1024; end` |
| `worker_check_interval 30` | `worker_health do; check_interval 30; end` |
| `log_level :info` | `logging do; level :info; end` |
| `log_format :json` | `logging do; format :json; end` |
| `log_requests true` | `logging do; requests true; end` |

CLI flags (`--admin-token`, `--worker-max-rss-mb`, `--log-level`, `--log-format`, `--log-requests`, `--max-body-bytes`, etc.) **do not change in 2.0.** They keep their flat operator-facing names.

### 4.2 Public API calls

| Before (1.6.x) | After (2.0) |
|---|---|
| `Hyperion.metrics = MyMetricsAdapter.new` | `runtime = Hyperion::Runtime.new(metrics: MyMetricsAdapter.new); Hyperion::Server.new(app:, runtime:)` |
| `Hyperion.logger = MyLogger.new` | same — pass via `Runtime` |
| `Hyperion::Server.new(...)` | unchanged signature except `runtime:` kwarg added |
| `Hyperion::Connection.new(parser:, writer:, thread_pool:)` | add `runtime:` kwarg; metrics/logger no longer reachable through globals from inside |
| `Hyperion::AsyncPg.install!(activerecord: true)` | remove — Railtie auto-installs. Or keep with deprecation warn for one minor. |
| `async_io: 1` (silently coerced today) | raises `ArgumentError` at config-load time |

### 4.3 Runtime behavior changes

- **H2 admission cap is on by default.** If you are running an h2-heavy multi-tenant edge with extreme stream fan-out (>`max_concurrent_streams × workers × 4` simultaneous streams), explicitly set `h2 do; max_total_streams nil; end` to restore 1.x behavior. Otherwise no action needed; the default headroom covers all realistic workloads.
- **Admin endpoints stay mounted in-app by default** (no behavior change). To migrate to the sibling-listener pattern, set `admin do; listener_port 9293; end` and update edge-proxy rules.
- **Per-server runtime swaps work.** `Hyperion.metrics =` only mutated `Runtime.default`; constructed `Server`s with explicit `runtime:` are isolated.

---

## 5. Open questions

Maintainer signoff needed before locking.

1. **`log_requests=` semantics (audit-original).** Current `Hyperion.log_requests=` is process-global, evaluated lazily on first read, env-fallback driven. Under A3's Runtime model, where does it live? **Recommendation:** move to `LoggingConfig` (`config.logging.requests`), exposed via `runtime.logger.requests?`. Env fallback `HYPERION_LOG_REQUESTS` stays in the CLI bootstrap path.

2. **`AdminMiddleware` in-app vs sibling default (audit-original, A8).** **Recommendation:** keep in-app as the 2.0 default; docs/CHANGELOG nudge operators toward the sibling pattern. No "first available port" picker — too much default-config magic for a port that should be explicit.

3. **`--async-io` + `thread_count: 0` traffic (audit-original).** DispatchMode resolves it to `:inline_h1_no_pool`. **Recommendation:** keep it valid. It's a useful debug/test config — `bundle exec hyperion -t 0` is the simplest way to reproduce a bug without the thread pool muddying the trace.

4. **`Hyperion::Runtime.default` mutability scope.** Should `Runtime.default` freeze after first read? **Recommendation:** NO. Tests need to swap it; freezing for no real safety benefit creates a thaw/refreeze ceremony.

5. **Multi-fiber accept on `:share` mode (A6).** Should Darwin honor `accept_fibers_per_worker > 1` even though it likely won't scale? **Recommendation:** silently honor the knob; document that Darwin shows no scaling benefit. Operators already know Darwin is special.

6. **Railtie hook point (A5).** `before_configuration` vs `to_prepare`? **Recommendation:** `before_configuration`. Cheaper (no per-reload cost in dev), idempotent guard catches re-entry, fires before AR::Base first loads.

7. **`Hyperion.stats[:dispatch_mode]` shape (new, A2).** Single latest value or per-mode counters? **Recommendation:** per-mode counters. New keys `:requests_dispatch_tls_h2`, `:requests_dispatch_tls_h1_inline`, etc. — existing `:requests_async_dispatched` / `:requests_threadpool_dispatched` retire (collapsed).

---

## 6. Out of scope for 2.0

Belongs in 2.x or 3.0:

- **Hello-world / h2 frame-writer perf squeeze.** 1.6.0 C-ext additions + writer-fiber architecture hit the headline numbers. Further microbenching not worth the C-ext maintenance cost in 2.0.
- **Falcon-class h2 multiplexing improvements.** Smaller mutex, smarter scheduling, per-stream priority frames (RFC 7540 §5.3). Real-world client impact is small; defer.
- **HTTP/3 (QUIC) support.** Runtime-level rewrite.
- **JRuby / TruffleRuby first-class support.** Pure-Ruby parser path stays correct; perf work for non-MRI is its own track.
- **Streaming request bodies (full duplex).** `Connection#read_request` buffers full body today. Phase-5 placeholder note in code; not a 2.0 commitment.
- **kTLS / OpenSSL 4.x sendfile-with-encrypt.** Kernel-version-gated.
- **WebSocket framing.** Not supported, no plans for 2.0.
- **Admin endpoints beyond drain + metrics** (`/-/reload`, `/-/config`). The admin port's single use case is metrics + drain.
- **Multi-host listener config.** Run multiple Hyperion processes for multi-listener needs.

---

End of RFC.
