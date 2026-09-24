#!/usr/bin/env bash
# Builds Sources/ComfyBar/Assets.xcassets/AppIcon.appiconset from the app-icon SVG - every
# PNG rendered from the vector at its exact pixel size (never upscaled from a small PNG).
# The mark is never redrawn: this only scales and rasterises assets/ComfyBar-2f-nest-balanced-appicon.svg.
# Requires rsvg-convert (brew install librsvg). Output is committed so builds don't need it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/assets/ComfyBar-2f-nest-balanced-appicon.svg"
CAT="$ROOT/Sources/ComfyBar/Assets.xcassets"
SET="$CAT/AppIcon.appiconset"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing - brew install librsvg"; exit 1; }
rm -rf "$SET"; mkdir -p "$SET"
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$CAT/Contents.json"
entries=""
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    suffix=""; if [ "$scale" = 2 ]; then suffix="@2x"; fi
    name="icon_${pt}x${pt}${suffix}.png"
    rsvg-convert -w $px -h $px "$SVG" -o "$SET/$name"
    entries="$entries    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${pt}x${pt}\" },\n"
  done
done
printf '{\n  "images" : [\n%b  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "${entries%,\\n}\n" > "$SET/Contents.json"
python3 -m json.tool "$SET/Contents.json" >/dev/null && echo "AppIcon.appiconset: $(ls "$SET"/*.png | wc -l | tr -d ' ') PNGs from $(basename "$SVG")"
