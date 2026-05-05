# Plan #3 — AR-CRUD bench → Postgres

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the Rails AR-CRUD bench rows (19-22 / 27-28) from SQLite-mem-shared to Postgres + `hyperion-async-pg` under `--async-io`, so the rows characterize the path Hyperion is actually optimized for. SQLite path retained as a fallback for hosts without PG.

**Architecture:** Config-only change. `bench/rails_app/config/database.yml` gains an ERB branch on `ENV['RAILS_DB']`. Hyperion AR-CRUD rows boot under `--async-io`; comparison servers (Agoo / Falcon / Puma) keep their native concurrency model. The `pg` and `hyperion-async-pg` gems are already in `bench/Gemfile.4way` (see lines 36-37), so no Gemfile edits are required. Re-run `--rails` on `openclaw-vm`, capture new "Bar d" status.

**Tech Stack:** Rails 8 / `active_record` (PG adapter), `pg ~> 1.5`, `hyperion-async-pg ~> 0.5`, `bash` (bench driver), `postgresql-15+` on the bench host.

**Spec reference:** `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` § "#3 — AR-CRUD bench → Postgres".

**Worktree:** Run on `openclaw-vm`. The AR-CRUD bench rows live at `bench/rails_ar.ru` and exercise `/users.json` → `UsersController#index_db` → `User.limit(10).as_json`.

---

## File map

| Path | Status | Responsibility |
|---|---|---|
| `bench/rails_app/config/database.yml` | Modify | ERB branch on `RAILS_DB` selecting sqlite (default) or pg adapter. |
| `bench/rails_app/config/application.rb` | Modify | The `after_initialize` seeder (lines 45-58) currently hard-codes "migrate then seed". For PG the table may already be migrated; make the seeder idempotent w.r.t. existing tables/users. |
| `bench/run_all.sh` | Modify | New helper `setup_pg_bench_db()`; export `RAILS_DB=pg` / `DATABASE_URL` for AR rows; pass `--async-io` to `boot_hyperion` for AR rows only. |
| `docs/BENCH_HOST_SETUP.md` | Modify | Append "Postgres" subsection (install, createdb, port 5432). |
| `docs/BENCH_HYPERION_RAILS.md` | Modify | "DB choice" section explaining `RAILS_DB={sqlite\|pg}`; matrix headers say "AR-CRUD (PG)"; "why we switched" paragraph. |
| `bench/Gemfile.4way` | **No change** | `pg ~> 1.5` and `hyperion-async-pg ~> 0.5` already pinned at lines 36-37. |
| `bench/rails_app/Gemfile` | **No change** | Intentionally near-empty per its own comment; the bench Gemfile is `bench/Gemfile.4way`. |
| `bench/rails_app/db/seeds.rb` | **No change** | Seeding happens via `config.after_initialize` (more reliable on every boot than `bin/rails db:seed`). |

---

## Task 1: Add ERB branch to `bench/rails_app/config/database.yml`

**Files:**
- Modify: `bench/rails_app/config/database.yml`

- [ ] **Step 1: Replace the file with the ERB-branching version**

Read the current file first (so the edit anchors are accurate), then overwrite with:

```yaml
# Bench DB config. Selected at boot via `RAILS_DB`:
#   unset / RAILS_DB=sqlite → in-memory SQLite (cache=shared) — works on
#                              any host, no external deps, used by CI
#                              smoke runs.
#   RAILS_DB=pg              → Postgres at DATABASE_URL (default
#                              postgres://localhost/hyperion_bench).
#                              Required for the canonical AR-CRUD bench
#                              rows; pairs with --async-io +
#                              hyperion-async-pg.
<% if ENV['RAILS_DB'].to_s.downcase == 'pg' %>
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  url: <%= ENV.fetch('DATABASE_URL', 'postgres://localhost/hyperion_bench') %>
  prepared_statements: true
  advisory_locks: false

production:
  <<: *default

development:
  <<: *default

test:
  <<: *default
<% else %>
default: &default
  adapter: sqlite3
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000
  # OPEN_URI(64) | OPEN_CREATE(4) | OPEN_READWRITE(2). Required so
  # sqlite3 actually parses the file: URI; otherwise the URI string is
  # treated as a literal filename and each pool connection opens a
  # fresh empty in-memory DB. mode=memory makes it in-RAM,
  # cache=shared lets all pool connections see one DB.
  flags: <%= 64 | 4 | 2 %>
  database: "file:rails_bench?mode=memory&cache=shared"

production:
  <<: *default

development:
  <<: *default

test:
  <<: *default
<% end %>
```

- [ ] **Step 2: Verify the YAML parses under both branches**

Run (from repo root, on a host with both sqlite3 and pg gems available):

```bash
cd bench/rails_app
RAILS_DB=sqlite ruby -ryaml -rerb -e 'YAML.safe_load(ERB.new(File.read("config/database.yml")).result, aliases: true).fetch("production").tap{|h| puts h.fetch("adapter")}'
RAILS_DB=pg ruby -ryaml -rerb -e 'YAML.safe_load(ERB.new(File.read("config/database.yml")).result, aliases: true).fetch("production").tap{|h| puts h.fetch("adapter")}'
```

Expected output (two lines):
```
sqlite3
postgresql
```

- [ ] **Step 3: Commit**

```bash
git add bench/rails_app/config/database.yml
git commit -m "[bench] rails_app/database.yml: add RAILS_DB={sqlite|pg} branch"
```

---

## Task 2: Make the boot-time seeder idempotent on PG

The current seeder (`bench/rails_app/config/application.rb:45-58`) only runs the migration if the `users` table doesn't exist, and only seeds if it ran the migration. On Postgres, an operator who runs `db:migrate` ahead of time leaves the seeder skipping seeds entirely. Fix: decouple "migrate if needed" from "seed if empty".

**Files:**
- Modify: `bench/rails_app/config/application.rb` (lines 42-58)

- [ ] **Step 1: Read the current `after_initialize` block to anchor the edit**

The block to replace is exactly:

```ruby
    # Bench-only: auto-migrate and seed 100 users on every boot.
    # The DB is `:memory:` shared-cache, so it's empty on every fresh
    # process — eager seeding is the only way the AR-CRUD row sees data.
    config.after_initialize do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        unless conn.table_exists?(:users)
          ActiveRecord::Migration.suppress_messages do
            ActiveRecord::MigrationContext.new(
              Rails.root.join('db/migrate')
            ).migrate
          end
          100.times do |i|
            User.create!(name: "User #{i}", email: "user#{i}@bench.local")
          end
        end
      end
    end
```

- [ ] **Step 2: Replace with the idempotent version**

```ruby
    # Bench-only: auto-migrate and seed 100 users on every boot.
    #
    # SQLite path: the DB is `:memory:` shared-cache, so it's empty on
    # every fresh process — eager seeding is the only way the AR-CRUD
    # row sees data.
    # PG path: an operator may have run `db:migrate` ahead of time, so
    # the table exists; we still need to seed if the table is empty.
    # Both branches are idempotent: re-boots on PG don't re-seed.
    config.after_initialize do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        unless conn.table_exists?(:users)
          ActiveRecord::Migration.suppress_messages do
            ActiveRecord::MigrationContext.new(
              Rails.root.join('db/migrate')
            ).migrate
          end
        end
        if User.count.zero?
          User.transaction do
            100.times do |i|
              User.create!(name: "User #{i}", email: "user#{i}@bench.local")
            end
          end
        end
      end
    end
```

- [ ] **Step 3: Commit**

```bash
git add bench/rails_app/config/application.rb
git commit -m "[bench] rails_app: idempotent seeder (decouple migrate-if-missing from seed-if-empty)"
```

---

## Task 3: Bench-driver helper — `setup_pg_bench_db`

Add a one-shot setup function called once before the AR-CRUD rows boot. It probes for `pg_isready`, creates `hyperion_bench` if needed, and runs the migrations. Idempotent: safe to call when DB exists / migrations already ran.

**Files:**
- Modify: `bench/run_all.sh` — add helper near the existing `boot_*` helpers (just before line 198 `boot_hyperion`).

- [ ] **Step 1: Locate the insertion point**

The helper goes immediately above `boot_hyperion()` (currently line 198). Search for the marker:

```bash
grep -n '^boot_hyperion()' bench/run_all.sh
```

Expected: one match at the line where `boot_hyperion()` is defined.

- [ ] **Step 2: Insert the helper**

Insert this block immediately before `boot_hyperion()`:

```bash
# Postgres setup for the AR-CRUD bench rows (19-22 / 27-28).
#
# Idempotent: probes for pg_isready, creates the bench database if
# missing, and runs the Rails migrations against it. Returns 0 on
# success, non-zero if PG is not reachable (caller marks the AR rows
# as BOOT-FAIL,no-pg).
#
# Required env (set by run_all.sh before AR rows):
#   RAILS_DB=pg
#   DATABASE_URL=postgres://localhost/hyperion_bench (default)
#
# On openclaw-vm: install with `apt-get install postgresql-15` and
# `sudo -u postgres createuser -s ubuntu` (see docs/BENCH_HOST_SETUP.md).
setup_pg_bench_db() {
  if ! command -v pg_isready >/dev/null 2>&1; then
    echo "[setup_pg_bench_db] pg_isready not on PATH; skipping AR rows"
    return 1
  fi
  if ! pg_isready -q -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}"; then
    echo "[setup_pg_bench_db] postgres not reachable at ${PGHOST:-localhost}:${PGPORT:-5432}; skipping AR rows"
    return 1
  fi

  local dbname="${PGDATABASE_BENCH:-hyperion_bench}"
  # createdb is idempotent if we tolerate the duplicate-database error.
  if ! psql -lqt | cut -d \| -f 1 | grep -qw "$dbname"; then
    echo "[setup_pg_bench_db] creating database $dbname"
    createdb "$dbname" || {
      echo "[setup_pg_bench_db] createdb failed; check PG auth on this host"
      return 1
    }
  fi

  echo "[setup_pg_bench_db] migrating $dbname"
  (
    cd bench/rails_app && \
    RAILS_ENV=production RAILS_DB=pg \
    DATABASE_URL="postgres://localhost/$dbname" \
    BUNDLE_GEMFILE=../Gemfile.4way \
    bundle exec bin/rails db:migrate
  ) || {
    echo "[setup_pg_bench_db] migrate failed; AR rows will boot-fail"
    return 1
  }

  return 0
}
```

- [ ] **Step 3: Verify shellcheck cleanliness**

Run:

```bash
shellcheck bench/run_all.sh
```

Expected: no new warnings beyond the existing baseline. (If shellcheck isn't installed, skip — the project uses it but it's not enforced in `bin/check`.)

- [ ] **Step 4: Commit**

```bash
git add bench/run_all.sh
git commit -m "[bench] run_all.sh: add setup_pg_bench_db helper for AR-CRUD rows"
```

---

## Task 4: Wire AR-CRUD rows to use `RAILS_DB=pg` + `--async-io`

Each AR-CRUD row needs three wiring changes: (a) the `setup_pg_bench_db` runs once at the start of the AR group; (b) Hyperion AR rows pass `--async-io` and export `RAILS_DB=pg` + `DATABASE_URL`; (c) Agoo / Falcon / Puma comparison rows export the same DB env but without `--async-io` (it's a Hyperion-only flag).

**Files:**
- Modify: `bench/run_all.sh`
  - Around line 532 (`if want_row 19`) — Hyperion 1w
  - Around line 547 (`if want_row 20`) — Agoo 1w
  - Around line 562 (`if want_row 21`) — Falcon 1w
  - Around line 577 (`if want_row 22`) — Puma 1w
  - Around line 652 (`if want_row 27`) — Hyperion 4w
  - Around line 667 (`if want_row 28`) — Agoo 4w
  - (Falcon/Puma 4w AR rows: there are no 4w Falcon/Puma rows in the matrix; only Hyperion vs Agoo for 4w.)

- [ ] **Step 1: Add a one-time PG setup gate immediately before the AR group**

Find the section heading for row 19 (line ~530, the comment `# ---------- Row 19: Hyperion Rails AR-CRUD (1w x 5t) ----------`). Insert this block IMMEDIATELY BEFORE that heading:

```bash
# AR-CRUD rows (19-22, 27-28) run on Postgres. Set up once; if the
# setup fails, the rows below will see PG_BENCH_OK=0 and skip with
# BOOT-FAIL,no-pg in the CSV.
PG_BENCH_OK=0
if want_row 19 || want_row 20 || want_row 21 || want_row 22 || \
   want_row 27 || want_row 28; then
  if setup_pg_bench_db; then
    PG_BENCH_OK=1
    export RAILS_DB=pg
    export DATABASE_URL="postgres://localhost/${PGDATABASE_BENCH:-hyperion_bench}"
  fi
fi
```

- [ ] **Step 2: Update Row 19 (Hyperion AR-CRUD 1w) to gate on PG + pass `--async-io`**

Locate the row-19 block (lines ~532-545). Replace with:

```bash
# ---------- Row 19: Hyperion Rails AR-CRUD (1w x 5t, PG + --async-io) ----------
if want_row 19; then
  echo
  echo "=== Row 19: Hyperion Rails AR-CRUD (1w x 5t, PG + --async-io) ==="
  if [ "$PG_BENCH_OK" != "1" ]; then
    echo "19,hyperion_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,no-pg," >> "$OUT_CSV"
  else
    stop_port
    boot_hyperion "row19" "bench/rails_ar.ru" --async-io -t 5 -w 1 -p "$PORT"
    if wait_for_bind "row19" "/healthz"; then
      warmup_hit "row19" "/users.json"
      bench_wrk_row 19 "hyperion_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
    else
      echo "19,hyperion_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
    fi
    stop_port
  fi
fi
```

- [ ] **Step 3: Update Row 20 (Agoo AR-CRUD 1w) — gate on PG, no `--async-io`**

Replace the row-20 block (lines ~547-560) with:

```bash
# ---------- Row 20: Agoo Rails AR-CRUD (1w x 5t, PG) ----------
if want_row 20; then
  echo
  echo "=== Row 20: Agoo Rails AR-CRUD (1w x 5t, PG) ==="
  if [ "$PG_BENCH_OK" != "1" ]; then
    echo "20,agoo_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,no-pg," >> "$OUT_CSV"
  else
    stop_port
    boot_agoo "bench/rails_ar.ru" 1
    if wait_for_bind "agoo-row20" "/healthz"; then
      warmup_hit "row20" "/users.json"
      bench_wrk_row 20 "agoo_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
    else
      echo "20,agoo_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
    fi
    stop_port
  fi
fi
```

- [ ] **Step 4: Update Row 21 (Falcon AR-CRUD 1w) — gate on PG**

Replace the row-21 block (lines ~562-575) with:

```bash
# ---------- Row 21: Falcon Rails AR-CRUD (1w x 5t, PG) ----------
if want_row 21; then
  echo
  echo "=== Row 21: Falcon Rails AR-CRUD (1w x 5t, PG) ==="
  if [ "$PG_BENCH_OK" != "1" ]; then
    echo "21,falcon_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,no-pg," >> "$OUT_CSV"
  else
    stop_port
    boot_falcon "bench/rails_ar.ru" 1
    if wait_for_bind "falcon-row21" "/healthz"; then
      warmup_hit "row21" "/users.json"
      bench_wrk_row 21 "falcon_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
    else
      echo "21,falcon_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
    fi
    stop_port
  fi
fi
```

- [ ] **Step 5: Update Row 22 (Puma AR-CRUD 1w) — gate on PG**

Replace the row-22 block (lines ~577-590) with:

```bash
# ---------- Row 22: Puma Rails AR-CRUD (1w x 5t, PG) ----------
if want_row 22; then
  echo
  echo "=== Row 22: Puma Rails AR-CRUD (1w x 5t, PG) ==="
  if [ "$PG_BENCH_OK" != "1" ]; then
    echo "22,puma_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,no-pg," >> "$OUT_CSV"
  else
    stop_port
    boot_puma "bench/rails_ar.ru" 1
    if wait_for_bind "puma-row22" "/healthz"; then
      warmup_hit "row22" "/users.json"
      bench_wrk_row 22 "puma_rails_ar_1w" "bench/rails_ar.ru" "/users.json"
    else
      echo "22,puma_rails_ar_1w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
    fi
    stop_port
  fi
fi
```

- [ ] **Step 6: Update Row 27 (Hyperion AR-CRUD 4w) — gate + `--async-io`**

Locate row 27 (`if want_row 27`, lines ~652-664). Replace with:

```bash
# ---------- Row 27: Hyperion Rails AR-CRUD (4w x 5t, PG + --async-io) ----------
if want_row 27; then
  echo
  echo "=== Row 27: Hyperion Rails AR-CRUD (4w x 5t, PG + --async-io) ==="
  if [ "$PG_BENCH_OK" != "1" ]; then
    echo "27,hyperion_rails_ar_4w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,no-pg," >> "$OUT_CSV"
  else
    stop_port
    boot_hyperion "row27" "bench/rails_ar.ru" --async-io -t 5 -w 4 -p "$PORT"
    if wait_for_bind "row27" "/healthz"; then
      warmup_hit "row27" "/users.json"
      bench_wrk_row 27 "hyperion_rails_ar_4w" "bench/rails_ar.ru" "/users.json"
    else
      echo "27,hyperion_rails_ar_4w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
    fi
    stop_port
  fi
fi
```

- [ ] **Step 7: Update Row 28 (Agoo AR-CRUD 4w) — gate on PG**

Locate row 28 (`if want_row 28`, lines ~667-679). Replace with:

```bash
# ---------- Row 28: Agoo Rails AR-CRUD (4w x 5t, PG) ----------
if want_row 28; then
  echo
  echo "=== Row 28: Agoo Rails AR-CRUD (4w x 5t, PG) ==="
  if [ "$PG_BENCH_OK" != "1" ]; then
    echo "28,agoo_rails_ar_4w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,no-pg," >> "$OUT_CSV"
  else
    stop_port
    boot_agoo "bench/rails_ar.ru" 4
    if wait_for_bind "agoo-row28" "/healthz"; then
      warmup_hit "row28" "/users.json"
      bench_wrk_row 28 "agoo_rails_ar_4w" "bench/rails_ar.ru" "/users.json"
    else
      echo "28,agoo_rails_ar_4w,wrk,bench/rails_ar.ru,BOOT-FAIL,BOOT-FAIL,," >> "$OUT_CSV"
    fi
    stop_port
  fi
fi
```

- [ ] **Step 8: Smoke-test on a host without PG (macOS dev)**

```bash
./bench/run_all.sh --rails --row 19
```

Expected: row 19 prints `[setup_pg_bench_db] postgres not reachable...` and the CSV gets a `BOOT-FAIL,BOOT-FAIL,no-pg` row. No crash; the script exits cleanly.

- [ ] **Step 9: Commit**

```bash
git add bench/run_all.sh
git commit -m "[bench] AR-CRUD rows (19-22, 27-28): switch to Postgres + --async-io"
```

---

## Task 5: Document the Postgres setup in `docs/BENCH_HOST_SETUP.md`

**Files:**
- Modify: `docs/BENCH_HOST_SETUP.md`

- [ ] **Step 1: Inspect the doc to find where to append the PG section**

Run:

```bash
grep -nE '^## ' docs/BENCH_HOST_SETUP.md
```

This lists the existing top-level sections (host info, kernel tuning, wrk install, ghz install, etc.). Pick the position after the "ghz install" / "wrk install" sections. If the doc has a "Test the harness" tail section, insert immediately before that. If unclear, append at the bottom.

- [ ] **Step 2: Append the PG section**

```markdown
## Postgres (for the Rails AR-CRUD bench rows)

The AR-CRUD bench rows (19-22, 27-28) run on Postgres so they exercise
Hyperion's `--async-io` + `hyperion-async-pg` story (a path SQLite-mem
can't characterize because there's no I/O wait to yield on). Rows that
need PG fail open: if `pg_isready` fails the rows write
`BOOT-FAIL,no-pg` to the CSV and the rest of the matrix continues.

```sh
# Ubuntu 22.04+ on the bench VM
sudo apt-get update
sudo apt-get install -y postgresql-15 postgresql-client-15

# Trust on localhost so the bench harness needs no password.
# /etc/postgresql/15/main/pg_hba.conf — replace the `local`/`host` peer
# rules with:
#
#   local   all   all                trust
#   host    all   all   127.0.0.1/32 trust
#   host    all   all   ::1/128      trust
#
sudo systemctl restart postgresql

# Bench user (matches the OS user that runs run_all.sh on openclaw-vm).
sudo -u postgres createuser -s ubuntu

# Verify
pg_isready -h localhost -p 5432
# /var/run/postgresql:5432 - accepting connections
```

The bench harness creates the `hyperion_bench` database itself
(`bench/run_all.sh::setup_pg_bench_db`); no manual `createdb` needed.

To override the database name, set `PGDATABASE_BENCH=other_name` before
invoking `./bench/run_all.sh`.

To run the AR rows against SQLite anyway (for hosts without PG, or to
A/B against the legacy results), unset `RAILS_DB` or pass
`RAILS_DB=sqlite` — the rest of the matrix continues to work the same.
```

- [ ] **Step 3: Commit**

```bash
git add docs/BENCH_HOST_SETUP.md
git commit -m "[docs] BENCH_HOST_SETUP: add Postgres install section"
```

---

## Task 6: Re-run the Rails matrix on `openclaw-vm`, capture new numbers

**Files:**
- Touched only by the bench driver writing to `/tmp/hyperion-2.16-bench.csv` (or whatever `OUT_CSV` is set to in the env).

- [ ] **Step 1: Sync local edits to the VM**

```bash
rsync -az --delete \
  --exclude=.git --exclude=tmp --exclude='*.gem' \
  --exclude='lib/hyperion_http/*.bundle' \
  --exclude='lib/hyperion_http/*.so' \
  --exclude='ext/*/target' \
  ./ ubuntu@openclaw-vm:~/hyperion/
```

- [ ] **Step 2: Install the new Gemfile on the VM (one-time per change)**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && BUNDLE_GEMFILE=bench/Gemfile.4way bundle install --quiet'
```

Expected: `pg` and `hyperion-async-pg` install (already pinned in `bench/Gemfile.4way:36-37`).

- [ ] **Step 3: Run only the AR rows first (faster signal)**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && BUNDLE_GEMFILE=bench/Gemfile.4way OUT_CSV=/tmp/hyperion-2.17-pg-arrows.csv ./bench/run_all.sh --rails --rows 19,20,21,22,27,28'
```

Expected: 6 rows in the CSV with non-`BOOT-FAIL` numbers. Print head:

```bash
ssh ubuntu@openclaw-vm 'cat /tmp/hyperion-2.17-pg-arrows.csv'
```

- [ ] **Step 4: Run the full Rails matrix to capture the post-PG headline**

```bash
ssh ubuntu@openclaw-vm 'cd ~/hyperion && BUNDLE_GEMFILE=bench/Gemfile.4way OUT_CSV=/tmp/hyperion-2.17-bench.csv OUT_MD=/tmp/hyperion-2.17-bench.md ./bench/run_all.sh --rails'
```

Expected runtime: ~30 minutes per `BENCH_HYPERION_RAILS.md`'s Reproduction note.

- [ ] **Step 5: Pull the CSV + markdown back**

```bash
scp ubuntu@openclaw-vm:/tmp/hyperion-2.17-bench.csv /tmp/
scp ubuntu@openclaw-vm:/tmp/hyperion-2.17-bench.md  /tmp/
```

- [ ] **Step 6: Commit the CSV artifact**

```bash
cp /tmp/hyperion-2.17-bench.csv docs/BENCH_HYPERION_2_17_results.csv
git add docs/BENCH_HYPERION_2_17_results.csv
git commit -m "[bench] capture post-PG-switch Rails matrix CSV (2.17 baseline)"
```

---

## Task 7: Update `docs/BENCH_HYPERION_RAILS.md` with the new numbers + decision

**Files:**
- Modify: `docs/BENCH_HYPERION_RAILS.md`

- [ ] **Step 1: Add a "DB choice" section near the top**

Insert immediately after the existing intro paragraph (the "**Bench host:**" / "**Ruby:**" / "**Rails:**" block):

```markdown
## DB choice for AR-CRUD rows

The AR-CRUD rows (19-22, 27-28) require `RAILS_DB=pg` to exercise the
canonical Hyperion path: `--async-io` + `hyperion-async-pg`, where the
AR-side `Fiber.scheduler.io_wait` parks on the PG socket while other
fibers run. SQLite in `mode=memory&cache=shared` (the previous default)
has no socket to yield on — the per-stmt cost is GVL-held C work + pool-
mutex contention, which characterizes neither Hyperion nor the
comparison servers fairly.

Hosts without PG can still run the AR rows by unsetting `RAILS_DB`
(or `RAILS_DB=sqlite`); the rows then exercise SQLite-mem-shared as
before. The headline numbers in this doc are PG.
```

- [ ] **Step 2: Add a "post-PG-switch" results section**

Append (do not replace) a new section at the bottom of the doc:

```markdown
## Post-PG-switch (2026-05-05)

After switching the AR-CRUD rows to Postgres + `--async-io` +
`hyperion-async-pg` (per `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` §#3),
the Rails matrix re-ran on `openclaw-vm`.

### Single-worker (1w × 5t) — PG

| Workload | Hyperion (r/s) | Agoo (r/s) | Falcon (r/s) | Puma (r/s) | Bar |
|---|---:|---:|---:|---:|:---:|
| AR-CRUD `/users.json` | <fill from CSV> | <fill> | <fill> | <fill> | <pass/fail (XX.X%)> |

### Multi-worker (4w × 5t, Hyperion vs Agoo) — PG

| Workload | Hyperion (r/s) | Agoo (r/s) | Bar |
|---|---:|---:|:---:|
| AR-CRUD | <fill> | <fill> | <pass/fail (XX.X%)> |

### Decision

<one of two paragraphs:>

a. PG closes the AR-CRUD gap (rows 19/20 and 27/28 both pass Bar d) →
   class #3 of the perf roadmap is retired. #1 (C ResponseWriter) and
   #2 (io_uring hot path) proceed as planned but with one fewer
   success criterion to chase.

b. PG narrows but does not close the AR-CRUD gap → #1 and #2 still
   need to do work on AR rows. Updated baseline is captured here;
   subsequent specs reference these numbers as the "post-#3" baseline.
```

- [ ] **Step 3: Fill in the actual numbers from the CSV**

After Task 6 captured the CSV, replace `<fill>` placeholders with the actual r/s values from `docs/BENCH_HYPERION_2_17_results.csv`. Compute "Bar" status using the existing rule (Hyperion ≥ Agoo for rows 19>20 and 27>28). Choose decision branch (a) or (b) based on the numbers.

- [ ] **Step 4: Update the spec doc to record the decision**

Append a single new section to `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` (under #3 → "Acceptance"):

```markdown
### Outcome (filled in after bench re-run)

- Date: <YYYY-MM-DD>
- AR-CRUD 1w (Hyperion vs Agoo): <r/s> vs <r/s> → <pass/fail>
- AR-CRUD 4w (Hyperion vs Agoo): <r/s> vs <r/s> → <pass/fail>
- Decision: <a or b from BENCH_HYPERION_RAILS.md "Post-PG-switch" section>
```

- [ ] **Step 5: Commit**

```bash
git add docs/BENCH_HYPERION_RAILS.md docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md
git commit -m "[docs] BENCH_HYPERION_RAILS: post-PG-switch results + decision"
```

---

## Task 8: Open the PR

**Files:**
- None modified — PR creation only.

- [ ] **Step 1: Push branch + open PR**

```bash
git push -u origin HEAD
gh pr create --title "[bench] AR-CRUD rows → Postgres + --async-io (perf roadmap #3)" --body "$(cat <<'EOF'
## Summary

- Switches Rails AR-CRUD bench rows (19-22 / 27-28) from in-memory SQLite to Postgres
- Hyperion AR rows boot under `--async-io` to engage `hyperion-async-pg` fiber-yielding I/O
- SQLite path retained as fallback (`RAILS_DB=sqlite`) for hosts without PG
- Per `docs/superpowers/specs/2026-05-05-hyperion-perf-roadmap-design.md` §#3

## Test plan

- [ ] On a host without PG: `./bench/run_all.sh --rails --row 19` writes `BOOT-FAIL,no-pg` and exits cleanly
- [ ] On `openclaw-vm`: full `--rails` matrix completes; AR rows report new numbers
- [ ] CSV from the run committed at `docs/BENCH_HYPERION_2_17_results.csv`
- [ ] `BENCH_HYPERION_RAILS.md` "Post-PG-switch" section filled in with actual numbers

EOF
)"
```

Expected: PR URL printed; CI matrix (Ubuntu + macOS × Ruby 3.3.6 + 3.4.1) is green (these changes are bench-only and don't touch the gem itself).

---

## Acceptance gate (from spec)

- [ ] `./bench/run_all.sh --rails --row 19` on a host without PG writes `BOOT-FAIL,no-pg` and exits cleanly.
- [ ] On `openclaw-vm`, the full `--rails` matrix completes with non-`BOOT-FAIL` numbers for rows 19-22 / 27-28.
- [ ] `docs/BENCH_HYPERION_RAILS.md` "Post-PG-switch" section is filled in with actual r/s + Bar d status.
- [ ] Spec doc has the "Outcome" subsection appended with the decision (a or b).
- [ ] CI green on Ubuntu + macOS × Ruby 3.3.6 + 3.4.1.

## Rollback

`git revert` the PR. SQLite path was preserved via the `RAILS_DB` ERB branch — no app-side rollback needed; existing `--rails` runs without `RAILS_DB` set continue to use SQLite.
