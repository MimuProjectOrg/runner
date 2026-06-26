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

## Create multiple runners on macOS (multi-server / multi-repo)

**Scenario**: Provision several independent runners on one macOS machine, each targeting a different GitHub server (github.com or GHES) or repository. Run the script once per runner — each invocation registers and starts its own launchd service. No sudo required.

:point_right: [Sample script here](../scripts/create-svc-macos.sh) :point_left:

```bash
export RUNNER_CFG_PAT=<yourPAT>

# Runner for a github.com repo
./create-svc-macos.sh -s myorg/myrepo

# Runner for a github.com org, with labels and a group
./create-svc-macos.sh -s myorg -n macos-arm64-01 -l macos,arm64,self-hosted -r my-group

# Runner for a GitHub Enterprise Server org
./create-svc-macos.sh -s myorg -g ghe.example.com -n macos-ghes-01 -l macos,arm64

# Second runner for a different GHE repo on the same machine
./create-svc-macos.sh -s myorg/myrepo -g ghe.example.com -n macos-ghes-02
```

Each runner is installed under `~/actions-runners/<runner-name>/` and registered as an independent launchd service. Running the script N times gives N independent, isolated runners.

```
Flags:
    -s  required  scope: repo (owner/repo) or org (orgname)
    -g  optional  GHE hostname (e.g. ghe.example.com); omit for github.com
    -n  optional  runner name; default: <hostname>-<scope-slug>
    -r  optional  runner group; default: Default
    -l  optional  labels (comma-separated, e.g. macos,arm64,self-hosted)
    -d  optional  disable auto-update (stay on current version for one month)
    -f  optional  replace an existing runner with the same name
    -e  optional  ephemeral: de-register runner after each job
```

The runner binary is downloaded once and cached in `~/.cache/actions-runner/<version>/`.

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
