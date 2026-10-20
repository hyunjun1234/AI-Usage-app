#!/bin/bash
# Build a fresh app and package it with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh
codesign --verify --deep --strict "AI Usage.app"

DMG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-dmg.XXXXXX")"
trap 'rm -rf "$DMG_WORK"' EXIT
mkdir "$DMG_WORK/payload"
ditto "AI Usage.app" "$DMG_WORK/payload/AI Usage.app"
ln -s /Applications "$DMG_WORK/payload/Applications"

hdiutil create -volname "AI Usage" -srcfolder "$DMG_WORK/payload" \
    -format UDZO "$DMG_WORK/AI Usage.dmg"
hdiutil verify "$DMG_WORK/AI Usage.dmg"
mv -f "$DMG_WORK/AI Usage.dmg" "AI Usage.dmg"

echo "Built: $(pwd)/AI Usage.dmg"
