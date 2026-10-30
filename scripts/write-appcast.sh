#!/usr/bin/env bash
# Signs a DMG and writes a Sparkle appcast with one item pointing at it.
# The private key is read from SPARKLE_PRIVATE_KEY.
# Usage: ./scripts/write-appcast.sh <sign_update> <path to .app> <dmg> <download url> <output xml>
set -euo pipefail

SIGN_UPDATE="${1:?sign_update path required}"
APP="${2:?App path required}"
DMG="${3:?DMG path required}"
URL="${4:?Download URL required}"
OUTPUT="${5:?Output path required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

PLIST="$APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
MINIMUM_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw "$PLIST")"
SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"

cat > "$OUTPUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Boring Notch (jackh54/notch)</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
