#!/bin/zsh
# Builds ImageCratCore and runs its unit tests in the Windows 11 Arm dev VM (UTM "Windows 11 Dev"), from the Mac.
#   scripts/test_core_windows.sh            # VM login from IMAGECRAT_WINVM or the local, git-ignored file .winvm
#                                           # (one line, e.g. user@192.168.64.3); key: ~/.ssh/imagecrat_winvm
# The VM was set up with docs/WINDOWS-PORT.md's setup script (Git, VS 2022 Build Tools, Swift 6.3.x, key-only SSH).
set -euo pipefail
cd "$(dirname "$0")/.."
VM=${IMAGECRAT_WINVM:-$(cat .winvm 2>/dev/null)}
[ -n "$VM" ] || { echo "Set IMAGECRAT_WINVM=user@host or write it to .winvm"; exit 2; }
KEY=${IMAGECRAT_WINVM_KEY:-$HOME/.ssh/imagecrat_winvm}
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$VM")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/imagecrat/Sources"
cp Package.swift "$T/imagecrat/"
for d in ImageCratCore ImageCratWinSupport ImageCratCLI ImageCratPreview; do rsync -a --exclude '._*' "Sources/$d" "$T/imagecrat/Sources/"; done
rsync -a --exclude '._*' Tests "$T/imagecrat/"
(cd "$T" && COPYFILE_DISABLE=1 tar czf core.tgz imagecrat)
scp -i "$KEY" -q "$T/core.tgz" "$VM:imagecrat-core.tgz"
"${SSH[@]}" 'New-Item -ItemType Directory -Force C:\dev | Out-Null; Remove-Item -Recurse -Force C:\dev\imagecrat -ErrorAction SilentlyContinue; tar -xzf $HOME\imagecrat-core.tgz -C C:\dev; cd C:\dev\imagecrat; swift build 2>&1 | Select-Object -Last 3; if ($LASTEXITCODE -ne 0) { exit 1 }; swift test 2>&1 | Select-String -Pattern "error:|failed \(|Executed .* tests" | Select-Object -Last 20; exit $LASTEXITCODE'
