#!/usr/bin/env bash
# setup-s390x-runner.sh — Create the gh-runner service account, extract the
# actions-runner deliverable, configure it with GitHub, and install it as a
# systemd service.
#
# Primary target: b46lp05.lnxne.boe (Ubuntu 26.04 s390x) — see ADR
#   docs/adrs/4520-linux-s390x-port.md, Gap 1.
#
# Usage:
#   sudo RUNNER_CFG_PAT=<pat> ./setup-s390x-runner.sh -s <scope> [options]
#   sudo ./setup-s390x-runner.sh -s <scope> -t <registration-token> [options]
#
# Options:
#   -s <scope>        Required. org (myorg) or repo (myorg/myrepo)
#   -t <token>        Pre-generated runner registration token (skips PAT exchange)
#   -g <ghe_host>     GitHub Enterprise Server hostname (omit for github.com)
#   -n <name>         Runner name (default: hostname)
#   -l <labels>       Extra labels appended to self-hosted,linux,s390x
#   -r <group>        Runner group (default: Default)
#   -f                Replace an existing runner with the same name
#   -h                Show this help
#
# Environment:
#   RUNNER_CFG_PAT    GitHub PAT with manage_runners:org or repo scope.
#                     Required unless -t is supplied.
#
# The script resolves the deliverable tarball as follows:
#   1. Use the newest _package/actions-runner-linux-s390x-*.tar.gz if present.
#   2. Otherwise build it: bootstrap-s390x-nuget.sh → dev.sh layout → package.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fatal() {
    echo "error: $1" >&2
    exit 1
}

info() {
    echo "==> $*"
}

usage() {
    sed -n '5,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------------------
# M2: Validate operator-supplied inputs against strict patterns.
# Accepted: alphanumeric, hyphens, underscores, dots.  Repo scope allows one slash.
# ---------------------------------------------------------------------------

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
# Argument parsing
# ---------------------------------------------------------------------------

runner_scope=""
reg_token=""
ghe_hostname=""
runner_name=""
labels=""
runner_group=""
replace=""

while getopts 's:t:g:n:l:r:fh' opt; do
    case $opt in
        s) runner_scope=$OPTARG ;;
        t) reg_token=$OPTARG ;;
        g) ghe_hostname=$OPTARG ;;
        n) runner_name=$OPTARG ;;
        l) labels=$OPTARG ;;
        r) runner_group=$OPTARG ;;
        f) replace=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

runner_name="${runner_name:-$(hostname)}"

# ---------------------------------------------------------------------------
# Sub-Task 1 guards: platform, root, required args
# ---------------------------------------------------------------------------

[[ "$(uname -m)" == "s390x" ]] \
    || fatal "This script must run on an s390x host (detected: $(uname -m))"

[[ "$(id -u)" -eq 0 ]] \
    || fatal "Run with sudo or as root"

[[ -n "$runner_scope" ]] \
    || fatal "Supply the runner scope with -s (e.g. -s myorg or -s myorg/myrepo)"

validate_scope        "$runner_scope"
validate_runner_name  "$runner_name"
[[ -n "$ghe_hostname" ]] && validate_hostname  "$ghe_hostname"
[[ -n "$labels"       ]] && validate_labels    "$labels"
[[ -n "$runner_group" ]] && validate_runner_group "$runner_group"

[[ -n "$reg_token" || -n "${RUNNER_CFG_PAT:-}" ]] \
    || fatal "Supply either -t <registration-token> or export RUNNER_CFG_PAT=<pat>"

which curl >/dev/null 2>&1 || fatal "curl is required — install with: apt-get install curl"
which jq   >/dev/null 2>&1 || fatal "jq is required — install with: apt-get install jq"

# Resolve the repo root (directory that contains src/ and _package/)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# Sub-Task 2: Create gh-runner group, user, and actions-runner directory
# ---------------------------------------------------------------------------

RUNNER_HOME="/home/gh-runner"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"

info "Ensuring group gh-runner exists"
if ! getent group gh-runner >/dev/null 2>&1; then
    groupadd --system gh-runner
    info "Created group gh-runner"
else
    info "Group gh-runner already exists — skipping"
fi

info "Ensuring user gh-runner exists"
if ! getent passwd gh-runner >/dev/null 2>&1; then
    useradd \
        --system \
        --gid gh-runner \
        --home-dir "${RUNNER_HOME}" \
        --create-home \
        --shell /bin/bash \
        --comment "GitHub Actions Runner" \
        gh-runner
    passwd --lock gh-runner
    info "Created user gh-runner (locked password, /bin/bash shell)"
else
    info "User gh-runner already exists — skipping"
fi

info "Ensuring ${RUNNER_DIR} exists"
install -d -m 750 -o gh-runner -g gh-runner "${RUNNER_DIR}"

# ---------------------------------------------------------------------------
# Sub-Task 3: Resolve or build the deliverable tarball
# ---------------------------------------------------------------------------

PKG_DIR="${REPO_ROOT}/_package"

find_tarball() {
    # Returns the newest matching tarball path, or empty string
    ls -t "${PKG_DIR}"/actions-runner-linux-s390x-*.tar.gz 2>/dev/null | head -1 || true
}

TARBALL="$(find_tarball)"

if [[ -z "$TARBALL" ]]; then
    info "No tarball found in ${PKG_DIR} — building from source"

    BOOTSTRAP="${REPO_ROOT}/src/Misc/bootstrap-s390x-nuget.sh"
    [[ -f "$BOOTSTRAP" ]] \
        || fatal "Expected bootstrap script not found: ${BOOTSTRAP}"

    info "Running bootstrap-s390x-nuget.sh"
    bash "${BOOTSTRAP}"

    info "Running dev.sh layout Release"
    (cd "${REPO_ROOT}/src" && ./dev.sh layout Release)

    info "Running dev.sh package Release"
    (cd "${REPO_ROOT}/src" && ./dev.sh package Release)

    TARBALL="$(find_tarball)"
    [[ -n "$TARBALL" ]] \
        || fatal "Build completed but no tarball found in ${PKG_DIR}"
fi

[[ -r "$TARBALL" ]] || fatal "Tarball is not readable: ${TARBALL}"
info "Using tarball: ${TARBALL}"

# ---------------------------------------------------------------------------
# Sub-Task 4: Extract tarball into /home/gh-runner/actions-runner
# ---------------------------------------------------------------------------

if [[ -f "${RUNNER_DIR}/run.sh" ]]; then
    if [[ -z "$replace" ]]; then
        fatal "Runner already extracted at ${RUNNER_DIR}. Pass -f to replace."
    fi
    info "Replacing existing runner files (-f specified)"
fi

info "Extracting $(basename "${TARBALL}") into ${RUNNER_DIR}"
tar xzf "${TARBALL}" -C "${RUNNER_DIR}"
chown -R gh-runner:gh-runner "${RUNNER_DIR}"
info "Extraction complete"

# ---------------------------------------------------------------------------
# Sub-Task 5: Configure the runner (config.sh)
# ---------------------------------------------------------------------------

# Build GitHub / GHE URLs
if [[ -n "$ghe_hostname" ]]; then
    RUNNER_URL="https://${ghe_hostname}/${runner_scope}"
    BASE_API_URL="https://${ghe_hostname}/api/v3"
else
    RUNNER_URL="https://github.com/${runner_scope}"
    BASE_API_URL="https://api.github.com"
fi

# Resolve registration token
if [[ -n "$reg_token" ]]; then
    RUNNER_TOKEN="$reg_token"
    info "Using supplied registration token"
else
    info "Exchanging RUNNER_CFG_PAT for a registration token"

    # Determine orgs vs repos endpoint based on slash in scope
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

    # H1: Scrub the PAT from the environment immediately after use.
    unset RUNNER_CFG_PAT

    [[ "$RUNNER_TOKEN" != "null" && -n "$RUNNER_TOKEN" ]] \
        || fatal "Failed to obtain a registration token — check RUNNER_CFG_PAT and scope"
fi

# Compose labels: always include self-hosted,linux,s390x; append extras
ALL_LABELS="self-hosted,linux,s390x${labels:+,$labels}"

info "Configuring runner '${runner_name}' at ${RUNNER_URL}"
info "Labels: ${ALL_LABELS}"

# L1: Pass the registration token via --token.  sudo -E is not available on
#     all targets (Ubuntu 26.04 s390x rejects it), so we cannot rely on env
#     var inheritance.  The registration token is short-lived (1 h, single use)
#     so brief ps-visibility is acceptable.
(
    cd "${RUNNER_DIR}"

    if [[ -n "$replace" && -f .runner ]]; then
        info "Removing existing runner configuration (-f specified)"
        sudo -u gh-runner ./config.sh remove --token "${RUNNER_TOKEN}"
    fi

    sudo -u gh-runner ./config.sh \
        --unattended \
        --url "${RUNNER_URL}" \
        --token "${RUNNER_TOKEN}" \
        --name "${runner_name}" \
        --labels "${ALL_LABELS}" \
        ${runner_group:+--runnergroup "${runner_group}"} \
        ${replace:+--replace}
)
unset RUNNER_TOKEN

[[ -f "${RUNNER_DIR}/.runner" ]] \
    || fatal "config.sh completed but .runner credentials file was not created"

info "Runner configured successfully"

# ---------------------------------------------------------------------------
# Sub-Task 6: Install and start the systemd service (svc.sh)
# ---------------------------------------------------------------------------

info "Installing systemd service"
(cd "${RUNNER_DIR}" && ./svc.sh install gh-runner)

info "Starting service"
(cd "${RUNNER_DIR}" && ./svc.sh start)

info "Service status"
(cd "${RUNNER_DIR}" && ./svc.sh status)

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------

echo ""
echo "======================================================"
echo "  GitHub Actions runner installed and running"
echo "  Name  : ${runner_name}"
echo "  Scope : ${RUNNER_URL}"
echo "  Labels: ${ALL_LABELS}"
echo "  User  : gh-runner"
echo "  Dir   : ${RUNNER_DIR}"
echo "======================================================"
