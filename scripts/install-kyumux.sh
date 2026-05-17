#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/kyumux-install}"
APP_NAME="Kyu-mux"
DEST="/Applications/${APP_NAME}.app"

echo "==> Release build (this takes a few minutes the first time)"
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -10

BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: built app not found at $BUILT_APP" >&2
  exit 1
fi

echo "==> Built: $BUILT_APP"

if [[ -d "$DEST" ]]; then
  echo "==> Removing existing $DEST"
  rm -rf "$DEST"
fi

echo "==> Installing to $DEST"
cp -R "$BUILT_APP" "$DEST"

echo "==> Removing macOS quarantine attribute (so it opens without right-click-Open dance)"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Self-signing the bundle (ad-hoc, required for libraries to load)"
codesign --force --deep --sign - "$DEST" 2>&1 | tail -5 || true

echo ""
echo "============================================================"
echo "  Installed: $DEST"
echo "  Bundle ID: $(defaults read "$DEST/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo '?')"
echo "  Open from: Launchpad / Spotlight / Dock / 'open -a Kyu-mux'"
echo "============================================================"
