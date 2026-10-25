#!/usr/bin/env bash
#
# Build the source package for the Launchpad PPA in dist/ppa/.
#
#   packaging/build-source.sh            # signed, ready for dput
#   packaging/build-source.sh -us -uc    # unsigned, to check it builds
#
# The upstream tarball holds every file git knows about (tracked, plus new files
# that aren't ignored) except debian/. Then:
#   dput ppa:homielab/clean-my-ubuntu dist/ppa/cleanmate_<version>_source.changes
#
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' "$ROOT/cleanmate.sh")
DEB_VERSION=$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)
OUT=${OUT:-$ROOT/dist/ppa}

[[ ${DEB_VERSION%%-*} == "$VERSION" ]] || {
  echo "debian/changelog is at $DEB_VERSION but cleanmate.sh says $VERSION." >&2
  echo "Add an entry first:  dch -v $VERSION-0ppa1 -D noble \"New upstream release.\"" >&2
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

# packaging
cp -a "$ROOT/debian" "$SRC/debian"
(cd "$SRC" && dpkg-buildpackage -S -d -sa "$@")

mkdir -p "$OUT"
cp "$WORK"/cleanmate_"$VERSION".orig.tar.xz "$WORK"/cleanmate_"$DEB_VERSION"* "$OUT/"
echo "Source package in $OUT:"
ls -1 "$OUT" | sed 's/^/  /'
