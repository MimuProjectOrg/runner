# Code Review Findings: setup-macos-runner.zsh

Branch: `s390x-port`
Commits reviewed: `86581f1`, `b9dcd41`, `7981935`
Date: 2026-06-24

---

## Findings

### H — High

**H1 — L1 regression: `reg_token` still visible in `ps aux`**
File: `scripts/setup-macos-runner.zsh`, line 366

`reexec_args+=( -t "$reg_token" )` passes the registration token as a CLI argument to the
phase-2 re-exec. This makes the token visible in `ps aux` for the `exec sudo` process —
the same exposure that L1 claimed to fix for `config.sh`.
Fix: export the token as an env var and forward it via `sudo -E`, mirroring how `RUNNER_CFG_PAT` is handled.

---

### M — Medium

**M1 — Missing input validation for `-n` (runner name) and `-r` (runner group)**
File: `scripts/setup-macos-runner.zsh`, lines 100–107

M2 validates scope, hostname, and labels, but `runner_name` and `runner_group` are used in
command arguments without any `validate_*` guard. Both should be checked against a safe
alphanumeric pattern before use.

---

### L — Low

**L1 — Outdated GitHub API Accept header**
File: `scripts/setup-macos-runner.zsh`, line 218

`application/vnd.github.everest-preview+json` is a deprecated preview-era header.
Replace with `application/vnd.github+json`.

**L2 — Redundant `-L` flag on download curl call**
File: `scripts/setup-macos-runner.zsh`, line 168

`CURL_OPTS` already includes `-L` (via `-fsSL`). Passing `-O -L` on the same call is redundant.
Remove the explicit `-L`.

**L3 — No curl timeouts**
File: `scripts/setup-macos-runner.zsh`, line 152 (`CURL_OPTS` definition)

All `curl` calls can hang indefinitely. Add `--connect-timeout 30 --max-time 120` to
`CURL_OPTS` to fail fast on network issues.

**L4 — Tarball and checksum file not cleaned up after extraction**
File: `scripts/setup-macos-runner.zsh`, lines 163–188

The `.tar.gz` and `.sha256` files are downloaded into `$PWD` and left on disk after
successful extraction. Remove both files after `tar` succeeds to avoid stale artifacts.
