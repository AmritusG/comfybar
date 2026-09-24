#!/usr/bin/env bash
# Notarise ./ComfyBar.app with Apple, staple the ticket, and verify Gatekeeper accepts it.
#
# One-time setup (stores an app-specific password in your login keychain):
#   xcrun notarytool store-credentials ComfyBarNotary \
#       --apple-id <your Apple ID> --team-id 3A3L2C6DFB
#   (it prompts for an app-specific password from appleid.apple.com)
# Override the profile name with NOTARY_PROFILE=...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${NOTARY_PROFILE:-ComfyBarNotary}"
APP=ComfyBar.app
[ -d "$APP" ] || { echo "Build first: scripts/build.sh"; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "ComfyBar.app is not Developer ID signed - notarisation would be rejected."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "No working notarytool profile '$PROFILE' - see the setup note at the top of this script."; exit 1; }

ZIP="build/ComfyBar-notarize.zip"
mkdir -p build; rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> submitting $(du -h "$ZIP" | cut -f1) to Apple (usually 1-10 min)"
out=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1) || true
echo "$out"
id=$(echo "$out" | awk '/^  id:/{print $2; exit}')
if ! echo "$out" | grep -q "status: Accepted"; then
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" build/notary-log.json && echo "log: build/notary-log.json"
  echo "NOTARISATION FAILED"; exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$ZIP"
echo "notarised and stapled: $ROOT/$APP (submission $id)"
