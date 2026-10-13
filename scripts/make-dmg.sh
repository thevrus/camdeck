#!/bin/bash
# Usage: scripts/make-dmg.sh [out.dmg]  Wraps build/Camdeck.app with an Applications shortcut for drag-and-drop install.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/Camdeck.dmg}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Camdeck.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -quiet -volname "Camdeck" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$OUT"
echo "built $OUT"
