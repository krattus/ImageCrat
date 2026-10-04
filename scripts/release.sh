#!/bin/zsh
# Builds ImageCrat.app, signs it with your Developer ID (hardened runtime), notarizes it with Apple, staples the ticket
# and packages a DMG (plus a ZIP) in ./dist for testers.
#
#   scripts/release.sh                 full build → sign → notarize → staple → dist/ImageCrat-<version>-<build>.dmg
#   scripts/release.sh --no-notarize   sign and package only (to test signing before the notary profile exists)
#   scripts/release.sh --skip-build    re-sign/package the existing build/ImageCrat.app
#
# One-time setup (see dist/HOW-TO-RELEASE.md):
#   • a "Developer ID Application" certificate in your login keychain (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates)
#   • notary credentials saved under the profile name below:
#       xcrun notarytool store-credentials imagecrat-notary --apple-id <you@example.com> --team-id <TEAMID>
#     (it asks for an app-specific password from appleid.apple.com; nothing is stored in this project)
# Overrides: IMAGECRAT_SIGN_ID="Developer ID Application: Name (TEAMID)", IMAGECRAT_NOTARY_PROFILE=imagecrat-notary,
#            IMAGECRAT_VERSION=1.0 (the older LUMEN_SIGN_ID / LUMEN_NOTARY_PROFILE / LUMEN_VERSION still work as fallbacks)
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/ImageCrat.app"
DIST="$ROOT/dist"
ENT="$ROOT/scripts/Lumen.entitlements"    # (file name kept; the entitlements are not tied to the app's name)
PROFILE=${IMAGECRAT_NOTARY_PROFILE:-${LUMEN_NOTARY_PROFILE:-imagecrat-notary}}
# (IMAGECRAT_VERSION / LUMEN_VERSION are read by build_app.sh)
NOTARIZE=1; BUILD=1
for a in "$@"; do
  case $a in
    --no-notarize) NOTARIZE=0 ;;
    --skip-build) BUILD=0 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done

# ── identity ────────────────────────────────────────────────────────────────────────────────────────────────────
SIGN_ID=${IMAGECRAT_SIGN_ID:-${LUMEN_SIGN_ID:-}}
[ -n "$SIGN_ID" ] || SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
if [ -z "$SIGN_ID" ]; then
  echo "✗ No 'Developer ID Application' certificate found in your keychain."
  echo "  Create one in Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ + ▸ Developer ID Application."
  exit 1
fi
echo "▸ Signing identity: $SIGN_ID"
if [ $NOTARIZE = 1 ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "✗ No notary credentials saved as '$PROFILE'. Run once:"
  echo "    xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id <your Team ID>"
  echo "  (or re-run with --no-notarize to only sign)"
  exit 1
fi

# ── build ───────────────────────────────────────────────────────────────────────────────────────────────────────
[ $BUILD = 1 ] && "$ROOT/scripts/build_app.sh" release
[ -d "$APP" ] || { echo "✗ $APP not found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILDNO=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
NAME="ImageCrat-$VERSION-$BUILDNO"

# ── sign, inside out (no --deep: every piece of code gets the same identity, runtime and a secure timestamp) ────
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$@"; }
echo "▸ Signing nested code…"
chmod -R u+w "$APP"   # SwiftPM copies some package resources read-only
xattr -cr "$APP"
for fw in "$APP"/Contents/Frameworks/*.framework(N); do sign "$fw"; done
for dylib in "$APP"/Contents/Frameworks/*.dylib(N); do sign "$dylib"; done
# Mach-O executables inside resource bundles (none today, but SwiftPM bundles may grow some)
find "$APP/Contents/Resources" -type f -perm -111 -print0 | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O && sign "$f"
done
echo "▸ Signing ImageCrat.app…"
sign --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime" || true

mkdir -p "$DIST"
ZIP="$DIST/$NAME.zip"
DMG="$DIST/$NAME.dmg"
rm -f "$ZIP" "$DMG"

# ── notarize the app (via a zip), staple it ─────────────────────────────────────────────────────────────────────
if [ $NOTARIZE = 1 ]; then
  echo "▸ Notarizing the app (usually a few minutes)…"
  ditto -c -k --keepParent "$APP" "$DIST/notarize-upload.zip"
  xcrun notarytool submit "$DIST/notarize-upload.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$DIST/notary-app.json" || true
  rm -f "$DIST/notarize-upload.zip"
  STATUS=$(python3 -c "import json;print(json.load(open('$DIST/notary-app.json')).get('status',''))" 2>/dev/null)
  if [ "$STATUS" != "Accepted" ]; then
    ID=$(python3 -c "import json;print(json.load(open('$DIST/notary-app.json')).get('id',''))" 2>/dev/null)
    echo "✗ Notarization status: ${STATUS:-unknown}"
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$DIST/notary-log.json" && echo "  Apple's log: $DIST/notary-log.json"
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# ── package: ZIP and DMG (the DMG is signed, notarized and stapled too, so it opens without warnings) ───────────────
echo "▸ Packaging…"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/ImageCrat.app"
ln -s /Applications "$STAGE/Applications"
[ -f "$ROOT/dist/README-FOR-TESTERS.md" ] && cp "$ROOT/dist/README-FOR-TESTERS.md" "$STAGE/Read Me First.md"
[ -f "$ROOT/dist/Testing Checklist.md" ] && cp "$ROOT/dist/Testing Checklist.md" "$STAGE/Testing Checklist.md"
# Built in a blank read-write image mounted at a private mount point, then compressed: `hdiutil create -srcfolder`
# copies through /Volumes, which macOS can refuse ("Operation not permitted") for the calling app, and `makehybrid`
# stamps com.apple.FinderInfo on every file, which breaks `codesign --verify --strict` of the app inside.
RW=$(mktemp -d)
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 64 ))
hdiutil create -quiet -size ${SIZE_MB}m -fs HFS+ -volname "ImageCrat $VERSION" -type UDIF "$RW/rw.dmg"
mkdir "$RW/mnt"
hdiutil attach -quiet -nobrowse -readwrite -mountpoint "$RW/mnt" "$RW/rw.dmg"
ditto "$STAGE" "$RW/mnt"
codesign --verify --deep --strict "$RW/mnt/ImageCrat.app"
hdiutil detach -quiet "$RW/mnt"
hdiutil convert -quiet "$RW/rw.dmg" -format UDZO -o "$DMG"
rm -rf "$STAGE" "$RW"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
if [ $NOTARIZE = 1 ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$DIST/notary-dmg.json" || true
  STATUS=$(python3 -c "import json;print(json.load(open('$DIST/notary-dmg.json')).get('status',''))" 2>/dev/null)
  [ "$STATUS" = "Accepted" ] || { echo "✗ DMG notarization status: ${STATUS:-unknown}"; exit 1; }
  xcrun stapler staple "$DMG"
fi

# ── final checks: what Gatekeeper on the tester's Mac will say ──────────────────────────────────────────────────
echo "▸ Gatekeeper assessment:"
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/  /'
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/  /' || true
echo "✓ $DMG"
echo "✓ $ZIP"
