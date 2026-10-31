#!/usr/bin/env bash
#
# Benchmark of Smart Scan on a home with many idle projects.
#
# Builds a throwaway home with PROJECTS fake projects (default 50), each with a
# node_modules of FILES small files (default 2000); every 3rd also has a Cargo
# target/, every 4th a Python .venv/, every 5th CocoaPods' Pods/, all left
# alone for 200 days. Then, ROUNDS times (default 5), a first scan (no cached
# sizes) and a repeat scan with nothing changed, and prints each and the
# median: of `cleanmate.sh --json scan` (what you wait for in the app) and of
# only the three items that measure projects (node_modules, stale_build_dirs,
# vscode_stale_workspaces, one after the other). The files were just written,
# so every run reads them from memory: this measures the scan's own work, not
# the disk. A whole scan waits for its slowest item (often a system one): it
# takes a few hundred ms even on an empty home and varies by as much, so
# compare medians.
#
# Usage: tests/bench-projects.sh [PROJECTS [FILES [ROUNDS]]]

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${CLEANMATE_SCRIPT:-$ROOT/cleanmate.sh}
N=${1:-50} FILES=${2:-2000} ROUNDS=${3:-5}
WORK=$(mktemp -d -t cleanmate-bench.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# the same stubs as tests/run.sh, plus a node so the node_modules item runs
mkdir -p "$WORK/stubs"
for c in sudo pgrep docker podman conda; do printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/$c"; done
printf '#!/bin/sh\nexit 0\n' >"$WORK/stubs/node"
chmod +x "$WORK/stubs/"*
H=$WORK/home
mkdir -p "$H/.config/cleanmate"

files() { # DIR COUNT PER_FOLDER — COUNT small files in folders of PER_FOLDER
  local d=$1 n=$2 per=$3 i body
  printf -v body '%*s' 900 ''
  for ((i = 0; i < n; i++)); do
    ((i % per)) || mkdir -p "$d/p$((i / per))"
    printf '%s%d\n' "$body" "$i" >"$d/p$((i / per))/f$i.js"
  done
}
files "$WORK/tpl/node_modules" "$FILES" 50
files "$WORK/tpl/target/debug" 300 100
files "$WORK/tpl/.venv/lib" 400 100; : >"$WORK/tpl/.venv/pyvenv.cfg"
files "$WORK/tpl/Pods" 200 50

for ((i = 1; i <= N; i++)); do
  p=$H/code/project-$i
  mkdir -p "$p"
  : >"$p/package.json"; : >"$p/package-lock.json"
  cp -r "$WORK/tpl/node_modules" "$p/"
  ((i % 3)) || { : >"$p/Cargo.toml"; cp -r "$WORK/tpl/target" "$p/"; }
  ((i % 4)) || { : >"$p/pyproject.toml"; cp -r "$WORK/tpl/.venv" "$p/"; }
  ((i % 5)) || { : >"$p/Podfile"; cp -r "$WORK/tpl/Pods" "$p/"; }
done
find "$H/code" -mindepth 2 -maxdepth 2 -exec touch -h -d '200 days ago' {} +

run() { env -i HOME="$H" PATH="$WORK/stubs:$PATH" LANG=C.UTF-8 TERM=dumb CLEANMATE_NO_UPDATE_CHECK=1 "$@"; }
secs() { printf '%d.%03d' $(($1 / 1000000)) $(($1 / 1000 % 1000)); } # MICROSECONDS
bytes_of() { grep -o "\"id\":\"$1\"[^}]*" | grep -o '"bytes":[0-9]*' | cut -d: -f2; } # ID < scan output

scan() { # → "SECONDS NODE_MODULES_BYTES BUILD_FOLDERS_BYTES" of a whole scan
  local t0 out
  t0=${EPOCHREALTIME/[.,]/}
  out=$(run bash "$SCRIPT" --json scan)
  printf '%s %s %s\n' "$(secs $((${EPOCHREALTIME/[.,]/} - t0)))" \
    "$(bytes_of node_modules <<<"$out")" "$(bytes_of stale_build_dirs <<<"$out")"
}
items() { # → seconds the three project items take, one after the other (loading the script not counted)
  run bash -c 'source "$1"
    t0=${EPOCHREALTIME/[.,]/}
    { scan_node_modules; scan_stale_build_dirs; scan_vscode_stale_workspaces; } >/dev/null 2>&1
    echo $((${EPOCHREALTIME/[.,]/} - t0))' _ "$SCRIPT" | tail -n1
}
median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
med() { printf '%s\n' "$@" | median; }

printf '%d projects, %d files in each node_modules, %d CPUs\n' "$N" "$FILES" "$(nproc)"
row() { printf '%-7s %10s %10s %10s %10s %13s %13s\n' "$@"; }
row round "scan 1st" "scan again" "items 1st" "items again" node_modules "build folders"
f1=() f2=() i1=() i2=()
for ((r = 1; r <= ROUNDS; r++)); do
  rm -rf "$H/.cache/cleanmate" # the sizes cached by the last round
  t1=$(secs "$(items)")
  rm -rf "$H/.cache/cleanmate"
  read -r s1 nm sb < <(scan)
  read -r s2 nm2 sb2 < <(scan)
  t2=$(secs "$(items)")
  [[ $nm == "$nm2" && $sb == "$sb2" ]] || echo "sizes differ between the scans: $nm/$sb, then $nm2/$sb2" >&2
  row "$r" "$s1" "$s2" "$t1" "$t2" "$nm" "$sb"
  f1+=("$s1") f2+=("$s2") i1+=("$t1") i2+=("$t2")
done
row median "$(med "${f1[@]}")" "$(med "${f2[@]}")" "$(med "${i1[@]}")" "$(med "${i2[@]}")"
