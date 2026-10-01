#!/usr/bin/env bash
# Builds the Release app, signs it ad hoc and installs it to /Applications.
# For machines without a signing identity: the hardened runtime is dropped,
# because it rejects the bundled frameworks when everything is ad hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${DERIVED_DATA:-$ROOT/build}"
BUILT="$DERIVED/Build/Products/Release/Boring Notch.app"
DEST="/Applications/Boring Notch.app"
ENTITLEMENTS="$DERIVED/app.entitlements"

xcodebuild -project "$ROOT/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
  -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build \
  | grep -E "error:|\*\* BUILD" || true
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found" >&2; exit 1; }

codesign -d --entitlements - --xml "$BUILT" 2>/dev/null > "$ENTITLEMENTS"

# Sign inside-out so every nested bundle is sealed before its parent.
find "$BUILT/Contents" -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.app" \) -print0 |
  while IFS= read -r -d '' item; do
    codesign --force --sign - --preserve-metadata=entitlements "$item" 2>/dev/null
  done
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUILT"
codesign --verify --deep --strict "$BUILT"

osascript -e 'tell application id "theboringteam.boringnotch" to quit' >/dev/null 2>&1 || true
sleep 1
if [ -d "$DEST" ]; then
  mv "$DEST" "$HOME/.Trash/Boring Notch $(date +%Y%m%d-%H%M%S).app"
fi
ditto "$BUILT" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
