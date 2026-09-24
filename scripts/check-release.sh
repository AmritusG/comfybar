#!/usr/bin/env bash
# Pre-flight for a public release. Read-only: checks ./ComfyBar.app and the tree, changes
# nothing. Exit 0 only when every check passes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP=ComfyBar.app
fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

echo "== app bundle"
[ -d "$APP" ] || { echo "  FAIL  $APP missing - run scripts/build.sh"; exit 1; }
codesign --verify --deep --strict "$APP" 2>/dev/null && ok "signature valid (deep, strict)" || bad "codesign --verify"
info=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$info" && ok "Developer ID Application" || bad "not signed with Developer ID (ad-hoc builds cannot be notarised)"
echo "$info" | grep -q "^Timestamp=" && ok "secure timestamp" || bad "no secure timestamp"
echo "$info" | grep -Eq "flags=.*runtime" && ok "hardened runtime" || bad "hardened runtime off"
ents=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)
echo "$ents" | grep -q "get-task-allow" && bad "get-task-allow entitlement present (debug build?)" || ok "no get-task-allow"
ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
ok "version $ver ($build)"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ok "app icon" || bad "no AppIcon.icns"

echo "== repository"
[ -z "$(git status --porcelain)" ] && ok "working tree clean" || bad "uncommitted changes"
[ -f LICENSE ] && ok "LICENSE present" || bad "LICENSE missing"
git rev-parse -q --verify "refs/tags/v$ver" >/dev/null && bad "tag v$ver already exists - bump MARKETING_VERSION" || ok "tag v$ver free"
# nothing personal in tracked files (patterns kept in one place)
hits=$(git grep -n -I -i -P "/Users/[a-z]|@gmail\.com|@me\.com|claude-handoffs|scratchpad|~/Documents/claude|\bamrit\b|rosell|\bhis (mark|install|rule|choice)|story-arc/" -- . ':!scripts/check-release.sh' | head -5)
[ -z "$hits" ] && ok "no personal paths/addresses in tracked files" || { bad "personal data in tracked files:"; echo "$hits" | sed 's/^/        /'; }

echo
[ $fail = 0 ] && echo "PREFLIGHT PASSED" || echo "PREFLIGHT FAILED"
exit $fail
