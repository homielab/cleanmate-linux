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
# On any exit, also kill what the tests left running (a test's http.server, a
# file holder): background jobs are started in per-test subshells and would
# otherwise outlive an interrupted run with parent pid 1.
kill_tree() { local c; for c in $(command pgrep -P "$1"); do kill_tree "$c"; kill "$c" 2>/dev/null; done; }
trap 'kill_tree $$; rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
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

tbytes() { # PATH… → bytes of everything inside, folders counted 0 (du -b gives folders a size that depends on the file system)
  find "$@" -not -type d -printf '%s\n' | awk '{ t += $1 } END { printf "%.0f\n", t }'
}

path_without() { # NAME… → a PATH like BASE_PATH where none of the commands exist (CI images ship node, go, …)
  local dir name hit shim out=() n=0
  while IFS= read -r dir; do
    hit=0
    for name in "$@"; do [[ -e $dir/$name ]] && hit=1; done
    if ((hit)); then
      shim=$WORK/pathshim.$((n++)); mkdir -p "$shim"
      for f in "$dir"/*; do
        [[ -e $f ]] || continue
        name=${f##*/}; case " $* " in *" $name "*) continue ;; esac
        ln -s "$f" "$shim/$name"
      done
      dir=$shim
    fi
    out+=("$dir")
  done < <(tr ':' '\n' <<<"$BASE_PATH")
  (IFS=:; printf '%s' "${out[*]}")
}

cm() { # run the app non-interactively inside the fake home (in English unless TEST_LANG is set)
  "${AS_USER[@]}" env -i HOME="$HOME_DIR" PATH="$HOME_DIR/.local/bin:$BASE_PATH" LANG="${TEST_LANG:-C.UTF-8}" TERM=dumb \
    CLEANMATE_NO_UPDATE_CHECK=1 ${CLEANMATE_UPDATE_URL:+CLEANMATE_UPDATE_URL=$CLEANMATE_UPDATE_URL} \
    ${CLEANMATE_APP_DIRS:+CLEANMATE_APP_DIRS=$CLEANMATE_APP_DIRS} \
    ${CLEANMATE_SYSTEM_AUTOSTART:+CLEANMATE_SYSTEM_AUTOSTART=$CLEANMATE_SYSTEM_AUTOSTART} \
    ${CLEANMATE_VOLUME_ROOTS:+CLEANMATE_VOLUME_ROOTS=$CLEANMATE_VOLUME_ROOTS} \
    ${CLEANMATE_MOUNTS:+CLEANMATE_MOUNTS=$CLEANMATE_MOUNTS} \
    ${CLEANMATE_SYSROOT:+CLEANMATE_SYSROOT=$CLEANMATE_SYSROOT} \
    ${CLEANMATE_PROC:+CLEANMATE_PROC=$CLEANMATE_PROC} bash "$SCRIPT" "$@"
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
  env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG="${TEST_LANG:-C.UTF-8}" bash -c "source \"\$1\"; $1" _ "$SCRIPT"
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
  v=$(cm --version | head -n 1)
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
    else theirs=$(LC_ALL=C numfmt --to=iec --round=nearest --suffix=B --format='%.1f' "$b" | sed 's/\([0-9]\)\([KMGTP]\)/\1 \2/'); fi
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

running_stub() { # DIR NAME… — a pgrep that reports these programs as running (the pattern is a whole-name ERE)
  local d=$1; shift
  mkdir -p "$d"
  { echo '#!/bin/sh'
    echo 'for a; do case $a in -*) continue ;; esac'
    printf '  for n in'; printf ' "%s"' "$@"; echo '; do'
    echo '    printf "%s\n" "$n" | grep -qEix -- "$a" && { echo "4242 $n"; exit 0; }'
    echo '  done'
    echo 'done; exit 1'; } >"$d/pgrep"
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

# PackageKit's cache (GNOME Software, Software Updater): the contents of downloads/ and metadata/
# go, the folders and anything else stay; skipped while PackageKit or its apps run.
test_packagekit_cache() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local r=$WORK/pkroot pk out bin=$WORK/pkbin
  pk=$r/var/cache/PackageKit
  mkdir -p "$pk/downloads/abc" "$pk/metadata" "$pk/other"
  head -c 3000 /dev/zero >"$pk/downloads/abc/foo.deb"
  head -c 1000 /dev/zero >"$pk/metadata/lists.xml"
  echo keep >"$pk/other/state"
  local CLEANMATE_SYSROOT=$r
  out=$(cm --json scan | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e.get("id") == "packagekit_cache" and e["event"] == "item": print(e["status"], e["bytes"] >= 4000, repr(e["locked"]))')
  assert_eq "$out" "found True ''" "both folders counted"
  assert_contains "$(cm --json items)" '"id":"packagekit_cache"'
  running_stub "$bin" packagekitd
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json clean packagekit_cache 2>&1)
  assert_contains "$out" '"state":"skip"'
  assert_exists "$pk/downloads/abc/foo.deb"
  if ((EUID != 0)); then rm -r "$r" "$bin"; return; fi # cleaning a system item needs root
  cm --json clean packagekit_cache >/dev/null 2>&1
  assert_missing "$pk/downloads/abc"
  assert_missing "$pk/metadata/lists.xml"
  assert_exists "$pk/downloads"
  assert_exists "$pk/metadata"
  assert_exists "$pk/other/state"
  rm -r "$r" "$bin"
}

# The agent skill: valid frontmatter, and every cm flag and --json command its examples use exists.
test_agent_skill_matches_cli() {
  fresh_home
  local f=$ROOT/skills/cleanmate/SKILL.md help flag cmd out
  assert_exists "$f"; assert_exists "$ROOT/skills/cleanmate/reference.md"
  assert_contains "$(head -n 1 "$f")" "---"
  assert_contains "$(sed -n 2p "$f")" "name: cleanmate"
  assert_contains "$(sed -n 3p "$f")" "description: "
  help=$(bash "$SCRIPT" --help)
  for flag in $(grep -ho 'cm \(--[a-z]* \)*--[a-z-]*' "$f" "$ROOT/skills/cleanmate/reference.md" | grep -o -- '--[a-z-]*' | sort -u); do
    [[ $flag == --json || $flag == --help ]] && continue
    [[ $help == *"$flag"* ]] || { FAILED=1; echo "skill uses $flag, not in --help"; }
  done
  for cmd in $(grep -ho 'cm --json \(--dry-run \)\?[a-z]*' "$f" | awk '{print $NF}' | sort -u); do
    [[ $help == *"$cmd"* ]] || { FAILED=1; echo "skill uses --json $cmd, not in --help"; }
  done
  out=$(bash "$SCRIPT" --json scan --only nonsense 2>&1); assert_contains "$out" "Unknown category"
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

# pnpm and Bun hard-link node_modules files to their store: only what deleting frees is counted
test_hard_linked_store_files_not_counted() {
  fresh_home
  local h=$HOME_DIR p=$HOME_DIR/code/web r=$HOME_DIR/code/rs out
  sized "$h/.local/share/pnpm/store/v3/files/ab/big" 100000
  mkdir -p "$p/node_modules/.pnpm/lib" "$r/target/debug"
  ln "$h/.local/share/pnpm/store/v3/files/ab/big" "$p/node_modules/.pnpm/lib/index.js"
  sized "$p/node_modules/own.js" 3000
  sized "$p/node_modules/a.js" 2000; ln "$p/node_modules/a.js" "$p/node_modules/b.js" # both links inside: once
  new "$p/package.json"; new "$p/pnpm-lock.yaml"
  ln "$h/.local/share/pnpm/store/v3/files/ab/big" "$r/target/debug/dep"; sized "$r/target/debug/app" 4000
  new "$r/Cargo.toml"
  touch -d '200 days ago' "$p"/* "$p" "$r"/* "$r"
  out=$(in_app 'find_stale_node_modules' | cut -f1)
  assert_eq "$out" "5000" "node_modules: the store's file left out, a link pair inside counted once"
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "4000" "target/: the store's file left out"
}

# sizes of project folders are measured in parallel and cached between scans, but never trusted once
# the folder changed (two levels down) or the entry is a week old
test_project_sizes_cached() {
  fresh_home
  local p=$HOME_DIR/code/web r=$HOME_DIR/code/rs c=$HOME_DIR/.cache/cleanmate out i
  for i in 1 2 3 4 5 6; do
    sized "$HOME_DIR/code/p$i/node_modules/x/i.js" "$((i * 100))"; new "$HOME_DIR/code/p$i/package.json"; new "$HOME_DIR/code/p$i/yarn.lock"
  done
  sized "$p/node_modules/a/b/x.js" 3000; new "$p/package.json"; new "$p/package-lock.json"
  sized "$r/target/debug/app" 4000; new "$r/Cargo.toml"
  touch -d '200 days ago' "$HOME_DIR"/code/*/* "$HOME_DIR"/code/*
  out=$(in_app 'find_stale_node_modules' | sort -t $'\t' -k2,2)
  assert_eq "$out" "$(for i in 1 2 3 4 5 6; do printf '%s\t%s\n' "$((i * 100))" "$HOME_DIR/code/p$i/node_modules"; done; printf '3000\t%s' "$p/node_modules")" \
    "node_modules: each project with its own size"
  assert_eq "$(wc -l <"$c/sizes-node_modules.tsv")" "7" "node_modules: one cached size per folder"
  sed -i "s|\t3000\t$p/node_modules\$|\t999\t$p/node_modules|" "$c/sizes-node_modules.tsv"
  out=$(in_app 'find_stale_node_modules' | grep -F "$p/")
  assert_eq "${out%%$'\t'*}" "999" "node_modules: an unchanged folder's size comes from the cache"
  sized "$p/node_modules/b/y.js" 1000
  out=$(in_app 'find_stale_node_modules' | grep -F "$p/")
  assert_eq "${out%%$'\t'*}" "4000" "node_modules: a package added, measured again"
  sized "$p/node_modules/a/b/x.js" 5000 # edited in place three levels down: the signature looks the same
  sed -i "s|^\([^\t]*\)\t[0-9]*\t4000\t|\1\t$(($(date +%s) - 8 * 86400))\t4000\t|" "$c/sizes-node_modules.tsv"
  out=$(in_app 'find_stale_node_modules' | grep -F "$p/")
  assert_eq "${out%%$'\t'*}" "6000" "node_modules: a size cached over a week ago, measured again"
  sed -i "s|^[^\t]*\t\([0-9]*\t6000\t\)|0.0.0.0.0.0\t\1|" "$c/sizes-node_modules.tsv"
  sized "$p/node_modules/a/b/x.js" 2000
  out=$(in_app 'find_stale_node_modules' | grep -F "$p/")
  assert_eq "${out%%$'\t'*}" "3000" "node_modules: a cached size of another state of the folder, measured again"
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "4000" "target/: measured"
  sed -i "s|\t4000\t$r/target\$|\t1\t$r/target|" "$c/sizes-stale_build_dirs.tsv"
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "1" "target/: an unchanged folder's size comes from the cache"
  sized "$r/target/new" 500
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "4500" "target/: a file added, measured again"
  rm -r "$r/target"
  in_app 'stale_build_dirs'
  assert_missing "$c/sizes-stale_build_dirs.tsv"
}

# a cached size is measured again when something changes up to three levels down, or when CleanMate
# moves something inside to the Trash or back — at the next scan, not a week later
test_project_sizes_see_deep_changes() {
  fresh_home
  local p=$HOME_DIR/code/web r=$HOME_DIR/code/rs c=$HOME_DIR/.cache/cleanmate out
  sized "$p/node_modules/a/lib/big.bin" 5000; sized "$p/node_modules/a/index.js" 100
  new "$p/package.json"; new "$p/package-lock.json"
  sized "$r/target/debug/deps/x/big.rlib" 6000; sized "$r/target/debug/app" 4000; new "$r/Cargo.toml"
  find "$HOME_DIR/code" -exec touch -h -d '200 days ago' {} +
  out=$(in_app 'find_stale_node_modules' | cut -f1)
  assert_eq "$out" "5100" "node_modules: measured"
  rm "$p/node_modules/a/lib/big.bin"
  out=$(in_app 'find_stale_node_modules' | cut -f1)
  assert_eq "$out" "100" "node_modules: a file removed three levels down, measured again"
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "10000" "target/: measured"
  out=$(user_cm --json trash "$r/target/debug/deps/x/big.rlib")
  assert_contains "$out" '"state":"ok"'
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "4000" "target/: a file four levels down moved to the Trash by CleanMate, measured again"
  user_cm --json restore big.rlib >/dev/null
  assert_exists "$r/target/debug/deps/x/big.rlib"
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "10000" "target/: the file put back, measured again"
  assert_missing "$c/sizes-stale_build_dirs.forget"
  # cleaned as an entry, then Undo: the size cached before is never shown again
  sed -i "s|\t10000\t$r/target\$|\t1\t$r/target|" "$c/sizes-stale_build_dirs.tsv"
  user_cm --json clean stale_build_dirs --entries "$(in_app "urlencode_path '$r'")" >/dev/null
  assert_missing "$r/target"
  user_cm --json restore target >/dev/null
  assert_exists "$r/target/debug/app"
  out=$(in_app 'stale_build_dirs; echo "${SB_BYTES[*]}"')
  assert_eq "$out" "10000" "target/: cleaned and put back, measured again"
  out=$(user_cm --json --dry-run trash "$r/target/debug/app")
  assert_missing "$c/sizes-stale_build_dirs.forget"
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

# Browser privacy: history, downloads and cookies go; bookmarks, passwords and
# the rest of the profile stay. Firefox keeps its files (bookmarks live in
# places.sqlite), Chromium loses only its History and Cookies files.
test_browser_privacy() {
  command -v sqlite3 >/dev/null || { SKIPPED="needs sqlite3"; return; }
  command -v python3 >/dev/null || { SKIPPED="needs python3"; return; }
  fresh_home
  local ff=$HOME_DIR/.mozilla/firefox/abcd.default-release cr=$HOME_DIR/.config/chromium f out want items
  local bin=$WORK/browserbin
  mkdir -p "$ff" "$cr/Default/Network" "$cr/Profile 1"
  sqlite3 "$ff/places.sqlite" "PRAGMA journal_mode=WAL;
    CREATE TABLE moz_origins (id INTEGER PRIMARY KEY, prefix TEXT, host TEXT, frecency INTEGER);
    CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER DEFAULT 0,
      last_visit_date INTEGER, origin_id INTEGER);
    CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER,
      visit_date INTEGER, visit_type INTEGER);
    CREATE TABLE moz_inputhistory (place_id INTEGER, input TEXT, use_count INTEGER);
    CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, title TEXT);
    CREATE TABLE moz_keywords (id INTEGER PRIMARY KEY, keyword TEXT, place_id INTEGER);
    CREATE TABLE moz_anno_attributes (id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE moz_annos (id INTEGER PRIMARY KEY, place_id INTEGER, anno_attribute_id INTEGER, content TEXT);
    INSERT INTO moz_origins VALUES (1, 'https://', 'example.org', 1), (2, 'https://', 'secret.example', 1);
    INSERT INTO moz_places VALUES (1, 'https://example.org/', 'Example', 3, 1700000000000000, 1),
      (2, 'https://secret.example/a', 'Secret', 1, 1700000000000000, 2),
      (3, 'https://secret.example/file.zip', '', 1, 1700000000000000, 2);
    INSERT INTO moz_historyvisits VALUES (1, 0, 1, 1700000000000000, 1), (2, 0, 2, 1700000000000000, 1),
      (3, 0, 3, 1700000000000000, 7);
    INSERT INTO moz_inputhistory VALUES (2, 'sec', 1);
    INSERT INTO moz_bookmarks VALUES (1, 1, 1, 0, 'Example');
    INSERT INTO moz_anno_attributes VALUES (1, 'downloads/destinationFileURI');
    INSERT INTO moz_annos VALUES (1, 3, 1, 'file:///tmp/file.zip');" >/dev/null
  sqlite3 "$ff/cookies.sqlite" "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, host TEXT, name TEXT, value TEXT);
    INSERT INTO moz_cookies VALUES (1, '.secret.example', 'sid', 'x'), (2, '.example.org', 'sid', 'y');"
  printf '{}\n' >"$ff/prefs.js"
  sqlite3 "$cr/Default/History" "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT);
    CREATE TABLE downloads (id INTEGER PRIMARY KEY, target_path TEXT);
    INSERT INTO urls VALUES (1, 'https://secret.example/'), (2, 'https://example.org/');
    INSERT INTO downloads VALUES (1, '/tmp/file.zip');"
  : >"$cr/Default/History-journal" # Chromium truncates its journals
  printf 'links\n' >"$cr/Default/Visited Links"
  sqlite3 "$cr/Default/Network/Cookies" "CREATE TABLE cookies (host_key TEXT, name TEXT);
    INSERT INTO cookies VALUES ('.secret.example', 'sid'), ('.example.org', 'sid');"
  sqlite3 "$cr/Profile 1/Cookies" "CREATE TABLE cookies (host_key TEXT, name TEXT); INSERT INTO cookies VALUES ('a', 'b');"
  printf 'passwords\n' >"$cr/Default/Login Data"
  printf '{"roots":{}}\n' >"$cr/Default/Bookmarks"
  printf '{}\n' >"$cr/Default/Preferences"
  mkdir -p "$cr/Default/Extensions/abc" && printf 'ext\n' >"$cr/Default/Extensions/abc/manifest.json"

  items='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "item" and e["id"].startswith("priv_browser_") and e["status"] != "clean" or e.get("note") == "needs sqlite3":
        print(e["id"], e["status"], e["bytes"], repr(e["note"]), repr(e["locked"]), e["default"])'
  out=$(cm --json --only privacy scan | python3 -c "$items")
  want=$(tbytes "$ff/places.sqlite" "$ff/cookies.sqlite")
  assert_contains "$out" "priv_browser_firefox found $want '3 history entries, 2 cookies, 1 download' '' False"
  want=$(tbytes "$cr/Default/History" "$cr/Default/History-journal" "$cr/Default/Visited Links" \
    "$cr/Default/Network/Cookies" "$cr/Profile 1/Cookies")
  assert_contains "$out" "priv_browser_chromium found $want '2 history entries, 3 cookies, 1 download' '' False"
  assert_eq "$(grep -c . <<<"$out")" 2 "only the browsers found are listed"
  out=$(cm --json details priv_browser_chromium)
  assert_contains "$out" "~/.config/chromium/Default  (2 history entries, 2 cookies, 1 download)"

  # a running browser locks its item, and a clean skips it
  running_stub "$bin" firefox chromium
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json --only privacy scan | python3 -c "$items")
  assert_contains "$out" "priv_browser_firefox found $(tbytes "$ff/places.sqlite" "$ff/cookies.sqlite") '3 history entries, 2 cookies, 1 download' 'firefox'"
  assert_contains "$out" "'chromium' False"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean priv_browser_firefox priv_browser_chromium 2>&1)
  assert_contains "$out" '"id":"priv_browser_firefox","state":"skip"'
  assert_contains "$out" '"id":"priv_browser_chromium","state":"skip"'
  assert_exists "$cr/Default/History"
  assert_eq "$(sqlite3 "$ff/places.sqlite" 'SELECT count(*) FROM moz_historyvisits;')" 3 "running Firefox: history kept"

  # without sqlite3 Firefox can't be cleared; Chromium is listed by size only
  out=$(BASE_PATH=$(path_without sqlite3) cm --json --only privacy scan | python3 -c "$items")
  assert_contains "$out" "priv_browser_firefox clean"
  assert_contains "$out" "'needs sqlite3'"
  assert_contains "$out" "priv_browser_chromium found"
  assert_contains "$out" "'install sqlite3 to count entries'"

  out=$(user_cm --json clean priv_browser_firefox priv_browser_chromium 2>&1)
  assert_contains "$out" '"id":"priv_browser_firefox","state":"ok"'
  assert_contains "$out" '"id":"priv_browser_chromium","state":"ok"'
  assert_eq "$(sqlite3 "$ff/places.sqlite" 'SELECT count(*) FROM moz_historyvisits; SELECT count(*) FROM moz_inputhistory;
    SELECT count(*) FROM moz_annos;' | paste -sd' ')" "0 0 0" "Firefox history, typed text and downloads cleared"
  assert_eq "$(sqlite3 "$ff/places.sqlite" 'SELECT url, visit_count, ifnull(last_visit_date, 0) FROM moz_places;
    SELECT count(*) FROM moz_origins; SELECT title FROM moz_bookmarks;' | paste -sd' ')" \
    "https://example.org/|0|0 1 Example" "Firefox bookmark kept, its visits forgotten"
  assert_eq "$(sqlite3 "$ff/cookies.sqlite" 'SELECT count(*) FROM moz_cookies;')" 0 "Firefox cookies cleared"
  assert_exists "$ff/prefs.js"
  for f in History History-journal "Visited Links" Network/Cookies; do assert_missing "$cr/Default/$f"; done
  assert_missing "$cr/Profile 1/Cookies"
  for f in "Login Data" Bookmarks Preferences Extensions/abc/manifest.json; do assert_exists "$cr/Default/$f"; done
  out=$(cm --json --only privacy scan | python3 -c "$items")
  assert_eq "$out" "" "nothing left to clear"
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
  assert_eq "$(env -i HOME="$HOME_DIR" PATH="$bin:$BASE_PATH" cm --version | head -n 1)" "$(cm --version | head -n 1)" "cm runs"
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
  assert_eq "$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" bash "$HOME_DIR/.local/bin/cleanmate" --version | head -n 1)" \
    "cleanmate 99.0.0" "installed copy updated"
  assert_eq "$(readlink "$HOME_DIR/.local/bin/cm")" "cleanmate" "cm link survives the update"
  out=$(env -i HOME="$HOME_DIR" PATH="$BASE_PATH" LANG=C.UTF-8 CLEANMATE_UPDATE_URL="http://127.0.0.1:$port/new.sh" \
    bash "$HOME_DIR/.local/bin/cleanmate" --update 2>&1 </dev/null)
  assert_contains "$out" "up to date"
  kill "$srv" 2>/dev/null
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

test_unused_packages_cached_until_packages_change() {
  fresh_home
  local bin=$WORK/orphbin r=$WORK/orphroot cache
  cache=$HOME_DIR/.cache/cleanmate/orphans.tsv
  mkdir -p "$bin" "$r/var/lib/dpkg" "$r/var/lib/apt" "$r/etc/apt/apt.conf.d"
  # apt-get lists the packages in $bin/orphans and counts its runs; dpkg-query sizes them from $bin/sizes
  printf '#!/bin/sh\necho run >>"%s/runs"\nsed "s/.*/Remv & [1.0]/" "%s/orphans"\n' "$bin" "$bin" >"$bin/apt-get"
  printf '#!/bin/sh\nshift 2\nfor p; do awk -v p="$p" '"'"'$2 == p {print $1 "\\t" $2}'"'"' "%s/sizes"; done\n' "$bin" >"$bin/dpkg-query"
  printf '#!/bin/sh\ncat "%s/kernel"\n' "$bin" >"$bin/uname"
  chmod +x "$bin/"*
  printf '100 libfoo\n50 libbar\n' >"$bin/sizes"
  printf 'libfoo\nlibbar\n' >"$bin/orphans"
  echo 6.8.0-40-generic >"$bin/kernel"
  echo "Package: base" >"$r/var/lib/dpkg/status"
  echo "Package: libfoo" >"$r/var/lib/apt/extended_states"
  local BASE_PATH="$bin:$BASE_PATH"
  scan() { in_app "SYSROOT='$r'; scan_orphans; echo \"\$? \${SCAN_BYTES:-0} \$SCAN_NOTE\""; }
  runs() { wc -l <"$bin/runs" | tr -d ' '; }
  assert_eq "$(scan)" "0 153600 2 packages" "both unused packages and their size"
  assert_eq "$(runs)" 1 "apt asked once"
  assert_eq "$(scan)" "0 153600 2 packages" "the same again"
  assert_eq "$(runs)" 1 "again: from the cache, apt not asked"
  local details
  details=$(in_app "SYSROOT='$r'; details_orphans")
  assert_eq "$(grep -c 'lib' <<<"$details")" 2 "details list the packages the scan counted"
  assert_contains "$details" "libfoo"
  assert_contains "$details" "100.0 KB"
  assert_eq "$(runs)" 1 "details use the scan's answer"
  # a package installed or removed: dpkg replaces its status file
  echo libfoo >"$bin/orphans"
  printf 'Package: base\n\nPackage: new\n' >"$r/var/lib/dpkg/status.new" && mv "$r/var/lib/dpkg/status.new" "$r/var/lib/dpkg/status"
  assert_eq "$(scan)" "0 102400 1 package" "packages changed: asked again"
  assert_eq "$(runs)" 2 "apt asked after the change"
  assert_contains "$(in_app "SYSROOT='$r'; details_orphans")" "libfoo"
  assert_eq "$(in_app "SYSROOT='$r'; details_orphans" | grep -c libbar)" 0 "details follow the new answer"
  # marked as installed by hand (apt-mark manual)
  : >"$bin/orphans"
  echo "Package: other" >"$r/var/lib/apt/extended_states"
  assert_eq "$(scan)" "2 0 " "nothing unused after apt-mark"
  assert_eq "$(scan)" "2 0 " "nothing unused, from the cache"
  assert_eq "$(runs)" 3 "an empty answer is cached too"
  # another kernel running: apt keeps the running one
  echo libbar >"$bin/orphans"
  echo 6.8.0-41-generic >"$bin/kernel"
  assert_eq "$(scan)" "0 51200 1 package" "rebooted into another kernel: asked again"
  # apt's settings (a NeverAutoRemove rule)
  echo libfoo >"$bin/orphans"
  echo 'APT::NeverAutoRemove { "^libbar$"; };' >"$r/etc/apt/apt.conf.d/99keep"
  assert_eq "$(scan)" "0 102400 1 package" "apt settings changed: asked again"
  assert_eq "$(runs)" 5 "one apt run per change"
  # a day old: asked again even if nothing changed
  sed -i '1s/\t[0-9]*\t/\t1\t/' "$cache"
  scan >/dev/null
  assert_eq "$(runs)" 6 "a cached answer is used for a day at most"
  # cleaning forgets the answer (apt decides again when it removes them)
  in_app "SYSROOT='$r'; clean_orphans" >/dev/null 2>&1
  assert_missing "$cache"
  # no package database to watch: never cached
  rm "$r/var/lib/dpkg/status"
  local before
  before=$(runs) # as root, clean_orphans itself ran apt-get
  scan >/dev/null; scan >/dev/null
  assert_eq "$(runs)" $((before + 2)) "without a package database apt is asked every time"
  assert_missing "$cache"
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
  version*) echo '1.41 1.41' ;; # Docker 22: volume prune removes named volumes too
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

docker_entries_stub() { # DIR LOG — a docker with dangling, unused and used images, three build-cache records
  # and five volumes (three unused, one in use, one on a network driver); calls logged
  local a b c d e f
  a=sha256:$(printf 'a%.0s' {1..64}) b=sha256:$(printf 'b%.0s' {1..64}) c=sha256:$(printf 'c%.0s' {1..64})
  d=sha256:$(printf 'd%.0s' {1..64}) e=sha256:$(printf 'e%.0s' {1..64}) f=$(printf 'f%.0s' {1..64})
  mkdir -p "$1"
  cat >"$1/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$2"
case "\$*" in
  info*) exit 0 ;;
  version*) cat "$1/api" 2>/dev/null || echo '1.43 1.45' ;;
  "context inspect"*) echo unix:///var/run/docker.sock ;;
  "system df --format"*) printf 'Images\t200MB (10%%)\nLocal Volumes\t1.6GB (80%%)\nBuild Cache\t3.5GB\n' ;;
  "system df -v --format {{range .BuildCache}}"*) printf '%s\n' \\
    'k4v2r7x9q0w3e5t8y1u6i2o4p|3GB|false|false|regular|2 days ago|mount / from exec /bin/sh -c npm ci' \\
    'z9y8x7w6v5u4t3s2r1q0p9o8n|500MB|false|true|source.local|3 hours ago|local source for context' \\
    'inuse0000000000000000000x|1GB|true|false|regular|1 minute ago|being built' ;;
  "system df -v --format {{range .Images}}"*) printf '%s\n' \\
    '$c|0|1.2GB|900MB|3 weeks ago|postgres|16' \\
    '$c|0|1.2GB|900MB|3 weeks ago|postgres|latest' \\
    '$d|2|500MB|500MB|1 day ago|nginx|latest' \\
    '$a|0|120MB|120MB|3 days ago|<none>|<none>' \\
    '$e|0|300MB|N/A|2 months ago|myapp|<none>' \\
    'sha256:short|0|1GB|1GB|1 day ago|odd|1' ;;
  "system df -v --format {{range .Volumes}}"*) printf '%s\n' \\
    'pgdata|0|1.5GB|local|com.example.app=db' \\
    '$f|0|20MB|local|com.docker.volume.anonymous=' \\
    'nfs-share|0|N/A|nfs|' \\
    'scratch|0|5MB|local|com.docker.volume.anonymous=,note=a|b' \\
    'live|1|2GB|local|' ;;
  "images --no-trunc --format"*) printf '%s\t%s\n' $c postgres:16 $c postgres:latest $d nginx:latest $e 'myapp:<none>' ;;
  "images -f dangling=true --format {{.Size}}") printf '120MB\n80MB\n' ;;
  "images -f dangling=true --no-trunc"*) printf '$a\t120MB\t3 days ago\n$b\t80MB\t2 weeks ago\n' ;;
  "volume ls -qf dangling=true") printf 'pgdata\n$f\nnfs-share\nscratch\n' ;;
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
  assert_contains "$(cm --json scan --only dev | grep '"id":"docker_containers"')" '"entries":false'
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
  out=$(user_cm --json clean docker_containers --entries abc 2>&1 | entry_list)
  assert_contains "$out" "error docker_containers can't be cleaned entry by entry"
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

entry_notes() { # reads `--json details` → id (16 chars), bytes, note and label of each entry
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"][:16], e["bytes"], e["note"] or "-", e["label"])'
}

test_docker_volumes_and_images_one_by_one() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local log=$WORK/docker-volumes.log out c e f
  c=sha256:$(printf 'c%.0s' {1..64}) e=sha256:$(printf 'e%.0s' {1..64}) f=$(printf 'f%.0s' {1..64})
  : >"$log"
  chmod 666 "$log" # root runs write it as nobody
  docker_entries_stub "$WORK/dockervolumes" "$log"
  local BASE_PATH="$WORK/dockervolumes:$BASE_PATH"
  out=$(cm --json scan --only dev)
  assert_contains "$(grep '"id":"docker_volumes"' <<<"$out")" '"entries":true'
  assert_contains "$(grep '"id":"docker_images"' <<<"$out")" '"entries":true'
  out=$(cm --json details docker_volumes | entry_notes)
  assert_eq "$out" "pgdata 1500000000 data pgdata · local
ffffffffffffffff 20000000 anonymous ffffffffffff · local
scratch 5000000 anonymous scratch · local
nfs-share 0 data nfs-share · nfs" "unused volumes: biggest first, anonymous or may hold data, the one in use left out"
  # Docker 23+ prunes only anonymous volumes: the scan counts those and names the named ones it keeps
  out=$(cm --json scan --only dev | grep '"id":"docker_volumes"')
  assert_contains "$out" '"bytes":25000000,"note":"2 anonymous volumes — may contain data; 2 named volumes kept"'
  echo '1.41 1.45' >"$WORK/dockervolumes/api" # an older client: prune removes them all
  out=$(cm --json scan --only dev | grep '"id":"docker_volumes"')
  assert_contains "$out" '"bytes":1600000000,"note":"4 volumes — may contain data"'
  rm "$WORK/dockervolumes/api"
  [[ $(cm --json details docker_volumes) == *'"selected":true'* ]] && fail "volumes must not be ticked" || ok_ "volumes not ticked"
  out=$(cm --json details docker_images | entry_notes)
  assert_eq "$out" "sha256:ccccccccc 900000000 - postgres:16 · created 3 weeks ago
sha256:eeeeeeeee 300000000 - myapp · created 2 months ago" \
    "unused images once each, sized by what only they hold; dangling, used and odd IDs left out"
  # only the chosen volume goes, by name; nothing is pruned
  : >"$log"
  out=$(user_cm --json clean docker_volumes --entries pgdata | entry_list)
  assert_contains "$out" "ok docker_volumes"
  assert_eq "$(grep -E '^volume (rm|prune)' "$log")" "volume rm pgdata" "one docker volume rm"
  : >"$log"
  user_cm --json clean docker_volumes --entries "scratch,$f" >/dev/null
  assert_eq "$(grep -E '^volume (rm|prune)' "$log" | sort)" "volume rm $f
volume rm scratch" "two volumes, one rm each"
  # an image goes with all its tags (no -f); one without a tag by its ID
  : >"$log"
  out=$(user_cm --json clean docker_images --entries "$c" | entry_list)
  assert_contains "$out" "ok docker_images"
  assert_eq "$(grep -E '^(rmi|image (rm|prune))' "$log")" "rmi postgres:16 postgres:latest" "rmi by every tag"
  : >"$log"
  user_cm --json clean docker_images --entries "$e" >/dev/null
  assert_eq "$(grep -E '^(rmi|image (rm|prune))' "$log")" "rmi $e" "untagged image by its ID"
  # dry run removes nothing
  : >"$log"
  out=$(user_cm --json --dry-run clean docker_volumes --entries pgdata | entry_list)
  assert_contains "$out" "ok docker_volumes 1500000000"
  [[ $(<"$log") == *"volume rm"* ]] && fail "dry run must not remove" || ok_ "dry run removes nothing"
  # odd IDs are refused before docker is asked anything
  : >"$log"
  out=$(user_cm --json clean docker_volumes --entries '-f' 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID of docker_volumes: -f"
  out=$(user_cm --json clean docker_volumes --entries 'pg data' 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID of docker_volumes"
  out=$(user_cm --json clean docker_volumes --entries '../x' 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID of docker_volumes"
  out=$(user_cm --json clean docker_images --entries 'postgres:16' 2>&1 | entry_list)
  assert_contains "$out" "error Not an entry ID of docker_images: postgres:16"
  assert_eq "$(<"$log")" "" "docker never called for a refused request"
  # well-formed but not listed: a volume in use, an image a container uses, a dangling image
  out=$(user_cm --json clean docker_volumes --entries live | entry_list)
  assert_contains "$out" "fail docker_volumes 0 None of the chosen entries is there any more"
  out=$(user_cm --json clean docker_images --entries "sha256:$(printf 'd%.0s' {1..64})" | entry_list)
  assert_contains "$out" "fail docker_images 0"
  out=$(user_cm --json clean docker_images --entries "sha256:$(printf 'a%.0s' {1..64})" | entry_list)
  assert_contains "$out" "fail docker_images 0"
  [[ $(<"$log") == *"volume rm"* || $(<"$log") == *"rmi"* ]] && fail "unlisted entries must not be removed" || ok_ "in-use volume and images untouched"
  out=$(in_app 'DOCKER_HOST=tcp://10.0.0.5:2375 json_entries docker_volumes')
  assert_eq "$out" "" "no entries for a remote Docker"
}

# Docker volumes and stopped containers may hold data: an unattended clean (--clean --yes, --auto)
# leaves them even when the remembered choices tick them; naming one with --json clean cleans it.
test_unattended_clean_skips_data_loss_items() {
  fresh_home
  local log=$WORK/docker-dataloss.log out
  : >"$log"
  chmod 666 "$log" # root runs write it as nobody
  mkdir -p "$WORK/dockerloss"
  cat >"$WORK/dockerloss/docker" <<EOF
#!/bin/sh
echo "\$*" >>"$log"
case "\$*" in
  info*) exit 0 ;;
  version*) echo '1.41 1.41' ;;
  "system df --format"*) printf 'Images\t1.5GB (60%%)\nContainers\t200MB (100%%)\nLocal Volumes\t50MB (10%%)\nBuild Cache\t2GB\n' ;;
  "images -f dangling=true --format {{.Size}}") printf '120MB\n80MB\n' ;;
  "ps -aq"*) printf 'a1\nb2\n' ;;
  "volume ls -qf dangling=true") printf 'v1\n' ;;
esac
EOF
  chmod +x "$WORK/dockerloss/docker"
  local BASE_PATH="$WORK/dockerloss:$BASE_PATH"
  select_only docker_dangling docker_volumes docker_containers
  out=$(cm --clean --yes --dry-run --only dev 2>&1 </dev/null)
  assert_contains "$out" "Docker: unused volumes skipped: may hold data — run cm --json clean docker_volumes"
  assert_contains "$out" "Docker: stopped containers skipped: may hold data — run cm --json clean docker_containers"
  assert_contains "$out" "[dry-run] docker image prune -f"
  [[ $out == *"docker volume prune"* || $out == *"docker container prune"* ]] && fail "skipped items must not be in the dry run" || ok_ "dry run leaves volumes and containers out"
  : >"$log"
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  out=$(<"$log")
  assert_contains "$out" "image prune -f"
  [[ $out == *"volume prune"* || $out == *"container prune"* ]] && fail "--clean --yes must not prune ticked volumes or containers" || ok_ "volumes and containers kept"
  : >"$log"
  out=$(user_cm --auto 2>&1 </dev/null)
  assert_contains "$out" "Docker: unused volumes skipped: may hold data"
  [[ $(<"$log") == *"volume prune"* || $(<"$log") == *"container prune"* ]] && fail "--auto must not prune ticked volumes or containers" || ok_ "--auto keeps them"
  # named = asked for
  out=$(user_cm --json --dry-run clean docker_volumes docker_containers)
  assert_contains "$out" '"id":"docker_volumes","state":"ok"'
  assert_contains "$out" '"id":"docker_containers","state":"ok"'
  : >"$log"
  user_cm --json clean docker_volumes >/dev/null
  assert_contains "$(<"$log")" "volume prune"
  # data_loss marks exactly these two
  out=$(cm --json items | grep '"data_loss":true' | grep -o '"id":"[a-z_]*"' | LC_ALL=C sort | paste -sd' ' -)
  assert_eq "$out" '"id":"docker_containers" "id":"docker_volumes"' "--json items: data_loss on volumes and containers only"
  out=$(cm --json items)
  [[ $(grep -c '"data_loss":' <<<"$out") == $(grep -c '"event":"item"' <<<"$out") ]] && ok_ "every item says data_loss" || fail "an item lacks data_loss"
  out=$(cm --json scan --only dev)
  assert_contains "$(grep '"id":"docker_volumes"' <<<"$out")" '"data_loss":true'
  assert_contains "$(grep '"id":"docker_dangling"' <<<"$out")" '"data_loss":false'
}

test_docker_sizes_in_a_decimal_comma_language() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  local l lang=""
  for l in vi_VN.UTF-8 de_DE.UTF-8 fr_FR.UTF-8; do
    [[ $(env LC_ALL="$l" printf '%.1f' 1 2>/dev/null) == 1,0 ]] && { lang=$l; break; }
  done
  [[ -n $lang ]] || { SKIPPED="no locale with a decimal comma installed (locale-gen vi_VN.UTF-8)"; return; }
  fresh_home
  local log=$WORK/docker-comma.log out
  : >"$log"
  docker_entries_stub "$WORK/dockercomma" "$log"
  local BASE_PATH="$WORK/dockercomma:$BASE_PATH" TEST_LANG=$lang
  # Docker writes "1.5GB" whatever the language
  out=$(cm --json details docker_volumes | entry_notes)
  assert_contains "$out" "pgdata 1500000000 data"
  out=$(cm --json scan --only dev)
  assert_contains "$(grep '"id":"docker_build"' <<<"$out")" '"bytes":3500000000'
  echo '1.41 1.45' >"$WORK/dockercomma/api" # prune removes them all: sized from `docker system df`
  out=$(cm --json scan --only dev | grep '"id":"docker_volumes"')
  assert_contains "$out" '"bytes":1600000000'
  assert_eq "$(in_app 'si_to_bytes 1,5GB')" 1500000000 "a size written with a decimal comma"
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
  out=$(cm --json large --min 1048576 --limit 1 | large_names)
  assert_eq "$out" $'video 3145728 film one.mkv\ndone 1' "--limit lists fewer"
  out=$(cm --json large --limit 0 2>&1); assert_contains "$out" "Invalid limit: 0"
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

test_json_clean_gives_trash_keys_for_undo() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local dl=$HOME_DIR/Downloads thumb=$HOME_DIR/.cache/thumbnails/large/a.png out
  sized "$dl/a.deb" 1000; touch -d "40 days ago" "$dl/a.deb"
  mkdir -p "${thumb%/*}"; echo x >"$thumb"
  local done_='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "done": print(json.dumps(e.get("trash"), sort_keys=True))
    elif e["event"] == "item": print(e["id"], e["trash"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["id"], e.get("trash", ""))'
  out=$(cm --json items | python3 -c "$done_" | grep -E '^(abandoned_downloads|old_installers|old_downloads|old_screenshots|stale_build_dirs|vscode_stale_workspaces|thumbs|node_modules) ' | sort)
  assert_eq "$out" $'abandoned_downloads True\nnode_modules False\nold_downloads True\nold_installers True\nold_screenshots True\nstale_build_dirs True\nthumbs False\nvscode_stale_workspaces True' \
    "items say which ones go to the Trash"
  out=$(user_cm --json --dry-run clean old_installers thumbs | python3 -c "$done_")
  assert_eq "$out" $'ok old_installers \nok thumbs \n{}' "dry run: nothing to undo"
  out=$(user_cm --json clean old_installers thumbs | python3 -c "$done_")
  assert_eq "$out" $'ok old_installers \nok thumbs \n{"old_installers": ["a.deb"]}' \
    "done lists the Trash keys of what went to the Trash, by item; deleted items have none"
  assert_missing "$dl/a.deb"; assert_missing "$thumb"
  out=$(user_cm --json restore a.deb | python3 -c "$done_")
  assert_eq "$out" $'ok '"$dl/a.deb"$' a.deb\nnull' "restore takes the keys of done"
  assert_exists "$dl/a.deb"; assert_missing "$thumb"
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

test_old_downloads() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local dl=$HOME_DIR/Downloads out f pid hold=()
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  sized "$dl/old.pdf" 1000
  sized "$dl/Trip/a.jpg" 2000; sized "$dl/Trip/raw/b.jpg" 3000           # a folder untouched inside too
  sized "$dl/new.pdf" 50                                                 # changed 10 days ago
  sized "$dl/read.pdf" 60                                                # opened 5 days ago
  sized "$dl/Work/x.txt" 70; sized "$dl/Work/y.txt" 80                    # y.txt changed 10 days ago
  sized "$dl/Read/z.txt" 90                                              # z.txt opened 5 days ago
  sized "$dl/setup.deb" 400                                              # an old installer: listed there
  sized "$dl/movie.mkv" 0; sized "$dl/movie.mkv.part" 500                # still downloading
  sized "$dl/file.crdownload" 600                                        # an unfinished download
  sized "$dl/.hidden" 700                                                # hidden
  sized "$dl/open.txt" 800                                               # open in a program
  sized "$dl/Keep/k.bin" 900                                             # Never clean
  sized "$WORK/elsewhere.bin" 500; ln -s "$WORK/elsewhere.bin" "$dl/link.bin"
  while IFS= read -r f; do touch -d "120 days ago" "$f"; done < <(find "$dl" -depth -mindepth 1 ! -type l)
  touch -h -d "120 days ago" "$dl/link.bin"
  touch -d "10 days ago" "$dl/new.pdf" "$dl/Work/y.txt"
  touch -a -d "5 days ago" "$dl/read.pdf" "$dl/Read/z.txt"
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  user_cm --json settings-set exclusions add "$dl/Keep" >/dev/null
  out=$(in_app 'load_settings; OD_MAX_FILES=1; old_downloads; echo "${OD_NAME[*]}"')
  assert_eq "$out" "old.pdf open.txt" "a folder with too many files is skipped"
  "${hold[@]}" sleep 60 <"$dl/open.txt" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only system | grep '"id":"old_downloads"' | python3 -c "$list")
  assert_eq "$out" "old_downloads 6000 2 items untouched for 90+ days False True False" \
    "old files and folders at the top of Downloads, not ticked"
  out=$(user_cm --json details old_downloads | python3 -c "$list")
  assert_eq "$out" "Trip 5000 off Trip/ · untouched for 120 days"$'\n'"old.pdf 1000 off old.pdf · untouched for 120 days" \
    "one entry per file or folder, biggest first"
  assert_contains "$(user_cm --json details old_installers | python3 -c "$list")" "setup.deb 400"
  out=$(user_cm --json --dry-run clean old_downloads | python3 -c "$list")
  assert_contains "$out" "ok 6000"
  assert_exists "$dl/old.pdf"
  out=$(user_cm --json clean old_downloads --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of old_downloads: ../etc"
  out=$(user_cm --json clean old_downloads --entries "Trip,new.pdf" | python3 -c "$list")
  assert_eq "$out" "ok 5000 4.9 KB freed" "only the chosen folder"
  assert_missing "$dl/Trip"; assert_exists "$HOME_DIR/.local/share/Trash/files/Trip/raw/b.jpg"; assert_exists "$dl/old.pdf"
  out=$(user_cm --json clean old_downloads | python3 -c "$list")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok 1000 1000 B freed" "the rest"
  assert_missing "$dl/old.pdf"; assert_exists "$HOME_DIR/.local/share/Trash/info/old.pdf.trashinfo"
  for f in new.pdf read.pdf Work/x.txt Read/z.txt setup.deb movie.mkv movie.mkv.part file.crdownload .hidden open.txt Keep/k.bin link.bin; do
    assert_exists "$dl/$f"
  done
  assert_exists "$WORK/elsewhere.bin"
  out=$(user_cm --json restore Trip old.pdf | python3 -c "$list")
  assert_eq "$out" "ok 0 put back"$'\n'"ok 0 put back" "restore puts them back"
  assert_exists "$dl/Trip/raw/b.jpg"; assert_exists "$dl/old.pdf"
  # the terminal app: what a cleanup moved to the Trash is the batch z puts back
  touch -d "120 days ago" "$dl/open.txt" "$dl/Trip"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  out=$(in_app 'SESSION_TMP=$(mktemp -d) UI_ACTIVE=0 DRY_RUN=0; load_settings
    new_tasks clean; add_task "Old downloads" task_clean old_downloads; CLEAN_UNDO=()
    run_tasks Cleaning >/dev/null
    echo "batch=${#CLEAN_UNDO[@]}"; UNDO_BATCH=("${CLEAN_UNDO[@]}")
    [[ -e $HOME/Downloads/old.pdf ]] && echo "not trashed"
    undo_trash; echo "restored=$UNDO_OK"; rm -r "$SESSION_TMP"')
  assert_eq "$out" "batch=3"$'\n'"restored=3" "z puts back what the cleanup trashed"
  assert_exists "$dl/Trip/a.jpg"; assert_exists "$dl/old.pdf"; assert_exists "$dl/open.txt"
  # Settings › Old downloads: how long something stays untouched
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  out=$(user_cm --json settings-set download_days 6 2>&1); assert_contains "$out" "download_days must be a number from 7 to 3650"
  user_cm --json settings-set download_days 7 >/dev/null
  out=$(user_cm --json details old_downloads | python3 -c "$list")
  assert_contains "$out" "new.pdf 50 off new.pdf · untouched for 10 days"
  assert_contains "$out" "Work 150 off Work/ · untouched for 10 days"
  assert_contains "$(user_cm --json items)" "opened or changed for more than 7 days"
  user_cm --json settings-set download_days 90 >/dev/null
  assert_eq "$(user_cm --json details old_downloads | python3 -c "$list" | cut -d' ' -f1 | LC_ALL=C sort | paste -sd' ' -)" \
    "Trip old.pdf open.txt" "download_days 90"
  # a Downloads folder outside the home folder is never scanned; the item says why
  mkdir -p "$HOME_DIR/.local/bin" "$WORK/data/dl2"
  sized "$WORK/data/dl2/x.pdf" 30; touch -d "120 days ago" "$WORK/data/dl2/x.pdf"
  printf '#!/bin/sh\necho "%s"\n' "$WORK/data/dl2" >"$HOME_DIR/.local/bin/xdg-user-dir"; chmod +x "$HOME_DIR/.local/bin/xdg-user-dir"
  out=$(user_cm --json scan --only system | grep '"id":"old_downloads"' | python3 -c "$list")
  assert_eq "$out" "old_downloads 0 Downloads folder is outside your home folder ($WORK/data/dl2); CleanMate only cleans inside it False True False" \
    "outside the home folder: a note, nothing listed"
  user_cm --json clean old_downloads >/dev/null 2>&1
  assert_exists "$WORK/data/dl2/x.pdf"
}

test_old_screenshots() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local pics=$HOME_DIR/Pictures shots=$HOME_DIR/Pictures/Screenshots out f pid hold=()
  local gnome="Screenshot from 2025-01-01 10-00-00.png" cast="Screencast from 2025-02-01 09-00-00.webm"
  local kde="Screenshot_20250101_100000.PNG" vi="Ảnh chụp màn hình từ 2025-01-01 10-00-00.png"
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  sized "$pics/$gnome" 1000                                               # GNOME, top of Pictures
  sized "$shots/$cast" 5000                                               # GNOME screencast
  sized "$shots/$kde" 300                                                 # KDE Spectacle
  sized "$shots/$vi" 200                                                  # GNOME in Vietnamese
  sized "$shots/Screenshot from 2026-10-21 08-00-00.png" 50               # changed 10 days ago
  sized "$shots/Screenshot from 2026-01-02 08-00-00.png" 60               # opened 5 days ago
  sized "$pics/photo.png" 70                                              # not a screenshot
  sized "$pics/Screenshot from notes.png" 80                              # no date after "from"
  sized "$pics/Screenshot from 2025-01-01.txt" 90                         # not a picture or video
  sized "$shots/old/Screenshot from 2025-01-01 11-00-00.png" 100          # one folder deeper
  sized "$shots/Screenshot from 2025-01-03 10-00-00.png" 110              # open in a program
  sized "$WORK/shot.png" 120; ln -s "$WORK/shot.png" "$pics/Screenshot from 2025-01-04 10-00-00.png"
  while IFS= read -r f; do touch -d "120 days ago" "$f"; done < <(find "$pics" -depth -mindepth 1 ! -type l)
  touch -d "10 days ago" "$shots/Screenshot from 2026-10-21 08-00-00.png"
  touch -a -d "5 days ago" "$shots/Screenshot from 2026-01-02 08-00-00.png"
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  "${hold[@]}" sleep 60 <"$shots/Screenshot from 2025-01-03 10-00-00.png" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only system | grep '"id":"old_screenshots"' | python3 -c "$list")
  assert_eq "$out" "old_screenshots 6500 4 files untouched for 90+ days False True False" \
    "old screenshots in Pictures and Pictures/Screenshots, not ticked"
  out=$(user_cm --json details old_screenshots | python3 -c "$list")
  assert_eq "$out" "Screenshots/Screencast%20from%202025-02-01%2009-00-00.webm 5000 off $cast · untouched for 120 days
Screenshot%20from%202025-01-01%2010-00-00.png 1000 off $gnome · untouched for 120 days
Screenshots/Screenshot_20250101_100000.PNG 300 off $kde · untouched for 120 days
Screenshots/$(in_app "urlencode_path '$vi'") 200 off $vi · untouched for 120 days" "one entry per file, biggest first"
  # Never clean
  user_cm --json settings-set exclusions add "$shots" >/dev/null
  out=$(user_cm --json details old_screenshots | python3 -c "$list" | cut -d' ' -f1)
  assert_eq "$out" "Screenshot%20from%202025-01-01%2010-00-00.png" "an excluded folder is skipped"
  user_cm --json settings-set exclusions remove "$shots" >/dev/null
  # automatic cleaning leaves them alone even when ticked
  select_only old_screenshots
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$pics/$gnome"; assert_exists "$shots/$cast"
  out=$(user_cm --json --dry-run clean old_screenshots | python3 -c "$list")
  assert_contains "$out" "ok 6500"
  assert_exists "$pics/$gnome"
  out=$(user_cm --json clean old_screenshots --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of old_screenshots: ../etc"
  out=$(user_cm --json clean old_screenshots --entries "Screenshots/Screencast%20from%202025-02-01%2009-00-00.webm,photo.png" |
    python3 -c "$list")
  assert_eq "$out" "ok 5000 4.9 KB freed" "only the chosen file"
  assert_missing "$shots/$cast"; assert_exists "$HOME_DIR/.local/share/Trash/files/$cast"; assert_exists "$pics/$gnome"
  out=$(user_cm --json clean old_screenshots | python3 -c "$list")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok 1500 1.5 KB freed" "the rest"
  assert_missing "$pics/$gnome"; assert_missing "$shots/$kde"; assert_missing "$shots/$vi"
  for f in "Screenshots/Screenshot from 2026-10-21 08-00-00.png" "Screenshots/Screenshot from 2026-01-02 08-00-00.png" \
    photo.png "Screenshot from notes.png" "Screenshot from 2025-01-01.txt" "Screenshots/old/Screenshot from 2025-01-01 11-00-00.png" \
    "Screenshots/Screenshot from 2025-01-03 10-00-00.png" "Screenshot from 2025-01-04 10-00-00.png"; do
    assert_exists "$pics/$f"
  done
  assert_exists "$WORK/shot.png"
  out=$(user_cm --json restore "$cast" "$gnome" | python3 -c "$list")
  assert_eq "$out" "ok 0 put back"$'\n'"ok 0 put back" "restore puts them back"
  assert_exists "$shots/$cast"; assert_exists "$pics/$gnome"
  # the terminal app: what a cleanup moved to the Trash is the batch z puts back
  touch -d "120 days ago" "$shots/$cast" "$pics/$gnome"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  out=$(in_app 'SESSION_TMP=$(mktemp -d) UI_ACTIVE=0 DRY_RUN=0; load_settings
    new_tasks clean; add_task "Old screenshots" task_clean old_screenshots; CLEAN_UNDO=()
    run_tasks Cleaning >/dev/null
    echo "batch=${#CLEAN_UNDO[@]}"; UNDO_BATCH=("${CLEAN_UNDO[@]}")
    undo_trash; echo "restored=$UNDO_OK"; rm -r "$SESSION_TMP"')
  assert_eq "$out" "batch=3"$'\n'"restored=3" "z puts back what the cleanup trashed"
  assert_exists "$shots/$cast"; assert_exists "$pics/$gnome"; assert_exists "$shots/Screenshot from 2025-01-03 10-00-00.png"
  # Settings › Old downloads sets how long a screenshot stays untouched too
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  user_cm --json settings-set download_days 7 >/dev/null
  assert_contains "$(user_cm --json details old_screenshots | python3 -c "$list")" "off Screenshot from 2026-10-21 08-00-00.png · untouched for 10 days"
  assert_contains "$(user_cm --json items)" "its Screenshots folder that you haven't opened or changed for more than 7 days"
  user_cm --json settings-set download_days 90 >/dev/null
  # the folder xdg-user-dir names; Pictures in Downloads is left to Old downloads; outside home: nothing
  mkdir -p "$HOME_DIR/.local/bin" "$HOME_DIR/Ảnh" "$WORK/data/pics"
  sized "$HOME_DIR/Ảnh/$gnome" 10; touch -d "120 days ago" "$HOME_DIR/Ảnh/$gnome"
  sized "$WORK/data/pics/$gnome" 20; touch -d "120 days ago" "$WORK/data/pics/$gnome"
  printf '#!/bin/sh\n[ "$1" = PICTURES ] && echo "%s" || echo "%s"\n' "$HOME_DIR/Ảnh" "$HOME_DIR/Downloads" \
    >"$HOME_DIR/.local/bin/xdg-user-dir"
  chmod +x "$HOME_DIR/.local/bin/xdg-user-dir"
  assert_eq "$(user_cm --json details old_screenshots | python3 -c "$list" | cut -d' ' -f2)" "10" "the folder xdg-user-dir names"
  printf '#!/bin/sh\necho "%s"\n' "$HOME_DIR/Ảnh" >"$HOME_DIR/.local/bin/xdg-user-dir"
  assert_eq "$(user_cm --json details old_screenshots | python3 -c "$list")" "" "Pictures is the Downloads folder"
  printf '#!/bin/sh\necho "%s"\n' "$WORK/data/pics" >"$HOME_DIR/.local/bin/xdg-user-dir"
  assert_eq "$(user_cm --json details old_screenshots | python3 -c "$list")" "" "Pictures outside the home folder"
  user_cm --json clean old_screenshots >/dev/null 2>&1
  assert_exists "$WORK/data/pics/$gnome"
}

test_abandoned_downloads() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local dl=$HOME_DIR/Downloads out f pid qb hold=()
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  sized "$dl/a.crdownload" 1000                                          # Chrome
  sized "$dl/film.mkv.part" 2000; sized "$dl/film.mkv" 0                 # Firefox: .part + empty real name
  sized "$dl/disk.iso.aria2" 50; sized "$dl/disk.iso" 5000               # aria2: control file + the data
  sized "$dl/movie.!qB" 3000                                             # qBittorrent
  sized "$dl/Upper.CRDOWNLOAD" 100                                       # any case
  sized "$dl/full.part" 400; sized "$dl/full" 700                        # a full file of that name: its own
  sized "$dl/new.crdownload" 60                                          # changed 3 days ago
  sized "$dl/read.part" 70                                               # opened 2 days ago
  sized "$dl/busy.iso.aria2" 80; sized "$dl/busy.iso" 800                # aria2 wrote the data yesterday
  sized "$dl/open.crdownload" 90                                         # open: still downloading
  sized "$dl/sub/deep.crdownload" 110                                    # one folder deeper
  sized "$dl/notes.txt" 120                                              # not a download in progress
  sized "$WORK/elsewhere.part" 130; ln -s "$WORK/elsewhere.part" "$dl/link.part"
  while IFS= read -r f; do touch -d "120 days ago" "$f"; done < <(find "$dl" -depth -mindepth 1 ! -type l)
  touch -d "3 days ago" "$dl/new.crdownload"
  touch -a -d "2 days ago" "$dl/read.part"
  touch -d "1 day ago" "$dl/busy.iso"
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "done" and "trash" in e: print("trash", " ".join(sorted(sum(e["trash"].values(), []))))
    elif e["event"] == "error": print("error", e["message"])'
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  "${hold[@]}" sleep 60 <"$dl/open.crdownload" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  qb=$(in_app "urlencode_path 'movie.!qB'")
  out=$(user_cm --json scan --only system | grep '"id":"abandoned_downloads"' | python3 -c "$list")
  assert_eq "$out" "abandoned_downloads 11550 6 downloads untouched for 7+ days False True False" \
    "unfinished downloads at the top of Downloads, not ticked"
  out=$(user_cm --json details abandoned_downloads | python3 -c "$list")
  assert_eq "$out" "disk.iso.aria2 5050 off disk.iso.aria2 · untouched for 120 days
$qb 3000 off movie.!qB · untouched for 120 days
film.mkv.part 2000 off film.mkv.part · untouched for 120 days
a.crdownload 1000 off a.crdownload · untouched for 120 days
full.part 400 off full.part · untouched for 120 days
Upper.CRDOWNLOAD 100 off Upper.CRDOWNLOAD · untouched for 120 days" "one entry per download, the file next to it counted in"
  # Old installers and Old downloads leave them (and the file of the real name) to this item
  out=$(user_cm --json details old_downloads | python3 -c "$list" | cut -d' ' -f1 | LC_ALL=C sort | paste -sd' ' -)
  assert_eq "$out" "notes.txt sub" "old downloads skips unfinished downloads"
  # Never clean
  user_cm --json settings-set exclusions add "$dl" >/dev/null
  assert_eq "$(user_cm --json details abandoned_downloads | python3 -c "$list")" "" "an excluded Downloads folder is skipped"
  user_cm --json settings-set exclusions remove "$dl" >/dev/null
  # automatic cleaning leaves them alone even when ticked
  select_only abandoned_downloads
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$dl/a.crdownload"; assert_exists "$dl/disk.iso.aria2"
  out=$(user_cm --json --dry-run clean abandoned_downloads | python3 -c "$list")
  assert_contains "$out" "ok 11550"
  assert_exists "$dl/film.mkv.part"
  out=$(user_cm --json clean abandoned_downloads --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of abandoned_downloads: ../etc"
  out=$(user_cm --json clean abandoned_downloads --entries "film.mkv.part,disk.iso.aria2,notes.txt" | python3 -c "$list")
  assert_eq "$out" $'ok 7050 6.9 KB freed\ntrash disk.iso disk.iso.aria2 film.mkv film.mkv.part' \
    "only the chosen downloads, each with the file next to it"
  for f in film.mkv.part film.mkv disk.iso.aria2 disk.iso; do
    assert_missing "$dl/$f"; assert_exists "$HOME_DIR/.local/share/Trash/files/$f"
  done
  out=$(user_cm --json clean abandoned_downloads | python3 -c "$list")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" $'ok 4500 4.4 KB freed\ntrash Upper.CRDOWNLOAD a.crdownload full.part movie.!qB' "the rest"
  for f in new.crdownload read.part busy.iso.aria2 busy.iso open.crdownload sub/deep.crdownload notes.txt full link.part; do
    assert_exists "$dl/$f"
  done
  assert_exists "$WORK/elsewhere.part"
  out=$(user_cm --json restore film.mkv.part film.mkv | python3 -c "$list")
  assert_eq "$out" "ok 0 put back"$'\n'"ok 0 put back" "restore puts both back"
  assert_exists "$dl/film.mkv.part"; assert_exists "$dl/film.mkv"
  # the terminal app: what a cleanup moved to the Trash is the batch z puts back
  touch -d "120 days ago" "$dl/film.mkv.part" "$dl/film.mkv"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  out=$(in_app 'SESSION_TMP=$(mktemp -d) UI_ACTIVE=0 DRY_RUN=0; load_settings
    new_tasks clean; add_task "Abandoned downloads" task_clean abandoned_downloads; CLEAN_UNDO=()
    run_tasks Cleaning >/dev/null
    echo "batch=${#CLEAN_UNDO[@]}"; UNDO_BATCH=("${CLEAN_UNDO[@]}")
    undo_trash; echo "restored=$UNDO_OK"; rm -r "$SESSION_TMP"')
  assert_eq "$out" "batch=3"$'\n'"restored=3" "z puts back what the cleanup trashed"
  assert_exists "$dl/film.mkv.part"; assert_exists "$dl/film.mkv"; assert_exists "$dl/open.crdownload"
  # a Downloads folder outside the home folder is never scanned
  mkdir -p "$HOME_DIR/.local/bin" "$WORK/data/dl3"
  sized "$WORK/data/dl3/x.crdownload" 10; touch -d "120 days ago" "$WORK/data/dl3/x.crdownload"
  printf '#!/bin/sh\necho "%s"\n' "$WORK/data/dl3" >"$HOME_DIR/.local/bin/xdg-user-dir"
  chmod +x "$HOME_DIR/.local/bin/xdg-user-dir"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  assert_eq "$(user_cm --json details abandoned_downloads | python3 -c "$list")" "" "Downloads outside the home folder"
  user_cm --json clean abandoned_downloads >/dev/null 2>&1
  assert_exists "$WORK/data/dl3/x.crdownload"
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
  b_rusty=$(tbytes "$rusty/target") b_py=$(tbytes "$py/.venv") b_pods=$(tbytes "$pods/Pods")
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

# Terraform/OpenTofu: of an idle project only .terraform/providers and .terraform/modules, never its state
test_stale_terraform_providers() {
  fresh_home
  local c=$HOME_DIR/code tf out pid hold=()
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups)
  tf=$c/infra
  new "$tf/main.tf"; new "$tf/.terraform.lock.hcl"; new "$tf/terraform.tfstate"
  sized "$tf/.terraform/providers/registry.terraform.io/hashicorp/aws/p" 3000; sized "$tf/.terraform/modules/vpc/m.tf" 1000
  new "$tf/.terraform/terraform.tfstate"; new "$tf/.terraform/environment"
  new "$c/fresh/main.tf"; sized "$c/fresh/.terraform/providers/p" 10           # changed lately
  new "$c/notf/README"; sized "$c/notf/.terraform/providers/p" 10              # no *.tf next to it
  new "$c/applying/main.tf"; sized "$c/applying/.terraform/providers/p" 10     # terraform works in it
  while IFS= read -r -d '' f; do touch -h -d "100 days ago" "$f"; done < <(find "$HOME_DIR" -print0)
  touch "$c/fresh/main.tf"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  mkdir -p "$WORK/tfbin"; cp "$(command -v sleep)" "$WORK/tfbin/terraform"; chmod 755 "$WORK/tfbin" "$WORK/tfbin/terraform"
  "${hold[@]}" sh -c 'cd "$1" && exec "$2" 60' _ "$c/applying" "$WORK/tfbin/terraform" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json details stale_build_dirs | grep '"event":"entry"')
  assert_eq "$(wc -l <<<"$out")" "1" "only the idle Terraform project"
  assert_contains "$out" '"bytes":4000'; assert_contains "$out" "~/code/infra — .terraform/providers/, .terraform/modules/ · 100 days idle"
  out=$(user_cm --json clean stale_build_dirs 2>&1)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_missing "$tf/.terraform/providers"; assert_missing "$tf/.terraform/modules"
  for f in .terraform/terraform.tfstate .terraform/environment terraform.tfstate main.tf .terraform.lock.hcl; do assert_exists "$tf/$f"; done
  for f in fresh notf applying; do assert_exists "$c/$f/.terraform/providers/p"; done
}

test_infra_tool_caches() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/infrabin f
  new "$h/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/p"; new "$h/.terraform.d/credentials.tfrc.json"
  printf 'plugin_cache_dir = "%s/tfc"\n' "$h" >"$h/.terraformrc"
  new "$h/tfc/registry.opentofu.org/x/p"; new "$h/tfc/notes/keep"
  new "$h/.minikube/cache/iso/amd64/minikube.iso"; new "$h/.minikube/cache/preloaded-tarball/p.tar.lz4"
  new "$h/.minikube/machines/minikube/disk"; new "$h/.minikube/profiles/minikube/config.json"; new "$h/.minikube/ca.crt"
  new "$h/.cache/helm/repository/bitnami-index.yaml"; new "$h/.config/helm/repositories.yaml"; new "$h/.local/share/helm/plugins/p"
  out=$(cm --scan --only dev 2>&1)
  for f in "Terraform plugin cache" "minikube cache" "Helm cache"; do assert_contains "$out" "$f"; done
  out=$(cm --json items 2>&1)
  assert_contains "$out" '"id":"helm_cache"'
  running_stub "$bin" terraform minikube helm
  select_only terraform_plugin_cache minikube_cache helm_cache
  BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_exists "$h/.terraform.d/plugin-cache/registry.terraform.io/hashicorp/aws/p"
  assert_exists "$h/.minikube/cache/iso/amd64/minikube.iso"; assert_exists "$h/.cache/helm/repository/bitnami-index.yaml"
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  for f in .terraform.d/plugin-cache/registry.terraform.io tfc/registry.opentofu.org/x .minikube/cache/iso .minikube/cache/preloaded-tarball \
    .cache/helm/repository/bitnami-index.yaml; do assert_missing "$h/$f"; done
  for f in .terraform.d/credentials.tfrc.json tfc/notes/keep .minikube/machines/minikube/disk .minikube/profiles/minikube/config.json \
    .minikube/ca.crt .config/helm/repositories.yaml .local/share/helm/plugins/p; do assert_exists "$h/$f"; done
}

test_language_package_caches() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/langbin f
  local gone=(.cabal/packages/hackage.haskell.org/x.tar.gz .cache/cabal/packages/h/y .ghcup/cache/ghc.tar.xz
    .stack/pantry/hackage/z .stack/snapshots/x86_64-linux/s .cache/coursier/v1/https/a.jar .ivy2/cache/org/b.jar
    .sbt/boot/scala-2.12/c.jar .opam/download-cache/md5/d .cache/composer/repo/e.json .composer/cache/files/f.zip)
  local kept=(.stack/programs/x86_64-linux/ghc .ghcup/ghc/9.4/bin/ghc .ghcup/bin/ghcup .cabal/bin/hlint .cabal/config
    .ivy2/local/me/p.jar .sbt/1.0/global.sbt .opam/default/lib/x .opam/config .composer/vendor/bin/phpunit .composer/composer.json)
  for f in "${gone[@]}" "${kept[@]}"; do new "$h/$f"; done
  out=$(cm --scan --only dev 2>&1)
  for f in "Haskell package cache" "Scala package cache" "opam download cache" "Composer cache"; do assert_contains "$out" "$f"; done
  out=$(cm --json items 2>&1)
  for f in haskell_cache scala_cache opam_cache composer_cache; do assert_contains "$out" "\"id\":\"$f\""; done
  running_stub "$bin" ghc-9.4.8 sbt opam composer
  select_only haskell_cache scala_cache opam_cache composer_cache
  BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  for f in "${gone[@]}"; do assert_exists "$h/$f"; done
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  for f in "${gone[@]}"; do assert_missing "$h/$f"; done
  for f in "${kept[@]}"; do assert_exists "$h/$f"; done
  # tool variables inside HOME are followed; nothing found → the items stay hidden
  fresh_home
  h=$HOME_DIR
  printf 'export STACK_ROOT="$HOME/st"\nexport COMPOSER_CACHE_DIR="$HOME/cc"\nexport OPAMROOT="$HOME/op"\n' >"$h/.bashrc"
  out=$(in_app 'printf "%s\n" "${ITEM_PATHS[haskell_cache]}" "${ITEM_PATHS[composer_cache]}" "${ITEM_PATHS[opam_cache]}"')
  for f in st/pantry st/snapshots cc op/download-cache; do assert_contains "$out" "$h/$f"; done
  out=$(cm --scan --only dev 2>&1)
  for f in "Haskell package cache" "Scala package cache" "opam download cache" "Composer cache"; do [[ $out == *"$f"* ]] && fail "should be hidden: $f"; done
  return 0
}

test_editor_data_of_deleted_projects() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local u=$HOME_DIR/.config/Code/User/workspaceStorage out gone bin=$WORK/edbin p
  export CLEANMATE_VOLUME_ROOTS=$WORK/nodrive # a drive that isn't plugged in: its projects are kept
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"].rsplit("/", 1)[1], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"], e["selected"], e["entries"], repr(e["locked"]))
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"], e["info"])
    elif e["event"] == "error": print("error", e["message"])'
  mkdir -p "$HOME_DIR/code/alive" "$HOME_DIR/code/with space"
  rmdir "$HOME_DIR/code/with space"
  ws() { # STORAGE-ROOT HASH JSON BYTES
    mkdir -p "$1/$2"; printf '%s\n' "$3" >"$1/$2/workspace.json"; sized "$1/$2/state.vscdb" "$4"
  }
  ws "$u" gone1 "{\"folder\": \"file://$HOME_DIR/code/old%20project\"}" 5000
  ws "$u" gone2 "{\"workspace\":\"file://$HOME_DIR/code/team.code-workspace\"}" 3000
  ws "$u" alive "{\"folder\":\"file://$HOME_DIR/code/alive\"}" 2000
  ws "$u" remote '{"folder":"vscode-remote://ssh-remote%2Bbox/home/me/x"}' 2000
  ws "$u" relative '{"folder":"file://relative/path"}' 2000
  ws "$u" openfile "{\"folder\":\"file://$HOME_DIR/code/open\"}" 2000
  ws "$u" nodrive "{\"folder\":\"file://$WORK/nodrive/usb/proj\"}" 2000
  mkdir -p "$u/nojson"; sized "$u/nojson/state.vscdb" 2000
  ws "$u" corrupt '{"folder":' 2000
  ws "$HOME_DIR/.config/Cursor/User/workspaceStorage" cur1 "{\"folder\":\"file://$HOME_DIR/code/cursor-app\"}" 4000
  ws "$HOME_DIR/.var/app/com.visualstudio.code/config/Code/User/workspaceStorage" fp1 "{\"folder\":\"file://$HOME_DIR/code/flat\"}" 1000
  mkdir -p "$HOME_DIR/.config/Code/User/globalStorage"; sized "$HOME_DIR/.config/Code/User/globalStorage/x" 1000
  gone=$(in_app "urlencode_path '$u/gone1'")
  local b1 b2 bc bf
  b1=$(du -sb "$u/gone1" | cut -f1) b2=$(du -sb "$u/gone2" | cut -f1)
  bc=$(du -sb "$HOME_DIR/.config/Cursor/User/workspaceStorage/cur1" | cut -f1)
  bf=$(du -sb "$HOME_DIR/.var/app/com.visualstudio.code/config/Code/User/workspaceStorage/fp1" | cut -f1)
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  local hold=(); ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups)
  "${hold[@]}" sleep 60 <"$u/openfile/state.vscdb" >/dev/null 2>&1 &
  local pid=$!
  sleep 0.3
  out=$(user_cm --json details vscode_stale_workspaces | python3 -c "$list")
  assert_contains "$out" "gone1 $b1 off old project · Code · 0 days"
  assert_contains "$out" "gone2 $b2 off team · Code · 0 days"
  assert_contains "$out" "cur1 $bc off cursor-app · Cursor · 0 days"
  assert_contains "$out" "fp1 $bf off flat · Code · 0 days"
  assert_eq "$(grep -c '^[a-z0-9]* [0-9]* o' <<<"$out")" 4 "only the folders of deleted projects"
  out=$(user_cm --json clean vscode_stale_workspaces --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of vscode_stale_workspaces: ../etc"
  # locked while an editor runs
  running_stub "$bin" cursor
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json scan --only ai | grep '"id":"vscode_stale_workspaces"' | python3 -c "$list")
  assert_contains "$out" "False True 'cursor'"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean vscode_stale_workspaces --entries "$gone" | python3 -c "$list")
  assert_contains "$out" "skip"
  assert_exists "$u/gone1"
  # automatic cleaning leaves them alone even when ticked
  select_only vscode_stale_workspaces
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$u/gone1"
  out=$(user_cm --json clean vscode_stale_workspaces --entries "$gone" | python3 -c "$list")
  assert_contains "$out" "ok $b1"
  assert_missing "$u/gone1"; assert_exists "$u/gone2"; assert_exists "$u/alive"
  assert_exists "$HOME_DIR/.local/share/Trash/files/gone1/state.vscdb"
  out=$(user_cm --json restore gone1 | python3 -c "$list")
  assert_eq "$out" "ok 0 put back" "restore puts it back"
  assert_exists "$u/gone1/workspace.json"
  out=$(user_cm --json clean vscode_stale_workspaces | python3 -c "$list")
  assert_contains "$out" "ok"
  for p in gone1 gone2; do assert_missing "$u/$p"; done
  assert_missing "$HOME_DIR/.config/Cursor/User/workspaceStorage/cur1"
  assert_missing "$HOME_DIR/.var/app/com.visualstudio.code/config/Code/User/workspaceStorage/fp1"
  for p in alive remote relative openfile nodrive nojson corrupt; do assert_exists "$u/$p"; done
  assert_exists "$HOME_DIR/.config/Code/User/globalStorage/x"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  unset CLEANMATE_VOLUME_ROOTS
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
  out=$(cm --json lens --limit 1 | lens_entries)
  assert_eq "$out" $'dir 4 true Big\ndone 12 1 5' "--limit lists fewer"
  # Space Lens moves things to the Trash with --home-only: what it lists as view only is refused
  local tasks='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], e["trash"] or "-", e["info"])
    elif e["event"] == "done": print("done", e.get("moved", e.get("restored")), e["failed"])'
  local why="Only items inside your home folder or on a writable drive can be moved to the Trash here"
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

# Space Lens on drives mounted for you: writable local ones move into the drive's own Trash and come
# back; read-only, network ones, the drive's top, its Trash, Timeshift backups and symlinks stay view only
test_space_lens_on_external_drives() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out uid=$EUID vol usb key
  ((EUID == 0)) && uid=65534
  vol=$(mktemp -d -p "$WORK" lensmedia.XXXX)
  usb=$vol/USB
  sized "$usb/Photos/a.jpg" 3000; sized "$usb/big.iso" 9000; sized "$usb/.Trash-$uid/files/old.bin" 10
  sized "$usb/timeshift/snapshots/s/x" 20; sized "$WORK/lens-elsewhere/e.bin" 30; ln -s "$WORK/lens-elsewhere" "$usb/link"
  sized "$vol/RO/r.bin" 600; sized "$vol/NAS/n.bin" 800
  printf 'server:/export %s/NAS nfs4 rw,relatime 0 0\n/dev/sdz1 %s/RO vfat ro,nosuid 0 0\n' "$vol" "$vol" >"$WORK/lens-mounts"
  ((EUID == 0)) && chown -R 65534:65534 "$vol" "$WORK/lens-elsewhere"
  local CLEANMATE_VOLUME_ROOTS=$vol CLEANMATE_MOUNTS=$WORK/lens-mounts
  local lens='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(str(e["movable"]).lower(), e["path"].rsplit("/", 1)[1])
    elif e["event"] == "done": print("done", e["drive"].rsplit("/", 1)[-1] or "-", str(e["drive_trash"]).lower())'
  out=$(user_cm --json lens --path "$usb" | python3 -c "$lens" | LC_ALL=C sort)
  assert_eq "$out" "done USB true
false .Trash-$uid
false timeshift
true Photos
true big.iso
true link" "a writable drive: movable but its Trash and Timeshift backups"
  out=$(user_cm --json lens --path "$usb/link" | python3 -c "$lens")
  assert_eq "$out" $'false e.bin\ndone USB true' "through a symlink to elsewhere: view only"
  out=$(user_cm --json lens --path "$vol/RO" | python3 -c "$lens")
  assert_eq "$out" $'false r.bin\ndone RO false' "a read-only drive: view only"
  out=$(user_cm --json lens --path "$vol/NAS" | python3 -c "$lens")
  assert_eq "$out" $'false n.bin\ndone NAS false' "a network drive: view only"
  out=$(user_cm --json lens --path "$vol" | python3 -c "$lens" | LC_ALL=C sort)
  assert_eq "$out" $'done - false\nfalse NAS\nfalse RO\nfalse USB' "the drives themselves: view only"
  local tasks='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], (e["trash"] or "-").replace(sys.argv[1], "<vol>"), e["info"])
    elif e["event"] == "done": print("done", e.get("moved", e.get("restored")), e["failed"])'
  local why="Only items inside your home folder or on a writable drive can be moved to the Trash here"
  out=$(user_cm --json trash --home-only "$vol/RO/r.bin" "$vol/NAS/n.bin" "$usb" "$usb/timeshift/snapshots" \
    "$usb/.Trash-$uid/files/old.bin" "$usb/link/e.bin" "$usb/Photos" | python3 -c "$tasks" "$vol")
  assert_eq "$out" "fail - $why
fail - $why
fail - $why
fail - $why
fail - $why
fail - $why
ok <vol>/USB/.Trash-$uid/files/Photos moved to the Trash
done 1 6" "trash --home-only takes a writable drive, refuses the rest"
  assert_missing "$usb/Photos"; assert_exists "$usb/.Trash-$uid/files/Photos/a.jpg"
  assert_exists "$vol/RO/r.bin"; assert_exists "$vol/NAS/n.bin"; assert_exists "$WORK/lens-elsewhere/e.bin"
  assert_exists "$usb/timeshift/snapshots/s/x"
  key=$usb/.Trash-$uid/files/Photos
  out=$(user_cm --json restore "$key" | python3 -c "$tasks" "$vol")
  assert_eq "$out" "ok <vol>/USB/.Trash-$uid/files/Photos put back"$'\ndone 1 0' "undo puts it back on the drive"
  assert_exists "$usb/Photos/a.jpg"
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
  out=$(cm --json dupes --limit 1 | dupe_groups)
  out=${out//Backup\/beach-link.jpg/Backup\/beach.jpg}
  assert_eq "$out" $'2000000 Downloads/beach (1).jpg,Backup/beach.jpg,Photos/beach.jpg\ndone 1 2 3 4000000' \
    "--limit keeps the biggest groups only"
  out=$(cm --json dupes --limit 0 2>&1); assert_contains "$out" "Invalid limit: 0"
}

startup_list() { # reads `--json startup` / `startup-set` → one line per event
  python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "unit":
        flags = "".join(c for c, k in (("s", "system"), ("h", "hidden"), ("t", "toggle"), ("r", "removable")) if e[k]) or "-"
        print(e["id"], "on" if e["enabled"] else "off", flags, e["name"] + (" !" + e["missing_cmd"] if e["missing"] else ""))
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
  mkdir -p "$HOME_DIR/bin" # the programs exist: nothing here is broken
  printf '#!/bin/sh\n' | tee "$HOME_DIR/.local/bin/chat" "$HOME_DIR/.local/bin/old" "$HOME_DIR/bin/sync" >/dev/null
  chmod +x "$HOME_DIR/.local/bin/systemctl" "$HOME_DIR/.local/bin/chat" "$HOME_DIR/.local/bin/old" "$HOME_DIR/bin/sync"
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
  assert_contains "$out" "fail - Only units in ~/.config/systemd/user, or whose program is gone, can be removed"
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

test_startup_broken_items() { # entries and units whose program a removed app took with it
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out a=$HOME_DIR/.config/autostart u=$HOME_DIR/.config/systemd/user s=$HOME_DIR/.local/share/systemd/user
  local sys=$WORK/xdg-autostart.$RANDOM b=$HOME_DIR/.local/bin
  local CLEANMATE_SYSTEM_AUTOSTART=$sys
  mkdir -p "$a" "$u" "$s" "$sys" "$b" "$HOME_DIR/opt/app" "$HOME_DIR/.local/share/flatpak/app/org.kept.App"
  startup_entry() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n%b' "$2" "$3" "${4:-}" >"$1"; }
  printf '#!/bin/sh\n' >"$b/tray-here"; printf '#!/bin/sh\n' >"$HOME_DIR/opt/app/run me"
  printf '#!/bin/sh\n[ "$1" = info ] && [ "$2" = org.other.App ]\n' >"$b/flatpak" # installed: org.other.App only
  chmod +x "$b/tray-here" "$HOME_DIR/opt/app/run me" "$b/flatpak"
  startup_entry "$a/here.desktop" Here "tray-here --hidden"
  startup_entry "$a/gone.desktop" Gone "zz-gone-app --tray"
  startup_entry "$a/abs.desktop" Abs "$HOME_DIR/opt/app/zz-gone"
  startup_entry "$a/quoted.desktop" Quoted "\"$HOME_DIR/opt/app/run me\" %U"
  startup_entry "$a/try.desktop" Try "tray-here" "TryExec=zz-gone-try\n"
  startup_entry "$a/env.desktop" Env "env GDK_BACKEND=x11 -u QT_QPA tray-here"
  startup_entry "$a/envgone.desktop" EnvGone "env FOO=1 zz-gone-env"
  startup_entry "$a/shell.desktop" Shell "sh -c 'sleep 5 && zz-gone-in-shell'"
  startup_entry "$a/var.desktop" Var "\$HOME/zz-gone"
  startup_entry "$a/flat.desktop" Flat "flatpak run --branch=stable org.other.App"
  startup_entry "$a/flatdir.desktop" FlatDir "$b/flatpak run --command=kept org.kept.App"
  startup_entry "$a/flatgone.desktop" FlatGone "flatpak run org.gone.App"
  startup_entry "$a/dbus.desktop" DBus "" "DBusActivatable=true\n"
  startup_entry "$sys/sysgone.desktop" SysGone "zz-gone-system" # the system's: never judged
  printf '[Service]\nExecStart="%%h/opt/app/run me" --x\n' >"$u/quoted.service"
  printf '[Service]\nExecStart=%%h/opt/zz-gone\\x20app/run\n' >"$u/escaped.service" # an escape: not judged
  printf '[Service]\nExecStart=-%%h/.local/bin/tray-here --x\n' >"$u/ok.service"
  printf '[Service]\nExecStart=\nExecStart=/opt/zz-gone/agent --daemon\n' >"$u/gone.service"
  printf '[Service]\nExecStart=/bin/sh -c "zz-gone-x"\n' >"$u/shell.service"
  printf '[Service]\nExecStart=zz-gone-bare\n' >"$u/bare.service"
  printf '[Timer]\nOnCalendar=daily\n' >"$s/backup.timer"
  printf '[Service]\nExecStart=%%h/zz-gone/backup\n' >"$s/backup.service"
  printf '[Service]\nExecStart=%%h/zz-gone/old\n' >"$s/old.service"
  printf '%s\n' 'quoted.service enabled enabled' 'escaped.service enabled enabled' 'ok.service enabled enabled' 'gone.service enabled enabled' 'shell.service enabled enabled' \
    'bare.service disabled enabled' 'backup.timer enabled enabled' 'old.service disabled enabled' >"$HOME_DIR/units"
  printf '%s\n' '#!/bin/sh' 'echo "$*" >>"$HOME/systemctl.log"' 'shift' \
    'case $1 in list-unit-files) cat "$HOME/units" ;; enable | disable) for u; do :; done; sed -i "s/^$u [a-z]*/$u ${1}d/" "$HOME/units" ;; esac' \
    >"$b/systemctl"
  chmod +x "$b/systemctl"
  out=$(user_cm --json startup | startup_list)
  assert_eq "$out" "autostart:abs.desktop on tr Abs !$HOME_DIR/opt/app/zz-gone
autostart:dbus.desktop on tr DBus
autostart:env.desktop on tr Env
autostart:envgone.desktop on tr EnvGone !zz-gone-env
autostart:flat.desktop on tr Flat
autostart:flatdir.desktop on tr FlatDir
autostart:flatgone.desktop on tr FlatGone !flatpak run org.gone.App
autostart:gone.desktop on tr Gone !zz-gone-app
autostart:here.desktop on tr Here
autostart:quoted.desktop on tr Quoted
autostart:shell.desktop on tr Shell
autostart:sysgone.desktop on st SysGone
autostart:try.desktop on tr Try !zz-gone-try
autostart:var.desktop on tr Var
systemd:quoted.service on tr quoted.service
systemd:escaped.service on tr escaped.service
systemd:ok.service on tr ok.service
systemd:gone.service on tr gone.service !/opt/zz-gone/agent
systemd:shell.service on tr shell.service
systemd:bare.service off tr bare.service
systemd:backup.timer on tr backup.timer !$HOME_DIR/zz-gone/backup
systemd:old.service off tr old.service !$HOME_DIR/zz-gone/old
done 22 true" "broken entries and units are flagged, the rest are not"
  # a broken unit in ~/.local/share/systemd/user can be removed too: turned off, then to the Trash
  out=$(user_cm --json startup-set systemd:backup.timer remove | startup_list)
  assert_contains "$out" "ok backup.timer moved to the Trash"; assert_missing "$s/backup.timer"
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" $'--user disable --now backup.timer\n--user daemon-reload'
  out=$(user_cm --json startup-set systemd:gone.service remove | startup_list)
  assert_contains "$out" "ok gone.service moved to the Trash"; assert_missing "$u/gone.service"
  out=$(user_cm --json startup-set autostart:gone.desktop remove | startup_list)
  assert_contains "$out" "ok gone.desktop moved to the Trash"; assert_missing "$a/gone.desktop"
  out=$(user_cm --json restore gone.desktop | startup_list)
  assert_contains "$out" "ok gone.desktop put back"; assert_exists "$a/gone.desktop"
  # your copy that turns a system entry off is not broken, also in the terminal app (Trash would turn it back on)
  startup_entry "$a/sysgone.desktop" SysGone "zz-gone-system" "Hidden=true\n"
  out=$(user_cm --json startup | startup_list | grep sysgone)
  assert_eq "$out" "autostart:sysgone.desktop off st SysGone" "an override of a system entry is not flagged"
  out=$(in_app "SYSTEM_AUTOSTART_DIR='$sys'; load_startup 1;"' for i in "${!S_NAME[@]}"; do echo "${S_NAME[i]} ${S_ON[i]} ${S_MISS[i]:--}"; done' | grep -E '^(SysGone|Gone) ')
  assert_eq "$out" $'Gone 1 zz-gone-app\nSysGone 0 -' "terminal app: the override is not marked missing, a broken entry is"
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
  printf '#!/bin/sh\nexit 1\n' >"$HOME_DIR/.local/bin/gsettings" # no GNOME settings: no recent_files
  chmod +x "$HOME_DIR/.local/bin/gsettings"
  if ((EUID == 0)); then
    out=$(cm --json settings 2>&1); assert_contains "$out" "run this as yourself, not as root"
  fi
  out=$(user_cm --json settings | settings_list)
  assert_eq "$out" "language system
schedule off
remind off
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
download_days 90 7-3650/90
ai_history_days 30 1-3650/30
selections 2
exclusions []
done true false" "every setting with its range and default; bad values fall back to the default"
  # the desktop app changes a number → the terminal app (same file) uses it
  out=$(user_cm --json settings-set journal_days 30 | settings_list)
  assert_eq "$out" $'ok journal_days set to 30\njournal_days 30 1-365/7\ndone  ' "set a number"
  assert_contains "$(cat "$f")" $'foo=3\njournal_days=30\ntmp_days=999'
  assert_contains "$(user_cm --json items)" "Keeps the last 30 days"
  # the desktop app's welcome, once closed: saved, not one of the settings shown
  out=$(user_cm --json settings-set welcome_shown 1 | settings_list)
  assert_eq "$out" $'ok welcome_shown set to 1\nwelcome_shown 1 0-1/0\ndone  ' "the welcome is marked as seen"
  # …and the other way round: the terminal app's Settings writes the file the desktop app reads
  in_app 'load_settings; save_setting journal_mb 250'
  assert_contains "$(user_cm --json settings | settings_list)" "journal_mb 250 16-10000/100"
  assert_contains "$(cat "$f")" "journal_days=30"
  assert_contains "$(cat "$f")" "welcome_shown=1"
  [[ $(user_cm --json settings) != *welcome_shown* ]] && ok_ "welcome_shown not listed" || fail "welcome_shown is listed"
  # the desktop app's language: kept when either app saves a number, a wrong value reads as "system"
  out=$(user_cm --json settings-set language vi | settings_list)
  assert_eq "$out" $'ok language set to vi\nlanguage vi\ndone  ' "set the language"
  user_cm --json settings-set journal_days 30 >/dev/null
  in_app 'load_settings; save_setting journal_mb 250'
  assert_contains "$(cat "$f")" "language=vi"
  assert_contains "$(user_cm --json settings | settings_list)" "language vi"
  sed -i 's/^language=.*/language=fr/' "$f"
  assert_contains "$(user_cm --json settings | settings_list)" "language system"
  # wrong values are refused and change nothing
  cp "$f" "$WORK/settings.before"
  out=$(user_cm --json settings-set language xx 2>&1); assert_contains "$out" "language must be one of: system en vi"
  user_cm --json settings-set language xx >/dev/null; assert_eq "$?" 2 "exit status of a refused language"
  out=$(user_cm --json --dry-run settings-set language en | settings_list)
  assert_eq "$out" $'ok language would be set to en\nlanguage system\ndone  ' "dry run of a language"
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

test_low_disk_alert_and_scan_reminder() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/checkbin out now f=$HOME_DIR/.config/cleanmate/settings u=$HOME_DIR/.config/systemd/user
  local st=$HOME_DIR/.local/state/cleanmate log=$HOME_DIR/notify.log
  mkdir -p "$bin" "$HOME_DIR/.local/bin" "$st"
  # notify-send logs to ~/notify.log, df reads "SIZE AVAIL" of / from ~/df, systemctl --user keeps
  # enabled units as files in ~/enabled — the real ones are never run
  printf '#!/bin/sh\necho "$*" >>"$HOME/notify.log"\n' >"$bin/notify-send"
  printf '#!/bin/sh\necho "1B-blocks Avail"\ncat "$HOME/df"\n' >"$bin/df"
  printf '%s\n' '#!/bin/sh' 'echo "$*" >>"$HOME/systemctl.log"' 'shift; mkdir -p "$HOME/enabled"' \
    'case $1 in is-enabled) test -e "$HOME/enabled/$3" ;; enable) touch "$HOME/enabled/$3" ;; disable) rm -f "$HOME/enabled/$3" ;; esac' \
    >"$HOME_DIR/.local/bin/systemctl"
  chmod +x "$bin/"* "$HOME_DIR/.local/bin/systemctl"
  local BASE_PATH="$bin:$BASE_PATH"
  echo "100000000000 5000000000" >"$HOME_DIR/df" # 5 % free
  : >"$log"
  if ((EUID == 0)); then
    out=$(cm --check 2>&1); assert_contains "$out" "not as root"
    out=$(cm --json check 2>&1); assert_contains "$out" "not as root"
  fi
  # low disk alert, on by default (10 %): one notification a day; the daily timer is switched on
  out=$(user_cm --check)
  assert_contains "$out" "Low disk alert: notified, 5% free on / (below 10%)"
  assert_contains "$out" "Scan reminder: off (last scan: never)"
  assert_eq "$(grep -c 'Disk almost full' "$log")" 1 "one low disk notification"
  assert_contains "$(cat "$log")" "string:desktop-entry:com.homielab.CleanMate"
  assert_contains "$(cat "$u/cleanmate-check.timer")" "OnCalendar=daily"
  assert_contains "$(cat "$u/cleanmate-check.service")" "--check"
  assert_exists "$HOME_DIR/enabled/cleanmate-check.timer"
  out=$(user_cm --check)
  assert_contains "$out" "already notified today"
  assert_eq "$(grep -c 'Disk almost full' "$log")" 1 "no second notification within a day"
  now=$(date +%s)
  printf 'low_disk\t%s\n' $((now - 90000)) >"$st/notified.tsv" # the last one 25 hours ago
  user_cm --check >/dev/null
  assert_eq "$(grep -c 'Disk almost full' "$log")" 2 "notified again the next day"
  rm -f "$st/notified.tsv"
  out=$(user_cm --dry-run --check); assert_contains "$out" "dry run"
  assert_eq "$(grep -c 'Disk almost full' "$log")" 2 "a dry run notifies nothing"
  echo "100000000000 50000000000" >"$HOME_DIR/df"
  out=$(user_cm --check); assert_contains "$out" "Low disk alert: fine, 50% free on / (alert below 10%)"
  echo "100000000000 5000000000" >"$HOME_DIR/df"
  echo "low_disk_pct=0" >"$f"
  out=$(user_cm --check); assert_contains "$out" "Low disk alert: off (5% free on /)"
  assert_eq "$(grep -c 'Disk almost full' "$log")" 2 "threshold 0: no notification"
  # both off: the timer goes away
  assert_missing "$u/cleanmate-check.timer"; assert_missing "$u/cleanmate-check.service"
  assert_missing "$HOME_DIR/enabled/cleanmate-check.timer"
  # scan reminder: weekly, the last cleanup 8 days ago → reminded once a week
  printf 'last_time=%s\n' $((now - 8 * 86400)) >"$st/stats"
  out=$(user_cm --json settings-set remind weekly | settings_list)
  assert_eq "$out" $'ok remind set to weekly\nremind weekly\ndone  ' "set the scan reminder"
  assert_exists "$HOME_DIR/enabled/cleanmate-check.timer"
  out=$(user_cm --check)
  assert_contains "$out" "Scan reminder: notified (last scan: 8 days ago)"
  assert_contains "$(cat "$log")" "Time for a Smart Scan Your last scan was 8 days ago."
  out=$(user_cm --check); assert_contains "$out" "Scan reminder: due (last scan: 8 days ago), already reminded"
  assert_eq "$(grep -c 'Time for a Smart Scan' "$log")" 1 "one reminder a week"
  # a scan 2 days ago (either app) puts it off
  rm -f "$st/notified.tsv"
  printf 'thumbs\t0\t0\t%s\n' $((now - 2 * 86400)) >"$st/last-scan.tsv"
  out=$(user_cm --check); assert_contains "$out" "Scan reminder: weekly, last scan 2 days ago"
  assert_eq "$(grep -c 'Time for a Smart Scan' "$log")" 1 "no reminder after a recent scan"
  # the desktop app's check
  out=$(user_cm --json check low_disk remind | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "check": print(e["kind"], e["due"], e["notified"], e.get("free_pct"), e.get("every"), e.get("last_scan", 0) > 0)
    else: print(e["event"])')
  assert_eq "$out" $'low_disk False False 5 None False\nremind False False None weekly True\ndone' "--json check"
  out=$(user_cm --json check foo 2>&1); assert_contains "$out" "Unknown check: foo"
  out=$(user_cm --json settings-set remind daily 2>&1); assert_contains "$out" "remind must be one of: off weekly monthly"
  # low disk on again, reminder off: the timer stays; both off: it goes
  user_cm --json settings-set low_disk_pct 15 >/dev/null
  user_cm --json settings-set remind off >/dev/null
  assert_exists "$u/cleanmate-check.timer"
  user_cm --json settings-set low_disk_pct 0 >/dev/null
  assert_missing "$u/cleanmate-check.timer"
  assert_contains "$(cat "$HOME_DIR/systemctl.log")" "--user disable --now cleanmate-check.timer"
}

test_never_clean_exclusions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out f p d=$HOME_DIR keep=$HOME_DIR/Projects/keep x=$HOME_DIR/.config/cleanmate/exclude
  local tasks='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], e["info"])
    elif e["event"] == "setting" and e["key"] == "exclusions": print("exclusions", " ".join(p.rsplit("/", 1)[1] for p in e["value"]) or "-")
    elif e["event"] == "item": print(e["id"], e["bytes"], e["note"])
    elif e["event"] == "entry": print(e["path"].rsplit("/", 1)[1], e["movable"], e["excluded"])
    elif e["event"] == "done" and "excluded" in e: print("done", e["excluded"])
    elif e["event"] == "error": print("error", e["message"])'
  # a project you work on now and then: big files, a copy, node_modules and a target/ left alone for long
  sized "$keep/data.bin" 3000000; sized "$d/Videos/film.mkv" 2000000
  head -c 1200000 /dev/urandom >"$keep/photo.jpg"; cp "$keep/photo.jpg" "$d/Videos/photo.jpg"
  new "$keep/web/package.json"; new "$keep/web/package-lock.json"; new "$keep/web/node_modules/x/i.js"
  new "$keep/rs/Cargo.toml"; sized "$keep/rs/target/x" 10
  new "$d/code/rs/Cargo.toml"; sized "$d/code/rs/target/keep/x" 10 # an excluded folder inside target/
  sized "$d/Downloads/old.deb" 100; mkdir -p "$d/notes" "$d/Projects/a*b"
  ln -s "$d/Projects" "$d/linked"
  while IFS= read -r -d '' f; do touch -h -d "200 days ago" "$f"; done < <(find "$d" -print0)
  # add and remove, in the file both apps read; refused paths change nothing
  out=$(user_cm --json settings-set exclusions add "$keep/./" | python3 -c "$tasks")
  assert_eq "$out" $'ok added\nexclusions keep' "add a folder"
  user_cm --json settings-set exclusions add "$d/Downloads" >/dev/null
  user_cm --json settings-set exclusions add "$d/code/rs/target/keep" >/dev/null
  user_cm --json settings-set exclusions add "$d/Projects/a*b" >/dev/null
  out=$(user_cm --json settings-set exclusions add "$keep" | python3 -c "$tasks")
  assert_eq "$out" $'ok already in the list\nexclusions keep Downloads keep a*b' "added once"
  for p in "$d" "$d/" "$d/.." / "$WORK/stubs" "$d/linked" "$d/linked/keep" "$d/nope" "Projects" "$d/Videos/film.mkv"; do
    user_cm --json settings-set exclusions add "$p"
  done | python3 -c "$tasks" >"$WORK/refused"
  assert_eq "$(grep -c '^fail' "$WORK/refused")" 10 "ten paths refused"
  out=$(cat "$WORK/refused")
  assert_contains "$out" "fail Your home folder or a folder above it is too broad to exclude"
  assert_contains "$out" "fail Only folders inside your home folder can be excluded"
  assert_contains "$out" "fail Folders reached through a symbolic link can't be excluded"
  assert_contains "$out" "fail Not a folder: $d/nope"
  assert_contains "$out" "fail Not a full path: Projects"
  assert_eq "$(cat "$x")" "$keep"$'\n'"$d/Downloads"$'\n'"$d/code/rs/target/keep"$'\n'"$d/Projects/a*b" "the exclude file"
  out=$(user_cm --json --dry-run settings-set exclusions add "$d/notes" | python3 -c "$tasks")
  assert_contains "$out" "ok would be added"
  out=$(user_cm --json settings-set exclusions remove "$d/notes" 2>&1 | python3 -c "$tasks")
  assert_contains "$out" "fail Not in the list: $d/notes"
  out=$(user_cm --json settings-set exclusions drop "$d/notes" 2>&1)
  assert_contains "$out" "Usage: --json settings-set exclusions add|remove PATH"
  assert_contains "$(user_cm --json settings | python3 -c "$tasks")" "exclusions keep Downloads keep a*b"
  # the terminal app's Settings: same file
  in_app 'load_settings; exclusion_add "$HOME/notes"; exclusion_remove "$HOME/Projects/a*b"; echo "$EX_WHY"' >/dev/null
  assert_eq "$(cat "$x")" "$keep"$'\n'"$d/Downloads"$'\n'"$d/code/rs/target/keep"$'\n'"$d/notes" "terminal app adds and removes"
  printf '%s\n' "$d" / "$WORK" "relative" "$d/notes" >>"$x" # written by hand: what can't be excluded is ignored
  assert_eq "$(user_cm --json settings | python3 -c "$tasks" | grep '^exclusions')" "exclusions keep Downloads keep notes" \
    "what can't be excluded is ignored"
  # Large & Old Files, Duplicates: nothing from inside
  out=$(cm --json large --min 1000000 | large_names)
  assert_eq "$out" $'video 2000000 film.mkv\nimage 1200000 photo.jpg\ndone 2' "large files skip excluded folders"
  assert_eq "$(cm --json large --min 0 --path "$keep/web" | large_names)" "done 0" "a folder inside one: nothing"
  assert_eq "$(cm --json dupes | dupe_groups)" "done 0 0 0 0" "a copy inside an excluded folder isn't offered"
  assert_eq "$(cm --json dupes --path "$keep" | dupe_groups)" "done 0 0 0 0" "dupes inside one: nothing"
  # Space Lens: view only, the folder and the ones holding it
  out=$(cm --json lens --path "$d/Projects" | python3 -c "$tasks")
  assert_eq "$out" $'keep False True\na*b True False\ndone False' "an excluded folder is view only"
  out=$(cm --json lens | python3 -c "$tasks")
  assert_contains "$out" "Projects False True"; assert_contains "$out" "Videos True False"
  assert_contains "$(cm --json lens --path "$keep" | python3 -c "$tasks")" $'data.bin False True'
  assert_contains "$(cm --json lens --path "$keep" | python3 -c "$tasks")" "done True"
  out=$(user_cm --json trash --home-only "$keep/data.bin" "$d/Projects" | python3 -c "$tasks")
  assert_eq "$out" $'fail Excluded in Settings (Never clean)\nfail Excluded in Settings (Never clean)' "trash --home-only refuses"
  out=$(user_cm --json trash "$keep/data.bin" | python3 -c "$tasks")
  assert_eq "$out" "fail Excluded in Settings (Never clean): $keep/data.bin" "nothing moves it to the Trash"
  assert_exists "$keep/data.bin"; assert_exists "$d/Projects/keep"
  # stale node_modules, project build folders, old installers
  mkdir -p "$WORK/nodebin" && printf '#!/bin/sh\n' >"$WORK/nodebin/node" && chmod 755 "$WORK/nodebin" "$WORK/nodebin/node"
  out=$(BASE_PATH="$WORK/nodebin:$BASE_PATH" user_cm --json scan --only dev,system | python3 -c "$tasks" |
    grep -E '^(node_modules|stale_build_dirs|old_installers) ')
  assert_eq "$out" $'node_modules 0 0 projects idle for 90+ days\nstale_build_dirs 0 \nold_installers 0 ' \
    "stale node_modules, build folders and old installers skip excluded folders"
  user_cm --json settings-set exclusions remove "$keep" >/dev/null
  user_cm --json settings-set exclusions remove "$d/Downloads" >/dev/null
  out=$(BASE_PATH="$WORK/nodebin:$BASE_PATH" user_cm --json scan --only dev,system | python3 -c "$tasks" |
    grep -E '^(node_modules|stale_build_dirs|old_installers) ')
  assert_contains "$out" "node_modules"; assert_contains "$out" "1 project idle for 90+ days"
  assert_contains "$out" "old_installers 100 1 file older than 30 days"
  if ((EUID == 0)); then
    out=$(cm --json settings-set exclusions add "$d/notes" 2>&1); assert_contains "$out" "run this as yourself, not as root"
  fi
}

test_json_recent_files_and_activity() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out g=$HOME_DIR/.local/bin/gsettings log=$HOME_DIR/.local/state/cleanmate/clean.log
  mkdir -p "$HOME_DIR/.local/bin" "${log%/*}"
  # a fake gsettings keeping remember-recent-files in ~/recent
  printf '%s\n' '#!/bin/sh' 'f=$HOME/recent; [ -e "$f" ] || echo true >"$f"' \
    'case $1 in get) cat "$f" ;; set) echo "$4" >"$f" ;; esac' >"$g"
  chmod +x "$g"
  assert_contains "$(user_cm --json settings | settings_list)" $'selections 0\nrecent_files 1\nexclusions []\ndone'
  out=$(user_cm --json settings-set recent_files 0 | settings_list)
  assert_eq "$out" $'ok recent_files set to 0\nrecent_files 0\ndone  ' "stop remembering recent files"
  assert_eq "$(cat "$HOME_DIR/recent")" false "gsettings changed"
  out=$(user_cm --json --dry-run settings-set recent_files 1 | settings_list)
  assert_eq "$out" $'ok recent_files would be set to 1\nrecent_files 0\ndone  ' "dry run of recent files"
  out=$(user_cm --json settings-set recent_files 2 2>&1); assert_contains "$out" "recent_files must be 0 or 1"
  rm -f "$g"
  if ! command -v gsettings >/dev/null; then
    out=$(user_cm --json settings | settings_list)
    assert_eq "${out//recent_files/}" "$out" "no recent_files without gsettings"
    out=$(user_cm --json settings-set recent_files 1 2>&1); assert_contains "$out" "gsettings is not available"
  fi
  # the activity log, newest first
  out=$(user_cm --json activity | tail -n 1)
  assert_contains "$out" '"count":0'
  printf '%s\n' '2026-01-02 03:04:05 trash /home/x/a b' 'not a log line' '2026-01-03 10:00:00 Cleanup finished — 1.0 MB freed (dry-run=0)' >"$log"
  out=$(user_cm --json activity | python3 -c 'import sys, json, time
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "activity": print(time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["epoch"])), e["text"])
    else: print(e["event"], e.get("count"), e.get("path", "").endswith("/cleanmate/clean.log"))')
  assert_eq "$out" "2026-01-03 10:00:00 Cleanup finished — 1.0 MB freed (dry-run=0)
2026-01-02 03:04:05 trash /home/x/a b
done 2 True" "activity events, newest first"
  assert_contains "$(user_cm --json activity --limit 1 | tail -n 1)" '"count":1'
  out=$(user_cm --json activity --limit x 2>&1); assert_contains "$out" "Invalid limit: x"
}

test_bug_report_details() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local out log=$HOME_DIR/.local/state/cleanmate/clean.log long stub=$WORK/sysreport-bin
  mkdir -p "${log%/*}" "$stub"
  sysreport() { # the sysreport event as "key=value" lines, activity one per line, then the done event
    cm --json sysreport | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] != "sysreport": print(e["event"]); continue
    for k in ("version", "os", "kernel", "arch", "desktop", "install", "language", "root"): print(f"{k}={e[k]}")
    for a in e["activity"]: print("activity=" + a)
    print("body=" + e["body"])'
  }
  out=$(sysreport)
  assert_contains "$out" "version=$(cm --version | awk 'NR == 1 {print $2}')"
  assert_contains "$out" "desktop=none (no graphical session)"
  assert_contains "$out" "language=C.UTF-8; the desktop app follows the system"
  assert_contains "$out" "Recent activity: none"
  assert_contains "$out" $'\ndone'
  # personal paths and names in the log: the home folder → ~, your own files and the Trash hidden, other users'
  # folders → <user>, long lines cut
  printf -v long '%0300d' 0
  printf '%s\n' "2026-01-01 08:00:00 the oldest line, left out" \
    "2026-01-02 03:04:05 trash $HOME_DIR/Documents/My Taxes 2025.pdf" \
    "2026-01-02 03:04:06 rm -rf -- $HOME_DIR/.cache/thumbnails $HOME_DIR/.local/share/Trash/files/secret.txt" \
    "2026-01-02 03:04:07 trash /home/bob/notes.txt /media/bob/Disk/.Trash-1000 $HOME_DIR" \
    'not a log line' \
    "2026-01-02 03:04:08 json clean x failed: $long" \
    "2026-01-03 10:00:00 Cleanup finished — 1.0 MB freed (dry-run=0)" >"$log"
  out=$(sysreport)
  assert_eq "$(grep '^activity=' <<<"$out" | cut -c10-)" "2026-01-02 03:04  trash ~/(file or folder)
2026-01-02 03:04  rm -rf -- ~/.cache/thumbnails ~/.local/share/Trash/(file or folder)
2026-01-02 03:04  trash /home/<user>/notes.txt /media/<user>/Disk/.Trash-1000 ~
2026-01-02 03:04  json clean x failed: ${long:0:98}…
2026-01-03 10:00  Cleanup finished — 1.0 MB freed (dry-run=0)" "the last 5 activity lines without personal paths"
  assert_contains "$out" "Recent activity (last 5, oldest first):"
  [[ $out == *"$HOME_DIR"* || $out == *Taxes* || $out == *secret* || $out == *bob* ]] &&
    fail "the report shows a personal path: $out" || ok_ "no personal path"
  # user names: whole words, any case, 3 characters or more
  out=$(in_app 'USER=alexsmith; sr_redact_lines out "a alexsmith-x Alexsmith alexsmith alexsmithy al"; printf "%s\n" "${out[@]}"')
  assert_eq "$out" "a <user>-x <user> <user> alexsmithy al" "user names hidden as whole words"
  # how it was installed, the desktop
  assert_eq "$(in_app 'SNAP=/snap/cleanmate/12 SNAP_REVISION=12; sr_install; echo "$SR_INSTALL"')" "snap (revision 12)" "snap"
  assert_eq "$(in_app 'packaged() { true; }; dpkg-query() { echo 2.0.0-0ppa1; }; sr_install; echo "$SR_INSTALL"')" \
    "PPA (2.0.0-0ppa1)" "PPA"
  assert_eq "$(in_app 'packaged() { true; }; dpkg-query() { echo 2.0.0; }; sr_install; echo "$SR_INSTALL"')" \
    ".deb package (2.0.0)" ".deb"
  assert_eq "$(in_app 'SELF=$BIN_PATH; sr_install; echo "$SR_INSTALL"')" "cleanmate --install" "--install"
  printf '#!/bin/sh\necho "GNOME Shell 46.0"\n' >"$stub/gnome-shell"; chmod +x "$stub/gnome-shell"
  assert_eq "$(in_app "PATH=$stub:\$PATH XDG_CURRENT_DESKTOP=ubuntu:GNOME XDG_SESSION_TYPE=wayland; sr_desktop; echo \"\$SR_DESKTOP\"")" \
    "ubuntu:GNOME, GNOME 46.0, Wayland" "GNOME on Wayland"
  assert_eq "$(in_app 'DISPLAY=:0; sr_desktop; echo "$SR_DESKTOP"')" "unknown, X11" "X11 without a desktop name"
  # cm --version: the version, the same details, where to report
  out=$(cm --version)
  assert_contains "$out" $'\n\nCleanMate: '
  assert_contains "$out" $'\nInstalled with: '
  assert_contains "$out" "Report a bug: https://github.com/homielab/cleanmate-linux/issues/new?template=bug_report.yml"
  [[ $out == *"$HOME_DIR"* ]] && fail "--version shows the home folder" || ok_ "--version: no home folder"
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
    else: print(e["event"], e.get("hidden", ""))' | sed "s|$HOME_DIR/||g" | LC_ALL=C sort)
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
test_appimage_apps() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/aibin h=$HOME_DIR out keys k proc=$WORK/aiproc
  local apps=$HOME_DIR/.local/share/applications icons=$HOME_DIR/.local/share/icons
  local img=$HOME_DIR/Applications/Zqnote-1.2.3-x86_64.AppImage tool=$HOME_DIR/.local/bin/zqtool
  local desk=$apps/appimagekit_0a1b2c-Zqnote.desktop icon=$icons/hicolor/256x256/apps/zqnote.png
  app_fixtures "$bin" # apt and Flatpak apps around it
  mkdir -p "$apps" "${img%/*}" "${tool%/*}" "${icon%/*}" "$h/scripts" "$proc"
  head -c 3000 /dev/zero >"$img"
  { printf '\177ELF\002\001\001\000AI\002'; head -c 989 /dev/zero; } >"$tool" # no .AppImage name: the magic says it
  printf '#!/bin/sh\n' >"$h/scripts/zqrun.sh"
  chmod +x "$img" "$tool" "$h/scripts/zqrun.sh"
  desk "$desk" "Zqnote" "\"$img\" %U" "Icon=zqnote"
  desk "$apps/zqtool.desktop" "Zq Tool" "env ZQ=1 $tool --quiet" "Icon=$icons/zqtool.svg"
  desk "$apps/zqrun.desktop" "Zq Run" "$h/scripts/zqrun.sh" "Icon=zqshared" # a script: not an AppImage
  desk "$apps/zqother.desktop" "Zq Other" "$h/scripts/zqrun.sh --other" "Icon=zqshared"
  head -c 400 /dev/zero >"$icon"; new "$icons/zqtool.svg"; new "$icons/zqshared.png"
  mkdir -p "$h/.config/Zqnote"; head -c 2000 /dev/zero >"$h/.config/Zqnote/settings.json"
  local CLEANMATE_APP_DIRS="$apps:$HOME_DIR/sys" BASE_PATH="$bin:$BASE_PATH" CLEANMATE_PROC=$proc
  out=$(user_cm --json apps | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "app":
        print(e["id"], e["kind"], e["name"], e["bytes"], e["data_bytes"] >= 2000 if e["kind"] == "appimage" else "-",
              " ".join(x["path"] for x in e["leftovers"]))' | sed "s|$HOME_DIR/||g" | LC_ALL=C sort)
  assert_eq "$out" $'appimage:.local/bin/zqtool appimage Zq Tool 1000 False \nappimage:Applications/Zqnote-1.2.3-x86_64.AppImage appimage Zqnote 3000 True .config/Zqnote\napt:foo apt Foo 102400 - \napt:gimp apt GNU Image Manipulation Program 20480000 - .config/GIMP\nflatpak:com.spotify.Client flatpak Spotify 123000000 - .var/app/com.spotify.Client' \
    "AppImage apps listed with their file size and data; scripts and apt launchers are not AppImages"
  local id ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "trashed": print("trashed", e["app"].split("/")[-1], e["path"].split("/")[-1], e["trash"])
    elif e["event"] == "task" and e["state"] != "run": print(e["id"].split("/")[-1], e["state"], e["info"])
    elif e["event"] == "error": print("error", e["message"])
    elif e["event"] == "done" and "failed" in e: print("done", e.get("removed", e.get("restored")), e["failed"], e.get("skipped", 0))'
  id=appimage:$(in_app "urlencode_path '$img'")
  if ((EUID == 0)); then
    out=$(cm --json uninstall "$id" | python3 -c "$ev"); assert_contains "$out" "error AppImage apps are removed as you"
    assert_exists "$img"
  fi
  # running: its file is the program of a process, or the first word of its command line
  mkdir -p "$proc/4242" "$proc/5151"; ln -s "$tool" "$proc/4242/exe"; printf '%s\0--x\0' "$img" >"$proc/5151/cmdline"
  out=$(user_cm --json uninstall "$id" "appimage:$(in_app "urlencode_path '$tool'")" | python3 -c "$ev")
  assert_eq "$out" $'Zqnote-1.2.3-x86_64.AppImage skip Skipped: Zqnote-1.2.3-x86_64.AppImage is running — close it and try again\nzqtool skip Skipped: zqtool is running — close it and try again\ndone 0 0 2' \
    "running AppImage apps are skipped"
  rm -r "$proc/4242" "$proc/5151"
  out=$(user_cm --json --dry-run uninstall "$id" | python3 -c "$ev")
  assert_eq "$out" $'Zqnote-1.2.3-x86_64.AppImage ok would be uninstalled\ndone 1 0 0' "dry run"
  assert_exists "$img"; assert_exists "$desk"; assert_exists "$icon"
  out=$(user_cm --json uninstall "$id" | python3 -c "$ev")
  assert_eq "$out" $'trashed Zqnote-1.2.3-x86_64.AppImage Zqnote-1.2.3-x86_64.AppImage Zqnote-1.2.3-x86_64.AppImage\ntrashed Zqnote-1.2.3-x86_64.AppImage appimagekit_0a1b2c-Zqnote.desktop appimagekit_0a1b2c-Zqnote.desktop\ntrashed Zqnote-1.2.3-x86_64.AppImage zqnote.png zqnote.png\nZqnote-1.2.3-x86_64.AppImage ok uninstalled\ndone 1 0 0' \
    "the AppImage, its launcher and its icon go to the Trash"
  out=$(user_cm --json trash "$h/.config/Zqnote" | python3 -c "$ev") # the desktop app then trashes the ticked folders
  assert_contains "$out" "ok moved to the Trash"
  assert_missing "$img"; assert_missing "$desk"; assert_missing "$icon"; assert_missing "$h/.config/Zqnote"
  assert_exists "$tool"; assert_exists "$icons/zqtool.svg"; assert_exists "$icons/zqshared.png"; assert_exists "$apps/zqrun.desktop"
  assert_eq "$(find "$h/.local/share/Trash/files" -mindepth 1 -maxdepth 1 | wc -l)" 4 "four things in the Trash"
  out=$(user_cm --json apps | grep -c Zqnote); assert_eq "$out" 0 "gone from the list"
  keys=(); for k in "$h/.local/share/Trash/files"/*; do keys+=("${k##*/}"); done
  out=$(user_cm --json restore "${keys[@]}" | python3 -c "$ev")
  assert_contains "$out" "done 4 0 0"
  assert_exists "$img"; assert_exists "$desk"; assert_exists "$icon"; assert_exists "$h/.config/Zqnote/settings.json"
  # the terminal app: the task reports what went to the Trash, and z puts it back
  if ((EUID != 0)); then
    out=$(in_app "out=\$(task_uninstall 'appimage:${id#appimage:}:0' 2>&1) || exit 1
      printf '%s\n' \"\$out\" >\"\$HOME/task.out\"; APP_UNDO=(); task_uninstall_post x 0 0 \"\$HOME/task.out\"
      UNDO_BATCH=(\"\${APP_UNDO[@]}\"); echo \${#UNDO_BATCH[@]}; [[ -e '$img' ]] && echo still; undo_trash; echo \$UNDO_OK \$UNDO_FAILED")
    assert_eq "$out" $'3\n3 0' "terminal app: uninstall and put back"
    assert_exists "$img"; assert_exists "$desk"; assert_exists "$icon"
  fi
}

# Several apps at once: apt and Snap each in one command (one password in the
# desktop app), Flatpak as you; a running app is skipped, and one that fails
# in a batch doesn't hide the others that are gone.
test_uninstall_several_apps_at_once() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/appbatch runbin=$WORK/appbatch-run proc=$WORK/appbatch-proc out s
  app_fixtures "$bin"
  for s in vlc obs zoom; do
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=/snap/bin/%s\nX-SnapInstanceName=%s\n' "$s" "$s" "$s" >"$HOME_DIR/sys/${s}_$s.desktop"
  done
  cat >"$bin/snap" <<'EOS'
#!/bin/sh
case $1 in
  list) if [ -n "$2" ]; then ! grep -qx "$2" "$HOME/snaps-gone" 2>/dev/null; exit; fi
        printf 'Name Version Rev\nvlc 3.0 1\nobs 30 1\nzoom 6 1\n' ;;
  remove) echo "snap $*" >>"$HOME/removed.log"; shift 2
          for s; do
            [ "$s" = zoom ] && [ -f "$HOME/zoom-fails" ] && { echo "error: cannot remove \"zoom\": snap is busy" >&2; exit 1; }
            echo "$s" >>"$HOME/snaps-gone"
          done ;;
esac
EOS
  cat >"$bin/flatpak" <<'EOS'
#!/bin/sh
case $1 in
  list) printf 'com.spotify.Client\t123.0 MB\n' ;;
  ps) [ -f "$HOME/spotify-runs" ] && echo com.spotify.Client ;;
  uninstall) echo "flatpak $*" >>"$HOME/removed.log" ;;
esac
EOS
  cat >"$bin/dpkg" <<'EOS'
#!/bin/sh
case $1 in
  -L) [ "$2" = gimp ] && printf '/.\n/usr/bin/gimp-2.10\n/usr/share/gimp\n' ;;
  -S) shift; for f; do n=${f##*/}; n=${n%.desktop}; case $n in gimp|foo|busybox|gnome-control-center) echo "$n: $f" ;; esac; done ;;
  *) exit 1 ;;
esac
EOS
  printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$bin/sudo" # the password was given (pkexec in the desktop app)
  chmod +x "$bin"/*
  running_stub "$runbin" gimp-2.10
  mkdir -p "$proc/4242"
  echo '0::/user.slice/user-1000.slice/user@1000.service/app.slice/snap.vlc.vlc-6f1c.scope' >"$proc/4242/cgroup"
  echo vlc >"$proc/4242/comm"
  local CLEANMATE_APP_DIRS="$HOME_DIR/sys" BASE_PATH="$bin:$BASE_PATH" CLEANMATE_PROC=$WORK/appbatch-none
  local ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "check": print("check", e["ok"], " ".join(r["id"] + "=" + r["program"] for r in e["running"]))
    elif e["event"] == "task" and e["state"] != "run": print(e["id"], e["state"], e["info"])
    elif e["event"] == "error": print("error", e["message"])
    elif e["event"] == "done" and "removed" in e: print("done", e["removed"], e["failed"], e["skipped"])'
  out=$(cm --json uninstall --check apt:gimp snap:vlc snap:obs | python3 -c "$ev")
  assert_eq "$out" "check True " "nothing runs"
  out=$(CLEANMATE_PROC=$proc cm --json uninstall --check apt:gimp snap:vlc snap:obs | python3 -c "$ev")
  assert_eq "$out" "check True snap:vlc=vlc" "a snap runs: a process in its cgroup"
  out=$(BASE_PATH="$runbin:$BASE_PATH" cm --json uninstall --check apt:gimp snap:obs | python3 -c "$ev")
  assert_eq "$out" "check True apt:gimp=gimp-2.10" "an apt app runs: a command of its package"
  out=$(CLEANMATE_PROC=$proc cm --json uninstall apt:gimp snap:vlc snap:obs snap:zoom | python3 -c "$ev")
  assert_eq "$out" $'snap:vlc skip Skipped: vlc is running — close it and try again\napt:gimp ok uninstalled\nsnap:obs ok uninstalled\nsnap:zoom ok uninstalled\ndone 3 0 1' \
    "the running snap skipped, the others removed"
  assert_eq "$(cat "$HOME_DIR/removed.log")" $'apt-get purge -y gimp\nsnap remove --purge obs zoom' "one apt and one snap command for all of them"
  rm -- "$HOME_DIR/removed.log" "$HOME_DIR/snaps-gone"
  touch "$HOME_DIR/zoom-fails"
  out=$(cm --json uninstall snap:obs snap:zoom snap:vlc | python3 -c "$ev")
  assert_eq "$out" $'snap:obs ok uninstalled\nsnap:zoom fail error: cannot remove "zoom": snap is busy\nsnap:vlc ok uninstalled\ndone 2 1 0' \
    "a failed batch: what is gone counts as removed, the app at fault gets its own error, the others are retried"
  assert_eq "$(cat "$HOME_DIR/removed.log")" $'snap remove --purge obs zoom vlc\nsnap remove --purge zoom\nsnap remove --purge vlc' \
    "after a failed batch, each app still installed is removed on its own in the same run"
  rm -- "$HOME_DIR/removed.log"
  touch "$HOME_DIR/spotify-runs"
  out=$(user_cm --json uninstall flatpak:com.spotify.Client | python3 -c "$ev")
  assert_eq "$out" $'flatpak:com.spotify.Client skip Skipped: com.spotify.Client is running — close it and try again\ndone 0 0 1' \
    "a running Flatpak app is skipped"
  assert_missing "$HOME_DIR/removed.log"
}

# Reset: the app stays, its data in your home goes to the Trash and comes back
# with restore; a Flatpak app's .var folder and a snap's ~/snap folder only in
# part, a running app is refused.
test_reset_app() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/resetbin proc=$WORK/resetproc h=$HOME_DIR out keys k
  app_fixtures "$bin"
  printf '[Desktop Entry]\nType=Application\nName=VLC\nExec=/snap/bin/vlc\nX-SnapInstanceName=vlc\n' >"$h/sys/vlc_vlc.desktop"
  cat >"$bin/snap" <<'EOS'
#!/bin/sh
case $1 in list) printf 'Name Version Rev\nvlc 3.0 42\n' ;; remove) echo "snap $*" >>"$HOME/removed.log" ;; esac
EOS
  cat >"$bin/flatpak" <<'EOS'
#!/bin/sh
case $1 in
  list) printf 'com.spotify.Client\t123.0 MB\n' ;;
  ps) [ -f "$HOME/spotify-runs" ] && echo com.spotify.Client ;;
  uninstall) echo "flatpak $*" >>"$HOME/removed.log" ;;
esac
EOS
  chmod +x "$bin/snap" "$bin/flatpak"
  new "$h/.cache/gimp/thumbs"; new "$h/.local/state/gimp/session"; mkdir -p "$h/.local/share/gimp" # empty: left alone
  new "$h/.config/other/keep"
  local fp=$h/.var/app/com.spotify.Client
  new "$fp/config/prefs"; new "$fp/data/db"; new "$fp/.ld.so/keep"
  new "$h/snap/vlc/42/.config/vlcrc"; new "$h/snap/vlc/41/.config/vlcrc"; new "$h/snap/vlc/common/c"
  ln -s 42 "$h/snap/vlc/current"
  mkdir -p "$proc/4242"
  echo '0::/user.slice/user-1000.slice/user@1000.service/app.slice/snap.vlc.vlc-6f1c.scope' >"$proc/4242/cgroup"
  echo vlc >"$proc/4242/comm"
  local CLEANMATE_APP_DIRS="$h/sys" BASE_PATH="$bin:$BASE_PATH" CLEANMATE_PROC=$WORK/resetproc-none
  local ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "data": print("data", e["path"], e["bytes"] > 0)
    elif e["event"] == "task": print(e["id"], e["state"], e["info"])
    elif e["event"] == "error": print("error", e["message"])
    elif e["event"] == "done": print("done", " ".join(k + "=" + str(v > 0 if k in ("bytes", "freed") else v) for k, v in e.items() if k != "event"))'
  out=$(cm --json reset --check apt:gimp | python3 -c "$ev" | sed "s|$h/||g" | sort)
  assert_eq "$out" $'data .cache/gimp True\ndata .config/GIMP True\ndata .local/state/gimp True\ndone count=3 bytes=True running=' \
    "apt app: its folders in .config, .cache and .local/state; not empty ones, not other apps'"
  out=$(cm --json reset --check flatpak:com.spotify.Client | python3 -c "$ev" | sed "s|$h/||g" | sort)
  assert_eq "$out" $'data .var/app/com.spotify.Client/cache True\ndata .var/app/com.spotify.Client/config True\ndata .var/app/com.spotify.Client/data True\ndone count=3 bytes=True running=' \
    "Flatpak app: cache, config and data of its .var folder"
  out=$(cm --json reset --check snap:vlc | python3 -c "$ev" | sed "s|$h/||g" | sort)
  assert_eq "$out" $'data snap/vlc/42 True\ndata snap/vlc/common True\ndone count=2 bytes=True running=' \
    "snap: the current revision and common, not older revisions"
  out=$(cm --json reset --check apt:busybox | python3 -c "$ev"); assert_eq "$out" "error Not an app CleanMate can reset: apt:busybox" "part of Ubuntu refused"
  out=$(CLEANMATE_PROC=$proc cm --json reset --check snap:vlc | python3 -c "$ev" | tail -n 1)
  assert_eq "$out" "done count=2 bytes=True running=vlc" "check says the snap runs"
  out=$(CLEANMATE_PROC=$proc user_cm --json reset snap:vlc | python3 -c "$ev")
  assert_eq "$out" "error Close vlc first: resetting an app while it runs can lose what is open in it" "a running app is not reset"
  assert_exists "$h/snap/vlc/42/.config/vlcrc"
  touch "$h/spotify-runs"
  out=$(user_cm --json reset flatpak:com.spotify.Client | python3 -c "$ev"); assert_contains "$out" "error Close com.spotify.Client first"
  rm -- "$h/spotify-runs"
  if ((EUID == 0)); then
    out=$(cm --json reset apt:gimp | python3 -c "$ev"); assert_eq "$out" "error Refusing to reset an app as root: its data is in your home" "never as root"
  fi
  out=$(user_cm --json --dry-run reset apt:gimp | python3 -c "$ev" | tail -n 1)
  assert_eq "$out" "done moved=3 failed=0 freed=True" "dry run"
  assert_exists "$h/.config/GIMP/2.10/gimprc"
  out=$(user_cm --json reset apt:gimp "$h/.config/other" | python3 -c "$ev" | sed "s|$h/||g")
  assert_eq "$out" "error Not a data folder of apt:gimp: .config/other" "only the app's own folders"
  out=$(user_cm --json reset apt:gimp "$h/.config/GIMP" "$h/.cache/gimp" | python3 -c "$ev" | sed "s|$h/||g")
  assert_eq "$out" $'.config/GIMP ok moved to the Trash\n.cache/gimp ok moved to the Trash\ndone moved=2 failed=0 freed=True' "the ticked folders only"
  assert_missing "$h/.config/GIMP"; assert_missing "$h/.cache/gimp"; assert_exists "$h/.local/state/gimp/session"
  out=$(user_cm --json reset flatpak:com.spotify.Client | python3 -c "$ev" | tail -n 1); assert_eq "$out" "done moved=3 failed=0 freed=True" "Flatpak reset"
  assert_missing "$fp/cache"; assert_missing "$fp/config"; assert_missing "$fp/data"; assert_exists "$fp/.ld.so/keep"
  out=$(user_cm --json reset snap:vlc | python3 -c "$ev" | tail -n 1); assert_eq "$out" "done moved=2 failed=0 freed=True" "snap reset"
  assert_missing "$h/snap/vlc/42"; assert_missing "$h/snap/vlc/common"; assert_exists "$h/snap/vlc/41/.config/vlcrc"
  assert_missing "$h/removed.log" # the apps stay installed
  assert_exists "$h/.config/other/keep"; assert_exists "$h/sys/gimp.desktop"
  out=$(user_cm --json apps | python3 -c 'import sys, json
print(" ".join(sorted(json.loads(l)["id"] for l in sys.stdin if json.loads(l)["event"] == "app")))')
  assert_eq "$out" "apt:foo apt:gimp flatpak:com.spotify.Client snap:vlc" "every app still listed"
  keys=(); for k in "$h/.local/share/Trash/files"/*; do keys+=("${k##*/}"); done
  assert_eq "${#keys[@]}" 7 "seven folders in the Trash"
  out=$(user_cm --json restore "${keys[@]}" | python3 -c "$ev" | tail -n 1); assert_eq "$out" "done restored=7 failed=0" "restore puts them back"
  assert_exists "$h/.config/GIMP/2.10/gimprc"; assert_exists "$fp/config/prefs"; assert_exists "$h/snap/vlc/42/.config/vlcrc"
  assert_exists "$h/snap/vlc/common/c"
  # the terminal app: r resets the app under the cursor, z puts it back
  if ((EUID != 0)); then
    out=$(in_app "ASSUME_YES=1; toast() { printf '%s\n' \"\$1\"; }; load_apps() { :; }; apps_view() { :; }
      A_SRC=(flatpak) A_ID=(com.spotify.Client) A_NAME=(Spotify) A_PATHS=('$fp')
      reset_app 0; [[ -e '$fp/config' ]] && echo still; echo \${#UNDO_BATCH[@]}; undo_trash; echo \$UNDO_OK \$UNDO_FAILED" |
      sed 's/\x1b\[[0-9;]*m//g')
    assert_eq "$out" $'✔ Reset Spotify: moved 3 folders to Trash — z puts them back\n3\n3 0' "terminal app: reset and put back"
    assert_exists "$fp/config/prefs"
  fi
}

test_leftovers_of_removed_apps() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local bin=$WORK/leftbin h=$HOME_DIR out pid key d
  mkdir -p "$bin" "$h/apps" "$h/tools/bin" "$h/.local/bin"
  cat >"$bin/dpkg-query" <<'EOS'
#!/bin/sh
case "$*" in *Status-Abbrev*) printf 'ii  zqkeeppkg-stable\nrc  zqslack-desktop\nii  libzqfoobar-2.0-0\n' ;; esac
EOS
  printf '#!/bin/sh\n[ "$1" = list ] && printf "org.keep.Zqkeep\\n"\nexit 0\n' >"$bin/flatpak"
  printf '#!/bin/sh\n[ "$1" = list ] && printf "Name  Version  Rev\\nzqkeepsnap  1.0  1\\n"\nexit 0\n' >"$bin/snap"
  printf '#!/bin/sh\n' >"$h/tools/bin/zqmytool"; printf '#!/bin/sh\n' >"$h/.local/bin/zqrun"
  chmod +x "$bin"/* "$h/tools/bin/zqmytool" "$h/.local/bin/zqrun"
  printf 'export PATH="$HOME/tools/bin:$PATH" # my tools\n' >"$h/.profile"
  printf '[Desktop Entry]\nType=Application\nName=Zq Editor\nExec=/opt/zq/bin/zq-editor-bin %%F\n' >"$h/apps/zqed.desktop"
  # gone: a Flatpak app, a snap, an apt package removed without --purge, folders nothing claims
  for d in .var/app/org.gone.Zqapp snap/zqgonesnap .config/Zqslack .local/share/zqobsidian .local/state/zqteams .cache/zqspotifyd \
    .var/app/org.keep.Zqkeep .var/app/org.deployed.Zqdep snap/zqkeepsnap snap/bin .config/zqkeeppkg .config/zqfoobar \
    .config/zqmytool .config/ZqEditor .config/zqrun-data .config/dconf .local/share/fonts .local/share/keyrings \
    .cache/huggingface .config/zqprogs .config/zqopen .config/.zqhidden; do
    new "$h/$d/data"
  done
  mkdir -p "$h/.local/share/flatpak/app/org.deployed.Zqdep" "$h/elsewhere"
  ln -s "$h/elsewhere" "$h/.config/zqlink"
  printf '#!/bin/sh\n' >"$h/.config/zqprogs/run"; chmod +x "$h/.config/zqprogs/run"
  find "$h/.var" "$h/snap" "$h/.config" "$h/.local/share" "$h/.local/state" "$h/.cache" -mindepth 1 \
    -exec touch -h -d "200 days ago" {} +
  new "$h/.config/zqrecent/data" # in use lately
  sh -c 'exec sleep 60' <"$h/.config/zqopen/data" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(CLEANMATE_APP_DIRS=$h/apps BASE_PATH="$bin:$BASE_PATH" cm --json apps | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "leftover": print(e["kind"], e["path"], e["name"], e["bytes"] > 0)' | sed "s|$h/||" | sort)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "flatpak .var/app/org.gone.Zqapp org.gone.Zqapp True
folder .cache/zqspotifyd zqspotifyd True
folder .config/Zqslack Zqslack True
folder .local/share/zqobsidian zqobsidian True
folder .local/state/zqteams zqteams True
snap snap/zqgonesnap zqgonesnap True" "only folders of removed apps are listed"
  # a snap or Flatpak list that can't be read: nothing of theirs is offered
  printf '#!/bin/sh\nexit 1\n' >"$bin/snap"; printf '#!/bin/sh\nexit 1\n' >"$bin/flatpak"
  out=$(CLEANMATE_APP_DIRS=$h/apps BASE_PATH="$bin:$BASE_PATH" cm --json apps | grep -c '"kind":"\(snap\|flatpak\)"')
  assert_eq "$out" "0" "no snap or Flatpak folders when their lists fail"
  # to the Trash and back
  out=$(user_cm --json trash --home-only "$h/.config/Zqslack" | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "task": print(e["state"], e["trash"])')
  assert_eq "${out%% *}" "ok" "leftover moved to the Trash"
  key=${out#ok }
  assert_missing "$h/.config/Zqslack"
  user_cm --json restore "$key" >/dev/null
  assert_exists "$h/.config/Zqslack/data"
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
    assert_contains "$out" "the box above the list ticks only the apps shown"
    assert_contains "$out" "ticks stay after the search; the box shows some"
    assert_contains "$out" "more than one app ticked: the panel lists each one"
    ((EUID == 0)) || assert_contains "$out" "one password for the apt and Snap apps together"
    ((EUID == 0)) || assert_contains "$out" "the running app says why it was skipped"
    ((EUID == 0)) || assert_contains "$out" "Restore folders in the toast puts the folders of all the removed apps back"
    ((EUID == 0)) || assert_contains "$out" "Reset needs exactly one app ticked"
    ((EUID == 0)) || assert_contains "$out" "a running app is not reset, the toast says which program"
    ((EUID == 0)) || assert_contains "$out" "Reset moves only the ticked folder to the Trash; the app stays"
    ((EUID == 0)) || assert_contains "$out" "Restore after Reset puts the folder back"
    ((EUID == 0)) || assert_contains "$out" "a changed number and switch are saved for the terminal app"
    ((EUID == 0)) || assert_contains "$out" "turning automatic cleaning on enables the weekly timer"
    ((EUID == 0)) || assert_contains "$out" "picking Tiếng Việt saves it and offers a restart"
    ((EUID == 0)) || assert_contains "$out" "Restart starts CleanMate again with the same arguments, then quits"
    ((EUID == 0)) || assert_contains "$out" "back to the language in use: no restart needed"
    assert_contains "$out" "unticking one: the item box is half-ticked and the size shows selected / total"
    ((EUID == 0)) || assert_contains "$out" "Clean removes only the ticked image"
    ((EUID == 0)) || assert_contains "$out" "a clean that deleted everything for good offers no Undo"
    assert_contains "$out" "the confirmation says an item that goes to the Trash can be undone"
    ((EUID == 0)) || assert_contains "$out" "Undo puts the installer back from the Trash and the scan lists it again"
    assert_contains "$out" "a missing tool locks the row with why"
    ((EUID == 0)) || assert_contains "$out" "Rebuild font cache runs as you; the log shows its output, then done"
    assert_contains "$out" "Update everything asks for the password once"
    assert_contains "$out" "the app opens on System Overview"
    assert_contains "$out" "a disk over 90 % full gets the warning colour"
    assert_contains "$out" "the page shows in under 300 ms once the engine answers"
    assert_contains "$out" "Refresh shows what was freed: 30 days, in total, the last cleanup"
    assert_contains "$out" "freed per day: 30 days, a bar for yesterday's cleanup"
    assert_contains "$out" "Refresh doesn't count up again"
    assert_contains "$out" "with new settings the welcome is shown"
    assert_contains "$out" "step 2 opens the terminal app"
    assert_contains "$out" "step 3 ends with Start"
    ((EUID == 0)) || assert_contains "$out" "Settings reads back what the welcome saved"
    ((EUID == 0)) || assert_contains "$out" "Start closes it and saves welcome_shown"
    ((EUID == 0)) || assert_contains "$out" "closing it from the menu changes no setting"
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
  assert_eq "$(dpkg-deb --field "$deb" Version)" "$(cm --version | awk 'NR == 1 {print $2}')" "package version = script VERSION"
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

# LM Studio: a models folder chosen in its settings is listed, and its
# headless daemon (llmster) locks the models like the app does.
test_lm_studio_downloads_folder_and_daemon_lock() {
  fresh_home
  local own=$HOME_DIR/AI/lms out id bin=$WORK/lmsbin
  old "$own/pub/qwen-4b/model.gguf"
  mkdir -p "$HOME_DIR/.lmstudio"
  printf '{"downloadsFolder": "%s"}\n' "$own" >"$HOME_DIR/.lmstudio/settings.json"
  out=$(cm --scan --only models 2>&1)
  assert_contains "$out" "LM Studio — pub/qwen-4b"
  id=$(in_app 'for i in "${ITEM_IDS[@]}"; do [[ ${ITEM_LABEL[$i]} == "LM Studio — pub/qwen-4b" ]] && echo "$i"; done')
  [[ -n $id ]] && ok_ "custom folder model registered" || fail "no item for the custom folder"
  running_stub "$bin" llmster
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --scan --only models 2>&1)
  assert_contains "$out" "close llmster first"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean "$id" 2>&1)
  assert_contains "$out" "\"id\":\"$id\",\"state\":\"skip\""
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app "ASSUME_YES=1; model_precheck $id" 2>&1) && fail "--yes did not skip"
  assert_contains "$out" "LM Studio is running"
  assert_exists "$own/pub/qwen-4b/model.gguf"
  running_stub "$bin" films "LM Studio Helpe"
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app "lockedby_model $id")
  [[ $out == "LM Studio Helpe" ]] && ok_ "app helper locks, 'films' does not" || fail "lock matched: '$out'"
  # a wrong type or a symlinked folder or settings file is ignored
  printf '{"downloadsFolder": 42}\n' >"$HOME_DIR/.lmstudio/settings.json"
  out=$(cm --scan --only models 2>&1)
  [[ $out == *qwen-4b* ]] && fail "non-string downloadsFolder used" || ok_ "wrong type ignored"
  ln -s "$own" "$HOME_DIR/AI/link"
  printf '{"downloadsFolder": "%s"}\n' "$HOME_DIR/AI/link" >"$HOME_DIR/AI/s.json"
  rm "$HOME_DIR/.lmstudio/settings.json"; ln -s "$HOME_DIR/AI/s.json" "$HOME_DIR/.lmstudio/settings.json"
  out=$(cm --scan --only models 2>&1)
  [[ $out == *qwen-4b* ]] && fail "symlinked settings used" || ok_ "symlinked settings ignored"
  rm "$HOME_DIR/.lmstudio/settings.json"; cp "$HOME_DIR/AI/s.json" "$HOME_DIR/.lmstudio/settings.json"
  out=$(cm --scan --only models 2>&1)
  [[ $out == *qwen-4b* ]] && fail "symlinked downloadsFolder used" || ok_ "symlinked folder ignored"
  assert_exists "$HOME_DIR/.lmstudio/settings.json"
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

test_gpu_shader_cache_item() {
  fresh_home
  local h=$HOME_DIR out
  old "$h/.cache/mesa_shader_cache/ab/x"; old "$h/.cache/radv_builtin_shaders64/y"; old "$h/.nv/GLCache/z"
  old "$h/.cache/qtshadercache-x86_64/q"; old "$h/mydir/mesa_shader_cache/m"; old "$WORK/outside/mesa_shader_cache/o"
  printf 'export MESA_SHADER_CACHE_DIR=$HOME/mydir\nexport __GL_SHADER_DISK_CACHE_PATH=%s\n' "$WORK/outside" >"$h/.bashrc"
  out=$(cm --scan --only apps 2>&1)
  assert_contains "$out" "GPU shader cache"
  out=$(cm --json details gpu_shader_cache 2>&1)
  assert_contains "$out" "radv_builtin_shaders64"
  assert_contains "$out" ".nv/GLCache"
  assert_contains "$out" "mydir/mesa_shader_cache"
  [[ $out == *outside* ]] && fail "a folder outside home was listed" || ok_ "outside home ignored"
  cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_exists "$h/.cache/mesa_shader_cache/ab/x" # not selected by default
  select_only gpu_shader_cache
  running_stub "$WORK/gpustub" lutris
  BASE_PATH="$WORK/gpustub:$BASE_PATH" cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_exists "$h/.cache/mesa_shader_cache/ab/x"
  cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_missing "$h/.cache/mesa_shader_cache/ab"
  assert_missing "$h/.cache/radv_builtin_shaders64/y"
  assert_missing "$h/.nv/GLCache/z"
  assert_missing "$h/.cache/qtshadercache-x86_64/q"
  assert_missing "$h/mydir/mesa_shader_cache/m"
  assert_exists "$h/.cache/mesa_shader_cache"
  assert_exists "$WORK/outside/mesa_shader_cache/o"
}

test_game_launcher_caches() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/glstub x=$HOME_DIR/.var/app
  local list='import json,sys
for l in sys.stdin:
    e = json.loads(l)
    if e.get("event") == "entry": print(e["id"], e["bytes"], e["selected"], e["label"])'
  old "$h/.cache/winetricks/vcrun2019/vc_redist.x64.exe"; old "$h/.cache/wine/wine-mono-9.0.0-x86.msi"
  old "$h/.cache/lutris/banners/game.jpg"; old "$h/.cache/lutris/runtime/dxvk/d3d11.dll" 1
  old "$x/com.heroicgameslauncher.hgl/cache/blob"
  old "$h/.wine/drive_c/windows/system32/a.dll"; old "$h/Games/foo/drive_c/save.dat"; old "$h/.config/heroic/config.json"
  out=$(cm --json details game_launcher_caches | python3 -c "$list")
  assert_eq "$(grep -c '^/' <<<"$out")" "4" "four cache folders"
  assert_contains "$out" "winetricks"; assert_contains "$out" "Wine (Gecko, Mono)"
  assert_contains "$out" "Lutris: banners"; assert_contains "$out" "Heroic (Flatpak)"
  [[ $out == *runtime* || $out == *drive_c* || $out == *.wine* ]] && fail "a prefix or runtime was listed" || ok_ "prefixes and runtime not listed"
  [[ $(grep -c ' True ' <<<"$out") == 4 ]] && ok_ "all ticked" || fail "entries not ticked: $out"
  running_stub "$bin" winetricks
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --clean --yes --only user 2>&1 </dev/null)
  assert_contains "$out" "Skipping Game launcher caches: close winetricks first."
  assert_exists "$h/.cache/winetricks/vcrun2019/vc_redist.x64.exe"
  local e1; e1=$(cm --json details game_launcher_caches | python3 -c "$list" | grep winetricks | cut -d' ' -f1)
  user_cm --json clean game_launcher_caches --entries "$e1" >/dev/null 2>&1
  assert_missing "$h/.cache/winetricks/vcrun2019"; assert_exists "$h/.cache/winetricks"
  assert_exists "$h/.cache/wine/wine-mono-9.0.0-x86.msi"
  user_cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_missing "$h/.cache/wine/wine-mono-9.0.0-x86.msi"; assert_missing "$h/.cache/lutris/banners/game.jpg"
  assert_missing "$x/com.heroicgameslauncher.hgl/cache/blob"
  assert_exists "$h/.cache/lutris/runtime/dxvk/d3d11.dll"; assert_exists "$h/.wine/drive_c/windows/system32/a.dll"
  assert_exists "$h/Games/foo/drive_c/save.dat"; assert_exists "$h/.config/heroic/config.json"
}

test_search_index_items() {
  fresh_home
  local nt; nt=$(path_without localsearch3 tracker3 balooctl6 balooctl) # the branch without the tools
  local h=$HOME_DIR out bin=$WORK/idxbin
  old "$h/.cache/tracker3/files/meta.db" 1; old "$h/.local/share/baloo/index"; old "$h/.config/baloofilerc"
  out=$(cm --scan --only user 2>&1)
  assert_contains "$out" "Desktop search index (GNOME Tracker)"
  assert_contains "$out" "Desktop search index (KDE Baloo)"
  BASE_PATH=$nt cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_exists "$h/.local/share/baloo/index" # not selected by default
  select_only tracker_index baloo_index
  BASE_PATH=$nt cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$h/.local/share/baloo/index" # never reset unattended by the timer
  # no tool: the folder is emptied, but not while the indexer runs
  running_stub "$WORK/idxrun" baloo_file
  BASE_PATH="$WORK/idxrun:$nt" cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_exists "$h/.local/share/baloo/index"
  assert_missing "$h/.cache/tracker3/files"
  BASE_PATH=$nt cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_missing "$h/.local/share/baloo/index"
  assert_exists "$h/.config/baloofilerc"
  # with the tool: its own reset command runs, also while the indexer runs
  old "$h/.cache/tracker3/files/meta.db" 1; old "$h/.local/share/baloo/index"
  mkdir -p "$bin"
  for c in tracker3 balooctl6; do printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$c" "$WORK" >"$bin/$c"; chmod 755 "$bin/$c"; done
  cp "$WORK/idxrun/pgrep" "$bin/pgrep"
  BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only user >/dev/null 2>&1 </dev/null
  assert_contains "$(<"$WORK/calls")" "tracker3 reset --filesystem"
  assert_contains "$(<"$WORK/calls")" "balooctl6 purge"
  assert_exists "$h/.local/share/baloo/index" # left to the tool
  rm -r "$h/.cache/tracker3" "$h/.local/share/baloo"
  out=$(cm --scan --only user 2>&1)
  [[ $out == *"Desktop search index"* ]] && fail "listed without its folder" || ok_ "hidden without its folder"
}

test_cloud_sync_client_caches() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/cloudbin
  mkdir -p "$h/Dropbox" "$h/Work Dropbox"
  new "$h/.dropbox/logs/a.log"
  old "$h/Dropbox/.dropbox.cache/2026-01-01_old/f"; touch -d '200 days ago' "$h/Dropbox/.dropbox.cache/2026-01-01_old"
  old "$h/Dropbox/.dropbox.cache/2026-02-01_busy/f"; new "$h/Dropbox/.dropbox.cache/2026-02-01_busy/fresh"
  old "$h/Work Dropbox/.dropbox.cache/w/f"; touch -d '200 days ago' "$h/Work Dropbox/.dropbox.cache/w"
  new "$h/Dropbox/keep.txt"; new "$h/.dropbox/instance1/config.dbx"; new "$WORK/outside/.dropbox.cache/x"; old "$(dirname "$h")/outside2/.dropbox.cache/y"
  printf '{"personal":{"path":"%s/Dropbox"},"business":{"path":"%s/Work Dropbox"},"other":{"path":"%s/outside"},"up":{"path":"%s/../outside2"}}' \
    "$h" "$h" "$WORK" "$h" >"$h/.dropbox/info.json"
  new "$h/.cache/Nextcloud/c"; new "$h/.local/share/Nextcloud/nextcloud.log.1"; new "$h/.local/share/Nextcloud/nextcloud.cfg"
  new "$h/.cache/ownCloud/c"; new "$h/.local/share/data/Mega Limited/MEGAsync/logs/m.log"
  new "$h/.local/share/data/Mega Limited/MEGAsync/MEGAsync.cfg"
  out=$(cm --scan --only apps 2>&1)
  assert_contains "$out" "Dropbox — cache & logs"; assert_contains "$out" "Nextcloud & ownCloud — cache & logs"
  assert_contains "$out" "MEGAsync — logs"
  # a running client: skipped
  running_stub "$bin" dropbox megasync
  select_only cloud_dropbox cloud_nextcloud cloud_mega
  BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_exists "$h/.dropbox/logs/a.log"; assert_exists "$h/.local/share/data/Mega Limited/MEGAsync/logs/m.log"
  assert_missing "$h/.cache/Nextcloud/c"; assert_missing "$h/.local/share/Nextcloud/nextcloud.log.1"
  assert_missing "$h/.cache/ownCloud/c"; assert_exists "$h/.local/share/Nextcloud/nextcloud.cfg"
  # dry-run deletes nothing
  cm --clean --yes --dry-run --only apps >/dev/null 2>&1 </dev/null
  assert_exists "$h/Dropbox/.dropbox.cache/2026-01-01_old/f"
  cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_missing "$h/.dropbox/logs/a.log"; assert_missing "$h/.local/share/data/Mega Limited/MEGAsync/logs/m.log"
  assert_missing "$h/Dropbox/.dropbox.cache/2026-01-01_old"; assert_missing "$h/Work Dropbox/.dropbox.cache/w"
  assert_exists "$h/Dropbox/.dropbox.cache/2026-02-01_busy/fresh" # changed lately: may still be uploading
  assert_exists "$h/Dropbox/keep.txt"; assert_exists "$h/.dropbox/instance1/config.dbx"; assert_exists "$h/.dropbox/info.json"
  assert_exists "$h/.local/share/data/Mega Limited/MEGAsync/MEGAsync.cfg"; assert_exists "$WORK/outside/.dropbox.cache/x"; assert_exists "$(dirname "$h")/outside2/.dropbox.cache/y"
  rm -r "$(dirname "$h")/outside2"
}

test_build_tool_caches_xdg_root() {
  fresh_home
  local h=$HOME_DIR out bad
  # XDG_CACHE_HOME unset: no item gets a path at the disk root (/zig, /pre-commit, …)
  out=$(in_app 'for i in "${ITEM_IDS[@]}"; do printf "%s\n" "${ITEM_PATHS[$i]-}" "${LIST_ROOTS[$i]-}"; done')
  bad=$(grep -vE "^($h/|$)" <<<"$out" | grep -E '^/(deno|zig|bazel|ccache|sccache|pypoetry|pipx|pre-commit|mesa_shader_cache|helm|cabal|coursier|composer)' || true)
  assert_eq "$bad" "" "no cache path at the disk root"
  # XDG_CACHE_HOME inside HOME: its tool folders are kept
  printf 'export XDG_CACHE_HOME="$HOME/xc"\n' >"$h/.bashrc"
  out=$(in_app 'for i in "${ITEM_IDS[@]}"; do printf "%s\n" "${ITEM_PATHS[$i]-}" "${LIST_ROOTS[$i]-}"; done')
  for f in deno/remote zig/o "bazel/_bazel_$(id -un)/cache" ccache/tmp sccache/0 pypoetry/cache pipx pre-commit mesa_shader_cache helm cabal/packages coursier composer; do
    assert_contains "$out" "$h/xc/$f"
  done
}
test_build_tool_caches() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/btbin c=$HOME_DIR/.cache
  new "$c/deno/remote/https/a"; new "$c/deno/npm/n"; new "$c/deno/gen/g"; new "$c/deno/location_data/ls/data"
  new "$c/zig/o/x"; new "$c/zig/z/y"; new "$c/zig/keep-me"
  new "$c/bazel/_bazel_$(id -un)/cache/repos/r"; new "$c/bazel/_bazel_$(id -un)/install/i"
  new "$c/bazel/_bazel_$(id -un)/abc123/execroot/out"
  new "$c/ccache/a/b"; new "$c/ccache/tmp/t"; new "$c/ccache/ccache.conf"; new "$h/.ccache/f/z"
  new "$c/sccache/0/s"; new "$h/.nuget/packages/pkg/1.0/lib.dll"; new "$h/.nuget/v3-cache/v"; new "$h/.local/share/NuGet/http-cache/h"
  new "$c/pypoetry/cache/c"; new "$c/pypoetry/artifacts/a"; new "$c/pypoetry/virtualenvs/proj/bin/python"
  new "$c/pre-commit/repoabc/hook"; new "$c/pre-commit/db.db"; new "$h/mine/README"; new "$h/mine/repo-notes/n"; new "$c/pre-commit/other/keep"
  new "$c/pipx/e/run"; new "$h/.local/share/pipx/venvs/tool/bin/t"; new "$h/.local/pipx/.cache/e2/r"
  # a wrong value must not reach anything outside the tool's cache folders
  new "$h/mine/documents/important"; new "$h/mine/o/ok"
  printf 'export DENO_DIR="$HOME/mine"\nexport ZIG_GLOBAL_CACHE_DIR="$HOME/mine"\nexport CCACHE_DIR="$HOME/mine"\nexport PRE_COMMIT_HOME="$HOME/mine"\n' >"$h/.bashrc"
  out=$(cm --scan --only dev 2>&1)
  for n in "Deno cache" "Zig cache" "Bazel cache" "ccache cache" "sccache cache" "NuGet cache" "Poetry cache" "pre-commit cache" "pipx run cache"; do
    assert_contains "$out" "$n"
  done
  # deno and a Bazel server (a java process) run; a file open in a folder keeps that folder
  running_stub "$bin" deno "_bazel_$(id -un)"
  sleep 60 3>>"$c/zig/o/x" & holder=$!
  sleep 60 3>>"$c/pre-commit/repoabc/hook" & holder2=$!
  select_only deno_cache zig_cache bazel_cache ccache_cache sccache_cache nuget_cache poetry_cache precommit_cache pipx_cache
  BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  assert_exists "$c/deno/remote/https/a"; assert_exists "$c/bazel/_bazel_$(id -un)/cache/repos/r"
  assert_exists "$c/zig/o/x"; assert_exists "$c/pre-commit/repoabc/hook"; assert_missing "$c/zig/z/y"
  kill "$holder" "$holder2" 2>/dev/null; wait "$holder" "$holder2" 2>/dev/null
  cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  for f in deno/remote/https/a deno/npm/n deno/gen/g zig/o/x zig/z/y "bazel/_bazel_$(id -un)/cache/repos/r" "bazel/_bazel_$(id -un)/install/i" \
    ccache/a/b ccache/tmp/t sccache/0/s pypoetry/cache/c pypoetry/artifacts/a pre-commit/repoabc pre-commit/db.db pipx/e/run; do
    assert_missing "$c/$f"
  done
  for f in .ccache/f/z .nuget/v3-cache/v .local/share/NuGet/http-cache/h .local/pipx/.cache/e2/r; do assert_missing "$h/$f"; done
  for f in "$c/deno/location_data/ls/data" "$c/zig/keep-me" "$c/bazel/_bazel_$(id -un)/abc123/execroot/out" "$c/ccache/ccache.conf" \
    "$c/pypoetry/virtualenvs/proj/bin/python" "$c/pre-commit/other/keep" "$h/.nuget/packages/pkg/1.0/lib.dll" \
    "$h/.local/share/pipx/venvs/tool/bin/t" "$h/mine/documents/important"; do assert_exists "$f"; done
  assert_exists "$h/mine/README"; assert_exists "$h/mine/repo-notes/n" # PRE_COMMIT_HOME without db.db
  assert_missing "$h/mine/o/ok" # zig's own cache folder under a custom ZIG_GLOBAL_CACHE_DIR
}

test_telegram_and_spotify_caches() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/mediabin t
  for t in "$h/.local/share/TelegramDesktop" "$h/snap/telegram-desktop/current/.local/share/TelegramDesktop" \
    "$h/.var/app/org.telegram.desktop/data/TelegramDesktop"; do
    new "$t/tdata/user_data/cache/0/a"; new "$t/tdata/user_data#2/media_cache/b"
    new "$t/tdata/key_datas"; new "$t/tdata/D877F783D5D3EF8C/maps"; new "$t/tdata/user_data/keep"
  done
  new "$h/.cache/spotify/Storage/ab/song.file"; old "$h/.cache/spotify/Storage/cd/old.file"; new "$h/.cache/spotify/prefs"
  out=$(cm --json details app_telegram 2>&1)
  assert_contains "$out" "user_data/cache/0"; assert_contains "$out" "org.telegram.desktop/data/TelegramDesktop/tdata/user_data#2/media_cache/b"
  assert_contains "$out" "snap/telegram-desktop/current"
  [[ $out != *key_datas* && $out != *D877F783D5D3EF8C* && $out != *user_data/keep* ]] && ok_ "rest of tdata not listed" || fail "tdata listed: $out"
  # the generic ~/.cache item leaves Spotify's Storage to its own item
  out=$(cm --json details app_cache 2>&1)
  [[ $out != *spotify* ]] && ok_ "Spotify not in ~/.cache item" || fail "app_cache: $out"
  out=$(cm --scan --only apps 2>&1)
  assert_contains "$out" "Telegram Desktop — media cache"; assert_contains "$out" "Spotify — cache"
  # running apps: locked, nothing deleted
  running_stub "$bin" telegram-deskto spotify
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json scan | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "item": print(e["id"], repr(e["locked"]))')
  assert_contains "$out" "app_telegram 'telegram-deskto'"; assert_contains "$out" "app_spotify 'spotify'"
  select_only app_telegram app_spotify
  BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  assert_exists "$h/.local/share/TelegramDesktop/tdata/user_data/cache/0/a"; assert_exists "$h/.cache/spotify/Storage/ab/song.file"
  cm --clean --yes --only apps >/dev/null 2>&1 </dev/null
  for t in "$h/.local/share/TelegramDesktop" "$h/snap/telegram-desktop/current/.local/share/TelegramDesktop" \
    "$h/.var/app/org.telegram.desktop/data/TelegramDesktop"; do
    assert_missing "$t/tdata/user_data/cache/0"; assert_missing "$t/tdata/user_data#2/media_cache/b"
    assert_exists "$t/tdata/key_datas"; assert_exists "$t/tdata/D877F783D5D3EF8C/maps"; assert_exists "$t/tdata/user_data/keep"
  done
  assert_missing "$h/.cache/spotify/Storage/ab"; assert_missing "$h/.cache/spotify/Storage/cd"; assert_exists "$h/.cache/spotify/prefs"
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

test_ollama_partial_downloads_and_pub_cache() {
  fresh_home
  local h=$HOME_DIR out bin=$WORK/pubbin
  new "$h/.ollama/models/blobs/sha256-aaaa"; new "$h/.ollama/models/blobs/sha256-bbbb-partial"
  new "$h/.ollama/models/blobs/sha256-cccc-partial-0"; new "$h/.ollama/models/manifests/m"
  new "$h/oll/blobs/sha256-dddd-partial"; new "$h/oll/blobs/sha256-eeee"; new "$WORK/outside/blobs/sha256-ffff-partial"
  new "$h/.pub-cache/hosted/pub.dev/http-1.0.0/a.dart"; new "$h/.pub-cache/git/cache/repo/x"
  new "$h/.pub-cache/git/repo-abc/src"; new "$h/.pub-cache/credentials.json"; new "$h/.pub-cache/bin/tool"
  new "$h/.pub-cache/global_packages/g/p"; new "$h/pc/hosted/pub.dev/p-1/a.dart"; new "$h/pc/credentials.json"
  printf 'export OLLAMA_MODELS=$HOME/oll\nexport PUB_CACHE="$HOME/pc"\n' >"$h/.bashrc"
  out=$(cm --scan 2>&1)
  assert_contains "$out" "Ollama — unfinished downloads"
  assert_contains "$out" "Dart & Flutter pub cache"
  select_only ollama_partial pub_cache
  cm --clean --yes --dry-run --only models,dev >/dev/null 2>&1 </dev/null
  assert_exists "$h/.ollama/models/blobs/sha256-bbbb-partial"; assert_exists "$h/.pub-cache/hosted/pub.dev/http-1.0.0/a.dart"
  # a running ollama / dart / flutter skips its item
  running_stub "$bin" ollama
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only models 2>&1 </dev/null)
  assert_contains "$out" "Skipping"; assert_exists "$h/.ollama/models/blobs/sha256-bbbb-partial"
  running_stub "$bin" flutter
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --clean --yes --only dev 2>&1 </dev/null)
  assert_contains "$out" "Skipping"; assert_exists "$h/.pub-cache/hosted/pub.dev/http-1.0.0/a.dart"
  cm --clean --yes --only models,dev >/dev/null 2>&1 </dev/null
  assert_missing "$h/.ollama/models/blobs/sha256-bbbb-partial"; assert_missing "$h/.ollama/models/blobs/sha256-cccc-partial-0"
  assert_missing "$h/oll/blobs/sha256-dddd-partial"
  assert_exists "$h/.ollama/models/blobs/sha256-aaaa"; assert_exists "$h/.ollama/models/manifests/m"
  assert_exists "$h/oll/blobs/sha256-eeee"; assert_exists "$WORK/outside/blobs/sha256-ffff-partial"
  assert_missing "$h/.pub-cache/hosted/pub.dev/http-1.0.0/a.dart"; assert_missing "$h/.pub-cache/git/cache/repo/x"
  assert_missing "$h/pc/hosted/pub.dev/p-1/a.dart"
  assert_exists "$h/.pub-cache/credentials.json"; assert_exists "$h/.pub-cache/bin/tool"
  assert_exists "$h/.pub-cache/global_packages/g/p"; assert_exists "$h/.pub-cache/git/repo-abc/src"; assert_exists "$h/pc/credentials.json"
}

# Models of PyTorch Hub, Whisper, sentence-transformers and Keras: one entry each, from the default
# folders and the ones the variables name; never ticked, an open one skipped, the rest of the cache kept.
test_python_ai_model_caches() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out pid enc f hold=()
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  sized "$h/.cache/torch/hub/checkpoints/resnet50.pth" 3000; new "$h/.cache/torch/hub/pytorch_vision_main/hubconf.py"
  new "$h/.cache/torch/kernels/k.bin"; sized "$WORK/elsewhere.pth" 10
  ln -s "$WORK/elsewhere.pth" "$h/.cache/torch/hub/checkpoints/link.pth"
  sized "$h/.cache/whisper/base.en.pt" 2000; sized "$h/.cache/whisper/open.pt" 100; new "$h/.cache/whisper/notes.txt"
  new "$h/.cache/torch/sentence_transformers/all-MiniLM/modules.json"; new "$h/.cache/torch/sentence_transformers/other/x"
  new "$h/.keras/models/m.h5"; new "$h/.keras/datasets/mnist.npz"; new "$h/.keras/keras.json"
  new "$h/.cache/huggingface/hub/models--a--b/blobs/x"
  sized "$h/th/hub/checkpoints/vit.pth" 500; new "$h/st/mpnet/config_sentence_transformers.json"
  new "$h/kh/keras.json"; new "$h/kh/models/k.keras"; sized "$h/xc/whisper/small.pt" 400
  printf 'export TORCH_HOME=$HOME/th\nexport SENTENCE_TRANSFORMERS_HOME="$HOME/st"\nexport KERAS_HOME=$HOME/kh\nexport XDG_CACHE_HOME=$HOME/xc\n' >"$h/.bashrc"
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["selected"], e["label"])
    elif e["event"] == "item": print(e["id"], e["category"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"])
    elif e["event"] == "error": print("error", e["message"])'
  ((EUID == 0)) && chown -R 65534:65534 "$h"
  "${hold[@]}" sleep 60 <"$h/.cache/whisper/open.pt" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only models | grep '"id":"ai_model_caches"' | python3 -c "$list")
  assert_eq "$out" "ai_model_caches models False True False" "one AI models item, not ticked, with entries"
  out=$(user_cm --json details ai_model_caches | python3 -c "$list" | sed "s|$h|~|" | sort)
  assert_eq "$out" "~/.cache/torch/hub/checkpoints/resnet50.pth False resnet50.pth — PyTorch Hub
~/.cache/torch/sentence_transformers/all-MiniLM False all-MiniLM — sentence-transformers
~/.cache/whisper/base.en.pt False base.en — Whisper
~/.keras/datasets False datasets — Keras
~/.keras/models False models — Keras
~/kh/models False models — Keras
~/st/mpnet False mpnet — sentence-transformers
~/th/hub/checkpoints/vit.pth False vit.pth — PyTorch Hub
~/xc/whisper/small.pt False small — Whisper" "each model of the four libraries, default and variable folders; the open one skipped"
  # automatic cleaning leaves them alone even when ticked
  select_only ai_model_caches
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$h/.cache/whisper/base.en.pt"; assert_exists "$h/.keras/models/m.h5"
  out=$(user_cm --json clean ai_model_caches --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of ai_model_caches"
  enc=$(in_app "urlencode_path '$h/th/hub/checkpoints/vit.pth'")
  out=$(user_cm --json clean ai_model_caches --entries "$enc" | python3 -c "$list")
  assert_eq "$out" "ok" "one chosen model"
  assert_missing "$h/th/hub/checkpoints/vit.pth"; assert_exists "$h/.cache/torch/hub/checkpoints/resnet50.pth"
  user_cm --json clean ai_model_caches >/dev/null
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  for f in .cache/torch/hub/checkpoints/resnet50.pth .cache/whisper/base.en.pt .cache/torch/sentence_transformers/all-MiniLM \
    .keras/models .keras/datasets kh/models st/mpnet xc/whisper/small.pt; do assert_missing "$h/$f"; done
  for f in .cache/whisper/open.pt .cache/whisper/notes.txt .cache/torch/hub/checkpoints/link.pth .cache/torch/hub/pytorch_vision_main/hubconf.py \
    .cache/torch/kernels/k.bin .cache/torch/sentence_transformers/other/x .keras/keras.json kh/keras.json \
    .cache/huggingface/hub/models--a--b/blobs/x; do assert_exists "$h/$f"; done
  assert_exists "$WORK/elsewhere.pth"
  # KERAS_HOME without keras.json (not Keras' folder) and a folder two libraries would claim list nothing
  new "$h/Documents/datasets/mine.csv"; sized "$h/x2/whisper/w.pt" 10; new "$h/x2/whisper/m/modules.json"
  printf 'export KERAS_HOME=$HOME/Documents\nexport SENTENCE_TRANSFORMERS_HOME=$HOME/x2/whisper\nexport XDG_CACHE_HOME=$HOME/x2\n' >"$h/.bashrc"
  new "$h/.cache/whisper/base.en.pt"
  out=$(user_cm --json details ai_model_caches | python3 -c "$list" | sed "s|$h|~|")
  assert_eq "$out" "~/.cache/whisper/open.pt False open — Whisper
~/.cache/whisper/base.en.pt False base.en — Whisper" "only Keras' and unclaimed folders, biggest first"
}

# Android emulator snapshots: one entry per AVD (also one an .ini points to elsewhere), never ticked,
# only the snapshots folder goes, locked while the emulator runs.
test_android_avd_snapshots() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out bin=$WORK/avdbin a f bp bt encp enct
  for a in "$h/.android/avd/Pixel.avd" "$h/vms/Tab.avd" "$h/emu/avd/Wear.avd"; do
    sized "$a/snapshots/default_boot/ram.bin" 50000
    for f in userdata-qemu.img sdcard.img config.ini hardware-qemu.ini; do new "$a/$f"; done
  done
  sized "$h/vms/Tab.avd/snapshots/default_boot/ram.bin" 90000
  printf 'path=%s/vms/Tab.avd\n' "$h" >"$h/.android/avd/Tab.ini"
  printf 'path=%s/gone/Gone.avd\n' "$h" >"$h/.android/avd/Gone.ini"
  mkdir -p "$h/.android/avd/Empty.avd/snapshots" "$h/real"; new "$h/real/x"; mkdir -p "$h/.android/avd/Link.avd"
  ln -s "$h/real" "$h/.android/avd/Link.avd/snapshots"
  printf 'export ANDROID_EMULATOR_HOME="$HOME/emu"\n' >"$h/.profile"
  bp=$(du -sb "$h/.android/avd/Pixel.avd/snapshots" | cut -f1) bt=$(du -sb "$h/vms/Tab.avd/snapshots" | cut -f1)
  encp=$(in_app "urlencode_path '$h/.android/avd/Pixel.avd/snapshots'") enct=$(in_app "urlencode_path '$h/vms/Tab.avd/snapshots'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["note"], e["selected"], e["entries"], repr(e["locked"]))
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])'
  out=$(cm --json scan --only dev | grep '"id":"android_avd_snapshots"' | python3 -c "$list")
  assert_eq "$out" "android_avd_snapshots found 3 AVDs False True ''" "three AVDs, not ticked"
  out=$(cm --json details android_avd_snapshots | python3 -c "$list")
  assert_contains "$out" "$enct $bt off Tab"; assert_contains "$out" "$encp $bp off Pixel"; assert_contains "$out" " off Wear"
  [[ $out != *Link* && $out != *Empty* ]] && ok_ "symlinked and empty snapshots not listed" || fail "listed: $out"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Android emulator snapshots"
  running_stub "$bin" "qemu-system-x86_64"
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json scan --only dev | grep '"id":"android_avd_snapshots"' | python3 -c "$list")
  assert_contains "$out" "'qemu-system-x86_64'"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean android_avd_snapshots --entries "$encp" 2>&1)
  assert_contains "$out" '"id":"android_avd_snapshots","state":"skip"'
  assert_exists "$h/.android/avd/Pixel.avd/snapshots/default_boot/ram.bin"
  out=$(user_cm --json clean android_avd_snapshots --entries "$enct" | python3 -c "$list")
  assert_eq "$out" "ok $bt" "only the chosen AVD"
  assert_missing "$h/vms/Tab.avd/snapshots"; assert_exists "$h/.android/avd/Pixel.avd/snapshots/default_boot/ram.bin"
  select_only android_avd_snapshots
  user_cm --clean --yes --only dev >/dev/null 2>&1 </dev/null
  for a in "$h/.android/avd/Pixel.avd" "$h/vms/Tab.avd" "$h/emu/avd/Wear.avd"; do
    assert_missing "$a/snapshots"
    for f in userdata-qemu.img sdcard.img config.ini hardware-qemu.ini; do assert_exists "$a/$f"; done
  done
  assert_exists "$h/.android/avd/Tab.ini"; assert_exists "$h/real/x"; assert_exists "$h/.android/avd/Link.avd/snapshots"
}

# Android system images: only those no AVD uses are listed, each as an entry, never ticked;
# an AVD that can't be read keeps all of them, and Android Studio or the emulator locks the item.
test_unused_android_system_images() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out bin=$WORK/androidbin p enc33 enc34 b33 b34
  local s=$h/Android/Sdk/system-images s2=$h/sdk2/system-images
  sized "$s/android-34/google_apis/x86_64/system.img" 300000; new "$s/android-34/google_apis/x86_64/source.properties"
  sized "$s/android-33/google_apis_playstore/x86_64/system.img" 200000; new "$s/android-33/google_apis_playstore/x86_64/package.xml"
  sized "$s/android-30/default/x86_64/system.img" 100000; new "$s/android-30/default/x86_64/source.properties" # the AVD's
  sized "$s/android-29/default/x86_64/system.img" 10                     # no source.properties / package.xml
  sized "$s2/android-31/google_apis/arm64-v8a/system.img" 10; new "$s2/android-31/google_apis/arm64-v8a/package.xml" # a moved AVD's
  for p in platforms/android-34/android.jar build-tools/34.0.0/aapt ndk/27.1/x emulator/emulator platform-tools/adb; do
    new "$h/Android/Sdk/$p"
  done
  printf 'export ANDROID_HOME="$HOME/sdk2"\n' >"$h/.profile"
  mkdir -p "$h/.android/avd/Pixel.avd" "$h/vms/Tab.avd"
  printf 'avd.ini.encoding=UTF-8\r\nimage.sysdir.1=system-images/android-30/default/x86_64/\r\n' >"$h/.android/avd/Pixel.avd/config.ini"
  printf 'path=%s\npath.rel=avd/Pixel.avd\n' "$h/.android/avd/Pixel.avd" >"$h/.android/avd/Pixel.ini"
  printf 'image.sysdir.1 = %s/sdk2/system-images/android-31/google_apis/arm64-v8a/\n' "$h" >"$h/vms/Tab.avd/config.ini"
  printf 'path=%s/vms/Tab.avd\n' "$h" >"$h/.android/avd/Tab.ini"
  printf 'path=%s/gone/Gone.avd\n' "$h" >"$h/.android/avd/Gone.ini" # its AVD was deleted
  b34=$(du -sb "$s/android-34/google_apis/x86_64" | cut -f1) b33=$(du -sb "$s/android-33/google_apis_playstore/x86_64" | cut -f1)
  enc34=$(in_app "urlencode_path '$s/android-34/google_apis/x86_64'") enc33=$(in_app "urlencode_path '$s/android-33/google_apis_playstore/x86_64'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"], repr(e["locked"]))
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])
    elif e["event"] == "error": print("error", e["message"])'
  out=$(cm --json scan --only dev | grep '"id":"android_images"' | python3 -c "$list")
  assert_eq "$out" "android_images found $((b34 + b33)) 2 images no AVD uses False True False ''" "two unused images, not ticked"
  out=$(cm --json details android_images | python3 -c "$list")
  assert_eq "$out" "$enc34 $b34 off Android 34 · google_apis · x86_64
$enc33 $b33 off Android 33 · google_apis_playstore · x86_64" "one entry per image, biggest first"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Android system images (unused)"
  select_only android_images # automatic cleaning leaves them alone even when ticked
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$s/android-34/google_apis/x86_64"
  # Android Studio, the emulator, sdkmanager or avdmanager running: locked and skipped
  running_stub "$bin" "qemu-system-x86"
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json scan --only dev | grep '"id":"android_images"' | python3 -c "$list")
  assert_contains "$out" "'qemu-system-x86'"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean android_images --entries "$enc34" 2>&1)
  assert_contains "$out" '"id":"android_images","state":"skip"'
  running_stub "$bin" studio
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --clean --yes --only dev 2>&1 </dev/null)
  assert_contains "$out" "Skipping"
  assert_exists "$s/android-34/google_apis/x86_64"
  out=$(user_cm --json clean android_images --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of android_images: ../etc"
  out=$(user_cm --json clean android_images --entries "$enc33" | python3 -c "$list")
  assert_eq "$out" "ok $b33" "only the chosen image"
  assert_missing "$s/android-33"; assert_exists "$s/android-34/google_apis/x86_64"
  out=$(user_cm --json clean android_images | python3 -c "$list")
  assert_eq "$out" "ok $b34" "the other unused image"
  assert_missing "$s/android-34"
  for p in system-images/android-30/default/x86_64/system.img system-images/android-29/default/x86_64/system.img \
    platforms/android-34/android.jar build-tools/34.0.0/aapt ndk/27.1/x emulator/emulator platform-tools/adb; do
    assert_exists "$h/Android/Sdk/$p"
  done
  assert_exists "$s2/android-31/google_apis/arm64-v8a/system.img"; assert_exists "$h/.android/avd/Pixel.avd/config.ini"
  # an AVD whose config.ini can't be read (here: names no image) keeps every image
  sized "$s/android-35/google_apis/x86_64/system.img" 10; new "$s/android-35/google_apis/x86_64/source.properties"
  out=$(cm --json details android_images | python3 -c "$list")
  assert_eq "$out" "$(in_app "urlencode_path '$s/android-35/google_apis/x86_64'") $(du -sb "$s/android-35/google_apis/x86_64" | cut -f1) off Android 35 · google_apis · x86_64" \
    "listed while every AVD reads fine"
  printf 'garbage\n' >"$h/vms/Tab.avd/config.ini"
  out=$(cm --json details android_images | python3 -c "$list")
  assert_eq "$out" "" "a broken config.ini lists nothing"
  printf 'image.sysdir.1=system-images/android-31/google_apis/arm64-v8a/\n' >"$h/vms/Tab.avd/config.ini"
  printf 'export ANDROID_AVD_HOME=$OTHER/avd\n' >>"$h/.profile" # an AVD folder we can't tell
  out=$(cm --json details android_images | python3 -c "$list")
  assert_eq "$out" "" "an AVD folder that can't be worked out lists nothing"
}

# Old Android SDK components: every NDK, build-tools, SDK platform and CMake version but the newest
# of each kind and the ones a project pins, one entry each, never ticked; locked while Android
# Studio, Gradle or the emulator runs.
test_old_android_sdk_components() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out bin=$WORK/sdkbin p s=$HOME_DIR/Android/Sdk out_sdk=$WORK/outside-sdk
  local b27 b34 b35 bp34 bc22 e27 e34 e35 ep34 ec22
  assert_eq "$(cm --json scan --only dev | grep -c '"id":"android_sdk_old","status":"found"')" "0" "no SDK: nothing found"
  sized "$s/ndk/26.1/libc.so" 1000; printf 'Pkg.Desc = NDK\nPkg.Revision = 26.1.10909125\n' >"$s/ndk/26.1/source.properties"
  sized "$s/ndk/27.1/libc.so" 50000; printf 'Pkg.Revision=27.1.12297006\r\n' >"$s/ndk/27.1/source.properties"
  sized "$s/ndk/28.0/libc.so" 10; printf 'Pkg.Revision=28.0.13004108\n' >"$s/ndk/28.0/source.properties"
  sized "$s/ndk/29.0/libc.so" 10                                                # neither source.properties nor package.xml
  sized "$h/elsewhere/ndk/source.properties" 10; ln -s "$h/elsewhere/ndk" "$s/ndk/30.0" # a symlink
  sized "$s/build-tools/34.0.0/aapt" 40000; new "$s/build-tools/34.0.0/package.xml" # the folder name is the version
  sized "$s/build-tools/35.0.0/aapt" 30000; new "$s/build-tools/35.0.0/package.xml"
  sized "$s/build-tools/36.0.0/aapt" 10; new "$s/build-tools/36.0.0/package.xml"
  for p in 33:3 34:2 35:1; do # platforms go by API level, not Pkg.Revision
    sized "$s/platforms/android-${p%:*}/android.jar" 10
    printf 'Pkg.Revision=%s\nAndroidVersion.ApiLevel=%s\n' "${p#*:}" "${p%:*}" >"$s/platforms/android-${p%:*}/source.properties"
  done
  sized "$s/platforms/android-34/android.jar" 20000
  sized "$s/cmake/3.22.1/bin/cmake" 10000; printf 'Pkg.Revision=3.22.1\n' >"$s/cmake/3.22.1/source.properties"
  sized "$s/cmake/3.30.5/bin/cmake" 10; printf 'Pkg.Revision=3.30.5\n' >"$s/cmake/3.30.5/source.properties"
  for p in platform-tools/adb emulator/emulator system-images/android-34/default/x86_64/source.properties \
    licenses/android-sdk-license sources/android-34/source.properties; do new "$s/$p"; done
  sized "$out_sdk/ndk/20.0/libc.so" 10; new "$out_sdk/ndk/20.0/source.properties" # an SDK outside your home
  sized "$out_sdk/ndk/21.0/libc.so" 10; new "$out_sdk/ndk/21.0/source.properties"
  printf 'export ANDROID_SDK_ROOT=%s\n' "$out_sdk" >"$h/.profile"
  mkdir -p "$h/code/app/app"
  printf 'android {\n    compileSdk 33\n    ndkVersion "26.1.10909125"\n    // buildToolsVersion "35.0.0"\n}\n' >"$h/code/app/app/build.gradle"
  b27=$(tbytes "$s/ndk/27.1") b34=$(tbytes "$s/build-tools/34.0.0") b35=$(tbytes "$s/build-tools/35.0.0")
  bp34=$(tbytes "$s/platforms/android-34") bc22=$(tbytes "$s/cmake/3.22.1")
  e27=$(in_app "urlencode_path '$s/ndk/27.1'") e34=$(in_app "urlencode_path '$s/build-tools/34.0.0'")
  e35=$(in_app "urlencode_path '$s/build-tools/35.0.0'") ep34=$(in_app "urlencode_path '$s/platforms/android-34'")
  ec22=$(in_app "urlencode_path '$s/cmake/3.22.1'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"], repr(e["locked"]))
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])
    elif e["event"] == "error": print("error", e["message"])'
  out=$(cm --json scan --only dev | grep '"id":"android_sdk_old"' | python3 -c "$list")
  assert_eq "$out" "android_sdk_old found $((b27 + b34 + b35 + bp34 + bc22)) 5 versions replaced by a newer one False True False ''" \
    "five old versions, not ticked"
  out=$(cm --json details android_sdk_old | python3 -c "$list")
  assert_eq "$out" "$e27 $b27 off NDK 27.1 · 0 days old
$e34 $b34 off Build-Tools 34.0.0 · 0 days old
$e35 $b35 off Build-Tools 35.0.0 · 0 days old
$ep34 $bp34 off SDK Platform 34 · 0 days old
$ec22 $bc22 off CMake 3.22.1 · 0 days old" "one entry per old version, the pinned NDK 26.1 and platform 33 kept"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Old Android SDK components"
  select_only android_sdk_old # automatic cleaning leaves them alone even when ticked
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$s/ndk/27.1/libc.so"
  # Android Studio, Gradle or the emulator running: locked and skipped
  running_stub "$bin" "org.gradle.launcher.daemon.bootstrap.GradleDaemon"
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json scan --only dev | grep '"id":"android_sdk_old"' | python3 -c "$list")
  assert_contains "$out" "'Gradle'"
  running_stub "$bin" emulator
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean android_sdk_old --entries "$e27" 2>&1)
  assert_contains "$out" '"id":"android_sdk_old","state":"skip"'
  running_stub "$bin" studio
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --clean --yes --only dev 2>&1 </dev/null)
  assert_contains "$out" "Skipping Old Android SDK components: close studio first."
  assert_exists "$s/ndk/27.1/libc.so"
  out=$(user_cm --json clean android_sdk_old --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of android_sdk_old: ../etc"
  out=$(user_cm --json clean android_sdk_old --entries "$e27" | python3 -c "$list")
  assert_eq "$out" "ok $b27" "only the chosen version"
  assert_missing "$s/ndk/27.1"; assert_exists "$s/build-tools/34.0.0/aapt"
  # more pins: buildToolsVersion in a Kotlin script, ndk.dir in local.properties, the new compileSdk block
  mkdir -p "$h/code/kt/app"
  printf 'android {\n  compileSdk {\n    version = release(34)\n  }\n  buildToolsVersion = "34.0.0"\n}\n' >"$h/code/kt/app/build.gradle.kts"
  sized "$s/ndk/25.2/libc.so" 10; new "$s/ndk/25.2/source.properties"
  printf 'sdk.dir=%s\nndk.dir=%s/ndk/25.2\n' "$s" "$s" >"$h/code/kt/local.properties"
  out=$(cm --json details android_sdk_old | python3 -c "$list")
  assert_eq "$out" "$e35 $b35 off Build-Tools 35.0.0 · 0 days old
$ec22 $bc22 off CMake 3.22.1 · 0 days old" "pinned build-tools, platform and NDK folder kept"
  out=$(user_cm --json clean android_sdk_old --entries "$e34" | python3 -c "$list")
  assert_eq "$out" "fail 0" "a pinned version is no entry: nothing deleted"
  assert_exists "$s/build-tools/34.0.0/aapt"
  out=$(user_cm --json clean android_sdk_old | python3 -c "$list")
  assert_eq "$out" "ok $((b35 + bc22))" "the other old versions"
  assert_missing "$s/build-tools/35.0.0"; assert_missing "$s/cmake/3.22.1"
  for p in ndk/26.1 ndk/28.0 ndk/29.0 ndk/25.2 build-tools/34.0.0 build-tools/36.0.0 platforms/android-33 platforms/android-34 \
    platforms/android-35 cmake/3.30.5 platform-tools emulator system-images licenses sources; do
    assert_exists "$s/$p"
  done
  assert_exists "$h/elsewhere/ndk/source.properties"; assert_exists "$out_sdk/ndk/20.0/libc.so"
}

# Old Proton and Wine versions of Steam, Lutris, Heroic and Bottles (deb and Flatpak): every version
# but the newest of its family in each folder and the ones a game or bottle uses, one entry each,
# never ticked; locked while a launcher, Wine or Proton runs.
test_old_proton_and_wine_versions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out bin=$WORK/gamebin v d st=$HOME_DIR/.local/share/Steam/compatibilitytools.d
  local fst=$HOME_DIR/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d lu=$HOME_DIR/.local/share/lutris/runners/wine
  local he=$HOME_DIR/.config/heroic bo=$HOME_DIR/.local/share/bottles fbo=$HOME_DIR/.var/app/com.usebottles.bottles/data/bottles
  local b1 b2 b3 b4 b5 b6 e1 e2 e3 e4 e5 e6
  steam_tool() { # FOLDER BYTES [NAME] — a compatibility tool, its compatibilitytool.vdf naming it NAME (default: the folder's name)
    sized "$1/files/lib/wine.so" "$2"
    printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s" // internal name\n    {\n      "install_path" "."\n      "display_name" "%s"\n    }\n  }\n}\n' \
      "${3:-${1##*/}}" "${1##*/}" >"$1/compatibilitytool.vdf"
  }
  assert_eq "$(cm --json scan --only dev | grep -c '"id":"game_runners_old","status":"found"')" "0" "no launcher: nothing found"
  steam_tool "$st/GE-Proton8-25" 30000; steam_tool "$st/GE-Proton9-20" 50; steam_tool "$st/GE-Proton10-1" 40
  sized "$h/.local/share/Steam/steamapps/common/Proton 8.0/dist/lib/wine.so" 60000 # Steam's own Proton
  mkdir -p "$h/.local/share/Steam/config" "$h/.steam"
  ln -s "$h/.local/share/Steam" "$h/.steam/root" # the same folder twice: listed once
  printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n\t\t\t\t\t"0"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"GE-Proton9-20"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"75"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\t"name"\t\t"GE-Proton8-25"\n\t\t\t}\n\t\t}\n\t}\n}\n' \
    >"$h/.local/share/Steam/config/config.vdf" # a "name" outside CompatToolMapping keeps nothing
  b1=$(tbytes "$st/GE-Proton8-25") e1=$(in_app "urlencode_path '$st/GE-Proton8-25'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"], repr(e["locked"]))
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])
    elif e["event"] == "error": print("error", e["message"])'
  out=$(cm --json details game_runners_old | python3 -c "$list")
  assert_eq "$out" "$e1 $b1 off Steam: GE-Proton8-25" "three Proton-GE versions, the one a game uses and the newest kept"
  # Flatpak Steam; Lutris (a game's and the default wine version); Heroic (by name, by path); Bottles (deb and Flatpak)
  steam_tool "$fst/GE-Proton9-1" 25000; steam_tool "$fst/GE-Proton9-2" 10
  steam_tool "$st/GE-Proton7-55" 10 GE-Proton7-55-custom; steam_tool "$st/SteamTinkerLaunch" 10 # mapped by its own name; another family
  sed -i 's/"0"/"440"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"GE-Proton7-55-custom"\n\t\t\t\t\t}\n\t\t\t\t\t"0"/' "$h/.local/share/Steam/config/config.vdf"
  sized "$st/GE-Proton6-1/files/lib/wine.so" 10 # no compatibilitytool.vdf: not a tool
  sized "$h/elsewhere/GE-Proton5-1/files/wine.so" 10; new "$h/elsewhere/GE-Proton5-1/compatibilitytool.vdf"
  ln -s "$h/elsewhere/GE-Proton5-1" "$st/GE-Proton5-1" # a symlink
  sized "$WORK/outside-steam/compatibilitytools.d/GE-Proton1-1/files/wine.so" 10; new "$WORK/outside-steam/compatibilitytools.d/GE-Proton1-1/compatibilitytool.vdf"
  sized "$WORK/outside-steam/compatibilitytools.d/GE-Proton2-1/files/wine.so" 10; new "$WORK/outside-steam/compatibilitytools.d/GE-Proton2-1/compatibilitytool.vdf"
  ln -s "$WORK/outside-steam" "$h/.steam/steam" # outside your home
  for v in 8-20:10 8-25:20000 8-26:10 8-10:10; do sized "$lu/wine-ge-${v%:*}-x86_64/bin/wine" "${v#*:}"; done
  mkdir -p "$h/.config/lutris/games" "$h/.config/lutris/runners"
  printf 'game:\n  exe: /games/x.exe\nwine:\n  version: wine-ge-8-20-x86_64\n' >"$h/.config/lutris/games/x-1700000000.yml"
  printf "wine:\n  version: 'wine-ge-8-10-x86_64'\n" >"$h/.config/lutris/runners/wine.yml"
  for v in 1:10 2:15000 3:10; do sized "$he/tools/proton/GE-Proton8-${v%:*}/files/wine.so" "${v#*:}"; new "$he/tools/proton/GE-Proton8-${v%:*}/proton"; done
  for v in 1 2; do sized "$he/tools/wine/Wine-GE-Proton8-$v/bin/wine" 10; done
  mkdir -p "$he/GamesConfig"
  printf '{"abc":{"wineVersion":{"bin":"%s/tools/proton/GE-Proton8-1/proton","name":"Proton - GE-Proton8-1","type":"proton"}}}\n' "$he" >"$he/GamesConfig/abc.json"
  printf '{\n  "def": {\n    "wineVersion": {\n      "bin": "%s/tools/wine/Wine-GE-Proton8-1/bin/wine",\n      "name": "My wine"\n    }\n  }\n}\n' "$he" >"$he/GamesConfig/def.json"
  for v in soda-7.0-8:10 soda-7.0-9:10 caffe-7.10:12000 caffe-7.20:10; do sized "$bo/runners/${v%:*}/bin/wine" "${v#*:}"; done
  mkdir -p "$bo/bottles/Games"; printf 'Name: Games\nRunner: soda-7.0-8\n' >"$bo/bottles/Games/bottle.yml"
  sized "$fbo/runners/kron4ek-wine-9.0-amd64/bin/wine" 10000; sized "$fbo/runners/kron4ek-wine-9.1-amd64/bin/wine" 10
  b2=$(tbytes "$fst/GE-Proton9-1") e2=$(in_app "urlencode_path '$fst/GE-Proton9-1'")
  b3=$(tbytes "$lu/wine-ge-8-25-x86_64") e3=$(in_app "urlencode_path '$lu/wine-ge-8-25-x86_64'")
  b4=$(tbytes "$he/tools/proton/GE-Proton8-2") e4=$(in_app "urlencode_path '$he/tools/proton/GE-Proton8-2'")
  b5=$(tbytes "$bo/runners/caffe-7.10") e5=$(in_app "urlencode_path '$bo/runners/caffe-7.10'")
  b6=$(tbytes "$fbo/runners/kron4ek-wine-9.0-amd64") e6=$(in_app "urlencode_path '$fbo/runners/kron4ek-wine-9.0-amd64'")
  out=$(cm --json scan --only dev | grep '"id":"game_runners_old"' | python3 -c "$list")
  assert_eq "$out" "game_runners_old found $((b1 + b2 + b3 + b4 + b5 + b6)) 6 versions replaced by a newer one False True False ''" \
    "six old versions, not ticked"
  out=$(cm --json details game_runners_old | python3 -c "$list")
  assert_eq "$out" "$e1 $b1 off Steam: GE-Proton8-25
$e2 $b2 off Steam (Flatpak): GE-Proton9-1
$e3 $b3 off Lutris: wine-ge-8-25-x86_64
$e4 $b4 off Heroic: GE-Proton8-2
$e5 $b5 off Bottles: caffe-7.10
$e6 $b6 off Bottles (Flatpak): kron4ek-wine-9.0-amd64" "one entry per old version, the ones in use and the newest of each family kept"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Old Proton and Wine versions"
  select_only game_runners_old # automatic cleaning leaves them alone even when ticked
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$st/GE-Proton8-25/files/lib/wine.so"
  # a launcher, Wine or Proton running: locked and skipped
  running_stub "$bin" steamwebhelper
  out=$(BASE_PATH="$bin:$BASE_PATH" cm --json scan --only dev | grep '"id":"game_runners_old"' | python3 -c "$list")
  assert_contains "$out" "'steamwebhelper'"
  running_stub "$bin" wineserver
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean game_runners_old --entries "$e1" 2>&1)
  assert_contains "$out" '"id":"game_runners_old","state":"skip"'
  running_stub "$bin" bottles
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --clean --yes --only dev 2>&1 </dev/null)
  assert_contains "$out" "Skipping Old Proton and Wine versions: close bottles first."
  assert_exists "$st/GE-Proton8-25/files/lib/wine.so"
  out=$(user_cm --json clean game_runners_old --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of game_runners_old: ../etc"
  out=$(user_cm --json clean game_runners_old --entries "$e1" | python3 -c "$list")
  assert_eq "$out" "ok $b1" "only the chosen version"
  assert_missing "$st/GE-Proton8-25"; assert_exists "$lu/wine-ge-8-25-x86_64/bin/wine"
  out=$(cm --json details game_runners_old | python3 -c "$list")
  assert_eq "$(grep -c GE-Proton8-25 <<<"$out")" "0" "the deleted version is no longer listed"
  out=$(user_cm --json clean game_runners_old | python3 -c "$list")
  assert_eq "$out" "ok $((b2 + b3 + b4 + b5 + b6))" "the other old versions"
  for d in "$fst/GE-Proton9-1" "$lu/wine-ge-8-25-x86_64" "$he/tools/proton/GE-Proton8-2" "$bo/runners/caffe-7.10" \
    "$fbo/runners/kron4ek-wine-9.0-amd64"; do assert_missing "$d"; done
  for d in "$st/GE-Proton9-20" "$st/GE-Proton10-1" "$st/GE-Proton7-55" "$st/SteamTinkerLaunch" "$st/GE-Proton6-1" "$st/GE-Proton5-1" \
    "$h/elsewhere/GE-Proton5-1/compatibilitytool.vdf" "$h/.local/share/Steam/steamapps/common/Proton 8.0/dist/lib/wine.so" \
    "$WORK/outside-steam/compatibilitytools.d/GE-Proton1-1" "$fst/GE-Proton9-2" "$lu/wine-ge-8-10-x86_64" "$lu/wine-ge-8-20-x86_64" \
    "$lu/wine-ge-8-26-x86_64" "$he/tools/proton/GE-Proton8-1" "$he/tools/proton/GE-Proton8-3" "$he/tools/wine/Wine-GE-Proton8-1" \
    "$he/tools/wine/Wine-GE-Proton8-2" "$bo/runners/soda-7.0-8" "$bo/runners/soda-7.0-9" "$bo/runners/caffe-7.20" \
    "$fbo/runners/kron4ek-wine-9.1-amd64"; do assert_exists "$d"; done
  # Steam's settings can't be read: every Steam version is kept
  steam_tool "$st/GE-Proton4-1" 10
  chmod 000 "$h/.local/share/Steam/config/config.vdf"
  if [[ -r $h/.local/share/Steam/config/config.vdf ]]; then rm "$h/.local/share/Steam/config/config.vdf"; mkdir "$h/.local/share/Steam/config/config.vdf"; fi # root reads anything
  out=$(cm --json details game_runners_old | python3 -c "$list")
  assert_eq "$out" "" "unreadable Steam settings keep everything"
  chmod -R u+rwX "$h/.local/share/Steam/config"
  unset -f steam_tool
}

test_old_jetbrains_and_android_studio_versions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out bin=$WORK/idebin f keys=() bi bp bw bs bf enci encp encs
  local c=$h/.config/JetBrains d=$h/.local/share/JetBrains k=$h/.cache/JetBrains g=$h/.config/Google kg=$h/.cache/Google
  local fp=$h/.var/app/com.jetbrains.PyCharm-Community/config/JetBrains
  assert_eq "$(user_cm --json scan --only dev | grep -c '"id":"jetbrains_old_versions"')" "0" "no IDE folders: not shown"
  sized "$c/IntelliJIdea2023.1/options/ide.general.xml" 1000; sized "$d/IntelliJIdea2023.1/plugins/p.jar" 4000
  sized "$k/IntelliJIdea2023.1/index/x" 90000                                       # the old one, in all three places
  sized "$c/IntelliJIdea2024.2/options/ide.general.xml" 10; sized "$k/IntelliJIdea2024.2/index/x" 10 # the newest
  sized "$d/PyCharm2023.3/plugins/p.jar" 20000; sized "$c/PyCharm2024.1/options/x.xml" 10
  sized "$c/PyCharmCE2022.1/options/x.xml" 10                                      # the only Community one
  sized "$c/WebStorm2023.9/options/x.xml" 5000; sized "$c/WebStorm2023.10/options/x.xml" 10 # 2023.10 is newer
  for f in "$c/consentOptions/accepted" "$c/IntelliJServer/x" "$k/Daemon/x" "$d/Toolbox/apps/x" "$c/IntelliJIdea/x"; do new "$f"; done
  sized "$g/AndroidStudio2023.3/options/x.xml" 7000; sized "$kg/AndroidStudio2023.3/caches/x" 20000
  sized "$g/AndroidStudio2024.1/options/x.xml" 10
  sized "$g/Chrome2020.1/x" 10; sized "$g/Chrome2021.1/x" 10                      # not Android Studio: never
  sized "$fp/PyCharmCE2023.1/options/x.xml" 6000; sized "$fp/PyCharmCE2023.2/options/x.xml" 10 # each sandbox on its own
  old "$k/IntelliJIdea2024.2/index/old"
  bi=$(du -sbc "$c/IntelliJIdea2023.1" "$d/IntelliJIdea2023.1" "$k/IntelliJIdea2023.1" | tail -n1 | cut -f1)
  bs=$(du -sbc "$g/AndroidStudio2023.3" "$kg/AndroidStudio2023.3" | tail -n1 | cut -f1)
  bp=$(du -sb "$d/PyCharm2023.3" | cut -f1) bw=$(du -sb "$c/WebStorm2023.9" | cut -f1) bf=$(du -sb "$fp/PyCharmCE2023.1" | cut -f1)
  enci=$(in_app "urlencode_path '$c/IntelliJIdea2023.1'") encp=$(in_app "urlencode_path '$d/PyCharm2023.3'")
  encs=$(in_app "urlencode_path '$g/AndroidStudio2023.3'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])
    elif e["event"] == "done" and e.get("trash"): print("trash", " ".join(sorted(e["trash"]["jetbrains_old_versions"])))
    elif e["event"] == "error": print("error", e["message"])'
  out=$(user_cm --json scan --only dev | grep '"id":"jetbrains_old_versions"' | python3 -c "$list")
  assert_eq "$out" "jetbrains_old_versions found $((bi + bs + bp + bf + bw)) 5 versions replaced by a newer one False True False" \
    "old versions, not ticked"
  out=$(user_cm --json details jetbrains_old_versions | python3 -c "$list")
  assert_eq "$out" "$enci $bi off IntelliJ IDEA 2023.1
$encs $bs off Android Studio 2023.3
$encp $bp off PyCharm 2023.3
$(in_app "urlencode_path '$fp/PyCharmCE2023.1'") $bf off PyCharm Community 2023.1 · Flatpak
$(in_app "urlencode_path '$c/WebStorm2023.9'") $bw off WebStorm 2023.9" "one entry per version (its three folders together), biggest first"
  assert_eq "$(in_app 'app_cache_find' | grep -c -e JetBrains -e AndroidStudio)" "0" "user caches leave IDE caches alone"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Old IDE versions"
  # automatic cleaning leaves them alone even when ticked
  select_only jetbrains_old_versions
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$c/IntelliJIdea2023.1"
  # that IDE running: its old versions are skipped, the others are not
  running_stub "$bin" pycharm
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json scan --only dev | grep '"id":"jetbrains_old_versions"' | python3 -c "$list" | cut -d' ' -f4-)
  assert_eq "$out" "3 versions replaced by a newer one; skipped while running: PyCharm 2023.3, PyCharm Community 2023.1 · Flatpak True True False" \
    "a running IDE's versions are skipped and named (ticked: select_only above)"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean jetbrains_old_versions --entries "$encp,$enci" | python3 -c "$list")
  assert_contains "$out" "ok $bi"
  assert_exists "$d/PyCharm2023.3/plugins/p.jar"
  for f in "$c/IntelliJIdea2023.1" "$d/IntelliJIdea2023.1" "$k/IntelliJIdea2023.1"; do assert_missing "$f"; done
  assert_exists "$h/.local/share/Trash/files/IntelliJIdea2023.1"
  out=$(user_cm --json clean jetbrains_old_versions --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of jetbrains_old_versions: ../etc"
  # Undo puts all three folders back
  mapfile -t keys < <(ls "$h/.local/share/Trash/files")
  assert_eq "${#keys[@]}" "3" "three folders in the Trash"
  user_cm --json restore "${keys[@]}" >/dev/null
  assert_exists "$c/IntelliJIdea2023.1/options/ide.general.xml"; assert_exists "$d/IntelliJIdea2023.1/plugins/p.jar"
  assert_exists "$k/IntelliJIdea2023.1/index/x"
  out=$(user_cm --json clean jetbrains_old_versions | python3 -c "$list")
  assert_contains "$out" "ok $((bi + bs + bp + bf + bw))"
  assert_eq "$(grep -o '^trash .*' <<<"$out" | wc -w)" "9" "every folder moved to the Trash has an undo key"
  for f in "$c/IntelliJIdea2023.1" "$d/IntelliJIdea2023.1" "$k/IntelliJIdea2023.1" "$d/PyCharm2023.3" "$c/WebStorm2023.9" \
    "$g/AndroidStudio2023.3" "$kg/AndroidStudio2023.3" "$fp/PyCharmCE2023.1"; do
    assert_missing "$f"
  done
  for f in IntelliJIdea2024.2 PyCharm2024.1 PyCharmCE2022.1 WebStorm2023.10 consentOptions IntelliJServer IntelliJIdea; do assert_exists "$c/$f"; done
  for f in "$k/IntelliJIdea2024.2/index/old" "$k/Daemon/x" "$d/Toolbox/apps/x" "$g/AndroidStudio2024.1" "$g/Chrome2020.1" \
    "$fp/PyCharmCE2023.2"; do
    assert_exists "$f"
  done
  out=$(user_cm --json scan --only dev | grep '"id":"jetbrains_old_versions"' | python3 -c "$list" | cut -d' ' -f1-3)
  assert_eq "$out" "jetbrains_old_versions clean 0" "nothing left"
}

test_old_editor_extension_versions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out bin=$WORK/extbin f e
  local v=$h/.vscode/extensions c=$h/.cursor/extensions w=$h/.windsurf/extensions
  local fv=$h/.var/app/com.visualstudio.code/data/vscode/extensions
  local bpy bcpp bjava bgo bcop bflat bcur encpy enccur
  assert_eq "$(user_cm --json scan --only dev | grep -c '"id":"vscode_old_extensions"')" "0" "no editor: not shown"
  sized "$v/ms-python.python-2024.1.0/a" 6000; sized "$v/ms-python.python-2024.2.0/a" 6000
  sized "$v/ms-python.python-2024.10.1/a" 10                              # newest (10 > 2): kept
  sized "$v/esbenp.prettier-vscode-10.4.0/a" 10                           # the only version: kept
  sized "$v/ms-vscode.cpptools-1.19.0-linux-x64/a" 9000; sized "$v/ms-vscode.cpptools-1.20.5-linux-x64/a" 10
  sized "$v/foo.bar-0.9.0/a" 10; sized "$v/foo.bar-1.0.0-beta/a" 10       # unknown suffix: not a version
  sized "$v/redhat.java-1.30.0/a" 2000                                    # uninstalled: in .obsolete
  sized "$v/golang.go-0.41.0/a" 10; sized "$v/golang.go-0.42.0/a" 5000    # downgraded: 0.42.0 obsolete, 0.41.0 in use
  sized "$v/dbaeumer.vscode-eslint-2.4.0/a" 10; sized "$v/dbaeumer.vscode-eslint-2.4.4/a" 10 # 2.4.0 named in extensions.json
  sized "$v/GitHub.copilot-1.0.0/a" 6000; sized "$v/github.copilot-1.1.0/a" 10 # same extension, other case
  sized "$h/elsewhere/ms-python.python-2023.1.0/a" 10
  ln -s "$h/elsewhere/ms-python.python-2023.1.0" "$v/ms-python.python-2023.1.0" # a symlink: never
  printf '{"redhat.java-1.30.0": true, "golang.go-0.42.0": true, "esbenp.prettier-vscode-10.4.0": false}' >"$v/.obsolete"
  printf '[{"identifier":{"id":"golang.go"},"relativeLocation":"golang.go-0.41.0"},
    {"identifier":{"id":"dbaeumer.vscode-eslint"},"location":{"$mid":1,"path":"%s/dbaeumer.vscode-eslint-2.4.0","scheme":"file"}}]' \
    "$v" >"$v/extensions.json"
  sized "$c/anysphere.cursorpyright-1.0.0/a" 7000; sized "$c/anysphere.cursorpyright-1.0.2/a" 10
  sized "$fv/ms-python.python-2024.1.0/a" 8000; sized "$fv/ms-python.python-2024.2.0/a" 10 # Flatpak: on its own
  sized "$w/codeium.windsurf-1.0.0/a" 10; sized "$w/codeium.windsurf-1.1.0/a" 10
  printf '{"codeium.windsurf-1.1.0": tr' >"$w/.obsolete"                 # can't be read: Windsurf left alone
  bpy=$(du -sbc "$v/ms-python.python-2024.1.0" "$v/ms-python.python-2024.2.0" | tail -n1 | cut -f1)
  bcpp=$(du -sb "$v/ms-vscode.cpptools-1.19.0-linux-x64" | cut -f1) bjava=$(du -sb "$v/redhat.java-1.30.0" | cut -f1)
  bgo=$(du -sb "$v/golang.go-0.42.0" | cut -f1) bcop=$(du -sb "$v/GitHub.copilot-1.0.0" | cut -f1)
  bflat=$(du -sb "$fv/ms-python.python-2024.1.0" | cut -f1) bcur=$(du -sb "$c/anysphere.cursorpyright-1.0.0" | cut -f1)
  encpy=$(in_app "urlencode_path '$v/ms-python.python-2024.2.0'") enccur=$(in_app "urlencode_path '$c/anysphere.cursorpyright-1.0.0'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])
    elif e["event"] == "error": print("error", e["message"])'
  local all=$((bpy + bcpp + bjava + bgo + bcop + bflat + bcur))
  out=$(user_cm --json scan --only dev | grep '"id":"vscode_old_extensions"' | python3 -c "$list")
  assert_eq "$out" "vscode_old_extensions found $all 8 versions replaced by a newer one False True False" "old versions, not ticked"
  local want
  want="$encpy $bpy off ms-python.python · VS Code  (2 versions)
$(in_app "urlencode_path '$v/ms-vscode.cpptools-1.19.0-linux-x64'") $bcpp off ms-vscode.cpptools · VS Code  (1 version)
$(in_app "urlencode_path '$fv/ms-python.python-2024.1.0'") $bflat off ms-python.python · VS Code · Flatpak  (1 version)
$enccur $bcur off anysphere.cursorpyright · Cursor  (1 version)
$(in_app "urlencode_path '$v/GitHub.copilot-1.0.0'") $bcop off GitHub.copilot · VS Code  (1 version)
$(in_app "urlencode_path '$v/golang.go-0.42.0'") $bgo off golang.go · VS Code  (1 version)
$(in_app "urlencode_path '$v/redhat.java-1.30.0'") $bjava off redhat.java · VS Code  (1 version)"
  out=$(user_cm --json details vscode_old_extensions | python3 -c "$list")
  assert_eq "$out" "$want" "one entry per extension and editor, biggest first"
  if command -v jq >/dev/null; then # the same without jq (python3 reads the JSON)
    out=$(BASE_PATH=$(path_without jq) user_cm --json details vscode_old_extensions | python3 -c "$list")
    assert_eq "$out" "$want" "same entries without jq"
  fi
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Old editor extension versions"
  # automatic cleaning leaves them alone even when ticked
  select_only vscode_old_extensions
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$v/ms-python.python-2024.1.0"
  # Cursor running: its extensions are skipped, the others are not
  running_stub "$bin" cursor
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json scan --only dev | grep '"id":"vscode_old_extensions"' | python3 -c "$list" | cut -d' ' -f4-)
  assert_eq "$out" "7 versions replaced by a newer one; skipped while running: Cursor True True False" \
    "a running editor's extensions are skipped and named (ticked: select_only above)"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean vscode_old_extensions --entries "$enccur,$encpy" | python3 -c "$list")
  assert_contains "$out" "ok $bpy"
  assert_exists "$c/anysphere.cursorpyright-1.0.0/a"
  assert_missing "$v/ms-python.python-2024.1.0"; assert_missing "$v/ms-python.python-2024.2.0"
  assert_exists "$v/ms-vscode.cpptools-1.19.0-linux-x64/a"
  assert_eq "$(find "$h/.local/share/Trash" -mindepth 2 2>/dev/null | wc -l)" "0" "deleted, not moved to the Trash"
  out=$(user_cm --json clean vscode_old_extensions --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of vscode_old_extensions: ../etc"
  out=$(user_cm --json clean vscode_old_extensions | python3 -c "$list")
  assert_contains "$out" "ok $((all - bpy))"
  for f in ms-vscode.cpptools-1.19.0-linux-x64 redhat.java-1.30.0 golang.go-0.42.0 GitHub.copilot-1.0.0; do assert_missing "$v/$f"; done
  assert_missing "$fv/ms-python.python-2024.1.0"; assert_missing "$c/anysphere.cursorpyright-1.0.0"
  for f in ms-python.python-2024.10.1 esbenp.prettier-vscode-10.4.0 ms-vscode.cpptools-1.20.5-linux-x64 foo.bar-0.9.0 \
    foo.bar-1.0.0-beta golang.go-0.41.0 dbaeumer.vscode-eslint-2.4.0 dbaeumer.vscode-eslint-2.4.4 github.copilot-1.1.0 \
    ms-python.python-2023.1.0 .obsolete extensions.json; do
    assert_exists "$v/$f"
  done
  assert_exists "$h/elsewhere/ms-python.python-2023.1.0/a"
  for e in "$fv/ms-python.python-2024.2.0" "$c/anysphere.cursorpyright-1.0.2" "$w/codeium.windsurf-1.0.0" "$w/codeium.windsurf-1.1.0"; do
    assert_exists "$e"
  done
  out=$(user_cm --json scan --only dev | grep '"id":"vscode_old_extensions"' | python3 -c "$list" | cut -d' ' -f1-3)
  assert_eq "$out" "vscode_old_extensions clean 0" "nothing left"
}

test_old_runtime_versions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local np; np=$(path_without node nodejs go); local BASE_PATH=$np
  local h=$HOME_DIR out pid hold=() f b18 b22 b17 b319 enc18 enc22
  local n=$h/.nvm/versions/node j=$h/.sdkman/candidates/java g=$h/.sdkman/candidates/gradle fv=$h/fvm/versions
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  assert_eq "$(user_cm --json scan --only dev | grep -c '"id":"old_runtimes"')" "0" "no nvm, SDKMAN or fvm: not shown"
  sized "$n/v18.20.4/bin/node" 3000; sized "$n/v20.11.0/bin/node" 2000; sized "$n/v22.1.0/bin/node" 4000
  mkdir -p "$h/.nvm/alias/lts"
  echo "lts/iron" >"$h/.nvm/alias/default"; echo "v20.11.0" >"$h/.nvm/alias/lts/iron"; echo "lts/iron" >"$h/.nvm/alias/lts/*"
  new "$h/project/.nvmrc"
  sized "$j/17.0.2-tem/bin/java" 5000; sized "$j/21.0.1-tem/bin/java" 6000; ln -s 21.0.1-tem "$j/current"
  sized "$g/8.5/bin/gradle" 700; sized "$g/8.7/bin/gradle" 800                  # no current: both kept
  mkdir -p "$WORK/jdk-local"; ln -s "$WORK/jdk-local" "$j/11-local"              # sdk install java 11-local /path
  sized "$fv/3.24.0/bin/flutter" 900; sized "$fv/3.19.0/bin/flutter" 1000; ln -s "$fv/3.24.0" "$h/fvm/default"
  b18=$(du -sb "$n/v18.20.4" | cut -f1) b22=$(du -sb "$n/v22.1.0" | cut -f1) b17=$(du -sb "$j/17.0.2-tem" | cut -f1)
  b319=$(du -sb "$fv/3.19.0" | cut -f1)
  enc18=$(in_app "urlencode_path '$n/v18.20.4'") enc22=$(in_app "urlencode_path '$n/v22.1.0'")
  local list='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["id"], e["bytes"], "on" if e["selected"] else "off", e["label"])
    elif e["event"] == "item": print(e["id"], e["status"], e["bytes"], e["note"], e["selected"], e["entries"], e["default"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"], e["freed"])
    elif e["event"] == "error": print("error", e["message"])'
  out=$(user_cm --json scan --only dev | grep '"id":"old_runtimes"' | python3 -c "$list")
  assert_eq "$out" "old_runtimes found $((b18 + b22 + b17 + b319)) 4 versions not your default False True False" \
    "versions that aren't the default, not ticked"
  out=$(user_cm --json details old_runtimes | python3 -c "$list")
  assert_eq "$out" "$(in_app "urlencode_path '$j/17.0.2-tem'") $b17 off java 17.0.2-tem
$enc22 $b22 off Node v22.1.0
$enc18 $b18 off Node v18.20.4
$(in_app "urlencode_path '$fv/3.19.0'") $b319 off Flutter 3.19.0" "one entry per version, biggest first"
  # a version a program runs from is skipped, and the scan says so
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  rm "$n/v18.20.4/bin/node"; cp "$(command -v sleep)" "$n/v18.20.4/bin/node"
  "${hold[@]}" "$n/v18.20.4/bin/node" 60 >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only dev | grep '"id":"old_runtimes"' | python3 -c "$list" | cut -d' ' -f4-)
  assert_eq "$out" "3 versions not your default; skipped while running: Node v18.20.4 False True False" "a running version is skipped"
  assert_eq "$(user_cm --json details old_runtimes | python3 -c "$list" | grep -c v18)" "0" "no entry for a running version"
  # automatic cleaning leaves them alone even when ticked
  select_only old_runtimes
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$n/v22.1.0/bin/node"; assert_exists "$j/17.0.2-tem/bin/java"
  out=$(user_cm --json clean old_runtimes --entries "../etc" | python3 -c "$list")
  assert_contains "$out" "error Not an entry ID of old_runtimes: ../etc"
  out=$(user_cm --json clean old_runtimes --entries "$enc22,$enc18" | python3 -c "$list")
  assert_eq "$out" "ok $b22" "only the chosen version, never a running one"
  assert_missing "$n/v22.1.0"; assert_exists "$n/v18.20.4/bin/node"
  out=$(user_cm --json clean old_runtimes | python3 -c "$list")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok $((b17 + b319))" "the rest"
  assert_missing "$j/17.0.2-tem"; assert_missing "$fv/3.19.0"; assert_exists "$n/v18.20.4/bin/node"
  for f in .nvm/versions/node/v20.11.0/bin/node .nvm/alias/default ".nvm/alias/lts/*" .nvm/alias/lts/iron project/.nvmrc \
    .sdkman/candidates/java/21.0.1-tem/bin/java .sdkman/candidates/java/current .sdkman/candidates/java/11-local \
    .sdkman/candidates/gradle/8.5/bin/gradle .sdkman/candidates/gradle/8.7/bin/gradle fvm/versions/3.24.0/bin/flutter fvm/default; do
    assert_exists "$h/$f"
  done
  assert_exists "$WORK/jdk-local"
  # nvm: node/stable mean the newest; another alias and the node on PATH keep theirs; NVM_DIR from your profile
  sized "$n/v22.1.0/bin/node" 10; sized "$n/v16.0.0/bin/node" 10; sized "$n/v14.0.0/bin/node" 10
  echo "node" >"$h/.nvm/alias/default"; echo "16" >"$h/.nvm/alias/work"
  mkdir -p "$h/.local/bin"; ln -s "$n/v14.0.0/bin/node" "$h/.local/bin/node"
  assert_eq "$(user_cm --json details old_runtimes | python3 -c "$list" | cut -d' ' -f4- | sort | paste -sd' ' -)" \
    "Node v18.20.4 Node v20.11.0" "keeps the newest, an alias's and the one on PATH"
  echo "system" >"$h/.nvm/alias/default"
  assert_eq "$(user_cm --json details old_runtimes | python3 -c "$list")" "" "a default that can't be told keeps every version"
  mv "$h/.nvm" "$h/nvm2"; printf 'export NVM_DIR="$HOME/nvm2"\n' >"$h/.profile"; echo "v20.11.0" >"$h/nvm2/alias/default"
  rm "$h/.local/bin/node"
  assert_eq "$(user_cm --json details old_runtimes | python3 -c "$list" | cut -d' ' -f4- | sort | paste -sd' ' -)" \
    "Node v14.0.0 Node v18.20.4 Node v22.1.0" "NVM_DIR from the profile"
}

test_old_pyenv_rbenv_rustup_go_versions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local np; np=$(path_without node nodejs go); local BASE_PATH=$np
  local h=$HOME_DIR out pid hold=() f enc
  local py=$h/.pyenv/versions rb=$h/.rbenv/versions rs=$h/.rustup/toolchains sdk=$h/sdk host=x86_64-unknown-linux-gnu
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  local labels='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["label"], "on" if e["selected"] else "off")
    elif e["event"] == "item": print(e["note"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"])
    elif e["event"] == "error": print("error", e["message"])'
  details() { user_cm --json details old_runtimes | python3 -c "$labels" | LC_ALL=C sort | paste -sd'|' -; }
  # pyenv: every line of version counts, 3.12 keeps every 3.12.x, a version holding a virtualenv stays
  for f in 3.12.1 3.12.3 3.11.4 3.10.0 3.9.1 pypy3.10-7.3.15; do sized "$py/$f/bin/python" 1000; done
  new "$py/3.9.1/envs/work/bin/python"; ln -s "$py/3.9.1/envs/work" "$py/work"
  printf '# pinned\n3.12 \npypy3.10-7.3.15\n' >"$h/.pyenv/version"; new "$h/.pyenv/shims/python"
  # rbenv: the first word of the first line, ruby- dropped
  for f in 3.2.2 3.3.0 3.1.4; do sized "$rb/$f/bin/ruby" 1000; done
  printf 'ruby-3.3.0 # global\n3.1.4\n' >"$h/.rbenv/version"; new "$h/.rbenv/shims/ruby"
  # rustup: the default (a short name, no host triple: any host) and the overrides
  for f in "stable-$host" "beta-$host" "nightly-2024-01-01-$host" "1.70.0-$host"; do sized "$rs/$f/bin/rustc" 1000; done
  mkdir -p "$WORK/custom-rust"; ln -s "$WORK/custom-rust" "$rs/custom" # rustup toolchain link
  printf 'version = "12"\ndefault_toolchain = "stable"\nprofile = "default"\n\n[overrides]\n"/home/u/old" = "1.70.0-%s"\n' \
    "$host" >"$h/.rustup/settings.toml"
  new "$h/.rustup/downloads/abc.partial"; new "$h/.rustup/update-hashes/stable-$host"
  # Go: the SDK go env GOROOT reports; a commented profile line names nothing
  for f in go1.22.0 go1.21.0 go1.20.0; do sized "$sdk/$f/bin/go" 1000; done
  new "$sdk/notes.txt"; mkdir -p "$sdk/other"
  mkdir -p "$h/.local/bin"
  printf '#!/bin/sh\n[ "$1 $2" = "env GOROOT" ] && echo "$HOME/sdk/go1.22.0"\n' >"$h/.local/bin/go"; chmod +x "$h/.local/bin/go"
  printf '# export PATH=$HOME/sdk/go1.21.0/bin:$PATH\n' >"$h/.bashrc"
  out=$(details)
  assert_eq "$out" "Go 1.20.0 off|Go 1.21.0 off|Python 3.10.0 off|Python 3.11.4 off|Ruby 3.1.4 off|Ruby 3.2.2 off|Rust beta-$host off|Rust nightly-2024-01-01-$host off" \
    "every version but the default, not ticked"
  # a version a program runs from is skipped, and the scan says so
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  rm "$py/3.11.4/bin/python"; cp "$(command -v sleep)" "$py/3.11.4/bin/python"
  "${hold[@]}" "$py/3.11.4/bin/python" 60 >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only dev | grep '"id":"old_runtimes"' | python3 -c "$labels")
  assert_eq "$out" "7 versions not your default; skipped while running: Python 3.11.4" "a running version is skipped"
  enc=$(in_app "urlencode_path '$rs/beta-$host'")
  out=$(user_cm --json clean old_runtimes --entries "$enc" | python3 -c "$labels")
  assert_eq "$out" "ok" "one toolchain"
  assert_missing "$rs/beta-$host"; assert_exists "$rs/nightly-2024-01-01-$host/bin/rustc"
  out=$(user_cm --json clean old_runtimes | python3 -c "$labels")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok" "the rest"
  for f in "$py/3.10.0" "$rb/3.2.2" "$rb/3.1.4" "$rs/nightly-2024-01-01-$host" "$sdk/go1.21.0" "$sdk/go1.20.0"; do
    assert_missing "$f"
  done
  for f in "$py/3.11.4/bin/python" "$py/3.12.1/bin/python" "$py/3.12.3/bin/python" "$py/pypy3.10-7.3.15/bin/python" \
    "$py/3.9.1/envs/work/bin/python" "$py/work" "$h/.pyenv/version" "$h/.pyenv/shims/python" "$rb/3.3.0/bin/ruby" \
    "$h/.rbenv/version" "$h/.rbenv/shims/ruby" "$rs/stable-$host/bin/rustc" "$rs/1.70.0-$host/bin/rustc" "$rs/custom" \
    "$h/.rustup/settings.toml" "$h/.rustup/downloads/abc.partial" "$h/.rustup/update-hashes/stable-$host" \
    "$sdk/go1.22.0/bin/go" "$sdk/notes.txt" "$sdk/other" "$WORK/custom-rust"; do
    assert_exists "$f"
  done
  # a default that can't be told keeps every version of that tool
  sized "$py/3.8.0/bin/python" 10; sized "$rb/3.0.0/bin/ruby" 10; sized "$rs/beta-$host/bin/rustc" 10; sized "$sdk/go1.19/bin/go" 10
  printf '3.13\n' >"$h/.pyenv/version"                             # nothing installed matches
  printf 'profile = "default"\n' >"$h/.rustup/settings.toml"       # rustup default none
  printf '#!/bin/sh\nexit 1\n' >"$h/.local/bin/go"                  # a go that fails
  : >"$h/.rbenv/version"
  assert_eq "$(details)" "" "no default: nothing listed"
  # system: no pyenv version is the default; PYENV_ROOT from your profile; a Go SDK the profile picks by variable
  printf 'system\n' >"$h/.pyenv/version"; mv "$h/.pyenv" "$h/pyenv2"; printf 'export PYENV_ROOT="$HOME/pyenv2"\n' >"$h/.profile"
  rm "$h/.local/bin/go"; printf 'export PATH=$HOME/sdk/$GOVERSION/bin:$PATH\n' >>"$h/.profile"
  assert_eq "$(details)" "Python 3.11.4 off|Python 3.12.1 off|Python 3.12.3 off|Python 3.8.0 off|Python pypy3.10-7.3.15 off" \
    "system lists them all, Go keeps every SDK"
  # the go a profile PATH line names keeps its SDK; no go at all and no SDK named keeps everything
  printf 'export PATH=$HOME/sdk/go1.19/bin:$PATH\n' >"$h/.profile"
  assert_eq "$(details)" "Go 1.22.0 off" "the Go SDK on the profile's PATH kept"
  mkdir -p "$h/.pyenv/versions"; : >"$h/.profile"
  # the usual folders the app also looks in (/usr/local/go/bin, …) can't be taken off a machine that has Go there
  if [[ ! -x /usr/local/go/bin/go && ! -x /usr/lib/go/bin/go && ! -x /usr/bin/go && ! -x /snap/bin/go ]]; then
    assert_eq "$(details)" "" "no go command: every Go SDK kept"
  fi
  unset -f details
}

# asdf and mise: per tool the newest stays, and what ~/.tool-versions, mise's settings and the projects in
# your home pin; mise's alias links are neither listed nor touched
test_old_asdf_and_mise_versions() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR out pid hold=() f enc bin=$WORK/misebin
  local an=$h/.asdf/installs/nodejs ap=$h/.asdf/installs/python aj=$h/.asdf/installs/java
  local mn=$h/.local/share/mise/installs/node mr=$h/.local/share/mise/installs/ruby mg=$h/.local/share/mise/installs/go
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  local labels='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["label"], e["bytes"], "on" if e["selected"] else "off")
    elif e["event"] == "item": print(e["status"], e["note"], repr(e["locked"]), e["selected"], e["entries"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"])
    elif e["event"] == "error": print("error", e["message"])'
  details() { user_cm --json details old_runtimes_asdf_mise | python3 -c "$labels" | cut -d' ' -f1-3 | LC_ALL=C sort | paste -sd'|' -; }
  assert_eq "$(user_cm --json scan --only dev | grep -c '"id":"old_runtimes_asdf_mise"')" "0" "no asdf or mise: not shown"
  # asdf: nodejs 20 (a partial pin) and lts, python with a prerelease, java pinned in a way that can't be read
  for f in 20.10.0 20.11.1 22.1.0 ref-main; do sized "$an/$f/bin/node" 1000; done
  sized "$an/18.19.0/bin/node" 3000
  for f in 3.10.0 3.11.4 3.12.1 3.13.0rc1; do sized "$ap/$f/bin/python" 1000; done
  for f in temurin-17.0.9+9 temurin-21.0.2+13; do sized "$aj/$f/bin/java" 1000; done
  new "$h/.asdf/shims/node"; new "$h/.asdf/plugins/nodejs/bin/install"
  # mise: alias links lts and 20, ruby pinned 3.2, go pinned by a project's .tool-versions (asdf's name golang)
  for f in 18.0.0 20.18.0 22.11.0; do sized "$mn/$f/bin/node" 1000; done
  ln -s 22.11.0 "$mn/lts"; ln -s "$mn/20.18.0" "$mn/20"; new "$mn/.mise.backend"
  for f in 3.1.4 3.2.2 3.3.0; do sized "$mr/$f/bin/ruby" 1000; done
  for f in 1.21.0 1.22.0 1.23.0; do sized "$mg/$f/bin/go" 1000; done
  printf 'nodejs 20 # LTS\npython 3.11.4\n' >"$h/.tool-versions"
  mkdir -p "$h/code/app/.mise" "$h/work/api" "$h/work/jvm"
  printf '[env]\nnode = "18"\n\n[tools]\nnode = "lts"\nruby = [\n  "3.2",\n]\n' >"$h/code/app/mise.toml"
  printf 'golang 1.21.0\n' >"$h/work/api/.tool-versions"
  printf '[tools.java]\nversion = "{{ env.JAVA }}"\n' >"$h/work/jvm/.mise.toml"
  out=$(user_cm --json scan --only dev | grep '"id":"old_runtimes_asdf_mise"' | python3 -c "$labels")
  assert_eq "$out" "found 6 versions not pinned, not the newest '' False True" "found, not ticked, one by one"
  assert_eq "$(details)" "go 1.22.0 (mise)|node 18.0.0 (mise)|nodejs 18.19.0 (asdf)|nodejs 20.10.0 (asdf)|python 3.10.0 (asdf)|ruby 3.1.4 (mise)" \
    "only versions neither pinned nor the newest"
  assert_eq "$(user_cm --json details old_runtimes_asdf_mise | python3 -c "$labels" | head -n 1 | cut -d' ' -f4-)" \
    "$(tbytes "$an/18.19.0") off" "each version with its size, biggest first"
  out=$(cm --scan --only dev 2>&1)
  assert_contains "$out" "Old runtime versions (asdf, mise)"
  # mise running: the item is skipped and says why
  running_stub "$bin" mise
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json scan --only dev | grep '"id":"old_runtimes_asdf_mise"' | python3 -c "$labels")
  assert_contains "$out" "'mise'"
  assert_contains "$(BASE_PATH="$bin:$BASE_PATH" cm --scan --only dev 2>&1)" "close mise first"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean old_runtimes_asdf_mise 2>&1)
  assert_contains "$out" '"id":"old_runtimes_asdf_mise","state":"skip"'
  assert_exists "$an/18.19.0/bin/node"
  # a version a program runs from is skipped, and the scan says so
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  rm "$ap/3.10.0/bin/python"; cp "$(command -v sleep)" "$ap/3.10.0/bin/python"
  "${hold[@]}" "$ap/3.10.0/bin/python" 60 >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(user_cm --json scan --only dev | grep '"id":"old_runtimes_asdf_mise"' | python3 -c "$labels")
  assert_contains "$out" "5 versions not pinned, not the newest; skipped while running: python 3.10.0 (asdf)"
  # automatic cleaning leaves them alone even when ticked
  select_only old_runtimes_asdf_mise
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$an/18.19.0/bin/node"
  out=$(user_cm --json clean old_runtimes_asdf_mise --entries "../etc" | python3 -c "$labels")
  assert_contains "$out" "error Not an entry ID of old_runtimes_asdf_mise: ../etc"
  enc=$(in_app "urlencode_path '$mn/18.0.0'")
  out=$(user_cm --json clean old_runtimes_asdf_mise --entries "$enc" | python3 -c "$labels")
  assert_eq "$out" "ok" "one version"
  assert_missing "$mn/18.0.0"; assert_exists "$an/18.19.0/bin/node"
  out=$(user_cm --json clean old_runtimes_asdf_mise | python3 -c "$labels")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok" "the rest"
  for f in "$an/18.19.0" "$an/20.10.0" "$mg/1.22.0"; do assert_missing "$f"; done
  for f in "$an/20.11.1/bin/node" "$an/22.1.0/bin/node" "$an/ref-main/bin/node" "$ap/3.10.0/bin/python" "$ap/3.11.4/bin/python" \
    "$ap/3.12.1/bin/python" "$ap/3.13.0rc1/bin/python" "$aj/temurin-17.0.9+9/bin/java" "$aj/temurin-21.0.2+13/bin/java" \
    "$h/.asdf/shims/node" "$h/.asdf/plugins/nodejs/bin/install" "$mn/20.18.0/bin/node" "$mn/22.11.0/bin/node" "$mn/lts" "$mn/20" \
    "$mn/.mise.backend" "$mr/3.2.2/bin/ruby" "$mr/3.3.0/bin/ruby" "$mg/1.21.0/bin/go" "$mg/1.23.0/bin/go" "$h/.tool-versions" \
    "$h/code/app/mise.toml" "$h/work/api/.tool-versions" "$h/work/jvm/.mise.toml"; do
    assert_exists "$f"
  done
  assert_missing "$mr/3.1.4" # pinned 3.2 keeps only the newest 3.2.x
  # mise's global config.toml and MISE_DATA_DIR from your profile; a profile renaming the settings files keeps everything
  sized "$mn/16.0.0/bin/node" 10; sized "$mr/3.0.0/bin/ruby" 10
  mkdir -p "$h/.config/mise"; printf '[tools]\nnode = { version = "16" }\n' >"$h/.config/mise/config.toml"
  assert_eq "$(details)" "python 3.10.0 (asdf)|ruby 3.0.0 (mise)" "the global config.toml pins node 16"
  mkdir -p "$h/mise-data"; mv "$h/.local/share/mise/installs" "$h/mise-data/installs"
  printf 'export MISE_DATA_DIR="$HOME/mise-data"\n' >"$h/.profile"
  assert_eq "$(details)" "python 3.10.0 (asdf)|ruby 3.0.0 (mise)" "MISE_DATA_DIR from the profile"
  mkdir -p "$h/big"; head -c 300000 /dev/zero | tr '\0' '#' >"$h/big/.tool-versions"
  assert_eq "$(details)" "" "a pin file too big to read: every version kept"
  rm "$h/big/.tool-versions"
  printf 'export MISE_DATA_DIR="$HOME/mise-data"\nexport MISE_DEFAULT_CONFIG_FILENAME=tools.toml\n' >"$h/.profile"
  assert_eq "$(details)" "" "renamed settings files: every version kept"
  unset -f details
}

# How a pin keeps versions: a partial version keeps the newest match, lts Node's two newest even majors, a
# flavor only its own; the newest release stays next to a newer prerelease
test_asdf_mise_pin_rules() {
  fresh_home
  local f=$HOME_DIR/installs/node j=$HOME_DIR/installs/java
  mkdir -p "$f/18.20.0" "$f/18.20.4" "$f/20.11.1" "$f/21.0.0" "$f/22.1.0" "$f/23.0.0-rc.1" "$j/temurin-17.0.9" "$j/temurin-21.0.2" \
    "$j/zulu-17.0.8" "$j/zulu-17.0.9"
  kept() { # FOLDER PIN… → the names it keeps, sorted
    local dir=$1 pins="" p
    shift
    for p; do pins+=$p$'\n'; done
    in_app "AM_PINS_RC=0; AM_PINS[${dir##*/}]=$(printf '%q' "$pins"); names=(); for n in '$dir'/*/; do n=\${n%/}; names+=(\"\${n##*/}\"); done
      am_kept '$dir' \"\${names[@]}\"; printf '%s\\n' \"\${!AM_KEPT[@]}\" | LC_ALL=C sort | paste -sd' ' -"
  }
  assert_eq "$(kept "$f")" "22.1.0 23.0.0-rc.1" "no pin: the newest and the newest release"
  assert_eq "$(kept "$f" 18)" "18.20.4 22.1.0 23.0.0-rc.1" "18 keeps the newest 18.x"
  assert_eq "$(kept "$f" v18.20)" "18.20.4 22.1.0 23.0.0-rc.1" "v18.20 too"
  assert_eq "$(kept "$f" lts)" "20.11.1 22.1.0 23.0.0-rc.1" "lts: the two newest even majors"
  assert_eq "$(kept "$f" 18.20.0 latest system)" "18.20.0 22.1.0 23.0.0-rc.1" "an exact version; latest and system add nothing"
  assert_eq "$(kept "$f" 19)" "22.1.0 23.0.0-rc.1" "nothing installed matches"
  assert_eq "$(kept "$f" 'sub-1:latest')" "18.20.0 18.20.4 20.11.1 21.0.0 22.1.0 23.0.0-rc.1" "a pin that can't be read keeps all"
  assert_eq "$(kept "$j")" "temurin-21.0.2 zulu-17.0.9" "the newest of each flavor"
  assert_eq "$(kept "$j" temurin-17)" "temurin-17.0.9 temurin-21.0.2 zulu-17.0.9" "a flavor's pin keeps only its own"
  unset -f kept
}

test_old_vagrant_boxes() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR vb=$HOME_DIR/.vagrant.d out enc bin=$WORK/vagrantbin
  local labels='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["label"], "on" if e["selected"] else "off")
    elif e["event"] == "item": print(e["id"], e["status"], e["note"], e["selected"], e["entries"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"])'
  details() { user_cm --json details vagrant_old_boxes | python3 -c "$labels" | LC_ALL=C sort | paste -sd'|' -; }
  assert_eq "$(user_cm --json scan --only dev | grep vagrant_old_boxes)" "" "no Vagrant: not shown"
  assert_contains "$(cm --json items)" '"id":"vagrant_old_boxes"'
  for v in 20230101.0.0 20240101.0.0 20250101.0.0; do sized "$vb/boxes/ubuntu-VAGRANTSLASH-jammy64/$v/virtualbox/box.vmdk" 2000; done
  sized "$vb/boxes/ubuntu-VAGRANTSLASH-jammy64/20230101.0.0/libvirt/box.img" 1000
  sized "$vb/boxes/debian-VAGRANTSLASH-bookworm64/12.1/libvirt/box.img" 1000
  sized "$vb/boxes/debian-VAGRANTSLASH-bookworm64/12.10/libvirt/box.img" 1000
  sized "$vb/boxes/single/1.0/virtualbox/box.vmdk" 1000
  sized "$h/proj/.vagrant/machines/default/virtualbox/id" 10
  mkdir -p "$vb/data/machine-index"
  printf '{"version":1,"machines":{"abc":{"name":"default","provider":"virtualbox","extra_data":{"box":{"name":"ubuntu/jammy64","provider":"virtualbox","version":"20240101.0.0"}}}}}' >"$vb/data/machine-index/index"
  out=$(user_cm --json scan --only dev | grep vagrant_old_boxes | python3 -c "$labels")
  assert_eq "$out" "vagrant_old_boxes found 3 versions not pinned, not the newest False True" "found, not ticked, one by one"
  assert_eq "$(details)" "debian/bookworm64 12.1 (libvirt) off|ubuntu/jammy64 20230101.0.0 (libvirt) off|ubuntu/jammy64 20230101.0.0 (virtualbox) off" \
    "old versions only: newest (12.10 > 12.1) and the machine's are kept"
  # an index that can't be read: nothing offered
  cp "$vb/data/machine-index/index" "$WORK/vagrant-index"
  printf '{"machines": ' >"$vb/data/machine-index/index"
  assert_eq "$(details)" "" "broken machine index: nothing offered"
  cp "$WORK/vagrant-index" "$vb/data/machine-index/index"
  # vagrant running: skipped
  running_stub "$bin" vagrant
  assert_contains "$(BASE_PATH="$bin:$BASE_PATH" cm --scan --only dev 2>&1)" "close vagrant first"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean vagrant_old_boxes 2>&1)
  assert_contains "$out" '"id":"vagrant_old_boxes","state":"skip"'
  assert_exists "$vb/boxes/debian-VAGRANTSLASH-bookworm64/12.1"
  # automatic cleaning leaves them alone even when ticked
  select_only vagrant_old_boxes
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$vb/boxes/debian-VAGRANTSLASH-bookworm64/12.1"
  enc=$(in_app "urlencode_path '$vb/boxes/debian-VAGRANTSLASH-bookworm64/12.1/libvirt'")
  assert_eq "$(user_cm --json clean vagrant_old_boxes --entries "$enc" | python3 -c "$labels")" "ok" "one version"
  assert_missing "$vb/boxes/debian-VAGRANTSLASH-bookworm64/12.1"
  assert_eq "$(user_cm --json clean vagrant_old_boxes | python3 -c "$labels")" "ok" "the rest"
  assert_missing "$vb/boxes/ubuntu-VAGRANTSLASH-jammy64/20230101.0.0"
  for f in ubuntu-VAGRANTSLASH-jammy64/20240101.0.0 ubuntu-VAGRANTSLASH-jammy64/20250101.0.0 debian-VAGRANTSLASH-bookworm64/12.10 single/1.0; do
    assert_exists "$vb/boxes/$f"
  done
  assert_exists "$h/proj/.vagrant/machines/default/virtualbox/id"
  # Vagrant 2.4 multi-arch layout: the provider is the label, the arch beside it
  sized "$vb/boxes/arm/1/arm64/libvirt/metadata.json" 10; sized "$vb/boxes/arm/2/arm64/libvirt/metadata.json" 10
  assert_eq "$(details)" "arm 1 (libvirt, arm64) off" "multi-arch layout"
  assert_eq "$(user_cm --json clean vagrant_old_boxes | python3 -c "$labels")" "ok" "multi-arch clean"
  assert_missing "$vb/boxes/arm/1"; assert_exists "$vb/boxes/arm/2/arm64/libvirt/metadata.json"
  # a machine naming a box without a version keeps every version of it
  sized "$vb/boxes/arm/1/arm64/libvirt/metadata.json" 10
  printf '{"version":1,"machines":{"a":{"extra_data":{"box":{"name":"arm","provider":"libvirt"}}}}}' >"$vb/data/machine-index/index"
  assert_eq "$(details)" "ubuntu/jammy64 20240101.0.0 (virtualbox) off" "box named without a version: all kept; others no longer pinned"
  # VAGRANT_HOME inside your home
  sized "$h/vg/boxes/b/1/libvirt/box.img" 10; sized "$h/vg/boxes/b/2/libvirt/box.img" 10
  printf 'export VAGRANT_HOME="$HOME/vg"\n' >"$h/.bashrc"
  assert_eq "$(details)" "b 1 (libvirt) off" "VAGRANT_HOME is followed"
  unset -f details
}

test_old_unity_editor_versions_and_caches() {
  command -v python3 >/dev/null || { SKIPPED="python3 not available"; return; }
  fresh_home
  local h=$HOME_DIR ed=$HOME_DIR/Unity/Hub/Editor hub=$HOME_DIR/.config/UnityHub out pid enc v hold=() bin=$WORK/unitybin
  ((EUID == 0)) && hold=(setpriv --reuid=65534 --regid=65534 --clear-groups) # user_cm runs as nobody
  local labels='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "entry": print(e["label"], e["bytes"], "on" if e["selected"] else "off")
    elif e["event"] == "item": print(e["id"], e["status"], e["note"], repr(e["locked"]), e["selected"], e["entries"])
    elif e["event"] == "task" and e["state"] != "run": print(e["state"])
    elif e["event"] == "error": print("error", e["message"])'
  details() { user_cm --json details unity_old_editors | python3 -c "$labels" | cut -d' ' -f1-2 | LC_ALL=C sort | paste -sd'|' -; }
  scan() { user_cm --json scan --only dev | grep -E '"id":"unity_(old_editors|caches)"' | python3 -c "$labels"; }
  assert_eq "$(scan)" "" "no Unity: neither item shown"
  out=$(cm --json items | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "item" and e["id"].startswith("unity_"): print(e["id"], e["category"], e["default"])')
  assert_eq "$out" $'unity_old_editors dev False\nunity_caches dev False' "--json items: both items, not ticked"
  # three versions and a project pinning the middle one: only the oldest is offered
  for v in 2021.3.5f1 2022.3.10f1 6000.0.23f1; do sized "$ed/$v/Editor/Unity" 1000; sized "$ed/$v/Editor/Data/big" 3000; done
  mkdir -p "$ed/2023.1.0f1/Editor" "$ed/custom/Editor"; sized "$ed/custom/Editor/Unity" 10 # no program; not a version
  mkdir -p "$h/games/kart/ProjectSettings"
  printf 'm_EditorVersion: 2022.3.10f1\r\nm_EditorVersionWithRevision: 2022.3.10f1 (ff3792e53c62)\r\n' \
    >"$h/games/kart/ProjectSettings/ProjectVersion.txt"
  out=$(scan)
  assert_eq "$out" "unity_old_editors found 1 version not pinned, not the newest '' False True" "found, not ticked, one by one"
  assert_eq "$(user_cm --json details unity_old_editors | python3 -c "$labels")" "Unity 2021.3.5f1 $(tbytes "$ed/2021.3.5f1") off" \
    "the unpinned old version with its size"
  # no pin: every version but the newest; a newer beta keeps the newest release too
  rm "$h/games/kart/ProjectSettings/ProjectVersion.txt"
  assert_eq "$(details)" "Unity 2021.3.5f1|Unity 2022.3.10f1" "unpinned: all but the newest"
  sized "$ed/6000.1.0b2/Editor/Unity" 10
  assert_eq "$(details)" "Unity 2021.3.5f1|Unity 2022.3.10f1" "a newer beta keeps the newest release"
  # Hub's settings: its install folder, its project list (a "version" and a project's own file) and projects folder
  mkdir -p "$hub" "$h/Editors/2020.3.48f1/Editor" "$h/.hidden/racer/ProjectSettings" "$h/UnityProjects/puzzle/ProjectSettings"
  sized "$h/Editors/2020.3.48f1/Editor/Unity" 10; sized "$h/Editors/2019.4.40f1/Editor/Unity" 10
  printf '"%s"' "$h/Editors" >"$hub/secondaryInstallPath.json"
  printf '{"schema_version":"v1","data":{"%s":{"title":"racer","path":"%s","version":"2019.4.40f1"},"x":{"path":7}}}' \
    "$h/.hidden/racer" "$h/.hidden/racer" >"$hub/projects-v1.json"
  printf 'm_EditorVersion: 2020.3.48f1\n' >"$h/.hidden/racer/ProjectSettings/ProjectVersion.txt"
  printf '{"directoryPath":"%s"}' "$h/UnityProjects" >"$hub/projectDir.json"
  printf 'm_EditorVersion: 2021.3.5f1\n' >"$h/UnityProjects/puzzle/ProjectSettings/ProjectVersion.txt"
  assert_eq "$(details)" "Unity 2022.3.10f1" "Hub's install folder, project list and projects folder"
  assert_eq "$(BASE_PATH=$(path_without jq) details)" "Unity 2022.3.10f1" "the same without jq"
  cp "$hub/projects-v1.json" "$WORK/unity-projects.json"
  printf '{"data": ' >"$hub/projects-v1.json"
  assert_eq "$(details)" "" "Hub's project list can't be read: nothing offered"
  cp "$WORK/unity-projects.json" "$hub/projects-v1.json"
  sized "$ed/2018.4.36f1/Editor/Unity" 10
  # Unity or Unity Hub running: the item is skipped and says why
  running_stub "$bin" unityhub
  out=$(BASE_PATH="$bin:$BASE_PATH" scan | grep unity_old_editors)
  assert_contains "$out" "'unityhub'"
  assert_contains "$(BASE_PATH="$bin:$BASE_PATH" cm --scan --only dev 2>&1)" "close unityhub first"
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean unity_old_editors 2>&1)
  assert_contains "$out" '"id":"unity_old_editors","state":"skip"'
  assert_exists "$ed/2022.3.10f1/Editor/Unity"
  # a version a program runs from is skipped, and the scan says so
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  rm "$ed/2022.3.10f1/Editor/Unity"; cp "$(command -v sleep)" "$ed/2022.3.10f1/Editor/Unity"
  "${hold[@]}" "$ed/2022.3.10f1/Editor/Unity" 60 >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  out=$(scan | grep unity_old_editors)
  assert_contains "$out" "1 version not pinned, not the newest; skipped while running: Unity 2022.3.10f1"
  # automatic cleaning leaves them alone even when ticked
  select_only unity_old_editors
  user_cm --auto >/dev/null 2>&1 </dev/null
  assert_exists "$ed/2018.4.36f1/Editor/Unity"
  out=$(user_cm --json clean unity_old_editors --entries "../etc" | python3 -c "$labels")
  assert_contains "$out" "error Not an entry ID of unity_old_editors: ../etc"
  enc=$(in_app "urlencode_path '$ed/2022.3.10f1'")
  out=$(user_cm --json clean unity_old_editors --entries "$enc" | python3 -c "$labels")
  assert_eq "$out" "fail" "a running version can't be picked"
  assert_exists "$ed/2022.3.10f1/Editor/Unity"
  enc=$(in_app "urlencode_path '$ed/2018.4.36f1'")
  out=$(user_cm --json clean unity_old_editors --entries "$enc" | python3 -c "$labels")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_eq "$out" "ok" "one version"
  assert_missing "$ed/2018.4.36f1"
  out=$(user_cm --json clean unity_old_editors | python3 -c "$labels")
  assert_eq "$out" "ok" "the rest"
  assert_missing "$ed/2022.3.10f1"
  for v in "$ed/2021.3.5f1/Editor/Unity" "$ed/6000.0.23f1/Editor/Unity" "$ed/6000.1.0b2/Editor/Unity" "$ed/2023.1.0f1/Editor" \
    "$ed/custom/Editor/Unity" "$h/Editors/2020.3.48f1/Editor/Unity" "$h/Editors/2019.4.40f1/Editor/Unity" "$hub/secondaryInstallPath.json" "$hub/projectDir.json" \
    "$h/.hidden/racer/ProjectSettings/ProjectVersion.txt" "$h/UnityProjects/puzzle/ProjectSettings/ProjectVersion.txt"; do
    assert_exists "$v"
  done
  # Unity's caches: emptied, never the license, settings, logs or a game's saves; skipped while Unity runs
  new "$h/.cache/unity3d/GiCache/a"; new "$h/.config/unity3d/cache/packages/p.tgz"
  new "$h/.local/share/unity3d/Asset Store-5.x/Pub/pack.unitypackage"
  new "$h/.local/share/unity3d/Unity/Unity_lic.ulf"; new "$h/.config/unity3d/Editor.log"
  new "$h/.config/unity3d/prefs"; new "$h/.config/unity3d/Studio/Game/save.dat"
  ((EUID == 0)) && chown -R 65534:65534 "$HOME_DIR"
  out=$(scan | grep unity_caches | cut -d' ' -f1-2)
  assert_eq "$out" "unity_caches found" "Unity caches found"
  running_stub "$bin" Unity
  out=$(BASE_PATH="$bin:$BASE_PATH" user_cm --json clean unity_caches 2>&1)
  assert_contains "$out" '"id":"unity_caches","state":"skip"'
  assert_exists "$h/.cache/unity3d/GiCache/a"
  out=$(user_cm --json clean unity_caches | python3 -c "$labels")
  assert_eq "$out" "ok" "caches cleaned"
  for v in "$h/.cache/unity3d/GiCache" "$h/.config/unity3d/cache/packages" "$h/.local/share/unity3d/Asset Store-5.x/Pub"; do
    assert_missing "$v"
  done
  for v in "$h/.cache/unity3d" "$h/.local/share/unity3d/Unity/Unity_lic.ulf" "$h/.config/unity3d/Editor.log" \
    "$h/.config/unity3d/prefs" "$h/.config/unity3d/Studio/Game/save.dat"; do
    assert_exists "$v"
  done
  unset -f details scan
}

test_unity_version_order() {
  fresh_home
  local out
  out=$(in_app 'for v in 6000.0.1f1 2020.1.0p1 2019.4.40f1c1 2020.1.0b1 2019.4.40f1 2020.1.0f1 2020.1.0a1 2020.1.0x1 2020.10.0a1; do
      unity_keyv "$v" && printf "%s %s %s\n" "$UV_KEY" "$UV_REL" "$v"; done | LC_ALL=C sort | cut -d" " -f2- | paste -sd" " -
    for v in 2022.3 latest 2022.3.10 2022.3.10f1-dev; do unity_keyv "$v" && echo "read $v"; done')
  assert_eq "$out" "1 2019.4.40f1 1 2019.4.40f1c1 0 2020.1.0x1 0 2020.1.0a1 0 2020.1.0b1 1 2020.1.0f1 1 2020.1.0p1 0 2020.10.0a1 1 6000.0.1f1" \
    "x < a < b < f < p, China builds after; only full Unity versions read"
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
  out=$(BASE_PATH="$bin:$BASE_PATH" in_app 'APP_DESKTOP_DIRS=("$HOME/.local/share/applications" "$HOME/sys"); SESSION_TMP=$HOME
    ui_busy() { wait "$2"; }; load_apps; A_FILTER=year; apps_view; echo "year:${#A_VIEW[@]}"
    for i in "${!A_ID[@]}"; do [[ ${A_ID[i]} == gimp ]] && A_LAST[i]=$((EPOCHSECONDS - 400 * 86400)); done
    apps_view; for i in "${A_VIEW[@]}"; do echo "${A_ID[i]}"; done')
  assert_eq "$out" $'year:0\ngimp' "unused for a year: none at 150 days, gimp at 400"
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
  *fstype*) printf 'Size Used Avail Type\n100000000000 90000000000 5000000000 ext4\n' ;;
  *) printf 'Size Avail\n100000000000 5000000000\n' ;;
esac
STUB
  printf '#!/bin/sh\nprintf "/swap.img file 2147483648\\n/dev/zram0 partition 1073741824\\n"\n' >"$bin/swapon"
  chmod +x "$bin/df" "$bin/swapon"
  local BASE_PATH="$bin:$BASE_PATH"
  ev='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "system": print("system", bool(e["kernel"]), e["threads"] > 0, e["uptime"] >= 0, isinstance(e["apt"], (int, type(None))))
    elif e["event"] == "disk": print("disk", e["mount"], e["fstype"], e["device"], e["size"], e["used"], e["avail"])
    elif e["event"] == "memory": print("memory", e["ram_total"] > 0, e["ram_used"] + e["ram_avail"] == e["ram_total"], e["swap_used"] <= e["swap_total"])
    elif e["event"] == "freed": print("freed", e["bytes"], e["cleanups"], e["lifetime"], e["runs"], e["last_bytes"], e["since"] > 0)
    elif e["event"] == "history": print("history", len(e["points"]))
    elif e["event"] == "outside": print("outside", e["kind"], e["bytes"], e["path"], e["count"], bool(e["note"]))
    elif e["event"] == "top_dirs": print("top_dirs", " ".join(d["path"].replace(e["home"] + "/", "") for d in e["dirs"] if d["bytes"] >= 0))
    elif e["event"] != "protection": print(e["event"])'
  out=$(cm --json overview | python3 -c "$ev")
  [[ $(grep '^top_dirs' <<<"$out") == "top_dirs "*.config* ]] || fail "top_dirs lists the home's folders: $(grep '^top_dirs' <<<"$out")"
  out=$(grep -v '^top_dirs' <<<"$out")
  assert_eq "$out" "system True True True True
disk / ext4 /dev/sda2 100000000000 95000000000 5000000000
disk /boot/efi vfat /dev/sda1 1000000000 100000000 900000000
memory True True True
history 1
outside reserved 5000000000 / 1 True
outside swapfile 2147483648 /swap.img 1 True
done" "system, real filesystems from df, memory, then free-space history, space outside your folders (reserved, swap file, not a swap partition) and the largest folders; no freed group before the first cleanup"
  # free-space history: one point per recorded day, oldest first, today's added by opening the overview
  mkdir -p "$state"
  printf '%s\t%s\t%s\n' 2026-01-01 50000000000 100000000000 2026-01-15 40000000000 100000000000 bad-row 1 2 \
    >"$state/disk-history.tsv"
  out=$(cm --json overview | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "history":
        for p in e["points"]: print(p["time"], p["avail"], p["size"])')
  assert_eq "$out" "$(date -d 2026-01-01 +%s) 50000000000 100000000000
$(date -d 2026-01-15 +%s) 40000000000 100000000000
$(date -d "$(date +%F)" +%s) 5000000000 100000000000" "history points: epoch of each day, free and total bytes on /"
  # largest folders in home, biggest first; Timeshift snapshots count as space outside your folders
  head -c 3000000 /dev/zero >"$HOME_DIR/Videos.big" && mkdir -p "$HOME_DIR/Videos" && mv "$HOME_DIR/Videos.big" "$HOME_DIR/Videos/film"
  mkdir -p "$HOME_DIR/Projects" && head -c 1000000 /dev/zero >"$HOME_DIR/Projects/app"
  out=$(cm --json overview | python3 -c "$ev" | grep top_dirs)
  assert_contains "$out" "top_dirs Videos Projects ."
  mkdir -p "$WORK/ts/snapshots/2026-10-01_10-00-00" "$WORK/ts/snapshots/2026-10-08_10-00-00"
  out=$(in_app "timeshift_snapshot_dirs() { echo '$WORK/ts/snapshots'; }; hidden_space_rows" | grep '^timeshift')
  assert_contains "$out" $'\t'"$WORK/ts/snapshots"$'\t2\t'"delete old ones in Timeshift"
  assert_contains "$(in_app "timeshift_snapshot_dirs() { echo '$WORK/ts/snapshots'; }; hidden_space_lines")" "Timeshift: 2 snapshots"
  mkdir -p "$state"
  printf '%s\t5000\n%s\t1000\n%s\tjunk\n' "$(($(date +%s) - 40 * 86400))" "$(($(date +%s) - 5 * 86400))" "x" >"$state/cleanups.tsv"
  printf 'lifetime=6000\nruns=2\nlast_time=%s\nlast_freed=1000\n' "$(($(date +%s) - 5 * 86400))" >"$state/stats"
  out=$(cm --json overview | python3 -c "$ev" | grep freed)
  assert_eq "$out" "freed 1000 1 6000 2 1000 True" "freed in 30 days counts only the recent cleanup"
  out=$(in_app 'load_kv "$STATS_FILE" STATS "^[0-9]+$"; record_cleanup 2048; tail -n 1 "$CLEANUP_HISTORY"')
  assert_contains "$out" $'\t2048'
  out=$(cm --json overview | python3 -c "$ev" | grep freed)
  assert_eq "$out" "freed 3048 2 8048 3 2048 True" "a cleanup is added to the history"
  # freed per calendar day for the chart: 30 days up to today, 0 on a day without a cleanup
  local by_day='import sys, json
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "freed":
        d = e["freed_by_day"]
        print(len(d), d[-1]["date"] if d else "-", sum(x["bytes"] == 0 and x["cleanups"] == 0 for x in d),
              " ".join("%s=%d/%d" % (x["date"], x["bytes"], x["cleanups"]) for x in d if x["cleanups"]))'
  local today d5
  today=$(date +%F) d5=$(date -d "@$(($(date +%s) - 5 * 86400))" +%F)
  out=$(cm --json overview | python3 -c "$by_day")
  assert_eq "$out" "30 $today 28 $d5=1000/1 $today=2048/1" \
    "freed_by_day: 30 days ending today, the cleanup 40 days ago left out, other days 0"
  printf '%s\t0\n' "$(date +%s)" >>"$state/cleanups.tsv"
  out=$(cm --json overview | python3 -c "$by_day")
  assert_eq "$out" "30 $today 28 $d5=1000/1 $today=2048/2" "a cleanup that freed nothing counts as a cleanup"
  printf 'keep' >"$HOME_DIR/note.txt"
  cm --json trash "$HOME_DIR/note.txt" >/dev/null
  out=$(cm --json overview | python3 -c "$by_day")
  assert_eq "$out" "30 $today 28 $d5=1000/1 $today=2048/2" "moving a file to the Trash is not a cleanup"
  rm "$state/cleanups.tsv"
  out=$(cm --json overview | python3 -c "$by_day")
  assert_eq "$out" "0 - 0 " "no cleanup history (only the totals): no days"
}

test_system_protection() {
  fresh_home
  local bin=$WORK/protbin r=$WORK/sysroot out before
  local sb=$r/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
  mkdir -p "$bin" "$r/etc/ufw" "$r/sys/module/apparmor/parameters" "$r/etc/apt/apt.conf.d" "$r/usr/bin" \
    "$r/run/systemd/system" "${sb%/*}"
  # systemctl answers from $bin/units (UNIT=state), mokutil prints $bin/sb-state; sudo and pkexec record a call
  printf '#!/bin/sh\ngrep -m1 "^$2=" "%s/units" 2>/dev/null | cut -d= -f2\n' "$bin" >"$bin/systemctl"
  printf '#!/bin/sh\ncat "%s/sb-state" 2>/dev/null\n' "$bin" >"$bin/mokutil"
  printf '#!/bin/sh\n[ -e "%s/apt-broken" ] && exit 100\nexit 0\n' "$bin" >"$bin/apt-config" # fails while apt-broken exists
  printf '#!/bin/sh\necho "$0 $*" >>"%s/escalated"\nexit 1\n' "$bin" | tee "$bin/sudo" >"$bin/pkexec"
  chmod +x "$bin/"*
  local BASE_PATH="$bin:$BASE_PATH"
  prot() { in_app "SYSROOT='$r'; protection_rows" | grep "^$1"$'\t' | cut -f2- | tr '\t' ' ' | sed 's/ *$//'; }
  # everything on
  printf '# comment\nIPV6=yes\nENABLED=yes\n' >"$r/etc/ufw/ufw.conf"
  echo Y >"$r/sys/module/apparmor/parameters/enabled"
  printf '#!/bin/sh\n' >"$r/usr/bin/unattended-upgrade" && chmod +x "$r/usr/bin/unattended-upgrade"
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$r/etc/apt/apt.conf.d/20auto-upgrades"
  printf '\006\000\000\000\001' >"$sb"
  printf 'ufw=active\napparmor=active\napt-daily-upgrade.timer=enabled\n' >"$bin/units"
  out=$(in_app "SYSROOT='$r'; protection_rows")
  assert_eq "$out" $'firewall\ton\tufw\t\napparmor\ton\tloaded\t\nupdates\ton\ton\t\nsecureboot\ton\ton\t' "all four on"
  # firewall
  printf 'ENABLED=no\n' >"$r/etc/ufw/ufw.conf"
  assert_eq "$(prot firewall)" "off disabled sudo ufw enable" "ufw switched off"
  printf 'ENABLED="yes"\n' >"$r/etc/ufw/ufw.conf"; sed -i 's/^ufw=.*/ufw=inactive/' "$bin/units"
  assert_eq "$(prot firewall)" "off inactive sudo ufw enable" "ufw on in its config but its service isn't running"
  mv "$r/run/systemd" "$r/run/systemd.off"
  assert_eq "$(prot firewall)" "on ufw" "without systemd running, ufw's config decides"
  mv "$r/run/systemd.off" "$r/run/systemd"
  printf 'ENABLED=maybe\n' >"$r/etc/ufw/ufw.conf"
  assert_eq "$(prot firewall)" "unknown unreadable" "a value it can't read: unknown"
  rm "$r/etc/ufw/ufw.conf"
  assert_eq "$(prot firewall)" "off missing sudo apt install ufw && sudo ufw enable" "no ufw"
  echo firewalld=active >>"$bin/units"
  assert_eq "$(prot firewall)" "on firewalld" "firewalld counts as a firewall"
  # AppArmor
  sed -i 's/^apparmor=.*/apparmor=inactive/' "$bin/units"
  assert_eq "$(prot apparmor)" "off service sudo systemctl enable --now apparmor" "profiles not loaded"
  echo N >"$r/sys/module/apparmor/parameters/enabled"
  assert_eq "$(prot apparmor)" "off kernel" "turned off on the kernel command line: no command"
  rm "$r/sys/module/apparmor/parameters/enabled"
  assert_eq "$(prot apparmor)" "unknown unreadable" "no AppArmor in the kernel: unknown"
  # automatic security updates
  printf 'APT::Periodic::Unattended-Upgrade "0";\n' >"$r/etc/apt/apt.conf.d/99local.dpkg-old"
  assert_eq "$(prot updates)" "on on" "APT skips .dpkg-old files"
  sed -i 's/^apt-daily-upgrade.timer=.*/apt-daily-upgrade.timer=disabled/' "$bin/units"
  assert_eq "$(prot updates)" "off timer sudo systemctl enable --now apt-daily-upgrade.timer" "daily upgrade timer off"
  printf 'apt::periodic::unattended-upgrade "0"; // later file wins\n' >"$r/etc/apt/apt.conf.d/99local"
  assert_eq "$(prot updates)" "off disabled sudo dpkg-reconfigure -plow unattended-upgrades" "a later file turns it off"
  rm "$r/etc/apt/apt.conf.d/99local"; printf 'APT::Periodic::Enable "0";\n' >"$r/etc/apt/apt.conf"
  assert_eq "$(prot updates)" "off disabled sudo dpkg-reconfigure -plow unattended-upgrades" "APT's periodic jobs off"
  rm "$r/etc/apt/apt.conf"; sed -i 's/^apt-daily-upgrade.timer=.*/apt-daily-upgrade.timer=enabled/' "$bin/units"
  assert_eq "$(prot updates)" "on on" "installed and turned on"
  touch "$bin/apt-broken"
  assert_eq "$(prot updates)" "unknown unreadable" "apt-config fails: unknown, no command"
  rm "$bin/apt-broken"
  if ((EUID != 0)); then # root reads anything
    chmod 000 "$r/etc/apt/apt.conf.d"
    assert_eq "$(prot updates)" "unknown unreadable" "APT's settings folder can't be read"
    chmod 755 "$r/etc/apt/apt.conf.d"
    chmod 000 "$r/etc/apt/apt.conf.d/20auto-upgrades"
    assert_eq "$(prot updates)" "unknown unreadable" "a settings file can't be read"
    chmod 644 "$r/etc/apt/apt.conf.d/20auto-upgrades"
  fi
  printf 'APT::Periodic::Enable "0";\n' >"$r/etc/apt/apt.conf"
  rm "$r/usr/bin/unattended-upgrade"
  assert_eq "$(prot updates)" "off missing sudo apt install unattended-upgrades" "package not installed"
  touch "$bin/apt-broken"
  assert_eq "$(prot updates)" "off missing sudo apt install unattended-upgrades" "not installed, even when APT can't be read"
  rm "$bin/apt-broken"
  mv "$r/etc/apt" "$r/etc/apt.off"
  assert_eq "$(prot updates)" "na no-apt" "no APT: not applicable"
  mv "$r/etc/apt.off" "$r/etc/apt"
  # Secure Boot
  printf '\006\000\000\000\000' >"$sb"
  assert_eq "$(prot secureboot)" "off firmware" "EFI variable says off"
  echo "SecureBoot enabled" >"$bin/sb-state"
  assert_eq "$(prot secureboot)" "on on" "mokutil comes first"
  rm "$bin/sb-state" "$sb"
  assert_eq "$(prot secureboot)" "unknown unreadable" "UEFI without the variable: unknown"
  rm -r "$r/sys/firmware"
  assert_eq "$(prot secureboot)" "na legacy" "no UEFI: not applicable"
  # both apps show it; nothing asked for a password, nothing written
  before=$(ls -lAR --time-style=+%s.%N "$r")
  out=$(in_app "SYSROOT='$r'; protection_lines")
  assert_contains "$out" "System protection"
  assert_contains "$out" "sudo apt install unattended-upgrades"
  assert_contains "$out" "Not applicable"
  out=$(CLEANMATE_SYSROOT=$r cm --json overview | grep '"protection"' | python3 -c 'import sys, json
for l in sys.stdin:
    e = json.loads(l); print(e["id"], e["state"], e["reason"], e["command"])')
  assert_eq "$out" "firewall on firewalld 
apparmor unknown unreadable 
updates off missing sudo apt install unattended-upgrades
secureboot na legacy " "--json overview sends one protection event per check"
  [[ -e $bin/escalated ]] && fail "protection asked for root: $(cat "$bin/escalated")"
  assert_eq "$(ls -lAR --time-style=+%s.%N "$r")" "$before" "reading changes no file"
}

test_gui_language_setting() {
  command -v msgfmt >/dev/null && command -v python3 >/dev/null || { SKIPPED="needs gettext and python3"; return; }
  fresh_home
  bash "$ROOT/po/compile.sh" "$WORK/locale" >/dev/null || { fail "po/compile.sh failed"; return; }
  local f=$HOME_DIR/.config/cleanmate/settings
  mkdir -p "${f%/*}"
  gui_text() { # LANG LANGUAGE — "Settings" as the desktop app shows it, and the language it read
    env -i HOME="$HOME_DIR" LANG="$1" ${2:+LANGUAGE=$2} CLEANMATE_LOCALEDIR="$WORK/locale" PYTHONPATH="$ROOT/gui" \
      python3 -c 'from cleanmate_gui import i18n; print(i18n._("Settings"), i18n.AT_LAUNCH)'
  }
  printf 'journal_days=14\n' >"$f"
  assert_eq "$(gui_text C.UTF-8)" "Settings system" "no language saved, English system"
  assert_eq "$(gui_text vi_VN.UTF-8)" "Cài đặt system" "no language saved, Vietnamese system"
  printf 'journal_days=14\nlanguage=vi\n' >"$f"
  assert_eq "$(gui_text C.UTF-8)" "Cài đặt vi" "Tiếng Việt on an English system"
  printf 'language=en\n' >"$f"
  assert_eq "$(gui_text vi_VN.UTF-8 vi)" "Settings en" "English on a Vietnamese system"
  printf 'language=system\n' >"$f"
  assert_eq "$(gui_text vi_VN.UTF-8)" "Cài đặt system" "same as system"
  printf 'language=fr\n' >"$f"
  assert_eq "$(gui_text C.UTF-8)" "Settings system" "a value it doesn't know: same as system"
}

test_gui_scan_texts_translated() {
  command -v msgfmt >/dev/null && command -v python3 >/dev/null || { SKIPPED="needs gettext and python3"; return; }
  fresh_home
  bash "$ROOT/po/compile.sh" "$WORK/locale" >/dev/null || { fail "po/compile.sh failed"; return; }
  local out
  out=$(env -i HOME="$HOME_DIR" LANG=C.UTF-8 LANGUAGE=vi CLEANMATE_LOCALEDIR="$WORK/locale" PYTHONPATH="$ROOT/gui" \
    python3 - <<'PY' 2>&1
from cleanmate_gui.i18n import detail_text, item_text, note_text
notes = {
    "1 file": "1 tệp",
    "12 files in /var/log": "12 tệp trong /var/log",
    "3 files in 2 apps": "3 tệp trong 2 ứng dụng",
    "4 removed packages still configured": "4 gói đã gỡ còn cấu hình",
    "2 files older than 30 days": "2 tệp cũ hơn 30 ngày",
    "5 items untouched for 90+ days": "5 mục không dùng hơn 90 ngày",
    "3 downloads untouched for 7+ days": "3 tệp tải về không dùng hơn 7 ngày",
    "2 items on 1 drive": "2 mục trên 1 ổ",
    "1 history list with entries": "1 danh sách lịch sử có mục",
    "2 projects that no longer exist": "2 dự án không còn tồn tại",
    "40 files in ~/.cache": "40 tệp trong ~/.cache",
    "3 projects idle for 90+ days": "3 dự án không dùng từ 90+ ngày",
    "2 versions not your default; skipped while running: Node 20, Python 3.11":
        "2 phiên bản không phải bản mặc định; bỏ qua vì đang chạy: Node 20, Python 3.11",
    "3 versions not pinned, not the newest; skipped while running: node 18.0.0 (mise)":
        "3 phiên bản không được ghim, không phải bản mới nhất; bỏ qua vì đang chạy: node 18.0.0 (mise)",
    "skipped while running: GoLand": "bỏ qua vì đang chạy: GoLand",
    "1 image no AVD uses": "1 image không AVD nào dùng",
    "3 AVDs": "3 AVD",
    "2 snapshots": "2 snapshot",
    "1 version replaced by a newer one": "1 phiên bản đã có bản mới hơn",
    "2 anonymous volumes — may contain data; 1 named volume kept":
        "2 volume ẩn danh — có thể chứa dữ liệu; giữ 1 volume có tên",
    "2 dangling images, 1 stopped container": "2 image lơ lửng, 1 container đã dừng",
    "1.2 GB in total": "tổng cộng 1.2 GB",
    "get it back with: ollama pull llama3:8b": "lấy lại bằng: ollama pull llama3:8b",
    "not used by any container": "không container nào dùng",
    "BuildKit cache": "Bộ nhớ đệm BuildKit",
    "scan timed out": "quét quá thời gian",
    "3 disabled revisions": "3 bản đã tắt",
    "3 history entries, 2 cookies, 1 download": "3 mục lịch sử, 2 cookie, 1 tệp tải về",
    "needs sqlite3": "cần sqlite3",
    "install sqlite3 to count entries": "cài sqlite3 để đếm số mục",
    "2 dumps": "2 bản dump",
    "~/.cache/thumbnails": "~/.cache/thumbnails",
    "Firefox, Chromium": "Firefox, Chromium",
    "Downloads folder is outside your home folder (/mnt/d); CleanMate only cleans inside it":
        "Thư mục Tải về nằm ngoài thư mục home (/mnt/d); CleanMate chỉ dọn bên trong home",
    "7 widgets in a box": "7 widgets in a box",
}
items = {
    "Cache folders of Slack (Electron app). Rebuilt automatically — close the app before cleaning.":
        "Các thư mục bộ nhớ đệm của Slack (ứng dụng Electron). Tự tạo lại — hãy đóng ứng dụng trước khi dọn.",
    "Cache folders of Spotify (Snap) (Snap spotify). Rebuilt automatically — close the app before cleaning.":
        "Các thư mục bộ nhớ đệm của Spotify (Snap) (Snap spotify). Tự tạo lại — hãy đóng ứng dụng trước khi dọn.",
    "A model downloaded in LM Studio. Download it again from LM Studio's Discover tab.":
        "Một model đã tải trong LM Studio. Tải lại từ thẻ Discover của LM Studio.",
}
details = {
    "  1.2 GB  setup.deb  (45 days old)": "  1.2 GB  setup.deb  (cũ 45 ngày)",
    "  20.0 KB  ~/.config/chromium/Default  (2 history entries, 1 cookie, 0 downloads)":
        "  20.0 KB  ~/.config/chromium/Default  (2 mục lịch sử, 1 cookie, 0 tệp tải về)",
    "setup.deb · 45 days old": "setup.deb · cũ 45 ngày",
    "NDK 27.1.12297006 · 3 days old": "NDK 27.1.12297006 · cũ 3 ngày",
    "SDK Platform 34 · 120 days old": "SDK Platform 34 · cũ 120 ngày",
    "Photos/ · untouched for 120 days": "Photos/ · không đụng tới 120 ngày",
    "~/code/api — target/, .venv/ · 120 days idle": "~/code/api — target/, .venv/ · không dùng 120 ngày",
    "             Node 18  (running, skipped)": "             Node 18  (đang chạy, bỏ qua)",
    "ms-python.python · VS Code  (2 versions)": "ms-python.python · VS Code  (2 phiên bản)",
    "  6.8.0-45  ← running (kept)": "  6.8.0-45  ← đang chạy (giữ lại)",
    "  6.8.0-40  ← kept as a fallback": "  6.8.0-40  ← giữ làm dự phòng",
    "  6.8.0-31  ← will be removed: linux-image-6.8.0-31": "  6.8.0-31  ← sẽ bị xoá: linux-image-6.8.0-31",
    "  80 MB  core (revision 1234)": "  80 MB  core (bản 1234)",
    "  Largest archived journal files:": "  Tệp journal lưu trữ lớn nhất:",
    "  Archived and active journals take up 1.1G in the file system.":
        "  Journal lưu trữ và đang dùng chiếm 1.1G trên hệ thống tệp.",
    "  ~/.zsh_history  (240 commands)": "  ~/.zsh_history  (240 lệnh)",
    "  ~/.cache/x/y": "  ~/.cache/x/y",
    "  1.0 MB  ~/backup (3 files).zip": "  1.0 MB  ~/backup (3 files).zip",
    "  1.0 MB  ~/notes (revision 2).txt": "  1.0 MB  ~/notes (revision 2).txt",
    "  1.0 MB  ~/report 5 days old.pdf": "  1.0 MB  ~/report 5 days old.pdf",
    "backup (3 files).zip · 45 days old": "backup (3 files).zip · cũ 45 ngày",
    "x · untouched for 3 days.mkv · untouched for 12 days": "x · untouched for 3 days.mkv · không đụng tới 12 ngày",
    "  2.0 MB  ~/a (running, skipped) b": "  2.0 MB  ~/a (running, skipped) b",
}
bad = [(f.__name__, k, f(k), v) for table, f in ((notes, note_text), (items, item_text), (details, detail_text))
       for k, v in table.items() if f(k) != v]
print("\n".join(map(repr, bad)) or "ok")
PY
)
  assert_eq "$out" "ok" "notes, scan-time item texts and details lines are translated (unknown ones kept)"
  out=$(env -i HOME="$HOME_DIR" LANG=C.UTF-8 CLEANMATE_LOCALEDIR="$WORK/locale" PYTHONPATH="$ROOT/gui" python3 -c '
from cleanmate_gui.i18n import detail_text, note_text
print(note_text("2 versions not your default; skipped while running: Node 20"), detail_text("a · 3 days old"), sep="|")')
  assert_eq "$out" "2 versions not your default; skipped while running: Node 20|a · 3 days old" "English stays as sent"
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
    "${XDG_DATA_HOME:-$HOME/.local/share}/Trash" \
    -printf '%p %s %T@\n' 2>/dev/null | sort
}
REAL_BEFORE=$(real_dirs)

pass=0 failed=0 skipped=0
printf 'CleanMate tests — %s\n\n' "$(bash "$SCRIPT" --version | head -n 1)"
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
