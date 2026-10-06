#!/bin/zsh
# Builds windows/ImageCrat.ico (16–256 px, PNG-compressed entries) from Resources/IconSource/imagecrat-icon-1024.png
# with macOS `sips` and python3's standard library. Run from anywhere; the .ico is checked in.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for s in 16 20 24 32 40 48 64 96 128 256; do
    sips -z $s $s Resources/IconSource/imagecrat-icon-1024.png --out "$T/$s.png" >/dev/null
done
python3 - "$T" windows/ImageCrat.ico <<'PY'
import struct, sys, os
d, out = sys.argv[1], sys.argv[2]
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
data = [open(os.path.join(d, f"{s}.png"), "rb").read() for s in sizes]
hdr = struct.pack("<HHH", 0, 1, len(sizes))
off = 6 + 16 * len(sizes)
entries = b""
for s, b in zip(sizes, data):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), off)
    off += len(b)
open(out, "wb").write(hdr + entries + b"".join(data))
print("wrote", out, off, "bytes")
PY
