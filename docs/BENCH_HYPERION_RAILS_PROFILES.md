# Hyperion vs Agoo profile data — pre-tuning baseline

Captured 2026-05-05 on `openclaw-vm` (Linux 6.8 / Ubuntu 24.04 / x86_64 KVM /
Ruby 3.3.3 + YJIT / Hyperion 2.16.2).
Workload: `bench/hello.ru`, `wrk -t4 -c100 -d30s`. Both servers single-worker (1w × 5t).

Throughput at capture time:
- Hyperion: **4,207 req/s** (wrk during perf record run)
- Agoo:    **14,677 req/s** (wrk during perf record run)
- Gap:     **3.49×** (consistent with Task 21 pre-tuning matrix result of 3.9–4.3×)

## Hyperion stackprof (Ruby CPU mode)

Sampled at 1 ms over 30 s of `wrk -t4 -c100` against `bench/profile_hello.rb`.
Total: 26,932 CPU samples, 1.41% miss rate, GC 0.89%.

```
==================================
  Mode: cpu(1000)
  Samples: 26932 (1.41% miss rate)
  GC: 239 (0.89%)
==================================
     TOTAL    (pct)     SAMPLES    (pct)     FRAME
      8853  (32.9%)        8853  (32.9%)     IO#write
      1115   (4.1%)        1115   (4.1%)     Time#strftime
      1076   (4.0%)        1076   (4.0%)     BasicSocket#__read_nonblock
      1196   (4.4%)         849   (3.2%)     Hyperion::CParser#parse
     26573  (98.7%)         824   (3.1%)     Hyperion::Connection#serve
      2174   (8.1%)         786   (2.9%)     Hyperion::Adapter::Rack.build_env
       841   (3.1%)         533   (2.0%)     Hyperion::Metrics#increment
     10538  (39.1%)         475   (1.8%)     Hyperion::ResponseWriter#write_buffered
       555   (2.1%)         455   (1.7%)     Hyperion::Metrics#increment_status
      2732  (10.1%)         452   (1.7%)     Hyperion::Connection#read_request
       918   (3.4%)         444   (1.6%)     Hyperion::Metrics#observe_histogram
       635   (2.4%)         403   (1.5%)     Hyperion::Metrics::PathTemplater#template
       444   (1.6%)         391   (1.5%)     Hyperion::Metrics#increment_labeled_counter
       390   (1.4%)         390   (1.4%)     Thread#thread_variable_get
       379   (1.4%)         379   (1.4%)     Hyperion::CParser.build_access_line
      3332  (12.4%)         362   (1.3%)     Hyperion::Adapter::Rack.call
       477   (1.8%)         350   (1.3%)     Class#new
       336   (1.2%)         336   (1.2%)     Process.clock_gettime
       335   (1.2%)         335   (1.2%)     Kernel#respond_to?
      1967   (7.3%)         286   (1.1%)     Hyperion::Logger#cached_timestamp
      1413   (5.2%)         280   (1.0%)     Time#xmlschema
       263   (1.0%)         263   (1.0%)     Hyperion::CParser.build_env
      3019  (11.2%)         254   (0.9%)     Hyperion::Logger#access
       232   (0.9%)         232   (0.9%)     Hyperion::CParser.build_response_head
       230   (0.9%)         230   (0.9%)     String#byteslice
       226   (0.8%)         222   (0.8%)     Hyperion::Metrics::HistogramAccumulator#observe
       191   (0.7%)         191   (0.7%)     Kernel#lambda
       188   (0.7%)         188   (0.7%)     #<Object:0x0000789676ffe468>.fetch
       186   (0.7%)         186   (0.7%)     String#include?
       182   (0.7%)         182   (0.7%)     (sweeping)
```

## Hyperion perf report (native frames)

`sudo perf record -F 99 -g -p <hyperion-pid> -- sleep 35`, 2,847 samples on `task-clock:ppp`.
Note: YJIT-compiled Ruby frames appear as `vm_exec_core`; individual Ruby methods are not
resolved at the native level without frame-pointer unwinding of JIT code.

```
# Overhead  Shared Object             Symbol
#
    13.73%  libruby.so.3.3.3      [.] vm_exec_core
    12.75%  [kernel.kallsyms]     [k] _raw_spin_unlock_irqrestore
             |--7.59%--try_to_wake_up (futex wakeup from ThreadPool dispatch)
              --4.99%--__wake_up_sync_key
     1.79%  libruby.so.3.3.3      [.] vm_call_cfunc_with_frame
     1.65%  [kernel.kallsyms]     [k] finish_task_switch.isra.0
     1.40%  libruby.so.3.3.3      [.] rb_vm_opt_getconstant_path
     1.33%  [kernel.kallsyms]     [k] do_syscall_64
     1.16%  libruby.so.3.3.3      [.] rb_class_of
     0.91%  libruby.so.3.3.3      [.] rb_st_lookup
     0.81%  libruby.so.3.3.3      [.] BSD_vfprintf.constprop.0
     0.81%  libruby.so.3.3.3      [.] rb_id_table_lookup
     0.77%  libruby.so.3.3.3      [.] newobj_alloc
     0.77%  libruby.so.3.3.3      [.] rb_gc_obj_slot_size
     0.70%  libc.so.6             [.] malloc (via objspace_xmalloc0)
     0.67%  hyperion_http.so      [.] llhttp__internal__run
     0.63%  libruby.so.3.3.3      [.] callable_method_entry_or_negative
     0.63%  libruby.so.3.3.3      [.] vm_call_iseq_setup_normal_0start_0params_0locals
     0.60%  libruby.so.3.3.3      [.] rb_hash_aref
     0.56%  libruby.so.3.3.3      [.] rb_obj_class
     0.56%  libruby.so.3.3.3      [.] ruby_sip_hash13
     0.56%  libruby.so.3.3.3      [.] vm_call_iseq_setup_normal_opt_start
     0.49%  libc.so.6             [.] pthread_cond_wait
     0.46%  [kernel.kallsyms]     [k] futex_wake
     0.46%  ld-linux-x86-64.so.2  [.] __tls_get_addr
     0.46%  libc.so.6             [.] getenv
     0.46%  libc.so.6             [.] malloc_usable_size
     0.46%  libc.so.6             [.] recv
     0.46%  libruby.so.3.3.3      [.] vm_call_iseq_setup_normal_0start
     0.42%  libc.so.6             [.] pthread_cond_signal
```

## Agoo perf report (native frames)

`sudo perf record -F 99 -g -p <agoo-pid> -- sleep 35`, 4,862 samples (note: Agoo served 3.5×
more requests in the same window, so its samples reflect a more evenly-spread profile).

```
# Overhead  Shared Object             Symbol
#
    14.77%  [kernel.kallsyms]     [k] _raw_spin_unlock_irqrestore
             |--8.60%--__wake_up_sync_key
             |          |--6.09%--sock_def_readable
             |          |           --6.07%--tcp_rcv_established
             |           --2.51%--pipe_write (internal queue notification)
             |                      --2.06%--handle_rack_inner.cold
              --5.45%--try_to_wake_up
                         --5.43%--pthread_cond_signal
     4.15%  [kernel.kallsyms]     [k] do_syscall_64
              |--0.68%--epoll_ctl
               --0.58%--open64
     3.62%  [kernel.kallsyms]     [k] finish_task_switch.isra.0
              |--2.22%--futex_wait_queue
              |--0.70%--do_nanosleep
               --0.70%--schedule_hrtimeout_range_clock (agoo_ready_go)
     2.20%  libc.so.6             [.] pthread_mutex_lock
              --1.21%--agoo_con_http_events
     1.97%  libruby.so.3.3.3      [.] find_table_bin_ind
     1.77%  agoo.so               [.] con_ready_io
     1.58%  libc.so.6             [.] pthread_mutex_unlock
              --0.99%--agoo_con_http_events
     1.09%  libruby.so.3.3.3      [.] ruby_sip_hash13
     1.05%  [kernel.kallsyms]     [k] __fdget
     0.93%  [kernel.kallsyms]     [k] __fdget_pos
              --0.66%--ksys_write (handle_rack_inner.cold)
     0.90%  agoo.so               [.] request_env
     0.90%  libruby.so.3.3.3      [.] fstring_cmp
     0.88%  libc.so.6             [.] write
              --0.58%--handle_rack_inner.cold
     0.86%  libruby.so.3.3.3      [.] newobj_alloc
     0.84%  libc.so.6             [.] malloc
     0.76%  libc.so.6             [.] cfree
     0.76%  libc.so.6             [.] epoll_ctl
     0.76%  libc.so.6             [.] read
              --0.74%--agoo_queue_release
     0.74%  libc.so.6             [.] open64
              --0.70%--_IO_file_open
     0.70%  [kernel.kallsyms]     [k] mutex_lock
     0.66%  [kernel.kallsyms]     [k] apparmor_file_permission
```

## Diff observations

### 1. `IO#write` dominates Hyperion at 32.9% — Agoo has no equivalent frame

The single biggest frame in Hyperion's stackprof is `IO#write` with 32.9% of all CPU samples.
The full logger subtree (`IO#write` + `Time#strftime` 4.1% + `Time#xmlschema` 5.2% total +
`Hyperion::Logger#cached_timestamp` 7.3% total + `Hyperion::CParser.build_access_line` 1.4%
+ `Hyperion::Logger#access` 11.2%) accounts for roughly **40%** of request-path CPU.

Agoo's perf report shows `write` at only 0.88% and `handle_rack_inner.cold` as the write
callsite — a thin C path. Agoo also does not emit a structured access log by default on
`bench/hello.ru` (it's off unless configured). Hyperion enables `log_requests: true` by
default and emits a JSON line per request even in the benchmark, paying the full
`IO#write` cost every time.

**Candidate fix (Task 25):** Gate access logging behind a flag that defaults to OFF when
`HYPERION_LOG_LEVEL=warn` or higher, or add a `--no-log-requests` flag and make the bench
boot harness use it. Alternatively, switch from per-request `IO#write` to a background
thread that drains a lock-free ring buffer, making the hot path a single atomic pointer
push. Expected gain: reclaiming ~30% of CPU => potential 35-45% throughput improvement.

### 2. Metrics overhead (13.2% combined) has no counterpart in Agoo's profile

Hyperion's stackprof shows `Hyperion::Metrics#increment` (2.0%), `Hyperion::Metrics#increment_status`
(1.7%), `Hyperion::Metrics#observe_histogram` (1.6%), `Hyperion::Metrics::PathTemplater#template`
(1.5%), `Hyperion::Metrics#increment_labeled_counter` (1.5%) — totalling **~8.3%** in self
time, and 13.2% when counting full subtrees. Thread contention accounts for additional
overhead: `Thread#thread_variable_get` at 1.4% is driven by per-thread slot lookup inside
the metrics counters.

Agoo's perf report contains no metrics-equivalent frame. `find_table_bin_ind` (1.97% in
Agoo) is Ruby hash lookup for the Rack env, not metrics. Agoo exposes no built-in
Prometheus-style metrics.

**Candidate fix (Task 26):** Make `observe_histogram` and `increment_labeled_counter` lazier
— skip `PathTemplater#template` when the path matches a cached bucket, or use a pre-built
label-string cache keyed by `(path_template, status)` pair. Alternatively, evaluate
disabling Prometheus metrics via `HYPERION_METRICS=off` in the bench harness to isolate
the delta. Expected gain: 8-12% CPU recovery.

### 3. ThreadPool futex contention (12.75% kernel) vs Agoo's epoll-native dispatch

Hyperion's perf report shows `_raw_spin_unlock_irqrestore` at 12.75% (second-largest
native symbol), with 7.59% tracing to `try_to_wake_up` — i.e., futex-based thread wakeup
from `ThreadPool` dispatch. Each request that goes through `ThreadPool` triggers a mutex
lock + condvar signal to wake a handler thread.

Agoo's profile shows the same `_raw_spin_unlock_irqrestore` at 14.77%, but the dominant
callsite is `sock_def_readable` → `tcp_rcv_established` (6.09%), meaning the wakeup is
driven by kernel network event delivery (epoll/socket ready), not by Ruby-to-Ruby thread
handoff. Agoo's C worker threads block directly on the connection queue with low-overhead
`pthread_cond_wait`; there is no Ruby-layer dispatch handoff.

Hyperion at `-w 1 -t 5` uses 5 OS threads dispatched through `ThreadPool`, each requiring
a Ruby mutex + condvar cycle per request. The 1.65% `finish_task_switch` in Hyperion vs
3.62% in Agoo is misleading — Agoo handled 3.5× more requests, so its per-request context
switch cost is actually much lower proportionally.

**Candidate fix (Task 27):** For single-worker mode on Linux, evaluate an inline-dispatch
path that skips the `ThreadPool` hand-off for short responses (i.e., if the response fits
in the write buffer and the Rack app returns synchronously, write inline without waking
another thread). This is most impactful for the `bench/hello.ru` minimal-response case.
Expected gain: 5-10% on the bench/hello.ru row; smaller effect on realistic Rails rows.

## Driving Tasks 25-27

Each tuning PR picks one finding above, implements the fix, and is gated on `>=+5%` on
`bench/run_all.sh --row 4` (the `bench/hello.ru` single-worker row) median across 3 trials.

Priority order:
1. **Task 25** — Suppress access-log `IO#write` in bench / add async log drain (32.9% win)
2. **Task 26** — Cache metrics label strings to eliminate `PathTemplater#template` per request (8-12% win)
3. **Task 27** — Inline dispatch for short synchronous responses in single-worker mode (5-10% win)
