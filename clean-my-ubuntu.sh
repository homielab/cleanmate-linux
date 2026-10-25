#!/usr/bin/env bash
#
# clean-my-ubuntu.sh — Clean My Ubuntu is now CleanMate (cleanmate.sh).
#
# Copies of Clean My Ubuntu 1.x installed with --install update themselves from this file.
# When it runs, it installs CleanMate — which moves the settings, logs, timer and commands
# over — and hands over to it. Keep VERSION equal to cleanmate.sh's (tests/run.sh checks).
#
# Source: https://github.com/homielab/cleanmate-linux — License: MIT

# shellcheck disable=SC2034 # read by the 1.x updater
VERSION="2.0.0"

set -u
say() { [[ -t 2 ]] && printf '  %s\n' "$*" >&2; return 0; }
here=$(dirname "$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")")
[[ -f $here/cleanmate.sh ]] && exec bash "$here/cleanmate.sh" "$@" # a clone
new=$HOME/.local/bin/cleanmate
if [[ ! -x $new ]]; then
  say "Clean My Ubuntu is now CleanMate — installing it…"
  url=${CLEANMATE_UPDATE_URL:-https://raw.githubusercontent.com/homielab/cleanmate-linux/main/cleanmate.sh}
  tmp=$(mktemp -t cleanmate.XXXXXX) || exit 1
  if command -v curl >/dev/null; then curl -fsSL --max-time 60 -o "$tmp" -- "$url"
  else wget -q -T 60 -O "$tmp" -- "$url"; fi 2>/dev/null &&
    grep -q '^VERSION="' "$tmp" && bash -n "$tmp" 2>/dev/null &&
    bash "$tmp" --install >/dev/null 2>&1 </dev/null
  rm -f -- "$tmp"
  if [[ ! -x $new ]]; then
    printf 'Clean My Ubuntu is now CleanMate, but it could not be installed (offline?).\n' >&2
    printf 'Get it at https://github.com/homielab/cleanmate-linux\n' >&2
    exit 1
  fi
fi
exec "$new" "$@"
