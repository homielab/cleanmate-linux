#!/usr/bin/env bash
# Writes the cleanmate(1) man page from `cleanmate.sh --help`, so the two never drift apart.
# Usage: packaging/make-man.sh OUT.1
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: make-man.sh OUT.1}
# HOME=~ prints the log and settings paths as ~/… instead of the builder's home
help=$(env -i HOME='~' PATH="$PATH" LANG=C.UTF-8 bash "$ROOT/cleanmate.sh" --help)
version=$(sed -n 's/^VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/cleanmate.sh" | head -n 1)
date=$(date -u -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)
esc() { sed -e 's/\\/\\e/g' -e "s/^\([.']\)/\\\\\&\1/" -e 's/-/\\-/g'; }
{
  printf '.TH CLEANMATE 1 "%s" "CleanMate %s" "User Commands"\n' "$date" "$version"
  printf '.SH NAME\ncleanmate, cm \\- free up disk space and keep Ubuntu tidy\n'
  printf '.SH SYNOPSIS\n.B cm\n[\\fIoptions\\fR]\n'
  printf '.SH DESCRIPTION\n'
  # first line: the summary; "Usage:" is the synopsis above
  sed -n '1p' <<<"$help" | esc
  # a line on its own, followed by indented lines, is a section; the rest stays as printed
  sed '1,/^Usage:/d' <<<"$help" | esc | awk '
    { line[NR] = $0 }
    END {
      print ".nf"
      for (i = 1; i <= NR; i++) {
        if (line[i] !~ /^ / && line[i] != "" && line[i+1] ~ /^ / && (i == 1 || line[i-1] == "")) {
          print ".fi"; print ".SH \"" toupper(line[i]) "\""; print ".nf"
        } else print line[i]
      }
      print ".fi"
    }'
  printf '.SH SEE ALSO\nThe desktop app: \\fBcleanmate --gui\\fR. Source and bug reports: https://github.com/homielab/cleanmate-linux\n'
} >"$out"
