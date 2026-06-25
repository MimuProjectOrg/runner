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
#   -r <group>      Runner group (default: Default)
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
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] \
        || fatal "Invalid runner group '${1}'. Use alphanumeric characters, hyphens, underscores, or dots only."
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
runner_group="${runner_group:-Default}"

validate_runner_name "$runner_name"
validate_runner_group "$runner_group"

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
    latest_version=${latest_label[2,-1]}   # strip leading 'v' (Zsh 1-based slice)

    runner_file="actions-runner-osx-${runner_arch}-${latest_version}.tar.gz"
    runner_url="https://github.com/actions/runner/releases/download/${latest_label}/${runner_file}"
    if [[ -f "${runner_file}" ]]; then
        info "${runner_file} exists. skipping download."
    else
        info "Downloading ${runner_file} ..."
        info "${runner_url}"
        curl "${CURL_OPTS[@]}" -O "${runner_url}"
    fi

    [[ -f "${runner_file}" ]] || fatal "Tarball not found after download: ${runner_file}"

    # Sub-Task 5: Extract tarball --------------------------------------------

    info "Extracting ${runner_file} to ${RUNNER_DIR}"
    tar xzf "./${runner_file}" -C "${RUNNER_DIR}"

    [[ -f "${RUNNER_DIR}/run.sh" ]] || fatal "Extraction failed — run.sh not found in ${RUNNER_DIR}"
    rm -f "./${runner_file}" "./${runner_file}.sha256"
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
    elif [[ -n "$reg_token" ]]; then
        RUNNER_TOKEN="$reg_token"
        info "Using supplied registration token"
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
    (
        cd "${RUNNER_DIR}"

        if [[ -n "$replace" && -f .runner ]]; then
            if [[ -f .service ]]; then
                info "Uninstalling existing service (-f specified)"
                ./svc.sh uninstall
            fi

            info "Removing existing local runner configuration (-f specified)"
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
    unset RUNNER_TOKEN

    [[ -f "${RUNNER_DIR}/.runner" ]] \
        || fatal "config.sh completed but .runner credentials file was not created"

    info "Runner configured successfully"

    # Sub-Task 7: Install and load the launchd LaunchAgent (svc.sh) ----------

    export HOME=/Users/gh-runner
    install -d -m 700 "${HOME}/Library"
    install -d -m 700 "${HOME}/Library/LaunchAgents"
    install -d -m 700 "${HOME}/Library/Logs"

    info "Installing launchd LaunchAgent"
    (cd "${RUNNER_DIR}" && ./svc.sh install)

    info "Starting service"
    (cd "${RUNNER_DIR}" && ./svc.sh start)

    info "Service status"
    svc_status=$(cd "${RUNNER_DIR}" && ./svc.sh status)
    print -- "${svc_status}"

    # svc.sh status output format varies across runner versions and macOS
    # releases; query launchd directly for a stable check: a running service
    # has a numeric PID (not '-') in the first column of launchctl list.
    launchctl list \
        | awk '$1 ~ /^[0-9]+/ && $3 ~ /^actions\.runner\./{found=1} END{exit !found}' \
        || fatal "Runner service did not start successfully"

    print ""
    print "======================================================"
    print "  GitHub Actions runner installed and running"
    print "  Name  : ${runner_name}"
    print "  Scope : ${RUNNER_URL}"
    print "  Labels: ${ALL_LABELS}"
    print "  User  : gh-runner"
    print "  Dir   : ${RUNNER_DIR}"
    print "  Logs  : /Users/gh-runner/Library/Logs/actions.runner.*/"
    print "  Plist : /Users/gh-runner/Library/LaunchAgents/actions.runner.*.plist"
    print "======================================================"
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
# M1: Drop root — re-exec the remainder of the script as gh-runner.
# Pass all parsed options explicitly so phase 2 does not need to re-parse
# from an untrusted environment.
# RUNNER_CFG_PAT is forwarded via sudo -E (only that variable is preserved).
# ---------------------------------------------------------------------------

info "Dropping root — continuing as gh-runner"

export HOME=/Users/gh-runner

if [[ -n "$reg_token" ]]; then
    export PHASE2_REG_TOKEN="$reg_token"
fi

# Build the argument list for the re-exec from the already-validated variables.
reexec_args=( --_continue -s "$runner_scope" )
[[ -n "$ghe_hostname" ]] && reexec_args+=( -g "$ghe_hostname" )
[[ -n "$runner_name"  ]] && reexec_args+=( -n "$runner_name"  )
[[ -n "$labels"       ]] && reexec_args+=( -l "$labels"       )
[[ -n "$runner_group" ]] && reexec_args+=( -r "$runner_group" )
[[ -n "$disableupdate" ]] && reexec_args+=( -d )
[[ -n "$replace"      ]] && reexec_args+=( -f )

# sudo -E forwards only variables that are already in the environment.
# RUNNER_CFG_PAT is unsurprisingly already there when set by the operator;
# it will be unset inside phase 2 immediately after the token exchange.
exec sudo -u gh-runner -E /bin/zsh "${SCRIPT_PATH}" "${reexec_args[@]}"
