#!/usr/bin/env bash
# Packages build/music_trainer (universal) into "Music Trainer.app" and a DMG.
# Usage: packaging/build-dmg.sh [version]
# Requires: macOS host (lipo, sips, iconutil, codesign, hdiutil) and a
# universal binary at build/music_trainer built by `make release-macos`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-v0.1.0-beta}"
BUILD="$ROOT/build"
APP_NAME="Music Trainer"
APP="$BUILD/$APP_NAME.app"
BUNDLE_ID="com.dantheobserver.music-trainer"

[ -x "$BUILD/music_trainer" ] || { echo "error: build/music_trainer not found — run 'make release-macos' first" >&2; exit 1; }
lipo -info "$BUILD/music_trainer"

# -- Icon: PNG -> icns (sips + iconutil) ---------------------------------------
ICONSET="$BUILD/icon.iconset"
rm -rf "$ICONSET" "$BUILD/icon.icns"
mkdir -p "$ICONSET"
sips -z 16 16   "$ROOT/packaging/icon.png" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$ROOT/packaging/icon.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$ROOT/packaging/icon.png" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$ROOT/packaging/icon.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$ROOT/packaging/icon.png" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$ROOT/packaging/icon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT/packaging/icon.png" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$ROOT/packaging/icon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUILD/icon.icns"
rm -rf "$ICONSET"

# -- App bundle -----------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/music_trainer" "$APP/Contents/MacOS/music_trainer"
chmod +x "$APP/Contents/MacOS/music_trainer"
# No bundled fonts on macOS: the app uses the system Arial font
# (see ui.odin), which ships with every macOS install.
cp "$BUILD/icon.icns" "$APP/Contents/Resources/icon.icns"
sed "s/@VERSION@/${VERSION#v}/g" "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"

# Ad-hoc signature: not notarized (Gatekeeper still asks on first launch),
# but avoids the stricter "damaged" warnings for unsealed binaries.
codesign --force -s - "$APP"

# -- DMG (drag-to-Applications layout) ------------------------------------------
STAGE="$BUILD/dmg-staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
	-o "$BUILD/Music-Trainer-macOS.dmg"
rm -rf "$STAGE"
echo "built: $BUILD/Music-Trainer-macOS.dmg"