#!/usr/bin/env bash
#
# Benchmark of Duplicates on a made-up folder of COUNT files (default 20000), all of one SIZE (default 300 KB):
# the worst case, every file has to be read. A tenth are pairs of copies; of the rest, half differ in their
# first bytes (the hash of the first 64 KB tells them apart) and half only in their last bytes (read whole to
# tell). The files are sparse, so they take little disk.
#
# Times `cleanmate.sh --json dupes` ROUNDS times (default 3), prints each and the median, and a checksum of
# the groups found: run it with CLEANMATE_SCRIPT=other/cleanmate.sh to compare two versions.
#
# Usage: tests/bench-dupes.sh [COUNT [ROUNDS [SIZE_BYTES]]]

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${CLEANMATE_SCRIPT:-$ROOT/cleanmate.sh}
COUNT=${1:-20000} ROUNDS=${2:-3} SIZE=${3:-307200}
WORK=$(mktemp -d -t cleanmate-bench.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

H=$WORK/home D=$WORK/home/Files
mkdir -p "$H/.config/cleanmate" "$D"
for ((i = 0; i < COUNT; i += 500)); do mkdir -p "$D/$((i / 500))"; done
name() { REPLY=$D/$(($1 / 500))/f$1.bin; }
for ((i = 0; i < COUNT; i++)); do
  name "$i"
  if ((i < COUNT / 10)); then printf 'pair %d' $((i / 2)) >"$REPLY"     # copies, two by two
  elif ((i % 2)); then printf 'only %d' "$i" >"$REPLY"                  # differs at the start
  else printf 'same start' >"$REPLY"; fi                                # differs at the end
done
find "$D" -type f -print0 | xargs -0 truncate -s $((SIZE - 16))
for ((i = 0; i < COUNT; i++)); do
  name "$i"
  if ((i < COUNT / 10)); then printf '%16d' $((i / 2)) >>"$REPLY"; else printf '%16d' "$i" >>"$REPLY"; fi
done

run() { env -i HOME="$H" PATH="$PATH" LANG=C.UTF-8 TERM=dumb CLEANMATE_NO_UPDATE_CHECK=1 "$@"; }
secs() { printf '%d.%03d' $(($1 / 1000000)) $(($1 / 1000 % 1000)); } # MICROSECONDS
times=()
for ((r = 1; r <= ROUNDS; r++)); do
  t0=${EPOCHREALTIME/[.,]/}
  run bash "$SCRIPT" --json dupes --min 1 --limit 500 --path "$D" >"$WORK/out"
  t=$((${EPOCHREALTIME/[.,]/} - t0))
  times+=("$t")
  echo "round $r: $(secs "$t") s"
done
mapfile -t times < <(printf '%s\n' "${times[@]}" | sort -n)
echo "median: $(secs "${times[ROUNDS / 2]}") s for $COUNT files of $SIZE bytes, $(nproc) CPUs"
echo "groups: $(grep -c '"event":"group"' "$WORK/out"), checksum $(grep '"event":"group"' "$WORK/out" |
  sed -e "s|$D||g" -e 's/,"mtime":[0-9]*//g' | md5sum | cut -c1-12)" # the same for every build of the folder
echo "progress events: $(grep -c '"event":"progress"' "$WORK/out")"
grep '"event":"done"' "$WORK/out"
