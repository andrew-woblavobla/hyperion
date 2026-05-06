# io_uring hot path (Hyperion 2.18+)

Per-request io_uring on Linux 5.19+ — multishot accept + multishot
recv with kernel-managed buffer rings (`IORING_REGISTER_PBUF_RING`)
+ send SQEs paired with the C-side `Hyperion::Http::ResponseWriter`.
Independent gate from the existing accept-only `io_uring:` policy
(2.3-A). Default off; opt-in only after operator validation.

## When to enable

| Environment | Recommendation |
|---|---|
| Linux 5.19+, no shared-CGroup quota pressure | `--io-uring-hotpath auto` |
| Linux 5.19+ in containers without io_uring whitelisting | leave off (kernel returns -EPERM at boot) |
| Linux <5.19 | not available; supported probe returns false |
| macOS / BSD | not applicable |

## Enable

```sh
# CLI
bundle exec hyperion --io-uring-hotpath on config.ru

# Env
HYPERION_IO_URING_HOTPATH=on bundle exec hyperion config.ru

# DSL (config/hyperion.rb)
io_uring_hotpath :auto
```

Independent of the accept-only gate. Both can be set:

```sh
HYPERION_IO_URING_ACCEPT=1 HYPERION_IO_URING_HOTPATH=on bundle exec hyperion config.ru
```

## Buffer-ring tuning

| Env var | Default | Notes |
|---|---|---|
| `HYPERION_IO_URING_HOTPATH_BUFS` | 512 | Number of kernel-managed receive buffers per worker. Must be a power of two (PBUF_RING constraint). |
| `HYPERION_IO_URING_HOTPATH_BUF_SIZE` | 8192 | Bytes per buffer. Requests larger than this size will span multiple recv CQEs. |

Total pinned memory per worker = `BUFS * BUF_SIZE` (default 4 MiB).

## Observability

Counters (in addition to existing accept-only ones):

- `:io_uring_recv_enobufs` — recv CQE returned ENOBUFS (buffer ring exhausted). A sustained spike indicates the buffer pool is too small; raise `HYPERION_IO_URING_HOTPATH_BUFS`.
- `:io_uring_send_short` — send CQE returned fewer bytes than submitted (follow-up SQE issued automatically).
- `:io_uring_hotpath_fallback_engaged` — per-worker fallback to accept4 + read_nonblock + write(2). Non-zero means a worker's ring went unhealthy; see Fallback model below.
- `:io_uring_release_double` — defensive counter; should always be 0. Non-zero indicates a double-release bug in the Ruby recv path.
- `:io_uring_unexpected_errno` — defensive counter; should always be 0.

All counters appear in `/-/metrics` (Prometheus-compatible text format) when the admin endpoint is configured.

## Fallback model

Per-worker, not per-process. If a worker's ring becomes unhealthy
(sustained SQE submit failures, repeated EBADR), that worker degrades
to the existing accept4 + read_nonblock + write(2) path. Other workers
keep running on the hotpath. The master process is unaware. Operators
see a single warn-level log line:

```
{"message":"io_uring hotpath ring unhealthy; engaging accept4 fallback per-worker","worker_pid":12345}
```

plus an increment on `:io_uring_hotpath_fallback_engaged`.

## Default-flip schedule

Non-binding; revisit after one minor release of soak.

| Version | Default |
|---|---|
| 2.18 | `:off` |
| 2.19 | `:auto` (planned, after one minor of soak) |
| 2.20+ | `:on` (planned) |

## Rollback

- Operator: unset `HYPERION_IO_URING_HOTPATH` (or set to `off`). Default off was the design.
- Hard rollback: revert the gem version; the existing accept-only `HYPERION_IO_URING_ACCEPT` path is unaffected by the hotpath gate.
