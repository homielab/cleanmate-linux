#!/usr/bin/env bash
#
# Regenerate the screenshots in docs/screenshots/ (README, AppStream, stores).
#
#   packaging/make-screenshots.sh
#
# Uses a throwaway demo home folder full of realistic junk, so no personal data
# ends up in a screenshot, and removes it afterwards. The desktop app runs on an
# invisible display (gtk4-broadwayd); the terminal app is rendered by
# packaging/render_terminal.py. Needs: python3-gi with GTK 4 + libadwaita,
# libgtk-4-bin, pyte (pip), Pillow, fonts-ubuntu, fonts-noto-color-emoji.
# Run it as a normal user: as root the engine refuses to clean a home folder.
# No display needed; CONTRIBUTING.md shows how to run it in a container.
set -euo pipefail
((EUID != 0)) || { echo "Run as a normal user, not root." >&2; exit 1; }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${OUT:-$ROOT/docs/screenshots}
# The demo home lives inside the project (git-ignored), not in /tmp: the app's
# "Old temporary files" cleaner looks at /tmp and must never see demo files.
mkdir -p "$ROOT/.demo"
BASE=$(mktemp -d -p "$ROOT/.demo" home.XXXXXX)
DEMO=$BASE/alex # Space Lens shows the home folder's name
mkdir "$DEMO"
STUBS=$DEMO/.stubs
trap 'case $BASE in "$ROOT"/.demo/home.*) rm -rf "$BASE" ;; esac; rmdir "$ROOT/.demo" 2>/dev/null || true' EXIT
mkdir -p "$OUT" "$STUBS"

# ── a demo home folder ──
blob() { # PATH MB [DAYS_OLD] — a file that really takes MB on disk
  mkdir -p "$(dirname "$DEMO/$1")"
  fallocate -l "${2}M" "$DEMO/$1" 2>/dev/null || head -c "$((${2} * 1048576))" /dev/zero >"$DEMO/$1"
  if [[ -n ${3:-} ]]; then touch -d "$3 days ago" "$DEMO/$1"; touch -a -d "$3 days ago" "$DEMO/$1"; fi
}
lines() { mkdir -p "$(dirname "$DEMO/$1")"; for ((i = 0; i < $2; i++)); do echo "$3 $i"; done >"$DEMO/$1"; }

blob .cache/google-chrome/Default/Cache/Cache_Data 1450
blob snap/firefox/common/.cache/mozilla/firefox/cache2 640
blob .config/Code/CachedData/1.95/chrome 520
blob .config/Code/Cache/Cache_Data 180
blob .config/Code/logs/20260801T091500/renderer.log 35 40
blob .config/Slack/Cache/Cache_Data 260
blob .config/discord/Cache/Cache_Data 190
blob .cache/thumbnails/large/thumbs 140
blob .local/share/Trash/files/old-backup.tar 900
mkdir -p "$DEMO/.local/share/Trash/info"
printf '[Trash Info]\nPath=%s/old-backup.tar\nDeletionDate=2026-09-01T10:00:00\n' "$DEMO" \
  >"$DEMO/.local/share/Trash/info/old-backup.tar.trashinfo"
blob .cache/someapp/old-data.bin 210 100
blob .npm/_cacache/content-v2/blobs 1100
blob .cache/pip/http/wheels 380
blob .cache/go-build/00/objects 720
blob .cache/yarn/v6/packages 310
blob .cargo/registry/cache/index.crates.io/crates 450
blob code/website/node_modules/.store/packages 480
echo '{}' >"$DEMO/code/website/package.json"; echo '{}' >"$DEMO/code/website/package-lock.json"
touch -d '200 days ago' "$DEMO/code/website/package.json" "$DEMO/code/website/package-lock.json" \
  "$DEMO/code/website/node_modules" "$DEMO/code/website"
# Large & Old Files
blob Videos/holiday-2025.mkv 2300 400
blob Downloads/ubuntu-24.04.3-desktop-amd64.iso 1600 200
blob Downloads/project-backup-2024.zip 750 300
blob Music/podcast-archive.tar 420 500
# Uninstaller: the apps' own folders
blob .config/GIMP/2.10/swap 120
blob .config/inkscape/extensions 15
blob .var/app/com.spotify.Client/cache 850
blob .var/app/md.obsidian.Obsidian/config 60
blob .claude/cache/models 40
blob .codex/.tmp/plugins/catalog 95
blob .gemini/antigravity-ide/conversations/old-chat.pb 30 60
lines .bash_history 1800 "ls -la"
# Duplicates: the same photos and a PDF copied into other folders, the original oldest
dup() { # SIZE-KB SOURCE COPY…
  mkdir -p "$(dirname "$DEMO/$2")"; head -c "$(($1 * 1024))" /dev/urandom >"$DEMO/$2"
  touch -d "400 days ago" "$DEMO/$2"; local src=$2 d=300; shift 2
  for c; do mkdir -p "$(dirname "$DEMO/$c")"; cp "$DEMO/$src" "$DEMO/$c"; touch -d "$d days ago" "$DEMO/$c"; d=$((d - 120)); done
}
dup 6200 Pictures/2025/beach-sunset.jpg "Pictures/Phone backup/IMG_2041.jpg" Downloads/beach-sunset.jpg
dup 4800 Pictures/2025/family-dinner.jpg "Pictures/Phone backup/IMG_2107.jpg"
dup 2300 Documents/tax-return-2025.pdf Downloads/tax-return-2025.pdf Desktop/tax-return-2025.pdf
# Startup Items: login apps of your own and units for a fake systemd user session
mkdir -p "$DEMO/.config/autostart" "$DEMO/.config/systemd/user"
for app in "slack|Slack|slack --startup|" "discord|Discord|discord --start-minimized|" \
  "dropbox|Dropbox|dropbox start -i|" "steam|Steam|steam -silent|Hidden=true"; do
  IFS='|' read -r id name exe extra <<<"$app"
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n' "$name" "$exe" "$extra" >"$DEMO/.config/autostart/$id.desktop"
done
printf '[Unit]\nDescription=Back up my documents\n' >"$DEMO/.config/systemd/user/backup.timer"
printf '[Unit]\nDescription=Sync notes with my server\n' >"$DEMO/.config/systemd/user/notes-sync.service"
printf 'backup.timer enabled enabled\nnotes-sync.service disabled enabled\n' >"$DEMO/.units"
lines .zsh_history 3400 ": 1700000000:0;git status"
lines .python_history 120 "print"
mkdir -p "$DEMO/.local/share"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<xbel version="1.0">'
  for ((i = 0; i < 64; i++)); do echo "  <bookmark href=\"file:///home/demo/Documents/file$i.pdf\"/>"; done
  echo '</xbel>'
} >"$DEMO/.local/share/recently-used.xbel"

# ── stubs: no password prompts, no "app is running", fixed Docker numbers ──
printf '#!/bin/sh\nexit 1\n' >"$STUBS/sudo"
printf '#!/bin/sh\nexit 1\n' >"$STUBS/pgrep"
printf '#!/bin/sh\n' >"$STUBS/node"
cat >"$STUBS/docker" <<'EOF'
#!/bin/sh
case "$*" in
  info*) exit 0 ;;
  "system df --format"*) printf 'Images\t2.8GB (61%%)\nContainers\t340MB (100%%)\nLocal Volumes\t1.2GB (40%%)\nBuild Cache\t2.1GB\n' ;;
  "images -f dangling=true --format {{.Size}}") printf '450MB\n230MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\nc3\n' ;;
  "volume ls -qf dangling=true") printf 'v1\nv2\n' ;;
esac
EOF
# Uninstaller scene only (the other scenes use the real dpkg): three apt apps and two Flatpaks
mkdir -p "$STUBS/apps" "$DEMO/.apps"
cat >"$STUBS/apps/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = -S ] || exit 1; shift
for f; do n=${f##*/}; n=${n%.desktop}; case $n in gimp|inkscape|vlc) echo "$n: $f" ;; esac; done
EOF
cat >"$STUBS/apps/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
  *Installed-Size*) printf 'gimp\t98000\toptional\tno\ninkscape\t121000\toptional\tno\nvlc\t9400\toptional\tno\n' ;;
esac
EOF
printf '#!/bin/sh\n' >"$STUBS/apps/apt-cache"
cat >"$STUBS/apps/flatpak" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf 'com.spotify.Client\t312.4 MB\nmd.obsidian.Obsidian\t268.0 MB\n'
EOF
for app in "gimp|GNU Image Manipulation Program|gimp-2.10 %U|" "inkscape|Inkscape|inkscape %F|" \
  "vlc|VLC media player|vlc %U|" "com.spotify.Client|Spotify|flatpak run com.spotify.Client|X-Flatpak=com.spotify.Client" \
  "md.obsidian.Obsidian|Obsidian|flatpak run md.obsidian.Obsidian|X-Flatpak=md.obsidian.Obsidian"; do
  IFS='|' read -r id name exe extra <<<"$app"
  printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n' "$name" "$exe" "$extra" >"$DEMO/.apps/$id.desktop"
done
cat >"$STUBS/systemctl" <<'EOF'
#!/bin/sh
shift
[ "$1" = list-unit-files ] && cat "$HOME/.units"
exit 0
EOF
chmod +x "$STUBS"/* "$STUBS"/apps/*
DEMO_PATH="$STUBS:/usr/local/bin:/usr/bin:/bin"

# ── desktop app scenes ──
if command -v gtk4-broadwayd >/dev/null; then
  rt=$DEMO/.runtime
  mkdir -p "$rt" && chmod 700 "$rt"
  XDG_RUNTIME_DIR=$rt gtk4-broadwayd :77 >/dev/null 2>&1 &
  srv=$!
  sleep 1
  # "done" really cleans the demo caches, so it runs last; the number keeps the file order
  for scene in 1:results 2:details 3:confirm 5:ai 6:privacy 7:large 8:uninstall 9:lens 10:duplicates \
    11:startup 12:settings 4:done; do
    n=${scene%%:*} scene=${scene#*:}
    path=$DEMO_PATH
    [[ $scene == uninstall ]] && path=$STUBS/apps:$DEMO_PATH
    env -i HOME="$DEMO" PATH="$path" CLEANMATE_APP_DIRS="$DEMO/.apps" LANG=C.UTF-8 XDG_RUNTIME_DIR="$rt" GDK_BACKEND=broadway \
      BROADWAY_DISPLAY=:77 CLEANMATE_NO_UPDATE_CHECK=1 timeout 180 /usr/bin/python3 "$ROOT/gui/cleanmate-gui" \
      --engine "$ROOT/cleanmate.sh" --screenshot "$OUT/desktop-$n-$scene.png" --scene "$scene" \
      --window-size 1280x800 2>/dev/null | grep "screenshot saved" >/dev/null &&
      echo "  desktop-$n-$scene.png" || echo "  ✘ desktop scene '$scene' failed"
  done
  kill "$srv"
else
  echo "  (gtk4-broadwayd missing: desktop screenshots skipped)"
fi

# ── terminal app scenes (scan only — nothing is cleaned) ──
term() { # NAME KEYS ROWS
  env -i HOME="$DEMO" PATH="$DEMO_PATH" LANG=C.UTF-8 PYTHONPATH="${PYTHONPATH:-}" \
    /usr/bin/python3 "$ROOT/packaging/render_terminal.py" "$ROOT/cleanmate.sh" "$OUT/$1" \
    --keys "$2" --rows "$3" --live --wait 4 >/dev/null && echo "  $1" || echo "  ✘ $1 failed"
}
if /usr/bin/python3 -c 'import pyte, PIL' 2>/dev/null || PYTHONPATH=${PYTHONPATH:-} /usr/bin/python3 -c 'import pyte, PIL' 2>/dev/null; then
  term terminal-1-menu.png "" 34
  term terminal-2-smart-scan.png "1|n" 40
  term terminal-3-ai-tools.png "5" 34
else
  echo "  (pyte or Pillow missing: terminal screenshots skipped — pip install pyte)"
fi
echo "Screenshots in ${OUT/#$ROOT\//}"
