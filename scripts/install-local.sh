#!/usr/bin/env bash
# Builds the Release app, signs it ad hoc and installs it to /Applications.
# For machines without a signing identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${DERIVED_DATA:-$ROOT/build}"
BUILT="$DERIVED/Build/Products/Release/Boring Notch.app"
DEST="/Applications/Boring Notch.app"

xcodebuild -project "$ROOT/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
  -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build \
  | grep -E "error:|\*\* BUILD" || true
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found" >&2; exit 1; }

"$ROOT/scripts/adhoc-sign.sh" "$BUILT"

osascript -e 'tell application id "theboringteam.boringnotch" to quit' >/dev/null 2>&1 || true
sleep 1
if [ -d "$DEST" ]; then
  mv "$DEST" "$HOME/.Trash/Boring Notch $(date +%Y%m%d-%H%M%S).app"
fi
ditto "$BUILT" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
