#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# UNIVERSAL=1 builds for Apple silicon and Intel, for a copy handed to other Macs.
# Multi-arch builds need Xcode's build system; a plain local build only needs Command Line Tools.
if [ "${UNIVERSAL:-0}" = 1 ]; then
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift build -c release --product Lilt --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Lilt
else
  swift build -c release --product Lilt
  BIN=.build/release/Lilt
fi
APP="$PWD/build/Lilt.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj"
# Swapped in by rename: a copy of the app that is running keeps the file it started from.
cp "$BIN" "$APP/Contents/MacOS/Lilt.new" && mv -f "$APP/Contents/MacOS/Lilt.new" "$APP/Contents/MacOS/Lilt"
# Always rewrite: PlistBuddy "Print" exits 0 for a missing file, so an existence probe never created it.
# The zh-Hans region and .lproj make AppKit's own menus, dialogs and tooltips follow the Chinese UI.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.lilt.desktop</string>
<key>CFBundleName</key><string>Lilt</string>
<key>CFBundleDisplayName</key><string>Lilt</string>
<key>CFBundleExecutable</key><string>Lilt</string>
<key>CFBundleIconFile</key><string>LiltOrbit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleShortVersionString</key><string>0.1.5</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
REVISION=$(git rev-parse --short HEAD)
if ! git diff --quiet HEAD -- Sources scripts; then REVISION="$REVISION+modified"; fi
plutil -insert LiltSourceRevision -string "$REVISION" "$APP/Contents/Info.plist"
plutil -insert LiltBuildTime -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$APP/Contents/Info.plist"
printf '"CFBundleDisplayName" = "Lilt";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
# Lilt green as the app accent, so system-drawn parts (focus rings, settings controls) match the rest.
# actool ships with Xcode only; without it the app simply keeps the system accent colour.
rm -f "$APP/Contents/Resources/Assets.car"
if ACTOOL_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" && [ -x "$ACTOOL_DIR/usr/bin/actool" ]; then
  if DEVELOPER_DIR="$ACTOOL_DIR" xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
      --platform macosx --minimum-deployment-target 26.0 --accent-color AccentColor \
      --output-partial-info-plist "$PWD/build/assets-info.plist" >/dev/null 2>&1 && [ -f "$APP/Contents/Resources/Assets.car" ]; then
    plutil -insert NSAccentColorName -string AccentColor "$APP/Contents/Info.plist"
  else
    echo "note: asset catalog not compiled; using the system accent colour" >&2
  fi
else
  echo "note: Xcode's actool not found; using the system accent colour" >&2
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null
swift scripts/make-icon.swift "$PWD/build"
# A new resource name and build number invalidate cached icons from the original green identity.
rm -f "$APP/Contents/Resources/Lilt.icns"
iconutil -c icns "$PWD/build/Lilt.iconset" -o "$APP/Contents/Resources/LiltOrbit.icns"
cp "$PWD/build/LiltMenu.png" "$PWD/build/LiltMenu@2x.png" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
touch "$APP"
echo "$APP"
