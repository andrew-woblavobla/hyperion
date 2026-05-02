# Operator guidance

> See [README.md](../README.md) for the headline overview.

Distilled from [BENCH_2026_04_27.md](BENCH_2026_04_27.md) (Rails 8.1
real-app sweep). Headline finding: **the simplest drop-in is the
right answer.** Most "tune knob X for +Y%" wisdom from synthetic
benches doesn't transfer to Rails-shaped traffic.

---

## Migrating from Puma

`hyperion -t N -w M` matching your current Puma `-t N:N -w M`. No
other flags. Versus Puma at the same `-t/-w` shape on real Rails
endpoints (Exodus platform sweep, Apr 2026):

- **+9% rps** on lightweight endpoints
- **28× lower p99** on health-style endpoints
- **3.8× lower p99** on PG-touching endpoints

Same RSS, same operator surface — keep all your existing config,
monitoring, deploy scripts. See
[MIGRATING_FROM_PUMA.md](MIGRATING_FROM_PUMA.md) for the full guide.

## Knobs that help on synthetic benches but **not** on real Rails

| Knob | Synthetic | Real Rails | Recommendation |
|---|---|---|---|
| `-t 30` | +5–10% on hello-world | **Hurts** p99 vs `-t 10` (3.51 s vs 148 ms on `/up`) — GVL + middleware Mutex contention | Stay at `-t 10`. |
| `--yjit` | +5–10% on CPU-bound | Wash on dev-mode Rails | Skip until you bench production-mode. |
| `RAILS_POOL > 25` | n/a | No improvement at 50 or 100 | Keep your existing AR pool. |
| `--async-io` | 33–42× rps on PG-bound | **Worse** than drop-in (4.14 s p99 on `/up`) until your full I/O stack is fiber-cooperative | Don't enable until `redis-rb` → `async-redis`. |

## When `-w N` helps

| Workload | Recommended | Why |
|---|---|---|
| Pure I/O-bound (PG / Redis / external HTTP) | `-w 1` + larger pool | `-w 1 pool=200` = 87 MB / 2,180 r/s vs `-w 4 pool=64` = 224 MB / 1,680 r/s. **2.6× memory, 0.77× rps** if you pick multi-worker on wait-bound. |
| Pure CPU-bound | `-w N` matching CPU count | Bench: `-w 16 -t 5` hits 98,818 r/s on a 16-vCPU box. |
| Mixed (Rails-shaped, ~5 ms CPU + 50 ms wait) | `-w N/2` (half cores) + medium pool | `-w 4 -t 5 pool=128` = 1,740 r/s on `pg_mixed.ru`, no cold-start spike. |

## Read p99 not mean

| Workload | Hyperion rps / p99 | Closest competitor | rps ratio | p99 ratio |
|---|---|---|---:|---:|
| Hello `-w 4` | 21,215 / 1.87 ms | Falcon 24,061 / 9.78 ms | 0.88× | **5.2× lower** |
| CPU JSON `-w 4` | 15,582 / 2.47 ms | Falcon 18,643 / 13.51 ms | 0.84× | **5.5× lower** |
| Static 1 MiB | 1,919 / 4.22 ms | Puma 2,074 / 55 ms | 0.93× | **13× lower** |
| PG-wait `-w 1` pool=200 | 2,180 / 668 ms | Puma 530 + 200 timeouts | **4.1×** | qualitative crush |

Throughput peaks are easy to fake under controlled conditions; tail
latency reflects what your slowest user actually experiences when
the load balancer fans them onto a busy worker.

## Production deploy checklist

1. `--bind 0.0.0.0` and run behind a reverse proxy (nginx / HAProxy /
   ALB). See [REVERSE_PROXY.md](REVERSE_PROXY.md) for the canonical
   nginx config.
2. Set `--admin-token-file /run/hyperion-admin-token` and isolate
   `/-/*` paths in your reverse proxy
   (`location /-/ { return 404; }`).
3. `--worker-max-rss-mb 768` (or whatever fits your container) so a
   leaking gem can't OOM the box.
4. `HYPERION_LOG_FORMAT=json` for structured logs to your aggregator.
5. `HYPERION_ENV=production` (or `RAILS_ENV=production`) so JSON
   logs auto-engage and dev-mode noise stays off.
6. Scrape `/-/metrics` from Prometheus; add the
   [Grafana dashboard](grafana/hyperion-2.4-dashboard.json).
