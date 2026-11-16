#!/usr/bin/env bash
#
# Build dist/CleanMate-<version>-<arch>.AppImage — no root needed.
#
# The image holds CleanMate and what its desktop app needs: Python 3, PyGObject, pycairo, GTK 4,
# libadwaita, the SVG loader, the Adwaita icons. It runs on a computer without any of them and
# without root. Everything is copied from the system that builds it, so it is built on the oldest
# system to support: Ubuntu 24.04 (glibc 2.39), the first with libadwaita 1.5.
#
#   packaging/build-appimage.sh --docker   # in a fresh ubuntu:24.04 container (what the release does)
#   packaging/build-appimage.sh            # on this system, with the packages of BUILD_PACKAGES
#   RUNTIME=/path/to/runtime-x86_64 packaging/build-appimage.sh   # no download (still checked)
#   packaging/test-appimage.sh             # then try it on a system without GTK or Python
#
# PLATFORM=linux/amd64 with --docker builds the x86_64 image on another architecture.
#
# Left on the computer, as every AppImage does (github.com/AppImage/pkg2appimage › excludelist):
# glibc, libstdc++, the graphics drivers (GL, EGL, DRM), X11 / Wayland client libraries,
# fontconfig, FreeType, HarfBuzz, FriBidi, zlib, expat. Every Linux desktop has them. The engine
# (cleanmate.sh) uses the computer's bash and coreutils, as everywhere else.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' "$ROOT/cleanmate.sh")
APP_ID=com.homielab.CleanMate
OUT=${OUT:-$ROOT/dist}
BUILD_IMAGE=ubuntu:24.04
BUILD_PACKAGES=(python3 python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1 librsvg2-common
  adwaita-icon-theme shared-mime-info dconf-gsettings-backend libglib2.0-bin libgdk-pixbuf2.0-bin
  squashfs-tools binutils gettext curl ca-certificates)

if [[ ${1:-} == --docker ]]; then # the same build in a container; the image belongs to whoever owns OUT
  mkdir -p "$OUT"
  exec docker run --rm ${PLATFORM:+--platform "$PLATFORM"} -v "$ROOT":/src:ro -v "$OUT":/out \
    -e OUT=/out -e DEBIAN_FRONTEND=noninteractive "$BUILD_IMAGE" bash -c '
      set -e
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends "$@" >/dev/null
      /src/packaging/build-appimage.sh
      chown --reference=/out /out/*.AppImage' _ "${BUILD_PACKAGES[@]}"
fi
ARCH=$(uname -m)

# The part of an AppImage that mounts it and starts AppRun (github.com/AppImage/type2-runtime).
# A fixed release, checked against its sha256: a new one is a deliberate change of both lines.
RUNTIME_TAG=20251108
declare -A RUNTIME_SHA256=(
  [x86_64]=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
  [aarch64]=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
)
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_TAG/runtime-$ARCH"

# Never bundled: the computer's own copy is the right one (see the header).
EXCLUDE_RE='^(ld-linux.*|lib(c|m|dl|pthread|rt|resolv|util|anl|mvec|BrokenLocale|thread_db|cidn)\.so\.[0-9]+'
EXCLUDE_RE+='|libnss_.*|libstdc\+\+\.so\.6|libgcc_s\.so\.1'
EXCLUDE_RE+='|lib(GL|EGL|GLdispatch|GLX|OpenGL|drm|glapi|gbm)\.so\.[0-9]+'
EXCLUDE_RE+='|lib(xcb|X11|X11-xcb|xcb-dri2|xcb-dri3|wayland-client|ICE|SM)\.so\.[0-9]+'
EXCLUDE_RE+='|lib(fontconfig|freetype|harfbuzz|fribidi|expat|z|uuid|gmp|com_err|gpg-error)\.so\.[0-9]+'
EXCLUDE_RE+='|lib(asound|jack|pipewire-0\.3|usb-1\.0)\.so\.[0-9]+)$'

# GObject introspection data the app (and what it imports) reads
TYPELIBS=(Adw-1 Gtk-4.0 Gdk-4.0 Gsk-4.0 Graphene-1.0 GLib-2.0 GLibUnix-2.0 GObject-2.0 GModule-2.0
  Gio-2.0 GioUnix-2.0 GdkPixbuf-2.0 Pango-1.0 PangoCairo-1.0 HarfBuzz-0.0 cairo-1.0 freetype2-2.0)
# Python's standard library without what a desktop app never loads (tests, Tk, the build tools, TLS)
PY_DROP=(test idlelib tkinter turtledemo ensurepip venv pydoc_data unittest/test lib2to3 distutils
  sitecustomize.py "config-*")
PY_DROP_EXT=(_tkinter _ssl _hashlib _sqlite3 _dbm _gdbm _curses _curses_panel readline "_test*" "_xx*" "xx*"
  _ctypes_test)

die() { echo "build-appimage: $*" >&2; exit 1; }
[[ -n $VERSION ]] || die "VERSION not found in cleanmate.sh"
[[ -n ${RUNTIME_SHA256[$ARCH]:-} ]] || die "no AppImage runtime pinned for $ARCH"
for tool in python3 mksquashfs msgfmt ldd strip sha256sum; do
  command -v "$tool" >/dev/null || die "$tool is missing (install: ${BUILD_PACKAGES[*]})"
done

MULTIARCH=$(python3 -c 'import sysconfig; print(sysconfig.get_config_var("MULTIARCH"))')
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
LIBDIR=/usr/lib/$MULTIARCH
PYLIB=/usr/lib/python$PYV
DIST=/usr/lib/python3/dist-packages
QUERY_LOADERS=$LIBDIR/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders
COMPILE_SCHEMAS=$(command -v glib-compile-schemas || echo "$LIBDIR/glib-2.0/glib-compile-schemas")
for need in "$DIST/gi" "$DIST/cairo" "$LIBDIR/libgtk-4.so.1" "$LIBDIR/libadwaita-1.so.0" \
  "$LIBDIR/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so" "$QUERY_LOADERS" "$COMPILE_SCHEMAS" \
  /usr/share/icons/Adwaita/index.theme /usr/share/mime/mime.cache; do
  [[ -e $need ]] || die "$need is missing (install: ${BUILD_PACKAGES[*]})"
done

WORK=$(mktemp -d -t cm-appimage.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
APPDIR=$WORK/AppDir
U=$APPDIR/usr
echo "Building CleanMate $VERSION AppImage ($ARCH, Python $PYV)"
mkdir -p "$U/bin" "$U/lib" "$U/share/cleanmate/gui/cleanmate_gui"

# ── CleanMate: the engine, the desktop app, its translations, icon and app-grid entry ──
install -m 755 "$ROOT/cleanmate.sh" "$U/bin/cleanmate"
install -m 755 "$ROOT/gui/cleanmate-gui" "$U/share/cleanmate/gui/cleanmate-gui"
install -m 644 "$ROOT"/gui/cleanmate_gui/*.py "$U/share/cleanmate/gui/cleanmate_gui/"
bash "$ROOT/po/compile.sh" "$U/share/locale"
install -D -m 644 "$ROOT/data/$APP_ID.desktop" "$U/share/applications/$APP_ID.desktop"
install -D -m 644 "$ROOT/data/$APP_ID.metainfo.xml" "$U/share/metainfo/$APP_ID.metainfo.xml"
install -D -m 644 "$ROOT/data/icons/hicolor/scalable/apps/$APP_ID.svg" \
  "$U/share/icons/hicolor/scalable/apps/$APP_ID.svg"
install -m 644 /usr/share/icons/hicolor/index.theme "$U/share/icons/hicolor/index.theme"
# what the AppImage format wants at the top: the entry, its icon, and a PNG for file managers
cp "$ROOT/data/$APP_ID.desktop" "$APPDIR/$APP_ID.desktop"
cp "$ROOT/data/icons/hicolor/scalable/apps/$APP_ID.svg" "$APPDIR/$APP_ID.svg"
python3 - "$APPDIR/$APP_ID.svg" "$APPDIR/.DirIcon" <<'PY'
import sys, gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
GdkPixbuf.Pixbuf.new_from_file_at_size(sys.argv[1], 256, 256).savev(sys.argv[2], "png", [], [])
PY

# ── Python: the interpreter, its standard library, PyGObject and pycairo ──
install -m 755 "$(realpath /usr/bin/python3)" "$U/bin/python3"
mkdir -p "$U/lib/python$PYV" "$U/lib/python3/dist-packages"
cp -rL "$PYLIB/." "$U/lib/python$PYV/"
for drop in "${PY_DROP[@]}"; do
  # shellcheck disable=SC2086 # the patterns are meant to expand
  rm -rf "$U/lib/python$PYV"/$drop
done
for drop in "${PY_DROP_EXT[@]}"; do
  # shellcheck disable=SC2086
  rm -f "$U/lib/python$PYV/lib-dynload"/$drop.*.so
done
cp -rL "$DIST/gi" "$DIST/cairo" "$U/lib/python3/dist-packages/"
find "$U/lib" -depth \( -name __pycache__ -o -name '*.pyc' -o -name '*.h' -o -name '*.a' \) -exec rm -rf {} +

# ── GObject introspection, image loaders, GSettings backend ──
mkdir -p "$U/lib/girepository-1.0" "$U/lib/gdk-pixbuf-2.0/2.10.0/loaders" "$U/lib/gio/modules"
for t in "${TYPELIBS[@]}"; do
  install -m 644 "$LIBDIR/girepository-1.0/$t.typelib" "$U/lib/girepository-1.0/"
done
install -m 644 "$LIBDIR"/gdk-pixbuf-2.0/2.10.0/loaders/*.so "$U/lib/gdk-pixbuf-2.0/2.10.0/loaders/"
# the list of loaders holds full paths: `@LOADERS@` is replaced by the real folder at each start
"$QUERY_LOADERS" "$U"/lib/gdk-pixbuf-2.0/2.10.0/loaders/*.so |
  sed "s|$U/lib/gdk-pixbuf-2.0/2.10.0/loaders|@LOADERS@|g" >"$U/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache.in"
grep -q '@LOADERS@/libpixbufloader-svg.so' "$U/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache.in" ||
  die "the SVG loader isn't in the loaders list"
if [[ -f $LIBDIR/gio/modules/libdconfsettings.so ]]; then # your GNOME settings (dark style, fonts) where no portal answers
  install -m 644 "$LIBDIR/gio/modules/libdconfsettings.so" "$U/lib/gio/modules/"
fi

# ── shared libraries: everything the files above load, minus what stays on the computer ──
declare -A SEEN=()
bundle_libs() { # FILE… — copy what they link to into usr/lib, and what those link to
  local f line so path queue=("$@")
  while ((${#queue[@]})); do
    f=${queue[0]}; queue=("${queue[@]:1}")
    while read -r line; do
      [[ $line == *"=> /"* ]] || { [[ $line == *"not found"* ]] && die "$f: $line"; continue; }
      so=${line%% *} path=${line#*=> }; path=${path%% (*}
      [[ -n ${SEEN[$so]:-} || $so =~ $EXCLUDE_RE ]] && continue
      SEEN[$so]=1
      install -m 644 "$(realpath "$path")" "$U/lib/$so"
      queue+=("$U/lib/$so")
    done < <(ldd "$f" 2>/dev/null)
  done
}
# the libraries the introspection data names (loaded by name when the app imports them)
mapfile -t gi_libs < <(for so in libgtk-4.so.1 libadwaita-1.so.0 libgirepository-1.0.so.1 libgraphene-1.0.so.0 \
  libpangocairo-1.0.so.0 libgdk_pixbuf-2.0.so.0 libcairo-gobject.so.2 libgmodule-2.0.so.0; do echo "$LIBDIR/$so"; done)
for f in "${gi_libs[@]}"; do
  so=${f##*/}; SEEN[$so]=1
  install -m 644 "$(realpath "$f")" "$U/lib/$so"
done
mapfile -t elfs < <(find "$U/bin/python3" "$U/lib" -type f \( -name '*.so' -o -name '*.so.*' -o -name python3 \))
bundle_libs "${elfs[@]}"
strip --strip-unneeded "$U"/lib/*.so*

# ── data GTK reads: its settings schemas, the Adwaita icons, the file type database ──
mkdir -p "$U/share/glib-2.0/schemas" "$U/share/icons" "$U/share/mime"
install -m 644 /usr/share/glib-2.0/schemas/org.gtk.gtk4.*.gschema.xml "$U/share/glib-2.0/schemas/"
"$COMPILE_SCHEMAS" "$U/share/glib-2.0/schemas" 2>/dev/null
rm -f "$U"/share/glib-2.0/schemas/*.xml
cp -rL /usr/share/icons/Adwaita "$U/share/icons/"
rm -rf "$U/share/icons/Adwaita/cursors" # the pointer comes from the desktop
for f in mime.cache globs globs2 magic aliases subclasses icons generic-icons types XMLnamespaces treemagic version; do
  [[ -f /usr/share/mime/$f ]] && install -m 644 "/usr/share/mime/$f" "$U/share/mime/$f"
done

# ── starters ──
# AppRun: what the image runs. No argument → the desktop app; `cm …`, any other argument, or a
# link to the image named cm / cleanmate → the engine (the terminal app, --scan, --json …).
cat >"$APPDIR/AppRun" <<'SH'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
APPDIR=${APPDIR:-$here}
export APPDIR
case ${ARGV0##*/} in
  cm | cleanmate) exec "$here/usr/bin/cleanmate" "$@" ;;
esac
[ $# -eq 0 ] && exec "$here/usr/bin/cleanmate" --gui
[ "$1" = cm ] && shift
exec "$here/usr/bin/cleanmate" "$@"
SH
chmod 755 "$APPDIR/AppRun"

# cleanmate-gui: starts the desktop app on the bundled Python and GTK (`cleanmate --gui` runs it).
# Only this process gets the bundle's environment: the app puts each variable named in
# CLEANMATE_BUNDLE_ENV back (to CLEANMATE_HOST_<NAME>, or unset) once GTK is up, so the engine,
# your browser and everything else it starts see the computer's own libraries.
cat >"$U/bin/cleanmate-gui" <<'SH'
#!/bin/sh
u=$(dirname "$(dirname "$(readlink -f "$0")")")
CLEANMATE_BUNDLE_ENV=
bundle_set() { # NAME VALUE
  eval "[ -n \"\${$1+x}\" ] && export CLEANMATE_HOST_$1=\"\${$1}\""
  export "$1=$2"
  CLEANMATE_BUNDLE_ENV="$CLEANMATE_BUNDLE_ENV $1"
}
loaders=$u/lib/gdk-pixbuf-2.0/2.10.0
cache=$(mktemp "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cleanmate-loaders.XXXXXX") &&
  sed "s|@LOADERS@|$loaders/loaders|g" "$loaders/loaders.cache.in" >"$cache" || exit 1
bundle_set LD_LIBRARY_PATH "$u/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
bundle_set PYTHONHOME "$u"
bundle_set PYTHONPATH ""
bundle_set PYTHONNOUSERSITE 1
bundle_set PYTHONDONTWRITEBYTECODE 1
bundle_set XDG_DATA_DIRS "$u/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
bundle_set GI_TYPELIB_PATH "$u/lib/girepository-1.0"
bundle_set GIO_MODULE_DIR "$u/lib/gio/modules"
bundle_set GDK_PIXBUF_MODULE_FILE "$cache"
bundle_set GTK_EXE_PREFIX "$u"
bundle_set GTK_DATA_PREFIX "$u"
export CLEANMATE_BUNDLE_ENV CLEANMATE_BUNDLE_TMP="$cache" CLEANMATE_GUI_LAUNCHER="$u/bin/cleanmate-gui"
exec "$u/bin/python3" "$u/share/cleanmate/gui/cleanmate-gui" "$@"
SH
chmod 755 "$U/bin/cleanmate-gui"

# ── the image: the runtime, then the folder as a squashfs ──
runtime=$WORK/runtime
if [[ -n ${RUNTIME:-} ]]; then cp "$RUNTIME" "$runtime"
elif command -v curl >/dev/null; then curl -fsSL --retry 3 -o "$runtime" "$RUNTIME_URL"
else wget -q -O "$runtime" "$RUNTIME_URL"; fi
[[ $(sha256sum "$runtime" | cut -d' ' -f1) == "${RUNTIME_SHA256[$ARCH]}" ]] ||
  die "the AppImage runtime doesn't match its pinned sha256 ($RUNTIME_URL)"
mksquashfs "$APPDIR" "$WORK/app.squashfs" -root-owned -noappend -comp zstd -Xcompression-level 19 -b 1M \
  -no-progress >/dev/null
mkdir -p "$OUT"
image="$OUT/CleanMate-$VERSION-$ARCH.AppImage"
cat "$runtime" "$WORK/app.squashfs" >"$image"
chmod 755 "$image"
echo "Built $image ($(du -h "$image" | cut -f1); unpacked $(du -sh "$APPDIR" | cut -f1))"
