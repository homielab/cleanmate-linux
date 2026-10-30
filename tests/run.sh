#!/usr/bin/env bash
#
# Test suite for cleanmate.sh.
#
# Safe to run anywhere: every test uses a throwaway HOME, `sudo` and `pgrep`
# are replaced by stubs (so system items can never run and results don't depend
# on which apps are open), and each cleanup test switches on only the items it
# is testing. Needs no root and no network.
#
# Usage: tests/run.sh [-v] [NAME_FILTER]

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${CLEANMATE_SCRIPT:-$ROOT/cleanmate.sh} # CLEANMATE_SCRIPT: test another copy
WORK=$(mktemp -d -t cleanmate-tests.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
VERBOSE=0
[[ ${1:-} == -v ]] && { VERBOSE=1; shift; }
FILTER=${1:-}

# stubs: no privilege escalation, no "is the app running?" surprises, and no
# real Docker on the machine leaking into results (the Docker test brings its own)
mkdir -p "$WORK/stubs"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/sudo"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/pgrep"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/docker"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/podman" # CI machines ship podman and conda: keep them out too
printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/conda"
chmod +x "$WORK/stubs/"*
# your own ~/… commands (e.g. an installed cm) must not leak into the tests
BASE_PATH="$WORK/stubs:$(tr ':' '\n' <<<"$PATH" | grep -v "^$HOME/" | grep -vx "$HOME" | paste -sd: -)"

if [[ -t 1 ]]; then G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' D=$'\e[2m' N=$'\e[0m'; else G="" R="" Y="" D="" N=""; fi

# ── helpers ──────────────────────────────────────────────────────────────────

fresh_home() { HOME_DIR=$(mktemp -d -p "$WORK" home.XXXX); mkdir -p "$HOME_DIR/.config/cleanmate"; }

cm() { # run the app non-interactively inside the fake home
  "${AS_USER[@]}" env -i HOME="$HOME_DIR" PATH="$HOME_DIR/.local/bin:$BASE_PATH" LANG=C.UTF-8 TERM=dumb \
    CLEANMATE_NO_UPDATE_CHECK=1 ${CLEANMATE_UPDATE_URL:+CLEANMATE_UPDATE_URL=$CLEANMATE_UPDATE_URL} \
    ${CLEANMATE_APP_DIRS:+CLEANMATE_APP_DIRS=$CLEANMATE_APP_DIRS} \
    ${CLEANMATE_SYSTEM_AUTOSTART:+CLEANMATE_SYSTEM_AUTOSTART=$CLEANMATE_SYSTEM_AUTOSTART} \
    ${CLEANMATE_VOLUME_ROOTS:+CLEANMATE_VOLUME_ROOTS=$CLEANMATE_VOLUME_ROOTS} \
    ${CLEANMATE_MOUNTS:+CLEANMATE_MOUNTS=$CLEANMATE_MOUNTS} bash "$SCRIPT" "$@"
}

# As root, `--json clean` refuses home items (the desktop app elevates only for
# system items), so tests of cleaning home items run as an ordinary user.
AS_USER=()
if ((EUID == 0)); then
  chmod 711 "$WORK" # the user needs to reach the stubs and the fake homes
  cp "$SCRIPT" "$WORK/cleanmate-as-user.sh" && chmod 644 "$WORK/cleanmate-as-user.sh" # the checkout may be root-only
fi
user_cm() { # like cm; as root it runs as nobody, who owns the fake home for the time being
  ((EUID == 0)) || { cm "$@"; return; }
  command -v setpriv >/dev/null || { fail "running as root needs setpriv (util-linux)"; return 1; }
  chown -R 65534:65534 "$HOME_DIR"
  local AS_USER=(setpriv --reuid=65534 --regid=65534 --clear-groups) SCRIPT=$WORK/cleanmate-as-user.sh
  cm "$@"
}

in_app() { # run bash code with the script's functions loaded (sourced, nothing starts)
  env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 bash -c "source \"\$1\"; $1" _ "$SCRIPT"
}

select_only() { # ID... — selection file with exactly these items switched on
  local id w on ids
  ids=$(in_app 'printf "%s\n" "${ITEM_IDS[@]}"')
  for id in $ids; do
    on=0
    for w in "$@"; do [[ $id == "$w" ]] && on=1; done
    echo "$id=$on"
  done >"$HOME_DIR/.config/cleanmate/selection"
}

old() { # FILE [DAYS] — create FILE, last modified and read DAYS (default 200) days ago
  mkdir -p "$(dirname "$1")"
  printf 'data\n' >"$1"
  touch -d "${2:-200} days ago" "$1"
  touch -a -d "${2:-200} days ago" "$1"
}
new() { mkdir -p "$(dirname "$1")"; printf 'data\n' >"$1"; }

fail() { printf '    %s✘ %s%s\n' "$R" "$*" "$N"; FAILED=1; }
ok_() { ((VERBOSE)) && printf '    %s✔ %s%s\n' "$D" "$*" "$N"; return 0; }
assert_exists() { if [[ -e $1 || -L $1 ]]; then ok_ "exists: ${1#"$HOME_DIR"/}"; else fail "should exist: ${1#"$HOME_DIR"/}"; fi; }
assert_missing() { if [[ -e $1 || -L $1 ]]; then fail "should be gone: ${1#"$HOME_DIR"/}"; else ok_ "gone: ${1#"$HOME_DIR"/}"; fi; }
assert_eq() { if [[ $1 == "$2" ]]; then ok_ "$3"; else fail "$3: expected '$2', got '$1'"; fi; }
assert_contains() { if [[ $1 == *"$2"* ]]; then ok_ "contains '$2'"; else fail "output should contain '$2'"; ((VERBOSE)) && printf '%s\n' "$1" | sed 's/^/      | /'; fi; }

# ── tests ────────────────────────────────────────────────────────────────────

test_syntax() {
  bash -n "$SCRIPT" && ok_ "bash -n" || fail "syntax error"
}

test_help_and_version() {
  fresh_home
  local v h
  v=$(cm --version)
  [[ $v =~ ^cleanmate\ [0-9]+\.[0-9]+\.[0-9]+$ ]] && ok_ "$v" || fail "bad --version: $v"
  h=$(cm --help)
  assert_contains "$h" "--install"
  assert_contains "$h" "github.com/homielab/cleanmate-linux"
}

test_human_sizes_match_numfmt() {
  fresh_home
  local b mine theirs
  for b in 0 1023 1024 1536 999999 1048576 2000000 1932735283 5368709120 1099511627776; do
    mine=$(in_app "humanv x $b; echo \"\$x\"")
    if ((b < 1024)); then theirs="$b B"
    else theirs=$(numfmt --to=iec --round=nearest --suffix=B --format='%.1f' "$b" | sed 's/\([0-9]\)\([KMGTP]\)/\1 \2/'); fi
    assert_eq "$mine" "$theirs" "human $b"
  done
}

test_plural_and_versions() {
  fresh_home
  assert_eq "$(in_app 'plural 1 file')" "1 file" "plural 1"
  assert_eq "$(in_app 'plural 3 entry')" "3 entries" "plural y→ies"
  assert_eq "$(in_app 'plural 2 day')" "2 days" "plural vowel+y"
  in_app 'version_gt 1.10.0 1.9.0' && ok_ "1.10.0 > 1.9.0" || fail "1.10.0 should be newer than 1.9.0"
  in_app 'version_gt 1.0.0 1.0.0' && fail "1.0.0 is not newer than itself" || ok_ "equal versions"
}

test_protected_paths() {
  fresh_home
  local p
  for p in / /usr /etc /var "$HOME_DIR" "$HOME_DIR/.config" "$HOME_DIR/.local" "$HOME_DIR/.cache/.."; do
    in_app "is_protected '$p'" && ok_ "protected: $p" || fail "should be protected: $p"
  done
  in_app "is_protected '$HOME_DIR/.cache/thing'" && fail "~/.cache/thing should be allowed" || ok_ "allowed: ~/.cache/thing"
}

test_scan_report() {
  fresh_home
  local out
  out=$(cm --scan 2>&1) || fail "--scan exited with an error"
  assert_contains "$out" "scan report"
  assert_contains "$out" "Found"
}

# Regression: -prune is ignored under -delete; excluded caches must survive.
test_stale_app_cache_keeps_excluded_caches() {
  fresh_home
  local c=$HOME_DIR/.cache
  old "$c/pip/http/old.whl"; old "$c/google-chrome/Default/Cache/old"
  old "$c/someapp/old.bin"; new "$c/someapp/fresh.bin"
  select_only app_cache
  cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_missing "$c/someapp/old.bin"
  assert_exists "$c/someapp/fresh.bin"
  assert_exists "$c/pip/http/old.whl"
  assert_exists "$c/google-chrome/Default/Cache/old"
}

test_trash_is_emptied_in_place() {
  fresh_home
  local t=$HOME_DIR/.local/share/Trash
  mkdir -p "$t/files/folder" "$t/info"
  echo x >"$t/files/a.txt"; echo y >"$t/files/folder/b"
  printf '[Trash Info]\nPath=/x/a.txt\nDeletionDate=2026-01-01T00:00:00\n' >"$t/info/a.txt.trashinfo"
  select_only trash
  cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_eq "$(find "$t/files" "$t/info" -mindepth 1 | wc -l)" 0 "this Trash is empty"
  assert_exists "$t/files"; assert_exists "$t/info"
}

test_browser_items_are_separate() {
  fresh_home
  new "$HOME_DIR/.cache/google-chrome/Default/Cache/a"
  new "$HOME_DIR/.cache/mozilla/firefox/x/cache2/b"
  select_only browser_firefox
  cm --clean --yes --only browser >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.cache/mozilla/firefox/x/cache2/b"
  assert_exists "$HOME_DIR/.cache/google-chrome/Default/Cache/a"
}

running_stub() { # DIR NAME… — a pgrep that reports these programs as running
  local d=$1; shift
  mkdir -p "$d"
  { echo '#!/bin/sh'
    echo 'for a; do case $a in'
    for n; do printf '  %s) echo "4242 %s"; exit 0 ;;\n' "$n" "$n"; done
    echo 'esac; done; exit 1'; } >"$d/pgrep"
  chmod 755 "$d/pgrep"
}

# A program that is running locks its items: the scan says which one, and an
# unattended clean (--json, --yes) skips the item.
test_running_tool_locks_item() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/lockbin out lock
  running_stub "$bin" firefox claude
  new "$HOME_DIR/.cache/mozilla/firefox/x/cache2/b"
  new "$HOME_DIR/.cache/google-chrome/Default/Cache/a"
  new "$HOME_DIR/.claude/cache/c"
  lock='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "item": print(e["id"], e["status"], repr(e["locked"]))'
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json scan | python3 -c "$lock")
  assert_contains "$out" "browser_firefox found 'firefox'"
  assert_contains "$out" "ai_claude_cache found 'claude'"
  assert_contains "$out" "browser_chrome found ''"
  assert_contains "$out" "thumbs clean ''"
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --scan --only browser 2>&1)
  assert_contains "$out" "close firefox first"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean browser_firefox browser_chrome 2>&1)
  assert_contains "$out" '"id":"browser_firefox","state":"skip"'
  assert_contains "$out" '"id":"browser_chrome","state":"ok"'
  assert_exists "$HOME_DIR/.cache/mozilla/firefox/x/cache2/b"
  assert_missing "$HOME_DIR/.cache/google-chrome/Default/Cache/a"
}

test_app_cache_keeps_app_data() {
  fresh_home
  new "$HOME_DIR/.config/Slack/Cache/c"
  new "$HOME_DIR/.config/Slack/Local Storage/login"
  select_only app_slack
  cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.config/Slack/Cache/c"
  assert_exists "$HOME_DIR/.config/Slack/Local Storage/login"
}

test_stale_node_modules_rules() {
  fresh_home
  local d=$HOME_DIR/code p
  for p in idle-with-lock idle-no-lock active; do
    new "$d/$p/node_modules/pkg/index.js"; new "$d/$p/package.json"
  done
  new "$d/idle-with-lock/package-lock.json"; new "$d/active/package-lock.json"
  new "$HOME_DIR/Applications/ide/resources/app/node_modules/x/i.js"
  new "$HOME_DIR/Applications/ide/resources/app/package.json"
  new "$HOME_DIR/Applications/ide/resources/app/package-lock.json"
  for p in "$d/idle-with-lock" "$d/idle-no-lock" "$HOME_DIR/Applications/ide/resources/app"; do
    touch -d '200 days ago' "$p"/* "$p"
  done
  mkdir -p "$WORK/nodebin" && printf '#!/bin/sh\n' >"$WORK/nodebin/node" && chmod +x "$WORK/nodebin/node"
  select_only node_modules
  BASE_PATH="$WORK/nodebin:$BASE_PATH" cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_missing "$d/idle-with-lock/node_modules"
  assert_exists "$d/idle-no-lock/node_modules"
  assert_exists "$d/active/node_modules"
  assert_exists "$HOME_DIR/Applications/ide/resources/app/node_modules"
}

test_ai_tools_keep_memory_and_logins() {
  fresh_home
  local P=$HOME_DIR/.claude/projects/-home-x-proj
  old "$P/aaaa-old.jsonl"; old "$P/aaaa-old/tool-results/r1.txt"; touch -d '200 days ago' "$P/aaaa-old"
  new "$P/bbbb-new.jsonl"
  old "$P/memory/MEMORY.md"; touch -d '200 days ago' "$P/memory"
  old "$HOME_DIR/.claude/.credentials.json"; old "$HOME_DIR/.claude/settings.json"
  old "$HOME_DIR/.claude/plugins/p/plugin.json"; old "$HOME_DIR/.claude/cache/c.bin"
  old "$HOME_DIR/.codex/auth.json"; old "$HOME_DIR/.codex/memories_1.sqlite"; old "$HOME_DIR/.codex/.tmp/plugins/x"
  old "$HOME_DIR/.codex/sessions/2026/01/01/old.jsonl"; new "$HOME_DIR/.codex/sessions/2026/10/01/new.jsonl"
  old "$HOME_DIR/.gemini/oauth_creds.json"
  select_only ai_claude_cache ai_claude_history ai_codex_cache ai_codex_history
  cm --clean --yes --only ai >/dev/null 2>&1 </dev/null
  assert_missing "$P/aaaa-old.jsonl"; assert_missing "$P/aaaa-old"
  assert_missing "$HOME_DIR/.claude/cache/c.bin"; assert_missing "$HOME_DIR/.codex/.tmp/plugins"
  assert_missing "$HOME_DIR/.codex/sessions/2026/01/01/old.jsonl"
  assert_exists "$P/bbbb-new.jsonl"; assert_exists "$P/memory/MEMORY.md"
  assert_exists "$HOME_DIR/.claude/.credentials.json"; assert_exists "$HOME_DIR/.claude/settings.json"
  assert_exists "$HOME_DIR/.claude/plugins/p/plugin.json"
  assert_exists "$HOME_DIR/.codex/auth.json"; assert_exists "$HOME_DIR/.codex/memories_1.sqlite"
  assert_exists "$HOME_DIR/.codex/sessions/2026/10/01/new.jsonl"; assert_exists "$HOME_DIR/.gemini/oauth_creds.json"
}

test_privacy_clears_in_place() {
  fresh_home
  printf 'ls\nssh host\n' >"$HOME_DIR/.bash_history"; chmod 600 "$HOME_DIR/.bash_history"
  printf ': 1:0;git push\n' >"$HOME_DIR/.zsh_history"
  printf '"x\n' >"$HOME_DIR/.viminfo"
  mkdir -p "$HOME_DIR/.local/share"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<xbel version="1.0">' \
    '<bookmark href="file:///secret.pdf"/>' '</xbel>' >"$HOME_DIR/.local/share/recently-used.xbel"
  select_only priv_bash priv_zsh priv_editor priv_recent
  cm --clean --yes --only privacy >/dev/null 2>&1 </dev/null
  assert_eq "$(stat -c %s "$HOME_DIR/.bash_history")" 0 "bash history emptied"
  assert_eq "$(stat -c %a "$HOME_DIR/.bash_history")" 600 "bash history keeps mode 600"
  assert_eq "$(stat -c %s "$HOME_DIR/.zsh_history")" 0 "zsh history emptied"
  assert_missing "$HOME_DIR/.viminfo"
  if grep -q '<bookmark' "$HOME_DIR/.local/share/recently-used.xbel"; then fail "recent files not cleared"
  else ok_ "recent files cleared"; fi
  grep -q '</xbel>' "$HOME_DIR/.local/share/recently-used.xbel" && ok_ "xbel still valid" || fail "xbel broken"
}

test_old_app_logs() {
  fresh_home
  old "$HOME_DIR/.config/Code/logs/20260101T100000/window1/renderer.log"
  touch -d '200 days ago' "$HOME_DIR/.config/Code/logs/20260101T100000/window1"
  new "$HOME_DIR/.config/Code/logs/20261012T150000/main.log"
  old "$HOME_DIR/.config/Code/User/settings.json"
  select_only app_logs
  cm --clean --yes --only logs >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.config/Code/logs/20260101T100000"
  assert_exists "$HOME_DIR/.config/Code/logs/20261012T150000/main.log"
  assert_exists "$HOME_DIR/.config/Code/User/settings.json"
}

test_dry_run_changes_nothing() {
  fresh_home
  local before after
  old "$HOME_DIR/.cache/someapp/old.bin"; new "$HOME_DIR/.cache/thumbnails/large/a.png"
  new "$HOME_DIR/.cache/pip/x"; new "$HOME_DIR/.cache/google-chrome/c"; new "$HOME_DIR/.config/Slack/Cache/c"
  printf 'secret\n' >"$HOME_DIR/.bash_history"
  old "$HOME_DIR/.claude/cache/c.bin"
  in_app 'printf "%s=1\n" "${ITEM_IDS[@]}"' >"$HOME_DIR/.config/cleanmate/selection" # everything on
  # compare every file (size + mtime); the app's own state and GLib's dconf cache don't count
  before=$(cd "$HOME_DIR" && find . \( -path ./.local/state -o -path ./.cache/dconf \) -prune -o -type f -printf '%p %s %T@\n' | sort)
  cm --clean --yes --dry-run --only user,browser,apps,ai,dev,privacy >/dev/null 2>&1 </dev/null
  after=$(cd "$HOME_DIR" && find . \( -path ./.local/state -o -path ./.cache/dconf \) -prune -o -type f -printf '%p %s %T@\n' | sort)
  assert_eq "$after" "$before" "file tree unchanged by --dry-run"
}

test_install_cm_and_uninstall() {
  fresh_home
  local out bin=$HOME_DIR/.local/bin
  out=$(cm --install 2>&1)
  assert_contains "$out" "Shorthand: "
  assert_exists "$bin/cleanmate"
  assert_eq "$(readlink "$bin/cm")" "cleanmate" "cm points to cleanmate"
  local desktop=$HOME_DIR/.local/share/applications/com.homielab.CleanMate.desktop
  local icon=$HOME_DIR/.local/share/icons/hicolor/scalable/apps/com.homielab.CleanMate.svg
  assert_exists "$desktop"
  assert_exists "$icon"
  assert_contains "$(<"$desktop")" "Icon=com.homielab.CleanMate"
  if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$desktop" >/dev/null && ok_ "launcher is valid" || fail "invalid launcher: $(desktop-file-validate "$desktop")"
  fi
  assert_eq "$(env -i HOME="$HOME_DIR" PATH="$bin:$BASE_PATH" cm --version)" "$(cm --version)" "cm runs"
  printf 'y\ny\n' | cm --uninstall >/dev/null 2>&1
  assert_missing "$bin/cleanmate"; assert_missing "$bin/cm"
  assert_missing "$desktop"; assert_missing "$icon"
}

# A script downloaded on its own (the curl install) fetches the desktop app and icon.
test_install_downloads_app_files() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  command -v curl >/dev/null || command -v wget >/dev/null || { SKIPPED="neither curl nor wget installed"; return; }
  fresh_home
  local www=$WORK/bundle lone=$WORK/lone port srv out
  mkdir -p "$www" "$lone"
  tar -czf "$www/main.tar.gz" -C "$ROOT/.." --transform "s,^$(basename "$ROOT"),cleanmate-main," \
    "$(basename "$ROOT")/gui" "$(basename "$ROOT")/data"
  cp "$SCRIPT" "$lone/cleanmate.sh"
  port=$((20000 + RANDOM % 20000))
  (cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
  srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.3; done
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CLEANMATE_BUNDLE_URL="http://127.0.0.1:$port/main.tar.gz" \
    bash "$lone/cleanmate.sh" --install 2>&1)
  kill "$srv" 2>/dev/null
  assert_contains "$out" "Downloaded the desktop app and icon"
  assert_exists "$HOME_DIR/.local/share/cleanmate/gui/cleanmate-gui"
  assert_exists "$HOME_DIR/.local/share/icons/hicolor/scalable/apps/com.homielab.CleanMate.svg"
  # offline: still installs the terminal app
  fresh_home
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CLEANMATE_BUNDLE_URL="http://127.0.0.1:9/x.tar.gz" \
    bash "$lone/cleanmate.sh" --install 2>&1)
  assert_contains "$out" "Couldn't get the desktop app"
  assert_exists "$HOME_DIR/.local/bin/cleanmate"
}

test_install_never_shadows_another_cm() {
  fresh_home
  local out
  mkdir -p "$WORK/othercm" && printf '#!/bin/sh\necho other\n' >"$WORK/othercm/cm" && chmod +x "$WORK/othercm/cm"
  out=$(BASE_PATH="$WORK/othercm:$BASE_PATH" cm --install 2>&1)
  assert_contains "$out" "Skipped the"
  assert_missing "$HOME_DIR/.local/bin/cm"
  assert_contains "$out" "Start it any time with: cleanmate"
}

test_update_flow() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  command -v curl >/dev/null || command -v wget >/dev/null || { SKIPPED="neither curl nor wget installed"; return; }
  fresh_home
  local www=$WORK/www port srv out
  mkdir -p "$www"
  sed 's/^VERSION="[0-9.]*"$/VERSION="99.0.0"/' "$SCRIPT" >"$www/new.sh"
  printf '<html>404</html>\n' >"$www/bad.sh"
  port=$((20000 + RANDOM % 20000))
  (cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
  srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.3; done
  cm --install >/dev/null 2>&1

  out=$(CLEANMATE_UPDATE_URL="http://127.0.0.1:$port/bad.sh" cm --update 2>&1 </dev/null)
  assert_contains "$out" "doesn't look like CleanMate"
  out=$(CLEANMATE_UPDATE_URL="http://127.0.0.1:$port/missing.sh" cm --update 2>&1 </dev/null)
  assert_contains "$out" "No published version"
  out=$(CLEANMATE_UPDATE_URL="http://127.0.0.1:9/x.sh" cm --update 2>&1 </dev/null)
  assert_contains "$out" "Could not reach"
  out=$(printf 'y\n' | CLEANMATE_UPDATE_URL="http://127.0.0.1:$port/new.sh" cm --update 2>&1)
  assert_contains "$out" "Updated to 99.0.0"
  assert_eq "$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" bash "$HOME_DIR/.local/bin/cleanmate" --version)" \
    "cleanmate 99.0.0" "installed copy updated"
  assert_eq "$(readlink "$HOME_DIR/.local/bin/cm")" "cleanmate" "cm link survives the update"
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CLEANMATE_UPDATE_URL="http://127.0.0.1:$port/new.sh" \
    bash "$HOME_DIR/.local/bin/cleanmate" --update 2>&1 </dev/null)
  assert_contains "$out" "up to date"
  kill "$srv" 2>/dev/null
}

# Clean My Ubuntu 1.x installed with --install: everything moves over to CleanMate.
test_install_replaces_clean_my_ubuntu() {
  fresh_home
  rmdir "$HOME_DIR/.config/cleanmate"
  local out bin=$HOME_DIR/.local/bin cfg=$HOME_DIR/.config share=$HOME_DIR/.local/share
  local units=$cfg/systemd/user stubs=$WORK/systemctlbin
  mkdir -p "$bin" "$cfg/clean-my-ubuntu" "$HOME_DIR/.local/state/clean-my-ubuntu" "$units" \
    "$share/applications" "$share/icons/hicolor/scalable/apps" "$share/clean-my-ubuntu/gui/cmu_gui" "$stubs"
  printf '#!/usr/bin/env bash\n# clean-my-ubuntu.sh 1.1.1\n' >"$bin/clean-my-ubuntu"
  chmod +x "$bin/clean-my-ubuntu"
  ln -s clean-my-ubuntu "$bin/cmu"
  echo "thumbs=0" >"$cfg/clean-my-ubuntu/selection"
  echo "old run" >"$HOME_DIR/.local/state/clean-my-ubuntu/clean.log"
  : >"$share/applications/com.homielab.CleanMyUbuntu.desktop"
  : >"$share/icons/hicolor/scalable/apps/com.homielab.CleanMyUbuntu.svg"
  : >"$share/clean-my-ubuntu/gui/cmu-gui"
  printf '[Timer]\nOnCalendar=weekly\n' >"$units/clean-my-ubuntu.timer"
  : >"$units/clean-my-ubuntu.service"
  printf '#!/bin/sh\nexit 0\n' >"$stubs/systemctl"; chmod +x "$stubs/systemctl"
  out=$(BASE_PATH="$stubs:$BASE_PATH" cm --install 2>&1)
  assert_contains "$out" "Replaced Clean My Ubuntu"
  assert_eq "$(<"$cfg/cleanmate/selection")" "thumbs=0" "selection moved"
  assert_eq "$(<"$HOME_DIR/.local/state/cleanmate/clean.log")" "old run" "log moved"
  assert_missing "$cfg/clean-my-ubuntu"; assert_missing "$HOME_DIR/.local/state/clean-my-ubuntu"
  assert_eq "$(readlink "$bin/clean-my-ubuntu")" "cleanmate" "clean-my-ubuntu points to cleanmate"
  assert_eq "$(readlink "$bin/cmu")" "cleanmate" "cmu points to cleanmate"
  assert_missing "$share/applications/com.homielab.CleanMyUbuntu.desktop"
  assert_missing "$share/icons/hicolor/scalable/apps/com.homielab.CleanMyUbuntu.svg"
  assert_missing "$share/clean-my-ubuntu"
  assert_missing "$units/clean-my-ubuntu.timer"; assert_missing "$units/clean-my-ubuntu.service"
  assert_contains "$(cat "$units/cleanmate.timer" 2>/dev/null)" "OnCalendar=weekly"
  assert_contains "$(cat "$units/cleanmate.service" 2>/dev/null)" "ExecStart=\"$bin/cleanmate\" --auto"
  printf 'y\nn\n' | BASE_PATH="$stubs:$BASE_PATH" cm --uninstall >/dev/null 2>&1
  assert_missing "$bin/clean-my-ubuntu"; assert_missing "$bin/cmu"
}

# Clean My Ubuntu 1.x updates itself from clean-my-ubuntu.sh, which hands over to CleanMate.
test_clean_my_ubuntu_hands_over() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  command -v curl >/dev/null || command -v wget >/dev/null || { SKIPPED="neither curl nor wget installed"; return; }
  local shim=$ROOT/clean-my-ubuntu.sh www=$WORK/handover port srv out bin
  fresh_home
  assert_eq "$(in_app "script_version '$shim'")" "$(cm --version | awk '{print $2}')" "shim VERSION = script VERSION"
  grep -q 'clean-my-ubuntu' "$shim" && bash -n "$shim" && ok_ "1.x accepts it as an update" || fail "1.x would reject the shim"
  fresh_home
  bin=$HOME_DIR/.local/bin
  mkdir -p "$www" "$bin"
  cp "$SCRIPT" "$www/cleanmate.sh"
  install -m 755 "$shim" "$bin/clean-my-ubuntu" # what a 1.x --update leaves behind
  port=$((20000 + RANDOM % 20000))
  (cd "$www" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
  srv=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.3; done
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CLEANMATE_NO_UPDATE_CHECK=1 \
    CLEANMATE_UPDATE_URL="http://127.0.0.1:$port/cleanmate.sh" CLEANMATE_BUNDLE_URL="http://127.0.0.1:9/x.tar.gz" \
    bash "$bin/clean-my-ubuntu" --version 2>&1)
  kill "$srv" 2>/dev/null
  assert_eq "$out" "$(cm --version)" "runs CleanMate"
  assert_exists "$bin/cleanmate"
  assert_eq "$(readlink "$bin/clean-my-ubuntu")" "cleanmate" "clean-my-ubuntu points to cleanmate"
  # offline and not installed yet: says where to get it
  fresh_home
  install -m 755 -D "$shim" "$HOME_DIR/.local/bin/clean-my-ubuntu"
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" CLEANMATE_UPDATE_URL="http://127.0.0.1:9/x.sh" \
    bash "$HOME_DIR/.local/bin/clean-my-ubuntu" 2>&1)
  assert_contains "$out" "github.com/homielab/cleanmate-linux"
}

test_trash_and_undo() {
  fresh_home
  local f="$HOME_DIR/Docs/sub dir/Tài liệu 50%.pdf" out info expected
  mkdir -p "$HOME_DIR/Docs/sub dir" "$HOME_DIR/Other" "$HOME_DIR/Docs/folder"
  echo a >"$f"; echo b >"$HOME_DIR/Docs/report.txt"; echo c >"$HOME_DIR/Other/report.txt"; echo d >"$HOME_DIR/Docs/folder/x"
  out=$(in_app '
    for p in "$HOME/Docs/sub dir/Tài liệu 50%.pdf" "$HOME/Docs/report.txt" "$HOME/Other/report.txt" "$HOME/Docs/folder"; do
      move_to_trash "$p" || echo "FAILED $p"
    done
    ls "$TRASH_DIR/files" | LC_ALL=C sort | paste -sd"|" -
    undo_trash; echo "restored=$UNDO_OK failed=$UNDO_FAILED"')
  assert_contains "$out" "Tài liệu 50%.pdf|folder|report.txt|report.txt.2" # same-name files don't collide
  assert_contains "$out" "restored=4 failed=0"
  assert_exists "$f"; assert_exists "$HOME_DIR/Docs/report.txt"; assert_exists "$HOME_DIR/Other/report.txt"
  assert_exists "$HOME_DIR/Docs/folder/x"
  # the .trashinfo must be spec-compliant (percent-encoded path), so GNOME Files can restore it too
  in_app 'move_to_trash "$HOME/Docs/sub dir/Tài liệu 50%.pdf"' >/dev/null
  info=$(sed -n 's/^Path=//p' "$HOME_DIR/.local/share/Trash/info/Tài liệu 50%.pdf.trashinfo")
  if command -v python3 >/dev/null; then
    expected=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/._~-"))' "$f")
    assert_eq "$info" "$expected" "trashinfo Path is percent-encoded like the spec"
  fi
  in_app 'move_to_trash /etc/hostname' >/dev/null 2>&1 && fail "should refuse protected paths" || ok_ "refuses /etc paths"
}

test_kernel_rules_keep_a_fallback() {
  fresh_home
  local r
  r=$(in_app 'printf "6.1\n6.2\n" | kernel_extras 6.2 | paste -sd" " -'); assert_eq "$r" "" "two kernels: keep both"
  r=$(in_app 'printf "6.1\n6.2\n6.3\n" | kernel_extras 6.3 | paste -sd" " -'); assert_eq "$r" "6.1" "keep newest two"
  r=$(in_app 'printf "6.1\n6.2\n6.3\n6.4\n" | kernel_extras 6.1 | paste -sd" " -'); assert_eq "$r" "6.2" "never the running one"
  r=$(in_app 'printf "6.8.0-9\n6.8.0-10\n6.8.0-11\n" | kernel_extras 6.8.0-11 | paste -sd" " -'); assert_eq "$r" "6.8.0-9" "version sort, not text sort"
}

test_docker_items_prune_only_what_is_selected() {
  fresh_home
  local log=$WORK/docker.log out
  : >"$log"
  mkdir -p "$WORK/dockerbin"
  cat >"$WORK/dockerbin/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$log"
case "\$*" in
  info*) exit 0 ;;
  "system df --format"*) printf 'Images\t1.5GB (60%%)\nContainers\t200MB (100%%)\nLocal Volumes\t50MB (10%%)\nBuild Cache\t2GB\n' ;;
  "images -f dangling=true --format {{.Size}}") printf '120MB\n80MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\n' ;;
  "volume ls -qf dangling=true") printf 'v1\n' ;;
esac
EOF
  chmod +x "$WORK/dockerbin/docker"
  out=$(BASE_PATH="$WORK/dockerbin:$BASE_PATH" cm --scan --only dev 2>&1)
  assert_contains "$out" "Docker: dangling images"
  assert_contains "$out" "2 images"
  assert_contains "$out" "2 containers"
  assert_contains "$out" "1 volume — may contain data"
  select_only docker_dangling docker_build
  BASE_PATH="$WORK/dockerbin:$BASE_PATH" cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  out=$(<"$log")
  assert_contains "$out" "image prune -f"
  assert_contains "$out" "builder prune -f"
  [[ $out == *"volume prune"* ]] && fail "volumes must not be pruned unless selected" || ok_ "volumes untouched"
  [[ $out == *"container prune"* ]] && fail "containers must not be pruned unless selected" || ok_ "containers untouched"
  [[ $out == *"image prune -a"* ]] && fail "unused images must not be pruned unless selected" || ok_ "unused images untouched"
}

docker_entries_stub() { # DIR LOG — a docker with two dangling images and three build-cache records; calls logged
  local a b
  a=sha256:$(printf 'a%.0s' {1..64}) b=sha256:$(printf 'b%.0s' {1..64})
  mkdir -p "$1"
  cat >"$1/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$2"
case "\$*" in
  info*) exit 0 ;;
  "context inspect"*) echo unix:///var/run/docker.sock ;;
  "system df --format"*) printf 'Images\t200MB (10%%)\nBuild Cache\t3.5GB\n' ;;
  "system df -v --format"*) printf '%s\n' \\
    'k4v2r7x9q0w3e5t8y1u6i2o4p|3GB|false|false|regular|2 days ago|mount / from exec /bin/sh -c npm ci' \\
    'z9y8x7w6v5u4t3s2r1q0p9o8n|500MB|false|true|source.local|3 hours ago|local source for context' \\
    'inuse0000000000000000000x|1GB|true|false|regular|1 minute ago|being built' ;;
  "images -f dangling=true --format {{.Size}}") printf '120MB\n80MB\n' ;;
  "images -f dangling=true --no-trunc"*) printf '$a\t120MB\t3 days ago\n$b\t80MB\t2 weeks ago\n' ;;
esac
EOF
  chmod +x "$1/docker"
}

entry_list() { # reads `--json details` / `clean` → entries and tasks, one line each
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["item"], e["id"][:16], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["id"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
}

test_docker_entries_one_by_one() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local log=$WORK/docker-entries.log out a b
  a=sha256:$(printf 'a%.0s' {1..64}) b=sha256:$(printf 'b%.0s' {1..64})
  : >"$log"
  chmod 666 "$log" # root runs write it as nobody
  docker_entries_stub "$WORK/dockerentries" "$log"
  local BASE_PATH="$WORK/dockerentries:$BASE_PATH"
  out=$(cm --json details docker_dangling | entry_list)
  assert_eq "$out" "docker_dangling sha256:aaaaaaaaa 120000000 on aaaaaaaaaaaa · created 3 days ago
docker_dangling sha256:bbbbbbbbb 80000000 on bbbbbbbbbbbb · created 2 weeks ago" "dangling images, ticked"
  out=$(cm --json details docker_build | entry_list)
  assert_eq "$out" "docker_build k4v2r7x9q0w3e5t8 3000000000 off mount / from exec /bin/sh -c npm ci · used 2 days ago
docker_build z9y8x7w6v5u4t3s2 0 off local source for context · used 3 hours ago · shared" \
    "build cache: not in use only, biggest first, shared = 0 bytes, not ticked"
  out=$(cm --json scan --only dev | grep '"id":"docker_build"')
  assert_contains "$out" '"entries":true'
  assert_contains "$(cm --json scan --only dev | grep '"id":"docker_volumes"')" '"entries":false'
  # untick one of two dangling images → only the other is removed
  : >"$log"
  out=$(user_cm --json clean docker_dangling --entries "$a" | entry_list)
  assert_contains "$out" "ok docker_dangling"
  assert_eq "$(grep -c '^rmi ' "$log")" 1 "one docker rmi"
  assert_contains "$(<"$log")" "rmi $a"
  [[ $(<"$log") == *"rmi $b"* || $(<"$log") == *"image prune"* ]] && fail "only the chosen image is removed" || ok_ "the other image stays"
  : >"$log"
  user_cm --json clean docker_build --entries k4v2r7x9q0w3e5t8y1u6i2o4p >/dev/null
  assert_contains "$(<"$log")" "builder prune --force --filter id=k4v2r7x9q0w3e5t8y1u6i2o4p"
  # dry run: what the chosen entries would free, nothing run
  : >"$log"
  out=$(user_cm --json --dry-run clean docker_dangling --entries "$a" | entry_list)
  assert_contains "$out" "ok docker_dangling 120000000"
  [[ $(<"$log") == *rmi* ]] && fail "dry run must not remove" || ok_ "dry run removes nothing"
  # wrong IDs are refused before docker is asked anything
  : >"$log"
  out=$(user_cm --json clean docker_dangling --entries 'sha256:abc;rm' 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID of docker_dangling: sha256:abc;rm"
  out=$(user_cm --json clean docker_dangling --entries "postgres:18" 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID"
  out=$(user_cm --json clean docker_build --entries "-f,abc" 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID of docker_build: -f"
  out=$(user_cm --json clean docker_volumes --entries abc 2>&1 | entry_list)
  assert_contains "$out" "error docker_volumes can't be cleaned entry by entry"
  out=$(user_cm --json clean docker_dangling docker_build --entries "$a" 2>&1 | entry_list)
  assert_contains "$out" "error --entries works with one item at a time"
  assert_eq "$(<"$log")" "" "docker never called for a refused request"
  # a well-formed ID that isn't listed (a tagged image, a record in use) is never removed
  out=$(user_cm --json clean docker_dangling --entries "sha256:$(printf 'c%.0s' {1..64})" | entry_list)
  assert_contains "$out" "fail docker_dangling 0 None of the chosen entries is there any more"
  out=$(user_cm --json clean docker_build --entries inuse0000000000000000000x | entry_list)
  assert_contains "$out" "fail docker_build"
  [[ $(<"$log") == *"rmi"* || $(<"$log") == *"builder prune"* ]] && fail "unlisted entries must not be removed" || ok_ "unlisted entries untouched"
  # a Docker that isn't on this computer: no entries
  out=$(in_app 'DOCKER_HOST=tcp://10.0.0.5:2375 json_entries docker_dangling')
  assert_eq "$out" "" "no entries for a remote Docker"
}

test_free_space_history() {
  fresh_home
  local out today
  printf -v today '%(%Y-%m-%d)T' -1
  in_app 'record_disk_usage; record_disk_usage' >/dev/null
  assert_eq "$(grep -c "^$today" "$HOME_DIR/.local/state/cleanmate/disk-history.tsv")" 1 "one row per day"
  assert_eq "$(in_app 'sparkline s 50 40 45 30 20 25 10; echo "$s"')" "█▆▇▄▂▃▁" "sparkline"
  printf '%s\t%s\t%s\n' 2026-01-01 50000000000 100000000000 2026-01-15 40000000000 100000000000 \
    >"$HOME_DIR/.local/state/cleanmate/disk-history.tsv"
  out=$(in_app 'disk_history_lines')
  assert_contains "$out" "Losing about"
  assert_contains "$out" "is full in ~"
}

test_auto_clean_reports_what_is_left() {
  fresh_home
  local log=$WORK/notify.log out
  : >"$log"
  mkdir -p "$WORK/notifybin" "$HOME_DIR/.cache/google-chrome/Default/Cache"
  printf '#!/bin/sh\necho "$*" >>"%s"\n' "$log" >"$WORK/notifybin/notify-send"
  chmod +x "$WORK/notifybin/notify-send"
  head -c 120000000 /dev/zero >"$HOME_DIR/.cache/google-chrome/Default/Cache/big" # 120 MB, never auto-cleaned
  new "$HOME_DIR/.cache/thumbnails/large/a.png"
  out=$(BASE_PATH="$WORK/notifybin:$BASE_PATH" cm --auto 2>&1 </dev/null)
  assert_missing "$HOME_DIR/.cache/thumbnails/large/a.png" # user junk is cleaned
  assert_exists "$HOME_DIR/.cache/google-chrome/Default/Cache/big" # browsers are only reported
  out=$(<"$log")
  assert_contains "$out" "Worth a look: "
  assert_contains "$out" "Google Chrome"
}

test_json_protocol() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out check
  mkdir -p "$HOME_DIR/.cache/thumbnails/large"; echo x >"$HOME_DIR/.cache/thumbnails/large/a.png"
  check='import sys, json
ev = [json.loads(l) for l in sys.stdin if l.strip()]   # every line must be JSON
kinds = {}
for e in ev: kinds[e["event"]] = kinds.get(e["event"], 0) + 1
print(" ".join(f"{k}={v}" for k, v in sorted(kinds.items())), "last=" + ev[-1]["event"])'
  out=$(cm --json items | python3 -c "$check" 2>&1); assert_contains "$out" "last=done"
  out=$(cm --json scan | python3 -c "$check" 2>&1)
  assert_contains "$out" "progress="; assert_contains "$out" "item="; assert_contains "$out" "last=done"
  out=$(cm --json scan | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e.get("id") == "thumbs": print(e["status"], e["bytes"] > 0, e["selected"], e["root"])')
  assert_eq "$out" "found True True False" "thumbs item in scan"
  out=$(cm --json details thumbs | python3 -c "$check" 2>&1); assert_contains "$out" "details=1"
  if ((EUID == 0)); then
    out=$(cm --json clean thumbs 2>&1); assert_contains "$out" "Refusing to clean thumbs as root"
    assert_exists "$HOME_DIR/.cache/thumbnails/large/a.png"
  fi
  out=$(user_cm --json --dry-run clean thumbs 2>&1); assert_contains "$out" '"state":"ok"'
  assert_exists "$HOME_DIR/.cache/thumbnails/large/a.png"
  out=$(user_cm --json clean thumbs 2>&1); assert_contains "$out" '"event":"done"'
  assert_missing "$HOME_DIR/.cache/thumbnails/large/a.png"
  out=$(user_cm --json clean thumbs nope 2>&1); assert_contains "$out" "Unknown item: nope"
  in_app 'json_allowed journal 0' && ok_ "root may clean system items" || fail "root should clean journal"
  in_app 'json_allowed thumbs 0' && fail "root must not clean home items" || ok_ "root refused for home items"
  in_app 'json_allowed thumbs 1000' && ok_ "user may clean home items" || fail "user should clean thumbs"
}

large_names() { # reads `--json large` → "kind bytes name" lines, then "done COUNT"
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "file": print(e["kind"], e["bytes"], e["path"].rsplit("/", 1)[1])
    elif e["event"] == "done": print("done", e["count"])
    else: print(e["event"], e.get("message", ""))'
}

test_json_large_files() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out v=$HOME_DIR/Videos
  mkdir -p "$v" "$HOME_DIR/Old stuff" "$HOME_DIR/.cache/app" "$HOME_DIR/code/.git" "$HOME_DIR/.local/share/Trash/files"
  truncate -s 3M "$v/film one.mkv"
  truncate -s 2M "$HOME_DIR/Old stuff/backup.iso"; truncate -s 1536K "$v/watched.mp4"
  touch -d '200 days ago' "$HOME_DIR/Old stuff/backup.iso"
  touch -m -d '200 days ago' "$v/watched.mp4" # old, but opened recently
  truncate -s 10K "$v/small.txt"
  truncate -s 5M "$HOME_DIR/.cache/app/blob" "$HOME_DIR/code/.git/pack" "$HOME_DIR/.local/share/Trash/files/gone.bin"
  out=$(cm --json large --min 1048576 | large_names)
  assert_eq "$out" $'video 3145728 film one.mkv\ndisk 2097152 backup.iso\nvideo 1572864 watched.mp4\ndone 3' \
    "big files listed biggest first; caches, .git and the Trash skipped"
  out=$(cm --json large --min 1048576 --days 90 | large_names)
  assert_eq "$out" $'disk 2097152 backup.iso\ndone 1' "old = not changed and not opened for 90 days"
  out=$(cm --json large --min 0 --path "$v" | large_names)
  assert_eq "$out" $'video 3145728 film one.mkv\nvideo 1572864 watched.mp4\ndocument 10240 small.txt\ndone 3' "--path"
  out=$(cm --json large --min 5M 2>&1); assert_contains "$out" "Invalid size: 5M"
  out=$(cm --json large --path "$HOME_DIR/nope" 2>&1); assert_contains "$out" "Not a folder"
  out=$(cm --json large --days 2>&1); assert_contains "$out" "--days needs a value"
}

test_json_trash_and_restore() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out f1="$HOME_DIR/Videos/film one.mkv" f2="$HOME_DIR/Docs/ünï %20.pdf" keep=$HOME_DIR/Videos/keep.mkv
  local trash=$HOME_DIR/.local/share/Trash
  new "$f1"; new "$f2"; new "$keep"
  local tasks='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], e["trash"] or "-", e["info"])
    elif e["event"] == "done": print("done", e.get("moved", e.get("restored")), e["failed"])'
  if ((EUID == 0)); then
    out=$(cm --json trash "$keep" 2>&1); assert_contains "$out" "Refusing to move files to the Trash as root"
    assert_exists "$keep"
  fi
  out=$(user_cm --json --dry-run trash "$f1" | python3 -c "$tasks")
  assert_eq "$out" $'ok - would be moved to the Trash\ndone 1 0' "dry run"
  assert_exists "$f1"
  out=$(user_cm --json trash "$f1" "$f2" "$HOME_DIR/missing" "$HOME_DIR" | python3 -c "$tasks")
  assert_eq "$out" $'ok film one.mkv moved to the Trash\nok ünï %20.pdf moved to the Trash\nfail - Not found\nfail - Refusing to touch protected path: '"$HOME_DIR"$'\ndone 2 2' "trash"
  assert_missing "$f1"; assert_missing "$f2"; assert_exists "$keep"; assert_exists "$HOME_DIR"
  assert_exists "$trash/files/film one.mkv"; assert_exists "$trash/info/ünï %20.pdf.trashinfo"
  out=$(user_cm --json --dry-run restore "film one.mkv" | python3 -c "$tasks")
  assert_eq "$out" $'ok film one.mkv would be put back\ndone 1 0' "dry-run restore"
  assert_missing "$f1"
  new "$HOME_DIR/Docs/ünï %20.pdf" # something new took its place: never overwritten
  out=$(user_cm --json restore "film one.mkv" "ünï %20.pdf" "../x" | python3 -c "$tasks")
  assert_eq "$out" $'ok film one.mkv put back\nfail ünï %20.pdf A file with this name is already there\nfail ../x Not in the Trash any more\ndone 1 2' "restore"
  assert_exists "$f1"; assert_missing "$trash/files/film one.mkv"; assert_missing "$trash/info/film one.mkv.trashinfo"
  assert_exists "$trash/files/ünï %20.pdf"
  rm -f "$f2"
  out=$(user_cm --json restore "ünï %20.pdf" | python3 -c "$tasks")
  assert_eq "$out" $'ok ünï %20.pdf put back\ndone 1 0' "restore an encoded name"
  assert_exists "$f2"
  out=$(user_cm --json restore "film one.mkv" | python3 -c "$tasks")
  assert_eq "$out" $'fail film one.mkv Not in the Trash any more\ndone 0 1' "restore twice"
  # a Path= that climbs out of the home folder is never followed
  mkdir -p "$trash/files" "$trash/info"; new "$trash/files/evil"
  printf '[Trash Info]\nPath=%s/../escaped\nDeletionDate=2026-01-01T00:00:00\n' "$HOME_DIR" >"$trash/info/evil.trashinfo"
  out=$(user_cm --json restore evil | python3 -c "$tasks")
  assert_contains "$out" "fail evil Not in the Trash any more"
  assert_missing "$(dirname "$HOME_DIR")/escaped"; assert_exists "$trash/files/evil"
}

test_json_trash_on_a_drive() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out key uid=$EUID vol usb f keep
  ((EUID == 0)) && uid=65534 # user_cm runs as nobody
  vol=$(mktemp -d -p "$WORK" media.XXXX) # every folder in it counts as a mounted drive
  usb=$vol/USB
  f="$usb/Films/big one.mkv" keep=$usb/Films/keep.mkv
  new "$f"; new "$keep"; new "$vol/RO/sub/disc.iso"; new "$vol/LINK/movie.mkv"; new "$vol/SHARED/a.bin"
  mkdir -p "$WORK/elsewhere.$uid"; ln -s "$WORK/elsewhere.$uid" "$vol/LINK/.Trash-$uid"
  mkdir -p "$vol/SHARED/.Trash" && chmod 1777 "$vol/SHARED/.Trash" # an admin's shared Trash (sticky)
  mkdir -p "$HOME_DIR/.local/bin" # gio would trash elsewhere: here it fails, so only the app's own Trash counts
  printf '#!/bin/sh\necho "gio could not trash it" >&2\nexit 1\n' >"$HOME_DIR/.local/bin/gio"; chmod +x "$HOME_DIR/.local/bin/gio"
  ((EUID == 0)) && chown -R 65534:65534 "$vol" "$WORK/elsewhere.$uid" && chown 0:0 "$vol/SHARED/.Trash"
  chmod 555 "$vol/RO" # read-only drive: no Trash folder can be made there
  local CLEANMATE_VOLUME_ROOTS=$vol
  local tasks='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], e["trash"] or "-", e["info"])
    elif e["event"] == "done": print("done", e.get("moved", e.get("restored")), e["failed"])'
  out=$(user_cm --json --dry-run trash "$f" | python3 -c "$tasks")
  assert_eq "$out" $'ok - would be moved to the Trash\ndone 1 0' "dry run"
  assert_exists "$f"; assert_missing "$usb/.Trash-$uid"
  key=$usb/.Trash-$uid/files/big\ one.mkv
  out=$(user_cm --json trash "$f" "$vol/RO/sub/disc.iso" "$vol/LINK/movie.mkv" "$vol/SHARED/a.bin" | python3 -c "$tasks")
  assert_eq "$out" "ok $key moved to the Trash"$'\nfail - gio could not trash it\nfail - gio could not trash it\n'"ok $vol/SHARED/.Trash/$uid/files/a.bin moved to the Trash"$'\ndone 2 2' \
    "to the drive's own Trash; a read-only drive or a symlinked Trash is left to gio"
  assert_missing "$f"; assert_exists "$keep"; assert_exists "$key"
  assert_eq "$(stat -c %a "$usb/.Trash-$uid")" 700 "the drive's Trash is private"
  assert_eq "$(sed -n 's/^Path=//p' "$usb/.Trash-$uid/info/big one.mkv.trashinfo")" "Films/big%20one.mkv" \
    "Path= relative to the drive, like GNOME Files"
  assert_exists "$vol/RO/sub/disc.iso"; assert_missing "$vol/RO/.Trash-$uid"
  assert_exists "$vol/LINK/movie.mkv"; assert_eq "$(ls -A "$WORK/elsewhere.$uid")" "" "never writes through a symlinked Trash"
  out=$(cm --json large --min 1 --path "$usb" | python3 -c 'import sys, json
print(*[e["path"].rsplit("/", 1)[1] for e in map(json.loads, sys.stdin) if e["event"] == "file"])')
  assert_eq "$out" "keep.mkv" "Large & Old Files skips the drive's Trash"
  new "$f" # something new took its place: never overwritten
  out=$(user_cm --json restore "$key" | python3 -c "$tasks")
  assert_eq "$out" "fail $key A file with this name is already there"$'\ndone 0 1' "restore never overwrites"
  assert_exists "$key"
  rm -f "$f"
  out=$(user_cm --json restore "$key" "$vol/SHARED/.Trash/$uid/files/a.bin" | python3 -c "$tasks")
  assert_eq "$out" "ok $key put back"$'\n'"ok $vol/SHARED/.Trash/$uid/files/a.bin put back"$'\ndone 2 0' "restore from the drive's Trash"
  assert_exists "$f"; assert_exists "$vol/SHARED/a.bin"
  assert_missing "$key"; assert_missing "$usb/.Trash-$uid/info/big one.mkv.trashinfo"
  # forged keys: outside a drive, through ../, or a Path= that climbs out of the drive
  mkdir -p "$WORK/.Trash-$uid/files" "$WORK/.Trash-$uid/info"; new "$WORK/.Trash-$uid/files/x"
  printf '[Trash Info]\nPath=x\nDeletionDate=2026-01-01T00:00:00\n' >"$WORK/.Trash-$uid/info/x.trashinfo"
  new "$usb/.Trash-$uid/files/evil"
  printf '[Trash Info]\nPath=../escaped\nDeletionDate=2026-01-01T00:00:00\n' >"$usb/.Trash-$uid/info/evil.trashinfo"
  ((EUID == 0)) && chown -R 65534:65534 "$vol" "$WORK/.Trash-$uid"
  out=$(user_cm --json restore "$WORK/.Trash-$uid/files/x" "$usb/.Trash-$uid/files/../../USB/.Trash-$uid/files/evil" \
    "$usb/.Trash-$uid/files/evil" | python3 -c "$tasks" | cut -d' ' -f1)
  assert_eq "$out" $'fail\nfail\nfail\ndone' "forged keys are refused"
  assert_exists "$WORK/.Trash-$uid/files/x"; assert_exists "$usb/.Trash-$uid/files/evil"; assert_missing "$vol/escaped"
  chmod 755 "$vol/RO" # so the clean-up can remove it
}

sized() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/zero >"$1"; } # FILE BYTES

test_trash_on_external_drives() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out uid=$EUID vol usb disk hold=() pid t
  ((EUID == 0)) && uid=65534 hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  vol=$(mktemp -d -p "$WORK" media.XXXX) # every folder in it counts as a mounted drive
  usb=$vol/USB disk="$vol/My Disk" t=$vol/USB/.Trash-$uid
  sized "$t/files/a.bin" 1000; sized "$t/files/b.bin" 2000; sized "$t/files/open.log" 100
  mkdir -p "$t/info"
  local f
  for f in a.bin b.bin open.log gone; do printf '[Trash Info]\nPath=%s\n' "$f" >"$t/info/$f.trashinfo"; done
  sized "$usb/.Trash-4242/files/other.bin" 7000 # another user's Trash
  mkdir -p "$disk/.Trash" && chmod 1777 "$disk/.Trash" # an admin's shared Trash (sticky)
  sized "$disk/.Trash/$uid/files/c.bin" 500
  sized "$WORK/elsewhere-drive/files/y.bin" 900; ln -s "$WORK/elsewhere-drive" "$vol/LINK" # a drive that is a symlink
  mkdir -p "$vol/LINKED"; ln -s "$WORK/elsewhere-drive" "$vol/LINKED/.Trash-$uid"  # a Trash that is a symlink
  sized "$vol/NAS/.Trash-$uid/files/n.bin" 800; sized "$vol/RO/.Trash-$uid/files/r.bin" 600
  printf 'server:/export %s/NAS nfs4 rw,relatime 0 0\n/dev/sdz1 %s/RO vfat ro,nosuid 0 0\n/dev/sdy1 %s/My\\040Disk ext4 rw,nosuid 0 0\n' \
    "$vol" "$vol" "$vol" >"$WORK/mounts"
  if ((EUID == 0)); then
    chown -R 65534:65534 "$vol" "$WORK/elsewhere-drive"; chown -R 4242:4242 "$usb/.Trash-4242"; chown 0:0 "$disk/.Trash"
  fi
  local CLEANMATE_VOLUME_ROOTS=$vol CLEANMATE_MOUNTS=$WORK/mounts
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
  out=$(user_cm --json scan --only user | grep '"id":"trash_drives"' | python3 -c "$list")
  assert_eq "$out" "trash_drives 3600 4 items on 2 drives False True False" \
    "counts your Trash on writable local drives only, not ticked"
  out=$(user_cm --json details trash_drives | python3 -c "$list")
  assert_eq "$out" "$vol/My%20Disk 500 off My Disk · 1 item"$'\n'"$vol/USB 3100 off USB · 3 items" "one entry per drive"
  out=$(user_cm --json --dry-run clean trash_drives | python3 -c "$list")
  assert_contains "$out" "ok 3600"
  assert_exists "$t/files/a.bin"; assert_exists "$disk/.Trash/$uid/files/c.bin"
  # one drive
  out=$(user_cm --json clean trash_drives --entries "$vol/My%20Disk" | python3 -c "$list")
  assert_eq "$out" "ok 500 500 B freed" "only the chosen drive"
  assert_missing "$disk/.Trash/$uid/files/c.bin"; assert_exists "$disk/.Trash/$uid/files"; assert_exists "$t/files/a.bin"
  out=$(user_cm --json clean trash_drives --entries "$vol/NAS" | python3 -c "$list")
  assert_contains "$out" "None of the chosen entries is there any more"
  out=$(user_cm --json clean trash_drives --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of trash_drives: ../etc"
  # everything, while a program keeps a file in the Trash open
  "${hold[@]}" sleep 60 <"$t/files/open.log" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json clean trash_drives | python3 -c "$list")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok 3000 2.9 KB freed" "empties the drive's Trash, an open file stays"
  assert_missing "$t/files/a.bin"; assert_missing "$t/files/b.bin"
  assert_missing "$t/info/a.bin.trashinfo"; assert_missing "$t/info/gone.trashinfo"
  assert_exists "$t/files/open.log"; assert_exists "$t/info/open.log.trashinfo"
  assert_exists "$t/info"
  assert_exists "$usb/.Trash-4242/files/other.bin"; assert_exists "$WORK/elsewhere-drive/files/y.bin"
  assert_exists "$vol/NAS/.Trash-$uid/files/n.bin"; assert_exists "$vol/RO/.Trash-$uid/files/r.bin"
  # automatic cleaning never empties it, even when you ticked it
  select_only trash_drives
  sized "$t/files/again.bin" 10
  ((EUID == 0)) && chown -R 65534:65534 "$t"
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$t/files/again.bin"
}

test_old_installers_in_downloads() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local dl=$HOME_DIR/Downloads out f pid hold=()
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  sized "$dl/a.deb" 1000; sized "$dl/b.iso" 2000; sized "$dl/Tool, v2.AppImage" 300
  sized "$dl/c.deb" 50                                       # new
  sized "$dl/d.iso.part" 70                                  # not an installer (a download in progress)
  sized "$dl/e.iso" 0; sized "$dl/e.iso.part" 80             # still downloading
  sized "$dl/sub/f.deb" 90                                   # in a subfolder
  sized "$dl/notes.txt" 40                                   # not an installer
  sized "$dl/open.run" 60                                    # open in a program
  sized "$WORK/elsewhere.deb" 500; ln -s "$WORK/elsewhere.deb" "$dl/link.deb"
  for f in a.deb b.iso "Tool, v2.AppImage" d.iso.part e.iso e.iso.part sub/f.deb notes.txt open.run; do
    touch -d "40 days ago" "$dl/$f"
  done
  touch -h -d "40 days ago" "$dl/link.deb"
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  "${hold[@]}" sleep 60 <"$dl/open.run" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only system | grep '"id":"old_installers"' | python3 -c "$list")
  assert_eq "$out" "old_installers 3300 3 files older than 30 days False True False" \
    "old installers at the top of Downloads only, not ticked"
  out=$(user_cm --json details old_installers | python3 -c "$list")
  assert_eq "$out" "b.iso 2000 off b.iso · 40 days old"$'\n'"a.deb 1000 off a.deb · 40 days old"$'\n'"Tool%2C%20v2.AppImage 300 off Tool, v2.AppImage · 40 days old" \
    "one entry per file, biggest first"
  out=$(user_cm --json --dry-run clean old_installers | python3 -c "$list")
  assert_contains "$out" "ok 3300"
  assert_exists "$dl/a.deb"
  out=$(user_cm --json clean old_installers --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of old_installers: ../etc"
  out=$(user_cm --json clean old_installers --entries "Tool%2C%20v2.AppImage,c.deb" | python3 -c "$list")
  assert_eq "$out" "ok 300 300 B freed" "only the chosen file"
  assert_missing "$dl/Tool, v2.AppImage"; assert_exists "$dl/a.deb"; assert_exists "$dl/c.deb"
  out=$(user_cm --json clean old_installers | python3 -c "$list")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  touch "$dl/open.run" # new now, so the next cleanups leave it alone
  assert_eq "$out" "ok 3000 2.9 KB freed" "the rest"
  assert_missing "$dl/a.deb"; assert_missing "$dl/b.iso"
  assert_exists "$HOME_DIR/.local/share/Trash/files/a.deb"; assert_exists "$HOME_DIR/.local/share/Trash/info/b.iso.trashinfo"
  for f in c.deb d.iso.part e.iso e.iso.part sub/f.deb notes.txt open.run link.deb; do assert_exists "$dl/$f"; done
  assert_exists "$WORK/elsewhere.deb"
  out=$(user_cm --json restore a.deb b.iso | python3 -c "$list")
  assert_eq "$out" "ok 0 put back"$'\n'"ok 0 put back" "restore puts them back"
  assert_exists "$dl/a.deb"; assert_exists "$dl/b.iso"
  # the terminal app: what a cleanup moved to the Trash is the batch z puts back
  out=$(in_app 'SESSION_TMP=$(mktemp -d) UI_ACTIVE=0 DRY_RUN=0
    new_tasks clean; add_task "Old installers" task_clean old_installers; CLEAN_UNDO=()
    run_tasks Cleaning >/dev/null
    echo "batch=${#CLEAN_UNDO[@]}"; UNDO_BATCH=("${CLEAN_UNDO[@]}")
    [[ -e $HOME/Downloads/a.deb ]] && echo "not trashed"
    undo_trash; echo "restored=$UNDO_OK"; rm -r "$SESSION_TMP"')
  assert_eq "$out" "batch=2"$'\n'"restored=2" "z puts back what the cleanup trashed"
  assert_exists "$dl/a.deb"; assert_exists "$dl/b.iso"
  # xdg-user-dir decides where Downloads is
  mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Tải về"
  printf '#!/bin/sh\necho "%s"\n' "$HOME_DIR/Tải về" >"$HOME_DIR/.local/bin/xdg-user-dir"; chmod +x "$HOME_DIR/.local/bin/xdg-user-dir"
  sized "$HOME_DIR/Tải về/g.flatpakref" 10; touch -d "40 days ago" "$HOME_DIR/Tải về/g.flatpakref"
  out=$(user_cm --json details old_installers | python3 -c "$list")
  assert_eq "$out" "g.flatpakref 10 off g.flatpakref · 40 days old" "the folder xdg-user-dir names"
  # Settings › Old installers: how old a file has to be
  sized "$HOME_DIR/Tải về/h.deb" 20; touch -d "10 days ago" "$HOME_DIR/Tải về/h.deb"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  out=$(user_cm --json settings-set installer_days 6 2>&1); assert_contains "$out" "installer_days must be a number from 7 to 3650"
  out=$(user_cm --json settings-set installer_days 3651 2>&1); assert_contains "$out" "installer_days must be a number from 7 to 3650"
  user_cm --json settings-set installer_days 7 >/dev/null
  out=$(user_cm --json details old_installers | python3 -c "$list")
  assert_eq "$out" "h.deb 20 off h.deb · 10 days old"$'\n'"g.flatpakref 10 off g.flatpakref · 40 days old" "installer_days 7"
  assert_contains "$(user_cm --json items)" "downloaded more than 7 days ago"
  user_cm --json settings-set installer_days 30 >/dev/null
  out=$(user_cm --json details old_installers | python3 -c "$list")
  assert_eq "$out" "g.flatpakref 10 off g.flatpakref · 40 days old" "installer_days 30"
  # a Downloads folder outside the home folder is never scanned; the item says why
  mkdir -p "$WORK/data/dl"; sized "$WORK/data/dl/x.deb" 30; touch -d "40 days ago" "$WORK/data/dl/x.deb"
  printf '#!/bin/sh\necho "%s"\n' "$WORK/data/dl" >"$HOME_DIR/.local/bin/xdg-user-dir"
  out=$(user_cm --json scan --only system | grep '"id":"old_installers"' | python3 -c "$list")
  assert_eq "$out" "old_installers 0 Downloads folder is outside your home folder ($WORK/data/dl); CleanMate only cleans inside it False True False" \
    "outside the home folder: a note, nothing listed"
  out=$(user_cm --json details old_installers 2>&1 | python3 -c "$list")
  assert_eq "$out" "" "no entries outside the home folder"
  user_cm --json clean old_installers >/dev/null 2>&1
  assert_exists "$WORK/data/dl/x.deb"
  # …and a symlink to it counts as outside
  ln -s "$WORK/data/dl" "$HOME_DIR/dl-link"
  printf '#!/bin/sh\necho "%s"\n' "$HOME_DIR/dl-link" >"$HOME_DIR/.local/bin/xdg-user-dir"
  out=$(user_cm --json scan --only system | grep '"id":"old_installers"' | python3 -c "$list")
  assert_contains "$out" "Downloads folder is outside your home folder ($HOME_DIR/dl-link)"
}

test_stale_project_build_folders() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local c=$HOME_DIR/code out f p pids=() hold=() rusty py pods enc
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  rusty=$c/rusty py=$c/py pods=$c/app/ios
  new "$rusty/Cargo.toml"; new "$rusty/Cargo.lock"; sized "$rusty/target/debug/app" 500000; new "$rusty/.git/index"
  new "$py/pyproject.toml"; new "$py/.venv/pyvenv.cfg"; sized "$py/.venv/lib/site.so" 200000
  new "$pods/Podfile"; new "$pods/Podfile.lock"; sized "$pods/Pods/Lib/lib.a" 50000
  new "$c/fresh-lock/Cargo.toml"; new "$c/fresh-lock/Cargo.lock"; sized "$c/fresh-lock/target/x" 10      # lockfile 10 days old
  new "$HOME_DIR/work/repo/.git/index"; new "$HOME_DIR/work/repo/sub/Cargo.toml"; sized "$HOME_DIR/work/repo/sub/target/x" 10 # repo in use
  sized "$c/no-manifest/target/x" 10                                                     # target/ without Cargo.toml
  new "$c/plain-venv/requirements-dev.txt"; sized "$c/plain-venv/venv/lib/x" 10          # no pyvenv.cfg: not a virtual environment
  new "$c/linked/Cargo.toml"; sized "$WORK/elsewhere/x" 10; ln -s "$WORK/elsewhere" "$c/linked/target"
  new "$c/web/node_modules/dep/Cargo.toml"; sized "$c/web/node_modules/dep/target/x" 10 # never inside node_modules
  new "$c/building/Cargo.toml"; sized "$c/building/target/x" 10                        # cargo works in it
  new "$c/open/setup.py"; new "$c/open/.venv/pyvenv.cfg"; sized "$c/open/.venv/lib/x.so" 10 # a file in it is open
  while IFS= read -r -d '' f; do touch -h -d "100 days ago" "$f"; done < <(find "$HOME_DIR" -print0)
  touch -d "10 days ago" "$c/fresh-lock/Cargo.lock"
  touch "$HOME_DIR/work/repo/.git/index"
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
  local b_rusty b_py b_pods
  b_rusty=$(du -sb "$rusty/target" | cut -f1) b_py=$(du -sb "$py/.venv" | cut -f1) b_pods=$(du -sb "$pods/Pods" | cut -f1)
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  mkdir -p "$WORK/buildbin"; cp "$(command -v sleep)" "$WORK/buildbin/cargo"; chmod 755 "$WORK/buildbin" "$WORK/buildbin/cargo"
  "${hold[@]}" sh -c 'cd "$1" && exec "$2" 60' _ "$c/building" "$WORK/buildbin/cargo" >/dev/null 2>&1 &
  pids+=($!)
  "${hold[@]}" sleep 60 <"$c/open/.venv/lib/x.so" >/dev/null 2>&1 &
  pids+=($!)
  sleep 0.3
  out=$(user_cm --json scan --only dev | grep '"id":"stale_build_dirs"' | python3 -c "$list")
  assert_eq "$out" "stale_build_dirs $((b_rusty + b_py + b_pods)) 3 projects idle for 90+ days False True False" \
    "three idle projects, not ticked"
  out=$(user_cm --json details stale_build_dirs | python3 -c "$list")
  enc=$(in_app "urlencode_path '$py'")
  assert_eq "$out" "$(in_app "urlencode_path '$rusty'") $b_rusty off ~/code/rusty — target/ · 100 days idle
$enc $b_py off ~/code/py — .venv/ · 100 days idle
$(in_app "urlencode_path '$pods'") $b_pods off ~/code/app/ios — Pods/ · 100 days idle" "one entry per project, biggest first"
  select_only stale_build_dirs # automatic cleaning leaves them alone even when ticked
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$py/.venv"
  out=$(user_cm --json clean stale_build_dirs --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of stale_build_dirs: ../etc"
  out=$(user_cm --json clean stale_build_dirs --entries "$enc" | python3 -c "$list")
  assert_eq "$out" "ok $b_py $(in_app "human $b_py") freed" "only the chosen project"
  assert_missing "$py/.venv"; assert_exists "$py/pyproject.toml"; assert_exists "$rusty/target"
  assert_exists "$HOME_DIR/.local/share/Trash/files/.venv/pyvenv.cfg"
  out=$(user_cm --json restore .venv | python3 -c "$list")
  assert_eq "$out" "ok 0 put back" "restore puts it back"
  assert_exists "$py/.venv/pyvenv.cfg"
  out=$(user_cm --json clean stale_build_dirs | python3 -c "$list")
  kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
  assert_contains "$out" "ok $((b_rusty + b_py + b_pods))"
  for p in "$rusty/target" "$py/.venv" "$pods/Pods"; do assert_missing "$p"; done
  for p in fresh-lock/target no-manifest/target plain-venv/venv linked/target web/node_modules/dep/target \
    building/target open/.venv; do assert_exists "$c/$p"; done
  assert_exists "$HOME_DIR/work/repo/sub/target"; assert_exists "$WORK/elsewhere/x"
}

lens_entries() { # reads `--json lens` → "kind count movable name" lines (sizes checked apart), then "done …"
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["kind"], e["count"], str(e["movable"]).lower(), e["path"].rsplit("/", 1)[1])
    elif e["event"] == "done": print("done", e["items"], e["count"], e["found"])
    else: print(e["event"], e.get("message", ""))'
}

test_json_lens() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out sizes outside big=$HOME_DIR/Big
  mkdir -p "$big/Deeper/Deepest" "$HOME_DIR/.config/app"
  truncate -s 3M "$big/Deeper/Deepest/a.bin"; truncate -s 1M "$big/b.bin"; truncate -s 2M "$HOME_DIR/movie.mkv"
  truncate -s 10K "$HOME_DIR/.config/app/settings"
  ln -s /usr "$HOME_DIR/usr link"
  touch "$HOME_DIR/bad"$'\xff'"name" # not UTF-8: counted, not listed
  outside=$(mktemp -d -p "$WORK" outside.XXXX); new "$outside/doc.txt"
  out=$(cm --json lens | lens_entries)
  assert_eq "$out" $'dir 4 true Big\nfile 1 true movie.mkv\ndir 3 false .config\nfile 1 false usr link\ndone 12 4 5' \
    "home listed biggest first; the protected .config and a link to /usr are view only"
  sizes=$(cm --json lens | python3 -c 'import sys, json
s = {e["path"].rsplit("/", 1)[1]: e["bytes"] for e in map(json.loads, sys.stdin) if e["event"] == "entry"}
print(4 << 20 <= s["Big"] < (4 << 20) + (1 << 20), s["movie.mkv"])')
  assert_eq "$sizes" "True 2097152" "sizes like du -b, a folder's include everything inside"
  out=$(cm --json lens --path "$big/Deeper/" | lens_entries)
  assert_eq "$out" $'dir 1 true Deepest\ndone 2 1 1' "--path drills into a folder"
  out=$(cm --json lens --path "$outside" | lens_entries)
  assert_eq "$out" $'file 1 false doc.txt\ndone 1 1 1' "outside your home folder: view only"
  out=$(cm --json lens --path "$HOME_DIR/nope" 2>&1); assert_contains "$out" "Not a folder"
  out=$(cm --json lens --min 1 2>&1); assert_contains "$out" "Unknown option for lens: --min"
  # Space Lens moves things to the Trash with --home-only: what it lists as view only is refused
  local tasks='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], e["trash"] or "-", e["info"])
    elif e["event"] == "done": print("done", e.get("moved", e.get("restored")), e["failed"])'
  local why="Only items inside your home folder can be moved to the Trash here"
  out=$(user_cm --json trash --home-only "$outside/doc.txt" "$big/../../${outside##*/}/doc.txt" "$HOME_DIR/.config" \
    "$HOME_DIR/usr link" "$big" | python3 -c "$tasks")
  assert_eq "$out" "fail - $why"$'\n'"fail - $why"$'\n'"fail - $why"$'\n'"fail - $why"$'\nok Big moved to the Trash\ndone 1 4' \
    "trash --home-only refuses what is outside home or protected"
  assert_exists "$outside/doc.txt"; assert_exists "$HOME_DIR/.config/app/settings"; assert_exists "$HOME_DIR/usr link"
  assert_missing "$big"
  out=$(user_cm --json restore Big | python3 -c "$tasks")
  assert_eq "$out" $'ok Big put back\ndone 1 0' "undo puts the folder back"
  assert_exists "$big/Deeper/Deepest/a.bin"
}

dupe_groups() { # reads `--json dupes` → "bytes name,name…" per group (newest first), then "done …"
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "group": print(e["bytes"], ",".join("/".join(f["path"].rsplit("/", 2)[-2:]) for f in e["files"]))
    elif e["event"] == "done": print("done", e["groups"], e["found"], e["files"], e["total_bytes"])
    elif e["event"] != "progress": print(e["event"], e.get("message", ""))'
}

test_json_duplicates() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out d=$HOME_DIR
  mkdir -p "$d/Photos" "$d/Backup" "$d/Downloads" "$d/.hidden" "$d/code/node_modules/x"
  head -c 2000000 /dev/urandom >"$d/Photos/beach.jpg"
  cp "$d/Photos/beach.jpg" "$d/Backup/beach.jpg"; cp "$d/Photos/beach.jpg" "$d/Downloads/beach (1).jpg"
  cp "$d/Photos/beach.jpg" "$d/.hidden/beach.jpg"; cp "$d/Photos/beach.jpg" "$d/code/node_modules/x/beach.jpg"
  touch -d '3 days ago' "$d/Photos/beach.jpg"; touch -d '2 days ago' "$d/Backup/beach.jpg"
  ln "$d/Backup/beach.jpg" "$d/Backup/beach-link.jpg" # a hard link is the same file: counted once
  # same size and same first 64 KB, different end: not duplicates
  head -c 1500000 /dev/zero >"$d/Photos/a.raw"; { head -c 1499999 /dev/zero; printf x; } >"$d/Photos/b.raw"
  # small duplicates (under --min) and a pair of 1.2 MB copies
  printf 'same\n' >"$d/Photos/n1.txt"; printf 'same\n' >"$d/Backup/n1.txt"; touch -d '1 day ago' "$d/Photos/n1.txt"
  head -c 1200000 /dev/urandom >"$d/Photos/clip.mp4"; cp "$d/Photos/clip.mp4" "$d/Downloads/clip.mp4"
  touch -d '1 day ago' "$d/Photos/clip.mp4"
  out=$(cm --json dupes | dupe_groups)
  out=${out//Backup\/beach-link.jpg/Backup\/beach.jpg} # either name of the hard link may be listed
  assert_eq "$out" $'2000000 Downloads/beach (1).jpg,Backup/beach.jpg,Photos/beach.jpg
1200000 Downloads/clip.mp4,Photos/clip.mp4
done 2 2 5 5200000' "groups biggest first, newest copy first; hard links, hidden folders, node_modules and different files left out"
  out=$(cm --json dupes --min 0 --path "$d/Photos" | dupe_groups)
  assert_eq "$out" "done 0 0 0 0" "one copy per folder: no group"
  out=$(cm --json dupes --min 1 | dupe_groups)
  assert_contains "$out" $'5 Backup/n1.txt,Photos/n1.txt'
  out=$(cm --json dupes --min 1M 2>&1); assert_contains "$out" "Invalid size: 1M"
  out=$(cm --json dupes --path "$d/nope" 2>&1); assert_contains "$out" "Not a folder"
}

startup_list() { # reads `--json startup` / `startup-set` → one line per event
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "unit":
        flags = "".join(c for c, k in (("s", "system"), ("h", "hidden"), ("t", "toggle"), ("r", "removable")) if e[k]) or "-"
        print(e["id"], "on" if e["enabled"] else "off", flags, e["name"])
    elif e["event"] == "task": print(e["state"], e["trash"] or "-", e["info"])
    elif e["event"] == "done": print("done", e.get("count", ""), str(e.get("systemd", "")).lower())
    else: print(e["event"], e.get("message", ""))'
}

test_json_startup_items() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out a=$HOME_DIR/.config/autostart u=$HOME_DIR/.config/systemd/user sys=$WORK/xdg-autostart.$RANDOM
  local CLEANMATE_SYSTEM_AUTOSTART=$sys
  mkdir -p "$a" "$u" "$HOME_DIR/.local/share/systemd/user" "$sys" "$HOME_DIR/.local/bin"
  printf '[Desktop Entry]\nType=Application\nName=Chat\nExec=chat --tray\nComment=Chat app\n' >"$a/chat.desktop"
  printf '[Desktop Entry]\nType=Application\nName=Old Tool\nExec=old\nX-GNOME-Autostart-enabled=false\n' >"$a/old.desktop"
  printf '[Desktop Entry]\nType=Application\nName=Backup Agent\nExec=backup-agent\n' >"$sys/backup.desktop"
  printf '[Desktop Entry]\nType=Application\nName=Keyring\nExec=keyring\nNoDisplay=true\n' >"$sys/keyring.desktop"
  printf '[Unit]\nDescription=Sync my files\n[Service]\nExecStart=%%h/bin/sync\n' >"$u/sync.service"
  printf '[Unit]\nDescription=Take notes\n' >"$HOME_DIR/.local/share/systemd/user/notes.timer"
  # a fake `systemctl --user`: unit states in ~/units, every call logged — the real one is never run
  printf '%s\n' 'sync.service enabled enabled' 'notes.timer disabled enabled' 'pipewire.service enabled enabled' \
    'muted.service disabled enabled' 'tpl@.service disabled enabled' 'static.service static -' >"$HOME_DIR/units"
  printf '%s\n' '#!/bin/sh' 'echo "$*" >>"$HOME/systemctl.log"' 'shift' \
    'case $1 in list-unit-files) cat "$HOME/units" ;; enable | disable) for u; do :; done; sed -i "s/^$u [a-z]*/$u ${1}d/" "$HOME/units" ;; esac' \
    >"$HOME_DIR/.local/bin/systemctl"
  chmod +x "$HOME_DIR/.local/bin/systemctl"
  if ((EUID == 0)); then
    out=$(cm --json startup 2>&1); assert_contains "$out" "run this as yourself, not as root"
  fi
  out=$(user_cm --json startup | startup_list)
  assert_eq "$out" "autostart:backup.desktop on st Backup Agent
autostart:chat.desktop on tr Chat
autostart:keyring.desktop on sht Keyring
autostart:old.desktop off tr Old Tool
systemd:sync.service on tr Sync my files
systemd:notes.timer off t Take notes
systemd:pipewire.service on sh pipewire.service
done 7 true" "autostart entries and systemd user units; the system's are view only"
  out=$(user_cm --json startup-set autostart:chat.desktop disable | startup_list)
  assert_eq "$out" $'ok - turned off\ndone  ' "turn an autostart entry off"
  assert_eq "$(grep -c '^Hidden=true$' "$a/chat.desktop")" 1 "Hidden=true written"
  user_cm --json startup-set autostart:chat.desktop enable >/dev/null
  assert_eq "$(grep -c '^Hidden=' "$a/chat.desktop")" 0 "turning it on removes the line"
  user_cm --json startup-set autostart:old.desktop enable >/dev/null
  assert_eq "$(grep -c 'Autostart-enabled' "$a/old.desktop")" 0 "X-GNOME-Autostart-enabled=false removed too"
  user_cm --json startup-set autostart:backup.desktop disable >/dev/null # a system entry: your copy overrides it
  assert_contains "$(cat "$a/backup.desktop")" "Hidden=true"
  assert_eq "$(grep -c Hidden "$sys/backup.desktop")" 0 "the system entry itself is untouched"
  out=$(user_cm --json startup-set autostart:backup.desktop remove | startup_list)
  assert_contains "$out" "fail - It comes with the system: turn it off instead"
  out=$(user_cm --json --dry-run startup-set autostart:chat.desktop remove | startup_list)
  assert_contains "$out" "ok - would be moved to the Trash"; assert_exists "$a/chat.desktop"
  out=$(user_cm --json startup-set autostart:chat.desktop remove | startup_list)
  assert_contains "$out" "ok chat.desktop moved to the Trash"; assert_missing "$a/chat.desktop"
  out=$(user_cm --json restore chat.desktop | startup_list)
  assert_contains "$out" "ok chat.desktop put back"; assert_exists "$a/chat.desktop"
  # systemd user units: only through (fake) systemctl --user, and only your own
  out=$(user_cm --json startup-set systemd:notes.timer enable | startup_list)
  assert_contains "$out" "ok - turned on"
  assert_contains "$(cat "$HOME_DIR/units")" "notes.timer enabled"
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" "--user enable --now notes.timer" # starts right away
  user_cm --json startup-set systemd:notes.timer disable >/dev/null
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" "--user disable --now notes.timer"
  assert_contains "$(cat "$HOME_DIR/units")" "notes.timer disabled"
  out=$(user_cm --json startup-set systemd:pipewire.service disable | startup_list)
  assert_contains "$out" "fail - It comes with the system: only shown here"
  out=$(user_cm --json startup-set systemd:notes.timer remove | startup_list)
  assert_contains "$out" "fail - Only units in ~/.config/systemd/user can be removed"
  out=$(user_cm --json startup-set systemd:sync.service remove | startup_list)
  assert_contains "$out" "ok sync.service moved to the Trash"; assert_missing "$u/sync.service"
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" $'--user disable --now sync.service\n--user daemon-reload'
  assert_eq "$(grep -c pipewire "$HOME_DIR/systemctl.log")" 0 "a system unit is never changed"
  out=$(user_cm --json startup-set 'systemd:-x.service' enable 2>&1); assert_contains "$out" "Not a service or timer"
  out=$(user_cm --json startup-set 'autostart:../x.desktop' enable 2>&1); assert_contains "$out" "Unknown startup item"
  out=$(user_cm --json startup-set autostart:chat.desktop delete 2>&1); assert_contains "$out" "Unknown action: delete"
  printf '#!/bin/sh\nexit 1\n' >"$HOME_DIR/.local/bin/systemctl" # no systemd user session: autostart entries only
  out=$(user_cm --json startup | startup_list | tail -n 1)
  assert_eq "$out" "done 4 false" "without systemctl --user"
}

settings_list() { # reads `--json settings` / `settings-set` → one line per event
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "setting":
        rng = " %d-%d/%d" % (e["min"], e["max"], e["default"]) if "min" in e else ""
        print(e["key"], e["value"], end=rng + "\n")
    elif e["event"] == "task": print(e["state"], e["id"], e["info"])
    elif e["event"] == "done": print("done", str(e.get("systemd", "")).lower(), str(e.get("packaged", "")).lower())
    else: print(e["event"], e.get("message", ""))'
}

test_json_settings() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out f=$HOME_DIR/.config/cleanmate/settings u=$HOME_DIR/.config/systemd/user
  mkdir -p "$HOME_DIR/.local/bin"
  printf 'journal_days=14\ntmp_days=999\ncache_days=045\nfoo=3\n' >"$f" # out of range → default; leading zero is decimal
  printf 'apt_cache=1\nthumbs=0\n' >"$HOME_DIR/.config/cleanmate/selection"
  # a fake `systemctl --user`: enabled units are files in ~/enabled, every call logged — the real one is never run
  printf '%s\n' '#!/bin/sh' 'echo "$*" >>"$HOME/systemctl.log"' 'shift; mkdir -p "$HOME/enabled"' \
    'case $1 in is-enabled) test -e "$HOME/enabled/$3" ;; enable) touch "$HOME/enabled/$3" ;; disable) rm -f "$HOME/enabled/$3" ;; esac' \
    >"$HOME_DIR/.local/bin/systemctl"
  chmod +x "$HOME_DIR/.local/bin/systemctl"
  if ((EUID == 0)); then
    out=$(cm --json settings 2>&1); assert_contains "$out" "run this as yourself, not as root"
  fi
  out=$(user_cm --json settings | settings_list)
  assert_eq "$out" "schedule off
update_check 1 0-1/1
low_disk_pct 10 0-50/10
journal_days 14 1-365/7
journal_mb 100 16-10000/100
log_max_mb 50 10-100000/50
app_log_days 3 1-365/3
tmp_days 10 1-365/10
cache_days 45 1-365/30
node_modules_days 90 7-3650/90
installer_days 30 7-3650/30
ai_history_days 30 1-3650/30
selections 2
done true false" "every setting with its range and default; bad values fall back to the default"
  # the desktop app changes a number → the terminal app (same file) uses it
  out=$(user_cm --json settings-set journal_days 30 | settings_list)
  assert_eq "$out" $'ok journal_days set to 30\njournal_days 30 1-365/7\ndone  ' "set a number"
  assert_contains "$(cat "$f")" $'foo=3\njournal_days=30\ntmp_days=999'
  assert_contains "$(user_cm --json items)" "Keeps the last 30 days"
  # …and the other way round: the terminal app's Settings writes the file the desktop app reads
  in_app 'load_settings; save_setting journal_mb 250'
  assert_contains "$(user_cm --json settings | settings_list)" "journal_mb 250 16-10000/100"
  assert_contains "$(cat "$f")" "journal_days=30"
  # wrong values are refused and change nothing
  cp "$f" "$WORK/settings.before"
  out=$(user_cm --json settings-set journal_days 0 2>&1); assert_contains "$out" "journal_days must be a number from 1 to 365"
  out=$(user_cm --json settings-set journal_days 12abc 2>&1); assert_contains "$out" "must be a number"
  out=$(user_cm --json settings-set update_check 2 2>&1); assert_contains "$out" "update_check must be a number from 0 to 1"
  out=$(user_cm --json settings-set foo 3 2>&1); assert_contains "$out" "Unknown setting: foo"
  out=$(user_cm --json settings-set schedule hourly 2>&1); assert_contains "$out" "schedule must be one of: off daily weekly monthly"
  out=$(user_cm --json settings-set selections 0 2>&1); assert_contains "$out" "selections can only be reset"
  out=$(user_cm --json settings-set journal_days 2>&1); assert_contains "$out" "Usage: --json settings-set KEY VALUE"
  user_cm --json settings-set journal_days 0 >/dev/null; assert_eq "$?" 2 "exit status of a refused value"
  out=$(user_cm --json --dry-run settings-set journal_days 60 | settings_list)
  assert_eq "$out" $'ok journal_days would be set to 60\njournal_days 30 1-365/7\ndone  ' "dry run"
  assert_eq "$(cat "$f")" "$(cat "$WORK/settings.before")" "nothing written"
  # automatic cleaning: the systemd user timer is written and enabled at once
  out=$(user_cm --json settings-set schedule weekly | settings_list)
  assert_contains "$out" "ok schedule Automatic cleaning: weekly"
  assert_contains "$out" "schedule weekly"
  assert_contains "$(cat "$u/cleanmate.timer")" "OnCalendar=weekly"
  assert_contains "$(cat "$u/cleanmate.service")" "--auto"
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" $'--user daemon-reload\n--user enable --now cleanmate.timer'
  assert_contains "$(user_cm --json settings | settings_list)" "schedule weekly"
  out=$(user_cm --json settings-set schedule off | settings_list)
  assert_contains "$out" "ok schedule Automatic cleaning turned off."
  assert_missing "$u/cleanmate.timer"; assert_missing "$u/cleanmate.service"
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" "--user disable --now cleanmate.timer"
  # remembered selections
  out=$(user_cm --json settings-set selections reset | settings_list)
  assert_eq "$out" $'ok selections forgotten\nselections 0\ndone  ' "forget remembered selections"
  assert_missing "$HOME_DIR/.config/cleanmate/selection"
  printf '#!/bin/sh\nexit 1\n' >"$HOME_DIR/.local/bin/systemctl" # no systemd user session
  out=$(user_cm --json settings-set schedule daily | settings_list)
  assert_contains "$out" "fail schedule Could not enable the systemd timer."
  assert_contains "$out" "schedule off"
}

app_fixtures() { # BIN — launchers, package stubs and home folders for gimp (apt), foo (apt) and Spotify (flatpak)
  local bin=$1 sys=$HOME_DIR/sys
  mkdir -p "$bin" "$sys"
  desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n' "$2" "$3" "${4:-}" >"$1"; }
  desk "$sys/gimp.desktop" "GNU Image Manipulation Program" "gimp-2.10 %U"
  desk "$sys/foo.desktop" "Foo" "foo"
  desk "$sys/busybox.desktop" "BusyBox" "busybox"
  desk "$sys/gnome-control-center.desktop" "Settings" "gnome-control-center"
  desk "$sys/com.spotify.Client.desktop" "Spotify" "flatpak run com.spotify.Client" "X-Flatpak=com.spotify.Client"
  cat >"$bin/dpkg" <<'EOS'
#!/bin/sh
[ "$1" = -S ] || exit 1; shift
for f; do n=${f##*/}; n=${n%.desktop}; case $n in gimp|foo|busybox|gnome-control-center) echo "$n: $f" ;; esac; done
EOS
  cat >"$bin/dpkg-query" <<'EOS'
#!/bin/sh
case "$*" in
  *Status-Abbrev*) printf 'ii  ubuntu-desktop-minimal\n' ;;
  *Installed-Size*) printf 'gimp\t20000\toptional\tno\nfoo\t100\toptional\tno\nbusybox\t900\trequired\tno\ngnome-control-center\t5000\toptional\tno\n' ;;
  *) for p; do case $p in -*) ;; libsystemd0) echo "libsystemd0 required " ;; *) echo "$p optional " ;; esac; done ;;
esac
EOS
  printf '#!/bin/sh\nprintf "ubuntu-desktop-minimal\\n  Depends: gnome-control-center\\n"\n' >"$bin/apt-cache"
  cat >"$bin/apt-get" <<'EOS'
#!/bin/sh
case "$*" in
  "-s purge gimp") printf 'Purg gimp [2.10]\nPurg gimp-data [2.10]\n' ;;
  "-s purge foo") printf 'Purg foo [1]\nPurg libsystemd0 [255]\n' ;;
  -s*) ;;
  *) echo "apt-get $*" >>"$HOME/removed.log" ;;
esac
EOS
  cat >"$bin/flatpak" <<'EOS'
#!/bin/sh
case $1 in list) printf 'com.spotify.Client\t123.0 MB\n' ;; uninstall) echo "flatpak $*" >>"$HOME/removed.log" ;; esac
EOS
  chmod +x "$bin"/*
  new "$HOME_DIR/.config/GIMP/2.10/gimprc"; new "$HOME_DIR/.var/app/com.spotify.Client/cache/x"
}

test_json_apps_and_uninstall() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/appjson out
  app_fixtures "$bin"
  local CLEANMATE_APP_DIRS="$HOME_DIR/.local/share/applications:$HOME_DIR/sys" BASE_PATH="$bin:$BASE_PATH"
  out=$(cm --json apps | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "app":
        print(e["id"], e["kind"], e["bytes"], e["desktop"], " ".join(f"{x['"'"'path'"'"']}={x['"'"'bytes'"'"'] > 0}" for x in e["leftovers"]))
    else: print(e["event"], e.get("hidden", ""))' | sed "s|$HOME_DIR/||g" | sort)
  assert_eq "$out" $'apt:foo apt 102400 foo \napt:gimp apt 20480000 gimp .config/GIMP=True\ndone 2\nflatpak:com.spotify.Client flatpak 123000000 com.spotify.Client .var/app/com.spotify.Client=True' \
    "apps listed with leftovers; parts of Ubuntu hidden"
  local ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "check": print("check", e["ok"], e["extra"], e["extra_text"], e["message"])
    elif e["event"] == "task" and e["state"] != "run": print(e["id"], e["state"], e["info"])
    elif e["event"] == "error": print("error", e["message"])
    elif e["event"] == "done" and "removed" in e: print("done", e["removed"], e["failed"])'
  out=$(cm --json uninstall --check apt:gimp flatpak:com.spotify.Client | python3 -c "$ev")
  assert_eq "$out" "check True 1 gimp-data " "check reports what else apt removes"
  out=$(cm --json uninstall --check apt:foo | python3 -c "$ev")
  assert_eq "$out" "check False 0  Not removed: libsystemd0 is marked as required by Ubuntu. Use apt yourself if you're sure." "check refuses"
  out=$(cm --json uninstall apt:foo | python3 -c "$ev")
  assert_contains "$out" "error Not removed: libsystemd0"
  out=$(cm --json uninstall apt:busybox | python3 -c "$ev"); assert_eq "$out" "error Not an app CleanMate can remove: apt:busybox" "part of Ubuntu refused"
  out=$(cm --json uninstall apt:gnome-control-center | python3 -c "$ev"); assert_contains "$out" "error Not an app CleanMate can remove"
  out=$(user_cm --json --dry-run uninstall apt:gimp flatpak:com.spotify.Client | python3 -c "$ev")
  assert_eq "$out" $'apt:gimp ok would be uninstalled\nflatpak:com.spotify.Client ok would be uninstalled\ndone 2 0' "dry run"
  assert_missing "$HOME_DIR/removed.log"
  out=$(user_cm --json uninstall flatpak:com.spotify.Client | python3 -c "$ev")
  assert_eq "$out" $'flatpak:com.spotify.Client ok uninstalled\ndone 1 0' "flatpak removed as you"
  assert_eq "$(cat "$HOME_DIR/removed.log")" "flatpak uninstall -y --noninteractive --delete-data com.spotify.Client" "flatpak command"
  assert_exists "$HOME_DIR/.var/app/com.spotify.Client" # leftovers only through trash, after the app is gone
  if ((EUID == 0)); then
    out=$(cm --json uninstall apt:gimp | python3 -c "$ev")
    assert_eq "$out" $'apt:gimp ok uninstalled\ndone 1 0' "apt removed as root"
    assert_contains "$(cat "$HOME_DIR/removed.log")" "apt-get purge -y gimp"
    out=$(cm --json uninstall flatpak:com.spotify.Client | python3 -c "$ev"); assert_contains "$out" "error Flatpak apps are removed as you"
  else
    out=$(cm --json uninstall apt:gimp | python3 -c "$ev"); assert_contains "$out" "apt:gimp fail" # no password: sudo -n fails
  fi
}

test_gui_selftest() {
  command -v gtk4-broadwayd >/dev/null || { SKIPPED="gtk4-broadwayd not installed (package libgtk-4-bin)"; return; }
  local py="" c
  for c in python3 /usr/bin/python3; do # a Python with GTK bindings (a virtualenv may come first)
    "$c" -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw; assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5)' 2>/dev/null &&
      { py=$c; break; }
  done
  [[ -n $py ]] || { SKIPPED="GTK 4 + libadwaita 1.5 not available"; return; }
  fresh_home
  local out srv lang display=$((50 + RANDOM % 40)) locales=(C.UTF-8)
  if command -v msgfmt >/dev/null; then # the Vietnamese translation too
    bash "$ROOT/po/compile.sh" "$WORK/locale" && locales+=(vi_VN.UTF-8)
  else
    echo "      (msgfmt not installed: GUI self-test in English only)"
  fi
  mkdir -p "$HOME_DIR/.cache/thumbnails/large"; echo x >"$HOME_DIR/.cache/thumbnails/large/a.png"
  new "$HOME_DIR/.cache/pip/p"; new "$HOME_DIR/.npm/_cacache/n"; new "$HOME_DIR/.cache/go-build/g" # two more items, so a group has several rows
  # Claude Code "running": its row is locked, in a group whose box covers the two others
  new "$HOME_DIR/.claude/cache/c"; new "$HOME_DIR/.cline/data/logs/l"; new "$HOME_DIR/.cache/kilo/k"
  running_stub "$WORK/guilock" claude
  local rt=$WORK/runtime-$display # the display's socket lives here; shared by server and app
  mkdir -p "$rt" && chmod 700 "$rt"
  XDG_RUNTIME_DIR=$rt gtk4-broadwayd ":$display" >/dev/null 2>&1 &
  srv=$!
  sleep 1
  for lang in "${locales[@]}"; do
    # a private, invisible display; dry run; the self-test never touches system items
    out=$(env -i HOME="$HOME_DIR" PATH="$WORK/guilock:$BASE_PATH" LANG="$lang" XDG_RUNTIME_DIR="$rt" \
      CLEANMATE_LOCALEDIR="$WORK/locale" GDK_BACKEND=broadway BROADWAY_DISPLAY=":$display" \
      timeout 120 "$py" "$ROOT/gui/cleanmate-gui" --engine "$SCRIPT" --dry-run --selftest 2>&1)
    ((VERBOSE)) && echo "      $lang:"
    ((VERBOSE)) && grep SELFTEST <<<"$out" | sed 's/^/      | /'
    assert_contains "$out" "SELFTEST done"
    [[ $out == *"SELFTEST FAIL"* ]] && { fail "GUI self-test reported a failure"; grep 'SELFTEST FAIL' <<<"$out" | sed 's/^/      | /'; }
    assert_contains "$out" "dry-run clean finished"
    assert_contains "$out" "group box selects the whole group"
    assert_contains "$out" "locked row “Claude Code — cache & logs” can't be ticked (claude running)"
    assert_contains "$out" "group boxes leave locked rows unticked"
    assert_contains "$out" "age filter keeps only the old file"
    assert_contains "$out" "dry run: the file stays"
    ((EUID == 0)) || assert_contains "$out" "Undo from the toast puts the file back where it was" # root: refused
    assert_contains "$out" "three folders deep, the path bar shows each"
    assert_contains "$out" "outside the home folder: view only"
    ((EUID == 0)) || assert_contains "$out" "Undo from the toast puts the folder back where it was"
    assert_contains "$out" "Select automatically keeps the oldest copy"
    assert_contains "$out" "ticking every copy shows a warning"
    ((EUID == 0)) || assert_contains "$out" "Undo from the toast puts the copies back in their group"
    ((EUID == 0)) || assert_contains "$out" "switching an app off writes Hidden=true"
    ((EUID == 0)) || assert_contains "$out" "Undo from the toast puts the startup entry back"
    assert_contains "$out" "apps listed, part of Ubuntu hidden"
    assert_contains "$out" "ticking an app ticks its leftover folder"
    assert_contains "$out" "dry run removes nothing"
    ((EUID == 0)) || assert_contains "$out" "Restore folders in the toast puts the app's folder back"
    ((EUID == 0)) || assert_contains "$out" "a changed number and switch are saved for the terminal app"
    ((EUID == 0)) || assert_contains "$out" "turning automatic cleaning on enables the weekly timer"
    assert_contains "$out" "unticking one: the item box is half-ticked and the size shows selected / total"
    ((EUID == 0)) || assert_contains "$out" "Clean removes only the ticked image"
    assert_contains "$out" "a missing tool locks the row with why"
    ((EUID == 0)) || assert_contains "$out" "Rebuild font cache runs as you; the log shows its output, then done"
    assert_contains "$out" "Update everything asks for the password once"
    assert_contains "$out" "the app opens on System Overview"
    assert_contains "$out" "a disk over 90 % full gets the warning colour"
    assert_contains "$out" "the page shows in under 300 ms once the engine answers"
    assert_contains "$out" "Refresh shows what was freed in 30 days"
    assert_exists "$HOME_DIR/.cache/thumbnails/large/a.png" # dry run: nothing deleted
    if [[ $lang == vi* ]]; then
      assert_contains "$out" "dry-run clean finished: Chạy thử: sẽ giải phóng"
      assert_contains "$out" "item names translated"
      ((VERBOSE)) && grep 'SELFTEST warn' <<<"$out" | sed 's/^/      | /'
    else
      assert_contains "$out" "item names stay in English"
    fi
  done
  kill "$srv" 2>/dev/null
}

test_deb_package() {
  command -v dpkg-deb >/dev/null || { SKIPPED="dpkg-deb not available"; return; }
  fresh_home
  local out=$WORK/dist x=$WORK/debroot deb contents msg
  OUT=$out bash "$ROOT/packaging/build-deb.sh" >/dev/null 2>&1 || { fail "build-deb.sh failed"; return; }
  deb=$(ls "$out"/cleanmate_*_all.deb 2>/dev/null)
  [[ -f $deb ]] && ok_ "built $(basename "$deb")" || { fail "no .deb produced"; return; }
  contents=$(dpkg-deb --contents "$deb")
  for f in ./usr/bin/cleanmate ./usr/bin/cm ./usr/share/cleanmate/gui/cleanmate-gui \
    ./usr/share/applications/com.homielab.CleanMate.desktop \
    ./usr/share/metainfo/com.homielab.CleanMate.metainfo.xml \
    ./usr/share/icons/hicolor/scalable/apps/com.homielab.CleanMate.svg \
    ./usr/share/polkit-1/actions/com.homielab.CleanMate.policy ./usr/share/doc/cleanmate/copyright; do
    assert_contains "$contents" "$f"
  done
  assert_eq "$(head -n 1 <<<"$contents" | cut -c1-10)" "drwxr-xr-x" "package root is 755"
  assert_eq "$(dpkg-deb --field "$deb" Breaks)" "clean-my-ubuntu (<< 2.0.0~)" "replaces the Clean My Ubuntu package"
  assert_eq "$(dpkg-deb --field "$deb" Version)" "$(cm --version | awk '{print $2}')" "package version = script VERSION"
  dpkg-deb -x "$deb" "$x"
  msg=$(env -i HOME="$HOME_DIR" PATH="$x/usr/bin:$BASE_PATH" LANG=C.UTF-8 cm --install 2>&1)
  assert_contains "$msg" "already installed as a package"
  msg=$(env -i HOME="$HOME_DIR" PATH="$x/usr/bin:$BASE_PATH" LANG=C.UTF-8 cm --update 2>&1)
  assert_contains "$msg" "sudo apt update"
  if command -v appstreamcli >/dev/null; then
    appstreamcli validate --no-net "$x/usr/share/metainfo/com.homielab.CleanMate.metainfo.xml" >/dev/null &&
      ok_ "metainfo valid" || fail "metainfo does not validate"
  fi
}

test_tui_smoke() {
  local out pylib
  # where pyte lives (it may be a --user install, which the throwaway HOME can't see)
  pylib=$(python3 -c 'import os, pyte; print(os.path.dirname(os.path.dirname(pyte.__file__)))' 2>/dev/null) ||
    { SKIPPED="python module pyte not installed"; return; }
  fresh_home
  if out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 PYTHONPATH="$pylib" \
    python3 "$ROOT/tests/tui_smoke.py" "$SCRIPT" 2>&1); then
    ((VERBOSE)) && printf '%s\n' "$out" | sed 's/^/      | /'
  else
    fail "TUI smoke test failed"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
  return 0
}

test_ai_models_are_separate_and_never_remembered() {
  fresh_home
  local hub=$HOME_DIR/.cache/huggingface/hub lms=$HOME_DIR/.lmstudio/models out
  old "$hub/models--org--small/blobs/a"; old "$hub/models--org--big/blobs/b"
  old "$hub/datasets--org--data/blobs/c"; old "$lms/pub/llm-7b/model.gguf"
  out=$(cm --scan --only models 2>&1)
  assert_contains "$out" "Hugging Face — org/small"
  assert_contains "$out" "Hugging Face — org/big"
  assert_contains "$out" "LM Studio — pub/llm-7b"
  [[ $out == *datasets* ]] && fail "datasets are not models" || ok_ "datasets not listed"
  local small lms7
  small=$(in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "Hugging Face — org/small" ]] && echo "$i"; done')
  lms7=$(in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "LM Studio — pub/llm-7b" ]] && echo "$i"; done')
  [[ $small == model_hf_org_small_[0-9]* ]] && ok_ "stable id $small" || fail "unexpected id: $small"
  # a remembered tick must not make an unattended clean delete a model
  echo "$small=1" >"$HOME_DIR/.config/cleanmate/selection"
  cm --clean --yes --only models >/dev/null 2>&1 </dev/null
  assert_exists "$hub/models--org--small"
  # the stale-cache cleaner leaves model caches alone too
  select_only app_cache
  cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_exists "$hub/models--org--small/blobs/a"
  # cleaning exactly that model (what the review screen and the desktop app do)
  out=$(user_cm --json clean "$small" 2>&1); assert_contains "$out" '"state":"ok"'
  assert_missing "$hub/models--org--small"
  assert_exists "$hub/models--org--big"
  assert_exists "$hub/datasets--org--data"
  out=$(user_cm --json clean "$lms7" 2>&1); assert_contains "$out" '"state":"ok"'
  assert_missing "$lms/pub/llm-7b"
  assert_exists "$lms/pub"
  in_app 'model_safe_path "$HOME/.cache/huggingface/hub"' && fail "the hub itself is not a model" || ok_ "hub refused"
  in_app 'model_safe_path "$HOME/.lmstudio/models/pub"' && fail "a publisher folder is not a model" || ok_ "publisher refused"
  # regression: a symlinked "publisher" (models/mine → ~) must never turn home folders into models
  new "$HOME_DIR/Documents/thesis.odt"
  ln -s "$HOME_DIR" "$lms/mine"
  out=$(cm --scan --only models 2>&1)
  [[ $out == *"mine/"* ]] && fail "home folders listed as models through a symlink" || ok_ "symlinked store ignored"
  in_app 'model_safe_path "$HOME/.lmstudio/models/mine/Documents"' && fail "symlinked path accepted" || ok_ "symlinked path refused"
  assert_exists "$HOME_DIR/Documents/thesis.odt"
}

test_ollama_models_use_ollama_rm() {
  fresh_home
  local log=$WORK/ollama.log out
  : >"$log"; chmod 666 "$log" # written by the clean, which runs as nobody under root
  mkdir -p "$WORK/ollamabin"
  cat >"$WORK/ollamabin/ollama" <<EOF
#!/bin/sh
echo "\$*" >>"$log"
case "\$1" in
  list) printf 'NAME              ID              SIZE      MODIFIED\nllama3.2:latest   a80c4f17acd5    2.0 GB    3 weeks ago\nqwen3:8b          500a1f067a9f    5.2 GB    2 days ago\n' ;;
esac
EOF
  chmod +x "$WORK/ollamabin/ollama"
  out=$(BASE_PATH="$WORK/ollamabin:$BASE_PATH" cm --scan --only models 2>&1)
  assert_contains "$out" "Ollama — llama3.2:latest"
  assert_contains "$out" "1.9 GB" # ollama says 2.0 GB in SI units; the app shows binary units
  local id
  id=$(BASE_PATH="$WORK/ollamabin:$BASE_PATH" in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "Ollama — llama3.2:latest" ]] && echo "$i"; done')
  out=$(BASE_PATH="$WORK/ollamabin:$BASE_PATH" user_cm --json clean "$id" 2>&1)
  assert_contains "$out" '"state":"ok"'
  assert_contains "$(<"$log")" "rm llama3.2:latest"
  [[ $(<"$log") == *"rm qwen3"* ]] && fail "only the chosen model is removed" || ok_ "other model kept"
}

test_conda_podman_and_steam_items() {
  fresh_home
  local log=$WORK/tools.log out sc=$HOME_DIR/.local/share/Steam/steamapps/shadercache
  : >"$log"
  mkdir -p "$HOME_DIR/miniconda3/bin" "$WORK/podmanbin"
  printf '#!/bin/sh\necho "conda $*" >>"%s"\n' "$log" >"$HOME_DIR/miniconda3/bin/conda"
  old "$HOME_DIR/miniconda3/pkgs/numpy-2.0.conda"
  cat >"$WORK/podmanbin/podman" <<EOF
#!/bin/sh
echo "podman \$*" >>"$log"
case "\$*" in
  info*) exit 0 ;;
  "images -f dangling=true --format {{.Size}}") printf '77.9 MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\n' ;;
esac
EOF
  chmod +x "$HOME_DIR/miniconda3/bin/conda" "$WORK/podmanbin/podman"
  # regression: a scan must not run podman for someone who never used it (it would create its folders)
  BASE_PATH="$WORK/podmanbin:$BASE_PATH" cm --scan --only dev >/dev/null 2>&1
  [[ $(<"$log") == *"podman info"* ]] && fail "podman asked although never used" || ok_ "unused podman left alone"
  assert_missing "$HOME_DIR/.local/share/containers"
  mkdir -p "$HOME_DIR/.local/share/containers" # podman is only asked once you've used it
  old "$sc/730/fozpipelinesv6/steamapprun_pipeline_cache"
  out=$(BASE_PATH="$WORK/podmanbin:$BASE_PATH" cm --scan --only dev,apps 2>&1)
  assert_contains "$out" "Conda package cache"
  assert_contains "$out" "1 package archive"
  assert_contains "$out" "1 dangling image, 2 stopped containers"
  assert_contains "$out" "Steam — shader cache"
  select_only conda app_steam_shaders
  BASE_PATH="$WORK/podmanbin:$BASE_PATH" cm --clean --yes --only dev,apps >/dev/null 2>&1 </dev/null
  assert_contains "$(<"$log")" "conda clean --tarballs --index-cache --logfiles -y"
  [[ $(<"$log") == *"system prune"* ]] && fail "podman must not be pruned unless selected" || ok_ "podman untouched"
  assert_missing "$sc/730"
  assert_exists "$sc"
  select_only podman
  BASE_PATH="$WORK/podmanbin:$BASE_PATH" cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_contains "$(<"$log")" "podman system prune -f"
}

test_uv_rustup_and_browser_test_caches() {
  fresh_home
  local out
  new "$HOME_DIR/.cache/uv/wheels/a.whl"
  new "$HOME_DIR/.rustup/downloads/x.partial"; new "$HOME_DIR/.rustup/tmp/t"
  new "$HOME_DIR/.rustup/toolchains/stable/bin/rustc"; new "$HOME_DIR/.rustup/settings.toml"
  new "$HOME_DIR/.cache/ms-playwright/chromium-1/chrome"; new "$HOME_DIR/.cache/puppeteer/p"; new "$HOME_DIR/.cache/Cypress/c"
  new "$HOME_DIR/uvcustom/u"; new "$WORK/outside/u"
  printf 'export UV_CACHE_DIR="$HOME/uvcustom"\n' >"$HOME_DIR/.bashrc"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "uv cache"
  assert_contains "$out" "rustup downloads"
  assert_contains "$out" "Playwright, Puppeteer"
  select_only uv_cache rustup_downloads
  cm --clean --yes --dry-run --only dev >/dev/null 2>&1 </dev/null
  assert_exists "$HOME_DIR/.cache/uv/wheels/a.whl"
  assert_exists "$HOME_DIR/.rustup/downloads/x.partial"
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.cache/uv/wheels/a.whl"
  assert_missing "$HOME_DIR/uvcustom/u"
  assert_missing "$HOME_DIR/.rustup/downloads/x.partial"
  assert_missing "$HOME_DIR/.rustup/tmp/t"
  assert_exists "$HOME_DIR/.rustup/toolchains/stable/bin/rustc"
  assert_exists "$HOME_DIR/.rustup/settings.toml"
  assert_exists "$HOME_DIR/.cache/ms-playwright/chromium-1/chrome" # not selected by default
  assert_exists "$HOME_DIR/.cache/puppeteer/p"
  # a path outside HOME in a startup file is ignored
  printf 'export UV_CACHE_DIR=%s/outside\nexport RUSTUP_HOME=/etc\n' "$WORK" >"$HOME_DIR/.bashrc"
  new "$HOME_DIR/.cache/uv/wheels/b.whl"
  select_only uv_cache rustup_downloads
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.cache/uv/wheels/b.whl"
  assert_exists "$WORK/outside/u"
  select_only browser_test_cache
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_missing "$HOME_DIR/.cache/ms-playwright/chromium-1/chrome"
  assert_missing "$HOME_DIR/.cache/Cypress/c"
}

test_ai_coding_tool_caches_keep_sessions_and_logins() {
  fresh_home
  local h=$HOME_DIR out
  new "$h/.config/Cursor/Cache/c"; new "$h/.config/Cursor/CachedData/c"; new "$h/.config/Cursor/Code Cache/c"
  new "$h/.config/Cursor/GPUCache/c"; new "$h/.config/Cursor/DawnCache/c"; new "$h/.config/Cursor/Service Worker/CacheStorage/c"; new "$h/.config/Cursor/logs/l"
  new "$h/.config/Cursor/User/globalStorage/state.vscdb"; new "$h/.config/Cursor/User/workspaceStorage/w/s"
  new "$h/.codeium/windsurf/database/idx"; new "$h/.codeium/windsurf/ws-browser-profile/Default/Cache/c"
  new "$h/.codeium/windsurf/ws-browser-profile/Default/Cookies"; new "$h/.codeium/windsurf/mcp_config.json"
  new "$h/.cache/opencode/models.json"; new "$h/.local/share/opencode/log/l"
  new "$h/.local/share/opencode/opencode.db"; new "$h/.local/share/opencode/auth.json"
  new "$h/.cline/data/logs/l"; new "$h/.cline/data/db/sessions.db"; new "$h/.cline/data/cache/user_input_history.jsonl"
  new "$h/.cache/kilo/models.json"; new "$h/.local/share/kilo/log/l"; new "$h/.local/share/kilo/auth.json"
  out=$(cm --scan --only ai 2>&1)
  assert_contains "$out" "Cursor — cache"
  assert_contains "$out" "Windsurf"
  assert_contains "$out" "Cline — logs"
  assert_contains "$out" "Kilo Code"
  cm --clean --yes --dry-run --only ai >/dev/null 2>&1 </dev/null
  assert_exists "$h/.config/Cursor/Cache/c"; assert_exists "$h/.cline/data/logs/l"
  cm --clean --yes --only ai >/dev/null 2>&1 </dev/null
  for f in .config/Cursor/Cache .config/Cursor/CachedData "'.config/Cursor/Code Cache'" .config/Cursor/GPUCache .config/Cursor/DawnCache "'.config/Cursor/Service Worker/CacheStorage'" .config/Cursor/logs \
    .codeium/windsurf/database/idx .codeium/windsurf/ws-browser-profile/Default/Cache .cache/opencode/models.json \
    .local/share/opencode/log/l .cline/data/logs/l .cache/kilo/models.json .local/share/kilo/log/l; do
    assert_missing "$h/$(eval echo "$f")"
  done
  assert_exists "$h/.config/Cursor/User/globalStorage/state.vscdb"; assert_exists "$h/.config/Cursor/User/workspaceStorage/w/s"
  assert_exists "$h/.codeium/windsurf/ws-browser-profile/Default/Cookies"; assert_exists "$h/.codeium/windsurf/mcp_config.json"
  assert_exists "$h/.local/share/opencode/opencode.db"; assert_exists "$h/.local/share/opencode/auth.json"
  assert_exists "$h/.cline/data/db/sessions.db"; assert_exists "$h/.cline/data/cache/user_input_history.jsonl"
  assert_exists "$h/.local/share/kilo/auth.json"
  # a running tool is skipped when unattended
  new "$h/.cline/data/logs/l2"; new "$h/.config/Cursor/logs/l2"; new "$h/.codeium/windsurf/database/l2"
  new "$h/.local/share/opencode/log/l2"; new "$h/.local/share/kilo/log/l2"
  printf '#!/bin/sh\ncase "$*" in *cline*|*cursor*|*windsurf*|*opencode*|*kilo*) exit 0;; esac\nexit 1\n' >"$WORK/stubs/pgrep"
  out=$(cm --clean --yes --only ai 2>&1 </dev/null)
  printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/pgrep"
  for t in Cline Cursor Windsurf opencode Kilo; do assert_contains "$out" "Skipping $t"; done
  for f in .cline/data/logs/l2 .config/Cursor/logs/l2 .codeium/windsurf/database/l2 .local/share/opencode/log/l2 .local/share/kilo/log/l2; do
    assert_exists "$h/$f"
  done
}

test_firebase_zcode_mimocode_keep_logins_and_sessions() {
  fresh_home
  local h=$HOME_DIR fb=$HOME_DIR/.cache/firebase out holder
  new "$fb/firebase-debug.log"; new "$fb/firebase-debug.1.log"; new "$fb/firebase-debug.2.log"
  new "$fb/emulators/cloud-firestore-emulator-v1.19.jar"; new "$fb/crashlytics/c"; new "$fb/extensions/e"
  new "$h/.config/configstore/firebase-tools.json"; new "$h/app/firebase-debug.log"
  new "$h/.zcode/v2/logs/2026-10-01.log"; new "$h/.zcode/cli/log/zcode-2026-10-01.jsonl"
  new "$h/.zcode/cli/rollout/r.jsonl"; new "$h/.zcode/credentials.json"; new "$h/.zcode/cli/zcode.db"
  new "$h/.cache/mimocode/models.json"; new "$h/.cache/mimocode/index.db"; new "$h/.local/share/mimocode/log/l"
  new "$h/.local/share/mimocode/mimocode.db"; new "$h/.local/share/mimocode/mimocode.db-wal"; new "$h/.local/share/mimocode/auth.json"
  sleep 60 3>>"$fb/firebase-debug.2.log" & # firebase mcp still writing this one
  holder=$!
  out=$(cm --scan --only dev,ai 2>&1)
  assert_contains "$out" "Firebase CLI logs"; assert_contains "$out" "Firebase emulators"
  assert_contains "$out" "ZCode — logs"; assert_contains "$out" "MiMoCode — cache & logs"
  select_only firebase_logs firebase_emulators ai_zcode_cache ai_mimocode_cache
  cm --clean --yes --dry-run --only dev,ai >/dev/null 2>&1 </dev/null
  assert_exists "$fb/firebase-debug.log"; assert_exists "$h/.zcode/v2/logs/2026-10-01.log"; assert_exists "$h/.cache/mimocode/models.json"
  cm --clean --yes --only dev,ai >/dev/null 2>&1 </dev/null
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  for f in "$fb/firebase-debug.log" "$fb/firebase-debug.1.log" "$fb/emulators/cloud-firestore-emulator-v1.19.jar" \
    "$h/.zcode/v2/logs/2026-10-01.log" "$h/.zcode/cli/log/zcode-2026-10-01.jsonl" \
    "$h/.cache/mimocode/models.json" "$h/.local/share/mimocode/log/l"; do
    assert_missing "$f"
  done
  for f in "$fb/firebase-debug.2.log" "$fb/crashlytics/c" "$fb/extensions/e" "$h/.config/configstore/firebase-tools.json" \
    "$h/app/firebase-debug.log" "$h/.zcode/cli/rollout/r.jsonl" "$h/.zcode/credentials.json" "$h/.zcode/cli/zcode.db" \
    "$h/.cache/mimocode/index.db" "$h/.local/share/mimocode/mimocode.db" "$h/.local/share/mimocode/mimocode.db-wal" \
    "$h/.local/share/mimocode/auth.json"; do
    assert_exists "$f"
  done
  # a running ZCode or MiMoCode is skipped when unattended
  new "$h/.zcode/v2/logs/l2"; new "$h/.local/share/mimocode/log/l2"
  printf '#!/bin/sh\ncase "$*" in *zcode*|*mimo*) exit 0;; esac\nexit 1\n' >"$WORK/stubs/pgrep"
  out=$(cm --clean --yes --only ai 2>&1 </dev/null)
  printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/pgrep"
  assert_contains "$out" "Skipping ZCode"; assert_contains "$out" "Skipping MiMoCode"
  assert_exists "$h/.zcode/v2/logs/l2"; assert_exists "$h/.local/share/mimocode/log/l2"
}

test_lasting_limits_and_space_reports() {
  fresh_home
  local out
  out=$(in_app 'JOURNALD_DROPIN=$HOME/j.conf; printf "[Journal]\nSystemMaxUse=150M\n" >"$JOURNALD_DROPIN"; journal_cap')
  assert_eq "$out" "150" "journal limit read back"
  out=$(in_app 'JOURNALD_DROPIN=$HOME/none.conf; journal_cap')
  assert_eq "$out" "" "no limit of ours"
  out=$(in_app 'DRY_RUN=1; JOURNAL_KEEP_MB=120; m_journal_cap; m_snap_retain')
  assert_contains "$out" "SystemMaxUse=%sM"
  assert_contains "$out" "snap set system refresh.retain=2"
  in_app 'hidden_space_lines >/dev/null' && ok_ "space report runs" || fail "hidden_space_lines failed"
  new "$HOME_DIR/VirtualBox VMs/win/win.vdi"; new "$HOME_DIR/vms/ubuntu.QCOW2"; new "$HOME_DIR/iso/ubuntu.img"
  out=$(in_app 'find "$HOME" -type f \( "${VM_DISK_NAMES[@]}" \) -printf "%f\n" | sort | paste -sd" " -')
  assert_eq "$out" "ubuntu.QCOW2 win.vdi" "VM disks found, other images not"
}

test_app_list_shows_real_apps_and_hides_ubuntu() {
  fresh_home
  local bin=$WORK/appbin sys=$HOME_DIR/sys out row
  mkdir -p "$bin" "$sys" "$HOME_DIR/.local/share/applications"
  desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%s\n' "$2" "$3" "${4:-}" >"$1"; }
  desk "$sys/gimp.desktop" "GNU Image Manipulation Program" "gimp-2.10 %U"
  desk "$sys/libreoffice-writer.desktop" "LibreOffice Writer" "libreoffice --writer %U"
  desk "$sys/libreoffice-calc.desktop" "LibreOffice Calc" "libreoffice --calc %U"
  desk "$sys/gnome-control-center.desktop" "Settings" "gnome-control-center"
  desk "$sys/busybox.desktop" "BusyBox" "busybox"
  desk "$sys/helper.desktop" "Helper" "helper" "NoDisplay=true"
  desk "$sys/hidden-by-user.desktop" "Hidden App" "hiddenapp"
  desk "$HOME_DIR/.local/share/applications/hidden-by-user.desktop" "Hidden App" "hiddenapp" "Hidden=true"
  desk "$HOME_DIR/.local/share/applications/my-appimage.desktop" "My AppImage" "/home/x/My.AppImage"
  desk "$sys/com.spotify.Client.desktop" "Spotify" "flatpak run com.spotify.Client" "X-Flatpak=com.spotify.Client"
  desk "$sys/vlc.desktop" "VLC media player" "vlc --started-from-file %U"
  desk "$sys/vlc-settings.desktop" "VLC settings" "vlc --settings" "NoDisplay=true"
  new "$HOME_DIR/.config/vlc/vlcrc"; new "$HOME_DIR/.config/run/state"
  cat >"$bin/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = -S ] || exit 1; shift
for f; do case $f in
  */gimp.desktop) echo "gimp: $f" ;; */libreoffice-writer.desktop) echo "libreoffice-writer: $f" ;;
  */libreoffice-calc.desktop) echo "libreoffice-calc: $f" ;; */gnome-control-center.desktop) echo "gnome-control-center:amd64: $f" ;;
  */busybox.desktop) echo "busybox: $f" ;; */hidden-by-user.desktop) echo "hiddenapp: $f" ;;
  */vlc.desktop) echo "vlc: $f" ;; */vlc-settings.desktop) echo "vlc: $f" ;;
esac; done
EOF
  cat >"$bin/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
  *Status-Abbrev*) printf 'ii  ubuntu-desktop-minimal\nii  gimp\n' ;;
  *) printf 'gimp\t20000\toptional\tno\nlibreoffice-writer\t30000\toptional\tno\nlibreoffice-calc\t30000\toptional\tno\ngnome-control-center\t5000\toptional\tno\nbusybox\t900\trequired\tno\nvlc\t8000\toptional\t\n' ;;
esac
EOF
  printf '#!/bin/sh\nprintf "ubuntu-desktop-minimal\\n  Depends: gnome-control-center\\n  Depends: <gdm3>\\n"\n' >"$bin/apt-cache"
  printf '#!/bin/sh\nprintf "com.spotify.Client\\t123.0 MB\\n"\n' >"$bin/flatpak"
  chmod +x "$bin"/*
  old "$HOME_DIR/.config/GIMP/2.10/gimprc"; touch -d "200 days ago" "$HOME_DIR/.config/GIMP/2.10" "$HOME_DIR/.config/GIMP"
  new "$HOME_DIR/.config/libreoffice/4/user/registrymodifications.xcu"
  new "$HOME_DIR/.var/app/com.spotify.Client/cache/x"
  mkdir -p "$HOME_DIR/.local/share/gnome-shell"
  printf '<?xml version="1.0"?>\n<application-state>\n  <context id="">\n    <application id="gimp.desktop" open-window-count="0" score="3" last-seen="%s"/>\n  </context>\n</application-state>\n' \
    "$(( $(date +%s) - 150 * 86400 ))" >"$HOME_DIR/.local/share/gnome-shell/application_state"
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'APP_DESKTOP_DIRS=("$HOME/.local/share/applications" "$HOME/sys"); app_inventory')
  assert_contains "$out" $'#hidden\t2'
  row=$(grep $'^apt\tgimp\t' <<<"$out")
  assert_contains "$row" "GNU Image Manipulation Program"
  assert_contains "$row" "$HOME_DIR/.config/GIMP"
  assert_eq "$(cut -f4 <<<"$row")" "20480000" "gimp package size"
  local seen; seen=$(cut -f6 <<<"$row")
  (( $(date +%s) - seen > 140 * 86400 && $(date +%s) - seen < 160 * 86400 )) && ok_ "last used from GNOME" || fail "gimp last used: $seen"
  row=$(grep $'^apt\tlibreoffice-writer\t' <<<"$out")
  [[ -n $row && $row != *libreoffice/4* && $row != *"/.config/libreoffice"* ]] && ok_ "shared LibreOffice folder not claimed" || fail "writer row: $row"
  row=$(grep $'^flatpak\tcom.spotify.Client\t' <<<"$out")
  assert_eq "$(cut -f4 <<<"$row")" "123000000" "flatpak size"
  assert_contains "$row" "$HOME_DIR/.var/app/com.spotify.Client"
  [[ $row == *"/.config/run"* ]] && fail "flatpak's 'run' must not match ~/.config/run" || ok_ "flatpak run not a name"
  row=$(grep $'^apt\tvlc\t' <<<"$out")
  [[ -n $row && $row != *"/.config/vlc"* ]] && ok_ "folder shared with a hidden launcher not offered" || fail "vlc row: $row"
  for w in gnome-control-center busybox Helper "Hidden App" "My AppImage"; do
    [[ $out == *"$w"* ]] && fail "should not be listed: $w" || ok_ "not listed: $w"
  done
  # filters
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'APP_DESKTOP_DIRS=("$HOME/.local/share/applications" "$HOME/sys"); SESSION_TMP=$HOME
    ui_busy() { wait "$2"; }; load_apps; A_FILTER=unused; apps_view; for i in "${A_VIEW[@]}"; do echo "${A_ID[i]}"; done')
  assert_eq "$out" "gimp" "only gimp is unused for 90+ days"
  assert_eq "$(in_app 'used_ago 0; echo; used_ago $((EPOCHSECONDS - 86400 * 400))')" $'—\n13 months ago' "used_ago"
}

test_uninstall_never_takes_ubuntu_with_it() {
  fresh_home
  local bin=$WORK/aptbin
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase "$*" in *gimp*) printf "Purg gimp [2.10]\\nPurg gimp-data [2.10]\\n" ;; *nautilus*) printf "Purg nautilus [46]\\nPurg gnome-shell [46]\\n" ;; *foo*) printf "Purg foo [1]\\nPurg libsystemd0 [255]\\n" ;; esac\n' >"$bin/apt-get"
  cat >"$bin/dpkg-query" <<'EOF'
#!/bin/sh
for p; do case $p in -*) ;; libsystemd0) echo "libsystemd0 required " ;; *) echo "$p optional " ;; esac; done
EOF
  chmod +x "$bin/apt-get" "$bin/dpkg-query"
  BASE_PATH="$bin:$BASE_PATH" in_app 'toast() { :; }; apt_check_removal gimp && echo "ok $APT_EXTRA_N $APT_EXTRA_TEXT"' | grep -q '^ok 1 gimp-data$' &&
    ok_ "extra package reported" || fail "gimp removal should report gimp-data"
  local out
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'toast() { echo "$1"; }; apt_check_removal nautilus && echo allowed')
  assert_contains "$out" "gnome-shell, which Ubuntu needs"
  [[ $out == *allowed* ]] && fail "gnome-shell must never be removed" || ok_ "removal refused"
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'toast() { echo "$1"; }; apt_check_removal foo && echo allowed')
  assert_contains "$out" "libsystemd0 is marked as required"
  [[ $out == *allowed* ]] && fail "required packages must never go as a side effect" || ok_ "required package kept"
}

test_update_preview_lists_pending_updates() {
  fresh_home
  local bin=$WORK/updbin out
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "Listing... Done\\nfirefox/noble-updates 131.0+build1 amd64 [upgradable from: 130.0]\\nlibc6/noble-security 2.39-0ubuntu8.4 amd64 [upgradable from: 2.39-0ubuntu8.3]\\n"\n' >"$bin/apt"
  printf '#!/bin/sh\nprintf "Name     Version  Rev   Size   Publisher  Notes\\nthunderbird  128.3  562  90MB  canonical  -\\n"\n' >"$bin/snap"
  printf '#!/bin/sh\nprintf "org.gimp.GIMP\\t2.10.38\\norg.gnome.Platform\\t\\n"\n' >"$bin/flatpak"
  chmod +x "$bin"/*
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'pending_updates')
  assert_eq "$(grep -c . <<<"$out")" "5" "five pending updates"
  assert_contains "$out" $'apt\tfirefox\t131.0+build1'
  assert_contains "$out" $'snap\tthunderbird\t128.3'
  assert_contains "$out" $'flatpak\torg.gimp.GIMP\t2.10.38'
  assert_contains "$out" $'flatpak\torg.gnome.Platform\tnew build'
}

test_json_maintenance() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/maintbin out ev list
  mkdir -p "$bin"
  printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$bin/sudo" # credentials cached
  printf '#!/bin/sh\necho "fstrim $*" >>"$HOME/ran.log"\nprintf "/boot/efi: 0 B (0 bytes) trimmed on /dev/sda1\\n\\n/: 2 GiB (2147483648 bytes) trimmed on /dev/sda2\\n"\n' >"$bin/fstrim"
  printf '#!/bin/sh\necho "fc-cache $*" >>"$HOME/ran.log"\nprintf "step 1\\rstep 2\\nfonts cached\\n"\n' >"$bin/fc-cache"
  printf '#!/bin/sh\necho "apt-get $*" >>"$HOME/ran.log"\n' >"$bin/apt-get"
  printf '#!/bin/sh\necho "flatpak $*" >>"$HOME/ran.log"\n' >"$bin/flatpak"
  chmod +x "$bin"/*
  local BASE_PATH="$bin:$BASE_PATH"
  list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "maint":
        print(e["id"], e["available"], e["root"], e["user"], e["toggle"], e["on"], e["value"] or "-", e["target"] or "-", e["reason"] or "-")
    else: print(e["event"])'
  out=$(in_app 'have() { case $1 in snap|updatedb) return 1 ;; esac; return 0; }; JOURNAL_KEEP_MB=100
    JOURNALD_DROPIN=$HOME/j.conf; printf "[Journal]\nSystemMaxUse=150M\n" >"$JOURNALD_DROPIN"; json_main maintenance' | python3 -c "$list")
  assert_eq "$out" "update True True True False False - - -
repair True True False False False - - -
flatpak_unused True False True False False - - -
fstrim True True False False False - - -
free_ram True True False False False - - -
fonts True False True False False - - -
locate False True False False False - - locate/plocate is not installed.
snap_versions False True False True False - 2 Snap is not installed.
journal_limit True True False True True 150 100 -
done" "nine items with what they need, their state and why one is locked"
  ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task" and e["state"] != "run": print(e["id"], e["state"], e["info"])
    elif e["event"] == "log": print("log", e["line"])
    elif e["event"] == "error": print("error", e["message"])
    elif e["event"] == "done": print("done", e["ok"], e["failed"], e["skipped"])'
  out=$(cm --json maintain fstrim | python3 -c "$ev")
  assert_eq "$out" "log /boot/efi: 0 B (0 bytes) trimmed on /dev/sda1
log /: 2 GiB (2147483648 bytes) trimmed on /dev/sda2
fstrim ok 2 filesystems trimmed
done 1 0 0" "TRIM streams its output, then the result"
  assert_contains "$(cat "$HOME_DIR/ran.log")" "fstrim -av"
  out=$(cm --json --dry-run maintain update | python3 -c "$ev")
  assert_contains "$out" "[dry-run]"
  assert_contains "$out" "apt-get update"
  assert_contains "$out" "apt_upgrade ok would run"
  if ((EUID == 0)); then
    [[ $out != *flatpak* ]] && ok_ "as root, update skips the flatpak step" || fail "flatpak update should run as you"
  else
    assert_contains "$out" "flatpak_update ok would run"
  fi
  assert_eq "$(grep -c apt-get "$HOME_DIR/ran.log")" "0" "dry run runs nothing"
  out=$(user_cm --json maintain update --user-steps | python3 -c "$ev")
  assert_eq "$out" $'flatpak_update ok done\ndone 1 0 0' "--user-steps runs only the steps that don't need root"
  out=$(user_cm --json maintain fonts | python3 -c "$ev")
  assert_eq "$out" $'log step 2\nlog fonts cached\nfc_cache ok done\ndone 1 0 0' "font cache rebuilt as you; a progress line keeps its last part"
  assert_contains "$(cat "$HOME_DIR/ran.log")" "fc-cache -f"
  if ((EUID == 0)); then
    out=$(cm --json maintain fonts | python3 -c "$ev"); assert_eq "$out" "error Rebuild font cache runs as you, not as root" "user-only item refused as root"
  fi
  out=$(cm --json maintain journal_limit | python3 -c "$ev"); assert_eq "$out" "error journal_limit needs on or off" "a limit needs on or off"
  out=$(cm --json maintain fstrim on | python3 -c "$ev"); assert_eq "$out" "error fstrim has no on or off" "only limits switch"
  out=$(cm --json maintain nope | python3 -c "$ev"); assert_eq "$out" "error Unknown maintenance item: nope" "unknown item"
  out=$(in_app 'have() { [[ $1 != updatedb ]]; }; json_main maintain locate' | python3 -c "$ev")
  assert_eq "$out" "error locate/plocate is not installed." "a missing tool is refused"
  out=$(in_app 'have() { return 0; }; DRY_RUN=1 JOURNAL_KEEP_MB=120 SESSION_TMP=$(mktemp -d); json_main maintain journal_limit on; rm -r "$SESSION_TMP"' | python3 -c "$ev")
  assert_contains "$out" "SystemMaxUse=%sM"
  assert_contains "$out" "journal_cap ok would run"
}

test_json_overview() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/ovbin out ev state=$HOME_DIR/.local/state/cleanmate
  mkdir -p "$bin"
  cat >"$bin/df" <<'STUB'
#!/bin/sh
case "$*" in
  *target*) printf 'Mounted on Size Used Avail Type Filesystem\n/ 100000000000 95000000000 5000000000 ext4 /dev/sda2\n/boot/efi 1000000000 100000000 900000000 vfat /dev/sda1\n/empty 0 0 0 ext4 /dev/loop9\n' ;;
  *) printf 'Size Avail\n100000000000 5000000000\n' ;;
esac
STUB
  chmod +x "$bin/df"
  local BASE_PATH="$bin:$BASE_PATH"
  ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "system": print("system", bool(e["kernel"]), e["threads"] > 0, e["uptime"] >= 0, isinstance(e["apt"], (int, type(None))))
    elif e["event"] == "disk": print("disk", e["mount"], e["fstype"], e["device"], e["size"], e["used"], e["avail"])
    elif e["event"] == "memory": print("memory", e["ram_total"] > 0, e["ram_used"] + e["ram_avail"] == e["ram_total"], e["swap_used"] <= e["swap_total"])
    elif e["event"] == "freed": print("freed", e["bytes"], e["cleanups"], e["lifetime"], e["runs"], e["last_bytes"], e["since"] > 0)
    else: print(e["event"])'
  out=$(cm --json overview | python3 -c "$ev")
  assert_eq "$out" "system True True True True
disk / ext4 /dev/sda2 100000000000 95000000000 5000000000
disk /boot/efi vfat /dev/sda1 1000000000 100000000 900000000
memory True True True
done" "system, real filesystems from df, memory; no freed group before the first cleanup"
  mkdir -p "$state"
  printf '%s\t5000\n%s\t1000\n%s\tjunk\n' "$(($(date +%s) - 40 * 86400))" "$(($(date +%s) - 5 * 86400))" "x" >"$state/cleanups.tsv"
  printf 'lifetime=6000\nruns=2\nlast_time=%s\nlast_freed=1000\n' "$(($(date +%s) - 5 * 86400))" >"$state/stats"
  out=$(cm --json overview | python3 -c "$ev" | grep freed)
  assert_eq "$out" "freed 1000 1 6000 2 1000 True" "freed in 30 days counts only the recent cleanup"
  out=$(in_app 'load_kv "$STATS_FILE" STATS "^[0-9]+$"; record_cleanup 2048; tail -n 1 "$CLEANUP_HISTORY"')
  assert_contains "$out" $'\t2048'
  out=$(cm --json overview | python3 -c "$ev" | grep freed)
  assert_eq "$out" "freed 3048 2 8048 3 2048 True" "a cleanup is added to the history"
}

test_extract_items_for_translation() {
  command -v msgcat >/dev/null && command -v python3 >/dev/null || { SKIPPED="needs gettext and python3"; return; }
  local d=$WORK/potest out
  mkdir -p "$d/po"
  cp "$ROOT/po/extract-items.sh" "$d/po/" && cp "$ROOT/po/cleanmate.pot" "$d/po/"
  sed 's/^JSON=0$/reg test_new_item user "Test item 42" 0 "Kept for 9 days, at most 3 MB."\nJSON=0/' "$SCRIPT" >"$d/cleanmate.sh"
  out=$(bash "$d/po/extract-items.sh" 2>&1) || fail "extract-items.sh failed: $out"
  out=$(grep -B2 -A1 'Test item' "$d/po/items.pot")
  assert_contains "$out" "#. test_new_item label"
  assert_contains "$out" "#, python-brace-format"
  assert_contains "$out" 'msgid "Test item {0}"'
  assert_contains "$(cat "$d/po/items.pot")" 'msgid "Kept for {0} days, at most {1} MB."'
  assert_contains "$(cat "$d/po/cleanmate.pot")" 'msgid "Test item {0}"'
  assert_contains "$(cat "$d/po/cleanmate.pot")" 'msgid "Move to Trash"' # the app's own strings stay
}

# ── runner ───────────────────────────────────────────────────────────────────

real_dirs() { # the real user's app folders and Trash — tests must never touch them
  find "$HOME/.config/cleanmate" "${XDG_STATE_HOME:-$HOME/.local/state}/cleanmate" \
    "$HOME/.config/clean-my-ubuntu" "${XDG_STATE_HOME:-$HOME/.local/state}/clean-my-ubuntu" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/Trash" \
    -printf '%p %s %T@\n' 2>/dev/null | sort
}
REAL_BEFORE=$(real_dirs)

pass=0 failed=0 skipped=0
printf 'CleanMate tests — %s\n\n' "$(bash "$SCRIPT" --version)"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  [[ -n $FILTER && $t != *"$FILTER"* ]] && continue
  result=$(
    FAILED="" SKIPPED=""
    "$t"
    if [[ -n $SKIPPED ]]; then echo "@@skip $SKIPPED"
    elif [[ -n $FAILED ]]; then echo "@@fail"
    else echo "@@pass"; fi
  )
  status=$(tail -n 1 <<<"$result")
  name=${t#test_}; name=${name//_/ }
  case $status in
    @@pass) printf '  %s✔%s %s\n' "$G" "$N" "$name"; ((++pass)) ;;
    @@skip*) printf '  %s–%s %s %s(skipped: %s)%s\n' "$Y" "$N" "$name" "$D" "${status#@@skip }" "$N"; ((++skipped)) ;;
    *) printf '  %s✘%s %s\n' "$R" "$N" "$name"; ((++failed)) ;;
  esac
  sed '$d' <<<"$result" | grep -v '^$'
done
if [[ $(real_dirs) != "$REAL_BEFORE" ]]; then
  printf '  %s✘ the tests changed your real ~/.config or ~/.local/state cleanmate folder%s\n' "$R" "$N"
  diff <(printf '%s\n' "$REAL_BEFORE") <(real_dirs) | sed 's/^/      | /'
  ((++failed))
fi
printf '\n  %d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
((failed == 0))
