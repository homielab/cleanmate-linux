#!/usr/bin/env bash
#
# Build the source packages for the Launchpad PPA in dist/ppa/: one per Ubuntu
# series, from one upstream tarball.
#
#   packaging/build-source.sh            # signed, ready for dput
#   packaging/build-source.sh -us -uc    # unsigned, to check it builds
#   SERIES="noble resolute" packaging/build-source.sh -us -uc
#
# SERIES defaults to the list at the top of .github/workflows/ppa.yml. Each
# series gets the version of debian/changelog plus "~<series>" (2.3.0-0ppa1~noble),
# because Launchpad takes a version once per PPA; the top changelog entry is
# rewritten for it in the build copy, never in debian/changelog itself.
#
# The upstream tarball holds every file git knows about (tracked, plus new files
# that aren't ignored) except debian/. Then:
#   dput ppa:homielab/cleanmate dist/ppa/cleanmate_<version>~<series>_source.changes
#
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' "$ROOT/cleanmate.sh")
DEB_VERSION=$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)
OUT=${OUT:-$ROOT/dist/ppa}
SERIES=${SERIES:-$(sed -n 's/^  SERIES: *"\{0,1\}\([a-z ]*\)"\{0,1\} *$/\1/p' "$ROOT/.github/workflows/ppa.yml")}
read -ra SERIES <<<"$SERIES"

((${#SERIES[@]})) || { echo "No Ubuntu series to build for (SERIES)." >&2; exit 1; }
for s in "${SERIES[@]}"; do
  [[ $s =~ ^[a-z]+$ ]] || { echo "Not an Ubuntu series name: $s" >&2; exit 1; }
done
[[ ${DEB_VERSION%%-*} == "$VERSION" ]] || {
  echo "debian/changelog is at $DEB_VERSION but cleanmate.sh says $VERSION." >&2
  echo "Add an entry first:  dch -v $VERSION-0ppa1 -D ${SERIES[0]} \"New upstream release.\"" >&2
  exit 1
}

WORK=$(mktemp -d -t cm-src.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SRC=$WORK/cleanmate-$VERSION

# upstream tarball
mkdir "$SRC"
(cd "$ROOT" && git ls-files -co --exclude-standard -z -- . ':!debian' ':!.github' |
  tar --null -T - -cf -) | tar -xf - -C "$SRC"
STAMP=$(cd "$ROOT" && git log -1 --format=%ct) # reproducible, and not "ancient" to lintian
tar -C "$WORK" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$STAMP" \
  -cJf "$WORK/cleanmate_$VERSION.orig.tar.xz" "cleanmate-$VERSION"

# packaging, once per series; every upload carries the same tarball (-sa), so
# Launchpad takes them in any order
for s in "${SERIES[@]}"; do
  rm -rf "$SRC/debian"
  cp -a "$ROOT/debian" "$SRC/debian"
  sed -i "1s/^cleanmate ([^)]*) [^;]*;/cleanmate ($DEB_VERSION~$s) $s;/" "$SRC/debian/changelog"
  (cd "$SRC" && dpkg-buildpackage -S -d -sa "$@")
done

mkdir -p "$OUT"
rm -f "$OUT"/cleanmate_*
cp "$WORK"/cleanmate_"$VERSION".orig.tar.xz "$WORK"/cleanmate_"$DEB_VERSION"~* "$OUT/"
echo "Source packages in $OUT:"
ls -1 "$OUT" | sed 's/^/  /'
