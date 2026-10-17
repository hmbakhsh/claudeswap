#!/bin/bash
# Builds "Claude Account Switcher.app" (universal) and a shareable zip in ../dist/.
set -euo pipefail
cd "$(dirname "$0")"
NAME="Claude Account Switcher"
OUT="../dist"
APP="$OUT/$NAME.app"
ZIP="Claude-Account-Switcher.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -swift-version 5 -target "$arch-apple-macos13.0" Switcher.swift -o "$TMP/switcher-$arch"
done
lipo -create "$TMP"/switcher-* -output "$APP/Contents/MacOS/switcher"

swift icon.swift "$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset" && mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>dev.claude-swap.switcher</string>
  <key>CFBundleExecutable</key><string>switcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$APP"
(cd "$OUT" && rm -f "$ZIP" && ditto -c -k --keepParent "$NAME.app" "$ZIP")
echo "Built $OUT/$ZIP"
