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
    sed -n '6,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------------------
# Sub-Task 1: Argument parsing
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
    d=_d f=_f h=_h \
    || { usage; exit 1 }

[[ ${#_h} -gt 0 ]] && usage
[[ ${#_s} -gt 0 ]] && runner_scope=${_s[2]}
[[ ${#_g} -gt 0 ]] && ghe_hostname=${_g[2]}
[[ ${#_n} -gt 0 ]] && runner_name=${_n[2]}
[[ ${#_l} -gt 0 ]] && labels=${_l[2]}
[[ ${#_r} -gt 0 ]] && runner_group=${_r[2]}
[[ ${#_t} -gt 0 ]] && reg_token=${_t[2]}
[[ ${#_d} -gt 0 ]] && disableupdate=true
[[ ${#_f} -gt 0 ]] && replace=true

runner_name="${runner_name:-$(hostname)}"

# ---------------------------------------------------------------------------
# Sub-Task 1: Guards — platform and root
# ---------------------------------------------------------------------------

[[ "$(uname)" == "Darwin" ]] \
    || fatal "This script must run on macOS (detected: $(uname))"

[[ "$(id -u)" -eq 0 ]] \
    || fatal "Must run as root or via sudo (required for dscl user/group creation)"

# ---------------------------------------------------------------------------
# Sub-Task 2: Validate prerequisites and detect architecture
# ---------------------------------------------------------------------------

(( $+commands[curl] )) || fatal "curl required. Install via Homebrew: brew install curl"
(( $+commands[jq] ))   || fatal "jq required.  Install via Homebrew: brew install jq"

raw_arch=$(uname -m)
runner_arch=x64
[[ $raw_arch == arm64 ]] && runner_arch=arm64

info "macOS $(sw_vers -productVersion) · ${raw_arch} → runner_arch=${runner_arch}"

# ---------------------------------------------------------------------------
# Sub-Task 1 (continued): Validate required arguments
# ---------------------------------------------------------------------------

[[ -n "$runner_scope" ]] \
    || fatal "Supply the runner scope with -s (e.g. -s myorg or -s myorg/myrepo)"

[[ -n "$reg_token" || -n "${RUNNER_CFG_PAT:-}" ]] \
    || fatal "Supply either -t <registration-token> or export RUNNER_CFG_PAT=<pat>"

# ---------------------------------------------------------------------------
# Sub-Task 3: Create gh-runner group, user, home, and actions-runner dir
# ---------------------------------------------------------------------------

RUNNER_DIR=/Users/gh-runner/actions-runner

info "Ensuring group gh-runner exists"
if ! dscl . -read /Groups/gh-runner &>/dev/null; then
    # Find the next free GID >= 500
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
    # Find the next free UID >= 500
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
install -d -m 755 -o gh-runner -g gh-runner /Users/gh-runner

info "Ensuring ${RUNNER_DIR} exists"
install -d -m 750 -o gh-runner -g gh-runner "${RUNNER_DIR}"

# ---------------------------------------------------------------------------
# Sub-Task 3 (continued): Idempotency guard
# ---------------------------------------------------------------------------

if [[ -f "${RUNNER_DIR}/run.sh" ]]; then
    if [[ -z "$replace" ]]; then
        fatal "Runner already installed at ${RUNNER_DIR}. Pass -f to replace."
    fi
    info "Replacing existing runner files (-f specified)"
fi

# ---------------------------------------------------------------------------
# Sub-Task 4: Download the runner tarball
# ---------------------------------------------------------------------------

latest_label=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
               | jq -r '.tag_name')
latest_version=${latest_label[2,-1]}   # strip leading 'v' (Zsh 1-based slice)

runner_file="actions-runner-osx-${runner_arch}-${latest_version}.tar.gz"
runner_url="https://github.com/actions/runner/releases/download/${latest_label}/${runner_file}"

if [[ -f "${runner_file}" ]]; then
    info "${runner_file} exists. skipping download."
else
    info "Downloading ${runner_file} ..."
    info "${runner_url}"
    curl -fsSL -O -L "${runner_url}"
fi

[[ -f "${runner_file}" ]] || fatal "Tarball not found after download: ${runner_file}"

# ---------------------------------------------------------------------------
# Sub-Task 5: Extract tarball and fix ownership
# ---------------------------------------------------------------------------

info "Extracting ${runner_file} to ${RUNNER_DIR}"
tar xzf "./${runner_file}" -C "${RUNNER_DIR}"
chown -R gh-runner:gh-runner "${RUNNER_DIR}"

[[ -f "${RUNNER_DIR}/run.sh" ]] || fatal "Extraction failed — run.sh not found in ${RUNNER_DIR}"
info "Extraction complete"

# ---------------------------------------------------------------------------
# Sub-Task 6: Configure the runner (config.sh)
# ---------------------------------------------------------------------------

if [[ -n "$ghe_hostname" ]]; then
    RUNNER_URL="https://${ghe_hostname}/${runner_scope}"
    BASE_API_URL="https://${ghe_hostname}/api/v3"
else
    RUNNER_URL="https://github.com/${runner_scope}"
    BASE_API_URL="https://api.github.com"
fi

if [[ -n "$reg_token" ]]; then
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
        curl -fsSL -X POST \
            "${BASE_API_URL}/${orgs_or_repos}/${runner_scope}/actions/runners/registration-token" \
            -H "Accept: application/vnd.github.everest-preview+json" \
            -H "Authorization: token ${RUNNER_CFG_PAT}" \
        | jq -r '.token'
    )

    [[ "$RUNNER_TOKEN" != "null" && -n "$RUNNER_TOKEN" ]] \
        || fatal "Failed to obtain a registration token — check RUNNER_CFG_PAT and scope"
fi

ALL_LABELS="self-hosted,macOS,${runner_arch}${labels:+,$labels}"

info "Configuring runner '${runner_name}' at ${RUNNER_URL}"
info "Labels: ${ALL_LABELS}"

(
    cd "${RUNNER_DIR}"
    sudo -u gh-runner ./config.sh \
        --unattended \
        --url    "${RUNNER_URL}" \
        --token  "${RUNNER_TOKEN}" \
        --name   "${runner_name}" \
        --labels "${ALL_LABELS}" \
        ${runner_group:+--runnergroup "${runner_group}"} \
        ${replace:+--replace} \
        ${disableupdate:+--disableupdate}
)

[[ -f "${RUNNER_DIR}/.runner" ]] \
    || fatal "config.sh completed but .runner credentials file was not created"

info "Runner configured successfully"

# ---------------------------------------------------------------------------
# Sub-Task 7: Install and load the launchd LaunchAgent (svc.sh)
# ---------------------------------------------------------------------------

info "Installing launchd LaunchAgent"
(cd "${RUNNER_DIR}" && sudo -u gh-runner ./svc.sh install)

info "Starting service"
(cd "${RUNNER_DIR}" && sudo -u gh-runner ./svc.sh start)

info "Service status"
(cd "${RUNNER_DIR}" && sudo -u gh-runner ./svc.sh status)

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------

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
