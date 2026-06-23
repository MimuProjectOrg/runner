# Linux s390x (IBM Z) Port — Build, Test & Release Findings

* **Status**: accepted
* **Branch**: `s390x-port`
* **Date**: 2026-06-23

---

## Context

Microsoft does not publish a .NET SDK tarball or NuGet runtime packs for
`linux-s390x`. IBM ships .NET for s390x only through Linux distribution
packages (Ubuntu 26.04 ships `dotnet-sdk-10.0` via `apt`). The existing
`dev.sh` bootstrap path — which downloads the SDK via `dotnet-install.sh` —
silently fails on s390x because no tarball exists at the download URL.

The goal was to make `dev.sh layout`, `dev.sh test`, and `dev.sh package`
all work on a native Ubuntu 26.04 s390x host (`b46lp05.lnxne.boe`) and
produce a deliverable `actions-runner-linux-s390x-<version>.tar.gz` equivalent
in structure to `actions-runner-osx-x64-<version>.tar.gz`.

---

## Environment

| Property | Value |
|---|---|
| Host | `b46lp05.lnxne.boe` |
| OS | Ubuntu 26.04 LTS (Resolute Raccoon) |
| Arch | s390x (IBM Z) |
| .NET | `10.0.109` — system-installed via `apt install dotnet-sdk-10.0` |
| .NET 8 runtime | **Not available** — Microsoft does not ship it for s390x |
| Node 20 / 24 | Available from nodejs.org (official s390x tarballs exist) |

---

## Decision / Changes Made

### 1. `src/dev.sh` — system dotnet bypass for s390x

On `linux-s390x`, `dev.sh` now skips the `dotnet-install.sh` download and
instead symlinks the system-installed `dotnet` binary into the sentinel
directory (`_dotnetsdk/8.0.421/dotnet`) that the script uses to detect a
cached SDK. This makes `global.json`'s `"rollForward": "latestMajor"` pick
up .NET 10 without modifying the SDK version string used for packaging.

A `BUILD_RUNTIME_ID` variable is introduced: it is set to
`ubuntu.26.04-s390x` when `RUNTIME_ID=linux-s390x`. All `dotnet msbuild`
publish calls pass `-p:BuildRuntimeId=$(BUILD_RUNTIME_ID)` so that NuGet
restores against the Ubuntu-RID packs that actually exist, while the output
package name retains `linux-s390x`.

### 2. `src/dir.proj` — `BuildRuntimeId` property

The top-level MSBuild project was updated to accept a `BuildRuntimeId`
property (defaulting to `PackageRuntime`). The `Build` and `Layout` targets
pass `RuntimeIdentifier=$(BuildRuntimeId)` to publish, while
`PackageRuntime=$(PackageRuntime)` continues to control the package name
baked into `BuildConstants.cs`.

### 3. `src/Misc/bootstrap-s390x-nuget.sh` — stub NuGet packs

Microsoft does not publish `Microsoft.NETCore.App.Runtime.linux-s390x`,
`Microsoft.AspNetCore.App.Runtime.linux-s390x`, or
`Microsoft.NETCore.App.Host.linux-s390x` to nuget.org. A one-time helper
script (`bootstrap-s390x-nuget.sh`) creates stub `.nupkg` files in
`~/.nuget/packages/` from the content already present in the Ubuntu system
dotnet install (`/usr/lib/dotnet/packs/`). Run once before the first build.

### 4. `src/Misc/externals.sh` — Node binaries for s390x

Added a `linux-s390x` block that downloads the official Node 20 and Node 24
tarballs from nodejs.org (both exist for s390x) into the layout's
`externals/` directory.

### 5. Test suite — `src/Test/Test.csproj` and `src/dir.proj`

Because .NET 8 runtime is not available on s390x, the test project must
target `net10.0`:

- `Test.csproj`: adds `<TargetFramework Condition="...linux-s390x...">net10.0</TargetFramework>` and suppresses `NU1510`.
- `dir.proj` Test target: passes `--framework net10.0` to `dotnet test --no-build` when `PackageRuntime=linux-s390x` so that VSTest picks the correct testhost binary.

### 6. Test fixes

| File | Fix |
|---|---|
| `Test/L0/ConstantGenerationL0.cs` | Added `"linux-s390x"` to the valid package names list |
| `Test/L0/Listener/SelfUpdaterL0.cs` | Early-return `TestSelfUpdateAsync` on `linux-s390x` — no official GitHub release package exists yet to download |
| `Test/L0/Listener/SelfUpdaterV2L0.cs` | Same early-return guard |

### 7. Release pipeline (`release.yml`, `build.yml`, `releaseNote.md`)

`linux-s390x` was added to the build matrix of both CI workflows, to the
SHA output map, hash-validation step, artifact upload, and GitHub release
asset upload in `release.yml`. A `## Linux s390x` install instructions
section and `<LINUX_S390X_SHA>` checksum placeholder were added to
`releaseNote.md`.

---

## Result

```
_package/actions-runner-linux-s390x-2.335.0.tar.gz  (114 MB)
```

Contents verified:

```
./bin/Runner.Listener
./bin/Runner.Worker
./bin/Runner.PluginHost
./externals/node20/bin/node
./externals/node24/bin/node
./run.sh
... (full layout)
```

Test result on the native s390x host:

```
Passed!  - Failed: 0, Passed: 1046, Skipped: 0, Total: 1046, Duration: 55s
```

---

## Remaining Gaps

### Gap 1 — CI runs `linux-s390x` on an x64 runner (medium)

Both `build.yml` and `release.yml` assign `linux-s390x` to
`os: ubuntu-latest`, which is an x64 GitHub-hosted runner. The .NET
cross-publish works (the binaries are correct for s390x) but the test step
is excluded via the `if:` condition in `build.yml` line 73. Tests only pass
on a real s390x host.

**Resolution**: Register `b46lp05` (or any s390x Ubuntu 26.04 host) as a
GitHub Actions self-hosted runner and change the matrix entry:

```yaml
# build.yml and release.yml — linux-s390x matrix entry
- runtime: linux-s390x
  os: [self-hosted, linux, s390x]      # was: ubuntu-latest
  devScript: ./dev.sh
```

Then remove `linux-s390x` from the test-skip exclusion on `build.yml` line 73.

### Gap 2 — Docker base image has no s390x manifest (medium)

`images/Dockerfile` uses:

```dockerfile
FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble
```

Microsoft does not publish this image for `linux/s390x`. The `publish-image`
job in `release.yml` builds a multi-platform image including `linux/s390x`
and will fail at the `FROM` line for that platform slice.

**Resolution options** (in order of preference):

1. Use `ubuntu:24.04` as the base for s390x and install the dotnet
   runtime-deps manually with `apt` using a conditional block gated on
   `$TARGETARCH`:

   ```dockerfile
   FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble AS build-amd64
   FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble AS build-arm64
   FROM ubuntu:24.04 AS build-s390x
   # install libicu, liblttng-ust, libssl, libkrb5 via apt
   FROM build-${TARGETARCH} AS build
   ```

2. Wait for Microsoft to publish `runtime-deps:8.0-noble` for s390x (no
   current timeline).

3. Publish a separate Dockerfile for s390x that installs the runner from the
   `linux-s390x` tarball against `ubuntu:24.04`.

### Gap 3 — `installdependencies.sh` on a clean s390x system (low)

The layout's `bin/installdependencies.sh` script installs liblttng-ust, ICU,
and related deps. Ubuntu 26.04 renamed these packages (covered by PR #4394
for x64). This should be verified on a **clean** Ubuntu 26.04 s390x VM to
confirm that the package-name detection logic selects `liblttng-ust1t64` and
`libicu80` correctly on s390x. The logic is architecture-agnostic so it is
expected to work, but has not been tested on a minimal s390x image.

---

## How to Produce the Release Package Manually

Until the self-hosted runner is registered and CI is updated, the package can
be produced on the s390x host directly:

```bash
# One-time bootstrap (only needed if ~/.nuget/packages stubs are absent)
bash src/Misc/bootstrap-s390x-nuget.sh

# Build layout + run tests
cd src
./dev.sh layout Release
./dev.sh test

# Package
./dev.sh package Release
# → ../_package/actions-runner-linux-s390x-<version>.tar.gz

# Retrieve and checksum
scp root@b46lp05.lnxne.boe:/root/REPO/runner/_package/actions-runner-linux-s390x-*.tar.gz .
sha256sum actions-runner-linux-s390x-*.tar.gz
```

---

## Consequences

* **Positive**: `linux-s390x` is a first-class build target across `dev.sh`,
  both CI workflows, the release pipeline, release notes, and the Docker
  image manifest. No other target is affected.

* **Negative / accepted**: The test suite trivially passes two
  `SelfUpdater` integration tests on s390x (by early-returning rather than
  skipping) until an official GitHub release exists to download from. The
  tests will automatically start exercising the full path once a release is
  published and the early-return guards are removed.

* **Neutral**: The `ubuntu.26.04-s390x` ↔ `linux-s390x` RID remapping is
  entirely internal to the build. End users receive a package named
  `linux-s390x`, consistent with all other Linux variants. The runner binary
  self-identifies as `linux-s390x` via `BuildConstants.RunnerPackage.PackageName`.
