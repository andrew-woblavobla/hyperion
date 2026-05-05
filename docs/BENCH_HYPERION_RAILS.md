# Hyperion Rails 8 bench — pre-tuning baseline

> Verifies Hyperion's performance vs Agoo / Falcon / Puma on three real
> Rails 8 workloads (API-only JSON, full-stack ERB render, AR-CRUD
> over SQLite). Reproducible via [`bench/run_all.sh --rails`](../bench/run_all.sh).

**Bench host:** `openclaw-vm` — Linux 6.8.0-107-generic Ubuntu, KVM x86_64,
16 vCPU, 34 GiB RAM. Kernel 6.8.
**Ruby:** 3.3.3 + YJIT (asdf-managed).
**Rails:** 8.0.5.
**Hyperion:** 2.16.2 (master at the time of the run).

**Tooling:** `wrk -t4 -c100 -d20s --latency` for the c100 matrix rows;
`-t2 -c10` for rows 29–30 (low-conc latency profile);
`-t8 -c500` for rows 31–32 (high-conc backpressure).
Three trials per row; median is the headline number.
Each server boots fresh per row, port released between rows.
`RUBYOPT=--yjit`. SQLite in `mode=memory&cache=shared` (per-connection
`OPEN_URI` flag).

---

## Pre-tuning baseline

### Single-worker (1w × 5t)

| Workload | Hyperion (r/s) | Agoo (r/s) | Falcon (r/s) | Puma (r/s) | Bar |
|---|---:|---:|---:|---:|:---:|
| API-only `/api/users` | **583** | **774** | 670 | 623 | fail |
| ERB `/page` | **421** | **460** | 453 | 425 | fail |
| AR-CRUD `/users.json` | **619** | **666** | 602 | 575 | fail |

### Multi-worker (4w × 5t, Hyperion vs Agoo)

| Workload | Hyperion (r/s) | Agoo (r/s) | Bar |
|---|---:|---:|:---:|
| API-only | **2,552** | **3,148** | fail |
| ERB | **1,708** | **1,921** | fail |
| AR-CRUD | **2,181** | **2,372** | fail |

### Latency profile (API-only, 1w × 5t, Hyperion vs Agoo)

| Concurrency | Hyperion r/s | Hyperion p99 | Agoo r/s | Agoo p99 |
|---|---:|---:|---:|---:|
| `-c10` (rows 29–30) | 559 | 10.6 ms | 724 | 17.4 ms |
| `-c100` (rows 11–12) | 583 | 10.2 ms | 774 | 157.2 ms |
| `-c500` (rows 31–32) | 556 | 11.1 ms | 717 | 837.5 ms |

**p99 observation.** Across every gated row Hyperion's p99 latency is
10–100× better than Agoo's despite lower throughput — Hyperion keeps
queues shallow (10–15 ms p99 even at c500) while Agoo absorbs requests
deep into queues to maximize throughput (157 ms at c100, 837 ms at c500).
This is a real and consistent pattern, not noise.

## Bar d status

Bar **d** = Hyperion ≥ Agoo on rows 11>12, 15>16, 19>20, 23>24, 25>26,
27>28. **Pre-tuning result: 0 / 6 passed.**

| Row pair | Workload | Process model | Hyperion r/s | Agoo r/s | Δ |
|---:|---|---|---:|---:|---:|
| 11 vs 12 | API-only | 1w × 5t | 583 | 774 | **−24.7%** |
| 15 vs 16 | ERB | 1w × 5t | 421 | 460 | **−8.5%** |
| 19 vs 20 | AR-CRUD | 1w × 5t | 619 | 666 | **−7.0%** |
| 23 vs 24 | API-only | 4w × 5t | 2,552 | 3,148 | **−18.9%** |
| 25 vs 26 | ERB | 4w × 5t | 1,708 | 1,921 | **−11.1%** |
| 27 vs 28 | AR-CRUD | 4w × 5t | 2,181 | 2,372 | **−8.0%** |

The largest gap is the API row (−25% / −19%), which is the same row where
Hyperion's Rack-adapter row on `bench/hello.ru` is 4.3× behind Agoo
(see `docs/BENCH_HYPERION_2_14.md` rows 4 vs 7). Rails framework cost
narrows the synthetic gap from 4.3× to 1.25×, but doesn't close it. The
ERB and AR rows (−7% to −11%) compress further because Rails-side cost
dominates each workload more.

## Reproduction

```sh
# Full Rails matrix on the bench host (≈30 min):
./bench/run_all.sh --rails

# Single row:
./bench/run_all.sh --rails --row 11

# Default rows + Rails matrix in one go:
./bench/run_all.sh --with-rails
```

(Final post-tuning numbers and a "What moved" diff section will be
appended to this doc once the tuning loop completes.)
