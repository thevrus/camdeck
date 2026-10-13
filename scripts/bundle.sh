#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Camdeck"
APP=build/Camdeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Camdeck"
# SwiftPM resource bundle for UVCKit (device profiles); Bundle.module finds it in Resources.
cp -R "$(dirname "$BIN")"/*UVCKit.bundle "$APP/Contents/Resources/"
# Liquid Glass icon (macOS 26): Icon Composer .icon compiled to Assets.car + legacy .icns
xcrun actool scripts/Camdeck.icon --compile "$APP/Contents/Resources" --app-icon Camdeck \
    --platform macosx --minimum-deployment-target 26.0 \
    --output-partial-info-plist build/icon-info.plist >/dev/null
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.camdeck</string>
    <key>CFBundleIconFile</key><string>Camdeck</string>
    <key>CFBundleIconName</key><string>Camdeck</string>
    <key>CFBundleName</key><string>Camdeck</string>
    <key>CFBundleDisplayName</key><string>Camdeck</string>
    <key>CFBundleExecutable</key><string>Camdeck</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>Camdeck shows a live preview of your camera and adjusts its controls.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
