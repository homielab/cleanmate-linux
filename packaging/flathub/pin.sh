#!/usr/bin/env bash
# Point the Flatpak manifest at a release: sets `tag:` and `commit:` of its git source to TAG and the
# commit TAG names. Run it after tagging a release (packaging/flathub/pin.sh v2.6.0), then commit.
set -euo pipefail
tag=${1:?usage: pin.sh TAG (for example v2.6.0)}
root=$(cd "$(dirname "$0")/../.." && pwd)
manifest=$root/packaging/flathub/com.homielab.CleanMate.yml
commit=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}") || {
  echo "pin.sh: tag $tag does not exist in this repository" >&2
  exit 1
}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed -e "s|^\( *\)tag: v.*|\1tag: $tag|" -e "s|^\( *\)commit: [0-9a-f]\{40\}.*|\1commit: $commit|" "$manifest" >"$tmp"
cat "$tmp" >"$manifest"
echo "pinned $manifest to $tag ($commit)"
