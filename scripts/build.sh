#!/usr/bin/env bash
# Release build -> ./ComfyBar.app (gitignored). Developer ID signed when the maintainer's
# identity is present, ad-hoc otherwise (see scripts/signing.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${CONFIG:-Release}"
source scripts/signing.sh
command -v xcodegen >/dev/null || { echo "xcodegen missing - brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project ComfyBar.xcodeproj -scheme ComfyBar -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build -quiet
APP="build/DerivedData/Build/Products/$CONFIG/ComfyBar.app"
rm -rf ComfyBar.app
ditto "$APP" ComfyBar.app          # ditto preserves timestamps and signatures
codesign --verify --deep --strict --verbose=2 ComfyBar.app
codesign -dv --verbose=2 ComfyBar.app 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Runtime Version|Timestamp|Signature=adhoc)" || true
echo "built: $ROOT/ComfyBar.app ($CONFIG, signing: $SIGN)"
