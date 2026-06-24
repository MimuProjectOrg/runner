# Plan: `scripts/setup-s390x-runner.sh`

## Top-Level Overview

Create a single Bash script, `scripts/setup-s390x-runner.sh`, that:

1. Creates a **`gh-runner`** system user (primary group `gh-runner`, locked
   password, `/bin/bash` login shell, least-privilege — no sudo, no extra
   groups).
2. Creates **`/home/gh-runner/actions-runner`** owned by that user.
3. Resolves the deliverable tarball: uses the newest
   `_package/actions-runner-linux-s390x-*.tar.gz` if one exists locally,
   otherwise builds it from source in this repository following the s390x
   procedure documented in `docs/adrs/4520-linux-s390x-port.md`.
4. Extracts the tarball into the `actions-runner` directory.
5. Runs **`config.sh`** as `gh-runner` (token sourced from `RUNNER_CFG_PAT`
   env var **or** a `--token` flag for a pre-generated registration token).
6. Installs and starts the runner as a **systemd service** via `svc.sh`.

The script is general-purpose (any Ubuntu s390x host) but its primary target
is `b46lp05.lnxne.boe` — the machine described in Gap 1 of the ADR.

---

## Sub-Tasks

---

### Sub-Task 1 — Scaffold the script skeleton

**Intent**: Lay out the script's overall structure — shebang, `set -euo
pipefail`, usage/help block, argument parsing (`-s scope`, `-g ghe_hostname`,
`-n runner_name`, `-l labels`, `-r runner_group`, `-f replace`), sudo-elevation
check, and platform guard (must be Linux s390x).

**Expected Outcomes**
- `scripts/setup-s390x-runner.sh` exists and is executable.
- Running `./setup-s390x-runner.sh --help` prints usage and exits cleanly.
- Running on a non-s390x host aborts with a clear error.

**Todo List**
1. Create `scripts/setup-s390x-runner.sh` with `#!/usr/bin/env bash` and
   `set -euo pipefail`.
2. Add a `usage()` function documenting all flags and the `RUNNER_CFG_PAT`
   environment variable.
3. Add `getopts` parsing for `-s`, `-g`, `-n`, `-l`, `-r`, `-t` (pre-generated
   token), `-f`, `-h`.
4. Add a platform guard: `uname -m` must equal `s390x`; abort otherwise.
5. Add a `require_root` check: script must run as root (or via sudo) so it
   can create users and manage systemd.
6. Add a `fatal()` helper (identical pattern to `scripts/create-latest-svc.sh`).
7. `chmod +x scripts/setup-s390x-runner.sh`.

**Relevant Context**
- Pattern: [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:1)
  — follow its `fatal()` / `getopts` style.

**Status**: [x] done

---

### Sub-Task 2 — Create the `gh-runner` user and home directory

**Intent**: Create a locked-password, least-privilege system user
`gh-runner` with primary group `gh-runner`, home directory
`/home/gh-runner`, and a `/bin/bash` login shell, then create
`/home/gh-runner/actions-runner` owned by that user.

**Expected Outcomes**
- `getent passwd gh-runner` shows the user with home `/home/gh-runner` and
  shell `/bin/bash`.
- `getent group gh-runner` shows a group matching the user's primary GID.
- `/home/gh-runner/actions-runner` exists and is owned `gh-runner:gh-runner`
  with mode `750`.
- The user is **not** in `sudo`, `docker`, or any other elevated group.
- Re-running the script is idempotent (user/group creation skipped if they
  already exist).

**Todo List**
1. Check `getent group gh-runner`; if absent, run
   `groupadd --system gh-runner`.
2. Check `getent passwd gh-runner`; if absent, run:
   ```
   useradd --system \
           --gid gh-runner \
           --home-dir /home/gh-runner \
           --create-home \
           --shell /bin/bash \
           --comment "GitHub Actions Runner" \
           gh-runner
   ```
3. Lock the password: `passwd --lock gh-runner`.
4. Create `/home/gh-runner/actions-runner` if absent:
   `install -d -m 750 -o gh-runner -g gh-runner /home/gh-runner/actions-runner`.

**Relevant Context**
- Least-privilege requirement: `useradd --system` avoids adding the user to
  any supplemental groups.
- The Docker reference in [`images/Dockerfile`](images/Dockerfile:58) uses
  `adduser --uid 1001`; we use `useradd --system` (no fixed UID) to avoid
  conflicts on arbitrary hosts.

**Status**: [x] done

---

### Sub-Task 3 — Resolve / build the deliverable tarball

**Intent**: Locate an existing `actions-runner-linux-s390x-*.tar.gz` in
`_package/`, or build it from source. This keeps the script self-contained:
drop it on the target host alongside the repo and it handles the full story.

**Expected Outcomes**
- After this block, a shell variable `TARBALL` holds the absolute path to a
  valid `actions-runner-linux-s390x-<version>.tar.gz`.
- If `_package/` already has one or more matching files, the newest is used
  and no build is attempted.
- If no file is found, the build is run automatically (`bootstrap-s390x-nuget.sh`
  if needed, then `dev.sh layout Release`, `dev.sh package Release`).
- Version used comes from `src/runnerversion` (currently `2.335.0`).

**Todo List**
1. Derive `RUNNER_VERSION` from `src/runnerversion` (trim whitespace).
2. Glob `_package/actions-runner-linux-s390x-*.tar.gz`; pick the newest via
   `ls -t | head -1`.
3. If no file found, print a notice and **silently proceed** to build:
   a. `bash src/Misc/bootstrap-s390x-nuget.sh` (idempotent; safe to re-run).
   b. `cd src && ./dev.sh layout Release`.
   c. `./dev.sh package Release`.
   d. Re-glob `_package/` to set `TARBALL`.
4. Verify `TARBALL` is non-empty and readable; `fatal` if not.
5. Print `Using tarball: $TARBALL`.

**Relevant Context**
- Build procedure from ADR §"How to Produce the Release Package Manually":
  [`docs/adrs/4520-linux-s390x-port.md`](docs/adrs/4520-linux-s390x-port.md:198).
- `src/runnerversion`: [`src/runnerversion`](src/runnerversion:1) → `2.335.0`.
- Build scripts: `src/Misc/bootstrap-s390x-nuget.sh`,
  [`src/dev.sh`](src/dev.sh:1).

**Status**: [x] done

---

### Sub-Task 4 — Extract the tarball into `actions-runner`

**Intent**: Unpack the tarball into `/home/gh-runner/actions-runner` with
`gh-runner` as owner so the runner can read/write its own working files.

**Expected Outcomes**
- `/home/gh-runner/actions-runner/run.sh` and `bin/Runner.Listener` exist.
- All extracted files are owned `gh-runner:gh-runner`.
- Extraction is idempotent: if `run.sh` already exists the script skips
  extraction (or warns and proceeds if `-f` replace flag is set).

**Todo List**
1. If `/home/gh-runner/actions-runner/run.sh` already exists and `-f` is not
   set, `fatal` with a message telling the operator to pass `-f` to replace.
2. Extract: `tar xzf "$TARBALL" -C /home/gh-runner/actions-runner`.
3. Fix ownership: `chown -R gh-runner:gh-runner /home/gh-runner/actions-runner`.

**Relevant Context**
- Pattern: [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:164)
  lines 164-169 (`tar xzf` + `chown -R`).

**Status**: [x] done

---

### Sub-Task 5 — Configure the runner (`config.sh`)

**Intent**: Run `config.sh` as the `gh-runner` user to register the runner
with GitHub (or GHE), using the token supplied via `RUNNER_CFG_PAT`.

**Expected Outcomes**
- The runner is registered at the specified scope URL.
- `.runner` credential file is present inside `actions-runner/`.
- Config runs as `gh-runner`, not as root.

**Todo List**
1. Validate required inputs: `-s` scope must be set; either `RUNNER_CFG_PAT`
   env var or `-t <token>` flag must supply a token.
2. Determine `RUNNER_URL`:
   - If `-g ghe_hostname` is set → `https://<ghe_hostname>/<scope>`
   - Otherwise → `https://github.com/<scope>`
3. Determine `BASE_API_URL` (same logic as `create-latest-svc.sh` lines
   121-124).
4. Resolve the registration token:
   - If `-t <token>` was passed, use it directly as `RUNNER_TOKEN`.
   - Otherwise exchange `RUNNER_CFG_PAT` for a registration token via the
     GitHub API (same `curl` + `jq` call as `create-latest-svc.sh` line 132).
5. Scope detection: if `runner_scope` contains `/` it is a repo runner
   (`repos`), otherwise org runner (`orgs`) — identical to
   `create-latest-svc.sh` lines 127-130.
6. Run `config.sh` as `gh-runner`:
   ```
   sudo -E -u gh-runner ./config.sh \
     --unattended \
     --url "$RUNNER_URL" \
     --token "$RUNNER_TOKEN" \
     --name "${runner_name:-$(hostname)}" \
     --labels "self-hosted,linux,s390x${labels:+,$labels}" \
     ${runner_group:+--runnergroup "$runner_group"} \
     ${replace:+--replace}
   ```
7. Confirm `.runner` file was created; `fatal` if not.

**Relevant Context**
- Pattern: [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:176)
  lines 176-184 (URL construction + `config.sh` call).
- The labels `self-hosted,linux,s390x` match the ADR's YAML matrix entry
  (`[self-hosted, linux, s390x]`) from
  [`docs/adrs/4520-linux-s390x-port.md`](docs/adrs/4520-linux-s390x-port.md:142).

**Status**: [x] done

---

### Sub-Task 6 — Install and start the systemd service (`svc.sh`)

**Intent**: Install the runner as a systemd service running as `gh-runner`
and start it, mirroring the final step of `create-latest-svc.sh`.

**Expected Outcomes**
- `systemctl status actions.runner.*` shows the unit active/running.
- Service is enabled to start on boot.
- Service runs as `gh-runner` (confirmed in the unit file's `User=` line).

**Todo List**
1. Run `sudo ./svc.sh install gh-runner` from inside `actions-runner/`.
2. Run `sudo ./svc.sh start`.
3. Print the final status: `sudo ./svc.sh status`.
4. Print a success banner with the runner name and scope.

**Relevant Context**
- Pattern: [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:196)
  lines 196-197 (`svc.sh install` + `svc.sh start`).
- `svc.sh` template:
  [`src/Misc/layoutbin/systemd.svc.sh.template`](src/Misc/layoutbin/systemd.svc.sh.template:1).

**Status**: [x] done

---

## File To Be Created

| Path | Description |
|---|---|
| `scripts/setup-s390x-runner.sh` | The setup + install script |

No existing files are modified.
