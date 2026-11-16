#!/usr/bin/env bash
#
# Lay out what `cm --update` downloads from a GitHub release, in OUT (default dist/):
#   cleanmate.sh            the script
#   cleanmate-app.tar.gz    the desktop app and icon (cleanmate-app/gui, cleanmate-app/data)
#   SHA256SUMS              sha256 of those two and of every .deb and .AppImage already in OUT
#                           (an AppImage updates itself to the release's image, checked against it)
#
#   packaging/build-update-assets.sh
#
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT:-$ROOT/dist}
mkdir -p "$OUT"

install -m 755 "$ROOT/cleanmate.sh" "$OUT/cleanmate.sh"
# reproducible: fixed owner, order and time; no caches
tar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
  --exclude=__pycache__ --exclude='*.pyc' --transform 's,^,cleanmate-app/,' \
  -czf "$OUT/cleanmate-app.tar.gz" gui data

cd "$OUT"
shopt -s nullglob
sha256sum cleanmate.sh cleanmate-app.tar.gz ./*.deb ./*.AppImage | sed 's,  \./,  ,' >SHA256SUMS
cat SHA256SUMS
