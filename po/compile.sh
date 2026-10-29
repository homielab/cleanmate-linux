#!/usr/bin/env bash
# Compile po/*.po into DEST/<lang>/LC_MESSAGES/cleanmate.mo (needs msgfmt from gettext).
#   po/compile.sh gui/locale          run the desktop app from a checkout in your language
#   po/compile.sh "$PKG/usr/share/locale"   packaging
set -euo pipefail
dest=${1:?usage: po/compile.sh DEST}
[[ $dest == /* ]] || dest=$PWD/$dest
cd "$(dirname "$0")"
for po in *.po; do
  lang=${po%.po}
  install -d -m 755 "$dest/$lang/LC_MESSAGES"
  msgfmt --check -o "$dest/$lang/LC_MESSAGES/cleanmate.mo" "$po"
  chmod 644 "$dest/$lang/LC_MESSAGES/cleanmate.mo"
done
