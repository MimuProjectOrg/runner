# Plan: `scripts/setup-macos-runner.zsh`

## Top-Level Overview

Create a single Zsh script, `scripts/setup-macos-runner.zsh`, that:

1. Validates the host is macOS (any architecture: x64 or arm64) and that
   required tools (`curl`, `jq`) are available.
2. Creates a dedicated **`gh-runner`** local user with primary group
   `gh-runner`, home directory `/Users/gh-runner`, and a `/bin/zsh` login
   shell (least-privilege — no admin, no extra groups). Must run as root
   (or via `sudo`) for user/group creation.
3. Creates **`/Users/gh-runner/actions-runner`** owned by `gh-runner:gh-runner`.
4. Downloads the latest `actions-runner-osx-{x64|arm64}-*.tar.gz` release
   from `https://github.com/actions/runner/releases` (skips download if the
   tarball is already present in the current directory).
5. Extracts the tarball into the `actions-runner` directory and fixes
   ownership to `gh-runner:gh-runner`.
6. Runs **`config.sh`** as `gh-runner` (via `sudo -u gh-runner`) to
   register the runner with GitHub (token sourced from `RUNNER_CFG_PAT`
   env var **or** a `-t` flag for a pre-generated registration token).
7. Installs and loads the runner as a **launchd LaunchAgent** via `svc.sh`,
   running in the `gh-runner` user session.

The script targets any macOS host (Intel or Apple Silicon) running macOS 12
Monterey or later, which aligns with the runner's minimum supported macOS
version. Zsh is used because it is the default interactive and scripting
shell on macOS since Catalina (10.15) and is guaranteed to be present at
`/bin/zsh` on every supported macOS version without any installation step.

---

## Sub-Tasks

---

### Sub-Task 1 — Scaffold the script skeleton

**Intent**: Lay out the script's overall structure — shebang, `set -euo
pipefail`, usage/help block, argument parsing (`-s scope`, `-g ghe_hostname`,
`-n runner_name`, `-l labels`, `-r runner_group`, `-t token`,
`-d disableupdate`, `-f replace`), platform guard (must be macOS), and a
`require_sudo` check.

**Expected Outcomes**
- `scripts/setup-macos-runner.zsh` exists and is executable.
- Running `./setup-macos-runner.zsh -h` prints usage and exits cleanly.
- Running on Linux aborts with a clear error message.
- Running without root / sudo aborts with a clear error message (user
  creation requires elevated privileges).

**Todo List**
1. Create `scripts/setup-macos-runner.zsh` with `#!/bin/zsh` and
   `set -euo pipefail`.
2. Add a `usage()` function documenting all flags and the `RUNNER_CFG_PAT`
   environment variable, modelled on the usage block in
   [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:44).
3. Add `zparseopts` parsing for `-s:`, `-g:`, `-n:`, `-r:`, `-l:`,
   `-t:`, `-d`, `-f`, `-h`. Assign each option to a local variable; print
   usage and exit `0` on `-h`.
4. Apply default: `runner_name=${runner_name:-$(hostname)}`.
5. Add a `fatal()` helper identical to
   [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:93).
6. Add a platform guard: `uname` must return `Darwin`; abort otherwise.
7. Add a `require_sudo` check: `id -u` must equal `0`; abort with
   `"Must run as root or via sudo (required for dscl user/group creation)"`.
8. `chmod +x scripts/setup-macos-runner.zsh`.

**Relevant Context**
- `-u svc_user` flag is removed: the service user is always `gh-runner`,
  matching the s390x convention and removing an operator footgun.
- `zparseopts` is the idiomatic Zsh option parser (man `zshmodules`);
  it is preferred over POSIX `getopts` in Zsh scripts.
- `#!/bin/zsh` is used instead of `#!/usr/bin/env zsh` because `/bin/zsh`
  is the guaranteed System Integrity Protection (SIP)-protected path on all
  macOS versions since Catalina; using the absolute path avoids any
  `PATH`-manipulation attacks.

**Status**: [ ] pending

---

### Sub-Task 2 — Validate prerequisites

**Intent**: Confirm all tools the script depends on (`curl`, `jq`,
`sw_vers`) are on `PATH` and print the macOS version for operator
visibility, before any network or filesystem work begins.

**Expected Outcomes**
- Script aborts early with a helpful message if `curl` or `jq` are missing.
- macOS version (`sw_vers -productVersion`) is printed to stdout so the
  operator can see what host is being configured.
- Architecture (`uname -m`) is detected and stored as `runner_arch`
  (`x64` for `x86_64`, `arm64` for `arm64`) to select the correct tarball.

**Todo List**
1. `(( $+commands[curl] )) || fatal "curl required. Install via Homebrew: brew install curl"`.
2. `(( $+commands[jq] ))   || fatal "jq required.  Install via Homebrew: brew install jq"`.
3. Detect arch using Zsh's `$(uname -m)`:
   ```zsh
   local raw_arch
   raw_arch=$(uname -m)
   local runner_arch=x64
   [[ $raw_arch == arm64 ]] && runner_arch=arm64
   ```
4. Print:
   ```
   macOS $(sw_vers -productVersion) · $raw_arch → runner_arch=$runner_arch
   ```

**Relevant Context**
- `(( $+commands[...] ))` is the idiomatic Zsh way to test for a command
  on `PATH` without a subprocess; it reads the `commands` hash that Zsh
  maintains automatically.
- Arch detection uses `[[ ... ]]` (Zsh extended test) instead of `[ ... ]`
  for consistency with the rest of the script.

**Status**: [ ] pending

---

### Sub-Task 3 — Create the `gh-runner` user, group, and home directory

**Intent**: Create a locked, least-privilege local user `gh-runner` with
primary group `gh-runner`, home directory `/Users/gh-runner`, and a
`/bin/zsh` login shell using macOS Directory Services (`dscl`), then
create `/Users/gh-runner/actions-runner` owned by that user.

**Expected Outcomes**
- `dscl . -read /Users/gh-runner` shows the user with
  `NFSHomeDirectory: /Users/gh-runner` and `UserShell: /bin/zsh`.
- `dscl . -read /Groups/gh-runner` shows a matching group.
- `/Users/gh-runner/actions-runner` exists and is owned
  `gh-runner:gh-runner` with mode `750`.
- The user is **not** in the `admin` group or any other elevated group.
- Re-running the script is idempotent (user/group creation skipped if they
  already exist).

**Todo List**
1. Choose a unique UID/GID ≥ 500 (macOS local accounts convention).
   Scan existing UIDs with `dscl . -list /Users UniqueID` and pick the
   next free value above 500; store as `GH_UID`.  Use the same value for
   the GID (`GH_GID`).
2. Create the group if absent:
   ```zsh
   if ! dscl . -read /Groups/gh-runner &>/dev/null; then
     dscl . -create /Groups/gh-runner
     dscl . -create /Groups/gh-runner PrimaryGroupID "$GH_GID"
   fi
   ```
3. Create the user if absent:
   ```zsh
   if ! dscl . -read /Users/gh-runner &>/dev/null; then
     dscl . -create /Users/gh-runner
     dscl . -create /Users/gh-runner UniqueID      "$GH_UID"
     dscl . -create /Users/gh-runner PrimaryGroupID "$GH_GID"
     dscl . -create /Users/gh-runner UserShell      /bin/zsh
     dscl . -create /Users/gh-runner RealName       "GitHub Actions Runner"
     dscl . -create /Users/gh-runner NFSHomeDirectory /Users/gh-runner
     dscl . -create /Users/gh-runner Password       "*"   # locked/no password
   fi
   ```
4. Create the home directory:
   ```zsh
   install -d -m 755 -o gh-runner -g gh-runner /Users/gh-runner
   ```
5. Create the `actions-runner` subdirectory:
   ```zsh
   install -d -m 750 -o gh-runner -g gh-runner /Users/gh-runner/actions-runner
   ```
6. Set `RUNNER_DIR=/Users/gh-runner/actions-runner`.
7. If `${RUNNER_DIR}/run.sh` already exists and `-f` is not set, `fatal`
   with message:
   `"Runner already installed at ${RUNNER_DIR}. Pass -f to replace."`.

**Relevant Context**
- macOS does not have `useradd`/`groupadd`; the equivalent is `dscl`
  (Directory Service command-line utility). This mirrors the approach used
  by Homebrew's service installer and other macOS provisioning tools.
- `Password "*"` in `dscl` sets a locked/disabled password (equivalent to
  `passwd --lock` on Linux), preventing interactive login.
- UID/GID ≥ 500 is the macOS convention for local (non-system) accounts;
  UIDs below 500 are reserved for Apple system services.
- Unlike the Linux plan which uses `useradd --system` (UID < 1000),
  macOS Directory Services assigns system users UIDs < 500; choosing ≥ 500
  keeps the account visible in System Settings while remaining
  non-privileged.

**Status**: [ ] pending

---

### Sub-Task 4 — Download the runner tarball

**Intent**: Query the GitHub Releases API for the latest runner version and
download `actions-runner-osx-{runner_arch}-{version}.tar.gz` into the
current working directory, skipping the download if the file already exists.

**Expected Outcomes**
- After this step, `runner_file` holds the local filename and the file
  exists on disk.
- If the file is already present (e.g. re-run), the download is skipped and
  a notice is printed.
- The downloaded filename matches the pattern
  `actions-runner-osx-{x64|arm64}-{version}.tar.gz`.

**Todo List**
1. Fetch the latest release tag:
   ```zsh
   local latest_label
   latest_label=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
                  | jq -r '.tag_name')
   local latest_version=${latest_label[2,-1]}   # strip leading 'v' (Zsh slice)
   ```
2. Compose the filename and URL:
   ```zsh
   local runner_file="actions-runner-osx-${runner_arch}-${latest_version}.tar.gz"
   local runner_url="https://github.com/actions/runner/releases/download/${latest_label}/${runner_file}"
   ```
3. If `$runner_file` exists locally, print `"${runner_file} exists. skipping download."`.
4. Otherwise `curl -O -L "${runner_url}"` and print the URL being downloaded.
5. Verify the file exists after download; `fatal` if not.

**Relevant Context**
- Mirrors the download block in
  [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:143) lines
  143-156, with `runner_plat` fixed to `osx`.
- macOS tarball naming uses `osx` (not `darwin` or `macos`), matching the
  existing release asset naming convention used by the runner project.

**Status**: [ ] pending

---

### Sub-Task 5 — Extract the tarball into `actions-runner`

**Intent**: Unpack the tarball into `$RUNNER_DIR` so that `config.sh`,
`svc.sh`, `run.sh`, and `bin/` are all at the expected paths.

**Expected Outcomes**
- `${RUNNER_DIR}/run.sh` and `${RUNNER_DIR}/bin/Runner.Listener` exist after
  extraction.
- If the runner directory already contained files and `-f` replace is set,
  extraction succeeds without error.

**Todo List**
1. Print `"Extracting ${runner_file} to ${RUNNER_DIR}"`.
2. Extract:
   ```zsh
   tar xzf "./${runner_file}" -C "${RUNNER_DIR}"
   ```
3. Fix ownership (script runs as root):
   ```zsh
   chown -R gh-runner:gh-runner "${RUNNER_DIR}"
   ```
4. Verify `${RUNNER_DIR}/run.sh` exists; `fatal "Extraction failed"` if not.

**Relevant Context**
- Pattern: [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:166)
  lines 166-169 (`tar xzf` + `chown -R`).
- The script runs as root (Sub-Task 1 `require_sudo` check), so `chown`
  is both possible and necessary — mirroring Sub-Task 4 of the s390x plan.

**Status**: [ ] pending

---

### Sub-Task 6 — Configure the runner (`config.sh`)

**Intent**: Run `config.sh` from inside `$RUNNER_DIR` to register the
runner with GitHub (or GHE), using the token supplied via `RUNNER_CFG_PAT`
or the `-t` flag.

**Expected Outcomes**
- The runner is registered at the specified scope URL.
- `${RUNNER_DIR}/.runner` credential file exists after config.
- Config runs as `gh-runner` (not root).
- If both `RUNNER_CFG_PAT` and `-t <token>` are absent, the script aborts
  before making any API call.

**Todo List**
1. Validate required inputs: `-s` scope must be set; either `RUNNER_CFG_PAT`
   or `-t <token>` must be provided; `fatal` otherwise.
2. Determine `RUNNER_URL`:
   - If `-g ghe_hostname` is set → `https://<ghe_hostname>/<scope>`
   - Otherwise → `https://github.com/<scope>`
3. Determine `base_api_url`:
   - Default `https://api.github.com`
   - If `-g ghe_hostname` → `https://<ghe_hostname>/api/v3`
   (mirrors [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:121)
   lines 121-124).
4. Resolve the registration token:
   - If `-t <token>` was passed, use it directly as `RUNNER_TOKEN`.
   - Otherwise: derive `orgs_or_repos` from whether `runner_scope` contains
     `/`, then exchange `RUNNER_CFG_PAT` via:
     ```zsh
     local RUNNER_TOKEN
     RUNNER_TOKEN=$(curl -s -X POST \
       "${base_api_url}/${orgs_or_repos}/${runner_scope}/actions/runners/registration-token" \
       -H "accept: application/vnd.github.everest-preview+json" \
       -H "authorization: token ${RUNNER_CFG_PAT}" | jq -r '.token')
     ```
     (mirrors [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:132)
     line 132).
5. `fatal` if `RUNNER_TOKEN` is empty or `"null"`.
6. `cd "${RUNNER_DIR}"` then run `config.sh` **as `gh-runner`**:
   ```zsh
   sudo -u gh-runner ./config.sh \
     --unattended \
     --url  "$RUNNER_URL" \
     --token "$RUNNER_TOKEN" \
     --name "${runner_name}" \
     --labels "self-hosted,macOS,${runner_arch}${labels:+,$labels}" \
     ${runner_group:+--runnergroup "$runner_group"} \
     ${replace:+--replace} \
     ${disableupdate:+--disableupdate}
   ```
7. Confirm `${RUNNER_DIR}/.runner` was created; `fatal` if not.

**Relevant Context**
- Pattern: [`scripts/create-latest-svc.sh`](scripts/create-latest-svc.sh:176)
  lines 176-184 (URL construction + `config.sh` invocation).
- `sudo -u gh-runner` mirrors Sub-Task 5 step 6 of the s390x plan
  (`sudo -E -u gh-runner ./config.sh`); `-E` is omitted here because
  `RUNNER_TOKEN` is passed explicitly on the command line.
- Labels `self-hosted,macOS,x64` or `self-hosted,macOS,arm64` match the
  conventional job matrix labels used for macOS runners in GitHub Actions
  workflows.

**Status**: [ ] pending

---

### Sub-Task 7 — Install and load the launchd LaunchAgent (`svc.sh`)

**Intent**: Install the runner as a launchd LaunchAgent for the `gh-runner`
user using `svc.sh`, then load it so it starts immediately and auto-loads
on future logins of that user.

**Expected Outcomes**
- `/Users/gh-runner/Library/LaunchAgents/actions.runner.<org>.<name>.plist`
  exists.
- `launchctl list | grep actions.runner` (run as `gh-runner`) shows the
  service running.
- `/Users/gh-runner/Library/Logs/actions.runner.<org>.<name>/` exists for
  log output.
- The service auto-loads on next `gh-runner` login (`RunAtLoad true` in
  the plist template).
- `svc.sh` is called **as `gh-runner`**, not as root (mandatory for
  launchd user-session agents).

**Todo List**
1. Ensure we are inside `$RUNNER_DIR`.
2. Install the service as `gh-runner`:
   ```zsh
   sudo -u gh-runner ./svc.sh install
   ```
   (`svc.sh` reads `$USER`/`$SUDO_USER` to populate the `{{User}}` token
   in the plist — running via `sudo -u gh-runner` sets `$SUDO_USER` to
   `gh-runner` as expected by
   [`src/Misc/layoutbin/darwin.svc.sh.template`](src/Misc/layoutbin/darwin.svc.sh.template:66).)
3. Load the service as `gh-runner`:
   ```zsh
   sudo -u gh-runner ./svc.sh start
   ```
4. Print status:
   ```zsh
   sudo -u gh-runner ./svc.sh status
   ```
5. Print a success banner, e.g.:
   ```
   ✓ Runner "${runner_name}" installed and running as gh-runner.
     Scope  : ${RUNNER_URL}
     Logs   : /Users/gh-runner/Library/Logs/actions.runner.*/
     Plist  : /Users/gh-runner/Library/LaunchAgents/actions.runner.*.plist
   ```

**Relevant Context**
- `svc.sh` on macOS calls `launchctl load -w` (not `systemctl`):
  [`src/Misc/layoutbin/darwin.svc.sh.template`](src/Misc/layoutbin/darwin.svc.sh.template:82).
- The plist template sets `RunAtLoad true` and `SessionCreate true`:
  [`src/Misc/layoutbin/actions.runner.plist.template`](src/Misc/layoutbin/actions.runner.plist.template:16).
- `darwin.svc.sh.template` line 10 rejects `user_id == 0`; wrapping the
  call in `sudo -u gh-runner` satisfies this constraint while allowing the
  outer script to run as root for user creation.

**Status**: [ ] pending

---

## Key macOS vs Linux Differences

| Concern | Linux (s390x plan) | macOS (this plan) |
|---|---|---|
| Service manager | systemd (`systemctl`) | launchd (`launchctl`) |
| Service descriptor | `.service` unit file | `.plist` in `~/Library/LaunchAgents/` |
| `svc.sh` needs `sudo` | Yes | **No** — must run as the owning user |
| User creation | `useradd --system gh-runner` + `passwd --lock` | `dscl . -create /Users/gh-runner` + `Password "*"` |
| Runner directory | `/home/gh-runner/actions-runner` | `/Users/gh-runner/actions-runner` |
| Platform label in tarball | `linux` | `osx` |
| Platform labels in `config.sh` | `self-hosted,linux,s390x` | `self-hosted,macOS,{x64\|arm64}` |
| Architecture detection | `uname -m` == `s390x` (hardcoded) | `uname -m`: `x86_64` → `x64`, `arm64` → `arm64` |
| Log location | `journalctl -u actions.runner.*` | `~/Library/Logs/actions.runner.*/` |

---

## File To Be Created

| Path | Description |
|---|---|
| `scripts/setup-macos-runner.zsh` | The macOS Zsh setup + LaunchAgent install script |

No existing files are modified.
