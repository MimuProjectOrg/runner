#!/usr/bin/env bash
# bootstrap-s390x-nuget.sh
#
# Creates stub NuGet packages for the three linux-s390x runtime packs that
# Microsoft does not publish to nuget.org. Run once before the first dev.sh build.
#
# Background: Ubuntu 26.04 ships .NET under RID 'ubuntu.26.04-s390x'. The SDK
# still requests 'linux-s390x' runtime packs from nuget.org during restore —
# those packages don't exist. This script builds stub .nupkg files in
# ~/.nuget/packages/ from the content already in the system dotnet install.
#
# Requirements: apt install dotnet-sdk-10.0  (provides /usr/lib/dotnet/packs/)
# Usage:        bash src/Misc/bootstrap-s390x-nuget.sh
# Idempotent:   safe to re-run after a system dotnet upgrade.

set -euo pipefail

if [[ $(uname -m) != s390x ]]; then
    echo 'This script is only needed on Linux s390x.' >&2; exit 1
fi

UBUNTU_PACKS=/usr/lib/dotnet/packs
NUGET_CACHE="${NUGET_PACKAGES:-${HOME}/.nuget/packages}"

UBUNTU_VER=$(ls ${UBUNTU_PACKS}/Microsoft.NETCore.App.Runtime.ubuntu.26.04-s390x/ \
             2>/dev/null | sort -V | tail -1)
if [[ -z ${UBUNTU_VER} ]]; then
    echo 'ERROR: ubuntu.26.04-s390x packs not found. Run: apt install dotnet-sdk-10.0' >&2
    exit 1
fi

REF_PACK_DIR=${UBUNTU_PACKS}/Microsoft.NETCore.App.Ref
NET8_VER=$(ls ${REF_PACK_DIR}/ 2>/dev/null | { grep '^8\.' || true; } | sort -V | tail -1)
NET8_VER="${NET8_VER:-8.0.28}"

echo "Ubuntu pack version : ${UBUNTU_VER}"
echo "net8 pack version   : ${NET8_VER}"
echo "NuGet cache         : ${NUGET_CACHE}"
echo

python3 - "${NUGET_CACHE}" "${NET8_VER}" "${UBUNTU_PACKS}" "${UBUNTU_VER}" << 'EOF'
import zipfile, os, hashlib, base64, sys, textwrap, shutil
NUGET_CACHE, VERSION, UBUNTU_PACKS, UBUNTU_VER = sys.argv[1:5]
PACKAGES = {
    "Microsoft.NETCore.App.Runtime.linux-s390x": {
        "ubuntu_pack": "Microsoft.NETCore.App.Runtime.ubuntu.26.04-s390x",
        "subdirs": ("data", "runtimes"),
    },
    "Microsoft.AspNetCore.App.Runtime.linux-s390x": {
        "ubuntu_pack": "Microsoft.AspNetCore.App.Runtime.ubuntu.26.04-s390x",
        "subdirs": ("data", "runtimes"),
    },
    "Microsoft.NETCore.App.Host.linux-s390x": {
        "ubuntu_pack": "Microsoft.NETCore.App.Host.ubuntu.26.04-s390x",
        "subdirs": ("runtimes",),
    },
}
def sha512_b64(p):
    with open(p,'rb') as f: return base64.b64encode(hashlib.sha512(f.read()).digest()).decode()
def add_dir(z, src, prefix):
    for r,_,fs in os.walk(src):
        for fn in fs: z.write(os.path.join(r,fn), prefix+'/'+os.path.relpath(os.path.join(r,fn),src))
for pkg, cfg in PACKAGES.items():
    pl = pkg.lower(); pd = os.path.join(NUGET_CACHE, pl, VERSION)
    nupkg = os.path.join(pd, f'{pl}.{VERSION}.nupkg')
    ub = os.path.join(UBUNTU_PACKS, cfg['ubuntu_pack'], UBUNTU_VER)
    if not os.path.isdir(ub): print(f'  SKIP  {pkg}'); continue
    os.makedirs(pd, exist_ok=True)
    nuspec = f"""<?xml version="1.0" encoding="utf-8"?>
<package><metadata><id>{pkg}</id><version>{VERSION}</version><description>Stub linux-s390x pack (Ubuntu 26.04 source-built)</description><authors>stub</authors></metadata></package>
"""
    with zipfile.ZipFile(nupkg,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr(f'{pkg}.nuspec', nuspec)
        for sub in cfg['subdirs']:
            src=os.path.join(ub,sub)
            if os.path.isdir(src): add_dir(z, src, sub)
    if 'Host' in pkg:
        ns=os.path.join(ub,'runtimes','ubuntu.26.04-s390x','native')
        nd=os.path.join(pd,'runtimes','linux-s390x','native')
        if os.path.isdir(ns):
            os.makedirs(nd, exist_ok=True)
            for f in os.listdir(ns):
                dst=os.path.join(nd,f)
                if not os.path.exists(dst): shutil.copy2(os.path.join(ns,f),dst)
    with open(nupkg+'.sha512','w') as f: f.write(sha512_b64(nupkg))
    with zipfile.ZipFile(nupkg,'r') as z: z.extractall(pd)
    print(f'  OK    {pkg}  {VERSION}')
print('Bootstrap complete.')
EOF
