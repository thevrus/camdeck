#!/bin/bash
# Usage: scripts/release.sh 0.2.0
# Tags the current commit and pushes it; .github/workflows/release.yml builds and publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first"; exit 1; }
git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"
echo "tagged v$VERSION; watch: gh run watch"
