# Bench Host Setup — openclaw-vm SSH

> **Audience:** maintainers and AI subagents that run the Hyperion
> bench harness against the in-house bench host `openclaw-vm`
> (192.168.31.14, user `ubuntu`).

## The recurring gap

Subagent bench runs from Phase 9 / 10 / 11 (kTLS / HPACK / GC audit)
through 2.2.x fix-A..E, 2.3-A..D, 2.5-B/D, 2.6-A..D, 2.7-A/C/D/F,
2.8-A and 2.9-B all hit the same wall:

```
ubuntu@openclaw-vm: Permission denied (publickey).
```

…even though the maintainer's interactive SSH from the same
workstation works fine. Every time, the subagent's report ends with
"SSH not available, deferred to maintainer".

**Root cause.** Process-environment, not credentials:

1. The maintainer's key (`~/.ssh/id_ed25519_woblavobla`) lives on
   disk and is referenced in `~/.ssh/config` under `Host openclaw-vm`.
2. macOS Keychain unlocks it for interactive shells via
   `UseKeychain yes` + `AddKeysToAgent yes`. The user's `ssh-agent`
   then holds the key.
3. Subagent shells inherit `SSH_AUTH_SOCK` from the controller —
   **but** if the controller's agent has no identities loaded
   (e.g. fresh login, locked Keychain, or `ssh-add -l` returns
   "The agent has no identities"), subagents get the empty agent too.
4. Without `IdentitiesOnly yes` set, OpenSSH offers every agent key
   (zero, in this case) before falling back to the on-disk
   `IdentityFile`. On hosts that have other keys in the agent (e.g.
   GitHub, GitLab), SSH offers those first and the bench host
   rejects them with `Too many authentication failures` before SSH
   ever tries the right key.

The fix removes the agent dependency entirely: read the key file
directly, every time, regardless of process environment.

## The fix — `IdentitiesOnly yes` + explicit `IdentityFile`

Edit `~/.ssh/config` on the controller workstation (the machine
that launches subagents — **not** anywhere in this repo):

```sshconfig
Host openclaw-vm 192.168.31.14
  HostName 192.168.31.14
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519_woblavobla
  IdentitiesOnly yes
```

The two load-bearing lines:

- **`IdentityFile ~/.ssh/id_ed25519_woblavobla`** — the key on disk.
  Must be readable by the user running the subagent (`chmod 600`).
- **`IdentitiesOnly yes`** — tells OpenSSH to ignore the agent
  entirely for this host and use **only** the listed `IdentityFile`.
  This is what makes the config robust to an empty / absent /
  agent-with-other-keys situation.

`User ubuntu` and `HostName 192.168.31.14` are convenience: subagents
can then `ssh openclaw-vm <cmd>` instead of
`ssh ubuntu@192.168.31.14 <cmd>`.

The maintainer's normal interactive SSH continues to work — the
agent is just no longer load-bearing.

## Verification

Run the same command a hermetic subagent would run, with **no**
inherited agent or environment:

```sh
env -i HOME=$HOME PATH=$PATH ssh -o ConnectTimeout=5 ubuntu@openclaw-vm date
```

Expected output: the openclaw-vm date (e.g. `Fri May  1 08:36:47 UTC 2026`),
no password prompt, no `Permission denied`.

If this works, every future subagent will too — they inherit the
same `~/.ssh/config` and the same on-disk key, but the new config no
longer relies on `ssh-agent`.

## Operator quick-reference

- **Bench host:** `openclaw-vm` (192.168.31.14)
- **Bench user:** `ubuntu`
- **Key on workstation:** `~/.ssh/id_ed25519_woblavobla`
  (`chmod 600`, `id_ed25519_woblavobla.pub` already in
  `~ubuntu/.ssh/authorized_keys` on openclaw-vm)
- **Config block:** see "The fix" above; goes in `~/.ssh/config` on
  the controller workstation, not in the Hyperion repo.

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

### Remote Postgres (override)

To run the AR-CRUD rows against a Postgres on a different host (a
shared bench DB, a managed cloud Postgres, etc.), set the standard
libpq env vars before invoking `./bench/run_all.sh`:

```sh
export PGHOST=your-postgres-host.example
export PGPORT=5432
export PGUSER=hyperion_bench
export PGPASSWORD=...           # if password auth is required
export PGDATABASE_BENCH=hyperion_bench

./bench/run_all.sh --rails
```

`bench/run_all.sh::setup_pg_bench_db` honors `PGHOST` / `PGPORT` /
`PGDATABASE_BENCH` for both the `pg_isready` probe and the
`DATABASE_URL` constructed for `bundle exec rails db:migrate`. The
helper assumes the user identified by `PGUSER` (or the OS-user default)
already has `CREATE DATABASE` and CONNECT privileges; it does NOT run
`CREATE ROLE`. For a fully-managed remote DB where you can't `createdb`
yourself, pre-create the database and either set
`PGDATABASE_BENCH=existing_name` or skip the create step manually.

## What this doc is *not*

This doc does not change Hyperion code. It documents an operator
setup step that needs to happen once per workstation. The fix is in
`~/.ssh/config`; the only thing in-repo is this guide so future
maintainers (and future subagents reading the repo for context)
know what's going on the next time they see
`Permission denied (publickey)`.
