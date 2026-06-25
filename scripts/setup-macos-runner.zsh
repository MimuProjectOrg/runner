#!/bin/zsh
# setup-macos-runner.zsh — Create the gh-runner local user, download the
# latest actions-runner tarball, configure it with GitHub, and install it
# as a launchd LaunchAgent running in the gh-runner user session.
#
# Usage:
#   sudo RUNNER_CFG_PAT=<pat> ./setup-macos-runner.zsh -s <scope> [options]
#   sudo ./setup-macos-runner.zsh -s <scope> -t <registration-token> [options]
#
# Options:
#   -s <scope>      Required. org (myorg) or repo (myorg/myrepo)
#   -t <token>      Pre-generated runner registration token (skips PAT exchange)
#   -g <ghe_host>   GitHub Enterprise Server hostname (omit for github.com)
#   -n <name>       Runner name (default: hostname)
#   -l <labels>     Extra labels appended to self-hosted,macOS,{arch}
#   -r <group>      Runner group (omit to use the GitHub API default)
#   -d              Disable automatic runner updates for one month
#   -f              Replace an existing runner with the same name
#   -h              Show this help
#
# Environment:
#   RUNNER_CFG_PAT  GitHub PAT with manage_runners:org or repo scope.
#                   Required unless -t is supplied.

set -euo pipefail

# Capture script path at top level before $0 is shadowed inside functions.
SCRIPT_PATH="${0:A}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fatal() {
    print -u2 "error: $1"
    exit 1
}

info() {
    print "==> $*"
}

usage() {
    sed -n '6,24p' "${SCRIPT_PATH}" | sed 's/^# \{0,1\}//'
    exit 0
}

# M2: Validate operator-supplied inputs against strict patterns.
# Accepted: alphanumeric, hyphens, underscores, dots.  Repo scope allows one slash.
validate_scope() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]] \
        || fatal "Invalid scope '${1}'. Expected org (myorg) or repo (myorg/myrepo)."
}
validate_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ ]] \
        || fatal "Invalid GHE hostname '${1}'. Must be a plain hostname with no scheme or path."
}
validate_labels() {
    # Each comma-separated label: alphanumeric, hyphens, underscores, dots
    [[ "$1" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] \
        || fatal "Invalid labels '${1}'. Use comma-separated alphanumeric identifiers."
}

validate_runner_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] \
        || fatal "Invalid runner name '${1}'. Use alphanumeric characters, hyphens, underscores, or dots only."
}

validate_runner_group() {
    # Must start and end with alphanumeric/._-; internal spaces allowed.
    [[ "$1" =~ ^[A-Za-z0-9._-]([A-Za-z0-9 ._-]*[A-Za-z0-9._-])?$ ]] \
        || fatal "Invalid runner group '${1}'. Must not have leading/trailing spaces; use alphanumeric, hyphens, underscores, dots, or internal spaces."
}

# ---------------------------------------------------------------------------
# M1: Privileged bootstrap vs. unprivileged runner-install phases.
#
# When the script is invoked as root (phase 1) it:
#   - Creates the gh-runner user/group
#   - Creates the home and actions-runner directories
#   - Re-executes itself as gh-runner (phase 2) for all network/install work
#
# Phase 2 is triggered by the internal --_continue flag; it must never be
# called directly by the operator.
# ---------------------------------------------------------------------------

PHASE2=0
[[ "${1:-}" == "--_continue" ]] && { PHASE2=1; shift; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

runner_scope=""
reg_token=""
ghe_hostname=""
runner_name=""
labels=""
runner_group=""
disableupdate=""
replace=""

zparseopts -D -E \
    s:=_s g:=_g n:=_n l:=_l r:=_r t:=_t \
    d=_d f=_f h=_h -help=_help \
    || { usage; exit 1 }

# Help is checked before any guards so it works without sudo.
[[ ${#_h} -gt 0 || ${#_help} -gt 0 ]] && usage

[[ ${#_s} -gt 0 ]] && runner_scope=${_s[2]}
[[ ${#_g} -gt 0 ]] && ghe_hostname=${_g[2]}
[[ ${#_n} -gt 0 ]] && runner_name=${_n[2]}
[[ ${#_l} -gt 0 ]] && labels=${_l[2]}
[[ ${#_r} -gt 0 ]] && runner_group=${_r[2]}
[[ ${#_t} -gt 0 ]] && reg_token=${_t[2]}
[[ ${#_d} -gt 0 ]] && disableupdate=true
[[ ${#_f} -gt 0 ]] && replace=true

runner_name="${runner_name:-$(hostname)}"

validate_runner_name "$runner_name"
[[ -z "$runner_group" ]] || validate_runner_group "$runner_group"

# ---------------------------------------------------------------------------
# Guards — platform (after -h so help works without sudo)
# ---------------------------------------------------------------------------

[[ "$(uname)" == "Darwin" ]] \
    || fatal "This script must run on macOS (detected: $(uname))"

# ---------------------------------------------------------------------------
# Validate operator-supplied inputs (M2) — before any network or fs work
# ---------------------------------------------------------------------------

[[ -n "$runner_scope" ]] \
    || fatal "Supply the runner scope with -s (e.g. -s myorg or -s myorg/myrepo)"

validate_scope "$runner_scope"
[[ -n "$ghe_hostname" ]] && validate_hostname "$ghe_hostname"
[[ -n "$labels"       ]] && validate_labels  "$labels"

[[ -n "$reg_token" || -n "${RUNNER_CFG_PAT:-}" || -n "${PHASE2_REG_TOKEN:-}" ]] \
    || fatal "Supply either -t <registration-token> or export RUNNER_CFG_PAT=<pat>"

# ---------------------------------------------------------------------------
# Phase 2 (unprivileged) — entered via re-exec as gh-runner
# ---------------------------------------------------------------------------

if [[ $PHASE2 -eq 1 ]]; then
    # Prerequisites and arch (Sub-Task 2)
    (( $+commands[curl] )) || fatal "curl required. Install via Homebrew: brew install curl"
    (( $+commands[jq] ))   || fatal "jq required.  Install via Homebrew: brew install jq"

    raw_arch=$(uname -m)
    runner_arch=x64
    [[ $raw_arch == arm64 ]] && runner_arch=arm64

    info "macOS $(sw_vers -productVersion) · ${raw_arch} → runner_arch=${runner_arch}"

    RUNNER_DIR=/Users/gh-runner/actions-runner

    # Sub-Task 4: Download the runner tarball --------------------------------

    # Work inside RUNNER_DIR so curl -O and tar write where gh-runner has
    # permission (inherited CWD from the root phase may not be writable).
    cd "${RUNNER_DIR}"

    # M3: Enforce HTTPS-only, minimum TLS 1.2 on every curl call.
    CURL_OPTS=( --proto '=https' --tlsv1.2 --connect-timeout 30 --max-time 120 -fsSL )

    latest_label=$(curl "${CURL_OPTS[@]}" \
        https://api.github.com/repos/actions/runner/releases/latest \
        | jq -r '.tag_name')

    [[ "$latest_label" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fatal "Unexpected tag from GitHub API: '${latest_label}' — check network and rate limits"

    latest_version=${latest_label[2,-1]}   # strip leading 'v' (Zsh 1-based slice)

    runner_file="actions-runner-osx-${runner_arch}-${latest_version}.tar.gz"
    runner_url="https://github.com/actions/runner/releases/download/${latest_label}/${runner_file}"
    if [[ -f "${runner_file}" ]]; then
        info "${runner_file} exists — skipping download."
    else
        info "Downloading ${runner_file} ..."
        info "${runner_url}"
        curl "${CURL_OPTS[@]}" -O "${runner_url}"
        [[ -f "${runner_file}" ]] || fatal "Tarball not found after download: ${runner_file}"

        # Sub-Task 5: Verify checksum (only for fresh downloads; cached
        # files were verified on the previous run).
        info "Verifying SHA256 checksum ..."
        if curl "${CURL_OPTS[@]}" -o "./${runner_file}.sha256" "${runner_url}.sha256"; then
            shasum -a 256 -c "./${runner_file}.sha256" \
                || fatal "SHA256 mismatch — tarball may be corrupt or tampered: ${runner_file}"
            rm -f "./${runner_file}.sha256"
        else
            info "WARNING: SHA256 file not available from GitHub — checksum skipped"
        fi
    fi

    info "Extracting ${runner_file} to ${RUNNER_DIR}"
    tar xzf "./${runner_file}" -C "${RUNNER_DIR}"

    [[ -f "${RUNNER_DIR}/run.sh" ]] || fatal "Extraction failed — run.sh not found in ${RUNNER_DIR}"
    rm -f "./${runner_file}"
    info "Extraction complete"

    # Sub-Task 6: Configure the runner (config.sh) ---------------------------

    if [[ -n "$ghe_hostname" ]]; then
        RUNNER_URL="https://${ghe_hostname}/${runner_scope}"
        BASE_API_URL="https://${ghe_hostname}/api/v3"
    else
        RUNNER_URL="https://github.com/${runner_scope}"
        BASE_API_URL="https://api.github.com"
    fi

    if [[ -n "${PHASE2_REG_TOKEN:-}" ]]; then
        RUNNER_TOKEN="${PHASE2_REG_TOKEN}"
        info "Using supplied registration token"
        unset PHASE2_REG_TOKEN
        unset RUNNER_CFG_PAT
    elif [[ -n "$reg_token" ]]; then
        RUNNER_TOKEN="$reg_token"
        info "Using supplied registration token"
        unset RUNNER_CFG_PAT
    else
        info "Exchanging RUNNER_CFG_PAT for a registration token"

        if [[ "$runner_scope" == */* ]]; then
            orgs_or_repos="repos"
        else
            orgs_or_repos="orgs"
        fi

        RUNNER_TOKEN=$(
            curl "${CURL_OPTS[@]}" -X POST \
                "${BASE_API_URL}/${orgs_or_repos}/${runner_scope}/actions/runners/registration-token" \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: token ${RUNNER_CFG_PAT}" \
            | jq -r '.token'
        )

        # H1: Scrub the PAT from the environment immediately after use.
        unset RUNNER_CFG_PAT

        [[ "$RUNNER_TOKEN" != "null" && -n "$RUNNER_TOKEN" ]] \
            || fatal "Failed to obtain a registration token — check RUNNER_CFG_PAT and scope"
    fi

    ALL_LABELS="self-hosted,macOS,${runner_arch}${labels:+,$labels}"

    info "Configuring runner '${runner_name}' at ${RUNNER_URL}"
    info "Labels: ${ALL_LABELS}"

    # L1: Pass the registration token via env var so it does not appear in
    #     `ps aux` output. ACTIONS_RUNNER_INPUT_TOKEN is read by config.sh
    #     when --token is omitted.
    # Trap ensures RUNNER_TOKEN is scrubbed even if config.sh exits non-zero
    # and set -e kills the parent before the unconditional unset below.
    trap 'unset RUNNER_TOKEN' EXIT INT TERM
    (
        cd "${RUNNER_DIR}"

        if [[ -n "$replace" && -f .runner ]]; then
            info "Removing existing local runner configuration (-f specified)"
            # svc.sh uninstall must precede config.sh remove; config.sh refuses
            # to deregister while a service is still installed. In a non-GUI
            # session svc.sh's launchctl calls query the wrong domain and report
            # "not installed", so they exit without removing the .service marker
            # file. Remove it explicitly so config.sh remove can proceed.
            ./svc.sh uninstall 2>/dev/null || true
            rm -f .service
            ACTIONS_RUNNER_INPUT_TOKEN="${RUNNER_TOKEN}" ./config.sh remove
        fi

        ACTIONS_RUNNER_INPUT_TOKEN="${RUNNER_TOKEN}" \
        ./config.sh \
            --unattended \
            --url    "${RUNNER_URL}" \
            --name   "${runner_name}" \
            --labels "${ALL_LABELS}" \
            ${runner_group:+--runnergroup} ${runner_group:+"${runner_group}"} \
            ${replace:+--replace} \
            ${disableupdate:+--disableupdate}
    )
    trap - EXIT INT TERM
    unset RUNNER_TOKEN

    [[ -f "${RUNNER_DIR}/.runner" ]] \
        || fatal "config.sh completed but .runner credentials file was not created"

    info "Runner configured successfully"

    # Sub-Task 7: Create Library dirs and write the launchd plist -------------
    # svc.sh install generates a LaunchAgent plist in ~/Library/LaunchAgents/.
    # Phase 1 (root) will convert it to a LaunchDaemon and bootstrap it —
    # gh-runner is headless (no GUI session), so the gui/<uid> domain never
    # exists and LaunchAgents cannot be used.

    export HOME=/Users/gh-runner
    install -d -m 700 "${HOME}/Library"
    install -d -m 700 "${HOME}/Library/LaunchAgents"
    install -d -m 700 "${HOME}/Library/Logs"

    info "Installing launchd plist via svc.sh"
    (cd "${RUNNER_DIR}" && ./svc.sh install)

    [[ -n "$(find "${HOME}/Library/LaunchAgents" -maxdepth 1 \
              -name 'actions.runner.*.plist' 2>/dev/null | head -1)" ]] \
        || fatal "svc.sh install did not create a LaunchAgent plist"

    exit 0
fi

# ---------------------------------------------------------------------------
# Phase 1 (root) — user/group/directory bootstrap
# ---------------------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] \
    || fatal "Must run as root or via sudo (required for dscl user/group creation)"

# Sub-Task 2: prerequisites check runs in phase 1 so we fail fast ------------

(( $+commands[curl] )) || fatal "curl required. Install via Homebrew: brew install curl"
(( $+commands[jq] ))   || fatal "jq required.  Install via Homebrew: brew install jq"

raw_arch=$(uname -m)
runner_arch=x64
[[ $raw_arch == arm64 ]] && runner_arch=arm64

info "macOS $(sw_vers -productVersion) · ${raw_arch} → runner_arch=${runner_arch}"

# Sub-Task 3: Create gh-runner group, user, home, and actions-runner dir -----

RUNNER_DIR=/Users/gh-runner/actions-runner

# Serialize GID/UID allocation: mkdir is atomic so two concurrent runs
# cannot both observe the same free ID and then race on dscl -create.
_lock_dir=/var/run/gh-runner-setup.lock
if ! mkdir "$_lock_dir" 2>/dev/null; then
    fatal "Another gh-runner setup is running. Remove ${_lock_dir} if stale."
fi
trap 'rmdir "$_lock_dir" 2>/dev/null' EXIT INT TERM

info "Ensuring group gh-runner exists"
if ! dscl . -read /Groups/gh-runner &>/dev/null; then
    GH_GID=$(dscl . -list /Groups PrimaryGroupID \
        | awk '{print $2}' \
        | sort -n \
        | awk 'BEGIN{g=500} $1>=g{if($1==g)g++} END{print g}')
    dscl . -create /Groups/gh-runner
    dscl . -create /Groups/gh-runner PrimaryGroupID "$GH_GID"
    info "Created group gh-runner (GID ${GH_GID})"
else
    GH_GID=$(dscl . -read /Groups/gh-runner PrimaryGroupID | awk '{print $2}')
    info "Group gh-runner already exists (GID ${GH_GID}) — skipping"
fi

info "Ensuring user gh-runner exists"
if ! dscl . -read /Users/gh-runner &>/dev/null; then
    GH_UID=$(dscl . -list /Users UniqueID \
        | awk '{print $2}' \
        | sort -n \
        | awk 'BEGIN{u=500} $1>=u{if($1==u)u++} END{print u}')
    dscl . -create /Users/gh-runner
    dscl . -create /Users/gh-runner UniqueID         "$GH_UID"
    dscl . -create /Users/gh-runner PrimaryGroupID   "$GH_GID"
    dscl . -create /Users/gh-runner UserShell        /bin/zsh
    dscl . -create /Users/gh-runner RealName         "GitHub Actions Runner"
    dscl . -create /Users/gh-runner NFSHomeDirectory /Users/gh-runner
    dscl . -create /Users/gh-runner Password         "*"
    info "Created user gh-runner (UID ${GH_UID}, locked password)"
else
    info "User gh-runner already exists — skipping"
fi

rmdir "$_lock_dir"
trap - EXIT INT TERM

info "Ensuring /Users/gh-runner home directory exists"
# L2: mode 700 — home is private to gh-runner only (matches macOS default drwx------).
install -d -m 700 -o gh-runner -g gh-runner /Users/gh-runner

info "Ensuring ${RUNNER_DIR} exists"
install -d -m 750 -o gh-runner -g gh-runner "${RUNNER_DIR}"

# Idempotency guard: check for existing installation before dropping privileges.
if [[ -f "${RUNNER_DIR}/run.sh" ]]; then
    if [[ -z "$replace" ]]; then
        fatal "Runner already installed at ${RUNNER_DIR}. Pass -f to replace."
    fi
    info "Replacing existing runner files (-f specified)"
fi

# ---------------------------------------------------------------------------
# M1: Drop root — run phase 2 as gh-runner, then install service here.
# Phase 2 (download/config/plist-write) runs as gh-runner via a subprocess.
# Service management stays in phase 1 (root) because gh-runner is a headless
# account that never creates a GUI session, so the gui/<uid> launchd domain
# does not exist. We use a LaunchDaemon (system domain, always available) with
# UserName=gh-runner rather than a LaunchAgent (user domain).
# ---------------------------------------------------------------------------

# If replacing, stop and remove the existing LaunchDaemon before phase 2
# deregisters the runner, so launchd terminates the old process cleanly.
if [[ -n "$replace" ]]; then
    _old_plist=$(find /Library/LaunchDaemons -maxdepth 1 \
                 -name 'actions.runner.*.plist' 2>/dev/null | head -1)
    if [[ -n "${_old_plist:-}" ]]; then
        info "Stopping existing service before replacement (-f specified)"
        launchctl bootout system "${_old_plist}" 2>/dev/null || true
        rm -f "${_old_plist}"
    fi
fi

info "Dropping root — running phase 2 as gh-runner"

# Build the argument list for phase 2 from the already-validated variables.
reexec_args=( --_continue -s "$runner_scope" )
[[ -n "$ghe_hostname" ]] && reexec_args+=( -g "$ghe_hostname" )
[[ -n "$runner_name"  ]] && reexec_args+=( -n "$runner_name"  )
[[ -n "$labels"       ]] && reexec_args+=( -l "$labels"       )
[[ -n "$runner_group" ]] && reexec_args+=( -r "$runner_group" )
[[ -n "$disableupdate" ]] && reexec_args+=( -d )
[[ -n "$replace"      ]] && reexec_args+=( -f )

# Minimal environment: only what phase 2 actually needs.
# env -i prevents DYLD_*, poisoned PATH, and other caller vars from leaking in.
# USER is required by svc.sh's plist template substitution (${USER:-$SUDO_USER}).
phase2_env=(
    HOME=/Users/gh-runner
    USER=gh-runner
    PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
)
[[ -n "${RUNNER_CFG_PAT:-}" ]] && phase2_env+=( "RUNNER_CFG_PAT=${RUNNER_CFG_PAT}" )
[[ -n "$reg_token"          ]] && phase2_env+=( "PHASE2_REG_TOKEN=${reg_token}" )

sudo -u gh-runner env -i "${phase2_env[@]}" /bin/zsh "${SCRIPT_PATH}" "${reexec_args[@]}"

# ---------------------------------------------------------------------------
# Sub-Task 7 (root): Convert the LaunchAgent plist svc.sh wrote into a
# LaunchDaemon so the runner starts at boot without requiring a GUI login.
# PlistBuddy adds UserName=gh-runner and removes SessionCreate (unsupported
# in the system domain). The daemon is then bootstrapped immediately.
# ---------------------------------------------------------------------------

GH_LA_PLIST=$(find /Users/gh-runner/Library/LaunchAgents -maxdepth 1 \
              -name 'actions.runner.*.plist' 2>/dev/null | head -1)
[[ -n "${GH_LA_PLIST}" ]] || fatal "LaunchAgent plist not found after phase 2"
GH_SVC_LABEL="${${GH_LA_PLIST##*/}%.plist}"
GH_LD_PLIST="/Library/LaunchDaemons/${GH_SVC_LABEL}.plist"

cp "${GH_LA_PLIST}" "${GH_LD_PLIST}"
/usr/libexec/PlistBuddy -c "Set :UserName gh-runner" "${GH_LD_PLIST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :UserName string gh-runner" "${GH_LD_PLIST}"
/usr/libexec/PlistBuddy -c "Delete :SessionCreate"          "${GH_LD_PLIST}" 2>/dev/null || true
chown root:wheel "${GH_LD_PLIST}"
chmod 644        "${GH_LD_PLIST}"
rm -f "${GH_LA_PLIST}"

info "Bootstrapping runner service in system launchd domain"
launchctl bootstrap system "${GH_LD_PLIST}"

info "Waiting for runner service to start ..."
_started=0
for _i in {1..10}; do
    launchctl print "system/${GH_SVC_LABEL}" 2>/dev/null \
        | grep -q 'state = running' && { _started=1; break; }
    sleep 1
done
(( _started )) || fatal "Runner service did not reach 'running' state within 10 seconds"

[[ -n "$ghe_hostname" ]] \
    && RUNNER_URL="https://${ghe_hostname}/${runner_scope}" \
    || RUNNER_URL="https://github.com/${runner_scope}"
ALL_LABELS="self-hosted,macOS,${runner_arch}${labels:+,$labels}"

print ""
print "======================================================"
print "  GitHub Actions runner installed and running"
print "  Name  : ${runner_name}"
print "  Scope : ${RUNNER_URL}"
print "  Labels: ${ALL_LABELS}"
print "  User  : gh-runner"
print "  Dir   : /Users/gh-runner/actions-runner"
print "  Logs  : /Users/gh-runner/Library/Logs/actions.runner.*/"
print "  Plist : ${GH_LD_PLIST}"
print "======================================================"
