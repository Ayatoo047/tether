#!/bin/bash
# Builds Tether.app into ./build (release, ad-hoc signed, adb bundled inside).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tether.app"
echo "▸ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Tether"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tether"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

echo "▸ Rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

ADB_SRC="$(command -v adb || true)"
if [[ -n "$ADB_SRC" ]]; then
  echo "▸ Bundling adb from $ADB_SRC"
  cp -L "$ADB_SRC" "$APP/Contents/MacOS/adb"
else
  echo "⚠︎ adb not found; the app will need platform-tools installed (brew install --cask android-platform-tools)"
fi

echo "▸ Bundling libmtp + libusb (USB File transfer support)"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"
bundle_dylib() {  # copy a Homebrew dylib into Frameworks and repoint references to it
  local src="$1" name
  name="$(basename "$src")"
  if [[ -f "$FW/$name" ]]; then return 0; fi
  cp -L "$src" "$FW/$name"
  chmod u+w "$FW/$name"
  install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
  # Recurse into this library's own Homebrew dependencies.
  otool -L "$FW/$name" | awk 'NR>1 {print $1}' | { grep -E '^/(opt/homebrew|usr/local)/' || true; } | while read -r dep; do
    bundle_dylib "$dep"
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$FW/$name" 2>/dev/null
  done
}
otool -L "$APP/Contents/MacOS/Tether" | awk 'NR>1 {print $1}' | { grep -E '^/(opt/homebrew|usr/local)/' || true; } | while read -r dep; do
  bundle_dylib "$dep"
  install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$APP/Contents/MacOS/Tether" 2>/dev/null
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Tether" 2>/dev/null || true

echo "▸ Signing (ad-hoc)"
for lib in "$FW"/*.dylib; do codesign --force --sign - "$lib"; done
codesign --force --sign - "$APP/Contents/MacOS/Tether"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
