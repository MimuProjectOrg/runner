#!/bin/bash
# create-svc-macos.sh
# Run once per runner to download, configure, and start a GitHub Actions
# runner as a launchd service on macOS.  No sudo required.
#
# Run it multiple times with different -s/-g/-n flags to set up independent
# runners for different servers or repositories on the same machine.
#
# RUNNER_CFG_PAT must be exported before calling.
#
# Examples:
#   export RUNNER_CFG_PAT=<yourPAT>
#   ./create-svc-macos.sh -s myorg/myrepo
#   ./create-svc-macos.sh -s myorg -g ghe.example.com -n macos-ghes-01 -l macos,arm64
#   ./create-svc-macos.sh -s myorg/myrepo -n macos-repo-02 -r my-group -d

set -e

function fatal() { echo "error: $1" >&2; exit 1; }

#---------------------------------------
# Parse flags
#---------------------------------------
while getopts 's:g:n:r:l:dfe' opt; do
    case $opt in
    s) runner_scope=$OPTARG ;;
    g) ghe_hostname=$OPTARG ;;
    n) runner_name=$OPTARG ;;
    r) runner_group=$OPTARG ;;
    l) labels=$OPTARG ;;
    d) disableupdate=true ;;
    f) replace=true ;;
    e) ephemeral=true ;;
    *)
        echo "
macOS Runner Service Installer — run once per runner

Usage:
    export RUNNER_CFG_PAT=<yourPAT>
    ./create-svc-macos.sh -s <scope> [OPTIONS]

Flags:
    -s  required  scope: repo (owner/repo) or org (orgname)
    -g  optional  GHE hostname (e.g. ghe.example.com); omit for github.com
    -n  optional  runner name; default: <hostname>-<scope-slug>
    -r  optional  runner group; default: Default
    -l  optional  labels (comma-separated, e.g. macos,arm64,self-hosted)
    -d  optional  disable auto-update (stay on current version for one month)
    -f  optional  replace an existing runner with the same name
    -e  optional  ephemeral: de-register runner after each job

Each invocation creates an independent runner directory under
~/actions-runners/ and registers a separate launchd service.
Run the script multiple times (with different -s/-n values) to
set up runners for different servers or repos."
        exit 0 ;;
    esac
done

#---------------------------------------
# Validate
#---------------------------------------
[ "$(uname -s)" = "Darwin" ] || fatal "This script is macOS only"
[ "$(id -u)" -ne 0 ]         || fatal "Do not run as root or with sudo"

[ -n "${runner_scope:-}" ]   || fatal "-s scope is required (e.g. myorg or myorg/myrepo)"
[ -n "${RUNNER_CFG_PAT:-}" ] || fatal "RUNNER_CFG_PAT must be set before calling"

which curl || fatal "curl required — install via Homebrew: brew install curl"
which jq   || fatal "jq required — install via Homebrew: brew install jq"

runner_arch=x64
[ -n "$(uname -m | grep arm64)" ] && runner_arch=arm64

#---------------------------------------
# Derive runner name and install dir
#---------------------------------------
# Sanitise scope to a filesystem-safe slug (replace / with -)
scope_slug=$(echo "$runner_scope" | tr '/' '-')

runner_name=${runner_name:-$(hostname -s)-${scope_slug}}
runner_dir="${HOME}/actions-runners/${runner_name}"

if [ -d "$runner_dir" ] && [ -f "${runner_dir}/.runner" ]; then
    if [ "${replace:-}" = "true" ]; then
        echo "Replacing existing runner at ${runner_dir} ..."
        if [ -f "${runner_dir}/svc.sh" ]; then
            pushd "$runner_dir" >/dev/null
            ./svc.sh stop      2>/dev/null || true
            ./svc.sh uninstall 2>/dev/null || true
            popd >/dev/null
        fi
    else
        fatal "Runner already exists at ${runner_dir}. Use -f to replace."
    fi
fi

echo
echo "Runner name : ${runner_name}"
echo "Install dir : ${runner_dir}"

#---------------------------------------
# Get a registration token
#---------------------------------------
echo
echo "Generating a registration token..."

base_api_url="https://api.github.com"
if [ -n "${ghe_hostname:-}" ]; then
    base_api_url="https://${ghe_hostname}/api/v3"
fi

orgs_or_repos="orgs"
if echo "$runner_scope" | grep -q '/'; then
    orgs_or_repos="repos"
fi

RUNNER_TOKEN=$(curl -fsSL -X POST \
    "${base_api_url}/${orgs_or_repos}/${runner_scope}/actions/runners/registration-token" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token ${RUNNER_CFG_PAT}" | jq -r '.token')

[ -n "$RUNNER_TOKEN" ] && [ "$RUNNER_TOKEN" != "null" ] \
    || fatal "Failed to get registration token"

#---------------------------------------
# Download (cached) and extract
#---------------------------------------
echo
echo "Resolving latest runner version..."

latest_label=$(curl -fsSL \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.tag_name')
latest_version="${latest_label#v}"

runner_file="actions-runner-osx-${runner_arch}-${latest_version}.tar.gz"
cache_dir="${HOME}/.cache/actions-runner/${latest_version}"
cache_path="${cache_dir}/${runner_file}"

if [ -f "$cache_path" ]; then
    echo "Using cached ${runner_file}"
else
    mkdir -p "$cache_dir"
    runner_url="https://github.com/actions/runner/releases/download/${latest_label}/${runner_file}"
    echo "Downloading ${latest_label} (osx-${runner_arch}) ..."
    curl -fSL --progress-bar -o "${cache_path}.tmp" "$runner_url" \
        || { rm -f "${cache_path}.tmp"; fatal "Download failed: ${runner_url}"; }
    mv "${cache_path}.tmp" "$cache_path"
fi

echo
echo "Extracting to ${runner_dir} ..."
mkdir -p "$runner_dir"
tar xzf "$cache_path" -C "$runner_dir"

#---------------------------------------
# Configure the runner
#---------------------------------------
runner_url="https://github.com/${runner_scope}"
if [ -n "${ghe_hostname:-}" ]; then
    runner_url="https://${ghe_hostname}/${runner_scope}"
fi

echo
echo "Configuring ${runner_name} @ ${runner_url}"

config_args="--unattended --url ${runner_url} --token ${RUNNER_TOKEN} --name ${runner_name}"
[ -n "${labels:-}"       ] && config_args="${config_args} --labels ${labels}"
[ -n "${runner_group:-}" ] && config_args="${config_args} --runnergroup ${runner_group}"
[ "${disableupdate:-}"   = "true" ] && config_args="${config_args} --disableupdate"
[ "${ephemeral:-}"       = "true" ] && config_args="${config_args} --ephemeral"
[ "${replace:-}"         = "true" ] && config_args="${config_args} --replace"

pushd "$runner_dir" >/dev/null
# shellcheck disable=SC2086
./config.sh $config_args

#---------------------------------------
# Install and start launchd service
#---------------------------------------
echo
echo "Installing launchd service..."
./svc.sh install

echo "Starting service..."
./svc.sh start

popd >/dev/null

echo
echo "Done. Runner '${runner_name}' is running."
echo "  Directory : ${runner_dir}"
echo "  Server    : ${runner_url}"
echo "  Version   : ${latest_version}"
echo
echo "To check status : cd ${runner_dir} && ./svc.sh status"
echo "To stop         : cd ${runner_dir} && ./svc.sh stop"
echo "To uninstall    : cd ${runner_dir} && ./svc.sh uninstall"
