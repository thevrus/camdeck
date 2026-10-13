#!/bin/bash
# Usage: scripts/release.sh 0.2.0
# Builds, zips, signs the update with the Sparkle key in your keychain, refreshes appcast.xml,
# pushes it, and publishes a GitHub Release. Installed apps pick it up automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first"; exit 1; }
export VERSION BUILD="$(git rev-list --count HEAD)"

make app
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="$OUT/Camdeck-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/Camdeck.app "$ZIP"

.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$OUT" \
    --download-url-prefix "https://github.com/thevrus/camdeck/releases/download/v$VERSION/"
cp "$OUT/appcast.xml" appcast.xml

git add appcast.xml
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "Camdeck $VERSION" --generate-notes
echo "released $VERSION"
