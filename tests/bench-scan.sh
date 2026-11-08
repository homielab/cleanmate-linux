#!/usr/bin/env bash
#
# Benchmark of Smart Scan on this machine's own system.
#
# Runs `cleanmate.sh --json scan` (what you wait for in the app) in a throwaway
# home, so the system items see this machine and the home items an empty home.
# ROUNDS times (default 5): a first scan with nothing cached, as right after
# installing or removing a package, and a scan again; prints each and the
# median. Then times each item on its own, first and again, and prints the
# SLOWEST (default 5) of each. Last, checks that the unused packages the scan
# finds are the ones `apt-get -s autoremove` lists with the package lists
# loaded. Run it as an ordinary user, like the app, on a machine with many
# packages installed.
#
# With BENCH_LIMITS=FILE (tests/bench-limits.sh in CI) it fails when a median
# is over the limit set there.
#
# Usage: [BENCH_LIMITS=FILE] tests/bench-scan.sh [ROUNDS [SLOWEST]]

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${CLEANMATE_SCRIPT:-$ROOT/cleanmate.sh}
ROUNDS=${1:-5} SLOWEST=${2:-5}
WORK=$(mktemp -d -t cleanmate-bench.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# the same stubs as tests/run.sh
mkdir -p "$WORK/stubs"
for c in sudo pgrep docker podman conda; do printf '#!/bin/sh\nexit 1\n' >"$WORK/stubs/$c"; done
chmod +x "$WORK/stubs/"*
H=$WORK/home
mkdir -p "$H/.config/cleanmate"

run() { env -i HOME="$H" PATH="$WORK/stubs:$PATH" LANG=C.UTF-8 TERM=dumb CLEANMATE_NO_UPDATE_CHECK=1 "$@"; }
secs() { printf '%d.%03d' $(($1 / 1000000)) $(($1 / 1000 % 1000)); } # MICROSECONDS
forget() { rm -rf "$H/.cache/cleanmate"; } # what earlier scans cached
scan() { # → seconds a whole scan takes
  local t0
  t0=${EPOCHREALTIME/[.,]/}
  run bash "$SCRIPT" --json scan >/dev/null
  secs $((${EPOCHREALTIME/[.,]/} - t0))
}
items() { # → "SECONDS<TAB>ID" of each item's scan, one after the other, slowest first
  run bash -c 'source "$1"
    for id in "${ITEM_IDS[@]}"; do
      t0=${EPOCHREALTIME/[.,]/}
      ( SCAN_BYTES=0 SCAN_NOTE=""; "scan_$id" ) </dev/null >/dev/null 2>&1 || true
      printf "%s\t%s\n" $((${EPOCHREALTIME/[.,]/} - t0)) "$id"
    done' _ "$SCRIPT" | sort -t$'\t' -k1,1rn | head -n "$SLOWEST" |
    while IFS=$'\t' read -r us id; do printf '  %s  %s\n' "$(secs "$us")" "$id"; done
}
median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
med() { printf '%s\n' "$@" | median; }

printf '%s packages installed, %d CPUs\n' "$(dpkg-query -W -f='.\n' 2>/dev/null | wc -l)" "$(nproc)"
row() { printf '%-7s %10s %10s\n' "$@"; }
row round "scan 1st" "scan again"
f1=() f2=()
for ((r = 1; r <= ROUNDS; r++)); do
  forget
  s1=$(scan)
  s2=$(scan)
  row "$r" "$s1" "$s2"
  f1+=("$s1") f2+=("$s2")
done
m1=$(med "${f1[@]}") m2=$(med "${f2[@]}")
row median "$m1" "$m2"
over=0
if [[ -n ${BENCH_LIMITS:-} ]]; then
  # shellcheck source=bench-limits.sh
  source "$BENCH_LIMITS"
  over_limit() { awk -v v="$2" -v max="$3" 'BEGIN { exit !(v > max) }' && { echo "SLOW: $1 took ${2} s, the limit is ${3} s ($BENCH_LIMITS)"; over=1; }; } # WHAT SECONDS MAX
  over_limit "median first scan" "$m1" "$SCAN_FIRST_MAX" || true
  over_limit "median scan again" "$m2" "$SCAN_AGAIN_MAX" || true
  lens=$(_lens_time)
  over_limit "lens /" "$lens" "$LENS_MAX" || true
fi

_lens_time() { # seconds one --json lens of / takes (the walk the app's Space Lens waits for)
  local t0
  t0=${EPOCHREALTIME/[.,]/}
  run bash "$SCRIPT" --json lens --path / >/dev/null
  secs $((${EPOCHREALTIME/[.,]/} - t0))
}

forget
echo "slowest items, first:"
items
echo "slowest items, again:"
items

if command -v apt-get >/dev/null; then
  ours=$(run bash -c 'source "$1"; orphan_pkgs' _ "$SCRIPT" | sort)
  apts=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv / {print $2}' | sort)
  if [[ $ours == "$apts" ]]; then
    printf 'unused packages: the same %d as apt-get -s autoremove\n' "$(grep -c . <<<"$ours" || true)"
  else
    echo "unused packages differ from apt-get -s autoremove (< ours, > apt's):"
    diff <(printf '%s\n' "$ours") <(printf '%s\n' "$apts") || true
    exit 1
  fi
fi
((over == 0))
