#!/bin/bash
# Builds build/packages/anyps5-desktop_<version>_amd64.deb from the Linux release bundle:
# /opt/anyps5-desktop, /usr/bin/anyps5-desktop, a desktop entry and the icon. The dependencies
# are read from the bundle's libraries (dpkg -S on what ldd resolves outside it), so build on
# the oldest distro it should install on (Ubuntu 22.04). SKIP_BUILD=1 packs an existing bundle.
source "$(dirname "$0")/common.sh"
build_bundle

PKG="$ROOT/build/deb/anyps5-desktop"
rm -rf "$ROOT/build/deb"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/anyps5-desktop" "$PKG/usr/bin" "$PKG/usr/share/applications" \
  "$PKG/usr/share/icons/hicolor/256x256/apps" "$PKG/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE/." "$PKG/opt/anyps5-desktop/"
ln -s /opt/anyps5-desktop/anyps5_desktop "$PKG/usr/bin/anyps5-desktop"
cp "$HERE/anyps5-desktop.desktop" "$PKG/usr/share/applications/"
cp "$HERE/anyps5-desktop.png" "$PKG/usr/share/icons/hicolor/256x256/apps/anyps5-desktop.png"
cp "$HERE/anyps5-desktop-512.png" "$PKG/usr/share/icons/hicolor/512x512/apps/anyps5-desktop.png"

# The packages that hold the system libraries the bundle links directly (its NEEDED entries
# that are not in the bundle), by their plain names (Ubuntu 24.04's t64 packages provide them),
# and the newest glibc symbol version it needs.
files=("$PKG/opt/anyps5-desktop/anyps5_desktop" "$PKG"/opt/anyps5-desktop/lib/*.so)
needed=$(for f in "${files[@]}"; do objdump -p "$f" | awk '/NEEDED/ {print $2}'; done | sort -u)
packages=$(for lib in $needed; do
    [ -e "$PKG/opt/anyps5-desktop/lib/$lib" ] && continue
    path=$(ldconfig -p | awk -v l="$lib" '$1 == l && /x86-64/ {print $NF; exit}')
    [ -n "$path" ] && { dpkg -S "$(readlink -f "$path")" 2>/dev/null || dpkg -S "$path" 2>/dev/null; } || true
  done | cut -d: -f1 | sed 's/t64$//' | grep -v '^libc6$' | sort -u)
glibc=$(for f in "${files[@]}"; do objdump -T "$f"; done \
  | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
depends="libc6 (>= $glibc)"
for package in $packages; do depends="$depends, $package"; done
depends="$depends, xdg-utils"

size=$(du -sk "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: anyps5-desktop
Version: $VERSION
Section: games
Priority: optional
Architecture: amd64
Maintainer: Utku Halis <personal@utkuhalis.com.tr>
Installed-Size: $size
Depends: $depends
Recommends: libsecret-tools
Homepage: https://github.com/utkuhalis/AnyPS5-Desktop
Description: PS5-style launcher for AnyPS5
 Finds PS5 game dumps in a games folder, unlocks them with the AnyPS5 toolkit
 (relinker and system libraries) and starts them, with controls, settings,
 saves, trophies and a phone controller per game.
CONTROL

TARGET="$OUT/anyps5-desktop_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$TARGET"
dpkg-deb --info "$TARGET" | sed -n '/Depends/p'
ls -l "$TARGET"
