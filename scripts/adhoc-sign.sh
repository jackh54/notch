#!/usr/bin/env bash
# Signs a built app ad hoc, keeping its entitlements.
# The hardened runtime is dropped, because it rejects the bundled frameworks
# when everything is ad hoc signed.
# Usage: ./scripts/adhoc-sign.sh <path to .app>
set -euo pipefail

APP="${1:?App path required}"
ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$ENTITLEMENTS"

# Sign inside-out so every nested bundle is sealed before its parent.
find "$APP/Contents" -depth \( -name "*.framework" -o -name "*.xpc" -o -name "*.dylib" -o -name "*.app" \) -print0 |
  while IFS= read -r -d '' item; do
    codesign --force --sign - --preserve-metadata=entitlements "$item" 2>/dev/null
  done
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
