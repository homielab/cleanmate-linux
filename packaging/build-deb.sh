#!/usr/bin/env bash
#
# Build dist/cleanmate_<version>_all.deb — no root needed.
#
#   packaging/build-deb.sh
#   packaging/build-deb.sh --stage DIR   # only lay out the files in DIR (used by debian/rules)
#
set -euo pipefail

STAGE=
if [[ ${1:-} == --stage ]]; then
  [[ -n ${2:-} ]] || { echo "usage: $0 [--stage DIR]" >&2; exit 2; }
  STAGE=$2
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' "$ROOT/cleanmate.sh")
MAINTAINER=${MAINTAINER:-"HomieLab <contact@homielab.com>"}
APP_ID=com.homielab.CleanMate
OUT=${OUT:-$ROOT/dist}
if [[ -n $STAGE ]]; then
  mkdir -p "$STAGE"
  PKG=$(cd "$STAGE" && pwd)
else
  PKG=$(mktemp -d -t cm-deb.XXXXXX)
  trap 'rm -rf "$PKG"' EXIT
  chmod 755 "$PKG" # mktemp makes it private; the package root must be 755
fi

[[ -n $VERSION ]] || { echo "VERSION not found in cleanmate.sh" >&2; exit 1; }
echo "$([[ -n $STAGE ]] && echo Staging || echo Building) cleanmate $VERSION"

d() { install -d -m 755 "$PKG/$1"; }
f() { install -D -m "$1" "$2" "$PKG/$3"; } # MODE SOURCE TARGET

# the command (+ cm shorthand)
f 755 "$ROOT/cleanmate.sh" usr/bin/cleanmate
ln -s cleanmate "$PKG/usr/bin/cm"

# the desktop app
d usr/share/cleanmate/gui/cleanmate_gui
f 755 "$ROOT/gui/cleanmate-gui" usr/share/cleanmate/gui/cleanmate-gui
for py in "$ROOT"/gui/cleanmate_gui/*.py; do f 644 "$py" "usr/share/cleanmate/gui/cleanmate_gui/$(basename "$py")"; done
bash "$ROOT/po/compile.sh" "$PKG/usr/share/locale" # translations of the desktop app
: >"$PKG/usr/share/cleanmate/packaged" # tells the app that apt handles updates
chmod 644 "$PKG/usr/share/cleanmate/packaged"

# desktop integration
f 644 "$ROOT/data/$APP_ID.desktop" "usr/share/applications/$APP_ID.desktop"
f 644 "$ROOT/data/$APP_ID.metainfo.xml" "usr/share/metainfo/$APP_ID.metainfo.xml"
f 644 "$ROOT/data/icons/hicolor/scalable/apps/$APP_ID.svg" "usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
# PNG sizes for software centers that don't read SVG, rendered from the SVG (needs python3-gi)
python3 - "$ROOT/data/icons/hicolor/scalable/apps/$APP_ID.svg" "$PKG/usr/share/icons/hicolor" "$APP_ID" <<'PY' ||
import os, sys, gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
svg, out, app_id = sys.argv[1:]
for s in (64, 128, 256, 512):
    d = f"{out}/{s}x{s}/apps"
    os.makedirs(d, exist_ok=True)
    GdkPixbuf.Pixbuf.new_from_file_at_size(svg, s, s).savev(f"{d}/{app_id}.png", "png", [], [])
PY
  if [[ -n $STAGE ]]; then
    echo "PNG icons failed (needs python3-gi, gir1.2-gdkpixbuf-2.0, librsvg2-common)" >&2
    exit 1
  else
    echo "  (python3-gi missing: PNG icons skipped, the SVG is still installed)"
  fi
find "$PKG/usr/share/icons" -type d -exec chmod 755 {} + -o -type f -exec chmod 644 {} +
f 644 "$ROOT/packaging/polkit/$APP_ID.policy" "usr/share/polkit-1/actions/$APP_ID.policy"

# --stage stops here: debhelper installs the docs, copyright and control file itself
if [[ -n $STAGE ]]; then
  echo "Staged into $PKG"
  exit 0
fi

# documentation
f 644 "$ROOT/README.md" usr/share/doc/cleanmate/README.md
gzip -9n -c "$ROOT/CHANGELOG.md" >"$PKG/usr/share/doc/cleanmate/changelog.gz"
chmod 644 "$PKG/usr/share/doc/cleanmate/changelog.gz"
cat >"$PKG/usr/share/doc/cleanmate/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: cleanmate
Upstream-Contact: HomieLab <contact@homielab.com>
Source: https://github.com/homielab/cleanmate-linux

Files: *
Copyright: 2026 HomieLab
License: MIT
$(sed '1,/^Copyright/d' "$ROOT/LICENSE" | sed '/./,$!d' | sed 's/^$/./; s/^/ /')
EOF
chmod 644 "$PKG/usr/share/doc/cleanmate/copyright"

# control
d DEBIAN
installed_kb=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
cat >"$PKG/DEBIAN/control" <<EOF
Package: cleanmate
Version: $VERSION
Architecture: all
Maintainer: $MAINTAINER
Installed-Size: $installed_kb
Depends: bash (>= 5), coreutils, findutils, gawk | mawk, python3, python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1 (>= 1.5), pkexec | policykit-1
Recommends: curl | wget, libglib2.0-bin, libnotify-bin, desktop-file-utils, sqlite3, gir1.2-gstreamer-1.0
Section: admin
Priority: optional
Homepage: https://github.com/homielab/cleanmate-linux
Description: free up disk space and keep Ubuntu tidy
 CleanMate finds caches, old logs, leftovers from removed packages,
 developer and AI tool caches, and more — and removes them safely after you
 have reviewed the list. Inspired by CleanMyMac.
 .
 It comes as a desktop app (GTK 4) and a terminal app (cm) that share one
 engine. System items use the standard password dialog; everything else runs
 as you.
EOF

mkdir -p "$OUT"
deb="$OUT/cleanmate_${VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$deb" >/dev/null
echo "Built $deb ($(du -h "$deb" | cut -f1))"
