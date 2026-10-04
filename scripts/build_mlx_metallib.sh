#!/bin/zsh
# Builds MLX's Metal kernels (mlx.metallib) for SAM 3.1 and places them next to the app binary.
#
# SwiftPM (`swift build`) does not compile mlx-swift's Metal shaders (mlx-swift#488); a binary without
# them fails to run MLX. xcodebuild does compile them, so we build the MLX scheme once with xcodebuild
# from the resolved mlx-swift checkout and copy `default.metallib` → `<bin dir>/mlx.metallib`
# (the first place MLX looks). ImageCrat only enables the SAM 3.1 engine when this file exists.
#
# Usage: scripts/build_mlx_metallib.sh [debug|release] [extra destination dir, e.g. build/ImageCrat.app/Contents/MacOS]
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
CONFIG=${1:-debug}
swift package resolve >/dev/null
BIN=$(swift build -c "$CONFIG" --show-bin-path)
WORK="$ROOT/.build/mlx-metallib"
LIB="$WORK/dd/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -f "$LIB" || "$ROOT/Package.resolved" -nt "$LIB" ]]; then
  echo "▸ Building MLX Metal kernels with xcodebuild (one time)…"
  rm -rf "$WORK/src"; mkdir -p "$WORK"
  cp -R "$ROOT/.build/checkouts/mlx-swift" "$WORK/src"
  (cd "$WORK/src" && xcodebuild build -scheme MLX -configuration Release -destination 'platform=macOS' -derivedDataPath "$WORK/dd" -quiet)
fi
mkdir -p "$BIN"
cp "$LIB" "$BIN/mlx.metallib"
echo "▸ $BIN/mlx.metallib"
if [[ -n "$2" ]]; then mkdir -p "$2"; cp "$LIB" "$2/mlx.metallib"; echo "▸ $2/mlx.metallib"; fi
