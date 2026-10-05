#!/bin/zsh
# Builds ImageCrat.app (release) into ./build.
# The SwiftPM product is still called "Lumen" (the internal module name); it is installed as Contents/MacOS/ImageCrat.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
CONFIG=${1:-release}
# version shown in About / bug reports: IMAGECRAT_VERSION (marketing) and a build number from the build time
# (the older LUMEN_VERSION / LUMEN_BUILD are still honoured)
VERSION=${IMAGECRAT_VERSION:-${LUMEN_VERSION:-1.0}}
BUILD=${IMAGECRAT_BUILD:-${LUMEN_BUILD:-$(date +%Y%m%d.%H%M)}}
NAME=ImageCrat                       # CFBundleName / CFBundleExecutable: crash reports are ImageCrat-<date>.ips
BUNDLE_ID=app.imagecrat.editor

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Lumen

APP="$ROOT/build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# SwiftPM resource bundles of dependencies. Their generated accessor looks in the app's root folder (which would
# break the code signature) and then at the absolute build path, so they go in Contents/Resources: SAM 3.1's CLIP
# tokenizer (sam31-swift_SAM31.bundle/Resources/clip-vocab.json, clip-merges.txt) is found there by
# SAM3Resources.swift, which points the package's lookup at it.
for b in "$(dirname "$BIN")"/sam31-swift_*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
for f in clip-vocab.json clip-merges.txt; do
  [ -f "$APP/Contents/Resources/sam31-swift_SAM31.bundle/Resources/$f" ] || { echo "✗ SAM 3.1 tokenizer file $f missing from the app bundle"; exit 1; }
done
# dynamic frameworks from SwiftPM binary targets (C2PAC for Content Credentials)
for FW in "$(dirname "$BIN")"/*.framework(N); do
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$FW" "$APP/Contents/Frameworks/$(basename "$FW")"
done
if [ -d "$APP/Contents/Frameworks" ]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$NAME" 2>/dev/null || true
fi
# MLX Metal kernels for SAM 3.1 (built once with xcodebuild)
echo "▸ MLX Metal kernels…"
# (as the SwiftPM-style resource bundle in Contents/Resources, where MLX looks for it: a non-code file in
#  Contents/MacOS can't be signed for notarization)
if "$ROOT/scripts/build_mlx_metallib.sh" "$CONFIG" >/dev/null; then
  ditto "$ROOT/.build/mlx-metallib/dd/Build/Products/Release/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
else
  echo "  (skipped: SAM 3.1 will be unavailable)"
fi

# App icon: Resources/AppIcon.icns is the ImageCrat icon (a copy of Resources/IconSource/ImageCrat.icns, made from
# IconSource/imagecrat-icon-1024.png). It is never generated here.
ICON="$ROOT/Resources/AppIcon.icns"
[ -f "$ICON" ] || ICON="$ROOT/Resources/IconSource/ImageCrat.icns"
[ -f "$ICON" ] || { echo "✗ App icon missing: Resources/AppIcon.icns (copy Resources/IconSource/ImageCrat.icns there)"; exit 1; }
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Document icon for .imagecrat (and legacy .lumen) files: a page with the ImageCrat emblem (scripts/make_document_icon.py)
DOCICON="$ROOT/Resources/ImageCratDocument.icns"
if [ ! -f "$DOCICON" ]; then
  echo "▸ Generating the document icon…"
  python3 "$ROOT/scripts/make_document_icon.py" "$ROOT/Resources/IconSource/imagecrat-icon-1024.png" "$DOCICON" >/dev/null \
    || { echo "✗ Could not generate Resources/ImageCratDocument.icns (needs Python 3 with Pillow)"; exit 1; }
fi
cp "$DOCICON" "$APP/Contents/Resources/ImageCratDocument.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.imagecrat.document</string>
      <key>UTTypeDescription</key><string>ImageCrat Document</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
      <key>UTTypeIconFile</key><string>ImageCratDocument</string>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>imagecrat</string></array></dict>
    </dict>
    <dict>
      <!-- ImageCrat's own brush sets (Brushes panel ▸ Export): a zip of manifest.json + PNG tips -->
      <key>UTTypeIdentifier</key><string>app.imagecrat.brushes</string>
      <key>UTTypeDescription</key><string>ImageCrat Brushes</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>icbrushes</string></array></dict>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <!-- documents saved before the rename: the same format, still opened and saved in place -->
      <key>UTTypeIdentifier</key><string>app.lumen.document</string>
      <key>UTTypeDescription</key><string>Lumen Document (legacy)</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
      <key>UTTypeIconFile</key><string>ImageCratDocument</string>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>lumen</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.adobe.photoshop-large-image</string>
      <key>UTTypeDescription</key><string>Photoshop Large Document</string>
      <key>UTTypeConformsTo</key><array><string>public.image</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>psb</string></array></dict>
    </dict>
    <!-- brush files: imported into the Brushes panel (BrushLibrary.importInBackground), never opened as documents -->
    <dict>
      <key>UTTypeIdentifier</key><string>com.adobe.photoshop-brush</string>
      <key>UTTypeDescription</key><string>Photoshop Brushes</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>abr</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.adobe.photoshop-tool-preset</string>
      <key>UTTypeDescription</key><string>Photoshop Tool Presets</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>tpl</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>org.gimp.gbr</string>
      <key>UTTypeDescription</key><string>GIMP Brush</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>gbr</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>org.gimp.gih</string>
      <key>UTTypeDescription</key><string>GIMP Image Pipe Brush</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>gih</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.savage.procreate.brush</string>
      <key>UTTypeDescription</key><string>Procreate Brush</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>brush</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.savage.procreate.brushset</string>
      <key>UTTypeDescription</key><string>Procreate Brush Set</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>brushset</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>org.krita.kpp</string>
      <key>UTTypeDescription</key><string>Krita Brush Preset</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>kpp</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>ImageCrat Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeIconFile</key><string>ImageCratDocument</string>
      <key>LSItemContentTypes</key><array><string>app.imagecrat.document</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Lumen Document (legacy)</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>CFBundleTypeIconFile</key><string>ImageCratDocument</string>
      <key>LSItemContentTypes</key><array><string>app.lumen.document</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.png</string><string>public.jpeg</string><string>public.tiff</string><string>public.heic</string>
        <string>com.compuserve.gif</string><string>com.microsoft.bmp</string><string>com.adobe.photoshop-image</string><string>com.adobe.photoshop-large-image</string><string>org.webmproject.webp</string><string>public.svg-image</string><string>com.adobe.pdf</string><string>com.adobe.illustrator.ai-image</string>
      </array>
    </dict>
    <dict>
      <!-- Importer: double-clicking / dropping these on the Dock icon imports them into the Brushes panel. (Launch
           Services knows Editor / Viewer / Shell / None roles; Viewer is the one that doesn't claim to save them.) -->
      <key>CFBundleTypeName</key><string>Brushes</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.adobe.photoshop-brush</string><string>com.adobe.photoshop-tool-preset</string><string>org.gimp.gbr</string><string>org.gimp.gih</string><string>com.savage.procreate.brush</string><string>com.savage.procreate.brushset</string><string>org.krita.kpp</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>ImageCrat Brushes</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.imagecrat.brushes</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP"
