#!/usr/bin/env bash
# Unit tests (hostless: they never launch the app or touch a ComfyUI server).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/signing.sh
xcodegen generate --quiet
xcodebuild -project ComfyBar.xcodeproj -scheme ComfyBar -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} test 2>&1 \
  | grep -E "Test Case .*(passed|failed|skipped)|Executed|error:|TEST (SUCCEEDED|FAILED)" | sed -e 's/\x1b\[[0-9;]*m//g'
