#!/usr/bin/env bash
# Packages build/music_trainer into an AppImage.
# Usage: packaging/build-appimage.sh [x86_64|aarch64]
# Requires: a built binary at build/music_trainer, curl, and the appimagetool
# download (fetched automatically into build/tools/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-x86_64}"
BUILD="$ROOT/build"
APPDIR="$BUILD/AppDir"
NAME="Music-Trainer"

[ -x "$BUILD/music_trainer" ] || { echo "error: build/music_trainer not found — run 'make release' first" >&2; exit 1; }

# -- Stage the AppDir ---------------------------------------------------------
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin/fonts" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp "$BUILD/music_trainer"          "$APPDIR/usr/bin/"
cp /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf "$APPDIR/usr/bin/fonts/"
cp /usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf    "$APPDIR/usr/bin/fonts/"
cp "$ROOT/packaging/music_trainer.desktop" "$APPDIR/usr/share/applications/"
cp "$ROOT/packaging/icon.png"              "$APPDIR/usr/share/icons/hicolor/256x256/apps/music_trainer.png"
cp "$ROOT/packaging/icon.png"              "$APPDIR/.DirIcon"
cp "$ROOT/packaging/icon.png"              "$APPDIR/music_trainer.png"

# AppRun — launches the binary regardless of how the AppImage was mounted
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "${HERE}/usr/bin/music_trainer" "$@"
EOF
chmod +x "$APPDIR/AppRun"
cp "$ROOT/packaging/music_trainer.desktop" "$APPDIR/"

# -- Fetch appimagetool (self-contained, runs without FUSE via extract-and-run)
TOOLS="$BUILD/tools"
mkdir -p "$TOOLS"
cd "$TOOLS"
if [ ! -x "appimagetool-$ARCH.AppImage" ]; then
	echo "fetching appimagetool-$ARCH..."
	curl -fsSLO "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
	chmod +x "appimagetool-$ARCH.AppImage"
fi

export APPIMAGE_EXTRACT_AND_RUN=1
./"appimagetool-$ARCH.AppImage" --no-appstream "$APPDIR" "$BUILD/Music-Trainer-$ARCH.AppImage"
echo "built: $BUILD/Music-Trainer-$ARCH.AppImage"