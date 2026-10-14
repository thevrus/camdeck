#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
# swiftbuild is the default from Swift 6.4; Xcode 26 needs it asked for. The App Intents step below
# reads its Intermediates.noindex layout, which the older native build system does not write.
swift build -c release --build-system swiftbuild
BIN="$(swift build -c release --build-system swiftbuild --show-bin-path)/Camdeck"
APP=build/Camdeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Camdeck"
# Sparkle (auto-update) lives next to the binary in the SwiftPM bin dir.
cp -R "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Camdeck"
# SwiftPM resource bundle for UVCKit (device profiles); Bundle.module finds it in Resources.
cp -R "$(dirname "$BIN")/Camdeck_UVCKit.bundle" "$APP/Contents/Resources/"
# Liquid Glass icon (macOS 26): Icon Composer .icon compiled to Assets.car + legacy .icns
xcrun actool scripts/Camdeck.icon --compile "$APP/Contents/Resources" --app-icon Camdeck \
    --platform macosx --minimum-deployment-target 26.0 \
    --output-partial-info-plist build/icon-info.plist >/dev/null
# App Intents (Shortcuts): `swift build` emits the const-values but never runs the metadata
# extractor, so run appintentsmetadataprocessor by hand. It writes <output>/Metadata.appintents.
# Best effort: a toolchain with a different build layout loses the Shortcuts actions, not the release.
appintents() {
    # Swift 6.4 writes Camdeck-p.build/Camdeck.SwiftFileList; 6.3 writes Camdeck-<hash>-testable.build/
    # Camdeck-<hash>-testable.SwiftFileList. The const-values file sits next to it either way.
    local list; list="$(find .build -path '*/Release/*/Objects-normal/arm64/*' \
        \( -name Camdeck.SwiftFileList -o -name 'Camdeck-*-testable.SwiftFileList' \) | head -1)"
    [ -n "$list" ] || { echo "appintents: no Camdeck SwiftFileList under .build" >&2; return 1; }
    local lists; lists="$(mktemp -d)"
    cp "$list" "$lists/src.txt"
    echo "${list%.SwiftFileList}-primary.swiftconstvalues" > "$lists/const.txt"
    xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" \
        --module-name Camdeck --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
        --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macosx26.0 \
        --source-file-list "$lists/src.txt" --swift-const-vals-list "$lists/const.txt" >/dev/null
    rm -rf "$lists"
    [ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]
}
appintents || {
    echo "warning: App Intents metadata not generated; Shortcuts actions will be missing" >&2
    if [ -n "${CI:-}" ]; then
        # Enough to see what this toolchain wrote instead of the expected layout.
        swift --version >&2; ls -d /Applications/Xcode* >&2
        find .build \( -name '*.SwiftFileList' -o -name '*.swiftconstvalues' \) -path '*Camdeck*' | head -20 >&2
        exit 1
    fi
}
cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/thevrus/camdeck/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>asQY/g4bqi8QoL8O3CQuX5CsaSb1TgrMb6nuIacY3qI=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>app.camdeck.url</string>
        <key>CFBundleURLSchemes</key><array><string>camdeck</string></array>
    </dict></array>
    <key>NSCameraUsageDescription</key><string>Camdeck shows a live preview of your camera and adjusts its controls.</string>
</dict>
</plist>
PLIST
# Ad-hoc sign inside-out: Sparkle helpers, framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for x in "$FW"/XPCServices/*.xpc "$FW/Updater.app" "$FW/Autoupdate"; do codesign --force --sign - "$x"; done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
echo "built $APP"
