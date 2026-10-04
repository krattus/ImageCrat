#!/bin/bash
# Portability lint for Sources/ImageCratCore (the platform-independent core library).
#
# This is the stand-in until a real Windows/Linux CI build of ImageCratCore exists. On macOS the core gets the
# CoreGraphics geometry members through Portability/GeometryTypes.swift and Foundation makes other Apple-only API
# visible, so the compiler alone cannot tell whether the core would still build with swift-corelibs-foundation.
# This script fails with file:line output on:
#   - any `import` other than Foundation (the one allowed exception is the conditional
#     `@_exported import CoreGraphics` in Portability/GeometryTypes.swift, guarded by `#if canImport(CoreGraphics)`);
#   - Apple-only identifiers: CoreGraphics types other than the geometry value types (CGFloat, CGPoint, CGSize, CGRect),
#     any CI* (Core Image) or MTL* (Metal) type, AppKit/UIKit graphics types (NSImage, NSColor, NSBezierPath, NSFont,
#     NSView, ...), CoreText, vImage/Accelerate, UTType, os_log / os.Logger, DispatchQueue.main / @MainActor,
#     Observation, Combine, SwiftUI and the `simd` module (the stdlib SIMD2/SIMD4 types are portable and allowed);
#   - CGAffineTransform used outside the shim while Portability/CGAffineTransformShim.swift does not exist.
# Comments and string literals are ignored.
#
# Usage: scripts/check_core_portable.sh [core-dir]     (exit 0 = clean, 1 = violations)
set -u
cd "$(dirname "$0")/.." || exit 2
CORE="${1:-Sources/ImageCratCore}"
SHIM="Portability/CGAffineTransformShim.swift"
GEOMETRY="Portability/GeometryTypes.swift"
[ -d "$CORE" ] || { echo "check_core_portable: no such directory: $CORE" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/coreportable.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Copy of the core with // comments, /* */ comments and "string" literals blanked (line numbers preserved).
(cd "$CORE" && find . -name '*.swift' | sed 's#^\./##') | sort > "$TMP/files"
while IFS= read -r rel; do
    mkdir -p "$TMP/src/$(dirname "$rel")"
    awk '
    BEGIN { inblock = 0; inml = 0 }
    {
        line = $0; out = ""
        i = 1; n = length(line)
        while (i <= n) {
            c = substr(line, i, 1); two = substr(line, i, 2); three = substr(line, i, 3)
            if (inblock) { if (two == "*/") { inblock = 0; i += 2 } else i++; continue }
            if (inml) { if (three == "\"\"\"") { inml = 0; out = out "\"\"\""; i += 3 } else i++; continue }
            if (two == "//") break
            if (two == "/*") { inblock = 1; i += 2; continue }
            if (three == "\"\"\"") { inml = 1; out = out "\"\"\""; i += 3; continue }
            if (c == "\"") {
                j = i + 1
                while (j <= n) { d = substr(line, j, 1); if (d == "\\") { j += 2; continue } if (d == "\"") break; j++ }
                out = out "\"\""; i = j + 1; continue
            }
            out = out c; i++
        }
        print out
    }' "$CORE/$rel" > "$TMP/src/$rel"
done < "$TMP/files"

fail=0
emit() {   # stdin: "rel:line:text" ; $1 = message (TOKEN replaced by the matched token when $2 is a token regex)
    while IFS= read -r hit; do
        rel=${hit%%:*}; rest=${hit#*:}; ln=${rest%%:*}; text=${rest#*:}
        if [ -n "${2:-}" ]; then
            for tok in $(printf '%s\n' "$text" | grep -oE "$2" | sort -u); do
                echo "$CORE/$rel:$ln: ${1//TOKEN/$tok}"; fail=1
            done
        else
            echo "$CORE/$rel:$ln: $1"; fail=1
        fi
    done
}

cd "$TMP/src" || exit 2

# 1. imports other than Foundation (GeometryTypes.swift may import CoreGraphics inside #if canImport(CoreGraphics))
while IFS= read -r hit; do
    rel=${hit%%:*}; rest=${hit#*:}; ln=${rest%%:*}; text=${rest#*:}
    mod=$(printf '%s\n' "$text" | sed -E 's/^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(kind[[:space:]]+)?([A-Za-z_]+).*/\3/')
    [ "$mod" = "Foundation" ] && continue
    if [ "$rel" = "$GEOMETRY" ] && [ "$mod" = "CoreGraphics" ] && head -n "$ln" "$rel" | grep -q '^#if canImport(CoreGraphics)'; then continue; fi
    echo "$CORE/$rel:$ln: import of '$mod' (only Foundation is allowed in the core)"; fail=1
done < <(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' --include='*.swift' . | sed 's#^\./##')

# 2. CoreGraphics beyond the portable geometry value types
CG_RE='\bCG[A-Z][A-Za-z0-9_]*\b'
while IFS= read -r hit; do
    rel=${hit%%:*}; rest=${hit#*:}; ln=${rest%%:*}; text=${rest#*:}
    for tok in $(printf '%s\n' "$text" | grep -oE "$CG_RE" | sort -u); do
        [[ "$tok" =~ ^CG(Float|Point|Size|Rect|AffineTransform)$ ]] && continue
        echo "$CORE/$rel:$ln: '$tok' is CoreGraphics API beyond the portable geometry types (CGFloat/CGPoint/CGSize/CGRect)"; fail=1
    done
done < <(grep -rnE "$CG_RE" --include='*.swift' . | sed 's#^\./##' | grep -v "^$GEOMETRY:")

# 3. Other Apple-only APIs
APPLE_RE='\b(CI[A-Z][A-Za-z0-9_]*|MTL[A-Za-z0-9_]*|vImage[A-Za-z0-9_]*|NS(Image|Color|ColorSpace|BezierPath|Font|FontManager|View|Window|Application|Event|GraphicsContext|Screen|Cursor|Pasteboard|Workspace|BitmapImageRep|Gradient|Shadow)|UI(Image|Color|Font|View|BezierPath|Application)|UTType|os_log|OSLog|Logger|ObservableObject|Published|Observable|ObservationIgnored|AnyCancellable|PassthroughSubject|CurrentValueSubject|simd_[a-z0-9_]+|CT(Font|Line|Frame|Run|Framesetter|Typesetter|Paragraph)[A-Za-z]*|SwiftUI|Combine|AppKit|UIKit|CoreImage|Accelerate)\b'
emit "'TOKEN' is not available outside Apple platforms" "$APPLE_RE" \
    < <(grep -rnE "$APPLE_RE" --include='*.swift' . | sed 's#^\./##' | grep -v "^$GEOMETRY:")
emit "main-thread / os logging assumption (DispatchQueue.main, @MainActor, os.Logger)" \
    < <(grep -rnE 'DispatchQueue\.main|@MainActor|\bos\.Logger' --include='*.swift' . | sed 's#^\./##')

# 4. CGAffineTransform needs the shim on Windows/Linux
if [ ! -f "$SHIM" ]; then
    emit "CGAffineTransform needs $CORE/$SHIM (swift-corelibs-foundation has no CGAffineTransform)" \
        < <(grep -rnE '\bCGAffineTransform\b' --include='*.swift' . | sed 's#^\./##')
fi

if [ $fail -ne 0 ]; then
    echo "check_core_portable: FAILED: $CORE must build with only Foundation (rules at the top of scripts/check_core_portable.sh)." >&2
    exit 1
fi
echo "check_core_portable: OK ($(wc -l < "$TMP/files" | tr -d ' ') files in $CORE)"
