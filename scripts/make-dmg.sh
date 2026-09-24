#!/usr/bin/env bash
# ComfyBar-v<version>.dmg from the notarised, stapled ComfyBar.app (drag-to-Applications
# layout), then sign, notarise and staple the DMG itself.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${NOTARY_PROFILE:-ComfyBarNotary}"
APP=ComfyBar.app
xcrun stapler validate "$APP" >/dev/null 2>&1 || { echo "Notarise the app first: scripts/notarize.sh"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/ComfyBar-v$VERSION.dmg"
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/ComfyBar.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "ComfyBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY=$(awk -F'"' '/Developer ID Application: .*\(3A3L2C6DFB\)/{print $2}' <<<"$IDENTITIES" | head -1)
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity for team 3A3L2C6DFB in the keychain."; exit 1; }
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "DMG: $ROOT/$DMG"
