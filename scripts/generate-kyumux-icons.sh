#!/usr/bin/env bash
# Generate yellow Kyu-mux icon variants by hue-shifting the cmux icons.
# Run once after the rebrand; output overwrites the appiconset PNGs in place.
#
# Tunings (chosen empirically to land on a clear, friendly yellow):
#   AppIcon (light)  : -modulate 105,180,8
#   AppIcon (dark)   : -modulate 105,180,8
#   AppIcon-Debug    : -modulate 105,180,8
#   AppIcon-Nightly  : regenerated via generate_nightly_icon.py from the new debug

set -euo pipefail

cd "$(dirname "$0")/.."

MAGICK=${MAGICK:-magick}
MODULATE="105,180,8"

shift_iconset() {
  local set_path="$1"
  local count=0
  for png in "$set_path"/*.png; do
    [[ -e "$png" ]] || continue
    "$MAGICK" "$png" -modulate "$MODULATE" "$png"
    count=$((count + 1))
  done
  echo "  shifted $count PNGs in $set_path"
}

echo "==> Generating Kyu-mux yellow icons (hue shift)"
shift_iconset "Assets.xcassets/AppIcon.appiconset"
shift_iconset "Assets.xcassets/AppIcon-Debug.appiconset"
shift_iconset "Assets.xcassets/AppIconLight.imageset"
shift_iconset "Assets.xcassets/AppIconDark.imageset"

echo "==> Regenerating Nightly icon from new Debug icon"
if [[ -x scripts/generate_nightly_icon.py ]]; then
  python3 scripts/generate_nightly_icon.py 2>/dev/null || \
    echo "  (skipping Nightly icon: generate_nightly_icon.py failed; not critical for dogfooding)"
else
  echo "  (skipping Nightly icon: script not found)"
fi

echo "==> Done. New icons are yellow."
