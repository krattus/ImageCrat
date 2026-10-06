#!/bin/zsh
# Builds the Windows technical preview in the Windows 11 Arm dev VM (UTM "Windows 11 Dev") from the Mac:
# syncs the sources, runs windows/build.ps1 there (x64 + arm64 builds, self-checks, installers, portable zip) and
# copies the results back to dist/windows/.
#   scripts/build_windows.sh                 # everything
#   scripts/build_windows.sh -Arch arm64     # extra arguments go to windows/build.ps1 (-Arch, -SkipInstaller, -SkipTests)
#   SYNC_ONLY=1 scripts/build_windows.sh     # only copy the sources to C:\dev\imagecrat-win
# Uses IMAGECRAT_WINVM or the local, git-ignored file .winvm (one line, e.g. user@192.168.64.3), and
# IMAGECRAT_WINVM_KEY (default ~/.ssh/imagecrat_winvm).
set -euo pipefail
cd "$(dirname "$0")/.."
VM=${IMAGECRAT_WINVM:-$(cat .winvm 2>/dev/null)}
[ -n "$VM" ] || { echo "Set IMAGECRAT_WINVM=user@host or write it to .winvm"; exit 2; }
KEY=${IMAGECRAT_WINVM_KEY:-$HOME/.ssh/imagecrat_winvm}
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$VM")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/Sources" "$T/src/windows"
cp Package.swift LICENSE "$T/src/"
for d in ImageCratCore ImageCratWinSupport ImageCratCLI ImageCratPreview; do rsync -a --exclude '._*' --exclude '.DS_Store' "Sources/$d" "$T/src/Sources/"; done
rsync -a --exclude '._*' --exclude '.DS_Store' Tests "$T/src/"
rsync -a --exclude '._*' --exclude '.DS_Store' --exclude 'build' windows/ "$T/src/windows/"
(cd "$T" && COPYFILE_DISABLE=1 tar czf src.tgz src)
scp -i "$KEY" -q "$T/src.tgz" "$VM:imagecrat-win-src.tgz"
# unpack next to the build tree and mirror into it (keeps the .build cache and windows\build)
"${SSH[@]}" 'New-Item -ItemType Directory -Force C:\dev | Out-Null; Remove-Item -Recurse -Force C:\dev\imagecrat-win-src -ErrorAction SilentlyContinue; New-Item -ItemType Directory C:\dev\imagecrat-win-src | Out-Null; tar -xzf $HOME\imagecrat-win-src.tgz -C C:\dev\imagecrat-win-src; robocopy C:\dev\imagecrat-win-src\src C:\dev\imagecrat-win /MIR /XD .build build dist /NFL /NDL /NJH /NJS /NP | Out-Null; if ($LASTEXITCODE -ge 8) { exit 1 }; exit 0'
[[ -n "${SYNC_ONLY:-}" ]] && { echo "synced to C:\\dev\\imagecrat-win"; exit 0; }
"${SSH[@]}" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\dev\\imagecrat-win\\windows\\build.ps1 $*"
mkdir -p dist/windows
scp -i "$KEY" -q "$VM:C:/dev/imagecrat-win/dist/windows/*" dist/windows/
ls -la dist/windows
