#!/bin/bash
# Builds build/packages/AnyPS5-Desktop-<version>-x86_64.AppImage from the Linux release bundle.
# Build on the oldest distro it should run on (Ubuntu 22.04: glibc 2.35); GTK 3 comes from the
# system. SKIP_BUILD=1 packs an existing bundle. Needs curl the first time (appimagetool).
source "$(dirname "$0")/common.sh"
build_bundle

TOOL="${APPIMAGETOOL:-$ROOT/build/appimagetool-x86_64.AppImage}"
if [ ! -x "$TOOL" ]; then
  curl -fsSL -o "$TOOL" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOL"
fi

APPDIR="$ROOT/build/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib/anyps5-desktop" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps" "$APPDIR/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE/." "$APPDIR/usr/lib/anyps5-desktop/"
cp "$HERE/anyps5-desktop.desktop" "$APPDIR/usr/share/applications/"
# .anyps5theme files (the MIME type the desktop entry opens).
mkdir -p "$APPDIR/usr/share/mime/packages"
cp "$HERE/anyps5-desktop-mime.xml" "$APPDIR/usr/share/mime/packages/anyps5-desktop.xml"
cp "$HERE/anyps5-desktop.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/anyps5-desktop.png"
cp "$HERE/anyps5-desktop-512.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/anyps5-desktop.png"
cp "$HERE/anyps5-desktop.desktop" "$APPDIR/anyps5-desktop.desktop"
cp "$HERE/anyps5-desktop.png" "$APPDIR/anyps5-desktop.png"
ln -s anyps5-desktop.png "$APPDIR/.DirIcon"
cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
# The icon for the window, from the AppImage's own icon theme folder.
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/lib/anyps5-desktop/anyps5_desktop" "$@"
RUN
chmod +x "$APPDIR/AppRun"

TARGET="$OUT/AnyPS5-Desktop-$VERSION-x86_64.AppImage"
# Extract-and-run: no FUSE needed where it is built (containers, WSL).
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --no-appstream "$APPDIR" "$TARGET"
ls -l "$TARGET"
