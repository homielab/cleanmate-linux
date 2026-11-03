#!/usr/bin/env bash
# Build the Flatpak from this working tree (the manifest itself builds a release tag) and install it
# for your user. Needs flatpak-builder and the Flathub remote (packaging/flathub/README.md).
#   packaging/flathub/build.sh             build and install com.homielab.CleanMate
#   packaging/flathub/build.sh --manifest  only write dist/flatpak/com.homielab.CleanMate.yml (CI)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=dist/flatpak
manifest=$out/com.homielab.CleanMate.yml
mkdir -p "$out"
{ # the release manifest up to its `sources:`, then this folder as the source
  sed '/^    sources:$/,$d' packaging/flathub/com.homielab.CleanMate.yml
  printf '    sources:\n      - type: dir\n        path: %s\n        skip: [.git, dist, .demo, gui/locale]\n' "$PWD"
} >"$manifest"
if [[ ${1:-} == --manifest ]]; then echo "$manifest"; exit 0; fi
flatpak-builder --user --install-deps-from=flathub --force-clean --install \
  --state-dir="$out/state" "$out/build" "$manifest"
echo "Installed. Run it: flatpak run com.homielab.CleanMate --gui"
