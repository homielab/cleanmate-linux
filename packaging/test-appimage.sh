#!/usr/bin/env bash
#
# Try an AppImage where it has to work: a fresh ubuntu:24.04 container without Python, GTK or
# libadwaita, as an ordinary user, without FUSE. Fails when the terminal app, the engine's JSON
# or the desktop app's self-test (on an invisible display, dry run) doesn't run.
#
#   packaging/test-appimage.sh [dist/CleanMate-<version>-<arch>.AppImage]   # default: the one in dist/
#
# PLATFORM=linux/amd64 tries the x86_64 image on another architecture.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# what an AppImage leaves to the computer (build-appimage.sh), a display server and one font
HOST_PACKAGES=(xvfb xauth fonts-dejavu-core libfontconfig1 libfreetype6 libharfbuzz0b libfribidi0 libx11-6
  libxcb1 libx11-xcb1 libwayland-client0 zlib1g libexpat1 libuuid1 libgmp10)

case ${1:-} in
  --root) # in the container
    shift
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${HOST_PACKAGES[@]}" >/dev/null
    useradd -m tester
    exec setpriv --reuid=tester --regid=tester --init-groups env HOME=/home/tester LANG=C.UTF-8 \
      bash "${BASH_SOURCE[0]}" --user "$@"
    ;;
  --user) ;;
  *)
    image=${1:-}
    [[ -n $image ]] || image=$(ls -t "$ROOT"/dist/CleanMate-*.AppImage 2>/dev/null | head -n 1)
    [[ -f $image ]] || { echo "test-appimage: no AppImage (run packaging/build-appimage.sh --docker first)" >&2; exit 1; }
    image=$(realpath "$image")
    exec docker run --rm ${PLATFORM:+--platform "$PLATFORM"} -e DEBIAN_FRONTEND=noninteractive \
      -v "$ROOT/packaging/test-appimage.sh":/test-appimage.sh:ro -v "$image":"/image/${image##*/}":ro \
      ubuntu:24.04 bash /test-appimage.sh --root "/image/${image##*/}"
    ;;
esac

# ── as an ordinary user, on a system without the app's libraries ──
fail() { echo "test-appimage: ✘ $*" >&2; exit 1; }
ok() { echo "  ✔ $*"; }
cd "$HOME"
cp "$2" . && image=$PWD/${2##*/}
version=${image##*/CleanMate-}; version=${version%%-*}
export APPIMAGE_EXTRACT_AND_RUN=1 # no FUSE in a container: the image unpacks itself, runs, and cleans up
command -v python3 >/dev/null && fail "this system has Python: not a test of the bundled one"
ldconfig -p | grep -Eq 'libgtk-4|libadwaita' && fail "this system has GTK 4 or libadwaita: not a test of the bundled ones"

out=$("$image" --version) || fail "--version exits $?"
[[ $out == "cleanmate $version"* && $out == *"Installed with: AppImage"* ]] || fail "--version: $out"
ok "--version: cleanmate $version, installed with: AppImage"
[[ $("$image" cm --version | head -n 1) == "cleanmate $version" ]] || fail "cm --version"
ok "cm … reaches the terminal app"
out=$("$image" --json overview) || fail "--json overview exits $?"
[[ $(tail -n 1 <<<"$out") == '{"event":"done"'* && $out == *'"event":"disk"'* ]] || fail "--json overview: $(tail -n 2 <<<"$out")"
ok "--json overview"
mkdir -p .cache/thumbnails/large .cache/pip && echo x >.cache/thumbnails/large/a.png && echo x >.cache/pip/p
"$image" --clean --yes --dry-run >/dev/null || fail "--clean --yes --dry-run exits $?"
[[ -f .cache/thumbnails/large/a.png ]] || fail "a dry run deleted a file"
ok "--clean --dry-run"
out=$("$image" --install --dry-run) || fail "--install --dry-run exits $?"
[[ $out == *"${image/#$HOME/\~}"* ]] || fail "--install doesn't use the image file: $out"
ok "--install would link to the image file"

# the desktop app, through the starter the image runs it with
"$image" --appimage-extract >/dev/null || fail "--appimage-extract exits $?"
app=$PWD/squashfs-root
out=$(APPDIR=$app CLEANMATE_SELFTEST_MAX_PAUSE_MS=1500 timeout 300 xvfb-run -a \
  "$app/usr/bin/cleanmate-gui" --engine "$app/usr/bin/cleanmate" --dry-run --selftest 2>&1) ||
  { grep -E 'SELFTEST FAIL|Error|error' <<<"$out" | tail -n 20 >&2; fail "the desktop app's self-test exits $?"; }
[[ $out == *"SELFTEST done"* && $out != *"SELFTEST FAIL"* ]] || fail "the desktop app's self-test didn't finish"
[[ $out == *"the Overview charts drew to snapshots"* ]] || fail "the Overview charts didn't draw (the cairo bridge is missing)"
ok "desktop app self-test ($(grep -c 'SELFTEST ok' <<<"$out") checks, Overview charts drawn)"
echo "test-appimage: ${image##*/} works without Python, GTK or libadwaita on the system"
