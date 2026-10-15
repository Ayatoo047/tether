#!/bin/bash
# Builds Tether.app and packages it as build/Tether-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

APP="build/Tether.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Tether-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "▸ Staging disk image contents"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING" 2>/dev/null || true   # use the custom volume icon if Xcode tools are present

echo "▸ Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Tether" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
