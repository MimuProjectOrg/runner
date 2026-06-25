# Automate Configuring Self-Hosted Runners


## Export PAT

Before running any of these sample scripts, create a GitHub PAT and export it before running the script

```bash
export RUNNER_CFG_PAT=yourPAT
```

## Create running as a service

**Scenario**: Run on a machine or VM ([not container](#why-cant-i-use-a-container)) which automates:

 - Resolving latest released runner
 - Download and extract latest
 - Acquire a registration token
 - Configure the runner
 - Run as a systemd (linux) or Launchd (osx) service

:point_right: [Sample script here](../scripts/create-latest-svc.sh) :point_left:

Run as a one-liner. NOTE: replace with yourorg/yourrepo (repo level) or just yourorg (org level)
```bash
curl -s https://raw.githubusercontent.com/actions/runner/main/scripts/create-latest-svc.sh | bash -s yourorg/yourrepo
```

You can call the script with additional arguments:
```bash
#   Usage:
#       export RUNNER_CFG_PAT=<yourPAT>
#       ./create-latest-svc -s scope -g [ghe_domain] -n [name] -u [user] -l [labels]
#       -s          required  scope: repo (:owner/:repo) or org (:organization)
#       -g          optional  ghe_hostname: the fully qualified domain name of your GitHub Enterprise Server deployment
#       -n          optional  name of the runner, defaults to hostname
#       -u          optional  user svc will run as, defaults to current
#       -l          optional  list of labels (split by comma) applied on the runner"
```

Use `--` to pass any number of optional named parameters:

```
curl -s https://raw.githubusercontent.com/actions/runner/main/scripts/create-latest-svc.sh | bash -s -- -s myorg/myrepo -n myname -l label1,label2
```
### Why can't I use a container?

The runner is installed as a service using `systemd` and `systemctl`. Docker does not support `systemd` for service configuration on a container.

## Configure multiple runners on macOS (multi-server / multi-repo)

**Scenario**: Provision several independent runners on one macOS machine, each targeting a different GitHub server (github.com or GHES) or repository, all running as separate launchd services under the current user.

:point_right: [Script](../scripts/setup-runners-macos.sh) · [Example config](../scripts/runners.conf.example) :point_left:

### Quick start

```bash
# 1. Copy and edit the example config
cp scripts/runners.conf.example runners.conf
$EDITOR runners.conf

# 2. Export a PAT (or set per-runner in the config file)
export RUNNER_CFG_PAT=ghp_xxxx

# 3. Install and start all runners
./scripts/setup-runners-macos.sh --config runners.conf
```

### Config file format

Each `[section]` defines one runner. Sections are processed independently:

```ini
[prod-org]
url     = https://github.com/myorg          # org-level (github.com)
name    = macos-arm64-prod                  # optional; default: <hostname>-<section>
labels  = macos,arm64,self-hosted,prod      # optional
group   = default                           # optional runner group
dir     = ~/actions-runners/prod-org        # optional install directory
token   = ghp_xxxx                          # optional per-runner PAT

[ghes-repo]
url     = https://ghe.mycompany.com/myorg/myrepo   # GHES repo-level
name    = macos-arm64-ghes
labels  = macos,arm64,ghes
```

The API base URL is derived automatically: `github.com` → `https://api.github.com`, any other host → `https://<host>/api/v3`.

### PAT resolution (per runner)

1. `token` field in the config section
2. Env var `RUNNER_CFG_PAT_<SECTION_UPPERCASE>` (hyphens become underscores)
3. Env var `RUNNER_CFG_PAT`

### Available options

```
--config FILE       Path to config file (required)
--action ACTION     install | uninstall | status  (default: install)
--only NAME         Process only one named section
--replace           Replace an existing runner with the same name
--version VERSION   Pin a specific runner version (default: latest)
```

### Common operations

```bash
# Check status of all runners
./scripts/setup-runners-macos.sh --config runners.conf --action status

# Replace a single runner's registration
./scripts/setup-runners-macos.sh --config runners.conf --only prod-org --replace

# Uninstall one runner (stops service, de-registers from GitHub, keeps directory)
./scripts/setup-runners-macos.sh --config runners.conf --action uninstall --only old-runner

# Pin all runners to a specific version
./scripts/setup-runners-macos.sh --config runners.conf --version 2.317.0
```

The runner binary is downloaded once and cached in `~/.cache/actions-runner/<version>/` regardless of how many runners are configured.

## Uninstall running as service

**Scenario**: Run on a machine or VM ([not container](#why-cant-i-use-a-container)) which automates:

 - Stops and uninstalls the systemd (linux) or Launchd (osx) service
 - Acquires a removal token
 - Removes the runner

:point_right: [Sample script here](../scripts/remove-svc.sh) :point_left:

Repo level one liner.  NOTE: replace with yourorg/yourrepo (repo level) or just yourorg (org level)
```bash
curl -s https://raw.githubusercontent.com/actions/runner/main/scripts/remove-svc.sh | bash -s yourorg/yourrepo
```

### Delete an offline runner

**Scenario**: Deletes a registered runner that is offline:

 - Ensures the runner is offline
 - Resolves id from name
 - Deletes the runner

:point_right: [Sample script here](../scripts/delete.sh) :point_left:

Repo level one-liner.  NOTE: replace with yourorg/yourrepo (repo level) or just yourorg (org level) and replace runnername
```bash
curl -s https://raw.githubusercontent.com/actions/runner/main/scripts/delete.sh | bash -s yourorg/yourrepo runnername
```
