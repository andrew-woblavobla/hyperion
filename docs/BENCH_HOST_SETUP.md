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

## What this doc is *not*

This doc does not change Hyperion code. It documents an operator
setup step that needs to happen once per workstation. The fix is in
`~/.ssh/config`; the only thing in-repo is this guide so future
maintainers (and future subagents reading the repo for context)
know what's going on the next time they see
`Permission denied (publickey)`.
