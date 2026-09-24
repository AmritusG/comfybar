#!/usr/bin/env bash
# Publish v<version> on GitHub: tag, push, and a release with the notarised DMG + checksum.
# Refuses unless every pre-flight check passes and you pass --yes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ "${1:-}" = "--yes" ] || { echo "usage: scripts/release.sh --yes   (publishes publicly)"; exit 1; }
scripts/check-release.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ComfyBar.app/Contents/Info.plist)
DMG="build/ComfyBar-v$VERSION.dmg"
[ -f "$DMG" ] && xcrun stapler validate "$DMG" >/dev/null || { echo "Run scripts/make-dmg.sh first."; exit 1; }
NOTES="docs/release-notes/v$VERSION.md"
[ -f "$NOTES" ] || { echo "Write $NOTES first."; exit 1; }
git tag -a "v$VERSION" -m "ComfyBar $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$DMG" "$DMG.sha256" --title "ComfyBar $VERSION" --notes-file "$NOTES"
