#!/bin/bash
# setup-runners-macos.sh
# Configure multiple independent GitHub Actions runners on macOS.
# Each runner installs as a separate launchd service under the current user.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/actions-runner"
DEFAULT_RUNNERS_BASE="${HOME}/actions-runners"

# ── output helpers ────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m[runner-setup]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[runner-setup]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[runner-setup]\033[0m WARNING: %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[runner-setup]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }
sep()   { printf '\033[2m%s\033[0m\n' '────────────────────────────────────────'; }

usage() {
    cat <<'EOF'
setup-runners-macos.sh — Configure multiple GitHub Actions runners on macOS

Usage:
  ./setup-runners-macos.sh --config <FILE> [OPTIONS]

Options:
  --config FILE       Path to runner config file (required)
  --action ACTION     install | uninstall | status  (default: install)
  --only NAME         Process only the named runner section
  --replace           Replace an existing runner with the same name
  --version VERSION   Pin a specific runner version (default: latest)
  -h, --help          Show this help and exit

PAT resolution order (checked per runner):
  1. 'token' field in the runner's config section
  2. Env var RUNNER_CFG_PAT_<SECTION_UPPERCASE>  (hyphens become underscores)
  3. Env var RUNNER_CFG_PAT

Config file format (INI-style, one [section] per runner):

  [my-runner]
  url     = https://github.com/myorg/myrepo   # repo-level
  # url   = https://github.com/myorg          # org-level
  # url   = https://ghe.example.com/myorg     # GitHub Enterprise Server
  name    = macos-runner-01           # optional; default: <hostname>-<section>
  labels  = macos,arm64,self-hosted   # optional
  group   = my-group                  # optional runner group
  dir     = ~/actions-runners/my-runner  # optional install dir
  token   = ghp_xxxx                  # optional per-runner PAT
  disableupdate = false               # optional; default: false
  ephemeral     = false               # optional; default: false

  Note: values cannot contain '#' (reserved for inline comments).

Examples:
  export RUNNER_CFG_PAT=ghp_xxx
  ./setup-runners-macos.sh --config runners.conf
  ./setup-runners-macos.sh --config runners.conf --action status
  ./setup-runners-macos.sh --config runners.conf --only my-runner --replace
  ./setup-runners-macos.sh --config runners.conf --action uninstall --only old-runner
EOF
}

# ── platform guard ────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || fatal "This script runs on macOS only"
[[ "$(id -u)" -ne 0 ]]          || fatal "Do not run as root or with sudo"

runner_arch=x64
[[ "$(uname -m)" == "arm64" ]] && runner_arch=arm64

# ── argument parsing ──────────────────────────────────────────────────────────
action=install
config_file=""
only_filter=""
replace=false
pin_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)   config_file="$2";   shift 2 ;;
        --action)   action="$2";        shift 2 ;;
        --only)     only_filter="$2";   shift 2 ;;
        --replace)  replace=true;       shift ;;
        --version)  pin_version="$2";   shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          fatal "Unknown argument: $1" ;;
    esac
done

[[ -n "$config_file" ]] || fatal "--config FILE is required. Run with --help for usage."
[[ -f "$config_file" ]] || fatal "Config file not found: $config_file"

case "$action" in
    install|uninstall|status) ;;
    *) fatal "--action must be install, uninstall, or status (got: $action)" ;;
esac

for _cmd in curl jq sed; do
    command -v "$_cmd" &>/dev/null || fatal "'$_cmd' is required. Install with: brew install $_cmd"
done

# ── config file parser ────────────────────────────────────────────────────────
# Populates variables named CFG_<safe_section>_<key> and the 'sections' array.
# Safe section name: hyphens replaced with underscores for valid identifier.
sections=()

parse_config() {
    local file="$1"
    local section=""
    local lineno=0

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        lineno=$(( lineno + 1 ))

        # Strip inline comment and trim surrounding whitespace via sed
        local line
        line=$(printf '%s' "${raw%%#*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9][a-zA-Z0-9_-]*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            sections+=("$section")

        elif [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*) ]]; then
            local key="${BASH_REMATCH[1]}"
            local value
            value=$(printf '%s' "${BASH_REMATCH[2]}" | sed 's/[[:space:]]*$//')
            [[ -n "$section" ]] \
                || fatal "Config line ${lineno}: key '${key}' appears before any [section] header"
            local safe_sec="${section//-/_}"
            printf -v "CFG_${safe_sec}_${key}" '%s' "$value"
        else
            fatal "Config parse error at line ${lineno}: ${raw}"
        fi
    done < "$file"
}

get_cfg() {
    local safe_sec="${1//-/_}"
    local varname="CFG_${safe_sec}_${2}"
    printf '%s' "${!varname:-}"
}

# ── runner version ────────────────────────────────────────────────────────────
runner_version=""

resolve_runner_version() {
    if [[ -n "$pin_version" ]]; then
        runner_version="$pin_version"
        return
    fi
    local resp tag
    resp=$(curl -fsSL \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/actions/runner/releases/latest")
    tag=$(printf '%s' "$resp" | jq -r '.tag_name')
    [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] \
        || fatal "Could not resolve latest runner version (got: '${tag}')"
    runner_version="${BASH_REMATCH[1]}"
}

# ── binary cache ──────────────────────────────────────────────────────────────
runner_archive_path=""

download_runner() {
    local version="$1"
    local archive="actions-runner-osx-${runner_arch}-${version}.tar.gz"
    local cache_path="${CACHE_DIR}/${version}/${archive}"

    if [[ -f "$cache_path" ]]; then
        info "Using cached ${archive}"
    else
        mkdir -p "${CACHE_DIR}/${version}"
        local url="https://github.com/actions/runner/releases/download/v${version}/${archive}"
        info "Downloading runner v${version} (osx-${runner_arch}) ..."
        curl -fSL --progress-bar -o "${cache_path}.tmp" "$url" \
            || { rm -f "${cache_path}.tmp"; fatal "Download failed: $url"; }
        mv "${cache_path}.tmp" "$cache_path"
        ok "Cached: ${cache_path}"
    fi

    runner_archive_path="$cache_path"
}

# ── URL parser ────────────────────────────────────────────────────────────────
# Sets parsed_api_base and parsed_scope globals (avoids subshell/fatal issue).
parsed_api_base=""
parsed_scope=""

parse_runner_url() {
    local url="${1%/}"

    local proto rest host path
    proto="${url%%://*}"
    rest="${url#*://}"
    host="${rest%%/*}"

    [[ "$proto" == "https" || "$proto" == "http" ]] \
        || fatal "Runner URL must use https://: ${url}"
    [[ -n "$host" ]] || fatal "Cannot parse hostname from URL: ${url}"
    [[ "$rest" == */* ]] \
        || fatal "URL must include an org or repo path (e.g. https://github.com/myorg): ${url}"

    path="${rest#*/}"
    [[ -n "$path" ]] || fatal "URL path is empty: ${url}"

    if [[ "$host" == "github.com" ]]; then
        parsed_api_base="https://api.github.com"
    else
        parsed_api_base="https://${host}/api/v3"
    fi
    parsed_scope="$path"
}

# ── token exchange ────────────────────────────────────────────────────────────
get_registration_token() {
    local api_base="$1" scope="$2" pat="$3"
    local endpoint

    if [[ "$scope" == */* ]]; then
        endpoint="${api_base}/repos/${scope}/actions/runners/registration-token"
    else
        endpoint="${api_base}/orgs/${scope}/actions/runners/registration-token"
    fi

    local response token
    response=$(curl -fsSL -X POST "$endpoint" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${pat}")
    token=$(printf '%s' "$response" | jq -r '.token // empty')

    [[ -n "$token" ]] || fatal "Failed to get registration token from ${endpoint}"
    printf '%s' "$token"
}

get_removal_token() {
    local api_base="$1" scope="$2" pat="$3"
    local endpoint

    if [[ "$scope" == */* ]]; then
        endpoint="${api_base}/repos/${scope}/actions/runners/remove-token"
    else
        endpoint="${api_base}/orgs/${scope}/actions/runners/remove-token"
    fi

    local response token
    response=$(curl -fsSL -X POST "$endpoint" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${pat}")
    token=$(printf '%s' "$response" | jq -r '.token // empty')

    [[ -n "$token" ]] || fatal "Failed to get removal token from ${endpoint}"
    printf '%s' "$token"
}

# ── PAT resolution ────────────────────────────────────────────────────────────
resolve_pat() {
    local section="$1"

    # 1. per-section token field in config
    local from_config
    from_config="$(get_cfg "$section" "token")"
    if [[ -n "$from_config" ]]; then
        printf '%s' "$from_config"
        return
    fi

    # 2. env var RUNNER_CFG_PAT_<SECTION_UPPER> (hyphens → underscores)
    local upper_section
    upper_section=$(printf '%s' "$section" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    local env_key="RUNNER_CFG_PAT_${upper_section}"
    local env_val="${!env_key:-}"
    if [[ -n "$env_val" ]]; then
        printf '%s' "$env_val"
        return
    fi

    # 3. global env var
    if [[ -n "${RUNNER_CFG_PAT:-}" ]]; then
        printf '%s' "${RUNNER_CFG_PAT}"
        return
    fi

    fatal "No PAT for runner '${section}'. Set 'token' in config, env ${env_key}, or env RUNNER_CFG_PAT"
}

# ── install ───────────────────────────────────────────────────────────────────
install_runner() {
    local section="$1"

    local url name labels group dir disableupdate ephemeral
    url="$(get_cfg "$section" "url")"
    name="$(get_cfg "$section" "name")"
    labels="$(get_cfg "$section" "labels")"
    group="$(get_cfg "$section" "group")"
    dir="$(get_cfg "$section" "dir")"
    disableupdate="$(get_cfg "$section" "disableupdate")"
    ephemeral="$(get_cfg "$section" "ephemeral")"

    [[ -n "$url" ]] || fatal "[${section}] 'url' is required"

    dir="${dir:-${DEFAULT_RUNNERS_BASE}/${section}}"
    dir="${dir/#\~/$HOME}"
    name="${name:-$(hostname -s)-${section}}"

    parse_runner_url "$url"
    local api_base="$parsed_api_base"
    local scope="$parsed_scope"

    local pat
    pat="$(resolve_pat "$section")"

    # Handle existing installation
    if [[ -d "$dir" && -f "${dir}/.runner" ]]; then
        if [[ "$replace" == true ]]; then
            warn "[${section}] Replacing existing runner at ${dir}"
            if [[ -f "${dir}/svc.sh" ]]; then
                pushd "$dir" >/dev/null
                ./svc.sh stop      2>/dev/null || true
                ./svc.sh uninstall 2>/dev/null || true
                popd >/dev/null
            fi
        else
            warn "[${section}] Already configured at ${dir}. Use --replace to reconfigure. Skipping."
            return 0
        fi
    fi

    info "[${section}] Installing to ${dir}"
    mkdir -p "$dir"
    tar xzf "$runner_archive_path" -C "$dir"

    info "[${section}] Acquiring registration token ..."
    local reg_token
    reg_token="$(get_registration_token "$api_base" "$scope" "$pat")"

    local config_args=(--unattended --url "$url" --token "$reg_token" --name "$name")
    [[ -n "$labels" ]]               && config_args+=(--labels "$labels")
    [[ -n "$group" ]]                && config_args+=(--runnergroup "$group")
    [[ "$disableupdate" == "true" ]] && config_args+=(--disableupdate)
    [[ "$ephemeral"     == "true" ]] && config_args+=(--ephemeral)
    [[ "$replace" == true ]]         && config_args+=(--replace)

    info "[${section}] Configuring runner ..."
    pushd "$dir" >/dev/null
    ./config.sh "${config_args[@]}"

    info "[${section}] Installing launchd service ..."
    ./svc.sh install

    info "[${section}] Starting service ..."
    ./svc.sh start

    popd >/dev/null
    ok "[${section}] Done — runner v${runner_version} running at ${dir}"
}

# ── uninstall ─────────────────────────────────────────────────────────────────
uninstall_runner() {
    local section="$1"

    local dir
    dir="$(get_cfg "$section" "dir")"
    dir="${dir:-${DEFAULT_RUNNERS_BASE}/${section}}"
    dir="${dir/#\~/$HOME}"

    if [[ ! -d "$dir" ]]; then
        warn "[${section}] Directory not found: ${dir}. Nothing to do."
        return 0
    fi

    if [[ -f "${dir}/svc.sh" ]]; then
        info "[${section}] Stopping and uninstalling launchd service ..."
        pushd "$dir" >/dev/null
        ./svc.sh stop      2>/dev/null || true
        ./svc.sh uninstall 2>/dev/null || true
        popd >/dev/null
    else
        warn "[${section}] svc.sh not found — service may not be installed"
    fi

    if [[ -f "${dir}/config.sh" ]]; then
        local url
        url="$(get_cfg "$section" "url")"

        if [[ -n "$url" ]]; then
            parse_runner_url "$url"
            local api_base="$parsed_api_base"
            local scope="$parsed_scope"

            local pat=""
            if ! pat="$(resolve_pat "$section" 2>/dev/null)"; then
                warn "[${section}] No PAT available — runner will not be de-registered from GitHub"
            else
                info "[${section}] Acquiring removal token ..."
                local rem_token=""
                if rem_token="$(get_removal_token "$api_base" "$scope" "$pat")"; then
                    info "[${section}] De-registering runner from GitHub ..."
                    pushd "$dir" >/dev/null
                    ./config.sh remove --token "$rem_token" || true
                    popd >/dev/null
                fi
            fi
        fi
    fi

    ok "[${section}] Uninstalled. Directory '${dir}' was kept."
}

# ── status ────────────────────────────────────────────────────────────────────
status_runner() {
    local section="$1"

    local dir
    dir="$(get_cfg "$section" "dir")"
    dir="${dir:-${DEFAULT_RUNNERS_BASE}/${section}}"
    dir="${dir/#\~/$HOME}"

    printf '\033[1m[%s]\033[0m\n' "$section"

    if [[ ! -d "$dir" ]]; then
        echo "  Not installed (directory not found: ${dir})"
        return
    fi
    echo "  Directory : ${dir}"

    if [[ ! -f "${dir}/.runner" ]]; then
        echo "  Status    : not configured (.runner file missing)"
        return
    fi

    local runner_name runner_url
    runner_name=$(jq -r '.agentName // "unknown"' "${dir}/.runner" 2>/dev/null || echo "unknown")
    runner_url=$(jq -r '.gitHubUrl  // "unknown"' "${dir}/.runner" 2>/dev/null || echo "unknown")
    echo "  Name      : ${runner_name}"
    echo "  Server    : ${runner_url}"

    if [[ -f "${dir}/svc.sh" ]]; then
        pushd "$dir" >/dev/null
        ./svc.sh status 2>/dev/null || true
        popd >/dev/null
    else
        echo "  Service   : not installed (svc.sh missing)"
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
parse_config "$config_file"

[[ ${#sections[@]} -gt 0 ]] || fatal "No runner [sections] found in: $config_file"

active_sections=()
if [[ -n "$only_filter" ]]; then
    for s in "${sections[@]}"; do
        [[ "$s" == "$only_filter" ]] && active_sections+=("$s")
    done
    [[ ${#active_sections[@]} -gt 0 ]] \
        || fatal "Runner '${only_filter}' not found. Available: ${sections[*]}"
else
    active_sections=("${sections[@]}")
fi

info "Action : ${action}"
info "Runners: ${active_sections[*]}"
sep

if [[ "$action" == "install" ]]; then
    info "Resolving runner version ..."
    resolve_runner_version
    info "Runner version: ${runner_version}"
    download_runner "$runner_version"
    sep
fi

errors=()
for section in "${active_sections[@]}"; do
    case "$action" in
        install)   ( install_runner   "$section" ) || errors+=("$section") ;;
        uninstall) ( uninstall_runner "$section" ) || errors+=("$section") ;;
        status)      status_runner    "$section" ;;
    esac
    sep
done

if [[ ${#errors[@]} -gt 0 ]]; then
    fatal "Failed for runner(s): ${errors[*]}"
fi

ok "All done."
