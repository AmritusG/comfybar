#!/usr/bin/env bash
# Orphan cleanup: before AND after every build / launch, end any running ComfyBar app
# process and confirm none remain. Matches the app's own executable path only, so editors,
# terminals or Xcode with "ComfyBar" in their arguments are never touched.
PATTERN='ComfyBar\.app/Contents/MacOS/ComfyBar'
pkill -9 -f "$PATTERN"
sleep 2
n=$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')
echo "cleanup: ComfyBar processes remaining = $n"
[ "$n" = "0" ]
