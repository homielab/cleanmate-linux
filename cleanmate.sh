#!/usr/bin/env bash
#
# cleanmate.sh — an interactive system cleaner for Ubuntu,
# inspired by CleanMyMac.
#
# Source, issues and updates: https://github.com/homielab/cleanmate-linux
# Copyright (c) 2026 HomieLab (https://homielab.com) — License: MIT
#
#   Smart Scan · System Junk · User & App Junk · Developer Junk · Space Lens
#   Large & Old Files · Duplicates · Uninstaller · Startup Items · Maintenance
#   System Overview · Settings (automatic cleaning via a systemd user timer)
#
# Usage:  ./cleanmate.sh [--dry-run] [--scan|--clean [--yes]] [--only LIST] [--auto] [--help]
#         ./cleanmate.sh --install      # then just type: cm
#
# Run it as your normal user; sudo is requested only for system-level tasks.
# Keys: ↑↓/jk move · space select · enter/→ open · q/esc/← back

set -o pipefail
shopt -s extglob

VERSION="2.0.0"
MOUSE=1
DRY_RUN=0
MODE=menu
ASSUME_YES=0
INTERACTIVE=1
SUDO_ASKED=0
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cleanmate"
LOG_FILE="$LOG_DIR/clean.log"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cleanmate"

UPDATE_REPO=${CLEANMATE_REPO:-homielab/cleanmate-linux}
REPO_URL="https://github.com/$UPDATE_REPO"
UPDATE_BRANCH=main
RUN_LOG="$LOG_DIR/last-run.log"

# ───────────────────────────── colors & output ──────────────────────────────

if [[ -t 1 && -z ${NO_COLOR:-} ]] && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' NC=$'\e[0m' REV=$'\e[7m'
  RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m'
  MAGENTA=$'\e[35m' CYAN=$'\e[36m'
  if [[ $(tput colors 2>/dev/null) -ge 256 ]]; then ACCENT=$'\e[38;5;44m'; else ACCENT=$CYAN; fi
else
  BOLD="" DIM="" NC="" REV="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" ACCENT=""
fi

info() { printf '  %s•%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '  %s✘%s %s\n' "$RED" "$NC" "$*" >&2; }

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

repeat() { local s="" i; for ((i = 0; i < $2; i++)); do s+=$1; done; printf '%s' "$s"; }
repeatv() { # VAR CHAR N — like repeat, without a subshell
  local -n __rv=$1
  local i
  __rv=""
  for ((i = 0; i < $3; i++)); do __rv+=$2; done
}

humanv() { # VAR BYTES — "1.8 GB" into VAR, pure bash (no subshell: used while redrawing)
  local -n __hv=$1
  local __b=${2:-0} __i=0 __d=1 __t __u=(B KB MB GB TB PB)
  if ((__b < 1024)); then __hv="$__b B"; return; fi
  while ((__b / __d >= 1024 && __i < 5)); do __d=$((__d * 1024)) __i=$((__i + 1)); done
  __t=$(((__b * 10 + __d / 2) / __d)) # tenths, rounded to nearest
  if ((__t >= 10240 && __i < 5)); then __d=$((__d * 1024)) __i=$((__i + 1)) __t=$(((__b * 10 + __d / 2) / __d)); fi
  __hv="$((__t / 10)).$((__t % 10)) ${__u[__i]}"
}
human() { local __h; humanv __h "$1"; printf '%s' "$__h"; }

size_color() {
  local b=${1:-0}
  if ((b >= 1073741824)); then printf '%s' "$RED"
  elif ((b >= 104857600)); then printf '%s' "$YELLOW"
  elif ((b > 0)); then printf '%s' "$GREEN"
  else printf '%s' "$DIM"; fi
}
size_colorv() { # VAR BYTES
  local b=${2:-0}
  if ((b >= 1073741824)); then printf -v "$1" '%s' "$RED"
  elif ((b >= 104857600)); then printf -v "$1" '%s' "$YELLOW"
  elif ((b > 0)); then printf -v "$1" '%s' "$GREEN"
  else printf -v "$1" '%s' "$DIM"; fi
}

confirm() { # plain-mode yes/no, default No
  ((ASSUME_YES)) && return 0
  local ans; read -rp "  $1 ${DIM}[y/N]${NC} " ans; [[ $ans =~ ^[Yy] ]]
}

# ───────────────────────────── terminal UI toolkit ──────────────────────────
#
# Screens are drawn into FRAME and written in one go on the alternate screen
# (no flicker, autowrap off so long lines are clipped instead of wrapped).
# ui_list is the scrollable list every screen is built on.

UI_ACTIVE=0
UI_RESIZED=0
TERM_DIRTY=1 # re-read the terminal size on the next frame
UI_TOAST=""
TERM_ROWS=24 TERM_COLS=80 UI_W=80
SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
SPIN_I=0

term_size() {
  local s
  s=$(stty size </dev/tty 2>/dev/null) || s="24 80"
  read -r TERM_ROWS TERM_COLS <<<"$s"
  ((TERM_ROWS > 0)) || TERM_ROWS=24
  ((TERM_COLS > 0)) || TERM_COLS=80
  UI_W=$((TERM_COLS > 110 ? 110 : TERM_COLS))
}

ui_start() {
  ((INTERACTIVE)) && [[ -t 0 && -t 1 ]] || return 0
  UI_ACTIVE=1
  UI_STTY=$(stty -g 2>/dev/null)
  key_mode_on
  { exec {UI_SLEEP_FD}<> <(:); } 2>/dev/null || UI_SLEEP_FD="" # an empty pipe: `read -t` on it sleeps without a fork
  printf '\e[?1049h\e[?25l\e[?7l\e[H\e[2J'
  mouse_on
  trap 'UI_RESIZED=1' WINCH # read_key notices this and triggers a redraw
}

# Mouse: wheel scrolls, click focuses (click again = select/open). SGR mode
# (1006) gives exact coordinates; hold Shift to select text as usual.
mouse_on()  { ((UI_ACTIVE && MOUSE)) && printf '\e[?1000h\e[?1006h'; return 0; }
mouse_off() { ((UI_ACTIVE)) && printf '\e[?1000l\e[?1006l'; return 0; }

ui_stop() {
  ((UI_ACTIVE)) || return 0
  printf '\e[?1000l\e[?1006l\e[?7h\e[?25h\e[?1049l'
  key_mode_off
  [[ -n $UI_SLEEP_FD ]] && exec {UI_SLEEP_FD}<&-
  UI_SLEEP_FD="" UI_ACTIVE=0
}

# While the UI runs, keys reach the app one at a time and are not echoed (also
# keys typed while it is busy), so read_key can see a waiting key without reading it.
UI_STTY="" UI_SLEEP_FD=""
key_mode_on()  { stty -icanon -echo min 1 time 0 2>/dev/null; return 0; }
key_mode_off() { [[ -n $UI_STTY ]] && stty "$UI_STTY" 2>/dev/null; return 0; }

# Temporarily hand the terminal back for prompts (sudo, text input).
term_raw_on()  { ((UI_ACTIVE)) && { mouse_off; key_mode_off; printf '\e[?25h\e[?7h'; }; return 0; }
term_raw_off() { ((UI_ACTIVE)) && { key_mode_on; printf '\e[?25l\e[?7l'; mouse_on; }; return 0; }

fl() { FRAME+="$1"$'\e[K\n'; ((++FRAME_N)); }
frame_begin() { ((TERM_DIRTY)) && { term_size; TERM_DIRTY=0; }; FRAME="" FRAME_N=0; }
frame_flush() { printf '\e[H%s\e[J' "${FRAME%$'\n'}"; }

vlen() { # VAR TEXT — visible length (ANSI codes stripped)
  local p=${2//$'\e'\[*([0-9;])m/}
  printf -v "$1" '%d' "${#p}"
}

fitv() { # VAR TEXT WIDTH — truncate with … and pad to exactly WIDTH characters
  local s=$2 w=$3
  ((w <= 0)) && { printf -v "$1" ''; return; }
  ((${#s} > w)) && s="${s:0:w-1}…"
  printf -v "$1" '%s%*s' "$s" $((w - ${#s})) ""
}

mini_bar() { # VAR PERCENT WIDTH
  local f=$(($2 * $3 / 100)) c a b
  ((f > $3)) && f=$3
  if (($2 >= 90)); then c=$RED; elif (($2 >= 75)); then c=$YELLOW; else c=$GREEN; fi
  repeatv a ━ "$f"; repeatv b ━ $(($3 - f))
  printf -v "$1" '%s%s%s%s%s' "$c" "$a" "$DIM" "$b" "$NC"
}

size_bar() { # VAR BYTES MAX WIDTH — proportional bar coloured by size
  local f=0 c a b
  (($3 > 0)) && f=$(($2 * $4 / $3))
  (($2 > 0 && f == 0)) && f=1
  size_colorv c "$2"
  repeatv a ■ "$f"; repeatv b · $(($4 - f))
  printf -v "$1" '%s%s%s%s%s' "$c" "$a" "$DIM" "$b" "$NC"
}

refresh_sysinfo() {
  local size used avail total mavail
  read -r size used avail < <(df -B1 --output=size,used,avail / | tail -n1)
  read -r total mavail < <(free -b | awk '/^Mem:/ {print $2, $7}')
  SYS_DISK_PCT=$((used * 100 / size)) SYS_DISK_FREE=$(human "$avail")
  SYS_MEM_PCT=$(((total - mavail) * 100 / total)) SYS_MEM_FREE=$(human "$mavail")
}

draw_header() { # TITLE
  local db mb rule badge="" where
  ((DRY_RUN)) && badge="  ${MAGENTA}${BOLD}DRY-RUN${NC}"
  if [[ -n $1 ]]; then where="${DIM} › ${NC}${BOLD}$1${NC}" # version and source link on Home only
  elif ((TERM_COLS >= 70)); then where=" ${DIM}v$VERSION · ${REPO_URL#https://}${NC}"
  else where=" ${DIM}v$VERSION${NC}"; fi
  fl " ${ACCENT}${BOLD}🧹 CleanMate${NC}$where$badge"
  mini_bar db "$SYS_DISK_PCT" 14; mini_bar mb "$SYS_MEM_PCT" 14
  if ((TERM_COLS >= 78)); then
    fl " ${DIM}Disk${NC} $db ${SYS_DISK_PCT}%${DIM} · $SYS_DISK_FREE free${NC}     ${DIM}RAM${NC} $mb ${SYS_MEM_PCT}%${DIM} · $SYS_MEM_FREE free${NC}"
  else
    fl " ${DIM}Disk${NC} $db ${SYS_DISK_PCT}%${DIM} · $SYS_DISK_FREE free${NC}"
  fi
  repeatv rule ─ $((UI_W - 2)); fl " ${DIM}$rule${NC}"
}

hints() { # KEY LABEL ... → HINTS (a key starting with ! is the primary action)
  set -- "$@" "?" help
  local k l s="" plen=0 piece max=$((TERM_COLS - 8))
  while (($# >= 2)); do
    k=$1 l=$2; shift 2
    if [[ $k == !* ]]; then piece="${GREEN}${BOLD}${k#!}${NC} ${BOLD}$l${NC}"; k=${k#!}
    else piece="${ACCENT}$k${NC} ${DIM}$l${NC}"; fi
    ((plen + ${#k} + ${#l} + 4 > max)) && break
    s+="$piece   "; plen=$((plen + ${#k} + ${#l} + 4))
  done
  HINTS=$s
}

draw_footer() { # HINTS — pads the frame so the footer sits at the bottom
  local pad=$((TERM_ROWS - FRAME_N - 3)) rule
  for ((; pad > 0; pad--)); do fl ""; done
  if [[ -n $UI_TOAST ]]; then fl " $UI_TOAST"; UI_TOAST=""; else fl ""; fi
  repeatv rule ─ $((UI_W - 2)); fl " ${DIM}$rule${NC}"
  fl " $1"
}

toast() { UI_TOAST=$1; }

ui_sleep() { # SECONDS
  if [[ -n $UI_SLEEP_FD ]]; then read -rt "$1" -u "$UI_SLEEP_FD"; else sleep "$1"; fi
  return 0
}

# read_key [TIMEOUT] → KEY: up down left right pgup pgdn home end enter space tab
# esc backspace resize wheelup wheeldown click (MOUSE_X/MOUSE_Y) <char>.
# With TIMEOUT it returns 1 when no key arrived (used by busy screens, so that
# keys and mouse sequences are consumed whole and never leak into later screens).
# It waits for a key without reading, then reads it without a timeout: bash
# before 5.3 can lose a key that arrives while `read -t` times out on a terminal.
read_key() {
  local k rest c seq
  if [[ -n ${1:-} ]]; then
    input_pending || { ui_sleep "$1"; input_pending; } || return 1
    IFS= read -rsn1 k || return 1
  else
    until input_pending; do
      if ((UI_RESIZED)); then UI_RESIZED=0 TERM_DIRTY=1; KEY=resize; return 0; fi
      ui_sleep 0.03
    done
    IFS= read -rsn1 k || { KEY=q; sleep 0.1; return 0; } # EOF: back out instead of spinning
  fi
  case $k in
    $'\e')
      IFS= read -rsn2 -t 0.02 rest
      case $rest in
        '[<') # SGR mouse report: ESC [ < button ; x ; y (M = press, m = release)
          seq=""
          while IFS= read -rsn1 -t 0.02 c && [[ $c != [Mm] ]]; do seq+=$c; done
          IFS=';' read -r MOUSE_B _ MOUSE_Y <<<"$seq" # only the row matters
          case $MOUSE_B in
            64) KEY=wheelup ;;
            65) KEY=wheeldown ;;
            0) if [[ $c == M ]]; then KEY=click; else KEY=other; fi ;;
            *) KEY=other ;;
          esac ;;
        '[A' | OA) KEY=up ;; '[B' | OB) KEY=down ;;
        '[C' | OC) KEY=right ;; '[D' | OD) KEY=left ;;
        '[H' | OH) KEY=home ;; '[F' | OF) KEY=end ;;
        '[5') read -rsn1 -t 0.02; KEY=pgup ;;
        '[6') read -rsn1 -t 0.02; KEY=pgdn ;;
        '') KEY=esc ;;
        *) read -rsn6 -t 0.02; KEY=other ;;
      esac ;;
    '') KEY=enter ;;
    ' ') KEY=space ;;
    $'\t') KEY=tab ;;
    $'\x7f' | $'\b') KEY=backspace ;;
    k) KEY=up ;;
    j) KEY=down ;;
    *) KEY=${k,,} ;;
  esac
  return 0
}

# ── ui_list ──
# Caller sets:
#   L_TITLE, L_HINTS            breadcrumb title and footer hints
#   L_COUNT                     number of rows
#   L_ROW fn IDX FOCUSED        appends one row with fl
#   L_FOCUSABLE fn IDX          (optional) succeeds if the row can take focus
#   L_TOP / L_BOTTOM fn         (optional) content above / below the list
#   L_VIEW=1                    read-only viewer: arrows scroll, no cursor
#   L_CUR, L_SCROLL             position, kept between calls
# Returns with KEY set to the first key it does not handle itself.
L_CUR=0 L_SCROLL=0 L_VIEW=0 L_TOP="" L_BOTTOM="" L_FOCUSABLE=""

list_focusable() { [[ -z $L_FOCUSABLE ]] || "$L_FOCUSABLE" "$1"; }

list_move() { # DELTA — move focus, skipping rows that can't take it
  ((L_COUNT > 0)) || return 0
  local step=1 t=$((L_CUR + $1)) c
  (($1 < 0)) && step=-1
  ((t < 0)) && t=0
  ((t >= L_COUNT)) && t=$((L_COUNT - 1))
  c=$t
  while ((c >= 0 && c < L_COUNT)) && ! list_focusable "$c"; do c=$((c + step)); done
  if ((c < 0 || c >= L_COUNT)); then
    c=$t
    while ((c >= 0 && c < L_COUNT)) && ! list_focusable "$c"; do c=$((c - step)); done
  fi
  ((c >= 0 && c < L_COUNT)) && L_CUR=$c
  return 0
}

input_pending() { read -t 0 2>/dev/null; } # a key is already waiting

list_click() { # a click on row MOUSE_Y: focus it; on the focused row → KEY=L_CLICK_KEY (return 1)
  local idx=$((L_SCROLL + MOUSE_Y - L_ROW0))
  ((L_VIEW == 0 && MOUSE_Y >= L_ROW0 && idx >= 0 && idx < L_COUNT && idx < L_SCROLL + L_VIS)) || return 0
  list_focusable "$idx" || return 0
  if ((idx == L_CUR)); then KEY=${L_CLICK_KEY:-space}; return 1; fi
  L_CUR=$idx
  return 0
}

list_find() { # / — jump to the next row whose text contains the query (Enter on / repeats it)
  local q i j
  if [[ -z ${L_TEXT:-} ]]; then toast "${YELLOW}!${NC} Nothing to search on this screen."; return 0; fi
  ui_input "Find:" "${L_FIND:-}" || return 0
  L_FIND=$REPLY_TEXT q=${REPLY_TEXT,,}
  for ((j = 1; j <= L_COUNT; j++)); do
    i=$(((L_CUR + j) % L_COUNT))
    list_focusable "$i" || continue
    TEXT=""
    "$L_TEXT" "$i"
    if [[ ${TEXT,,} == *"$q"* ]]; then
      L_CUR=$i
      toast "${ACCENT}/${NC} “$L_FIND” — press / and Enter for the next match"
      return 0
    fi
  done
  toast "${YELLOW}!${NC} No match for “$L_FIND”."
}

list_key() { # handle navigation keys; returns 1 when the caller must handle KEY
  if ((L_VIEW)); then
    case $KEY in
      up) ((L_SCROLL > 0)) && ((L_SCROLL--)) ;;
      down) ((L_SCROLL++)) ;;
      wheelup) L_SCROLL=$((L_SCROLL > 3 ? L_SCROLL - 3 : 0)) ;;
      wheeldown) L_SCROLL=$((L_SCROLL + 3)) ;;
      pgup) L_SCROLL=$((L_SCROLL - L_VIS)) ;;
      pgdn | space) L_SCROLL=$((L_SCROLL + L_VIS)) ;;
      home) L_SCROLL=0 ;;
      end) L_SCROLL=$L_COUNT ;;
      resize | other | click) ;;
      '?') [[ $L_TITLE == Help ]] || show_help ;;
      *) return 1 ;;
    esac
  else
    case $KEY in
      up | wheelup) list_move -1 ;;
      down | wheeldown) list_move 1 ;;
      pgup) list_move "-$L_VIS" ;;
      pgdn) list_move "$L_VIS" ;;
      home) L_CUR=0; list_move 0 ;;
      end) L_CUR=$((L_COUNT - 1)); list_move 0 ;;
      click) list_click || return 1 ;;
      resize | other) ;;
      '?') show_help ;;
      /) list_find ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

ui_list() {
  local top_n bottom bottom_n vis i saved saved_n pos
  L_VIS=${L_VIS:-10} L_ROW0=${L_ROW0:-5}
  while :; do
    if input_pending; then # catch up with typed-ahead keys first, draw once at the end
      read_key
      list_key || return 0
      continue
    fi
    frame_begin
    draw_header "$L_TITLE"
    [[ -n $L_TOP ]] && "$L_TOP"
    top_n=$FRAME_N
    saved=$FRAME saved_n=$FRAME_N FRAME="" FRAME_N=0
    [[ -n $L_BOTTOM ]] && "$L_BOTTOM"
    bottom=$FRAME bottom_n=$FRAME_N FRAME=$saved FRAME_N=$saved_n

    vis=$((TERM_ROWS - top_n - bottom_n - 3))
    ((vis < 1)) && vis=1
    L_VIS=$vis L_ROW0=$((top_n + 1))
    if ((L_VIEW)); then
      ((L_SCROLL > L_COUNT - vis)) && L_SCROLL=$((L_COUNT - vis))
      ((L_SCROLL < 0)) && L_SCROLL=0
    else
      ((L_CUR >= L_COUNT)) && L_CUR=$((L_COUNT - 1))
      ((L_CUR < 0)) && L_CUR=0
      list_focusable "$L_CUR" || list_move 0
      ((L_CUR < L_SCROLL)) && L_SCROLL=$L_CUR
      ((L_CUR >= L_SCROLL + vis)) && L_SCROLL=$((L_CUR - vis + 1))
      # keep a header row visible when the first item is focused
      ((L_SCROLL > 0 && L_CUR - L_SCROLL < 2 && L_SCROLL <= 2)) && ! list_focusable 0 && L_SCROLL=0
    fi

    for ((i = L_SCROLL; i < L_COUNT && i < L_SCROLL + vis; i++)); do
      "$L_ROW" "$i" $((!L_VIEW && i == L_CUR))
    done
    FRAME+=$bottom FRAME_N=$((FRAME_N + bottom_n))
    pos=""
    if ((L_COUNT > vis)); then
      if ((L_VIEW)); then pos="${DIM}$((L_SCROLL + 1))–$((L_SCROLL + vis > L_COUNT ? L_COUNT : L_SCROLL + vis))/$L_COUNT${NC}   "
      else pos="${DIM}$((L_CUR + 1))/$L_COUNT${NC}   "; fi
    fi
    draw_footer "$pos$L_HINTS"
    frame_flush

    read_key
    list_key || return 0
  done
}

show_help() { # key reference over the current screen; restores the screen's state
  local t=$L_TITLE tp=$L_TOP bt=$L_BOTTOM rw=$L_ROW fc=$L_FOCUSABLE vw=$L_VIEW n=$L_COUNT \
    cu=$L_CUR sc=$L_SCROLL hn=$L_HINTS ck=${L_CLICK_KEY:-} saved_lines=("${V_LINES[@]}")
  V_LINES=("" "  ${BOLD}Moving around${NC}"
    "    ${ACCENT}↑ ↓${NC}  or  ${ACCENT}j k${NC}         move"
    "    ${ACCENT}PgUp PgDn Home End${NC}  jump"
    "    ${ACCENT}mouse wheel${NC}         scroll"
    "    ${ACCENT}click${NC}               focus a row · click it again to select / open"
    "    ${ACCENT}/${NC}                   find a row by name (/ then Enter finds the next one)"
    "" "  ${BOLD}Choosing${NC}"
    "    ${ACCENT}space${NC}               select or deselect (on a group header: the whole group)"
    "    ${ACCENT}enter  →${NC}            open · show details"
    "    ${ACCENT}a  n${NC}                select all / none"
    "    ${ACCENT}h${NC}                   show or hide items that are already clean"
    "    ${ACCENT}z${NC}                   undo: put back what you just moved to the Trash"
    "" "  ${BOLD}Leaving${NC}"
    "    ${ACCENT}q  esc  ←${NC}           back"
    "    ${ACCENT}ctrl+c${NC}              quit at once"
    "" "  ${BOLD}On this screen${NC}" "    $hn"
    "" "  ${BOLD}Good to know${NC}"
    "    ${DIM}Nothing is deleted until you confirm. Try everything safely with --dry-run.${NC}"
    "    ${DIM}The mouse is captured while the app runs — hold Shift to select text.${NC}"
    "    ${DIM}Activity log: ${LOG_FILE/#$HOME/\~}${NC}"
    "" "  ${BOLD}About${NC}"
    "    CleanMate $VERSION · MIT license"
    "    Source code:  ${ACCENT}$REPO_URL${NC}"
    "    Report a bug: ${ACCENT}$REPO_URL/issues${NC}")
  ui_view "Help"
  L_TITLE=$t L_TOP=$tp L_BOTTOM=$bt L_ROW=$rw L_FOCUSABLE=$fc L_VIEW=$vw L_COUNT=$n L_CUR=$cu L_SCROLL=$sc
  L_HINTS=$hn L_CLICK_KEY=$ck V_LINES=("${saved_lines[@]}")
  KEY=resize
}

# ── menus ──
# M_KEY / M_LABEL / M_DESC arrays (an empty label is a spacer row), and
# optionally M_BADGE (right-aligned, consumed by the next ui_menu call).
declare -A MENU_POS=()
declare -a M_BADGE=() MENU_BADGE=()

menu_text() { TEXT=${M_LABEL[$1]}; }
menu_focusable() { [[ -n ${M_LABEL[$1]} && ${M_KEY[$1]} != "#" ]]; }

menu_row() {
  local i=$1 label desc badge="" bw=0 plain
  [[ -n ${M_LABEL[i]} ]] || { fl ""; return; }
  if [[ ${M_KEY[i]} == "#" ]]; then fl "   ${BLUE}${BOLD}${M_LABEL[i]^^}${NC}"; return; fi # section header (one row)
  if [[ -n ${MENU_BADGE[i]:-} ]] && ((UI_W >= 90)); then
    bw=20
    vlen plain "${MENU_BADGE[i]}"
    printf -v badge '%*s%s' $((bw - plain)) "" "${MENU_BADGE[i]}"
  fi
  fitv label "${M_LABEL[i]}" 24
  fitv desc "${M_DESC[i]}" $((UI_W - 36 - bw))
  if (($2)); then fl "  ${ACCENT}${BOLD}▸ ${M_KEY[i]:- }  $label${NC}  $desc$badge"
  else fl "    ${DIM}${M_KEY[i]:- }${NC}  $label  ${DIM}$desc${NC}$badge"; fi
}

ui_menu() { # TITLE [TOP_FN] → MENU_IDX; returns 1 when the user goes back
  local title=$1 i
  local bi
  MENU_BADGE=()
  for bi in "${!M_BADGE[@]}"; do MENU_BADGE[bi]=${M_BADGE[bi]}; done # keep the indices
  M_BADGE=() # badges are opt-in per call
  L_TITLE=${title#Home} L_TOP=${2:-} L_BOTTOM="" L_ROW=menu_row L_FOCUSABLE=menu_focusable L_TEXT=menu_text
  L_VIEW=0 L_COUNT=${#M_LABEL[@]} L_CUR=${MENU_POS[$title]:-0} L_SCROLL=0
  hints "↑↓" move "enter" open "q" back
  L_HINTS=$HINTS
  while :; do
    L_CLICK_KEY=enter
    ui_list
    L_CLICK_KEY=""
    MENU_POS[$title]=$L_CUR
    case $KEY in
      enter | right | space) MENU_IDX=$L_CUR; return 0 ;;
      q | esc | left | backspace) return 1 ;;
      *)
        for i in "${!M_KEY[@]}"; do
          if [[ -n ${M_KEY[i]} && ${M_KEY[i]} == "$KEY" ]]; then
            MENU_IDX=$i L_CUR=$i MENU_POS[$title]=$i
            return 0
          fi
        done ;;
    esac
  done
}

# ── text viewer ──
view_row() { fl "${V_LINES[$1]}"; }

ui_view() { # TITLE [TOP_FN] — scroll through V_LINES
  L_TITLE=$1 L_TOP=${2:-} L_BOTTOM="" L_ROW=view_row L_FOCUSABLE="" L_VIEW=1 L_TEXT=""
  L_COUNT=${#V_LINES[@]} L_SCROLL=0
  hints "↑↓" scroll "q" back
  L_HINTS=$HINTS
  while :; do
    ui_list
    case $KEY in q | esc | left | enter | backspace) L_VIEW=0; return 0 ;; esac
  done
}

# ── dialogs ──

ui_confirm() { # TITLE [BODY] [DEFAULT y|n] → 0 = yes; CONFIRM_LINES (optional) are listed too
  local extra=("${CONFIRM_LINES[@]}")
  CONFIRM_LINES=()
  ((ASSUME_YES)) && return 0
  if ((!UI_ACTIVE)); then
    local l; for l in "${extra[@]}"; do printf '    %s\n' "$l"; done
    confirm "$1${2:+ ($2)}"; return
  fi
  local title=$1 body=${2:-} choice=${3:-n} w iw row col t b yes no btn pad r rule h maxl l x
  w=$((TERM_COLS - 8)); ((w > 64)) && w=64
  iw=$((w - 4))
  maxl=$((TERM_ROWS - 14))
  if ((${#extra[@]} > maxl && maxl > 1)); then
    x=$((${#extra[@]} - maxl + 1)); extra=("${extra[@]:0:maxl-1}" "… and $x more")
  elif ((maxl <= 1)); then extra=()
  fi
  h=$((8 + (${#extra[@]} ? ${#extra[@]} + 1 : 0)))
  row=$(((TERM_ROWS - h) / 2 + 1)); col=$(((TERM_COLS - w) / 2 + 1))
  local bc=$ACCENT
  [[ $title == ⚠* ]] && bc=$RED # dangerous action: red frame
  fitv t "$title" "$iw"; fitv b "$body" "$iw"
  repeatv rule ─ $((w - 2))
  while :; do
    if [[ $choice == y ]]; then yes="${REV}${GREEN}${BOLD}  Yes  ${NC}" no="${DIM}  No  ${NC}"
    else yes="${DIM}  Yes  ${NC}" no="${REV}${BOLD}  No  ${NC}"; fi
    btn="$yes    $no"
    pad=$(((iw - 17) / 2))
    r=$row
    printf '\e[%d;%dH%s╭%s╮%s' $((r++)) "$col" "$bc" "$rule" "$NC"
    printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %s%s%s %s│%s' $((r++)) "$col" "$bc" "$NC" "$BOLD" "$t" "$NC" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %s%s%s %s│%s' $((r++)) "$col" "$bc" "$NC" "$DIM" "$b" "$NC" "$bc" "$NC"
    if ((${#extra[@]})); then
      printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
      for l in "${extra[@]}"; do
        fitv l "$l" "$iw"
        printf '\e[%d;%dH%s│%s %s %s│%s' $((r++)) "$col" "$bc" "$NC" "$l" "$bc" "$NC"
      done
    fi
    printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %*s%s%*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$pad" "" "$btn" $((iw - pad - 17)) "" "$bc" "$NC"
    printf '\e[%d;%dH%s│%s %*s %s│%s' $((r++)) "$col" "$bc" "$NC" "$iw" "" "$bc" "$NC"
    printf '\e[%d;%dH%s╰%s╯%s' $((r++)) "$col" "$bc" "$rule" "$NC"
    read_key
    case $KEY in
      y) return 0 ;;
      n | q | esc) return 1 ;;
      left | right | tab) [[ $choice == y ]] && choice=n || choice=y ;;
      enter | space) [[ $choice == y ]]; return ;;
    esac
  done
}

ui_input() { # PROMPT [DEFAULT] → REPLY_TEXT; returns 1 when left empty
  if ((UI_ACTIVE)); then
    printf '\e[%d;1H\e[K' $((TERM_ROWS - 2))
    term_raw_on
    IFS= read -e -r -p " ? $1 " -i "${2:-}" REPLY_TEXT # no colours: readline would miscount the width
    term_raw_off
  else
    IFS= read -r -p "  $1 " REPLY_TEXT
    REPLY_TEXT=${REPLY_TEXT:-${2:-}}
  fi
  [[ -n $REPLY_TEXT ]]
}

ui_busy() { # MESSAGE PID [COUNT_FILE NOUN] — spinner until PID exits; q/esc cancels (returns 130)
  local n="" k
  while kill -0 "$2" 2>/dev/null; do
    if ((UI_ACTIVE)); then
      [[ -n ${3:-} ]] && n="   ${DIM}$(plural "$(wc -l <"$3" 2>/dev/null || echo 0)" "$4") found so far${NC}"
      frame_begin; draw_header "$UI_BUSY_TITLE"; fl ""
      fl "  ${ACCENT}${SPINNER[SPIN_I++ % 10]}${NC} $1$n"
      [[ -n ${UI_BUSY_STATUS:-} && -s $UI_BUSY_STATUS ]] && fl "    ${DIM}$(<"$UI_BUSY_STATUS")${NC}"
      hints q cancel
      draw_footer "$HINTS"; frame_flush
      if read_key 0.1 && [[ $KEY == q || $KEY == esc ]]; then
        kill_tree "$2"; wait "$2" 2>/dev/null
        toast "${YELLOW}!${NC} Cancelled."
        return 130
      fi
    else
      sleep 0.1
    fi
  done
  wait "$2" 2>/dev/null
  return 0 # the job's own status (e.g. permission errors) is not a cancellation
}

fl_card() { # LINE... — boxed card (lines may contain colors)
  local l w=0 n rule pad
  for l in "$@"; do vlen n "$l"; ((n > w)) && w=$n; done
  w=$((w + 4))
  repeatv rule ─ "$w"
  fl "   ${DIM}╭$rule╮${NC}"
  local sp
  for l in "$@"; do
    vlen n "$l"; pad=$((w - n - 2))
    printf -v sp '%*s' "$pad" ""
    fl "   ${DIM}│${NC}  $l$sp${DIM}│${NC}"
  done
  fl "   ${DIM}╰$rule╯${NC}"
}

# ───────────────────────────── command helpers ──────────────────────────────

# Every destructive action goes through run/run_root so --dry-run is honoured.
run() {
  if ((DRY_RUN)); then
    printf '    %s[dry-run]%s %.140s\n' "$MAGENTA" "$NC" "$*"
    return 0
  fi
  log "$*"
  "$@"
}

run_root() { # credentials are obtained up front by ensure_sudo, so never prompt here
  if ((EUID == 0)); then run "$@"; else run sudo -n "$@"; fi
}

# Use root for read-only scanning if credentials are already cached.
try_root() {
  if ((EUID == 0)); then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

du_bytes() { du -sbx -- "$1" 2>/dev/null | cut -f1; } # PATH → its bytes, this file system only

du_sum() { # total bytes of the existing paths given
  local p ex=()
  for p in "$@"; do [[ -e $p ]] && ex+=("$p"); done
  ((${#ex[@]})) || { echo 0; return; }
  try_root du -scb -- "${ex[@]}" 2>/dev/null | tail -n1 | cut -f1
}

sum_lines() { awk '{s += $1} END {printf "%d\n", s}'; }
count_sum() { awk '{s += $1} END {printf "%d %d\n", NR, s}'; } # sizes on stdin → "COUNT BYTES"

pluralv() { # VAR N WORD → "1 file" / "3 files" / "2 entries" into VAR
  if (($2 == 1)); then printf -v "$1" '%d %s' "$2" "$3"
  elif [[ $3 == *[^aeiou]y ]]; then printf -v "$1" '%d %sies' "$2" "${3%y}"
  else printf -v "$1" '%d %ss' "$2" "$3"; fi
}
plural() { local __p; pluralv __p "$1" "$2"; printf '%s' "$__p"; }

is_protected() {
  local p
  p=$(realpath -m -- "$1")
  [[ $p == /* ]] || return 0
  case $p in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /opt | /proc | /root | \
      /sbin | /srv | /sys | /usr | /usr/* | /var | /var/lib | "$HOME" | "$HOME/.config" | \
      "$HOME/.local" | "$HOME/.local/share") return 0 ;;
  esac
  return 1
}

empty_dir() { # [--root] DIR — delete the contents of DIR, keep DIR itself
  local as_root=0
  [[ $1 == --root ]] && { as_root=1; shift; }
  local d=$1
  [[ -d $d ]] || return 0
  if is_protected "$d"; then err "Refusing to touch protected path: $d"; return 1; fi
  if ((as_root)); then run_root find "$d" -mindepth 1 -delete
  else run find "$d" -mindepth 1 -delete; fi
}

# ── Trash (freedesktop.org Trash spec, like GNOME Files) ──
#
# Files in your home folder are moved into ~/.local/share/Trash by the app
# itself, and files on a drive mounted under /media/$USER (/run/media/$USER) or /mnt into that
# drive's own Trash ($topdir/.Trash/$uid or $topdir/.Trash-$uid), so it knows
# where each one went and can put the last batch back (undo) without copying
# anything across drives. Anything else goes through `gio trash`. Nothing is
# ever deleted permanently by these helpers.

UNDO_BATCH=() # "<trash key><TAB><original path>" of the last trash action
# A trash key is the file's name in your Trash, or its full path in a drive's Trash (".../.Trash-1000/files/NAME").

# Drives the desktop mounts for you (udisks) and the classic /mnt. Tests set
# CLEANMATE_VOLUME_ROOTS (":"-separated); there every folder in a root counts as a drive.
if [[ -n ${CLEANMATE_VOLUME_ROOTS:-} ]]; then IFS=: read -ra VOLUME_ROOTS <<<"$CLEANMATE_VOLUME_ROOTS"
else VOLUME_ROOTS=("/media/${USER:-$(id -un)}" "/run/media/${USER:-$(id -un)}" /mnt); fi

urlencode_path() { # PATH → percent-encoded, as the Trash spec wants for Path=
  local LC_ALL=C s=$1 i c out=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9/._~-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

volume_top_ok() { # DIR — DIR is a drive's top folder: right inside a volume root, a real mount point, no symlinks
  local d=$1 r
  for r in "${VOLUME_ROOTS[@]}"; do
    [[ -n $r && $d == "$r"/* && ${d#"$r"/} != */* ]] || continue
    [[ -d $d && ! -L $d && $(realpath -e -- "$d" 2>/dev/null) == "$d" ]] || return 1
    [[ -n ${CLEANMATE_VOLUME_ROOTS:-} || $(stat -c %m -- "$d" 2>/dev/null) == "$d" ]]
    return
  done
  return 1
}

volume_top() { # VAR PATH (absolute, normalised) — the drive PATH is on, when it can use that drive's Trash
  local -n __vt=$1
  local __p=$2 __r __top __rest
  __vt=""
  for __r in "${VOLUME_ROOTS[@]}"; do
    [[ -n $__r && $__p == "$__r"/*/* ]] || continue
    __rest=${__p#"$__r"/} __top=$__r/${__rest%%/*}
    volume_top_ok "$__top" || return 1
    case ${__p#"$__top"/} in .Trash | .Trash/* | .Trash-*) return 1 ;; esac # already in a Trash
    # same file system as the drive, so the move is a rename (nested mounts go through gio)
    [[ $(stat -c %d -- "$__p" 2>/dev/null) == "$(stat -c %d -- "$__top" 2>/dev/null)" ]] || return 1
    __vt=$__top
    return 0
  done
  return 1
}

trash_dir_ok() { # DIR — a Trash folder of yours: a real folder (not a symlink), owned by you, writable
  [[ -d $1 && ! -L $1 && -O $1 && -w $1 ]]
}

volume_trash_dir() { # VAR TOP — the drive's Trash for you, created if needed (spec: .Trash/$uid, else .Trash-$uid)
  local -n __vd=$1
  local __t
  __vd=""
  __t=$2/.Trash
  if [[ -d $__t && ! -L $__t && -k $__t ]]; then # a shared Trash the admin made (sticky bit)
    [[ -e $__t/$UID || -L $__t/$UID ]] || mkdir -m 700 -- "$__t/$UID" 2>/dev/null
    trash_dir_ok "$__t/$UID" && __vd=$__t/$UID
  fi
  if [[ -z $__vd ]]; then
    __t=$2/.Trash-$UID
    [[ -e $__t || -L $__t ]] || mkdir -m 700 -- "$__t" 2>/dev/null
    trash_dir_ok "$__t" && __vd=$__t
  fi
  [[ -n $__vd ]] || return 1
  [[ -e $__vd/files || -L $__vd/files ]] || mkdir -m 700 -- "$__vd/files" 2>/dev/null
  [[ -e $__vd/info || -L $__vd/info ]] || mkdir -m 700 -- "$__vd/info" 2>/dev/null
  trash_dir_ok "$__vd/files" && trash_dir_ok "$__vd/info"
}

trash_locate() { # KEY → TL_DIR (Trash folder), TL_NAME, TL_TOP (where its files may go back); 1 if not a valid key
  local key=$1 dir
  TL_DIR="" TL_NAME=${key##*/} TL_TOP=""
  [[ -n $TL_NAME && $TL_NAME != . && $TL_NAME != .. ]] || return 1
  if [[ $key != */* ]]; then TL_DIR=$TRASH_DIR TL_TOP=$HOME; return 0; fi
  dir=${key%/*}
  [[ $dir == */files ]] || return 1
  dir=${dir%/files}
  case $dir in
    */.Trash-"$UID") TL_TOP=${dir%/.Trash-"$UID"} ;;
    */.Trash/"$UID") TL_TOP=${dir%/.Trash/"$UID"} ;;
    *) return 1 ;;
  esac
  volume_top_ok "$TL_TOP" && trash_dir_ok "$dir" && trash_dir_ok "$dir/files" &&
    [[ $(realpath -e -- "$dir" 2>/dev/null) == "$dir" ]] || { TL_TOP=""; return 1; }
  TL_DIR=$dir
}

trash_into() { # PATH DIR KEY_PREFIX PATH_VALUE — move PATH into the Trash folder DIR, recorded for undo
  local p=$1 dir=$2 prefix=$3 value=$4 base name n=1 files=$2/files info=$2/info
  base=${p##*/} name=${p##*/}
  while [[ -e $files/$name || -L $files/$name || -e $info/$name.trashinfo ]]; do
    n=$((n + 1)) name="$base.$n"
  done
  # write the .trashinfo first (as the spec asks), then move the file
  printf '[Trash Info]\nPath=%s\nDeletionDate=%(%Y-%m-%dT%H:%M:%S)T\n' "$(urlencode_path "$value")" -1 \
    >"$info/$name.trashinfo" || return 1
  if mv -- "$p" "$files/$name" 2>/dev/null; then
    log "trash $p"
    UNDO_BATCH+=("$prefix$name"$'\t'"$p")
    return 0
  fi
  rm -f -- "$info/$name.trashinfo"
  return 1
}

trash_put() { # PATH (inside $HOME) → moved to the Trash, recorded for undo
  local p=$1
  [[ -e $p || -L $p ]] || return 1
  if ((DRY_RUN)); then run mv -- "$p" "$TRASH_DIR/files/"; return 0; fi
  if [[ ! -d $TRASH_DIR ]]; then mkdir -p "$TRASH_DIR" && chmod 700 "$TRASH_DIR" || return 1; fi
  mkdir -p "$TRASH_DIR/files" "$TRASH_DIR/info" || return 1
  trash_into "$p" "$TRASH_DIR" "" "$p"
}

volume_trash_put() { # PATH (normalised) TOP → moved to the drive's Trash; 1 if that Trash can't be used
  local p=$1 top=$2 dir
  [[ -e $p || -L $p ]] || return 1
  if ((DRY_RUN)); then run mv -- "$p" "$top/.Trash-$UID/files/"; return 0; fi
  volume_trash_dir dir "$top" || return 1 # read-only drive or not yours: gio decides
  # Path= relative to the drive, as the spec suggests for removable media
  trash_into "$p" "$dir" "$dir/files/" "${p#"$top"/}"
}

move_to_trash() { # PATH — never deletes permanently
  local p=$1 np top
  [[ $p == /* ]] || p=$PWD/$p
  if is_protected "$p"; then err "Refusing to touch protected path: $p"; return 1; fi
  if ((${#EXCLUDES[@]})) && touches_exclusion "$(realpath -m -s -- "$p")"; then
    err "Excluded in Settings (Never clean): $p"; return 1
  fi
  if [[ $p == "$HOME"/* ]]; then trash_put "$p"; return; fi
  np=$(realpath -m -s -- "$p")
  if volume_top top "$np" && volume_trash_put "$np" "$top"; then return 0; fi
  if have gio; then run gio trash -- "$p"
  else err "Can't move $p to the Trash (it's outside your home folder and gio is missing)"; return 1; fi
}

undo_trash() { # put the last batch back → UNDO_OK, UNDO_FAILED
  local e orig f
  UNDO_OK=0 UNDO_FAILED=0
  for e in "${UNDO_BATCH[@]}"; do
    orig=${e#*$'\t'}
    if ! trash_locate "${e%%$'\t'*}"; then UNDO_FAILED=$((UNDO_FAILED + 1)); continue; fi
    f=$TL_DIR/files/$TL_NAME
    if [[ -e $orig || -L $orig || ! (-e $f || -L $f) ]]; then
      UNDO_FAILED=$((UNDO_FAILED + 1)); continue # already back, or emptied from the Trash
    fi
    # -n -T: never replace or move into something that appeared at that path meanwhile;
    # mv -n may exit 0 when it skips, so success = the file left the Trash
    if mkdir -p -- "${orig%/*}" && mv -n -T -- "$f" "$orig" 2>/dev/null && [[ ! -e $f && ! -L $f ]]; then
      rm -f -- "$TL_DIR/info/$TL_NAME.trashinfo"
      log "restore $orig"
      UNDO_OK=$((UNDO_OK + 1))
    else UNDO_FAILED=$((UNDO_FAILED + 1)); fi
  done
  UNDO_BATCH=()
}

undo_toast() { # after a screen's own undo
  if ((UNDO_FAILED)); then toast "${YELLOW}!${NC} Put back $UNDO_OK, $UNDO_FAILED could not be restored."
  else toast "${GREEN}↶${NC} Put back $(plural "$UNDO_OK" item) from the Trash."; fi
}


# ───────────────────────────── cleanup registry ─────────────────────────────
#
# Each item <id> provides:
#   scan_<id>     sets SCAN_BYTES / SCAN_NOTE; returns 0 = junk found,
#                 1 = not applicable (hidden), 2 = nothing to clean
#   clean_<id>    performs the cleanup; non-zero return means skipped
#   details_<id>  (optional) shows exactly what would be removed
#
# Scans run in parallel subshells: they must only communicate through
# SCAN_BYTES / SCAN_NOTE (or files under $LOG_DIR).

declare -a ITEM_IDS=()
declare -A ITEM_CAT ITEM_LABEL ITEM_DEFAULT ITEM_DESC ITEM_ROOT
declare -A CAT_TITLE=([system]="System Junk" [logs]="Logs" [user]="User Junk" [browser]="Browsers"
  [apps]="App Caches" [ai]="AI Tools" [models]="AI Models" [dev]="Developer Junk" [privacy]="Privacy")
CATEGORIES=(system logs user browser apps ai models dev)

reg() { ITEM_IDS+=("$1"); ITEM_CAT[$1]=$2; ITEM_LABEL[$1]=$3; ITEM_DEFAULT[$1]=$4; ITEM_DESC[$1]=$5; }

#   id           category label                          default  description
reg apt_cache    system "APT package cache"                 1 "Downloaded .deb installers. apt re-downloads them if ever needed."
reg old_installers system "Old installers in Downloads"     0 "Installers and disk images (.deb, AppImage, .iso, .img, .run, .snap, Flatpak) at the top of your Downloads folder, downloaded more than 30 days ago. Moved to the Trash."
reg old_downloads system "Old downloads"                   0 "Files and folders at the top of your Downloads folder that you haven't opened or changed for more than 90 days. Moved to the Trash."
reg old_screenshots system "Old screenshots"                 0 "Screenshots and screen recordings in your Pictures folder and its Screenshots folder that you haven't opened or changed for more than 90 days. Moved to the Trash."
reg abandoned_downloads system "Abandoned downloads"         0 "Unfinished downloads (.crdownload, .part, .aria2, .!qB) at the top of your Downloads folder that haven't changed or been opened for more than 7 days. Moved to the Trash."
reg orphans      system "Unused packages & old kernels"     1 "Packages installed as dependencies that nothing needs any more (apt autoremove)."
reg residual     system "Leftover package configs"          1 "System config files of packages that were removed but not purged."
reg journal      logs   "Systemd journal logs"              1 "Archived system logs. Keeps the last 7 days and at most 100 MB."
reg old_logs     logs   "Rotated / archived logs"           1 "Compressed or rotated log files in /var/log (*.gz, *.1, *.old)."
reg big_logs     logs   "Oversized active logs"             1 "Live logs in /var/log over 50 MB, emptied in place — services keep logging normally."
reg app_logs     logs   "Old app logs"                      1 "Log files of apps (VS Code, Slack, …) not written for 3+ days."
reg crash        logs   "Crash reports"                     1 "Apport crash reports in /var/crash."
reg coredump     logs   "Core dumps"                        1 "Memory dumps of crashed programs kept by systemd-coredump."
reg snap_old     system "Old Snap revisions"                1 "Disabled previous versions of snaps, kept only for rollback."
reg old_kernels  system "Extra old kernels"                 0 "Kernels older than your two newest (never the one running), so a fallback always stays."
reg tmp          system "Old temporary files"               1 "Your files in /tmp and /var/tmp not touched for 10+ days."
reg thumbs       user   "Thumbnail cache"                   1 "Image previews generated by the file manager; rebuilt on demand."
reg trash        user   "Trash"                             1 "Files you already deleted. Review before emptying!"
reg trash_drives user   "Trash on external drives"          0 "Files you deleted on USB sticks and other drives stay in that drive's own Trash and keep using its space. Emptying deletes them for good."
reg app_cache    user   "Stale app caches (>30 days)"       1 "Files under ~/.cache not modified or read for 30+ days."
reg node_modules dev    "Stale node_modules"                0 "node_modules of projects untouched for 90+ days. Restore with npm/yarn/pnpm install."
reg stale_build_dirs dev "Stale project build folders"      0 "Cargo target/, Python .venv/ and CocoaPods Pods/ folders of projects untouched for 90+ days. Moved to the Trash; rebuilt by cargo build, pip/uv install or pod install."
reg npm          dev    "npm cache"                         1 "npm's package download cache (~/.npm/_cacache)."
reg yarn         dev    "Yarn cache"                        1 "Yarn's package download cache."
reg pnpm         dev    "pnpm store (unreferenced)"         1 "Packages in the pnpm store no project references (pnpm store prune)."
reg bun          dev    "Bun cache"                         1 "Bun's package install cache."
reg pip          dev    "pip cache"                         1 "pip's wheel and HTTP download cache."
reg gobuild      dev    "Go build cache"                    1 "Compiled Go build artifacts (go clean -cache)."
reg cargo        dev    "Cargo registry cache"              0 "Downloaded and extracted crates; re-downloaded on next build."
reg gradle       dev    "Gradle caches"                     0 "Gradle dependency and build caches; re-downloaded on next build."
reg maven        dev    "Maven repository"                  0 "Local Maven repository (~/.m2/repository); re-downloaded on next build."
reg conda        dev    "Conda package cache"               1 "Downloaded package archives, index cache and logs (conda clean --tarballs). Your environments are kept."
reg docker_dangling dev "Docker: dangling images"           1 "Untagged leftover image layers from rebuilds — nothing uses them."
reg docker_build dev    "Docker: build cache"               0 "BuildKit cache. Safe to remove; the next build is slower once."
reg docker_containers dev "Docker: stopped containers"      0 "Containers that aren't running. Anything stored inside them (not in volumes) is lost."
reg docker_images dev   "Docker: unused images"             0 "Images no container uses. They are pulled again when needed."
reg docker_volumes dev  "Docker: unused volumes"            0 "Volumes no container uses — they may hold databases or other data. Review before removing!"
reg podman       dev    "Podman: stopped containers & dangling images" 0 "podman system prune: stopped containers, untagged image layers and unused networks. Volumes and tagged images are kept."

for _id in apt_cache orphans residual journal old_logs big_logs crash coredump snap_old old_kernels; do ITEM_ROOT[$_id]=1; done
unset _id
# items cleaned by moving them to your Trash (Undo puts them back); everything else is deleted for good
declare -A ITEM_TRASH=([old_installers]=1 [old_downloads]=1 [old_screenshots]=1 [abandoned_downloads]=1 [stale_build_dirs]=1 [vscode_stale_workspaces]=1 [jetbrains_old_versions]=1)
# items whose scan only looks at a few folders (test, du): a scan runs them in a
# few shared processes, one after the other, since a process each costs more than
# the scan. reg_cache_item and reg_list_item add theirs; any other item gets its own.
declare -A ITEM_LIGHT=([bun]=1 [cargo]=1 [gobuild]=1 [gradle]=1 [maven]=1 [npm]=1 [pip]=1 [pnpm]=1 [yarn]=1 [thumbs]=1 [trash]=1)

# ── detail helpers ──

detail_files() { # [N] — reads "bytes<TAB>path" lines, prints the N largest
  sort -t$'\t' -k1,1rn | head -n "${1:-20}" | while IFS=$'\t' read -r b f; do
    printf '  %s%10s%s  %s\n' "$(size_color "$b")" "$(human "$b")" "$NC" "${f/#$HOME/\~}"
  done
}

detail_paths() { # PATH... — size of each path and its biggest entries
  local p
  for p in "$@"; do
    [[ -e $p ]] || continue
    printf '  %s%10s  %s%s\n' "$BOLD" "$(human "$(du_sum "$p")")" "${p/#$HOME/\~}" "$NC"
    [[ -d $p ]] || continue
    try_root find "$p" -mindepth 1 -maxdepth 1 -exec du -sb {} + 2>/dev/null | detail_files 8 | sed 's/^/  /'
  done
}

# ── System ──

scan_apt_cache() {
  have apt-get || return 1
  local debs
  mapfile -t debs < <(compgen -G '/var/cache/apt/archives/*.deb')
  ((${#debs[@]})) || return 2
  SCAN_BYTES=$(du_sum "${debs[@]}")
  SCAN_NOTE="$(plural ${#debs[@]} "downloaded installer")"
  ((SCAN_BYTES > 0)) || return 2
}
clean_apt_cache() { run_root apt-get clean; }
details_apt_cache() { find /var/cache/apt/archives -name '*.deb' -printf '%s\t%f\n' 2>/dev/null | detail_files 30; }

# apt decides what autoremove would take from the installed packages only: the package lists don't
# change that choice, and loading them is most of apt's time (seconds while its saved cache is out
# of date, which only root rebuilds). Nothing is written to apt's cache, also as root.
orphan_pkgs() {
  apt-get -s -o Dir::State::Lists=/nonexistent -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= \
    autoremove 2>/dev/null | awk '/^Remv / {print $2}'
}
# The answer is kept in CACHE_DIR while the package database, the auto/manual marks, apt's settings
# and the running kernel (apt keeps it) stay the same, for a day at most. Cleaning runs
# apt-get autoremove, which decides again, so an outdated list never removes anything.
ORPHAN_CACHE_SECS=86400
orphan_key() { # → what the answer depends on; fails without a package database
  local f out kernel
  f=$SYSROOT/var/lib/dpkg/status
  [[ -r $f ]] || return 1
  out=$(stat -L -c '%n %i %s %y' "$f" "$SYSROOT/var/lib/apt/extended_states" "$SYSROOT/etc/apt/apt.conf" \
    "$SYSROOT/etc/apt/apt.conf.d" 2>/dev/null)
  kernel=$(uname -r 2>/dev/null)
  printf '%s\n' "${out//$'\n'/ | } | $kernel"
}
orphan_list() { # → ORPHAN_N packages apt autoremove would remove, ORPHAN_SIZES lines "KB<TAB>package"
  local key file now head n t pkgs=()
  ORPHAN_N=0 ORPHAN_SIZES=()
  file=$CACHE_DIR/orphans.tsv
  key=$(orphan_key) || key=""
  printf -v now '%(%s)T' -1
  if [[ -n $key && -f $file && ! -L $file ]]; then
    { IFS= read -r head; mapfile -t ORPHAN_SIZES; } <"$file"
    IFS=$'\t' read -r _ t n <<<"$head"
    if [[ ${head%%$'\t'*} == "$key" && $t =~ ^[0-9]+$ && $n =~ ^[0-9]+$ ]] && ((t <= now && now - t < ORPHAN_CACHE_SECS)); then
      ORPHAN_N=$n
      return 0
    fi
    ORPHAN_SIZES=()
  fi
  mapfile -t pkgs < <(orphan_pkgs)
  ORPHAN_N=${#pkgs[@]}
  ((ORPHAN_N)) && mapfile -t ORPHAN_SIZES < <(dpkg-query -W -f='${Installed-Size}\t${Package}\n' "${pkgs[@]}" 2>/dev/null)
  [[ -n $key ]] || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null &&
    printf '%s\t%s\t%s\n' "$key" "$now" "$ORPHAN_N" >"$file.$BASHPID" 2>/dev/null &&
    printf '%s\n' "${ORPHAN_SIZES[@]}" >>"$file.$BASHPID" && mv -f "$file.$BASHPID" "$file" 2>/dev/null
  return 0
}
scan_orphans() {
  have apt-get || return 1
  orphan_list
  ((ORPHAN_N)) || return 2
  SCAN_BYTES=$(($(printf '%s\n' "${ORPHAN_SIZES[@]}" | sum_lines) * 1024))
  SCAN_NOTE="$(plural "$ORPHAN_N" package)"
}
clean_orphans() {
  run_root apt-get autoremove --purge -y
  local rc=$?
  rm -f -- "$CACHE_DIR/orphans.tsv"
  return $rc
}
details_orphans() {
  orphan_list
  ((ORPHAN_N)) || return 0
  printf '%s\n' "${ORPHAN_SIZES[@]}" | awk -F'\t' '$2 != "" {print $1 * 1024 "\t" $2}' | detail_files 200
}

# Bootloader packages are skipped: their purge scripts can remove boot configuration.
residual_pkgs() { dpkg -l 2>/dev/null | awk '/^rc/ && $2 !~ /^(grub|shim|systemd-boot)/ {print $2}'; }
scan_residual() {
  have dpkg || return 1
  local pkgs
  mapfile -t pkgs < <(residual_pkgs)
  ((${#pkgs[@]})) || return 2
  SCAN_NOTE="$(plural ${#pkgs[@]} "removed package") still configured"
}
clean_residual() {
  local pkgs
  mapfile -t pkgs < <(residual_pkgs)
  ((${#pkgs[@]})) && run_root dpkg --purge "${pkgs[@]}"
}
details_residual() { residual_pkgs | column -c 100 | sed 's/^/  /'; }

# Only archived journal files (name@….journal or *.journal~) can be vacuumed:
# estimate those older than 7 days plus whatever exceeds the 100 MB cap.
JOURNAL_KEEP_DAYS=7 JOURNAL_KEEP_BYTES=$((100 * 1024 * 1024))
journal_files() { try_root find /var/log/journal -type f -name '*.journal*' -printf '%s\t%T@\t%f\t%p\n' 2>/dev/null; }
scan_journal() {
  have journalctl && [[ -d /var/log/journal ]] || return 1
  local total archived old cutoff extra
  cutoff=$((EPOCHSECONDS - JOURNAL_KEEP_DAYS * 86400))
  read -r total archived old < <(journal_files | awk -F'\t' -v c="$cutoff" '
    {t += $1; if ($3 ~ /@|~$/) {a += $1; if ($2 < c) o += $1}}
    END {printf "%d %d %d\n", t, a, o}')
  extra=$((total - old - JOURNAL_KEEP_BYTES)); ((extra < 0)) && extra=0
  SCAN_BYTES=$((old + extra)); ((SCAN_BYTES > archived)) && SCAN_BYTES=$archived
  SCAN_NOTE="$(human "$total") in total"
  ((SCAN_BYTES > 0)) || return 2
}
clean_journal() { run_root journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d" --vacuum-size="${JOURNAL_KEEP_MB}M"; }
details_journal() {
  journalctl --disk-usage 2>/dev/null | sed 's/^/  /'
  printf '\n  %sLargest archived journal files:%s\n' "$BOLD" "$NC"
  journal_files | awk -F'\t' '$3 ~ /@|~$/ {print $1 "\t" $4}' | detail_files 15
}

# Rotated logs only: compressed, numbered (syslog.1) or *.old, untouched for an hour.
# Samba's live per-client logs (log.<host>) also end in digits, so skip those.
LOG_MATCH=(\( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' \) -not -name 'log.*' -mmin +60)
scan_old_logs() {
  local n
  read -r n SCAN_BYTES < <(try_root find /var/log -type f "${LOG_MATCH[@]}" -printf '%s\n' 2>/dev/null | count_sum)
  SCAN_NOTE="$(plural "$n" file) in /var/log"
  ((SCAN_BYTES > 0)) || return 2
}
clean_old_logs() { run_root find /var/log -type f "${LOG_MATCH[@]}" -delete || true; } # unreadable dirs are expected
details_old_logs() { try_root find /var/log -type f "${LOG_MATCH[@]}" -printf '%s\t%p\n' 2>/dev/null | detail_files 30; }

dir_files_scan() { # DIR NOUN — size and count of files under DIR
  [[ -d $1 ]] || return 1
  local n
  read -r n SCAN_BYTES < <(try_root find "$1" -mindepth 1 -type f -printf '%s\n' 2>/dev/null | count_sum)
  SCAN_NOTE=$(plural "$n" "$2")
  ((n > 0)) || return 2
}
dir_files_details() { try_root find "$1" -mindepth 1 -type f -printf '%s\t%p\n' 2>/dev/null | detail_files 30; }

scan_crash() { dir_files_scan /var/crash report; }
clean_crash() { empty_dir --root /var/crash; }
details_crash() { dir_files_details /var/crash; }

scan_coredump() { dir_files_scan /var/lib/systemd/coredump dump; }
clean_coredump() { empty_dir --root /var/lib/systemd/coredump; }
details_coredump() { dir_files_details /var/lib/systemd/coredump; }

# Live logs that grew past LOG_MAX_MB. They are truncated, not deleted: the
# service keeps its file open and continues writing to it. Login records,
# audit logs and the binary journal are never touched.
big_logs_find() {
  try_root find /var/log \( -path /var/log/journal -o -path /var/log/audit -o -name wtmp -o -name btmp \
    -o -name lastlog -o -name faillog \) -prune -o -type f -size +"${LOG_MAX_MB}"M \
    -not \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*.old' -o -name '*.journal*' \) "$@" 2>/dev/null
}
scan_big_logs() {
  local rows r names=()
  mapfile -t rows < <(big_logs_find -printf '%s\t%f\n')
  ((${#rows[@]})) || return 2
  SCAN_BYTES=0
  for r in "${rows[@]}"; do SCAN_BYTES=$((SCAN_BYTES + ${r%%$'\t'*})) names+=("${r#*$'\t'}"); done
  SCAN_NOTE=$(printf '%s\n' "${names[@]}" | head -n 3 | paste -sd, - | sed 's/,/, /g')
  ((${#rows[@]} > 3)) && SCAN_NOTE+=", …"
  return 0
}
clean_big_logs() {
  local files f
  mapfile -t files < <(big_logs_find -print)
  for f in "${files[@]}"; do run_root truncate -s 0 -- "$f"; done
}
details_big_logs() { big_logs_find -printf '%s\t%p\n' | detail_files 30; }

app_log_dirs() { # per-app log folders
  local d
  for d in "${XDG_CONFIG_HOME:-$HOME/.config}"/*/{logs,log} "${XDG_DATA_HOME:-$HOME/.local/share}"/*/{logs,log} \
    "$HOME"/snap/*/*/.config/*/logs "$HOME"/.var/app/*/config/*/logs; do
    [[ -d $d && ! -L $d ]] && printf '%s\n' "$d"
  done
}
app_logs_find() { # log files not written for APPLOG_DAYS (current logs stay)
  local dirs
  mapfile -t dirs < <(app_log_dirs)
  ((${#dirs[@]})) || return 0
  find "${dirs[@]}" -type f -mtime +"$APPLOG_DAYS" "$@" 2>/dev/null
}
scan_app_logs() {
  local n dirs
  mapfile -t dirs < <(app_log_dirs)
  ((${#dirs[@]})) || return 1
  read -r n SCAN_BYTES < <(find "${dirs[@]}" -type f -mtime +"$APPLOG_DAYS" -printf '%s\n' 2>/dev/null | count_sum)
  SCAN_NOTE="$(plural "$n" file) in $(plural ${#dirs[@]} app)"
  ((n > 0)) || return 2
}
clean_app_logs() {
  local dirs
  if ((DRY_RUN)); then run find "(app log folders)" -type f -mtime +"$APPLOG_DAYS" -delete; return; fi
  log "app_logs_find -delete"
  app_logs_find -delete
  mapfile -t dirs < <(app_log_dirs) # drop the session folders that are now empty
  ((${#dirs[@]})) && find "${dirs[@]}" -mindepth 1 -type d -empty -delete 2>/dev/null
  return 0
}
details_app_logs() { # grouped per app
  local d
  app_log_dirs | while IFS= read -r d; do
    printf '%s\t%s\n' "$(find "$d" -type f -mtime +"$APPLOG_DAYS" -printf '%s\n' 2>/dev/null | sum_lines)" "$d"
  done | awk -F'\t' '$1 > 0' | detail_files 30
}

snap_disabled() { snap list --all 2>/dev/null | awk 'NR > 1 && /disabled/ {print $1, $3}'; }
scan_snap_old() {
  have snap || return 1
  local revs n r files=()
  mapfile -t revs < <(snap_disabled)
  ((${#revs[@]})) || return 2
  for n in "${revs[@]}"; do
    read -r n r <<<"$n"; files+=("/var/lib/snapd/snaps/${n}_${r}.snap")
  done
  SCAN_BYTES=$(du_sum "${files[@]}")
  SCAN_NOTE="$(plural ${#revs[@]} "disabled revision")"
}
clean_snap_old() {
  local revs line n r
  mapfile -t revs < <(snap_disabled)
  for line in "${revs[@]}"; do
    read -r n r <<<"$line"
    run_root snap remove "$n" --revision="$r"
  done
}
details_snap_old() {
  local n r
  snap_disabled | while read -r n r; do
    printf '%s\t%s (revision %s)\n' "$(du_sum "/var/lib/snapd/snaps/${n}_${r}.snap")" "$n" "$r"
  done | detail_files 50
}

# Kernels beyond the two newest and the running one. Like Ubuntu itself, we
# always keep a fallback: if the newest kernel fails to boot, the previous one is there.
kernel_extras() { # RUNNING_VERSION, installed versions on stdin → versions that are safe to remove
  local running=$1 v all=() n
  mapfile -t all < <(grep -v '^$' | sort -V -u)
  n=${#all[@]}
  ((n > 2)) || return 0
  for v in "${all[@]:0:n-2}"; do [[ $v != "$running" ]] && printf '%s\n' "$v"; done
  return 0
}
installed_kernels() { # versions of installed linux-image-<version> packages
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-[0-9]*' 2>/dev/null |
    awk -F'\t' '$1 ~ /^ii/ {sub(/^linux-image-(unsigned-)?/, "", $2); print $2}' | sort -u
}
kernel_packages() { # VERSION... → installed packages belonging to those kernels
  local v
  for v in "$@"; do
    dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' "*-$v" 2>/dev/null | awk -F'\t' '$1 ~ /^ii/ {print $2}'
  done | sort -u
}
scan_old_kernels() {
  have dpkg-query || return 1
  local extras pkgs kb
  mapfile -t extras < <(installed_kernels | kernel_extras "$(uname -r)")
  ((${#extras[@]})) || return 2
  mapfile -t pkgs < <(kernel_packages "${extras[@]}")
  kb=$(dpkg-query -W -f='${Installed-Size}\n' "${pkgs[@]}" 2>/dev/null | sum_lines)
  SCAN_BYTES=$((kb * 1024))
  SCAN_NOTE=$(printf '%s\n' "${extras[@]}" | paste -sd, - | sed 's/,/, /g')
}
clean_old_kernels() {
  local extras pkgs sim others
  mapfile -t extras < <(installed_kernels | kernel_extras "$(uname -r)")
  ((${#extras[@]})) || return 0
  mapfile -t pkgs < <(kernel_packages "${extras[@]}")
  # refuse unless apt would remove exactly these kernel packages and nothing else
  sim=$(LC_ALL=C apt-get -s purge "${pkgs[@]}" 2>&1) || { echo "apt refuses: $(grep -m1 '^E:' <<<"$sim")"; return 1; }
  others=$(grep '^Purg' <<<"$sim" | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${pkgs[@]}"))
  if [[ -n $others ]]; then
    echo "Not removing: apt would also remove $(paste -sd' ' <<<"$others")"
    return 1
  fi
  run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
}
details_old_kernels() {
  local v running
  local extras
  running=$(uname -r)
  extras=" $(installed_kernels | kernel_extras "$running" | paste -sd' ' -) "
  installed_kernels | sort -V | while IFS= read -r v; do
    if [[ $v == "$running" ]]; then printf '  %s  ← running (kept)\n' "$v"
    elif [[ $extras != *" $v "* ]]; then printf '  %s  ← kept as a fallback\n' "$v"
    else printf '  %s  ← will be removed: %s\n' "$v" "$(kernel_packages "$v" | paste -sd' ' -)"; fi
  done
  return 0
}

# Untouched (neither modified nor read) for 10+ days and owned by you.
tmp_find() { find /tmp /var/tmp -xdev -mindepth 1 -user "$(id -u)" -type f -mtime +"$TMP_DAYS" -atime +"$TMP_DAYS" "$@" 2>/dev/null; }
scan_tmp() {
  local n
  read -r n SCAN_BYTES < <(tmp_find -printf '%s\n' | count_sum)
  SCAN_NOTE=$(plural "$n" file)
  ((n > 0)) || return 2
}
clean_tmp() {
  if ((DRY_RUN)); then run find /tmp /var/tmp -xdev -mindepth 1 -user "$(id -u)" -type f -mtime +"$TMP_DAYS" -atime +"$TMP_DAYS" -delete
  else log "tmp_find -delete"; tmp_find -delete || true; fi # other users' folders in /tmp are unreadable: expected
}
details_tmp() { tmp_find -printf '%s\t%p\n' | detail_files 30; }

# Old installers in your Downloads folder: .deb, AppImage, .iso… files at its top level (no subfolders,
# no symlinks) last modified more than OLD_INSTALLER_DAYS ago. One still downloading (a .part,
# .crdownload, .!qB or .aria2 next to it) or open in a program is skipped. They are your files, so cleaning
# moves them to the Trash; the terminal app's z puts them back. The desktop app lists each file as an entry.
# A Downloads folder outside your home folder (or a symlink) is never scanned: the item says so.
OLD_INSTALLER_DAYS=30 # Settings: installer_days
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_old_installers='^[A-Za-z0-9._~%-]+$' # the file name, percent-encoded (urlencode_path)

downloads_dir() { # → your Downloads folder (xdg-user-dir; ~/Downloads when it isn't set)
  local d=""
  have xdg-user-dir && d=$(xdg-user-dir DOWNLOAD 2>/dev/null)
  d=${d%/}
  [[ -n $d && $d != "$HOME" ]] || d=$HOME/Downloads # xdg-user-dir answers $HOME when it isn't set
  printf '%s' "$d"
}

downloads_outside() { # DIR → true when your Downloads folder is outside your home folder or a symlink
  [[ $1 != "$HOME"/* || -L $1 ]]
}

old_installers() { # → OI_DIR, and OI_NAME / OI_BYTES / OI_DAYS (days since modified) biggest first
  local b m name lower open now
  OI_DIR=$(downloads_dir) OI_NAME=() OI_BYTES=() OI_DAYS=()
  ! downloads_outside "$OI_DIR" && [[ -d $OI_DIR ]] || return 0
  open=$(open_files)
  printf -v now '%(%s)T' -1
  while IFS=$'\t' read -r -d '' b m name; do
    [[ -n $name && $name != *[[:cntrl:]]* ]] || continue
    lower=${name,,}
    case $lower in
      *.deb | *.appimage | *.iso | *.img | *.run | *.snap | *.flatpakref | *.flatpak) ;;
      *) continue ;;
    esac
    partial_download "$OI_DIR" "$name" && continue # still downloading
    grep -qxF -- "$OI_DIR/$name" <<<"$open" && continue
    in_exclusion "$OI_DIR/$name" && continue
    OI_NAME+=("$name") OI_BYTES+=("$b") OI_DAYS+=($(((now - ${m%.*}) / 86400)))
  done < <(find "$OI_DIR" -mindepth 1 -maxdepth 1 -type f -mmin +$((OLD_INSTALLER_DAYS * 1440)) \
    -printf '%s\t%T@\t%f\0' 2>/dev/null | sort -z -t $'\t' -k1,1nr)
}

trash_installers() { # NAME… — move these files of OI_DIR to the Trash; @@undo lines let the terminal app undo it
  local name e rc=0
  UNDO_BATCH=()
  for name; do move_to_trash "$OI_DIR/$name" || rc=1; done
  for e in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$e"; done
  return "$rc"
}

scan_old_installers() {
  local b
  old_installers
  if downloads_outside "$OI_DIR"; then
    SCAN_NOTE="Downloads folder is outside your home folder (${OI_DIR}); CleanMate only cleans inside it"
    return 2
  fi
  ((${#OI_NAME[@]})) || return 2
  SCAN_BYTES=0
  for b in "${OI_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#OI_NAME[@]} file) older than $OLD_INSTALLER_DAYS days"
}
clean_old_installers() {
  old_installers
  ((${#OI_NAME[@]})) || return 0
  trash_installers "${OI_NAME[@]}"
}
details_old_installers() {
  local i
  old_installers
  for i in "${!OI_NAME[@]}"; do
    printf '  %s%10s%s  %s  %s(%s days old)%s\n' "$(size_color "${OI_BYTES[i]}")" "$(human "${OI_BYTES[i]}")" "$NC" \
      "${OI_DIR/#$HOME/\~}/${OI_NAME[i]}" "$DIM" "${OI_DAYS[i]}" "$NC"
  done
}
entries_old_installers() {
  local i
  old_installers
  for i in "${!OI_NAME[@]}"; do
    printf '%s\t%s\t0\t%s · %s days old\n' "$(urlencode_path "${OI_NAME[i]}")" "${OI_BYTES[i]}" "${OI_NAME[i]}" "${OI_DAYS[i]}"
  done
}
clean_entries_old_installers() { # encoded file names (json_clean_entries only passes ones listed now)
  local i id pick=()
  old_installers
  for id; do
    for i in "${!OI_NAME[@]}"; do
      [[ $(urlencode_path "${OI_NAME[i]}") == "$id" ]] && pick+=("${OI_NAME[i]}")
    done
  done
  ((${#pick[@]})) || return 0
  trash_installers "${pick[@]}"
}

# Old downloads: what sits at the top of your Downloads folder (files and folders; no symlinks, no
# hidden ones) that you haven't opened or changed for OLD_DOWNLOAD_DAYS. A file counts as touched when
# it changed or was read (atime; relatime still records a read once a day); a folder when it or
# anything inside it changed, or a file inside it was read. Folders' own read times are left out:
# listing a folder, as this scan does, updates them. A folder holding more than OD_MAX_FILES files is
# skipped. Old installers (that item lists them), downloads in progress (.part, .crdownload, .!qB,
# .aria2, or one next to it: Abandoned downloads lists them), anything a program has open and Never
# clean folders are skipped too. They are your files, so cleaning moves them to the Trash; the terminal
# app's z puts them back. The desktop app lists each one as an entry. A Downloads folder outside your
# home folder (or a symlink) is never scanned.
OLD_DOWNLOAD_DAYS=90 # Settings: download_days
OD_MAX_FILES=20000
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_old_downloads='^[A-Za-z0-9._~%-]+$' # the file or folder name, percent-encoded (urlencode_path)

partial_download() { # DIR NAME — NAME is a download in progress, or has one next to it
  case ${2,,} in *.part | *.crdownload | *.!qb | *.aria2) return 0 ;; esac
  [[ -e $1/$2.part || -e $1/$2.crdownload || -e $1/$2.!qB || -e $1/$2.aria2 ]]
}

folder_touched() { # DIR CUTOFF → "NEWEST BYTES": the last change inside DIR (or read of a file in it) and
  # the size of its files; "new" as soon as something is newer than CUTOFF, "big" past OD_MAX_FILES files
  find "$1" -xdev -mindepth 1 -printf '%y %T@ %A@ %s\n' 2>/dev/null |
    awk -v cut="$2" -v max="$OD_MAX_FILES" '
      { t = $2; if ($1 != "d" && $3 > t) t = $3
        if (t >= cut) { r = "new"; exit }
        if (t > newest) newest = t
        if ($1 != "d") { s += $4; if (++n > max) { r = "big"; exit } } }
      END { if (r != "") print r; else printf "%.0f %.0f\n", newest, s }'
}

old_downloads() { # → OD_DIR, and OD_NAME / OD_KIND (f or d) / OD_BYTES / OD_DAYS (days since touched) biggest first
  local y m a b n name p r t open now cut installers=$'\n'
  OD_DIR=$(downloads_dir) OD_NAME=() OD_KIND=() OD_BYTES=() OD_DAYS=()
  ! downloads_outside "$OD_DIR" && [[ -d $OD_DIR ]] || return 0
  old_installers # listed there, not here
  for name in "${OI_NAME[@]}"; do installers+=$name$'\n'; done
  open=$'\n'$(open_files)$'\n'
  printf -v now '%(%s)T' -1
  cut=$((now - OLD_DOWNLOAD_DAYS * 86400))
  while IFS=$'\t' read -r -d '' b n y name; do
    OD_NAME+=("$name") OD_KIND+=("$y") OD_BYTES+=("$b") OD_DAYS+=("$n")
  done < <(
    find "$OD_DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) ! -name '.*' \
      -printf '%y\t%T@\t%A@\t%s\t%f\0' 2>/dev/null |
      while IFS=$'\t' read -r -d '' y m a b name; do
        [[ -n $name && $name != *[[:cntrl:]]* && $installers != *$'\n'"$name"$'\n'* ]] || continue
        partial_download "$OD_DIR" "$name" && continue
        p=$OD_DIR/$name
        touches_exclusion "$p" && continue
        open_under "$open" "$p" && continue
        m=${m%.*} a=${a%.*}
        if [[ $y == f ]]; then
          ((a > m)) && m=$a
          ((m < cut)) || continue
        else
          ((m < cut)) || continue
          r=$(folder_touched "$p" "$cut")
          [[ $r == [0-9]* ]] || continue # something new inside, or too big to check
          read -r t b <<<"$r"
          ((t > m)) && m=$t
        fi
        printf '%s\t%s\t%s\t%s\0' "$b" "$(((now - m) / 86400))" "$y" "$name"
      done | sort -z -t $'\t' -k1,1nr
  )
}

trash_downloads() { # NAME… — move these of OD_DIR to the Trash; @@undo lines let the terminal app undo it
  local name e rc=0
  UNDO_BATCH=()
  for name; do move_to_trash "$OD_DIR/$name" || rc=1; done
  for e in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$e"; done
  return "$rc"
}

download_label() { # INDEX → "Photos/ · untouched for 120 days"
  local s=""
  [[ ${OD_KIND[$1]} == d ]] && s=/
  printf '%s%s · untouched for %s days' "${OD_NAME[$1]}" "$s" "${OD_DAYS[$1]}"
}

scan_old_downloads() {
  local b
  old_downloads
  if downloads_outside "$OD_DIR"; then
    SCAN_NOTE="Downloads folder is outside your home folder (${OD_DIR}); CleanMate only cleans inside it"
    return 2
  fi
  ((${#OD_NAME[@]})) || return 2
  SCAN_BYTES=0
  for b in "${OD_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#OD_NAME[@]} item) untouched for ${OLD_DOWNLOAD_DAYS}+ days"
}
clean_old_downloads() {
  old_downloads
  ((${#OD_NAME[@]})) || return 0
  trash_downloads "${OD_NAME[@]}"
}
details_old_downloads() {
  local i
  old_downloads
  for i in "${!OD_NAME[@]}"; do
    printf '  %s%10s%s  %s\n' "$(size_color "${OD_BYTES[i]}")" "$(human "${OD_BYTES[i]}")" "$NC" \
      "${OD_DIR/#$HOME/\~}/$(download_label "$i")"
  done
}
entries_old_downloads() {
  local i
  old_downloads
  for i in "${!OD_NAME[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${OD_NAME[i]}")" "${OD_BYTES[i]}" "$(download_label "$i")"
  done
}
clean_entries_old_downloads() { # encoded names (json_clean_entries only passes ones listed now)
  local i id pick=()
  old_downloads
  for id; do
    for i in "${!OD_NAME[@]}"; do
      [[ $(urlencode_path "${OD_NAME[i]}") == "$id" ]] && pick+=("${OD_NAME[i]}")
    done
  done
  ((${#pick[@]})) || return 0
  trash_downloads "${pick[@]}"
}

# Old screenshots: screenshots and screen recordings at the top of your Pictures folder or of its
# Screenshots folder, named the way GNOME ("Screenshot from <date>…", "Screencast from …", in Vietnamese
# "Ảnh chụp màn hình …") and KDE Spectacle ("Screenshot_<date>…") name them, .png/.jpg/.jpeg/.webp/
# .webm/.mp4, not changed or opened for OLD_DOWNLOAD_DAYS (Settings › Old downloads). Only a Pictures
# folder inside your home folder (no symlinks); when it is your Downloads folder, Old downloads covers
# it. Files a program has open and Never clean folders are skipped. Moved to the Trash; the terminal
# app's z puts them back; the desktop app lists each file as an entry.
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_old_screenshots='^(Screenshots/)?[A-Za-z0-9._~%-]+$' # the path inside Pictures, percent-encoded

pictures_dir() { # → your Pictures folder (xdg-user-dir; ~/Pictures when it isn't set)
  local d=""
  have xdg-user-dir && d=$(xdg-user-dir PICTURES 2>/dev/null)
  d=${d%/}
  [[ -n $d && $d != "$HOME" ]] || d=$HOME/Pictures # xdg-user-dir answers $HOME when it isn't set
  printf '%s' "$d"
}

screenshot_name() { # NAME — a file name screenshot tools give
  case $1 in
    "Screenshot from "[0-9]* | Screenshot_[0-9]* | "Screencast from "* | "Ảnh chụp màn hình "*) ;;
    *) return 1 ;;
  esac
  case ${1,,} in *.png | *.jpg | *.jpeg | *.webp | *.webm | *.mp4) return 0 ;; esac
  return 1
}

old_screenshots() { # → OS_DIR, and OS_PATH (inside OS_DIR) / OS_BYTES / OS_DAYS (days since touched) biggest first
  local b m a rel p open now mins
  OS_DIR=$(pictures_dir) OS_PATH=() OS_BYTES=() OS_DAYS=()
  [[ $OS_DIR == "$HOME"/* && ! -L $OS_DIR && -d $OS_DIR && $OS_DIR != "$(downloads_dir)" ]] || return 0
  open=$'\n'$(open_files)$'\n'
  printf -v now '%(%s)T' -1
  mins=$((OLD_DOWNLOAD_DAYS * 1440))
  while IFS=$'\t' read -r -d '' b m a rel; do
    [[ -n $rel && $rel != *[[:cntrl:]]* ]] && screenshot_name "${rel##*/}" || continue
    p=$OS_DIR/$rel
    in_exclusion "$p" && continue
    open_under "$open" "$p" && continue
    m=${m%.*} a=${a%.*}
    ((a > m)) && m=$a
    OS_PATH+=("$rel") OS_BYTES+=("$b") OS_DAYS+=($(((now - m) / 86400)))
  done < <(
    {
      find "$OS_DIR" -mindepth 1 -maxdepth 1 -type f -mmin +$mins -amin +$mins -printf '%s\t%T@\t%A@\t%f\0'
      [[ -d $OS_DIR/Screenshots && ! -L $OS_DIR/Screenshots ]] &&
        find "$OS_DIR/Screenshots" -mindepth 1 -maxdepth 1 -type f -mmin +$mins -amin +$mins \
          -printf '%s\t%T@\t%A@\tScreenshots/%f\0'
    } 2>/dev/null | sort -z -t $'\t' -k1,1nr
  )
}

trash_screenshots() { # PATH… — move these of OS_DIR to the Trash; @@undo lines let the terminal app undo it
  local rel e rc=0
  UNDO_BATCH=()
  for rel; do move_to_trash "$OS_DIR/$rel" || rc=1; done
  for e in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$e"; done
  return "$rc"
}

scan_old_screenshots() {
  local b
  old_screenshots
  ((${#OS_PATH[@]})) || return 2
  SCAN_BYTES=0
  for b in "${OS_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#OS_PATH[@]} file) untouched for ${OLD_DOWNLOAD_DAYS}+ days"
}
clean_old_screenshots() {
  old_screenshots
  ((${#OS_PATH[@]})) || return 0
  trash_screenshots "${OS_PATH[@]}"
}
details_old_screenshots() {
  local i
  old_screenshots
  for i in "${!OS_PATH[@]}"; do
    printf '  %s%10s%s  %s  %s(untouched for %s days)%s\n' "$(size_color "${OS_BYTES[i]}")" "$(human "${OS_BYTES[i]}")" "$NC" \
      "${OS_DIR/#$HOME/\~}/${OS_PATH[i]}" "$DIM" "${OS_DAYS[i]}" "$NC"
  done
}
entries_old_screenshots() {
  local i
  old_screenshots
  for i in "${!OS_PATH[@]}"; do
    printf '%s\t%s\t0\t%s · untouched for %s days\n' "$(urlencode_path "${OS_PATH[i]}")" "${OS_BYTES[i]}" \
      "${OS_PATH[i]##*/}" "${OS_DAYS[i]}"
  done
}
clean_entries_old_screenshots() { # encoded paths (json_clean_entries only passes ones listed now)
  local i id pick=()
  old_screenshots
  for id; do
    for i in "${!OS_PATH[@]}"; do
      [[ $(urlencode_path "${OS_PATH[i]}") == "$id" ]] && pick+=("${OS_PATH[i]}")
    done
  done
  ((${#pick[@]})) || return 0
  trash_screenshots "${pick[@]}"
}

# Abandoned downloads: unfinished downloads at the top of your Downloads folder (no symlinks) — Chrome's
# .crdownload, Firefox's .part, aria2's .aria2 and qBittorrent's .!qB (any case) — neither changed nor
# opened for ABANDONED_DAYS. Firefox makes an empty file of the real name next to its .part, and aria2
# keeps the data in the file of the real name next to its .aria2: such a file goes along as one entry,
# and when it was used lately (or is open) the download isn't abandoned. A file a program has open
# (still downloading) and Never clean folders are skipped. Old installers and Old downloads skip these.
# Moved to the Trash; the terminal app's z puts them back; the desktop app lists each one as an entry.
ABANDONED_DAYS=7
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_abandoned_downloads='^[A-Za-z0-9._~%-]+$' # the unfinished file's name, percent-encoded

abandoned_downloads() { # → AD_DIR, and AD_NAME / AD_MATE (moved along, or empty) / AD_BYTES / AD_DAYS biggest first
  local b m a n name mate mb mm ma open now cut
  AD_DIR=$(downloads_dir) AD_NAME=() AD_MATE=() AD_BYTES=() AD_DAYS=()
  ! downloads_outside "$AD_DIR" && [[ -d $AD_DIR ]] || return 0
  open=$'\n'$(open_files)$'\n'
  printf -v now '%(%s)T' -1
  cut=$((now - ABANDONED_DAYS * 86400))
  while IFS=$'\t' read -r -d '' b n name mate; do
    AD_NAME+=("$name") AD_MATE+=("$mate") AD_BYTES+=("$b") AD_DAYS+=("$n")
  done < <(
    find "$AD_DIR" -mindepth 1 -maxdepth 1 -type f -mmin +$((ABANDONED_DAYS * 1440)) -amin +$((ABANDONED_DAYS * 1440)) \
      -printf '%s\t%T@\t%A@\t%f\0' 2>/dev/null |
      while IFS=$'\t' read -r -d '' b m a name; do
        [[ -n $name && $name != *[[:cntrl:]]* ]] || continue
        mate=""
        case ${name,,} in
          *.crdownload | *.!qb) ;;
          *.part | *.aria2) mate=${name%.*} ;;
          *) continue ;;
        esac
        in_exclusion "$AD_DIR/$name" && continue
        open_under "$open" "$AD_DIR/$name" && continue
        m=${m%.*} a=${a%.*}
        ((a > m)) && m=$a
        [[ -n $mate && -f $AD_DIR/$mate && ! -L $AD_DIR/$mate ]] &&
          read -r mb mm ma < <(stat -c '%s %Y %X' -- "$AD_DIR/$mate" 2>/dev/null) || mb=-1
        # aria2's holds the data; Firefox's is empty (a full one is a file of its own)
        if ((mb > 0)) && [[ ${name,,} == *.aria2 ]] || ((mb == 0)); then
          ((mm < cut && ma < cut)) || continue # used lately: still downloading
          open_under "$open" "$AD_DIR/$mate" && continue
          ((mm > m)) && m=$mm
          ((ma > m)) && m=$ma
          b=$((b + mb))
        else
          mate=""
        fi
        printf '%s\t%s\t%s\t%s\0' "$b" "$(((now - m) / 86400))" "$name" "$mate"
      done | sort -z -t $'\t' -k1,1nr
  )
}

trash_abandoned() { # INDEX… — move these of AD_NAME (and the file next to each) to the Trash; @@undo lines for z
  local i e rc=0
  UNDO_BATCH=()
  for i; do
    move_to_trash "$AD_DIR/${AD_NAME[i]}" || rc=1
    [[ -z ${AD_MATE[i]} ]] || move_to_trash "$AD_DIR/${AD_MATE[i]}" || rc=1
  done
  for e in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$e"; done
  return "$rc"
}

abandoned_label() { # INDEX → "movie.mkv.part · untouched for 12 days"
  printf '%s · untouched for %s days' "${AD_NAME[$1]}" "${AD_DAYS[$1]}"
}

scan_abandoned_downloads() {
  local b
  abandoned_downloads
  ((${#AD_NAME[@]})) || return 2
  SCAN_BYTES=0
  for b in "${AD_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#AD_NAME[@]} download) untouched for ${ABANDONED_DAYS}+ days"
}
clean_abandoned_downloads() {
  abandoned_downloads
  ((${#AD_NAME[@]})) || return 0
  trash_abandoned "${!AD_NAME[@]}"
}
details_abandoned_downloads() {
  local i
  abandoned_downloads
  for i in "${!AD_NAME[@]}"; do
    printf '  %s%10s%s  %s%s\n' "$(size_color "${AD_BYTES[i]}")" "$(human "${AD_BYTES[i]}")" "$NC" \
      "${AD_DIR/#$HOME/\~}/$(abandoned_label "$i")" "${AD_MATE[i]:+ (with ${AD_MATE[i]})}"
  done
}
entries_abandoned_downloads() {
  local i
  abandoned_downloads
  for i in "${!AD_NAME[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${AD_NAME[i]}")" "${AD_BYTES[i]}" "$(abandoned_label "$i")"
  done
}
clean_entries_abandoned_downloads() { # encoded names (json_clean_entries only passes ones listed now)
  local i id pick=()
  abandoned_downloads
  for id; do
    for i in "${!AD_NAME[@]}"; do
      [[ $(urlencode_path "${AD_NAME[i]}") == "$id" ]] && pick+=("$i")
    done
  done
  ((${#pick[@]})) || return 0
  trash_abandoned "${pick[@]}"
}

# ── User ──

scan_thumbs() {
  SCAN_BYTES=$(du_sum "$HOME/.cache/thumbnails")
  SCAN_NOTE="~/.cache/thumbnails"
  ((SCAN_BYTES > 0)) || return 2
}
clean_thumbs() { empty_dir "$HOME/.cache/thumbnails"; }
details_thumbs() { detail_paths "$HOME/.cache/thumbnails"; }

TRASH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
scan_trash() {
  local n
  SCAN_BYTES=$(du_sum "$TRASH_DIR/files")
  n=$(find "$TRASH_DIR/files" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  SCAN_NOTE=$(plural "$n" item)
  ((n > 0)) || return 2
}
clean_trash() { # the same Trash folder the scan measures (gio could act on another one, or on none)
  empty_dir "$TRASH_DIR/files" && empty_dir "$TRASH_DIR/info"
  [[ -d $TRASH_DIR/expunged ]] && empty_dir "$TRASH_DIR/expunged"
  return 0
}
details_trash() { detail_paths "$TRASH_DIR/files"; }

# Trash on external drives: what you delete on a USB stick or another drive stays in that drive's
# own Trash (.Trash-$UID, or $UID inside an admin's shared, sticky .Trash) and keeps its space used.
# Only drives mounted for you (VOLUME_ROOTS), never read-only or network ones, never another user's
# Trash, never through a symlink, and nothing is created on a drive. Emptying deletes for good and
# skips whatever a program still has open. The desktop app lists each drive as an entry.
MOUNTS_FILE=${CLEANMATE_MOUNTS:-/proc/mounts} # tests: a fake mount table
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_trash_drives='^/[A-Za-z0-9/._~%-]+$' # the drive's folder, percent-encoded (urlencode_path)

drive_mount_ok() { # TOP → 0 when its Trash may be emptied: writable, not a network or FUSE file system; DRIVE_DEV
  local dev mp type opts rest found=""
  DRIVE_DEV=""
  if [[ -r $MOUNTS_FILE ]]; then
    while read -r dev mp type opts rest; do
      printf -v mp '%b' "${mp//\\/\\0}" # \040 = space, as the kernel escapes it
      [[ $mp == "$1" ]] && found="$type ,$opts," DRIVE_DEV=$dev # the last mount on a folder wins
    done <"$MOUNTS_FILE"
  fi
  [[ -n $found ]] || { [[ -n ${CLEANMATE_VOLUME_ROOTS:-} ]]; return; } # tests: a plain folder is a drive
  [[ ${found#* } != *,ro,* ]] || return 1
  case ${found%% *} in
    nfs* | cifs | smb* | sshfs | fuse | fuse.* | 9p | drvfs | virtiofs | afs | ceph | glusterfs | davfs | ncpfs) return 1 ;;
  esac # fuseblk (NTFS, exFAT through FUSE) is a real drive
}

drive_trash_dirs() { # VAR TOP → your Trash folders that exist on that drive
  local -n __dt=$1
  local __top=$2 __d
  __dt=()
  for __d in "$__top/.Trash-$UID" "$__top/.Trash/$UID"; do
    if [[ $__d == "$__top/.Trash/$UID" ]]; then
      [[ -d $__top/.Trash && ! -L $__top/.Trash && -k $__top/.Trash ]] || continue
    fi
    trash_dir_ok "$__d" && trash_dir_ok "$__d/files" && __dt+=("$__d")
  done
}

drive_trashes() { # → DT_TOP, DT_N (items), DT_BYTES, DT_LABEL for each drive whose Trash of yours has something
  local r top t n b label
  local -a dirs files
  DT_TOP=() DT_N=() DT_BYTES=() DT_LABEL=()
  for r in "${VOLUME_ROOTS[@]}"; do
    [[ -n $r && -d $r ]] || continue
    while IFS= read -r -d '' top; do
      [[ $top != *[$'\t\n']* ]] && volume_top_ok "$top" && drive_mount_ok "$top" || continue
      drive_trash_dirs dirs "$top"
      ((${#dirs[@]})) || continue
      files=()
      for t in "${dirs[@]}"; do files+=("$t/files"); done
      n=$(find "${files[@]}" -mindepth 1 -maxdepth 1 -printf . 2>/dev/null | wc -c)
      ((n > 0)) || continue
      b=$(find "${files[@]}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | du -scb --files0-from=- 2>/dev/null | tail -n 1 | cut -f1)
      label=""
      [[ $DRIVE_DEV == /dev/* ]] && have lsblk && label=$(lsblk -dno LABEL -- "$DRIVE_DEV" 2>/dev/null | head -n 1)
      label=${label//[$'\t\r']/ }
      DT_TOP+=("$top") DT_N+=("$n") DT_BYTES+=("${b:-0}") DT_LABEL+=("${label:-${top##*/}}")
    done < <(find "$r" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
  done
}

empty_drive_trash() { # TOP — delete what is in your Trash on that drive, except what a program has open
  local top=$1 t name line rc=0
  local -a dirs
  local -A busy
  drive_trash_dirs dirs "$top"
  for t in "${dirs[@]}"; do
    busy=()
    while IFS= read -r line; do
      [[ $line == "$t/files/"* ]] || continue
      line=${line#"$t/files/"}; busy[${line%%/*}]=1
    done < <(open_files)
    while IFS= read -r -d '' name; do
      if [[ -n ${busy[$name]:-} ]]; then echo "Kept (in use): $t/files/$name"; continue; fi
      run find "$t/files/$name" -delete || { rc=1; continue; }
      if [[ -e $t/info/$name.trashinfo || -L $t/info/$name.trashinfo ]]; then run rm -f -- "$t/info/$name.trashinfo" || rc=1; fi
    done < <(find "$t/files" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null)
    trash_dir_ok "$t/info" || continue
    while IFS= read -r -d '' name; do # what is left in info/ with nothing in files/ any more
      [[ -e $t/files/${name%.trashinfo} || -L $t/files/${name%.trashinfo} ]] || run find "$t/info/$name" -delete || rc=1
    done < <(find "$t/info" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null)
  done
  return "$rc"
}

scan_trash_drives() {
  local i n=0
  drive_trashes
  ((${#DT_TOP[@]})) || return 2
  SCAN_BYTES=0
  for i in "${!DT_TOP[@]}"; do SCAN_BYTES=$((SCAN_BYTES + DT_BYTES[i])) n=$((n + DT_N[i])); done
  SCAN_NOTE="$(plural "$n" item) on $(plural ${#DT_TOP[@]} drive)"
}
clean_trash_drives() {
  local top rc=0
  drive_trashes
  for top in "${DT_TOP[@]}"; do empty_drive_trash "$top" || rc=1; done
  return "$rc"
}
details_trash_drives() {
  local i
  drive_trashes
  for i in "${!DT_TOP[@]}"; do
    printf '  %s%10s  %s%s  %s(%s)%s\n' "$BOLD" "$(human "${DT_BYTES[i]}")" "${DT_LABEL[i]}" "$NC" "$DIM" "${DT_TOP[i]}" "$NC"
  done
}
entries_trash_drives() {
  local i
  drive_trashes
  for i in "${!DT_TOP[@]}"; do
    printf '%s\t%s\t0\t%s · %s\n' "$(urlencode_path "${DT_TOP[i]}")" "${DT_BYTES[i]}" "${DT_LABEL[i]}" "$(plural "${DT_N[i]}" item)"
  done
}
clean_entries_trash_drives() { # encoded drive folders (json_clean_entries only passes ones listed now)
  local i id rc=0
  drive_trashes
  for id; do
    for i in "${!DT_TOP[@]}"; do
      [[ $(urlencode_path "${DT_TOP[i]}") == "$id" ]] && { empty_drive_trash "${DT_TOP[i]}" || rc=1; }
    done
  done
  return "$rc"
}

# ── Browsers & apps: one item per browser / app ──
#
# Cache items are data-driven: ITEM_PATHS holds the cache folders (one per
# line) and ITEM_PROCS the process names to check before cleaning. Their
# scan_/clean_/details_ functions are generated by reg_cache_item.

declare -A ITEM_PATHS=() ITEM_PROCS=()

declare -A ITEM_OPEN=() ITEM_ARGS=() # ITEM_OPEN: skip folders with a file open; ITEM_ARGS: running when a command line has this

cache_item_dirs() { # ID → existing cache folders, one per line
  local p open=""
  [[ -n ${ITEM_OPEN[$1]:-} ]] && open=$'\n'$(open_files)$'\n'
  while IFS= read -r p; do
    [[ -n $p && -d $p && ! -L $p ]] || continue
    [[ -z $open ]] || ! open_under "$open" "$p" || continue
    printf '%s\n' "$p"
  done <<<"${ITEM_PATHS[$1]}"
}

cache_item_scan() {
  local dirs n
  mapfile -t dirs < <(cache_item_dirs "$1")
  ((${#dirs[@]})) || return 1
  SCAN_BYTES=$(du_sum "${dirs[@]}")
  if ((${#dirs[@]} == 1)); then SCAN_NOTE=${dirs[0]/#$HOME/\~}
  else
    n=$(printf '%s\n' "${dirs[@]##*/}" | sort -u | head -n 3 | paste -sd, - | sed 's/,/, /g')
    SCAN_NOTE="$n$( ((${#dirs[@]} > 3)) && echo ", …")"
  fi
  ((SCAN_BYTES > 0)) && return 0
  [[ ${ITEM_CAT[$1]} == apps ]] && return 1 # don't list apps with empty caches
  return 2
}

cache_item_clean() { local d; while IFS= read -r d; do empty_dir "$d"; done < <(cache_item_dirs "$1"); }

cache_item_details() {
  local d
  cache_item_dirs "$1" | while IFS= read -r d; do printf '%s\t%s\n' "$(du_sum "$d")" "$d"; done | detail_files 40
  return 0
}

running_proc() { # PGREP_ARGS… PATTERN → name of the first matching process; fails when none runs
  local out pid name
  out=$(pgrep -l "$@" 2>/dev/null) || return 1 # pgrep's status decides, the name is only shown
  read -r pid name <<<"$out"
  printf '%s\n' "${name:-${!#}}"
}

# lockedby_ID (made by the generators below) prints the running program that
# makes the item skip when cleaning unattended (--yes, the desktop app); a scan
# reports it as the item's lock.
item_locked() { declare -F "lockedby_$1" >/dev/null && "lockedby_$1"; }

cache_item_precheck() { # ask (or skip when unattended) if the program is running
  lockedby_cache_item "$1" >/dev/null || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[$1]}: it is running."; return 1; fi
  ui_confirm "${ITEM_LABEL[$1]} is running" "Close it first for best results. Clean its cache anyway?" n
}

lockedby_cache_item() {
  running_proc -xi "${ITEM_PROCS[$1]}" ||
    { [[ -n ${ITEM_ARGS[$1]:-} ]] && running_proc -f "${ITEM_ARGS[$1]}"; }
}

reg_cache_item() { # ID CATEGORY LABEL DEFAULT DESCRIPTION PATHS [PROCESS_REGEX]
  local id=$1
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1 # ids become function names below
  reg "$id" "$2" "$3" "$4" "$5"
  ITEM_PATHS[$id]=$6
  ITEM_PROCS[$id]=${7:-} ITEM_LIGHT[$id]=1
  eval "scan_$id() { cache_item_scan $id; }
        clean_$id() { cache_item_clean $id; }
        details_$id() { cache_item_details $id; }"
  [[ -n ${7:-} ]] && eval "precheck_$id() { cache_item_precheck $id; }
                          lockedby_$id() { lockedby_cache_item $id; }"
  return 0
}

#   id                label            processes              cache folders (deb, snap, flatpak)
BROWSERS=(
  "browser_firefox|Firefox|firefox|$HOME/.cache/mozilla
$HOME/snap/firefox/common/.cache
$HOME/.var/app/org.mozilla.firefox/cache"
  "browser_chrome|Google Chrome|chrome|$HOME/.cache/google-chrome
$HOME/.var/app/com.google.Chrome/cache"
  "browser_chromium|Chromium|chromium|$HOME/.cache/chromium
$HOME/snap/chromium/common/.cache
$HOME/.var/app/org.chromium.Chromium/cache"
  "browser_brave|Brave|brave|$HOME/.cache/BraveSoftware
$HOME/snap/brave/common/.cache
$HOME/.var/app/com.brave.Browser/cache"
  "browser_edge|Microsoft Edge|msedge|$HOME/.cache/microsoft-edge
$HOME/.var/app/com.microsoft.Edge/cache"
  "browser_vivaldi|Vivaldi|vivaldi-bin|$HOME/.cache/vivaldi"
  "browser_opera|Opera|opera|$HOME/.cache/opera
$HOME/snap/opera/common/.cache"
)
for _b in "${BROWSERS[@]}"; do
  IFS='|' read -r _id _label _procs _paths <<<"$_b"
  _paths=${_b#*|*|*|}
  reg_cache_item "$_id" browser "$_label" 0 \
    "Web cache of $_label (pages, images, scripts). Logins, history and bookmarks are kept." "$_paths" "$_procs"
done

ELECTRON_SUBDIRS=(Cache "Code Cache" GPUCache DawnCache DawnGraphiteCache DawnWebGPUCache
  CachedData CachedExtensionVSIXs "Service Worker/CacheStorage")
declare -A APP_NAMES=([Code]="VS Code" ["Code - Insiders"]="VS Code Insiders" [VSCodium]="VSCodium"
  [discord]="Discord" [Slack]="Slack" [Signal]="Signal" [obsidian]="Obsidian" [spotify]="Spotify"
  [teams-for-linux]="Teams" [Element]="Element" [bitwarden]="Bitwarden" [Postman]="Postman"
  [Cursor]="Cursor" [Notion]="Notion" [1Password]="1Password" [whatsapp-for-linux]="WhatsApp"
  [snap-store]="App Center")
BROWSER_DIRS='^(google-chrome.*|chromium|BraveSoftware|microsoft-edge.*|vivaldi.*|opera.*|mozilla)$'
BROWSER_FLATPAKS='^(org\.mozilla\.firefox|com\.google\.Chrome|org\.chromium\.Chromium|com\.brave\.Browser|com\.microsoft\.Edge)$'
BROWSER_SNAPS='^(firefox|chromium|brave|opera)$'

add_app_item() { # NAME KIND PATHS [PROCESS]
  local id=${1,,}
  id="app_${id//[^a-z0-9]/_}"
  while [[ -n ${ITEM_CAT[$id]:-} ]]; do id+=_; done
  reg_cache_item "$id" apps "$1" 0 \
    "Cache folders of $1 ($2). Rebuilt automatically — close the app before cleaning." "$3" "${4:-}"
}

pretty_name() { # snap-store → Snap Store, firmware_updater → Firmware Updater
  local IFS='-_ ' w out=() words
  read -ra words <<<"$1"
  for w in "${words[@]}"; do out+=("${w^}"); done
  IFS=' '
  printf '%s' "${out[*]}"
}

flatpak_label() { # org.telegram.desktop → telegram, com.spotify.Client → spotify, org.gimp.GIMP → GIMP
  local IFS=. parts
  read -ra parts <<<"$1"
  local last=${parts[-1]}
  [[ ${last,,} =~ ^(client|desktop|app|application)$ && ${#parts[@]} -gt 1 ]] && last=${parts[-2]}
  pretty_name "$last"
}

discover_app_caches() {
  local app name sub dirs
  for app in "${XDG_CONFIG_HOME:-$HOME/.config}"/*/; do # Electron apps
    name=${app%/}; name=${name##*/}
    [[ $name =~ $BROWSER_DIRS || $name == Cursor ]] && continue # Cursor has its own item in AI Tools
    dirs=""
    for sub in "${ELECTRON_SUBDIRS[@]}"; do [[ -d $app$sub && ! -L $app$sub ]] && dirs+="$app$sub"$'\n'; done
    # process name guess: first word of the folder name (Code → code, "Antigravity IDE" → antigravity)
    [[ -n $dirs ]] && add_app_item "${APP_NAMES[$name]:-$( [[ $name == [a-z]* ]] && pretty_name "$name" || printf '%s' "$name")}" \
      "Electron app" "${dirs%$'\n'}" "${name%% *}"
  done
  for app in "$HOME"/.var/app/*/cache; do # Flatpak apps
    [[ -d $app ]] || continue
    name=${app%/cache}; name=${name##*/}
    [[ $name =~ $BROWSER_FLATPAKS ]] && continue
    add_app_item "$(flatpak_label "$name") (Flatpak)" "Flatpak $name" "$app"
  done
  for app in "$HOME"/snap/*/common/.cache; do # Snap apps
    [[ -d $app ]] || continue
    name=${app#"$HOME"/snap/}; name=${name%%/*}
    [[ $name =~ $BROWSER_SNAPS ]] && continue
    add_app_item "${APP_NAMES[$name]:-$(pretty_name "$name")} (Snap)" "Snap $name" "$app"
  done
  return 0
}
discover_app_caches
reg_cache_item app_steam_shaders apps "Steam — shader cache" 0 \
  "Shaders Steam compiled for your games. Steam rebuilds them; a game may stutter briefly the first time." \
  "$HOME/.local/share/Steam/steamapps/shadercache
$HOME/.steam/debian-installation/steamapps/shadercache
$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/shadercache
$HOME/snap/steam/common/.local/share/Steam/steamapps/shadercache" 'steam|steamwebhelper'
unset _b _id _label _procs _paths

# ── Privacy: histories and recent-items lists ──
#
# History files are emptied in place (truncate) so permissions and symlinks
# survive; the recent-files list gets a valid empty XBEL document. These
# items are not part of Smart Scan — they live on the Privacy screen.

declare -A PRIV_MODE=() PRIV_NOUN=()

priv_files() { # ID → existing files, one per line
  local p
  while IFS= read -r p; do [[ -n $p && -f $p ]] && printf '%s\n' "$p"; done <<<"${ITEM_PATHS[$1]}" | sort -u
}

priv_count() { # FILE MODE → number of entries
  case $2 in
    xbel) grep -c '<bookmark ' -- "$1" 2>/dev/null || true ;;
    fish) grep -c '^- cmd:' -- "$1" 2>/dev/null || true ;;
    lines) wc -l <"$1" 2>/dev/null || echo 0 ;;
    *) echo 0 ;;
  esac
}

priv_scan() {
  local files f n=0 mode=${PRIV_MODE[$1]}
  mapfile -t files < <(priv_files "$1")
  ((${#files[@]})) || return 1
  SCAN_BYTES=$(du_sum "${files[@]}")
  if [[ -n ${PRIV_NOUN[$1]} ]]; then
    for f in "${files[@]}"; do n=$((n + $(priv_count "$f" "$mode"))); done
    SCAN_NOTE=$(plural "$n" "${PRIV_NOUN[$1]}")
    ((n > 0)) || return 2
  else
    SCAN_NOTE=$(printf '%s\n' "${files[@]##*/}" | paste -sd, - | sed 's/,/, /g')
    ((SCAN_BYTES > 0)) || return 2
  fi
}

write_empty_xbel() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<xbel version="1.0" xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">' \
    '</xbel>' >"$1"
}

priv_clean() {
  local f
  [[ $1 == priv_zeitgeist ]] && have zeitgeist-daemon && run zeitgeist-daemon --quit
  while IFS= read -r f; do
    case ${PRIV_MODE[$1]} in
      xbel) run write_empty_xbel "$f" ;;
      delete) run rm -f -- "$f" ;;
      *) run truncate -s 0 -- "$f" ;;
    esac
  done < <(priv_files "$1")
}

priv_details() { # sizes and entry counts only — never the contents
  local f
  while IFS= read -r f; do
    printf '%s\t%s%s\n' "$(du_sum "$f")" "$f" \
      "$([[ -n ${PRIV_NOUN[$1]} ]] && echo "  ($(plural "$(priv_count "$f" "${PRIV_MODE[$1]}")" "${PRIV_NOUN[$1]}"))")"
  done < <(priv_files "$1") | detail_files 20
  return 0
}

priv_shell_precheck() { # open terminals write their in-memory history back on exit
  local n
  n=$(pgrep -cxf "${ITEM_PROCS[$1]}" 2>/dev/null) || n=0
  ((n > 0)) || return 0
  ((ASSUME_YES)) && return 0
  ui_confirm "$(plural "$n" "open terminal") will rewrite this history" \
    "Run 'history -c' in them or close them first. Clear the file anyway?" y
}

reg_privacy_item() { # ID LABEL DEFAULT DESCRIPTION MODE NOUN PATHS [SHELL_CMDLINE_REGEX]
  local id=$1
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1
  reg "$id" privacy "$2" "$3" "$4"
  PRIV_MODE[$id]=$5 PRIV_NOUN[$id]=$6 ITEM_PATHS[$id]=$7 ITEM_PROCS[$id]=${8:-}
  eval "scan_$id() { priv_scan $id; }
        clean_$id() { priv_clean $id; }
        details_$id() { priv_details $id; }"
  [[ -n ${8:-} ]] && eval "precheck_$id() { priv_shell_precheck $id; }"
  return 0
}

_data=${XDG_DATA_HOME:-$HOME/.local/share}
_state=${XDG_STATE_HOME:-$HOME/.local/state}
reg_privacy_item priv_recent "Recent files list" 1 \
  "What Files and Open dialogs show under “Recent”. Only the list is cleared — your files are not touched." \
  xbel "recent file" "$_data/recently-used.xbel"
reg_privacy_item priv_zsh "Zsh history" 0 "Every command you typed in zsh." lines command \
  "$HOME/.zsh_history
$HOME/.zhistory
$HOME/.histfile
${ZDOTDIR:-$HOME}/.zsh_history" 'zsh|-zsh|/bin/zsh|/usr/bin/zsh'
reg_privacy_item priv_bash "Bash history" 0 "Every command you typed in bash (~/.bash_history)." lines command \
  "$HOME/.bash_history" 'bash|-bash|/bin/bash|/usr/bin/bash'
reg_privacy_item priv_fish "Fish history" 0 "Every command you typed in fish." fish command \
  "$_data/fish/fish_history" 'fish|-fish|/bin/fish|/usr/bin/fish'
reg_privacy_item priv_repl "Python, Node & database shells" 0 \
  "History of the python, node, irb, mysql, psql, sqlite3 and redis-cli prompts." lines entry \
  "$HOME/.python_history
$HOME/.node_repl_history
$HOME/.irb_history
$HOME/.mysql_history
$HOME/.psql_history
$HOME/.sqlite_history
$HOME/.rediscli_history"
reg_privacy_item priv_misc "less & wget history" 1 "Searches typed in less, and wget's list of visited HTTPS sites." \
  lines entry "$HOME/.lesshst
$HOME/.wget-hsts"
reg_privacy_item priv_editor "Vim & Neovim history" 0 \
  "Command and search history, marks and registers that Vim (~/.viminfo) and Neovim (ShaDa) remember." delete "" \
  "$HOME/.viminfo
$_state/nvim/shada/main.shada"
reg_privacy_item priv_zeitgeist "Activity log (Zeitgeist)" 0 "The record of files and apps you used, kept by Zeitgeist." delete "" \
  "$_data/zeitgeist/activity.sqlite
$_data/zeitgeist/activity.sqlite-wal
$_data/zeitgeist/activity.sqlite-shm"
unset _data _state

# GNOME remembers some things in settings rather than files.
GS_HISTORY_KEYS=("org.gnome.shell command-history" "org.gnome.shell looking-glass-history"
  "org.gtk.Settings.EmojiChooser recent-emoji" "org.gtk.gtk4.Settings.EmojiChooser recently-used-emoji"
  "org.gnome.Characters recent-characters")
reg priv_gsettings privacy "Run dialog & emoji history" 1 \
  "Commands typed in Alt+F2, recently used emoji and characters."
gs_nonempty_keys() {
  local k v schema key
  for k in "${GS_HISTORY_KEYS[@]}"; do
    read -r schema key <<<"$k"
    v=$(gsettings get "$schema" "$key" 2>/dev/null) || continue
    [[ $v =~ ^(@[^\ ]+\ )?\[\]$ ]] || printf '%s\n' "$k"
  done
}
scan_priv_gsettings() {
  have gsettings || return 1
  local keys
  mapfile -t keys < <(gs_nonempty_keys)
  ((${#keys[@]})) || return 2
  SCAN_NOTE="$(plural ${#keys[@]} list) with entries"
}
clean_priv_gsettings() {
  local schema key
  while read -r schema key; do run gsettings reset "$schema" "$key"; done < <(gs_nonempty_keys)
}
details_priv_gsettings() { gs_nonempty_keys | sed 's/^/  /'; return 0; }

# ── Privacy: browsing history, downloads list and cookies, one item per browser ──
#
# Firefox keeps bookmarks in places.sqlite next to the history, so history,
# download records and cookies are deleted row by row with sqlite3 and the
# files stay. Chromium-based browsers keep them in files of their own
# (History also holds the downloads list), which are removed. Login Data,
# Web Data, Bookmarks, Extensions and Preferences are never touched. A running
# browser holds these files open and writes them back, so it is skipped.

declare -A BPRIV_KIND=()
BPRIV_FIREFOX_FILES=(places.sqlite places.sqlite-wal cookies.sqlite cookies.sqlite-wal downloads.sqlite)
BPRIV_CHROME_FILES=(History History-journal Cookies Cookies-journal "Visited Links" "Top Sites" "Top Sites-journal"
  Network/Cookies Network/Cookies-journal)

bpriv_profiles() { # ID → profile folders (a root itself or a folder directly in it) holding history or cookies
  local root d f marks
  if [[ ${BPRIV_KIND[$1]} == firefox ]]; then marks=(places.sqlite cookies.sqlite)
  else marks=(History Cookies Network/Cookies); fi
  while IFS= read -r root; do
    [[ -n $root && -d $root && ! -L $root ]] || continue
    for d in "$root" "$root"/*/; do
      d=${d%/}
      [[ -d $d && ! -L $d ]] || continue
      for f in "${marks[@]}"; do [[ -f $d/$f && ! -L $d/$f ]] && { printf '%s\n' "$d"; break; }; done
    done
  done <<<"${ITEM_PATHS[$1]}" | sort -u
}

bpriv_files() { # ID PROFILE → the history and cookie files in it
  local f list
  if [[ ${BPRIV_KIND[$1]} == firefox ]]; then list=("${BPRIV_FIREFOX_FILES[@]}"); else list=("${BPRIV_CHROME_FILES[@]}"); fi
  for f in "${list[@]}"; do [[ -f $2/$f && ! -L $2/$f ]] && printf '%s\n' "$2/$f"; done
  return 0
}

bpriv_query() { # DB SQL → the answer; 0 when DB doesn't exist, fails when sqlite3 can't read it
  [[ -f $1 ]] || { echo 0; return 0; }
  local v
  v=$(sqlite3 -readonly -batch -noheader -cmd '.timeout 2000' "$1" "$2" 2>/dev/null) || return 1
  [[ $v =~ ^[0-9]+$ ]] || return 1
  echo "$v"
}

bpriv_counts() { # ID PROFILE → "HISTORY COOKIES DOWNLOADS"; fails without sqlite3 or when a database can't be read
  local p=$2 h c c2=0 d
  have sqlite3 || return 1
  if [[ ${BPRIV_KIND[$1]} == firefox ]]; then
    h=$(bpriv_query "$p/places.sqlite" "SELECT count(*) FROM moz_places WHERE last_visit_date IS NOT NULL;") || return 1
    d=$(bpriv_query "$p/places.sqlite" "SELECT count(*) FROM moz_annos WHERE anno_attribute_id IN
      (SELECT id FROM moz_anno_attributes WHERE name = 'downloads/destinationFileURI');") || d=0 # no download ever
    c=$(bpriv_query "$p/cookies.sqlite" "SELECT count(*) FROM moz_cookies;") || return 1
  else
    h=$(bpriv_query "$p/History" "SELECT count(*) FROM urls;") || return 1
    d=$(bpriv_query "$p/History" "SELECT count(*) FROM downloads;") || return 1
    c=$(bpriv_query "$p/Cookies" "SELECT count(*) FROM cookies;") || return 1
    c2=$(bpriv_query "$p/Network/Cookies" "SELECT count(*) FROM cookies;") || return 1
  fi
  printf '%d %d %d\n' "$h" "$((c + c2))" "$d"
}

bpriv_note() { printf '%s, %s, %s' "$(plural "$1" "history entry")" "$(plural "$2" cookie)" "$(plural "$3" download)"; }

bpriv_scan() {
  local profiles p files=() h c d th=0 tc=0 td=0
  mapfile -t profiles < <(bpriv_profiles "$1")
  ((${#profiles[@]})) || return 1
  for p in "${profiles[@]}"; do mapfile -t -O "${#files[@]}" files < <(bpriv_files "$1" "$p"); done
  SCAN_BYTES=$(du_sum "${files[@]}")
  if ! have sqlite3; then # Firefox can't be cleared without it; the others only lose the counts
    [[ ${BPRIV_KIND[$1]} == firefox ]] && { SCAN_NOTE="needs sqlite3"; return 2; }
    SCAN_NOTE="install sqlite3 to count entries"
    ((SCAN_BYTES > 0)) || return 2
    return 0
  fi
  for p in "${profiles[@]}"; do
    read -r h c d < <(bpriv_counts "$1" "$p") || return 0 # unreadable (a running browser locks them): size only
    th=$((th + h)) tc=$((tc + c)) td=$((td + d))
  done
  SCAN_NOTE=$(bpriv_note "$th" "$tc" "$td")
  ((th + tc + td > 0)) || return 2
}

bpriv_sqlite() { # DB SQL… — change a database, all or nothing (-bail stops at the first error, rolling back)
  run sqlite3 -bail -batch -cmd '.timeout 5000' "$@"
}

bpriv_tables() { sqlite3 -readonly -batch -noheader "$1" "SELECT name FROM sqlite_master WHERE type = 'table';" 2>/dev/null; }

bpriv_clean_firefox() { # PROFILE
  local p=$1 db t sql=() rc=0
  local -A has=()
  db=$p/places.sqlite
  if [[ -f $db ]]; then
    while IFS= read -r t; do has[$t]=1; done < <(bpriv_tables "$db")
    if [[ -n ${has[moz_places]:-} && -n ${has[moz_historyvisits]:-} ]]; then
      sql=("BEGIN;" "DELETE FROM moz_historyvisits;")
      for t in moz_historyvisits_extra moz_inputhistory moz_places_metadata_search_queries moz_places_metadata; do
        [[ -n ${has[$t]:-} ]] && sql+=("DELETE FROM $t;")
      done
      [[ -n ${has[moz_annos]:-} && -n ${has[moz_anno_attributes]:-} ]] && sql+=("DELETE FROM moz_annos WHERE
        anno_attribute_id IN (SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%');")
      t="id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)" # bookmarked pages stay
      [[ -n ${has[moz_bookmarks]:-} ]] || t="1"
      [[ -n ${has[moz_keywords]:-} ]] && t+=" AND id NOT IN (SELECT place_id FROM moz_keywords WHERE place_id IS NOT NULL)"
      sql+=("DELETE FROM moz_places WHERE $t;" "UPDATE moz_places SET visit_count = 0, last_visit_date = NULL;")
      [[ -n ${has[moz_annos]:-} ]] && sql+=("DELETE FROM moz_annos WHERE place_id NOT IN (SELECT id FROM moz_places);")
      [[ -n ${has[moz_places_extra]:-} ]] &&
        sql+=("DELETE FROM moz_places_extra WHERE place_id NOT IN (SELECT id FROM moz_places);")
      [[ -n ${has[moz_origins]:-} ]] &&
        sql+=("DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places WHERE origin_id IS NOT NULL);")
      sql+=("COMMIT;" "VACUUM;")
      bpriv_sqlite "$db" "${sql[*]}" || { echo "Could not clear the history in ${db/#$HOME/\~}"; rc=1; }
    else
      echo "Unknown history database, left alone: ${db/#$HOME/\~}"
    fi
  fi
  db=$p/cookies.sqlite
  if [[ -f $db ]]; then
    bpriv_sqlite "$db" "DELETE FROM moz_cookies; VACUUM;" || { echo "Could not clear the cookies in ${db/#$HOME/\~}"; rc=1; }
  fi
  db=$p/downloads.sqlite # Firefox before version 26
  if [[ -f $db ]] && bpriv_tables "$db" | grep -qx moz_downloads; then
    bpriv_sqlite "$db" "DELETE FROM moz_downloads; VACUUM;" || rc=1
  fi
  return "$rc"
}

bpriv_clean() {
  local p f rc=0 name
  if name=$(lockedby_cache_item "$1"); then
    echo "Skipped: $name is running — close it and try again"
    return 1
  fi
  while IFS= read -r p; do
    if [[ ${BPRIV_KIND[$1]} == firefox ]]; then
      have sqlite3 || { echo "needs sqlite3"; return 1; }
      bpriv_clean_firefox "$p" || rc=1
    else
      while IFS= read -r f; do run rm -f -- "$f" || rc=1; done < <(bpriv_files "$1" "$p")
    fi
  done < <(bpriv_profiles "$1")
  return "$rc"
}

bpriv_details() { # each profile: size and entry counts — never the contents
  local p h c d count files
  while IFS= read -r p; do
    count=""
    read -r h c d < <(bpriv_counts "$1" "$p") && count="  ($(bpriv_note "$h" "$c" "$d"))"
    mapfile -t files < <(bpriv_files "$1" "$p")
    printf '%s\t%s%s\n' "$(du_sum "${files[@]}")" "$p" "$count"
  done < <(bpriv_profiles "$1") | detail_files 20
  return 0
}

bpriv_precheck() { # never ask: the browser would write the history back when it closes
  local name
  name=$(lockedby_cache_item "$1") || return 0
  ((UI_ACTIVE)) || warn "Skipping ${ITEM_LABEL[$1]}: $name is running — close it and try again."
  return 1
}

reg_browser_privacy() { # ID LABEL KIND PROCESS_REGEX PROFILE_ROOTS [CMDLINE_REGEX]
  local id=$1 extra=""
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1
  [[ $3 == firefox ]] && extra=" Needs sqlite3."
  reg "$id" privacy "$2 — history & cookies" 0 \
    "Browsing history, the downloads list and cookies of $2, in every profile. Signs you out of websites; passwords, bookmarks and extensions are kept. Skipped while $2 is running.$extra"
  BPRIV_KIND[$id]=$3 ITEM_PROCS[$id]=$4 ITEM_PATHS[$id]=$5 ITEM_ARGS[$id]=${6:-}
  eval "scan_$id() { bpriv_scan $id; }
        clean_$id() { bpriv_clean $id; }
        details_$id() { bpriv_details $id; }
        precheck_$id() { bpriv_precheck $id; }
        lockedby_$id() { lockedby_cache_item $id; }"
}

#                   id                    label           kind     processes          profile folders (deb, snap, flatpak)
reg_browser_privacy priv_browser_firefox Firefox firefox 'firefox|firefox-esr|firefox-bin' "$HOME/.mozilla/firefox
${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox
$HOME/snap/firefox/common/.mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox"
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
reg_browser_privacy priv_browser_chrome "Google Chrome" chromium chrome "$_cfg/google-chrome
$_cfg/google-chrome-beta
$_cfg/google-chrome-unstable
$HOME/.var/app/com.google.Chrome/config/google-chrome"
reg_browser_privacy priv_browser_chromium Chromium chromium 'chromium|chromium-browse' "$_cfg/chromium
$HOME/snap/chromium/common/chromium
$HOME/.var/app/org.chromium.Chromium/config/chromium" '/snap/chromium/'
reg_browser_privacy priv_browser_brave Brave chromium 'brave|brave-browser' "$_cfg/BraveSoftware/Brave-Browser
$HOME/snap/brave/current/.config/BraveSoftware/Brave-Browser
$HOME/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser"
reg_browser_privacy priv_browser_edge "Microsoft Edge" chromium msedge "$_cfg/microsoft-edge
$_cfg/microsoft-edge-beta
$_cfg/microsoft-edge-dev
$HOME/.var/app/com.microsoft.Edge/config/microsoft-edge"
reg_browser_privacy priv_browser_vivaldi Vivaldi chromium 'vivaldi-bin|vivaldi' "$_cfg/vivaldi
$_cfg/vivaldi-snapshot
$HOME/.var/app/com.vivaldi.Vivaldi/config/vivaldi"
reg_browser_privacy priv_browser_opera Opera chromium opera "$_cfg/opera
$HOME/snap/opera/current/.config/opera"
unset _cfg

# ── AI tools: caches/logs and old chat history ──
#
# Each item has a list function printing the paths to remove (files or whole
# folders). History items only list sessions older than AI_HISTORY_DAYS, so
# recent and running sessions stay. Credentials, settings, plugins, skills and
# Claude Code's memory/ folders are never listed (see ai_safe_path).

declare -A LIST_FN=() LIST_ROOTS=() LIST_NOUN=() LIST_RUN_DEFAULT=()

aged() { # DIR DAYS [find tests…] — entries directly inside DIR not modified for DAYS
  [[ -d $1 && ! -L $1 ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -mtime +"$2" "${@:3}" -print 2>/dev/null
}
contents() { # DIR — everything directly inside DIR
  [[ -d $1 && ! -L $1 ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -print 2>/dev/null
}
old_versions() { # DIR [NAME_GLOB] — every version folder except the newest
  [[ -d $1 && ! -L $1 ]] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -name "${2:-*}" -printf '%T@\t%p\n' 2>/dev/null |
    sort -rn | tail -n +2 | cut -f2-
}

ai_safe_path() { # refuse anything that is not clearly disposable
  local p=$1 base=${1##*/}
  [[ $p == "$HOME"/?* && ! -L $p ]] || return 1
  is_protected "$p" && return 1
  [[ $p == */memory || $p == */memory/* ]] && return 1 # Claude Code memory
  case $base in
    .credentials.json | auth.json | oauth_creds.json | *credential* | *token* | settings.json | \
      config.json | config.toml | *.pem | *.key | memories*.sqlite) return 1 ;;
    plugins | skills | agents | commands) [[ $p == */.tmp/* ]] || return 1 ;; # only temporary copies
  esac
  return 0
}

list_paths() { # ID → existing, safe paths
  local p
  "${LIST_FN[$1]}" | sort -u | while IFS= read -r p; do
    [[ -n $p && -e $p ]] && ai_safe_path "$p" && printf '%s\n' "$p"
  done
}

list_scan() {
  local r present=0 paths
  while IFS= read -r r; do [[ -n $r && -e $r ]] && present=1; done <<<"${LIST_ROOTS[$1]}"
  ((present)) || return 1 # tool not installed
  mapfile -t paths < <(list_paths "$1")
  ((${#paths[@]})) || return 2
  SCAN_BYTES=$(du_sum "${paths[@]}")
  ((SCAN_BYTES > 0)) || return 2
  SCAN_NOTE=$(plural ${#paths[@]} "${LIST_NOUN[$1]}")
  [[ ${ITEM_DESC[$1]} == *"older than"* ]] && SCAN_NOTE+=" · older than ${AI_HISTORY_DAYS}d"
  return 0
}

list_clean() {
  local p
  while IFS= read -r p; do
    ai_safe_path "$p" || continue # checked again right before deleting
    run rm -rf -- "$p"
  done < <(list_paths "$1")
}

list_details() {
  local p
  list_paths "$1" | while IFS= read -r p; do printf '%s\t%s\n' "$(du_sum "$p")" "$p"; done | detail_files 60
  return 0
}

lockedby_list_item() { running_proc -x "${ITEM_PROCS[$1]}"; }

list_precheck() { # the tool is running: skip when unattended, otherwise ask
  lockedby_list_item "$1" >/dev/null || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[$1]}: the app is running."; return 1; fi
  ui_confirm "${ITEM_LABEL[$1]%% —*} is running" \
    "Only old sessions and rebuildable caches are removed. Continue?" "${LIST_RUN_DEFAULT[$1]:-y}"
}

reg_list_item() { # ID LABEL DEFAULT NOUN DESCRIPTION LIST_FN ROOTS [PROCESS_REGEX] [RUNNING_DEFAULT]
  local id=$1 # category: ai, or LIST_CAT=… in front of the call
  [[ $id =~ ^[a-z0-9_]+$ ]] || return 1
  reg "$id" "${LIST_CAT:-ai}" "$2" "$3" "$5"
  LIST_NOUN[$id]=$4 LIST_FN[$id]=$6 LIST_ROOTS[$id]=$7 ITEM_PROCS[$id]=${8:-} LIST_RUN_DEFAULT[$id]=${9:-y} ITEM_LIGHT[$id]=1
  eval "scan_$id() { list_scan $id; }
        clean_$id() { list_clean $id; }
        details_$id() { list_details $id; }"
  [[ -n ${8:-} ]] && eval "precheck_$id() { list_precheck $id; }
                          lockedby_$id() { lockedby_list_item $id; }"
  return 0
}

# Claude Code (CLI)
ai_claude_cache() {
  contents "$HOME/.claude/cache"; contents "$HOME/.cache/claude-cli-nodejs"
  contents "$HOME/.claude/debug"; contents "$HOME/.claude/statsig"
  aged "$HOME/.claude/shell-snapshots" 7; aged "$HOME/.claude/backups" 7
}
ai_claude_history() { # a transcript goes together with its tool-output folder
  local j
  for j in "$HOME"/.claude/projects/*/*.jsonl; do
    [[ -f $j && -n $(find "$j" -mtime +"$AI_HISTORY_DAYS" -print 2>/dev/null) ]] || continue
    printf '%s\n' "$j"
    [[ -d ${j%.jsonl} ]] && printf '%s\n' "${j%.jsonl}"
  done
  aged "$HOME/.claude/file-history" "$AI_HISTORY_DAYS"
  aged "$HOME/.claude/todos" "$AI_HISTORY_DAYS"
  aged "$HOME/.claude/session-env" "$AI_HISTORY_DAYS"
}
# Claude Desktop
ai_claude_desktop_cache() {
  old_versions "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude-code"
  contents "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/Crashpad/completed"
}
ai_claude_desktop_history() {
  aged "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/local-agent-mode-sessions" "$AI_HISTORY_DAYS"
  aged "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude-code-sessions" "$AI_HISTORY_DAYS"
}
# Codex
ai_codex_cache() {
  local f
  contents "$HOME/.codex/.tmp"; contents "$HOME/.codex/tmp"; aged "$HOME/.codex/log" 3
  for f in "$HOME"/.codex/logs_*.sqlite "$HOME"/.codex/logs_*.sqlite-wal "$HOME"/.codex/logs_*.sqlite-shm; do
    [[ -f $f ]] && printf '%s\n' "$f"
  done
}
ai_codex_history() {
  local d
  for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
    [[ -d $d ]] && find "$d" -type f -name '*.jsonl' -mtime +"$AI_HISTORY_DAYS" -print 2>/dev/null
  done
}
# Gemini CLI & Antigravity
ai_gemini_cache() {
  local a
  aged "$HOME/.gemini/logs" 3
  for a in "$HOME/.gemini/antigravity" "$HOME/.gemini/antigravity-ide"; do
    contents "$a/crashes"; aged "$a/log" 3
  done
}
ai_gemini_history() {
  local a
  for a in "$HOME/.gemini/antigravity" "$HOME/.gemini/antigravity-ide"; do
    aged "$a/conversations" "$AI_HISTORY_DAYS"; aged "$a/brain" "$AI_HISTORY_DAYS"
    aged "$a/html_artifacts" "$AI_HISTORY_DAYS"
  done
  aged "$HOME/.gemini/tmp" "$AI_HISTORY_DAYS"
}
# opencode
ai_opencode_cache() { contents "$HOME/.cache/opencode"; contents "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/log"; }
ai_opencode_history() { aged "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/snapshot" "$AI_HISTORY_DAYS"; }
# Cursor (Electron caches and logs only; User/, workspaceStorage and globalStorage hold chats and settings)
ai_cursor_cache() {
  local d=${XDG_CONFIG_HOME:-$HOME/.config}/Cursor s
  for s in "${ELECTRON_SUBDIRS[@]}" logs; do [[ -d $d/$s && ! -L $d/$s ]] && printf '%s\n' "$d/$s"; done
  return 0
}
# Windsurf: embedding index and the Chromium cache of its built-in browser (no auth or settings)
ai_windsurf_cache() {
  local b s
  contents "$HOME/.codeium/windsurf/database"
  contents "$HOME/.codeium/database"
  for b in "$HOME/.codeium/windsurf/ws-browser-profile" "$HOME/.codeium/ws-browser-profile"; do
    for s in Cache "Code Cache" GPUCache DawnCache; do [[ -d $b/$s && ! -L $b/$s ]] && printf '%s\n' "$b/$s"; done
    for s in "$b"/*/Cache "$b"/*/"Code Cache" "$b"/*/GPUCache; do [[ -d $s && ! -L $s ]] && printf '%s\n' "$s"; done
  done
  return 0
}
# Cline and Kilo Code: logs/caches only (Cline's db/ and data/cache hold sessions and input history)
ai_cline_cache() { contents "$HOME/.cline/data/logs"; }
ai_kilo_cache() { contents "$HOME/.cache/kilo"; contents "${XDG_DATA_HOME:-$HOME/.local/share}/kilo/log"; }
# MiMoCode (an opencode fork): cache and logs; never its databases (*.db*) or auth.json
ai_mimocode_cache() {
  { contents "$HOME/.cache/mimocode"; contents "${XDG_DATA_HOME:-$HOME/.local/share}/mimocode/log"; } |
    grep -v '/[^/]*\.db[^/]*$'
  return 0
}
# ZCode: dated log files of the app and the CLI; never cli/rollout (the sessions' model traffic),
# credentials or databases
ai_zcode_cache() { contents "$HOME/.zcode/v2/logs"; contents "$HOME/.zcode/cli/log"; }
# Zed
ai_zed_cache() {
  local a
  contents "${XDG_DATA_HOME:-$HOME/.local/share}/zed/hang_traces"
  for a in "${XDG_DATA_HOME:-$HOME/.local/share}"/zed/external_agents/registry/*/; do old_versions "${a%/}" 'v_*'; done
}
ai_zed_downloads() {
  local z=${XDG_DATA_HOME:-$HOME/.local/share}/zed
  find "$z/external_agents/registry" -mindepth 1 -maxdepth 1 -type d -not -name icons -print 2>/dev/null
  contents "$z/languages"
}
# GitHub Copilot CLI & Continue
ai_misc_cache() { aged "$HOME/.copilot/logs" 3; contents "$HOME/.continue/index"; }
ai_misc_history() { aged "$HOME/.copilot/session-state" "$AI_HISTORY_DAYS"; aged "$HOME/.continue/sessions" "$AI_HISTORY_DAYS"; }

_c=${XDG_CONFIG_HOME:-$HOME/.config} _d=${XDG_DATA_HOME:-$HOME/.local/share}
reg_list_item ai_claude_cache "Claude Code — cache & logs" 1 item \
  "Claude Code caches, MCP logs, week-old shell snapshots and backups. Memory, settings and logins are kept." \
  ai_claude_cache "$HOME/.claude" claude
reg_list_item ai_claude_history "Claude Code — old sessions" 0 item \
  "Session transcripts, checkpoints and todos older than 30 days. Memory, settings and logins are kept." \
  ai_claude_history "$HOME/.claude" claude
reg_list_item ai_claude_desktop_cache "Claude Desktop — old versions" 1 item \
  "Previous bundled Claude Code versions and crash dumps of the Claude desktop app." \
  ai_claude_desktop_cache "$_c/Claude" claude-desktop
reg_list_item ai_claude_desktop_history "Claude Desktop — old sessions" 0 session \
  "Agent-mode sessions of the Claude desktop app older than 30 days." \
  ai_claude_desktop_history "$_c/Claude" claude-desktop
reg_list_item ai_codex_cache "Codex — cache & logs" 1 item \
  "Codex's temporary plugin cache and log database; both are recreated." \
  ai_codex_cache "$HOME/.codex" codex n
reg_list_item ai_codex_history "Codex — old sessions" 0 session \
  "Codex session transcripts older than 30 days. Memories and settings are kept." \
  ai_codex_history "$HOME/.codex" codex
reg_list_item ai_gemini_cache "Gemini/Antigravity — logs" 1 item \
  "Logs and crash dumps of Gemini CLI and Antigravity." \
  ai_gemini_cache "$HOME/.gemini" 'antigravity|gemini'
reg_list_item ai_gemini_history "Gemini/Antigravity — old chats" 0 item \
  "Antigravity conversations and agent workspaces (brain), and Gemini CLI checkpoints, older than 30 days." \
  ai_gemini_history "$HOME/.gemini" 'antigravity|gemini'
reg_list_item ai_opencode_cache "opencode — cache & logs" 1 item "opencode's download cache and logs. Sessions (opencode.db) and logins are kept." \
  ai_opencode_cache "$_d/opencode
$HOME/.cache/opencode" opencode
reg_list_item ai_opencode_history "opencode — old undo snapshots" 0 snapshot \
  "Undo snapshots of opencode sessions older than 30 days. Sessions in opencode.db are kept." \
  ai_opencode_history "$_d/opencode" opencode
reg_list_item ai_cursor_cache "Cursor — cache & logs" 1 item \
  "Cursor's web caches and logs. Chats, settings, extensions and logins are kept." \
  ai_cursor_cache "$_c/Cursor" cursor
reg_list_item ai_windsurf_cache "Windsurf — index & browser cache" 1 item \
  "Windsurf's code index (rebuilt on next launch) and the cache of its built-in browser. Logins and settings are kept." \
  ai_windsurf_cache "$HOME/.codeium" 'windsurf|language_server'
reg_list_item ai_cline_cache "Cline — logs" 1 item \
  "Cline's log files. Sessions and settings are kept." \
  ai_cline_cache "$HOME/.cline" cline
reg_list_item ai_kilo_cache "Kilo Code — cache & logs" 1 item \
  "Kilo Code's model list, downloaded helpers and logs. Sessions and logins are kept." \
  ai_kilo_cache "$HOME/.cache/kilo
$_d/kilo" 'kilo|kilocode'
reg_list_item ai_mimocode_cache "MiMoCode — cache & logs" 1 item \
  "MiMoCode's download cache and logs. Sessions (its databases) and logins are kept." \
  ai_mimocode_cache "$HOME/.cache/mimocode
$_d/mimocode" mimo
reg_list_item ai_zcode_cache "ZCode — logs" 1 item \
  "Daily logs of the ZCode app and CLI. Sessions, credentials and settings are kept." \
  ai_zcode_cache "$HOME/.zcode" 'zcode|zcode-cli|ZCode'
reg_list_item ai_zed_cache "Zed — hang traces & old agents" 1 item \
  "Older versions of AI agents Zed downloaded (the newest is kept), and hang traces." \
  ai_zed_cache "$_d/zed" 'zed|zed-editor'
reg_list_item ai_zed_downloads "Zed — agents & language servers" 0 item \
  "All AI agents and language servers Zed downloaded. Zed downloads them again when needed." \
  ai_zed_downloads "$_d/zed" 'zed|zed-editor' n
reg_list_item ai_misc_cache "Copilot & Continue — cache" 1 item "Copilot CLI logs and Continue's code index." \
  ai_misc_cache "$HOME/.copilot
$HOME/.continue"
reg_list_item ai_misc_history "Copilot & Continue — sessions" 0 session \
  "Copilot CLI and Continue sessions older than 30 days." \
  ai_misc_history "$HOME/.copilot
$HOME/.continue"
reg vscode_stale_workspaces ai "VS Code & forks — data of deleted projects" 0 "Per-project storage (extension state, search index) of VS Code, Cursor, Windsurf and VSCodium for projects that no longer exist. Each is moved to the Trash; close the editor first."
unset _c _d

# Editor data of projects that no longer exist. VS Code and its forks keep a folder per workspace in
# User/workspaceStorage (extension state, search index); it stays after the project is deleted.
# Orphan = workspace.json names a file:// folder or .code-workspace file that is gone (its nearest
# existing parent must be readable; drives that aren't mounted, remote and unreadable ones are kept).
# Each folder is its own entry, moved to the Trash (z puts it back), skipped while the editor runs
# or has a file in it open. globalStorage and History are never touched. Not ticked.
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_vscode_stale_workspaces='^/[A-Za-z0-9/._~%-]+$' # the folder's full path, percent-encoded (urlencode_path)

editor_workspace_roots() { # → lines "editor<TAB>…/User/workspaceStorage"
  local e
  for e in "Code" "Code - Insiders" "VSCodium" "Cursor" "Windsurf"; do
    printf '%s\t%s\n' "$e" "${XDG_CONFIG_HOME:-$HOME/.config}/$e/User/workspaceStorage"
  done
  printf '%s\t%s\n' "Code" "$HOME/snap/code/common/.config/Code/User/workspaceStorage" \
    "VSCodium" "$HOME/snap/codium/common/.config/VSCodium/User/workspaceStorage" \
    "Code" "$HOME/.var/app/com.visualstudio.code/config/Code/User/workspaceStorage" \
    "VSCodium" "$HOME/.var/app/com.vscodium.codium/config/VSCodium/User/workspaceStorage"
}

workspace_target() { # DIR → WT_PATH: the local path DIR/workspace.json points to; fails for anything else
  local f=$1/workspace.json json v
  WT_PATH=""
  [[ -f $f && ! -L $f ]] || return 1
  [[ $(stat -c %s -- "$f" 2>/dev/null) -le 65536 ]] || return 1
  json=$(<"$f") || return 1
  [[ $json =~ \"(folder|workspace)\"[[:space:]]*:[[:space:]]*\"(file:///[^\"]*)\" ]] || return 1
  v=${BASH_REMATCH[2]#file://}
  [[ $v != *\\* ]] || return 1
  urldecode_path v "$v"
  [[ $v == /* && $v != *[[:cntrl:]]* && $v != */../* && $v != */.. && $v != */./* ]] || return 1
  WT_PATH=${v%/}
  [[ -n $WT_PATH ]]
}

path_gone() { # PATH → true only when PATH is certainly missing: the nearest existing parent can be searched
  local p=$1 v
  [[ -e $p || -L $p ]] && return 1
  for v in "${VOLUME_ROOTS[@]}"; do # a drive that isn't plugged in
    [[ $p == "$v"/* ]] || continue
    v=${p#"$v"/}
    [[ -d ${p%"$v"}${v%%/*} ]] || return 1
    break
  done
  while [[ $p != / && ! -e $p && ! -L $p ]]; do p=${p%/*}; [[ -n $p ]] || p=/; done
  [[ -d $p && -x $p ]]
}

stale_workspaces() { # → EW_DIR (storage folder) / EW_BYTES / EW_LABEL, biggest first
  local editor root d name b m now open i lines=() dirs=() sizes=()
  EW_DIR=() EW_BYTES=() EW_LABEL=()
  open=$'\n'$(open_files)$'\n'
  exclusion_prune
  printf -v now '%(%s)T' -1
  while IFS=$'\t' read -r editor root; do
    [[ -d $root && ! -L $root ]] || continue
    for d in "$root"/*/; do
      d=${d%/}
      [[ -d $d && ! -L $d ]] || continue
      touches_exclusion "$d" && continue
      workspace_target "$d" || continue
      path_gone "$WT_PATH" || continue
      open_under "$open" "$d" && continue
      name=${WT_PATH##*/}; name=${name%.code-workspace}
      m=$(stat -c %Y -- "$d/state.vscdb" "$d" 2>/dev/null | head -n1)
      dirs+=("$d") lines+=("$d"$'\t'"$name · $editor · $(((now - ${m:-$now}) / 86400)) days")
    done
  done < <(editor_workspace_roots)
  mapfile -t sizes < <(printf '%s' "${dirs[@]/%/$'\n'}" | sized_paths vscode_stale_workspaces du_bytes)
  ((${#lines[@]})) || return 0
  for i in "${!lines[@]}"; do lines[i]=${sizes[i]:-0}$'\t'${lines[i]}; done
  while IFS=$'\t' read -r b d name; do
    EW_BYTES+=("$b") EW_DIR+=("$d") EW_LABEL+=("$name")
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr)
}

lockedby_vscode_stale_workspaces() { running_proc -x 'code|code-insiders|codium|vscodium|cursor|windsurf'; }
precheck_vscode_stale_workspaces() { # an editor is running: skip when unattended, otherwise ask
  lockedby_vscode_stale_workspaces >/dev/null || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[vscode_stale_workspaces]}: an editor is running."; return 1; fi
  ui_confirm "An editor is running" "Close VS Code, Cursor and the others first. Clean anyway?" n
}

trash_workspaces() { # INDEX… of EW_DIR — move them to the Trash; @@undo lines let the terminal app undo it
  local i d rc=0
  UNDO_BATCH=()
  for i; do move_to_trash "${EW_DIR[i]}" || rc=1; done
  for d in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$d"; done
  return "$rc"
}

scan_vscode_stale_workspaces() {
  local b
  stale_workspaces
  ((${#EW_DIR[@]})) || return 2
  SCAN_BYTES=0
  for b in "${EW_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#EW_DIR[@]} project) that no longer exist"
}
clean_vscode_stale_workspaces() {
  stale_workspaces
  ((${#EW_DIR[@]})) || return 0
  trash_workspaces "${!EW_DIR[@]}"
}
details_vscode_stale_workspaces() {
  local i
  stale_workspaces
  for i in "${!EW_DIR[@]}"; do
    printf '  %s%10s%s  %s\n' "$(size_color "${EW_BYTES[i]}")" "$(human "${EW_BYTES[i]}")" "$NC" "${EW_LABEL[i]}"
  done
}
entries_vscode_stale_workspaces() {
  local i
  stale_workspaces
  for i in "${!EW_DIR[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${EW_DIR[i]}")" "${EW_BYTES[i]}" "${EW_LABEL[i]}"
  done
}
clean_entries_vscode_stale_workspaces() { # encoded folders (json_clean_entries only passes ones listed now)
  local i id pick=()
  stale_workspaces
  for id; do
    for i in "${!EW_DIR[@]}"; do [[ $(urlencode_path "${EW_DIR[i]}") == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  trash_workspaces "${pick[@]}"
}

# Files under ~/.cache untouched for 30+ days, excluding caches handled elsewhere.
app_cache_find() {
  # Exclude with -path tests, not -prune: -delete implies -depth, which disables -prune.
  local ex=(thumbnails pip go-build yarn pnpm mozilla google-chrome chromium BraveSoftware
    microsoft-edge vivaldi opera huggingface lm-studio firebase JetBrains 'Google/AndroidStudio*' spotify/Storage) skip=() e # AI models, old IDE versions and Spotify's cache are items of their own
  for e in "${ex[@]}"; do skip+=(-path "$HOME/.cache/$e/*" -o); done
  unset 'skip[-1]'
  find "$HOME/.cache" -type f -not \( "${skip[@]}" \) -mtime +"$CACHE_DAYS" -atime +"$CACHE_DAYS" "$@" 2>/dev/null
}
scan_app_cache() {
  [[ -d $HOME/.cache ]] || return 1
  local n
  read -r n SCAN_BYTES < <(app_cache_find -printf '%s\n' | count_sum)
  SCAN_NOTE="$(plural "$n" file) in ~/.cache"
  ((SCAN_BYTES > 0)) || return 2
}
clean_app_cache() {
  if ((DRY_RUN)); then run find "$HOME/.cache" -type f -mtime +"$CACHE_DAYS" -atime +"$CACHE_DAYS" -delete "(excluding browser/dev caches)"
  else log "app_cache_find -delete"; app_cache_find -delete || true; fi
}
details_app_cache() { # grouped per application folder
  app_cache_find -printf '%s\t%P\n' |
    awk -F'\t' -v h="$HOME" '{split($2, a, "/"); s[a[1]] += $1} END {for (k in s) print s[k] "\t" h "/.cache/" k}' |
    detail_files 30
}

# ── Developer ──

NM_DAYS=90
NM_LIST="$LOG_DIR/stale-node-modules.tsv"
# A project counts only with package.json AND a lockfile (installed apps ship
# node_modules without lockfiles), and when nothing at its top level changed
# for NM_DAYS.
nm_has_lock() { # NODE_MODULES_DIR — a real folder next to package.json and a lockfile
  local p=${1%/node_modules} lock
  [[ ${1##*/} == node_modules && -d $1 && ! -L $1 && -f $p/package.json ]] || return 1
  for lock in package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock npm-shrinkwrap.json; do
    [[ -f $p/$lock ]] && return 0
  done
  return 1
}
nm_is_stale() { # NODE_MODULES_DIR
  nm_has_lock "$1" || return 1
  [[ -z $(find "${1%/node_modules}" -mindepth 1 -maxdepth 1 -not -name node_modules -mtime -"$NM_DAYS" -print -quit 2>/dev/null) ]]
}
own_bytes() { # PATH… → bytes deleting them frees, like du -sbx, but a file hard-linked from elsewhere (the
  # pnpm store, Bun's cache) counts only when all its links are inside: then each inode once. Folders
  # count 0, as du -b does.
  find "$@" -xdev -printf '%y %D:%i %n %s\n' 2>/dev/null | awk '
    $1 == "d" { next }
    $1 == "f" && $3 > 1 { if (!($2 in seen)) { size[$2] = $4; links[$2] = $3 } seen[$2]++; next }
    { t += $4 }
    END { for (k in seen) if (seen[k] >= links[k]) t += size[k]; printf "%.0f\n", t }'
}
# Sizes of project folders, measured nproc at a time and cached in CACHE_DIR between scans. A cached
# size is used only while the folders and what is directly inside them are unchanged (count, inodes,
# times, sizes and links), and for SIZE_CACHE_DAYS at most, so a change deeper down shows within days.
SIZE_CACHE_DAYS=7
path_sigs() { # PATH… → "PATH<TAB>signature" of each, one find for all
  find "$@" -maxdepth 1 -printf '%H\t%i %T@ %s %n\n' 2>/dev/null | awk -F'\t' '
    { split($2, a, " "); i = index(a[2], "."); k = $1; n[k]++; ino[k] += a[1]; sz[k] += a[3]; ln[k] += a[4]
      if (i) { sec[k] += substr(a[2], 1, i - 1); ns[k] += substr(a[2], i + 1) } else sec[k] += a[2] }
    END { for (k in n) printf "%s\t%.0f.%.0f.%.0f.%.0f.%.0f.%.0f\n", k, n[k], ino[k], sec[k], ns[k], sz[k], ln[k] }'
}
sized_paths() { # NAME MEASURE — stdin: lines of tab-separated paths; stdout: the bytes `MEASURE PATH…` gives for each line, in order
  local name=$1 measure=$2 file now jobs line sig t b i out p ps running recs=() all=() cache=()
  local -A c_sig=() c_time=() c_bytes=() sig_of=()
  file=$CACHE_DIR/sizes-$name.tsv
  printf -v now '%(%s)T' -1
  mapfile -t recs
  ((${#recs[@]})) || { rm -f -- "$file"; return 0; }
  if [[ -f $file && ! -L $file ]]; then
    while IFS=$'\t' read -r sig t b line; do
      [[ $t =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] && ((t <= now && now - t < SIZE_CACHE_DAYS * 86400)) || continue
      c_sig[$line]=$sig c_time[$line]=$t c_bytes[$line]=$b
    done <"$file"
  fi
  for line in "${recs[@]}"; do IFS=$'\t' read -ra ps <<<"$line"; all+=("${ps[@]}"); done
  while IFS=$'\t' read -r p sig; do sig_of[$p]=$sig; done < <(path_sigs "${all[@]}")
  jobs=$(nproc 2>/dev/null) && ((jobs > 0)) || jobs=2
  out=$(
    running=0
    for i in "${!recs[@]}"; do
      IFS=$'\t' read -ra ps <<<"${recs[i]}"
      sig=""
      for p in "${ps[@]}"; do sig+=${sig:+,}${sig_of[$p]:-?}; done # signatures are measured before the sizes
      if [[ $sig != *'?'* && ${c_sig[${recs[i]}]-} == "$sig" ]]; then
        printf '%d\t%s\t%s\t%s\n' "$i" "$sig" "${c_time[${recs[i]}]}" "${c_bytes[${recs[i]}]}"
        continue
      fi
      if ((running >= jobs)); then wait -n; ((running--)); fi
      ( b=$("$measure" "${ps[@]}"); printf '%d\t%s\t%s\t%s\n' "$i" "$sig" "$now" "${b:-0}" ) &
      ((++running))
    done
    wait
  )
  while IFS=$'\t' read -r i sig t b; do
    [[ $sig == *'?'* ]] || cache+=("$sig"$'\t'"$t"$'\t'"$b"$'\t'"${recs[i]}")
    printf '%s\n' "$b"
  done < <(sort -t $'\t' -k1,1n <<<"$out")
  # only the folders seen now: the file never grows past one line per folder
  mkdir -p "$CACHE_DIR" 2>/dev/null && printf '%s\n' "${cache[@]}" >"$file.$BASHPID" 2>/dev/null &&
    mv -f "$file.$BASHPID" "$file" 2>/dev/null
  return 0
}
find_stale_node_modules() { # bytes<TAB>path of stale node_modules, outside your excluded folders
  local d p dirs=() stale=() sizes=() i
  local -A recent=()
  exclusion_prune
  while IFS= read -r d; do
    touches_exclusion "$d" && continue
    nm_has_lock "$d" && dirs+=("$d")
  done < <(find "$HOME" -xdev "${XPRUNE[@]}" \( -path "$HOME/.*" -o -path "$HOME/snap" -o -path "$HOME/Applications" \
    -o -path '*/resources/app' -o -name .git \) -prune -o -type d -name node_modules -prune -print 2>/dev/null)
  # one find for all: the projects with something at their top level changed within NM_DAYS
  # (unreadable folders make find fail; the list is still valid)
  ((${#dirs[@]})) && while IFS= read -r p; do recent[$p]=1; done < <(find "${dirs[@]%/node_modules}" -mindepth 1 -maxdepth 1 \
    -not -name node_modules -mtime -"$NM_DAYS" -printf '%H\n' 2>/dev/null)
  for d in "${dirs[@]}"; do [[ -n ${recent[${d%/node_modules}]:-} ]] || stale+=("$d"); done
  mapfile -t sizes < <(printf '%s' "${stale[@]/%/$'\n'}" | sized_paths node_modules own_bytes) # none: forgets the cached sizes
  for i in "${!stale[@]}"; do printf '%s\t%s\n' "${sizes[i]:-0}" "${stale[i]}"; done
}
scan_node_modules() {
  have node || have npm || return 1
  mkdir -p "$LOG_DIR" || return 1
  { find_stale_node_modules; true; } | sort -t$'\t' -k1,1rn >"$NM_LIST.tmp"; mv -f "$NM_LIST.tmp" "$NM_LIST"
  local n
  n=$(wc -l <"$NM_LIST")
  SCAN_BYTES=$(cut -f1 "$NM_LIST" | sum_lines)
  SCAN_NOTE="$(plural "$n" project) idle for ${NM_DAYS}+ days"
  ((n > 0)) || return 2
}
clean_node_modules() {
  local b d
  while IFS=$'\t' read -r b d; do
    nm_is_stale "$d" || continue # re-check: the project may have been used since the scan
    is_protected "$d" && continue
    touches_exclusion "$(realpath -m -s -- "$d")" && continue # excluded since the scan
    run rm -rf -- "$d"
  done <"$NM_LIST"
}
details_node_modules() { [[ -f $NM_LIST ]] && detail_files 100 <"$NM_LIST"; }

# Build folders of projects left alone: Cargo's target/, a Python virtual environment (.venv/ or
# venv/ with a pyvenv.cfg) and CocoaPods' Pods/, each only next to the project file that makes it.
# Found like stale node_modules (same folders, never inside node_modules, build folders, symlinks or
# other file systems). A project is left alone when its project files, lockfiles and the .git/index
# of its repository (in the project or a folder above it in your home) haven't changed for NM_DAYS.
# A project a cargo, rustc, python, uv or pod process works in, or with a file open in it, is
# skipped. Rebuilding can take long, so cleaning moves them to the Trash (z puts them back); the
# desktop app lists each project as an entry.
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_stale_build_dirs='^/[A-Za-z0-9/._~%-]+$' # the project folder's full path, percent-encoded (urlencode_path)

build_dirs_of() { # PROJECT → BD_DIRS: names of its build folders
  local p=$1 f py=0
  BD_DIRS=()
  [[ -f $p/Cargo.toml && -d $p/target && ! -L $p/target ]] && BD_DIRS+=(target)
  [[ -f $p/pyproject.toml || -f $p/setup.py ]] && py=1
  for f in "$p"/requirements*.txt; do [[ -f $f ]] && py=1; done
  if ((py)); then
    for f in .venv venv; do [[ -d $p/$f && ! -L $p/$f && -f $p/$f/pyvenv.cfg ]] && BD_DIRS+=("$f"); done
  fi
  [[ -f $p/Podfile && -d $p/Pods && ! -L $p/Pods ]] && BD_DIRS+=(Pods)
  return 0
}

project_files() { # PROJECT → PF: its project files, lockfiles and its repository's .git/index (some may not exist)
  local p=$1 d=$1 g
  PF=("$p"/{Cargo.toml,Cargo.lock,pyproject.toml,setup.py,setup.cfg,Pipfile,Pipfile.lock,poetry.lock,uv.lock,pdm.lock,Podfile,Podfile.lock}
    "$p"/requirements*.txt)
  while [[ $d == "$HOME"/* ]]; do
    if [[ -f $d/.git ]]; then # a worktree or submodule: "gitdir: PATH"
      { read -r g <"$d/.git"; } 2>/dev/null && g=${g#gitdir: } && { [[ $g == /* ]] || g=$d/$g; } && PF+=("$g/index")
    else PF+=("$d/.git/index"); fi
    d=${d%/*}
  done
}

busy_paths() { # files your processes have open, and the folders cargo, rustc, python, uv or pod work in
  local d c
  open_files
  for d in /proc/[0-9]*; do
    { read -r c <"$d/comm"; } 2>/dev/null || continue
    case $c in cargo | rustc | python* | uv | pod) readlink -- "$d/cwd" 2>/dev/null ;; esac
  done
  return 0
}

stale_build_dirs() { # → SB_DIR (project) / SB_WHAT (its build folders, space-separated) / SB_BYTES / SB_DAYS, biggest first
  local d p busy now changed b f i rec what=() dirs=() files=() recs=() sizes=() keep=()
  local -A seen=() mtime=()
  SB_DIR=() SB_WHAT=() SB_BYTES=() SB_DAYS=()
  busy=$'\n'$(busy_paths)$'\n'
  exclusion_prune
  printf -v now '%(%s)T' -1
  while IFS= read -r d; do
    p=${d%/*}
    [[ $p == "$HOME"/* && $p != *[[:cntrl:]]* && -z ${seen[$p]:-} ]] || continue
    seen[$p]=1
    build_dirs_of "$p"
    for i in "${!BD_DIRS[@]}"; do touches_exclusion "$p/${BD_DIRS[i]}" && unset "BD_DIRS[i]"; done
    ((${#BD_DIRS[@]})) || continue
    # in use (a path containing it elsewhere only errs on the safe side)
    [[ $busy == *$'\n'"$p"$'\n'* || $busy == *"$p/"* ]] && continue
    project_files "$p"
    files+=("${PF[@]}")
    rec=""
    for b in "${BD_DIRS[@]}"; do rec+=${rec:+$'\t'}$p/$b; done
    what+=("${BD_DIRS[*]}") dirs+=("$p") recs+=("$rec")
  done < <(find "$HOME" -xdev "${XPRUNE[@]}" \( -path "$HOME/.*" -o -path "$HOME/snap" -o -path "$HOME/Applications" \
    -o -path '*/resources/app' -o -name .git -o -name node_modules \) -prune -o \
    -type d \( -name target -o -name .venv -o -name venv -o -name Pods \) -prune -print 2>/dev/null)
  # when each project last changed: one stat for all their files
  ((${#files[@]})) && while IFS=$'\t' read -r changed f; do mtime[$f]=$changed; done < <(stat -c $'%Y\t%n' -- "${files[@]}" 2>/dev/null)
  for i in "${!dirs[@]}"; do
    project_files "${dirs[i]}"
    changed=0
    for f in "${PF[@]}"; do ((${mtime[$f]:-0} > changed)) && changed=${mtime[$f]}; done
    ((now - changed >= NM_DAYS * 86400)) && keep+=("$i"$'\t'"$changed")
  done
  mapfile -t sizes < <(for i in "${keep[@]}"; do printf '%s\n' "${recs[${i%%$'\t'*}]}"; done | sized_paths stale_build_dirs own_bytes)
  while IFS=$'\t' read -r b changed d p; do
    SB_BYTES+=("$b") SB_DAYS+=($(((now - changed) / 86400))) SB_WHAT+=("$d") SB_DIR+=("$p")
  done < <(for f in "${!keep[@]}"; do
    i=${keep[f]%%$'\t'*}
    printf '%s\t%s\t%s\t%s\n' "${sizes[f]:-0}" "${keep[f]#*$'\t'}" "${what[i]}" "${dirs[i]}"
  done | sort -t $'\t' -k1,1nr)
}

trash_build_dirs() { # INDEX… of SB_DIR — move their build folders to the Trash; @@undo lines let the terminal app undo it
  local i d rc=0 what
  UNDO_BATCH=()
  for i; do
    read -ra what <<<"${SB_WHAT[i]}"
    for d in "${what[@]}"; do move_to_trash "${SB_DIR[i]}/$d" || rc=1; done
  done
  for d in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$d"; done
  return "$rc"
}

build_dirs_label() { # INDEX → "~/code/api — target/, .venv/ · 120 days idle"
  local w=${SB_WHAT[$1]}/
  printf '%s — %s · %s days idle' "${SB_DIR[$1]/#$HOME/\~}" "${w// //, }" "${SB_DAYS[$1]}"
}

scan_stale_build_dirs() {
  local b
  stale_build_dirs
  ((${#SB_DIR[@]})) || return 2
  SCAN_BYTES=0
  for b in "${SB_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#SB_DIR[@]} project) idle for ${NM_DAYS}+ days"
}
clean_stale_build_dirs() {
  stale_build_dirs
  ((${#SB_DIR[@]})) || return 0
  trash_build_dirs "${!SB_DIR[@]}"
}
details_stale_build_dirs() {
  local i
  stale_build_dirs
  for i in "${!SB_DIR[@]}"; do
    printf '  %s%10s%s  %s\n' "$(size_color "${SB_BYTES[i]}")" "$(human "${SB_BYTES[i]}")" "$NC" "$(build_dirs_label "$i")"
  done
}
entries_stale_build_dirs() {
  local i
  stale_build_dirs
  for i in "${!SB_DIR[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${SB_DIR[i]}")" "${SB_BYTES[i]}" "$(build_dirs_label "$i")"
  done
}
clean_entries_stale_build_dirs() { # encoded project folders (json_clean_entries only passes ones listed now)
  local i id pick=()
  stale_build_dirs
  for id; do
    for i in "${!SB_DIR[@]}"; do [[ $(urlencode_path "${SB_DIR[i]}") == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  trash_build_dirs "${pick[@]}"
}

dev_scan() { # NOTE PATH...
  local note=$1; shift
  local p any=0
  for p in "$@"; do [[ -e $p ]] && any=1; done
  ((any)) || return 1
  SCAN_BYTES=$(du_sum "$@")
  SCAN_NOTE=$note
  ((SCAN_BYTES > 0)) || return 2
}

NPM_PATHS=("$HOME/.npm/_cacache")
scan_npm() { dev_scan "~/.npm/_cacache" "${NPM_PATHS[@]}"; }
clean_npm() { if have npm; then run npm cache clean --force; else empty_dir "${NPM_PATHS[0]}"; fi; }
details_npm() { detail_paths "${NPM_PATHS[@]}"; }

YARN_PATHS=("$HOME/.cache/yarn" "$HOME/.yarn/berry/cache")
scan_yarn() { dev_scan "~/.cache/yarn" "${YARN_PATHS[@]}"; }
clean_yarn() { local p; for p in "${YARN_PATHS[@]}"; do empty_dir "$p"; done; }
details_yarn() { detail_paths "${YARN_PATHS[@]}"; }

PNPM_PATHS=("${XDG_DATA_HOME:-$HOME/.local/share}/pnpm/store")
scan_pnpm() { have pnpm || return 1; dev_scan "store size; prune keeps used packages" "${PNPM_PATHS[@]}"; }
clean_pnpm() { run pnpm store prune; }
details_pnpm() { detail_paths "${PNPM_PATHS[@]}"; }

BUN_PATHS=("$HOME/.bun/install/cache")
scan_bun() { dev_scan "~/.bun/install/cache" "${BUN_PATHS[@]}"; }
clean_bun() { if have bun; then run bun pm cache rm; else empty_dir "${BUN_PATHS[0]}"; fi; }
details_bun() { detail_paths "${BUN_PATHS[@]}"; }

PIP_PATHS=("$HOME/.cache/pip")
scan_pip() { dev_scan "~/.cache/pip" "${PIP_PATHS[@]}"; }
clean_pip() { empty_dir "${PIP_PATHS[0]}"; }
details_pip() { detail_paths "${PIP_PATHS[@]}"; }

GO_PATHS=("$HOME/.cache/go-build")
scan_gobuild() { dev_scan "~/.cache/go-build" "${GO_PATHS[@]}"; }
clean_gobuild() { if have go; then run go clean -cache; else empty_dir "${GO_PATHS[0]}"; fi; }
details_gobuild() { detail_paths "${GO_PATHS[@]}"; }

CARGO_PATHS=("$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src")
scan_cargo() { dev_scan "~/.cargo/registry" "${CARGO_PATHS[@]}"; }
clean_cargo() { local p; for p in "${CARGO_PATHS[@]}"; do empty_dir "$p"; done; }
details_cargo() { detail_paths "${CARGO_PATHS[@]}"; }

GRADLE_PATHS=("$HOME/.gradle/caches")
scan_gradle() { dev_scan "~/.gradle/caches" "${GRADLE_PATHS[@]}"; }
clean_gradle() { empty_dir "${GRADLE_PATHS[0]}"; }
details_gradle() { detail_paths "${GRADLE_PATHS[@]}"; }

MAVEN_PATHS=("$HOME/.m2/repository")
scan_maven() { dev_scan "~/.m2/repository" "${MAVEN_PATHS[@]}"; }
clean_maven() { empty_dir "${MAVEN_PATHS[0]}"; }
details_maven() { detail_paths "${MAVEN_PATHS[@]}"; }

# A folder a tool is pointed to by an environment variable: the live environment first, then
# the last `export NAME=value` in the shell startup files (read as text, never run). Only a
# plain path inside HOME ($HOME, ${HOME} or ~ allowed) counts; anything else is ignored.
declare -A ENV_PROFILE=() # NAME → its last NAME=… line in the startup files (a later file wins)
env_profile_read() { # once, while loading: a grep per variable and file cost more than reading them
  local f line re='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)='
  for f in .profile .bash_profile .bashrc .zshenv .zprofile .zshrc; do
    [[ -f $HOME/$f && ! -L $HOME/$f && -r $HOME/$f ]] || continue
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ $re ]] && ENV_PROFILE[${BASH_REMATCH[2]}]=$line
    done 2>/dev/null <"$HOME/$f"
  done
}
env_profile_read
env_valuev() { # VAR NAME → NAME's value (live environment, else the shell startup files) with ~ and $HOME expanded, or ""
  local -n __ev=$1
  local __n=$2 __v
  __v=${!__n:-}
  if [[ -z $__v && -n ${ENV_PROFILE[$__n]+x} ]]; then
    __v=${ENV_PROFILE[$__n]}
    __v=${__v#*"$__n"=}
    __v=${__v%%[[:space:]]#*}
    __v=${__v#\"}; __v=${__v%\"}; __v=${__v#\'}; __v=${__v%\'}
  fi
  __v=${__v/#\~/$HOME}; __v=${__v/#\$\{HOME\}/$HOME}; __v=${__v/#\$HOME/$HOME}
  __ev=$__v
}
env_value() { local v; env_valuev v "$1"; [[ -n $v ]] && printf '%s\n' "$v"; return 0; } # NAME → its value, or nothing
env_home_dirv() { # VAR NAME → NAME's folder when it's a plain path inside HOME, else ""
  local -n __ehd=$1
  local __hv
  env_valuev __hv "$2"
  if [[ $__hv == "$HOME"/* && $__hv != *[\$\`\;\&\|\<\>\(\)\\]* && $__hv != *..* && ! -L $__hv ]]; then __ehd=${__hv%/}; else __ehd=""; fi
}
env_home_dir() { local v; env_home_dirv v "$1"; [[ -n $v ]] && printf '%s\n' "$v"; return 0; } # NAME → path, or nothing
uniq_lines() { # LINE… → each once, in order (no awk: called while loading)
  local -A __seen=()
  local l
  for l; do [[ -n ${__seen[x$l]+x} ]] || { __seen[x$l]=1; printf '%s\n' "$l"; }; done
}
env_home_paths() { # NAME SUBFOLDER|"" DEFAULT... → the default folders plus NAME's (+ /SUBFOLDER), one per line
  local e
  env_home_dirv e "$1"
  [[ -n $e && -n $2 ]] && e+=/$2
  uniq_lines "${@:3}" ${e:+"$e"}
}

reg_cache_item uv_cache dev "uv cache" 1 \
  "uv's package and wheel cache (~/.cache/uv). Re-downloaded on next use; your environments are kept." \
  "$(env_home_paths UV_CACHE_DIR "" "$HOME/.cache/uv")" "uv|uvx"
reg_cache_item rustup_downloads dev "rustup downloads" 1 \
  "Leftover rustup downloads and temp files. Your installed toolchains are kept." \
  "$(env_home_paths RUSTUP_HOME downloads "$HOME/.rustup/downloads")
$(env_home_paths RUSTUP_HOME tmp "$HOME/.rustup/tmp")" "rustup"
reg_cache_item browser_test_cache dev "Playwright, Puppeteer & Cypress browsers" 0 \
  "Browsers downloaded for test tools (~/.cache/ms-playwright, puppeteer, Cypress). Re-downloaded on next install or test run." \
  "$HOME/.cache/ms-playwright
$HOME/.cache/puppeteer
$HOME/.cache/Cypress" "node|playwright"

# Firebase CLI: its debug logs (`firebase mcp` writes them without limit, rotating to .1–.9) and the
# emulators it downloaded. The CLI runs as `node`, so a log a process still has open is skipped
# instead of looking for the CLI by name. Never configstore/firebase-tools.json (login),
# crashlytics/, extensions/ or logs inside projects.
open_files() { # every file a process of yours (all of them as root) has open; not folders: scanning opens
  # them for a moment (other items run at the same time), programs keep files open. The path is
  # checked, not the fd: one closed between find's steps passes `-xtype d`
  local l
  while IFS= read -r l; do
    [[ $l == /* && ! -d $l ]] && printf '%s\n' "$l"
  done < <(find /proc/[0-9]*/fd -type l -printf '%l\n' 2>/dev/null)
  return 0
}
firebase_logs() {
  local d=$HOME/.cache/firebase f open
  [[ -d $d && ! -L $d ]] || return 0
  open=$(open_files)
  for f in "$d"/firebase-debug.log "$d"/firebase-debug.*.log; do
    [[ -f $f && ! -L $f ]] || continue
    grep -qxF -- "$f" <<<"$open" || printf '%s\n' "$f"
  done
}
firebase_emulators() { contents "$HOME/.cache/firebase/emulators"; }
LIST_CAT=dev reg_list_item firebase_logs "Firebase CLI logs" 1 file \
  "Debug logs of the Firebase CLI (firebase mcp can grow them to gigabytes). A log still being written is skipped. Your login is kept." \
  firebase_logs "$HOME/.cache/firebase"
LIST_CAT=dev reg_list_item firebase_emulators "Firebase emulators" 0 item \
  "Emulators the Firebase CLI downloaded (Firestore, Database, Pub/Sub, UI…). Downloaded again when you start them." \
  firebase_emulators "$HOME/.cache/firebase"

# Build tool caches (not ticked, skipped while the tool runs, deleted for good). Each item lists only the
# cache folders of its tool, also under a folder set by the tool's variable or XDG_CACHE_HOME, so a wrong
# value deletes nothing else. Never Deno's location_data, Poetry's virtualenvs, pipx's venvs and py,
# ccache.conf, Bazel's output bases or ~/.nuget/packages.
sub_paths() { # "NAME NAME…" BASE… → BASE/NAME for each (NAME "." = BASE itself), one per line, no duplicates
  local subs=$1 b n out=()
  shift
  for b; do
    [[ -n $b ]] || continue
    for n in $subs; do if [[ $n == . ]]; then out+=("$b"); else out+=("$b/$n"); fi; done
  done
  ((${#out[@]})) && uniq_lines "${out[@]}"
  return 0
}
xdg_cache() { env_home_dir XDG_CACHE_HOME; }
_xc="" # XDG_CACHE_HOME's folder, for the items below
env_home_dirv _xc XDG_CACHE_HOME
HEX_NAMES="0 1 2 3 4 5 6 7 8 9 a b c d e f"
reg_cache_item deno_cache dev "Deno cache" 0 \
  "Modules and npm packages Deno downloaded, plus its compiled code. Downloaded again on the next run; localStorage data of scripts (location_data) is kept." \
  "$(sub_paths "remote npm gen registries dl deps" "$HOME/.cache/deno" "$_xc/deno" "$(env_home_dir DENO_DIR)")" "deno"
reg_cache_item zig_cache dev "Zig cache" 0 \
  "Build outputs and fetched packages of Zig. Made again by the next build." \
  "$(sub_paths "o h z p tmp" "$HOME/.cache/zig" "$_xc/zig" "$(env_home_dir ZIG_GLOBAL_CACHE_DIR)")" "zig|zls"
reg_cache_item bazel_cache dev "Bazel cache" 0 \
  "Dependencies Bazel downloaded and its unpacked install. Made again by the next build; the output folders of your workspaces are kept." \
  "$(sub_paths "cache install" "$HOME/.cache/bazel/_bazel_${USER:-$(id -un)}" "$_xc/bazel/_bazel_${USER:-$(id -un)}")" "bazel.*|bazelisk"
reg_cache_item ccache_cache dev "ccache cache" 0 \
  "Compiler outputs ccache saved. Made again by the next build; ccache.conf is kept." \
  "$(sub_paths "$HEX_NAMES tmp" "$HOME/.cache/ccache" "$HOME/.ccache" "$_xc/ccache" "$(env_home_dir CCACHE_DIR)")" "ccache"
reg_cache_item sccache_cache dev "sccache cache" 0 \
  "Compiler outputs sccache saved. Made again by the next build." \
  "$(sub_paths "$HEX_NAMES" "$HOME/.cache/sccache" "$_xc/sccache" "$(env_home_dir SCCACHE_DIR)")" "sccache"
reg_cache_item nuget_cache dev "NuGet cache" 0 \
  "Package metadata and downloads NuGet cached (HTTP caches). Downloaded again by the next restore; ~/.nuget/packages is kept." \
  "$HOME/.local/share/NuGet/v3-cache
$HOME/.local/share/NuGet/http-cache
$HOME/.nuget/v3-cache" "dotnet|nuget"
reg_cache_item poetry_cache dev "Poetry cache" 0 \
  "Packages Poetry downloaded. Downloaded again by poetry install; your virtualenvs are kept." \
  "$(sub_paths "cache artifacts" "$HOME/.cache/pypoetry" "$_xc/pypoetry" "$(env_home_dir POETRY_CACHE_DIR)")" "poetry"
reg_cache_item pipx_cache dev "pipx run cache" 0 \
  "Environments of apps started with pipx run. Made again on the next run; apps installed with pipx install and its Pythons are kept." \
  "$(sub_paths . "$HOME/.cache/pipx" "$_xc/pipx"; sub_paths .cache "$HOME/.local/pipx" "$(env_home_dir PIPX_HOME)")" "pipx"

for _id in deno zig bazel ccache sccache nuget poetry pipx; do ITEM_OPEN[${_id}_cache]=1; done
ITEM_ARGS[bazel_cache]="_bazel_${USER:-$(id -un)}" # the Bazel server is a java process
unset _id

# pre-commit keeps hook repositories and their environments in one folder (PRE_COMMIT_HOME); only those names go,
# and only in a folder that has pre-commit's db.db.
precommit_entries() {
  local b n open kept
  open=$'\n'$(open_files)$'\n'
  for b in "$HOME/.cache/pre-commit" "$(xdg_cache)/pre-commit" "$(env_home_dir PRE_COMMIT_HOME)"; do
    [[ -n $b && -d $b && ! -L $b && -f $b/db.db && ! -L $b/db.db ]] || continue # only pre-commit's own folder
    kept=0
    for n in "$b"/repo* "$b"/patch* "$b/README" "$b/.lock" "$b/db.db"; do
      [[ -e $n && ! -L $n ]] || continue
      # db.db (the marker, and the list of repos) goes last, and only when everything else could go
      if touches_exclusion "$n" || open_under "$open" "$n" || { [[ $n == "$b/db.db" ]] && ((kept)); }; then kept=1
      else printf '%s\n' "$n"; fi
    done
  done | awk '!seen[$0]++'
}
LIST_CAT=dev reg_list_item precommit_cache "pre-commit cache" 0 item \
  "Hook repositories and environments pre-commit made. Installed again on the next commit (slower once)." \
  precommit_entries "$HOME/.cache/pre-commit
$_xc/pre-commit
$(env_home_dir PRE_COMMIT_HOME)" "pre-commit"
unset _xc

# Cloud sync clients: Dropbox (its logs and the .dropbox.cache of each Dropbox folder named in
# ~/.dropbox/info.json — what changed in the last 7 days stays, it may still wait to upload),
# Nextcloud / ownCloud (logs and ~/.cache) and MEGAsync (logs). Never the synced folders, settings,
# logins or databases. Skipped while the client runs or has a file open; not ticked; deleted for good.
CLOUD_CACHE_DAYS=7
dropbox_folders() { # the Dropbox folders of info.json ("personal", "business"): real folders in your home
  local f=$HOME/.dropbox/info.json v p
  [[ -f $f && ! -L $f ]] || return 0
  if have jq; then
    v=$(jq -r 'if type == "object" then [.[] | objects | .path | strings] | .[] else empty end' -- "$f" 2>/dev/null)
  elif have python3; then
    v=$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for e in (d.values() if isinstance(d, dict) else []):
    if isinstance(e, dict) and isinstance(e.get("path"), str): print(e["path"])' "$f" 2>/dev/null)
  else
    return 0
  fi
  while IFS= read -r p; do
    p=${p%/}
    [[ $p == "$HOME"/?* && /$p/ != */../* && -d $p && ! -L $p ]] && printf '%s\n' "$p"
  done <<<"$v"
  return 0
}
cloud_free() { # [DAYS] — paths on stdin that are not excluded, not open and (with DAYS) untouched for DAYS days
  local p open
  open=$'\n'$(open_files)$'\n'
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    touches_exclusion "$p" && continue
    open_under "$open" "$p" && continue
    [[ -z ${1:-} || -z $(find "$p" -mtime -"$1" -print -quit 2>/dev/null) ]] && printf '%s\n' "$p"
  done
}
cloud_dropbox() {
  local d
  contents "$HOME/.dropbox/logs" | cloud_free
  while IFS= read -r d; do contents "$d/.dropbox.cache"; done < <(dropbox_folders) | cloud_free "$CLOUD_CACHE_DAYS"
}
cloud_nextcloud() {
  local d
  for d in Nextcloud ownCloud; do
    contents "$HOME/.cache/$d"
    [[ -d $HOME/.local/share/$d && ! -L $HOME/.local/share/$d ]] &&
      find "$HOME/.local/share/$d" -mindepth 1 -maxdepth 1 -type f -name '*.log*' -print 2>/dev/null
  done | cloud_free
}
cloud_mega() { contents "$HOME/.local/share/data/Mega Limited/MEGAsync/logs" | cloud_free; }
LIST_CAT=apps reg_list_item cloud_dropbox "Dropbox — cache & logs" 0 item \
  "Dropbox's logs and the .dropbox.cache of your Dropbox folder (older copies of files) untouched for 7 days. Your files and settings are kept. Skipped while Dropbox runs." \
  cloud_dropbox "$HOME/.dropbox" 'dropbox'
LIST_CAT=apps reg_list_item cloud_nextcloud "Nextcloud & ownCloud — cache & logs" 0 item \
  "Logs and cache of the Nextcloud and ownCloud desktop clients. Your synced folders and settings are kept. Skipped while the client runs." \
  cloud_nextcloud "$HOME/.cache/Nextcloud
$HOME/.local/share/Nextcloud
$HOME/.cache/ownCloud
$HOME/.local/share/ownCloud" 'nextcloud|Nextcloud|owncloud|ownCloud'
LIST_CAT=apps reg_list_item cloud_mega "MEGAsync — logs" 0 item \
  "Logs of the MEGAsync client. Your synced folders and settings are kept. Skipped while MEGAsync runs." \
  cloud_mega "$HOME/.local/share/data/Mega Limited/MEGAsync" 'megasync|MEGAsync'

# Media caches of chat and music apps, downloaded again when needed. Telegram: only cache/ and
# media_cache/ of each account (tdata/user_data*), never the rest of tdata (logins, keys). Spotify:
# the deb's ~/.cache/spotify/Storage (app_cache_find leaves it to this item); the Snap and Flatpak
# caches are already whole items of their own (discover_app_caches).
TELEGRAM_DIRS="$HOME/.local/share/TelegramDesktop
$HOME/snap/telegram-desktop/current/.local/share/TelegramDesktop
$HOME/.var/app/org.telegram.desktop/data/TelegramDesktop"
app_telegram() {
  local d u
  while IFS= read -r d; do
    [[ -d $d/tdata && ! -L $d/tdata ]] || continue
    for u in "$d"/tdata/user_data*; do
      [[ -d $u && ! -L $u ]] || continue
      contents "$u/cache"; contents "$u/media_cache"
    done
  done <<<"$TELEGRAM_DIRS" | cloud_free
}
app_spotify() { contents "$HOME/.cache/spotify/Storage" | cloud_free; }
LIST_CAT=apps reg_list_item app_telegram "Telegram Desktop — media cache" 0 item \
  "Photos, videos and files Telegram Desktop cached; it downloads them again when you open a chat. Your logins and chats are kept. Skipped while Telegram runs." \
  app_telegram "$TELEGRAM_DIRS" 'telegram-deskto.*|Telegram'
LIST_CAT=apps reg_list_item app_spotify "Spotify — cache" 0 item \
  "Songs Spotify cached while streaming; it streams them again when needed. Songs you downloaded for offline listening are stored here too and must be downloaded again. Skipped while Spotify runs." \
  app_spotify "$HOME/.cache/spotify/Storage" 'spotify'

# Flutter/Dart's pub cache: downloaded packages and git checkouts, fetched again by `pub get`.
# Never credentials.json, bin/ or global_packages/ (activated tools).
reg_cache_item pub_cache dev "Dart & Flutter pub cache" 0 \
  "Packages Dart and Flutter downloaded (~/.pub-cache/hosted, git/cache). Fetched again by 'pub get'; activated tools and your pub login are kept." \
  "$(env_home_paths PUB_CACHE hosted "$HOME/.pub-cache/hosted")
$(env_home_paths PUB_CACHE git/cache "$HOME/.pub-cache/git/cache")" "dart|dartaotruntime|flutter"

# Old runtime versions: Node.js versions nvm installed ($NVM_DIR/versions/node/vX.Y.Z), SDKMAN
# candidates ($SDKMAN_DIR/candidates/<java, gradle…>/<version>), Flutter versions fvm installed
# (~/fvm/versions/<version>, $FVM_CACHE_PATH/versions), Python versions of pyenv and Ruby versions of
# rbenv ($PYENV_ROOT|~/.pyenv/versions, $RBENV_ROOT|~/.rbenv/versions), rustup toolchains
# ($RUSTUP_HOME|~/.rustup/toolchains) and Go SDKs golang.org/dl downloaded (~/sdk/go<version>) that
# aren't your default: nvm's alias/default (followed through alias/lts/… and other aliases;
# node/stable = the newest), SDKMAN's current, fvm's default (the default link next to versions/),
# what pyenv's version file names (every line) and rbenv's (the first), rustup's default_toolchain and
# overrides in settings.toml, the Go SDK each go command runs from (go env GOROOT) or your profile names,
# plus the node on PATH, a version your PATH runs from and whatever another nvm alias names; pyenv also
# keeps a version holding virtualenvs. A tool whose default can't be told keeps every version. Versions
# a program runs from (/proc/*/exe, open files) are skipped and the scan says which. Deleted for good
# (the tool installs them again); alias/, current, default, version, settings.toml, shims, downloads and
# .nvmrc are never touched. Not ticked; the desktop app lists each version.
reg old_runtimes dev "Old runtime versions" 0 "Node.js (nvm), Python (pyenv), Ruby (rbenv), Rust toolchains (rustup), Go SDKs (~/sdk), SDKMAN candidates (Java, Gradle, Maven…) and Flutter (fvm) versions that aren't your default. Deleted; install one again with the same tool. A version that is running is skipped."
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_old_runtimes='^/[A-Za-z0-9/._~%-]+$' # the version folder's full path, percent-encoded (urlencode_path)

runtime_dir() { # PATH → PATH when it is a folder inside your home with no symlinks on the way
  [[ $1 == "$HOME"/* && -d $1 && ! -L $1 && $(realpath -e -- "$1" 2>/dev/null) == "$1" ]] && printf '%s\n' "$1"
}

nvm_version() { # NVM_DIR NAME → the installed version folder name (vX.Y.Z) NAME means, following aliases
  local d=$1 v=$2 n f best=""
  for n in 1 2 3 4 5 6 7 8; do
    v=${v//[[:space:]]/}
    [[ -n $v && $v != *..* ]] || return 1
    case $v in node | stable) v=v ;; esac # the newest installed
    f=$d/alias/$v
    [[ $v != v && -f $f && ! -L $f ]] || break
    v=$(head -c 200 -- "$f" 2>/dev/null)
  done
  [[ $v == v* || $v == [0-9]* ]] || return 1
  v=v${v#v}
  for f in "$d"/versions/node/v*/; do
    [[ -d $f ]] || continue
    f=${f%/} f=${f##*/}
    [[ $v == v || $f == "$v" || $f == "$v".* ]] && best+=$f$'\n'
  done
  [[ -n $best ]] || return 1
  printf '%s' "$best" | sort -V | tail -n 1
}

path_versions() { # FOLDER → names of FOLDER's subfolders a PATH folder (live or from your profile) lies in
  local base d ds=()
  base=$(realpath -e -- "$1" 2>/dev/null) || return 0
  IFS=: read -ra ds <<<"${PATH:-}"
  mapfile -t -O "${#ds[@]}" ds < <(profile_path_dirs)
  for d in "${ds[@]}"; do
    [[ -n $d ]] && d=$(realpath -e -- "$d" 2>/dev/null) && [[ $d == "$base"/* ]] || continue
    d=${d#"$base"/}
    printf '%s\n' "${d%%/*}"
  done
}

small_text() { # FILE → its text when it is a regular file of at most 64 KB with something in it; fails otherwise
  local t
  [[ -f $1 && -r $1 ]] && (($(stat -c %s -- "$1" 2>/dev/null || echo 65537) <= 65536)) || return 1
  t=$(cat -- "$1" 2>/dev/null) || return 1
  [[ -n ${t//[[:space:]]/} ]] || return 1
  printf '%s\n' "$t"
}

named_versions() { # VERSIONS FILE PREFIX FIRST_ONLY(0|1) → the installed versions a pyenv/rbenv version file keeps
  # As pyenv and rbenv read it: the first word of each line (rbenv: of the first one), # comments skipped, a
  # python-/ruby- prefix dropped when no such folder exists, 3.11 keeping every installed 3.11.x, system none.
  # A name that is a link in VERSIONS (a pyenv-virtualenv env) keeps the version it lives in too. Fails when it
  # can't be told: no readable file, no version in it, or a name nothing installed matches.
  local dir=$1 file=$2 prefix=$3 first=$4 text line w name m base t words=() matches=()
  text=$(small_text "$file") || return 1
  while IFS= read -r line; do
    w=${line#"${line%%[![:space:]]*}"} w=${w%%[[:space:]]*}
    [[ -n $w && $w != \#* ]] && words+=("$w")
  done <<<"$text"
  ((first)) && words=("${words[@]:0:1}")
  ((${#words[@]})) || return 1
  base=$(realpath -e -- "$dir") || return 1
  for w in "${words[@]}"; do
    [[ $w == system ]] && continue
    [[ $w != . && $w != .. && $w != */* ]] || return 1
    name=$w
    [[ ! -e $dir/$w && $w == "$prefix"* ]] && name=${w#"$prefix"}
    matches=()
    if [[ -e $dir/$name ]]; then matches=("$name")
    else
      for m in "$dir/$name".*; do [[ -e $m ]] && matches+=("${m##*/}"); done
    fi
    ((${#matches[@]})) || return 1
    for m in "${matches[@]}"; do
      printf '%s\n' "$m"
      t=$(realpath -e -- "$dir/$m" 2>/dev/null) && [[ $t == "$base"/* ]] && { t=${t#"$base"/}; printf '%s\n' "${t%%/*}"; }
    done
  done
  return 0
}

rust_kept() { # SETTINGS_TOML → toolchain names rustup keeps: default_toolchain and every [overrides] value, each also
  # with -<default_host_triple> (stable is installed as stable-x86_64-unknown-linux-gnu), or -* without one (any
  # host). Fails when it can't be told: no readable file or no default toolchain (rustup default none).
  local text line section="" key value def="" host="" names=() n
  local re=$'^("[^"]*"|\'[^\']*\'|[A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*("([^"]*)"|\'([^\']*)\')[[:space:]]*(#.*)?$'
  text=$(small_text "$1") || return 1
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"} line=${line%"${line##*[![:space:]]}"}
    if [[ $line == \[* ]]; then section=$line; continue; fi
    [[ $line =~ $re ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
    [[ -n $value ]] || continue
    [[ $section == "[overrides]" ]] && names+=("$value")
    [[ -z $section && $key == default_toolchain ]] && def=$value
    [[ -z $section && $key == default_host_triple ]] && host=$value
  done <<<"$text"
  [[ -n $def ]] || return 1
  for n in "${names[@]}" "$def"; do printf '%s\n%s-%s\n' "$n" "$n" "${host:-*}"; done
}

rust_keeps() { # KEPT(newline-framed, from rust_kept) NAME — a kept name, or a short one (stable-*) for any host
  local k
  [[ $1 == *$'\n'"$2"$'\n'* ]] && return 0
  while IFS= read -r k; do [[ $k == *-\* && $2 == "${k%\*}"* ]] && return 0; done <<<"$1"
  return 1
}

GO_VERSION_RE='^go([0-9]+(\.[0-9]+)*((rc|beta)[0-9]+)?|tip)$' # the folders golang.org/dl downloads to in ~/sdk

go_kept() { # SDK → the SDKs in SDK in use: the one each go command (PATH, your profile's PATH, the usual folders)
  # runs from or reports as `go env GOROOT`, and every one a line of your profile or Go's env file names
  # (PATH=$HOME/sdk/go1.21.0/bin, GOROOT=…, alias go=go1.21.0). Fails when it can't be told: a profile line picks
  # the SDK with a variable ($HOME/sdk/$GOVERSION), a go command that fails, or no go command and no SDK named.
  local sdk f d g root kept="" found=0 dirs=() gos=$'\n'
  sdk=$(realpath -e -- "$1") || return 1
  for f in .profile .bash_profile .bash_login .bashrc .zshenv .zprofile .zshrc .config/fish/config.fish .config/go/env; do
    [[ -f $HOME/$f && -r $HOME/$f ]] || continue
    grep -v '^[[:space:]]*#' -- "$HOME/$f" 2>/dev/null | grep -qE 'sdk/(go)?[$`]' && return 1
    kept+=$(grep -v '^[[:space:]]*#' -- "$HOME/$f" 2>/dev/null | tr -c 'A-Za-z0-9._\n-' '\n' | grep -E "$GO_VERSION_RE")$'\n'
  done
  IFS=: read -ra dirs <<<"${PATH:-}"
  mapfile -t -O "${#dirs[@]}" dirs < <(profile_path_dirs)
  dirs+=(/usr/local/go/bin "$HOME/go/bin" "$HOME/bin" "$HOME/.local/bin" /usr/lib/go/bin /usr/bin /snap/bin)
  for d in "${dirs[@]}"; do
    g=$d/go
    [[ -n $d && -f $g && -x $g && $gos != *$'\n'"$g"$'\n'* ]] || continue
    gos+=$g$'\n' found=1
    for root in "$(realpath -e -- "$g" 2>/dev/null)" \
      "$(cd / && GOTOOLCHAIN=local GOFLAGS='' timeout 10 "$g" env GOROOT 2>/dev/null)"; do
      [[ -n $root ]] || return 1 # a go that can't tell where it runs from
      root=$(realpath -e -- "$root" 2>/dev/null) || continue
      [[ $root == "$sdk"/* ]] && { root=${root#"$sdk"/}; kept+=${root%%/*}$'\n'; }
    done
  done
  [[ $found == 1 || -n ${kept//$'\n'/} ]] || return 1
  printf '%s' "$kept"
}

runtime_versions() { # → KIND\tLABEL\tFOLDER for every version of nvm, SDKMAN, fvm, pyenv, rbenv, rustup and ~/sdk that isn't kept
  local d f c v t n keep node
  # nvm: keep the default, the node on PATH and what any of your own aliases names
  d=$(runtime_dir "$(env_home_dir NVM_DIR)") || d=""
  [[ -n $d ]] || d=$(runtime_dir "$HOME/.nvm")
  if [[ -n $d && -d $d/versions/node && ! -L $d/versions/node ]] && [[ -f $d/alias/default ]] &&
    keep=$(nvm_version "$d" "$(head -c 200 -- "$d/alias/default" 2>/dev/null)"); then
    keep=$'\n'$keep$'\n'
    node=$(command -v node 2>/dev/null) && node=$(realpath -e -- "$node" 2>/dev/null) &&
      [[ $node == "$d"/versions/node/v*/* ]] && { node=${node#"$d"/versions/node/}; keep+=${node%%/*}$'\n'; }
    for f in "$d"/alias/*; do
      [[ -f $f && ! -L $f && ${f##*/} != default ]] || continue
      v=$(nvm_version "$d" "${f##*/}") && keep+=$v$'\n'
    done
    for f in "$d"/versions/node/v*/; do
      f=${f%/} v=${f##*/}
      [[ -d $f && ! -L $f && $keep != *$'\n'"$v"$'\n'* ]] && printf 'node\tNode %s\t%s\n' "$v" "$f"
    done
  fi
  # SDKMAN: keep each candidate's current; a candidate without one keeps everything
  d=$(runtime_dir "$(env_home_dir SDKMAN_DIR)") || d=""
  [[ -n $d ]] || d=$(runtime_dir "$HOME/.sdkman")
  if [[ -n $d && -d $d/candidates && ! -L $d/candidates ]]; then
    for c in "$d"/candidates/*/; do
      c=${c%/}
      [[ -d $c && ! -L $c && -L $c/current ]] || continue
      t=$(readlink -- "$c/current") || continue
      t=${t%/} t=${t##*/}
      [[ -n $t && -d $c/$t ]] || continue
      for f in "$c"/*/; do
        f=${f%/} v=${f##*/}
        [[ -d $f && ! -L $f && $v != current && $v != "$t" ]] && printf 'sdkman\t%s %s\t%s\n' "${c##*/}" "$v" "$f"
      done
    done
  fi
  # fvm: keep the global default; none set keeps everything
  for d in "$HOME/fvm" "$(env_home_dir FVM_CACHE_PATH)"; do
    d=$(runtime_dir "$d") || continue
    [[ -d $d/versions && ! -L $d/versions && -L $d/default ]] || continue
    t=$(readlink -- "$d/default") || continue
    t=${t%/} t=${t##*/}
    [[ -n $t ]] || continue
    for f in "$d"/versions/*/; do
      f=${f%/} v=${f##*/}
      [[ -d $f && ! -L $f && $v != "$t" ]] && printf 'fvm\tFlutter %s\t%s\n' "$v" "$f"
    done
  done | awk -F '\t' '!seen[$3]++'
  # pyenv and rbenv: keep what the root's version file names (pyenv: every line) and a version the PATH runs
  # from; pyenv also keeps a version holding virtualenvs (envs/). Links in versions/ are envs: never listed.
  for t in pyenv rbenv; do
    if [[ $t == pyenv ]]; then c=PYENV_ROOT v=Python; else c=RBENV_ROOT v=Ruby; fi
    d=$(runtime_dir "$(env_home_dir "$c")") || d=""
    [[ -n $d ]] || d=$(runtime_dir "$HOME/.$t")
    [[ -n $d && -d $d/versions && ! -L $d/versions ]] || continue
    if [[ $t == pyenv ]]; then keep=$(named_versions "$d/versions" "$d/version" python- 0) || continue
    else keep=$(named_versions "$d/versions" "$d/version" ruby- 1) || continue
    fi
    keep=$'\n'$keep$'\n'$(path_versions "$d/versions")$'\n'
    for f in "$d"/versions/*/; do
      f=${f%/} n=${f##*/}
      [[ -d $f && ! -L $f && $keep != *$'\n'"$n"$'\n'* ]] || continue
      [[ $t == pyenv && -d $f/envs ]] && find "$f/envs" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit 2>/dev/null | grep -q . && continue
      printf '%s\t%s %s\t%s\n' "$t" "$v" "$n" "$f"
    done
  done
  # rustup: keep the default toolchain and every override in settings.toml, and one the PATH runs from
  d=$(runtime_dir "$(env_home_dir RUSTUP_HOME)") || d=""
  [[ -n $d ]] || d=$(runtime_dir "$HOME/.rustup")
  if [[ -n $d && -d $d/toolchains && ! -L $d/toolchains ]] && keep=$(rust_kept "$d/settings.toml"); then
    keep=$'\n'$keep$'\n'$(path_versions "$d/toolchains")$'\n'
    for f in "$d"/toolchains/*/; do
      f=${f%/} v=${f##*/}
      [[ -d $f && ! -L $f ]] && ! rust_keeps "$keep" "$v" && printf 'rustup\tRust %s\t%s\n' "$v" "$f"
    done
  fi
  # Go SDKs golang.org/dl downloaded to ~/sdk: keep the ones in use (go_kept)
  d=$(runtime_dir "$HOME/sdk") || d=""
  if [[ -n $d ]] && compgen -G "$d/go*" >/dev/null && keep=$(go_kept "$d"); then
    keep=$'\n'$keep$'\n'
    for f in "$d"/go*/; do
      f=${f%/} v=${f##*/}
      [[ -d $f && ! -L $f && $v =~ $GO_VERSION_RE && $keep != *$'\n'"$v"$'\n'* ]] && printf 'go\tGo %s\t%s\n' "${v#go}" "$f"
    done
  fi
  return 0
}

old_runtimes() { # → OR_DIR / OR_BYTES / OR_LABEL of versions to offer, biggest first; OR_BUSY = labels of running ones
  local kind label d b used lines=()
  OR_DIR=() OR_BYTES=() OR_LABEL=() OR_BUSY=()
  used=$'\n'$(find /proc/[0-9]*/exe -maxdepth 0 -printf '%l\n' 2>/dev/null)$'\n'$(open_files)$'\n'
  while IFS=$'\t' read -r kind label d; do
    [[ -n $d && $d != *[[:cntrl:]]* && $label != *[[:cntrl:]]* ]] || continue
    touches_exclusion "$d" && continue
    if open_under "$used" "$d"; then OR_BUSY+=("$label"); continue; fi
    b=$(du -sbx -- "$d" 2>/dev/null | cut -f1)
    lines+=("${b:-0}"$'\t'"$d"$'\t'"$label")
  done < <(runtime_versions)
  ((${#lines[@]})) || return 0
  while IFS=$'\t' read -r b d label; do
    OR_BYTES+=("$b") OR_DIR+=("$d") OR_LABEL+=("$label")
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr)
}

runtimes_found() { # nvm, SDKMAN, fvm, pyenv, rbenv, rustup or a Go SDK in ~/sdk is there
  local d
  for d in "$(env_home_dir NVM_DIR)" "$HOME/.nvm" "$(env_home_dir SDKMAN_DIR)" "$HOME/.sdkman" "$HOME/fvm" \
    "$(env_home_dir FVM_CACHE_PATH)" "$(env_home_dir PYENV_ROOT)" "$HOME/.pyenv" "$(env_home_dir RBENV_ROOT)" \
    "$HOME/.rbenv" "$(env_home_dir RUSTUP_HOME)" "$HOME/.rustup"; do
    [[ -n $d && -d $d ]] && return 0
  done
  compgen -G "$HOME/sdk/go*" >/dev/null
}

delete_runtimes() { # INDEX… of OR_DIR
  local i d rc=0
  for i; do
    d=${OR_DIR[i]}
    is_protected "$d" && { err "Refusing to touch protected path: $d"; rc=1; continue; }
    run rm -rf -- "$d" || rc=1
  done
  return "$rc"
}

scan_old_runtimes() {
  local b busy=""
  runtimes_found || return 1
  old_runtimes
  ((${#OR_BUSY[@]})) && busy="skipped while running: $(printf '%s, ' "${OR_BUSY[@]}")" busy=${busy%, }
  if ((${#OR_DIR[@]} == 0)); then
    SCAN_NOTE=$busy
    return 2
  fi
  SCAN_BYTES=0
  for b in "${OR_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#OR_DIR[@]} version) not your default${busy:+; $busy}"
}
clean_old_runtimes() {
  old_runtimes
  ((${#OR_DIR[@]})) || return 0
  delete_runtimes "${!OR_DIR[@]}"
}
details_old_runtimes() {
  local i
  old_runtimes
  for i in "${!OR_DIR[@]}"; do
    printf '  %s%10s%s  %s  %s\n' "$(size_color "${OR_BYTES[i]}")" "$(human "${OR_BYTES[i]}")" "$NC" "${OR_LABEL[i]}" "${OR_DIR[i]/#$HOME/\~}"
  done
  for i in "${OR_BUSY[@]}"; do printf '  %s%10s  %s  (running, skipped)%s\n' "$DIM" "" "$i" "$NC"; done
}
entries_old_runtimes() {
  local i
  old_runtimes
  for i in "${!OR_DIR[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${OR_DIR[i]}")" "${OR_BYTES[i]}" "${OR_LABEL[i]}"
  done
}
clean_entries_old_runtimes() { # encoded version folders (json_clean_entries only passes ones listed now)
  local i id pick=()
  old_runtimes
  for id; do
    for i in "${!OR_DIR[@]}"; do [[ $(urlencode_path "${OR_DIR[i]}") == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  delete_runtimes "${pick[@]}"
}

# Android emulator system images no virtual device (AVD) uses: 1–8 GB each, and they stay when
# the AVD is deleted. SDKs: ~/Android/Sdk, ANDROID_HOME and ANDROID_SDK_ROOT (inside your home, no
# symlinks on the way). An image is system-images/<android-N>/<tag>/<abi> with a source.properties
# or package.xml; an AVD uses the one its config.ini's image.sysdir.N names. AVDs are read from
# ~/.android/avd, ANDROID_AVD_HOME, ANDROID_USER_HOME/avd, ANDROID_EMULATOR_HOME/avd and ANDROID_SDK_HOME/.android/avd, both
# the <name>.avd folders and the <name>.ini files pointing elsewhere (path=). An AVD that can't be
# read keeps every image. Deleted for good (the SDK Manager downloads one again); platforms,
# build-tools, ndk, emulator and the AVDs are never touched. Locked while Android Studio, the
# emulator, sdkmanager or avdmanager runs. Not ticked; the desktop app lists each image.
reg android_images dev "Android system images (unused)" 0 "Android emulator system images no virtual device (AVD) uses, often several GB each. Deleted; download one again with Android Studio's SDK Manager. Close Android Studio and the emulator first."
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_android_images='^/[A-Za-z0-9/._~%-]+$' # the image folder's full path, percent-encoded (urlencode_path)
declare -A AU_USED=() # <android-N>/<tag>/<abi> of the images AVDs use

android_sdk_roots() { # SDK folders inside your home, no symlinks on the way
  local d
  { printf '%s\n' "$HOME/Android/Sdk"; env_home_dir ANDROID_HOME; env_home_dir ANDROID_SDK_ROOT; } | awk '!seen[$0]++' |
    while IFS= read -r d; do
      [[ $d == "$HOME"/* && -d $d && ! -L $d && $(realpath -e -- "$d" 2>/dev/null) == "$d" ]] && printf '%s\n' "$d"
    done
  return 0
}

avd_homes() { # folders AVDs are kept in; fails when a variable names one that can't be read as a plain path
  local n v
  printf '%s\n' "$HOME/.android/avd"
  for n in ANDROID_AVD_HOME ANDROID_USER_HOME ANDROID_EMULATOR_HOME ANDROID_SDK_HOME; do
    v=$(env_value "$n")
    [[ -n $v ]] || continue
    [[ $v == /* && $v != *[\$\`[:cntrl:]]* ]] || return 1
    v=${v%/}
    case $n in ANDROID_USER_HOME | ANDROID_EMULATOR_HOME) v+=/avd ;; ANDROID_SDK_HOME) v+=/.android/avd ;; esac
    printf '%s\n' "$v"
  done
}

ini_lines() { # FILE → its lines without CR; fails when it isn't a readable, small regular file
  [[ -f $1 && -r $1 ]] && (($(stat -c %s -- "$1" 2>/dev/null || echo 1048577) <= 1048576)) || return 1
  tr -d '\r' <"$1" 2>/dev/null
}

avd_uses() { # AVD_FOLDER → AU_USED[<android-N>/<tag>/<abi>]=1 for its images; fails when its config.ini can't be read
  local lines line v got=0
  lines=$(ini_lines "$1/config.ini") || return 1
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*image\.sysdir\.[0-9]+[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue
    v=${BASH_REMATCH[1]//\\//}
    v=${v%/}
    [[ $v == system-images/* || $v == */system-images/* ]] || return 1 # an image somewhere we don't look
    AU_USED[${v##*system-images/}]=1 got=1
  done <<<"$lines"
  ((got))
}

android_used_images() { # → AU_USED for every AVD; fails when one of them can't be read
  local homes h f d lines line p
  local -A seen=()
  AU_USED=()
  homes=$(avd_homes) || return 1
  while IFS= read -r h; do
    [[ -e $h || -L $h ]] || continue
    [[ -d $h && -r $h && -x $h ]] || return 1
    for d in "$h"/*.avd; do
      [[ -e $d ]] || continue
      seen[$d]=1
      avd_uses "$d" || return 1
    done
    for f in "$h"/*.ini; do
      [[ -e $f ]] || continue
      lines=$(ini_lines "$f") || return 1
      p=""
      while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*path\.rel[[:space:]]*=[[:space:]]*(.*[^[:space:]]) && -z $p ]] && p=${h%/*}/${BASH_REMATCH[1]}
        [[ $line =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*[^[:space:]]) ]] && p=${BASH_REMATCH[1]}
      done <<<"$lines"
      p=${p%/}
      [[ -n $p && -z ${seen[$p]:-} ]] || continue
      seen[$p]=1
      if [[ -d $p ]]; then avd_uses "$p" || return 1
      elif ! path_gone "$p"; then return 1; fi # on a drive that isn't plugged in, or can't be checked
    done
  done <<<"$homes"
}

android_images() { # → AI_DIR / AI_BYTES / AI_LABEL of images no AVD uses, biggest first; none when an AVD can't be read
  local root d rel api tag abi b lines=()
  AI_DIR=() AI_BYTES=() AI_LABEL=()
  android_used_images || return 0
  while IFS= read -r root; do
    [[ -d $root/system-images && ! -L $root/system-images ]] || continue
    for d in "$root"/system-images/*/*/*/; do
      d=${d%/} rel=${d#"$root"/system-images/}
      IFS=/ read -r api tag abi <<<"$rel"
      [[ ! -L $root/system-images/$api && ! -L $root/system-images/$api/$tag && ! -L $d && -d $d ]] || continue
      [[ -f $d/source.properties || -f $d/package.xml ]] || continue
      [[ -z ${AU_USED[$rel]:-} && $d != *[[:cntrl:]]* ]] || continue
      touches_exclusion "$d" && continue
      b=$(du -sbx -- "$d" 2>/dev/null | cut -f1)
      lines+=("${b:-0}"$'\t'"$d"$'\t'"Android ${api#android-} · $tag · $abi")
    done
  done < <(android_sdk_roots)
  ((${#lines[@]})) || return 0
  while IFS=$'\t' read -r b d rel; do
    AI_BYTES+=("$b") AI_DIR+=("$d") AI_LABEL+=("$rel")
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr)
}

lockedby_android_images() { # Android Studio, the emulator, sdkmanager or avdmanager
  running_proc -x 'studio|android-studio|studio\.sh|emulator|emulator64-.*|qemu-system-.*|sdkmanager|avdmanager' && return
  # started by studio.sh, sdkmanager and avdmanager they run as java
  if running_proc -f 'idea\.platform\.prefix=AndroidStudio' >/dev/null; then echo "Android Studio"
  elif running_proc -f 'com\.android\.sdklib\.tool\.(sdkmanager\.SdkManagerCli|AvdManagerCli)' >/dev/null; then echo "sdkmanager"
  else return 1; fi
}
precheck_android_images() { # deleting an image the SDK Manager or the emulator works on would break it
  local p
  p=$(lockedby_android_images) || return 0
  warn "Skipping ${ITEM_LABEL[android_images]}: close $p first."
  return 1
}

delete_android_images() { # INDEX… of AI_DIR
  local i d rc=0
  for i; do
    d=${AI_DIR[i]}
    is_protected "$d" && { err "Refusing to touch protected path: $d"; rc=1; continue; }
    run rm -rf -- "$d" || { rc=1; continue; }
    ((DRY_RUN)) || rmdir -- "${d%/*}" "${d%/*/*}" 2>/dev/null # <tag> and <android-N> once empty
  done
  return "$rc"
}

scan_android_images() {
  local b
  android_images
  ((${#AI_DIR[@]})) || return 2
  SCAN_BYTES=0
  for b in "${AI_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#AI_DIR[@]} image) no AVD uses"
}
clean_android_images() {
  android_images
  ((${#AI_DIR[@]})) || return 0
  delete_android_images "${!AI_DIR[@]}"
}
details_android_images() {
  local i
  android_images
  for i in "${!AI_DIR[@]}"; do
    printf '  %s%10s%s  %s  %s\n' "$(size_color "${AI_BYTES[i]}")" "$(human "${AI_BYTES[i]}")" "$NC" "${AI_LABEL[i]}" "${AI_DIR[i]/#$HOME/\~}"
  done
}
entries_android_images() {
  local i
  android_images
  for i in "${!AI_DIR[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${AI_DIR[i]}")" "${AI_BYTES[i]}" "${AI_LABEL[i]}"
  done
}
clean_entries_android_images() { # encoded image folders (json_clean_entries only passes ones listed now)
  local i id pick=()
  android_images
  for id; do
    for i in "${!AI_DIR[@]}"; do [[ $(urlencode_path "${AI_DIR[i]}") == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  delete_android_images "${pick[@]}"
}

# Snapshots of Android emulator virtual devices (AVDs): <name>.avd/snapshots, often GBs per AVD.
# The emulator makes a new one (the next start is a cold boot). Only that folder: the AVD's disks
# (userdata*.img, sdcard.img), config and .ini files stay. AVDs as android_images finds them, only
# inside your home, no symlinks. Locked while the emulator runs. Not ticked; one entry per AVD.
reg android_avd_snapshots dev "Android emulator snapshots" 0 "Saved states (quick-boot snapshots) of your Android emulator virtual devices, often several GB each. Deleted; the next start is a cold boot and the emulator saves a new one. Apps and data on the device are kept. Close the emulator first."
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_android_avd_snapshots='^/[A-Za-z0-9/._~%-]+$' # the snapshots folder's full path, percent-encoded

avd_dirs() { # every AVD folder: <name>.avd in the AVD homes, and where their .ini files point
  local homes h d f line p
  homes=$(avd_homes) || homes=$HOME/.android/avd
  while IFS= read -r h; do
    [[ -d $h && ! -L $h ]] || continue
    for d in "$h"/*.avd; do [[ -d $d ]] && printf '%s\n' "$d"; done
    for f in "$h"/*.ini; do
      p=""
      while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*[^[:space:]]) ]] && p=${BASH_REMATCH[1]%/}
      done < <(ini_lines "$f")
      [[ -n $p && -d $p ]] && printf '%s\n' "$p"
    done
  done <<<"$homes" | awk '!seen[$0]++'
}
avd_snapshots() { # → AS_DIR / AS_BYTES / AS_LABEL of snapshots folders, biggest first
  local d s b lines=()
  AS_DIR=() AS_BYTES=() AS_LABEL=()
  while IFS= read -r d; do
    s=$d/snapshots
    [[ $d == "$HOME"/* && $d != *[[:cntrl:]]* && ! -L $d && -d $s && ! -L $s ]] || continue
    [[ $(realpath -e -- "$s" 2>/dev/null) == "$s" ]] || continue
    touches_exclusion "$s" && continue
    [[ -n $(find "$s" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] || continue
    b=$(du -sbx -- "$s" 2>/dev/null | cut -f1)
    d=${d##*/}
    lines+=("${b:-0}"$'\t'"$s"$'\t'"${d%.avd}")
  done < <(avd_dirs)
  ((${#lines[@]})) || return 0
  while IFS=$'\t' read -r b s d; do
    AS_BYTES+=("$b") AS_DIR+=("$s") AS_LABEL+=("$d")
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr)
}
lockedby_android_avd_snapshots() { running_proc -x 'emulator|emulator64-.*|qemu-system-.*'; }
precheck_android_avd_snapshots() {
  local p
  p=$(lockedby_android_avd_snapshots) || return 0
  warn "Skipping ${ITEM_LABEL[android_avd_snapshots]}: close $p first."
  return 1
}
delete_avd_snapshots() { # INDEX… of AS_DIR
  local i rc=0
  for i; do
    is_protected "${AS_DIR[i]}" && { err "Refusing to touch protected path: ${AS_DIR[i]}"; rc=1; continue; }
    run rm -rf -- "${AS_DIR[i]}" || rc=1
  done
  return "$rc"
}
scan_android_avd_snapshots() {
  local b
  avd_snapshots
  ((${#AS_DIR[@]})) || return 2
  SCAN_BYTES=0
  for b in "${AS_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#AS_DIR[@]} AVD)"
}
clean_android_avd_snapshots() {
  avd_snapshots
  ((${#AS_DIR[@]})) || return 0
  delete_avd_snapshots "${!AS_DIR[@]}"
}
details_android_avd_snapshots() {
  local i
  avd_snapshots
  for i in "${!AS_DIR[@]}"; do
    printf '  %s%10s%s  %s  %s\n' "$(size_color "${AS_BYTES[i]}")" "$(human "${AS_BYTES[i]}")" "$NC" "${AS_LABEL[i]}" "${AS_DIR[i]/#$HOME/\~}"
  done
}
entries_android_avd_snapshots() {
  local i
  avd_snapshots
  for i in "${!AS_DIR[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${AS_DIR[i]}")" "${AS_BYTES[i]}" "${AS_LABEL[i]}"
  done
}
clean_entries_android_avd_snapshots() {
  local i id pick=()
  avd_snapshots
  for id; do
    for i in "${!AS_DIR[@]}"; do [[ $(urlencode_path "${AS_DIR[i]}") == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  delete_avd_snapshots "${pick[@]}"
}

# Old JetBrains IDE and Android Studio versions. Each version keeps its settings, plugins, caches,
# indexes and logs in <vendor>/<Product><year>.<n> under ~/.config, ~/.local/share and ~/.cache
# (JetBrains/IntelliJIdea2023.1, Google/AndroidStudio2023.3), also inside Flatpak
# (~/.var/app/<id>/{config,data,cache}) and Snap (~/snap/<name>/<revision>/{.config,.local/share},
# ~/snap/<name>/common/.cache) sandboxes; an upgrade copies the settings to the new version's
# folders and leaves the old ones. A version is listed when a newer version of the same product is
# found in the same place (the three folders together), its folders as one entry. Never the newest,
# nor a name without a <year>.<n> version (consentOptions, IntelliJServer, Daemon, Toolbox); in
# Google only AndroidStudio… counts. Skipped while that IDE runs (its launcher by name, or java with
# idea.paths.selector=<Product>) or a program has a file open in it, and the scan says which. Moved
# to the Trash (z puts it back). Not ticked; automatic cleaning leaves them alone. User caches
# leaves ~/.cache/JetBrains and ~/.cache/Google/AndroidStudio… to this item.
reg jetbrains_old_versions dev "Old IDE versions" 0 "Settings, plugins, caches and logs of JetBrains IDE (IntelliJ IDEA, PyCharm, WebStorm…) and Android Studio versions that a newer version of the same IDE replaced. Moved to the Trash; skipped while that IDE runs."
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_jetbrains_old_versions='^/[A-Za-z0-9/._~%-]+$' # the version's first folder, full path percent-encoded

IDE_VERSION_RE='^([A-Za-z]+)([0-9]{4}(\.[0-9]+)+)$' # PyCharm2024.2, AndroidStudio2023.3.1
declare -A IDE_NAMES=([IntelliJIdea]="IntelliJ IDEA" [IdeaIC]="IntelliJ IDEA Community" [PyCharmCE]="PyCharm Community"
  [PyCharmEdu]="PyCharm Edu" [AndroidStudio]="Android Studio" [AndroidStudioPreview]="Android Studio Preview"
  [JetBrainsGateway]="Gateway" [JetBrainsClient]="JetBrains Client")
declare -A IDE_PROCS=([IntelliJIdea]=idea [IdeaIC]=idea [PyCharmCE]=pycharm [PyCharmEdu]=pycharm
  [AndroidStudio]='studio|android-studio' [AndroidStudioPreview]='studio|android-studio'
  [JetBrainsGateway]=gateway [JetBrainsClient]=jetbrains_client) # others: the product's name in lower case

ide_roots() { # → lines "where<TAB>config<TAB>data<TAB>cache" (where: - for your own folders, Flatpak, Snap)
  local a r
  printf -- '-\t%s\t%s\t%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "${XDG_DATA_HOME:-$HOME/.local/share}" "${XDG_CACHE_HOME:-$HOME/.cache}"
  for a in "$HOME"/.var/app/*/; do
    [[ -d $a && ! -L ${a%/} ]] && printf 'Flatpak\t%s\t%s\t%s\n' "${a}config" "${a}data" "${a}cache"
  done
  for a in "$HOME"/snap/*/; do
    r=$(readlink -- "${a}current" 2>/dev/null) || continue # current → the revision folder
    [[ $r =~ ^x?[0-9]+$ && ! -L ${a%/} ]] && printf 'Snap\t%s\t%s\t%s\n' "$a$r/.config" "$a$r/.local/share" "${a}common/.cache"
  done
  return 0
}

ide_running() { # PRODUCT → the running program of that IDE (its launcher, or java started by <ide>.sh); fails when none
  running_proc -x "(${IDE_PROCS[$1]:-${1,,}})(\.sh)?" && return
  running_proc -f "idea\.paths\.selector=$1[0-9]" >/dev/null && printf '%s\n' "${IDE_NAMES[$1]:-$1}"
}

version_newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; } # A B → A is newer

ide_old_versions() { # → IV_ID / IV_DIRS (newline-separated) / IV_BYTES / IV_LABEL to offer, biggest first; IV_BUSY, IV_FOUND
  local where conf data cache vendor root vd d name prod ver key pk i=0 n b used lines=() all=()
  local -A vdirs=() kprod=() kver=() kwhere=() newest=() prodrun=()
  IV_ID=() IV_DIRS=() IV_BYTES=() IV_LABEL=() IV_BUSY=() IV_FOUND=0
  while IFS=$'\t' read -r where conf data cache; do
    i=$((i + 1))
    for vendor in JetBrains Google; do
      for root in "$conf" "$data" "$cache"; do
        vd=$(runtime_dir "$root/$vendor") || continue
        [[ $vendor == Google ]] && ! compgen -G "$vd/AndroidStudio*" >/dev/null && continue
        IV_FOUND=1
        for d in "$vd"/*/; do
          d=${d%/} name=${d##*/}
          [[ -d $d && ! -L $d && $d != *[[:cntrl:]]* && $name =~ $IDE_VERSION_RE ]] || continue
          prod=${BASH_REMATCH[1]} ver=${BASH_REMATCH[2]}
          [[ $vendor == JetBrains || $prod == AndroidStudio* ]] || continue
          key=$i/$vendor/$name pk=$i/$vendor/$prod
          vdirs[$key]+=$d$'\n' kprod[$key]=$prod kver[$key]=$ver kwhere[$key]=$where
          [[ -z ${newest[$pk]:-} ]] || version_newer "$ver" "${newest[$pk]}" && newest[$pk]=$ver
        done
      done
    done
  done < <(ide_roots)
  ((${#vdirs[@]})) || return 0
  used=$'\n'$(open_files)$'\n'
  for key in "${!vdirs[@]}"; do
    prod=${kprod[$key]} ver=${kver[$key]}
    [[ $ver != "${newest[${key%/*}/$prod]}" ]] || continue
    name="${IDE_NAMES[$prod]:-$prod} $ver"
    [[ ${kwhere[$key]} == - ]] || name+=" · ${kwhere[$key]}"
    n=0
    while IFS= read -r d; do touches_exclusion "$d" && n=1; done <<<"${vdirs[$key]%$'\n'}"
    ((n)) && continue
    [[ -n ${prodrun[$prod]:-} ]] || { ide_running "$prod" >/dev/null && prodrun[$prod]=1 || prodrun[$prod]=0; }
    n=${prodrun[$prod]}
    while IFS= read -r d; do open_under "$used" "$d" && n=1; done <<<"${vdirs[$key]%$'\n'}"
    if ((n)); then IV_BUSY+=("$name"); continue; fi
    mapfile -t all <<<"${vdirs[$key]%$'\n'}"
    b=$(du -sbcx -- "${all[@]}" 2>/dev/null | tail -n1 | cut -f1)
    lines+=("${b:-0}"$'\t'"$key"$'\t'"$name")
  done
  ((${#IV_BUSY[@]})) && mapfile -t IV_BUSY < <(printf '%s\n' "${IV_BUSY[@]}" | LC_ALL=C sort)
  ((${#lines[@]})) || return 0
  while IFS=$'\t' read -r b key name; do
    d=${vdirs[$key]%$'\n'}
    IV_BYTES+=("$b") IV_DIRS+=("$d") IV_LABEL+=("$name") IV_ID+=("$(urlencode_path "${d%%$'\n'*}")")
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr -k3,3)
}

trash_ide_versions() { # INDEX… of IV_ID — move their folders to the Trash; @@undo lines let the terminal app undo it
  local i d rc=0
  UNDO_BATCH=()
  for i; do
    while IFS= read -r d; do move_to_trash "$d" || rc=1; done <<<"${IV_DIRS[i]}"
  done
  for d in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$d"; done
  return "$rc"
}

scan_jetbrains_old_versions() {
  local b busy=""
  ide_old_versions
  ((IV_FOUND)) || return 1
  ((${#IV_BUSY[@]})) && busy="skipped while running: $(printf '%s, ' "${IV_BUSY[@]}")" busy=${busy%, }
  if ((${#IV_ID[@]} == 0)); then
    SCAN_NOTE=$busy
    return 2
  fi
  SCAN_BYTES=0
  for b in "${IV_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural ${#IV_ID[@]} version) replaced by a newer one${busy:+; $busy}"
}
clean_jetbrains_old_versions() {
  ide_old_versions
  ((${#IV_ID[@]})) || return 0
  trash_ide_versions "${!IV_ID[@]}"
}
details_jetbrains_old_versions() {
  local i d
  ide_old_versions
  for i in "${!IV_ID[@]}"; do
    d=${IV_DIRS[i]/#$HOME/\~} d=${d//$'\n'"$HOME"/  \~}
    printf '  %s%10s%s  %s  %s\n' "$(size_color "${IV_BYTES[i]}")" "$(human "${IV_BYTES[i]}")" "$NC" "${IV_LABEL[i]}" "$d"
  done
  for i in "${IV_BUSY[@]}"; do printf '  %s%10s  %s  (running, skipped)%s\n' "$DIM" "" "$i" "$NC"; done
}
entries_jetbrains_old_versions() {
  local i
  ide_old_versions
  for i in "${!IV_ID[@]}"; do printf '%s\t%s\t0\t%s\n' "${IV_ID[i]}" "${IV_BYTES[i]}" "${IV_LABEL[i]}"; done
}
clean_entries_jetbrains_old_versions() { # encoded first folders (json_clean_entries only passes ones listed now)
  local i id pick=()
  ide_old_versions
  for id; do
    for i in "${!IV_ID[@]}"; do [[ ${IV_ID[i]} == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  trash_ide_versions "${pick[@]}"
}

# Old versions of VS Code extensions (also Insiders, VSCodium, Cursor, Windsurf and the Flatpak
# builds). An update installs the new version next to the old one in <editor>/extensions, named
# <publisher>.<name>-<x.y.z>[-<platform>], and the old folder often stays: 100–500 MB a version for
# the large ones (Pylance, C/C++, Copilot). Old = a higher version of the same extension (any case)
# is there and not marked obsolete, or the editor marked it obsolete in .obsolete. A version
# extensions.json names is never old; when .obsolete or extensions.json can't be read, that editor is
# left alone. One entry per extension and editor (its old versions together, found again right
# before deleting); deleted for good (the editor installs any version again); skipped while that
# editor runs, a version with a file open is skipped. Never extensions.json, .obsolete, the newest
# version, symlinks or folders named otherwise. Not ticked; automatic cleaning leaves them alone.
reg vscode_old_extensions dev "Old editor extension versions" 0 "Versions of VS Code, Cursor, Windsurf and VSCodium extensions that an update left behind, often 100–500 MB each. The version in use is kept. Deleted; the editor downloads any version again. Skipped while that editor runs."
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_vscode_old_extensions='^/[A-Za-z0-9/._~%-]+$' # the highest old version's folder, full path percent-encoded

EDITOR_EXT_PLATFORMS='darwin-x64|darwin-arm64|linux-x64|linux-arm64|linux-armhf|alpine-x64|alpine-arm64|win32-x64|win32-arm64|win32-ia32|web|universal'
EDITOR_EXT_RE="^([A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*)-([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})(-($EDITOR_EXT_PLATFORMS))?$"
EDITOR_EXT_JSON_MAX=$((8 << 20)) # largest .obsolete or extensions.json read (a few KB in practice)

editor_extension_roots() { # → lines "editor<TAB>process names (ERE)<TAB>extensions folder"
  printf '%s\t%s\t%s\n' \
    "VS Code" code "$HOME/.vscode/extensions" \
    "VS Code Insiders" code-insiders "$HOME/.vscode-insiders/extensions" \
    "VSCodium" 'codium|vscodium|code-oss' "$HOME/.vscode-oss/extensions" \
    "Cursor" cursor "$HOME/.cursor/extensions" \
    "Windsurf" windsurf "$HOME/.windsurf/extensions" \
    "VS Code · Flatpak" code "$HOME/.var/app/com.visualstudio.code/data/vscode/extensions" \
    "VS Code Insiders · Flatpak" code-insiders "$HOME/.var/app/com.visualstudio.code.insiders/data/vscode/extensions" \
    "VSCodium · Flatpak" 'codium|vscodium' "$HOME/.var/app/com.vscodium.codium/data/codium/extensions"
}

editor_ext_names() { # o|i FILE → folder names .obsolete marks true (o) or extensions.json names (i); fails when FILE can't be read
  local kind=$1 f=$2 s
  [[ -e $f || -L $f ]] || return 0
  [[ -f $f && ! -L $f ]] || return 1
  s=$(stat -c %s -- "$f" 2>/dev/null) && ((s <= EDITOR_EXT_JSON_MAX)) || return 1
  if have jq; then
    if [[ $kind == o ]]; then
      jq -r 'if type == "object" then to_entries[] | select(.value == true) | .key else empty end
        | select(test("^[A-Za-z0-9.-]+$"))' -- "$f" 2>/dev/null
    else
      jq -r 'if type == "array" then .[] | objects
          | (.relativeLocation | strings), (.location | strings), (.location | objects | (.path, .fsPath) | strings)
        else empty end
        | sub("/+$"; "") | split("/") | last | select(type == "string" and test("^[A-Za-z0-9.-]+$"))' -- "$f" 2>/dev/null
    fi
  elif have python3; then
    python3 -I -c 'import json, os, re, sys
d = json.load(open(sys.argv[2], encoding="utf-8"))
names = []
if sys.argv[1] == "o":
    names = [k for k, v in d.items() if v is True] if isinstance(d, dict) else []
else:
    for e in d if isinstance(d, list) else []:
        if not isinstance(e, dict):
            continue
        loc = e.get("location")
        for p in (e.get("relativeLocation"), loc) + ((loc.get("path"), loc.get("fsPath")) if isinstance(loc, dict) else ()):
            if isinstance(p, str):
                names.append(os.path.basename(p.rstrip("/")))
for n in names:
    if re.fullmatch(r"[A-Za-z0-9.-]+", n):
        print(n)' "$kind" "$f" 2>/dev/null
  else
    return 1
  fi
}

editor_old_extensions() { # → EX_ID / EX_DIRS (newline-separated) / EX_BYTES / EX_LABEL to offer, biggest first; EX_COUNT (old versions), EX_BUSY, EX_FOUND
  local editor procs root d name key ver n b open="" lines=() dirs=() old=()
  local -A vid=() vkey=() vver=() newest=() obsolete=() installed=() kdirs=() kname=() kbest=() kbestv=() kn=() size=() running=()
  EX_ID=() EX_DIRS=() EX_BYTES=() EX_LABEL=() EX_BUSY=() EX_COUNT=0 EX_FOUND=0
  while IFS=$'\t' read -r editor procs root; do
    runtime_dir "$root" >/dev/null || continue
    EX_FOUND=1
    vid=() vkey=() vver=() newest=() obsolete=() installed=() dirs=()
    for d in "$root"/*/; do
      d=${d%/} name=${d##*/}
      [[ -d $d && ! -L $d && $name =~ $EDITOR_EXT_RE ]] || continue
      printf -v ver '%09d%09d%09d' "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))" "$((10#${BASH_REMATCH[4]}))"
      dirs+=("$d") vid[$d]=${BASH_REMATCH[1]} vkey[$d]=${BASH_REMATCH[1],,} vver[$d]=$ver
    done
    ((${#dirs[@]})) || continue
    # what the editor says about its folders; unreadable → this editor is left alone
    n=$(editor_ext_names o "$root/.obsolete") || continue
    while IFS= read -r name; do [[ -n $name ]] && obsolete[${name,,}]=1; done <<<"$n"
    n=$(editor_ext_names i "$root/extensions.json") || continue
    while IFS= read -r name; do [[ -n $name ]] && installed[${name,,}]=1; done <<<"$n"
    for d in "${dirs[@]}"; do # the highest version of each extension not marked obsolete
      name=${d##*/} key=${vkey[$d]}
      [[ -z ${obsolete[${name,,}]:-} ]] || continue
      [[ -n ${newest[$key]:-} && ! ${vver[$d]} > ${newest[$key]} ]] || newest[$key]=${vver[$d]}
    done
    old=()
    for d in "${dirs[@]}"; do
      name=${d##*/} key=${vkey[$d]}
      [[ -z ${installed[${name,,}]:-} ]] || continue
      [[ -n ${obsolete[${name,,}]:-} || ( -n ${newest[$key]:-} && ${newest[$key]} > ${vver[$d]} ) ]] || continue
      old+=("$d")
    done
    ((${#old[@]})) || continue
    [[ -n ${running[$procs]:-} ]] || { running_proc -x "($procs)" >/dev/null && running[$procs]=1 || running[$procs]=0; }
    if [[ ${running[$procs]} == 1 ]]; then EX_BUSY+=("$editor"); continue; fi
    [[ -n $open ]] || open=$'\n'$(open_files)$'\n'
    for d in "${old[@]}"; do
      touches_exclusion "$d" && continue
      open_under "$open" "$d" && continue
      key=$root/${vkey[$d]}
      kdirs[$key]+=$d$'\n' kn[$key]=$((${kn[$key]:-0} + 1))
      if [[ -z ${kbest[$key]:-} || ${vver[$d]} > ${kbestv[$key]} || ( ${vver[$d]} == "${kbestv[$key]}" && $d > ${kbest[$key]} ) ]]; then
        kbest[$key]=$d kbestv[$key]=${vver[$d]} kname[$key]="${vid[$d]} · $editor"
      fi
    done
  done < <(editor_extension_roots)
  ((${#kdirs[@]})) || return 0
  while IFS=$'\t' read -r b d; do size[$d]=$b; done < <(printf '%s' "${kdirs[@]}" | tr '\n' '\0' | xargs -0 du -sbx -- 2>/dev/null)
  for key in "${!kdirs[@]}"; do
    b=0
    while IFS= read -r d; do b=$((b + ${size[$d]:-0})); done <<<"${kdirs[$key]%$'\n'}"
    lines+=("$b"$'\t'"$key"$'\t'"${kname[$key]}  ($(plural "${kn[$key]}" version))")
    EX_COUNT=$((EX_COUNT + ${kn[$key]}))
  done
  ((${#EX_BUSY[@]})) && mapfile -t EX_BUSY < <(printf '%s\n' "${EX_BUSY[@]}" | LC_ALL=C sort)
  while IFS=$'\t' read -r b key name; do
    EX_BYTES+=("$b") EX_DIRS+=("${kdirs[$key]%$'\n'}") EX_LABEL+=("$name") EX_ID+=("$(urlencode_path "${kbest[$key]}")")
  done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k3,3)
}

delete_editor_extensions() { # INDEX… of EX_ID — delete their old version folders, each checked again first
  local i d rc=0
  for i; do
    while IFS= read -r d; do
      [[ ${d##*/} =~ $EDITOR_EXT_RE && -d $d && ! -L $d ]] && runtime_dir "${d%/*}" >/dev/null || continue
      is_protected "$d" && { err "Refusing to touch protected path: $d"; rc=1; continue; }
      run rm -rf -- "$d" || rc=1
    done <<<"${EX_DIRS[i]}"
  done
  return "$rc"
}

scan_vscode_old_extensions() {
  local b busy=""
  editor_old_extensions
  ((EX_FOUND)) || return 1
  ((${#EX_BUSY[@]})) && busy="skipped while running: $(printf '%s, ' "${EX_BUSY[@]}")" busy=${busy%, }
  if ((${#EX_ID[@]} == 0)); then
    SCAN_NOTE=$busy
    return 2
  fi
  SCAN_BYTES=0
  for b in "${EX_BYTES[@]}"; do SCAN_BYTES=$((SCAN_BYTES + b)); done
  SCAN_NOTE="$(plural "$EX_COUNT" version) replaced by a newer one${busy:+; $busy}"
}
clean_vscode_old_extensions() {
  editor_old_extensions
  ((${#EX_ID[@]})) || return 0
  delete_editor_extensions "${!EX_ID[@]}"
}
details_vscode_old_extensions() {
  local i
  editor_old_extensions
  for i in "${!EX_ID[@]}"; do
    printf '  %s%10s%s  %s\n' "$(size_color "${EX_BYTES[i]}")" "$(human "${EX_BYTES[i]}")" "$NC" "${EX_LABEL[i]}"
  done
  for i in "${EX_BUSY[@]}"; do printf '  %s%10s  %s  (running, skipped)%s\n' "$DIM" "" "$i" "$NC"; done
}
entries_vscode_old_extensions() {
  local i
  editor_old_extensions
  for i in "${!EX_ID[@]}"; do printf '%s\t%s\t0\t%s\n' "${EX_ID[i]}" "${EX_BYTES[i]}" "${EX_LABEL[i]}"; done
}
clean_entries_vscode_old_extensions() { # encoded folders (json_clean_entries only passes ones listed now)
  local i id pick=()
  editor_old_extensions
  for id; do
    for i in "${!EX_ID[@]}"; do [[ ${EX_ID[i]} == "$id" ]] && pick+=("$i"); done
  done
  ((${#pick[@]})) || return 0
  delete_editor_extensions "${pick[@]}"
}

si_to_bytes() { local v=${1%B}; v=${v/k/K}; numfmt --from=si "$v" 2>/dev/null || echo 0; }
# Docker: one item per kind of leftover, sized from `docker system df`.
docker_ok() { have docker && timeout 5 docker info >/dev/null 2>&1; }
docker_reclaimable() { # TYPE (Images, Containers, Local Volumes, Build Cache) → bytes
  local t r
  while IFS=$'\t' read -r t r; do
    [[ $t == "$1" ]] && si_to_bytes "${r%% *}" && return
  done < <(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)
  echo 0
}
docker_scan() { # BYTES NOTE
  SCAN_BYTES=${1:-0} SCAN_NOTE=$2
  ((SCAN_BYTES > 0)) || return 2
}

scan_docker_dangling() {
  docker_ok || return 1
  local sizes n b=0 v
  mapfile -t sizes < <(docker images -f dangling=true --format '{{.Size}}' 2>/dev/null)
  for v in "${sizes[@]}"; do b=$((b + $(si_to_bytes "$v"))); done
  n=${#sizes[@]}
  docker_scan "$b" "$(plural "$n" image)"
}
clean_docker_dangling() { run docker image prune -f; }
details_docker_dangling() { docker images -f dangling=true --format '  {{.Size}}\t{{.ID}}  created {{.CreatedSince}}' 2>/dev/null; return 0; }

scan_docker_build() { docker_ok || return 1; docker_scan "$(docker_reclaimable "Build Cache")" "BuildKit cache"; }
clean_docker_build() { run docker builder prune -f; }
details_docker_build() { docker system df 2>/dev/null | sed 's/^/  /'; return 0; }

# Entries: the desktop app can clean single dangling images, build-cache records, unused images
# and unused volumes (`--json details` lists them, `--json clean ID --entries …` removes those).
# entries_ID prints id<TAB>bytes<TAB>selected<TAB>label[<TAB>note]; clean_entries_ID removes the given IDs.
# Only for a Docker on this computer (a unix socket), never a remote one.
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
{
  ENTRY_RE_docker_dangling='^sha256:[0-9a-f]{64}$'
  ENTRY_RE_docker_images='^sha256:[0-9a-f]{64}$'
  ENTRY_RE_docker_build='^[a-z0-9]{20,32}$'                 # BuildKit record IDs are base-32
  ENTRY_RE_docker_volumes='^[A-Za-z0-9][A-Za-z0-9_.-]+$' # Docker's own rule for volume names
}
# awk: bytes("1.09MB") — the SI units `docker system df` prints (like si_to_bytes); N/A → 0
DOCKER_AWK_BYTES='function bytes(s,  n, u) {
  n = s + 0; u = toupper(substr(s, match(s, /[^0-9.]/), 1))
  return int(n * (u == "K" ? 1e3 : u == "M" ? 1e6 : u == "G" ? 1e9 : u == "T" ? 1e12 : 1) + 0.5)
}'
docker_local() {
  local h=${DOCKER_HOST:-}
  [[ -n $h ]] || h=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
  [[ -z $h || $h == unix://* ]]
}
entries_docker_dangling() {
  docker_ok && docker_local || return 1
  local id size since
  while IFS=$'\t' read -r id size since; do
    [[ $id =~ $ENTRY_RE_docker_dangling ]] || continue
    printf '%s\t%s\t1\t%s\n' "$id" "$(si_to_bytes "$size")" "${id:7:12} · created $since"
  done < <(docker images -f dangling=true --no-trunc --format '{{.ID}}\t{{.Size}}\t{{.CreatedSince}}' 2>/dev/null)
}
entries_docker_build() { # records not in use, biggest first; a shared one frees nothing on its own
  docker_ok && docker_local || return 1
  docker system df -v --format \
    '{{range .BuildCache}}{{.ID}}|{{.Size}}|{{.InUse}}|{{.Shared}}|{{.CacheType}}|{{.LastUsedSince}}|{{.Description}}{{println}}{{end}}' \
    2>/dev/null | awk -F'|' "$DOCKER_AWK_BYTES"'
      $1 ~ /^[a-z0-9]+$/ && length($1) >= 20 && length($1) <= 32 && $3 != "true" { # see ENTRY_RE_docker_build
        d = $7; for (i = 8; i <= NF; i++) d = d "|" $i
        if (d == "") d = $5
        gsub(/[\t\r]/, " ", d)
        printf "%s\t%.0f\t0\t%s · used %s%s\n", $1, ($4 == "true" ? 0 : bytes($2)), d, $6, ($4 == "true" ? " · shared" : "")
      }' | sort -t $'\t' -k2,2nr | head -n 300
}
clean_entries_docker_dangling() { local id rc=0; for id; do run docker rmi "$id" || rc=1; done; return "$rc"; }
clean_entries_docker_build() {
  local id rc=0
  for id; do run docker builder prune --force --filter "id=$id" || rc=1; done
  return "$rc"
}
entries_docker_images() { # images no container uses, biggest first; dangling ones are docker_dangling's
  docker_ok && docker_local || return 1
  local dangling
  dangling=$(docker images -f dangling=true --no-trunc --format '{{.ID}}' 2>/dev/null | cut -f1 | paste -sd' ' -)
  docker system df -v --format \
    '{{range .Images}}{{.ID}}|{{.Containers}}|{{.Size}}|{{.UniqueSize}}|{{.CreatedSince}}|{{.Repository}}|{{.Tag}}{{println}}{{end}}' \
    2>/dev/null | awk -F'|' -v dangling="$dangling" "$DOCKER_AWK_BYTES"'
      BEGIN { n = split(dangling, d, " "); for (i = 1; i <= n; i++) skip[d[i]] = 1 }
      $2 == "0" && !($1 in skip) && !seen[$1]++ && $1 ~ /^sha256:[0-9a-f]+$/ && length($1) == 71 { # see ENTRY_RE_docker_images
        name = ($6 == "<none>") ? substr($1, 8, 12) : ($7 == "<none>" || $7 == "") ? $6 : ($6 ":" $7)
        # removing it frees what no other image shares; N/A (containerd store) → its whole size
        b = $4 ~ /^[0-9.]+[kKMGT]?B$/ ? bytes($4) : bytes($3)
        printf "%s\t%.0f\t0\t%s · created %s\n", $1, b, name, $5
      }' | sort -t $'\t' -k2,2nr
}
clean_entries_docker_images() { # by all of its tags: an image with two tags needs no -f
  local id rc=0 refs
  for id; do
    mapfile -t refs < <(docker images --no-trunc --format '{{.ID}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null |
      awk -F'\t' -v id="$id" '$1 == id && $2 !~ /<none>/ { print $2 }')
    ((${#refs[@]})) || refs=("$id")
    run docker rmi "${refs[@]}" || rc=1
  done
  return "$rc"
}
docker_unused_volumes() { # volumes no container uses, biggest first, as entries; note: anonymous, or data (a named one)
  docker system df -v --format \
    '{{range .Volumes}}{{.Name}}|{{.Links}}|{{.Size}}|{{.Driver}}|{{.Labels}}{{println}}{{end}}' \
    2>/dev/null | awk -F'|' "$DOCKER_AWK_BYTES"'
      $2 == "0" && $1 ~ /^[A-Za-z0-9][A-Za-z0-9_.-]+$/ { # see ENTRY_RE_docker_volumes
        labels = $5; for (i = 6; i <= NF; i++) labels = labels "|" $i
        hex = length($1) == 64 && $1 ~ /^[0-9a-f]+$/
        anon = hex || labels ~ /(^|,)com\.docker\.volume\.anonymous=/
        printf "%s\t%.0f\t0\t%s · %s\t%s\n", $1, bytes($3), (hex ? substr($1, 1, 12) : $1), $4, (anon ? "anonymous" : "data")
      }' | sort -t $'\t' -k2,2nr
}
entries_docker_volumes() { docker_ok && docker_local || return 1; docker_unused_volumes; }
clean_entries_docker_volumes() { local v rc=0; for v; do run docker volume rm "$v" || rc=1; done; return "$rc"; }

scan_docker_containers() {
  docker_ok || return 1
  local n
  n=$(docker ps -aq -f status=exited -f status=created -f status=dead 2>/dev/null | wc -l)
  docker_scan "$(docker_reclaimable Containers)" "$(plural "$n" container)"
  ((n > 0)) && return 0 || return 2
}
clean_docker_containers() { run docker container prune -f; }
details_docker_containers() {
  docker ps -a -f status=exited -f status=created -f status=dead \
    --format '  {{.Names}}  ({{.Image}}) — {{.Status}}' 2>/dev/null
  return 0
}

scan_docker_images() { docker_ok || return 1; docker_scan "$(docker_reclaimable Images)" "not used by any container"; }
clean_docker_images() { run docker image prune -a -f; }
details_docker_images() { docker images --format '  {{.Size}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null; return 0; }

# `docker volume prune -f` removes only anonymous volumes since Docker 23 (API 1.42; the API version both
# sides speak decides), so then the scan counts only those and names the named ones it keeps; the desktop
# app removes a named volume when you tick it. An API version that can't be read counts as 1.42 or newer.
docker_prunes_named_volumes() {
  local c s
  read -r c s < <(timeout 5 docker version --format '{{.Client.APIVersion}} {{.Server.APIVersion}}' 2>/dev/null)
  [[ $c =~ ^([0-9]+)\.([0-9]+) ]] && c=$((BASH_REMATCH[1] * 1000 + 10#${BASH_REMATCH[2]})) || return 1
  [[ $s =~ ^([0-9]+)\.([0-9]+) ]] && s=$((BASH_REMATCH[1] * 1000 + 10#${BASH_REMATCH[2]})) || return 1
  ((c < s ? c < 1042 : s < 1042))
}
scan_docker_volumes() {
  docker_ok || return 1
  local n named=0 b=0 _id vb _sel _label note
  if docker_prunes_named_volumes; then
    n=$(docker volume ls -qf dangling=true 2>/dev/null | wc -l)
    docker_scan "$(docker_reclaimable "Local Volumes")" "$(plural "$n" volume) — may contain data"
    ((n > 0)) && return 0 || return 2
  fi
  n=0
  while IFS=$'\t' read -r _id vb _sel _label note; do
    if [[ $note == anonymous ]]; then n=$((n + 1)) b=$((b + vb)); else named=$((named + 1)); fi
  done < <(docker_unused_volumes)
  docker_scan "$b" "$(plural "$n" "anonymous volume") — may contain data$( ((named)) && printf '; %s kept' "$(plural "$named" "named volume")")"
  ((n + named > 0)) && return 0 || return 2
}
clean_docker_volumes() { run docker volume prune -f; }
details_docker_volumes() {
  if docker_prunes_named_volumes; then
    docker volume ls -f dangling=true --format '  {{.Name}}  ({{.Driver}})' 2>/dev/null
  else
    docker_unused_volumes | awk -F'\t' '{ print "  " $4 ($5 == "anonymous" ? "" : "  (named, kept)") }'
  fi
  return 0
}

# Conda: downloaded archives in pkgs/ plus the index cache — what `conda clean --tarballs
# --index-cache` frees. Extracted packages stay: removing them can break softlinked envs.
CONDA_ROOTS=("$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3" "$HOME/mambaforge")
conda_bin() {
  local c
  for c in "${CONDA_ROOTS[@]/%//bin/conda}" "$(command -v conda 2>/dev/null)"; do # your own install first
    [[ -n $c && -x $c ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
conda_pkgs_dirs() {
  local d
  for d in "${CONDA_ROOTS[@]/%//pkgs}" "$HOME/.conda/pkgs"; do [[ -d $d && ! -L $d ]] && printf '%s\n' "$d"; done
  return 0
}
conda_archives() { # bytes<TAB>path of downloaded package archives
  local dirs
  mapfile -t dirs < <(conda_pkgs_dirs)
  ((${#dirs[@]})) || return 0
  find "${dirs[@]}" -maxdepth 1 -type f \( -name '*.conda' -o -name '*.tar.bz2' \) -printf '%s\t%p\n' 2>/dev/null
}
scan_conda() {
  conda_bin >/dev/null || return 1
  local n b dirs
  mapfile -t dirs < <(conda_pkgs_dirs)
  read -r n b < <(conda_archives | cut -f1 | count_sum)
  SCAN_BYTES=$((b + $(du_sum "${dirs[@]/%//cache}")))
  SCAN_NOTE="$(plural "$n" "package archive")"
  ((SCAN_BYTES > 0)) || return 2
}
clean_conda() { run "$(conda_bin)" clean --tarballs --index-cache --logfiles -y; } # not --packages: it can break softlinked envs
details_conda() { conda_archives | detail_files 30; }

# Podman: like `docker system prune`, without volumes or tagged images. Only asked when
# you've used it: `podman info` creates its storage folders, and a scan must change nothing.
podman_ok() { have podman && [[ -d ${XDG_DATA_HOME:-$HOME/.local/share}/containers ]] && timeout 5 podman info >/dev/null 2>&1; }
scan_podman() {
  podman_ok || return 1
  local sizes v b=0 c
  mapfile -t sizes < <(podman images -f dangling=true --format '{{.Size}}' 2>/dev/null)
  for v in "${sizes[@]}"; do b=$((b + $(si_to_bytes "${v// /}"))); done
  c=$(podman ps -aq -f status=exited -f status=created 2>/dev/null | wc -l)
  SCAN_BYTES=$b SCAN_NOTE="$(plural ${#sizes[@]} "dangling image"), $(plural "$c" "stopped container")"
  ((${#sizes[@]} + c > 0)) || return 2
}
clean_podman() { run podman system prune -f; }
details_podman() {
  podman images -f dangling=true --format '  {{.Size}}  {{.ID}}  created {{.CreatedSince}}' 2>/dev/null
  podman ps -a -f status=exited -f status=created --format '  {{.Names}}  ({{.Image}}) — {{.Status}}' 2>/dev/null
  return 0
}

# ── AI models: one item per downloaded model ──
#
# Models take gigabytes each and are slow to download again, so every model is
# an item of its own: never pre-selected, never cleaned by automatic cleaning
# (it only cleans user & developer junk), and a tick is not remembered for the
# next scan (ITEM_ONCE). Ollama models are removed with `ollama rm` because
# models share layers; Hugging Face and LM Studio models are folders.

declare -A ITEM_ONCE=() MODEL_KIND=() MODEL_REF=()
HF_HUB=${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}
LMS_DIRS=("$HOME/.lmstudio/models" "$HOME/.cache/lm-studio/models")

lms_downloads_folder() { # the models folder chosen in LM Studio's My Models ("downloadsFolder" in its settings.json)
  local f v
  for f in "$HOME/.lmstudio/settings.json" "$HOME/.cache/lm-studio/settings.json"; do
    [[ -f $f && ! -L $f ]] || continue # only read, never written
    if have jq; then
      v=$(jq -r 'if type == "object" and (.downloadsFolder | type) == "string" then .downloadsFolder else empty end' -- "$f" 2>/dev/null)
    elif have python3; then
      v=$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get("downloadsFolder") if isinstance(d, dict) else None
if isinstance(v, str): print(v)' "$f" 2>/dev/null)
    else
      return 0
    fi
    v=${v%/}
    [[ $v == /?* && $v != *$'\n'* ]] && printf '%s\n' "$v"
  done
  return 0
}
lms_add_downloads_folder() {
  local d e
  while IFS= read -r d; do
    for e in "${LMS_DIRS[@]}"; do [[ $e == "$d" ]] && continue 2; done
    LMS_DIRS+=("$d") # model_safe_path still checks every model in it
  done < <(lms_downloads_folder)
}
lms_add_downloads_folder

ollama_models() { # name<TAB>bytes, as the Ollama server reports them
  have ollama || return 0
  local n s1 s2
  timeout 2 ollama list 2>/dev/null | awk 'NR > 1 && NF >= 4 {print $1, $3, $4}' |
    while read -r n s1 s2; do printf '%s\t%s\n' "$n" "$(si_to_bytes "$s1$s2")"; done
}

model_safe_path() { # only a real model folder exactly where a model store keeps them — no symlinks on the way
  local p=$1 rp store d
  [[ -d $p && ! -L $p && ! -L ${p%/*} ]] && ! is_protected "$p" || return 1
  rp=$(realpath -e -- "$p" 2>/dev/null) || return 1
  [[ $rp == "$p" ]] || return 1 # a symlink anywhere in the path (e.g. models/mine → ~) points elsewhere
  if [[ ${p##*/} == models--* ]]; then
    store=$(realpath -e -- "$HF_HUB" 2>/dev/null) && [[ ${rp%/*} == "$store" ]] && return 0
  fi
  for d in "${LMS_DIRS[@]}"; do
    store=$(realpath -e -- "$d" 2>/dev/null) || continue
    [[ ${rp%/*/*} == "$store" && ${p%/*/*} == "$d" ]] && return 0 # <store>/<publisher>/<model>
  done
  return 1
}

model_scan() {
  local ref=${MODEL_REF[$1]} b
  case ${MODEL_KIND[$1]} in
    ollama)
      b=$(ollama_models | awk -F'\t' -v n="$ref" '$1 == n {print $2; exit}')
      [[ -n $b ]] || return 1
      SCAN_BYTES=$b SCAN_NOTE="get it back with: ollama pull $ref" ;;
    *)
      model_safe_path "$ref" || return 1
      SCAN_BYTES=$(du_sum "$ref") SCAN_NOTE=${ref/#$HOME/\~} ;;
  esac
  ((SCAN_BYTES > 0)) || return 2
}
model_clean() {
  local ref=${MODEL_REF[$1]}
  case ${MODEL_KIND[$1]} in
    ollama) run ollama rm "$ref" ;;
    *)
      model_safe_path "$ref" || { err "Not a model folder, skipped: $ref"; return 1; }
      run rm -rf -- "$ref" ;;
  esac
}
model_details() {
  local ref=${MODEL_REF[$1]}
  case ${MODEL_KIND[$1]} in
    ollama) timeout 5 ollama show "$ref" 2>/dev/null | sed 's/^/  /' | head -n 25 ;;
    *) detail_paths "$ref" ;;
  esac
  return 0
}
lockedby_model() { [[ ${MODEL_KIND[$1]} == lms ]] && running_proc -xi 'lms|llmster|lm[- ]studio|lm studio helpe?r?'; }
model_precheck() { # LM Studio may have the model loaded
  lockedby_model "$1" >/dev/null || return 0
  if ((ASSUME_YES)); then warn "Skipping ${ITEM_LABEL[$1]}: LM Studio is running."; return 1; fi
  ui_confirm "LM Studio is running" "Eject the model in LM Studio first. Delete it anyway?" n
}

reg_model_item() { # KIND REF LABEL DESCRIPTION
  local id="model_${1}_${3#* — }" sum
  id=${id,,}; id=${id//[^a-z0-9_]/_}
  sum=$(printf '%s' "$2" | cksum | cut -d' ' -f1)
  id="${id:0:48}_$sum" # the checksum of the exact path/name keeps ids from swapping between scan and clean
  while [[ -n ${ITEM_CAT[$id]:-} ]]; do id+=_; done
  reg "$id" models "$3" 0 "$4"
  MODEL_KIND[$id]=$1 MODEL_REF[$id]=$2 ITEM_ONCE[$id]=1
  eval "scan_$id() { model_scan $id; }
        clean_$id() { model_clean $id; }
        details_$id() { model_details $id; }
        precheck_$id() { model_precheck $id; }
        lockedby_$id() { lockedby_model $id; }"
}

# Ollama keeps an interrupted download as blobs/sha256-<hash>-partial[-N]; no model uses it.
ollama_blob_dirs() { env_home_paths OLLAMA_MODELS blobs "$HOME/.ollama/models/blobs"; }
ollama_partial() {
  local d f
  while IFS= read -r d; do
    [[ -d $d && ! -L $d ]] || continue
    for f in "$d"/sha256-*-partial "$d"/sha256-*-partial-*; do
      [[ -f $f && ! -L $f ]] && printf '%s\n' "$f"
    done
  done < <(ollama_blob_dirs)
  return 0
}
LIST_CAT=models reg_list_item ollama_partial "Ollama — unfinished downloads" 0 download \
  "Pieces of Ollama downloads that were interrupted (sha256-…-partial). Complete models are kept; a pull starts them again." \
  ollama_partial "$(ollama_blob_dirs)" "ollama"

# Models Python libraries downloaded and fetch again when a program needs them: PyTorch Hub weights (each
# file in <torch>/hub/checkpoints), Whisper models (each *.pt in <cache>/whisper), sentence-transformers
# models (each folder with modules.json or config_sentence_transformers.json in <torch>/sentence_transformers
# and SENTENCE_TRANSFORMERS_HOME) and Keras' downloads (models/ and datasets/ of ~/.keras, and of KERAS_HOME
# when it holds keras.json). <cache> = ~/.cache and XDG_CACHE_HOME, <torch> = <cache>/torch and TORCH_HOME;
# variables only inside your home (env_home_dir), no symlinks. A folder two libraries would claim, and a
# model folder holding another library's folder, are left out. Each model is an entry; one a program has
# a file open in is skipped (no lock by name: python runs plenty of other things). Deleted for good; never
# torch/kernels, Hub repos (hub/<owner>_<repo>_<ref>), keras.json or the Hugging Face cache (its own
# items). Not ticked, not remembered; automatic cleaning leaves AI models alone.
model_cache_roots() { # → kind<TAB>folder for each place a library keeps its downloads; a folder two claim: none
  local x t s k c
  x=$(env_home_dir XDG_CACHE_HOME) t=$(env_home_dir TORCH_HOME)
  s=$(env_home_dir SENTENCE_TRANSFORMERS_HOME) k=$(env_home_dir KERAS_HOME)
  {
    for c in "$HOME/.cache" ${x:+"$x"}; do
      printf 'torch\t%s\nwhisper\t%s\nst\t%s\n' "$c/torch/hub/checkpoints" "$c/whisper" "$c/torch/sentence_transformers"
    done
    [[ -n $t ]] && printf 'torch\t%s\nst\t%s\n' "$t/hub/checkpoints" "$t/sentence_transformers"
    [[ -n $s ]] && printf 'st\t%s\n' "$s"
    printf 'keras\t%s\n' "$HOME/.keras"
    [[ -n $k && -f $k/keras.json && ! -L $k/keras.json ]] && printf 'keras\t%s\n' "$k"
  } | awk -F'\t' '{ kind[$2] = (kind[$2] == "" || kind[$2] == $1) ? $1 : "-"; if (!seen[$2]++) order[++n] = $2 }
    END { for (i = 1; i <= n; i++) if (kind[order[i]] != "-") print kind[order[i]] "\t" order[i] }'
}

model_caches() { # → path<TAB>label of each downloaded model to offer
  local roots open kind root p r _k name label cands
  roots=$(model_cache_roots)
  open=$'\n'$(open_files)$'\n'
  while IFS=$'\t' read -r kind root; do
    [[ -n $root && -d $root && ! -L $root ]] || continue
    cands=()
    case $kind in
      torch) for p in "$root"/*; do [[ -f $p ]] && cands+=("$p"); done ;;
      whisper) for p in "$root"/*.pt; do [[ -f $p ]] && cands+=("$p"); done ;;
      st) for p in "$root"/*/; do
            p=${p%/}
            [[ -f $p/modules.json || -f $p/config_sentence_transformers.json ]] && cands+=("$p")
          done ;;
      keras) for p in "$root/models" "$root/datasets"; do [[ -d $p ]] && cands+=("$p"); done ;;
    esac
    for p in "${cands[@]}"; do
      [[ ! -L $p && $p != *[[:cntrl:]]* ]] || continue
      while IFS=$'\t' read -r _k r; do # holds another library's folder
        [[ $r != "$root" && ($r == "$p" || $r == "$p"/*) ]] && continue 2
      done <<<"$roots"
      touches_exclusion "$p" && continue
      open_under "$open" "$p" && continue
      name=${p##*/}
      case $kind in
        torch) label="$name — PyTorch Hub" ;;
        whisper) label="${name%.pt} — Whisper" ;;
        st) label="$name — sentence-transformers" ;;
        keras) label="$name — Keras" ;;
      esac
      printf '%s\t%s\n' "$p" "$label"
    done
  done <<<"$roots"
}
ai_model_caches() { model_caches | cut -f1; }

model_cache_list() { # → MC_PATH / MC_BYTES / MC_LABEL of the models to offer, biggest first
  local p label b lines=()
  MC_PATH=() MC_BYTES=() MC_LABEL=()
  while IFS=$'\t' read -r p label; do
    ai_safe_path "$p" || continue
    b=$(du -sb -- "$p" 2>/dev/null | cut -f1)
    lines+=("${b:-0}"$'\t'"$p"$'\t'"$label")
  done < <(model_caches)
  ((${#lines[@]})) || return 0
  while IFS=$'\t' read -r b p label; do
    MC_BYTES+=("$b") MC_PATH+=("$p") MC_LABEL+=("$label")
  done < <(printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr)
}

LIST_CAT=models reg_list_item ai_model_caches "PyTorch, Whisper & Keras — models" 0 model \
  "Models PyTorch Hub, Whisper, sentence-transformers and Keras downloaded (~/.cache/torch, ~/.cache/whisper, ~/.keras). Deleted; downloaded again when a program needs one. A model in use is skipped." \
  ai_model_caches "$(model_cache_roots | cut -f2)"
ITEM_ONCE[ai_model_caches]=1
# shellcheck disable=SC2034 # read through ${!re_var} in json_pick_entries
ENTRY_RE_ai_model_caches='^/[A-Za-z0-9/._~%-]+$' # the model's full path, percent-encoded (urlencode_path)
entries_ai_model_caches() {
  local i
  model_cache_list
  for i in "${!MC_PATH[@]}"; do
    printf '%s\t%s\t0\t%s\n' "$(urlencode_path "${MC_PATH[i]}")" "${MC_BYTES[i]}" "${MC_LABEL[i]}"
  done
}
clean_entries_ai_model_caches() { # encoded paths (json_clean_entries only passes ones listed now)
  local i id rc=0
  model_cache_list
  for id; do
    for i in "${!MC_PATH[@]}"; do
      [[ $(urlencode_path "${MC_PATH[i]}") == "$id" ]] || continue
      ai_safe_path "${MC_PATH[i]}" || continue
      run rm -rf -- "${MC_PATH[i]}" || rc=1
    done
  done
  return "$rc"
}

discover_models() {
  local n _b d m name
  while IFS=$'\t' read -r n _b; do
    [[ -n $n ]] && reg_model_item ollama "$n" "Ollama — $n" \
      "A model Ollama downloaded. Removed with 'ollama rm'; layers other models use are kept."
  done < <(ollama_models)
  for d in "$HF_HUB"/models--*/; do
    d=${d%/}
    model_safe_path "$d" || continue
    name=${d##*/models--}
    reg_model_item hf "$d" "Hugging Face — ${name//--//}" \
      "A model in the Hugging Face cache. Python code downloads it again the next time it is used."
  done
  for d in "${LMS_DIRS[@]}"; do
    for m in "$d"/*/*/; do
      m=${m%/}
      model_safe_path "$m" || continue
      name=${m#"$d"/}
      reg_model_item lms "$m" "LM Studio — $name" \
        "A model downloaded in LM Studio. Download it again from LM Studio's Discover tab."
    done
  done
  return 0
}
discover_models

# ───────────────────────────── preferences & stats ──────────────────────────

PREF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cleanmate/selection"
STATS_FILE="$LOG_DIR/stats"
CLEANUP_HISTORY="$LOG_DIR/cleanups.tsv" # epoch<TAB>bytes freed, one row per cleanup (last 1000)
declare -A PREF=() STATS=()

load_kv() { # FILE ASSOC_NAME VALUE_REGEX
  local -n _map=$2
  local k v
  [[ -f $1 ]] || return 0
  while IFS='=' read -r k v; do
    [[ $k =~ ^[a-z_]+$ && $v =~ $3 ]] && _map[$k]=$v
  done <"$1"
}

save_prefs() {
  local k
  mkdir -p "${PREF_FILE%/*}" || return
  for k in "${!PREF[@]}"; do printf '%s=%s\n' "$k" "${PREF[$k]}"; done | sort >"$PREF_FILE"
}

record_cleanup() { # BYTES_FREED
  ((DRY_RUN)) && return
  STATS[lifetime]=$((${STATS[lifetime]:-0} + $1))
  STATS[runs]=$((${STATS[runs]:-0} + 1))
  STATS[last_time]=$EPOCHSECONDS
  STATS[last_freed]=$1
  mkdir -p "$LOG_DIR" || return
  local k
  for k in lifetime runs last_time last_freed; do printf '%s=%s\n' "$k" "${STATS[$k]}"; done >"$STATS_FILE"
  { [[ -f $CLEANUP_HISTORY ]] && tail -n 999 "$CLEANUP_HISTORY"; printf '%s\t%s\n' "$EPOCHSECONDS" "$1"; } \
    >"$CLEANUP_HISTORY.tmp" 2>/dev/null && mv -f "$CLEANUP_HISTORY.tmp" "$CLEANUP_HISTORY"
  if [[ -f $LOG_FILE ]] && (($(wc -l <"$LOG_FILE") > 2000)); then # keep our own log small
    tail -n 1000 "$LOG_FILE" >"$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

agov() { # VAR EPOCH → "just now" / "5 min ago" / "3 h ago" / "2 days ago"
  local s=$((EPOCHSECONDS - $2))
  if ((s < 60)); then printf -v "$1" 'just now'
  elif ((s < 3600)); then printf -v "$1" '%d min ago' $((s / 60))
  elif ((s < 86400)); then printf -v "$1" '%d h ago' $((s / 3600))
  else printf -v "$1" '%d days ago' $((s / 86400)); fi
}
ago() { local __a; agov __a "$1"; printf '%s' "$__a"; }

# ───────────────────────────── sudo ─────────────────────────────────────────

sudo_auth() { # REASON — ask for the sudo password
  if ((UI_ACTIVE)); then
    frame_begin; draw_header "Administrator access"; fl ""
    fl "  ${BOLD}🔒 Administrator password required${NC}"
    fl "  ${DIM}$1${NC}"
    fl ""
    frame_flush
    printf '\n'
    term_raw_on
    sudo -v -p "  Password for %p: "
    local rc=$?
    term_raw_off
    return "$rc"
  fi
  info "$1"
  sudo -v
}

ensure_sudo() { # [REASON]
  ((EUID == 0 || DRY_RUN)) && return 0
  sudo -n true 2>/dev/null && return 0
  [[ -t 0 ]] || return 1 # unattended: no password prompt
  sudo_auth "${1:-This task changes system files.}"
}

offer_sudo_for_scan() {
  ((EUID == 0 || SUDO_ASKED)) && return 0
  SUDO_ASKED=1
  sudo -n true 2>/dev/null && return 0
  ui_confirm "Scan system folders with sudo?" "Gives exact sizes for root-owned logs and caches." y &&
    { sudo_auth "Used to measure root-owned folders. Nothing is changed during a scan." || toast "${YELLOW}!${NC} Continuing without sudo — system sizes may be low."; }
  return 0
}

# ───────────────────────────── last-scan cache ──────────────────────────────
#
# Results of the latest scan per item, so the main menu can show what was
# found (and when) without scanning again.

SCAN_CACHE_FILE="$LOG_DIR/last-scan.tsv"
declare -A LAST_RC=() LAST_BYTES=() LAST_AT=()

load_scan_cache() {
  local id rc b t
  [[ -f $SCAN_CACHE_FILE ]] || return 0
  while IFS=$'\t' read -r id rc b t; do
    [[ $id =~ ^[a-z0-9_]+$ && $rc =~ ^[0-9]$ && $b =~ ^[0-9]+$ && $t =~ ^[0-9]+$ && -n ${ITEM_CAT[$id]:-} ]] || continue
    LAST_RC[$id]=$rc LAST_BYTES[$id]=$b LAST_AT[$id]=$t
  done <"$SCAN_CACHE_FILE"
}

save_scan_cache() { # record RES_* for SCANNED; forget items of those categories that vanished
  local id c
  for id in "${!LAST_RC[@]}"; do
    for c in "${SCAN_CATS[@]}"; do
      [[ ${ITEM_CAT[$id]:-} == "$c" ]] && unset "LAST_RC[$id]" "LAST_BYTES[$id]" "LAST_AT[$id]"
    done
  done
  for id in "${SCANNED[@]}"; do
    LAST_RC[$id]=${RES_RC[$id]} LAST_BYTES[$id]=${RES_BYTES[$id]} LAST_AT[$id]=$EPOCHSECONDS
  done
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  for id in "${!LAST_RC[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$id" "${LAST_RC[$id]}" "${LAST_BYTES[$id]}" "${LAST_AT[$id]}"
  done >"$SCAN_CACHE_FILE" 2>/dev/null
  return 0
}

ago_short() { # VAR EPOCH → now / 5m / 3h / 2d
  local s=$((EPOCHSECONDS - $2))
  if ((s < 60)); then printf -v "$1" 'now'
  elif ((s < 3600)); then printf -v "$1" '%dm ago' $((s / 60))
  elif ((s < 86400)); then printf -v "$1" '%dh ago' $((s / 3600))
  else printf -v "$1" '%dd ago' $((s / 86400)); fi
}

cat_badge() { # CATEGORY... → BADGE: what the last scan found there (empty if unknown or > 7 days old)
  local id c tot=0 n=0 oldest=0 hit=0 sz age clr
  BADGE=""
  for id in "${!LAST_RC[@]}"; do
    for c in "$@"; do
      [[ ${ITEM_CAT[$id]:-} == "$c" ]] || continue
      hit=1
      ((oldest == 0 || LAST_AT[$id] < oldest)) && oldest=${LAST_AT[$id]}
      ((LAST_RC[$id] == 0)) && { tot=$((tot + LAST_BYTES[$id])); ((++n)); }
    done
  done
  ((hit && EPOCHSECONDS - oldest < 7 * 86400)) || return 0
  ago_short age "$oldest"
  if [[ $* == privacy ]]; then
    if ((n)); then BADGE="${YELLOW}$n to clear${NC} ${DIM}· $age${NC}"; else BADGE="${GREEN}✓ clear${NC} ${DIM}· $age${NC}"; fi
  elif ((tot > 0)); then
    humanv sz "$tot"; size_colorv clr "$tot"
    BADGE="$clr$sz${NC} ${DIM}· $age${NC}"
  else BADGE="${GREEN}✓ clean${NC} ${DIM}· $age${NC}"; fi
  return 0
}

# ───────────────────────────── free-space history ───────────────────────────

DISK_HISTORY="$LOG_DIR/disk-history.tsv" # day<TAB>free bytes on /<TAB>size of /

record_disk_usage() { # one row per day (the latest reading of the day wins), last 400 days
  local size avail today
  read -r size avail < <(df -B1 --output=size,avail / 2>/dev/null | tail -n 1)
  [[ $avail =~ ^[0-9]+$ ]] || return 0
  printf -v today '%(%Y-%m-%d)T' -1
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  {
    [[ -f $DISK_HISTORY ]] && grep -v "^$today"$'\t' "$DISK_HISTORY" | tail -n 399
    printf '%s\t%s\t%s\n' "$today" "$avail" "$size"
  } >"$DISK_HISTORY.tmp" 2>/dev/null && mv -f "$DISK_HISTORY.tmp" "$DISK_HISTORY"
  return 0
}

sparkline() { # VAR VALUE... → ▁▂▃▅▇ (lowest to highest)
  local -n __sp=$1
  shift
  local blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █) v min=$1 max=$1
  for v in "$@"; do ((v < min)) && min=$v; ((v > max)) && max=$v; done
  __sp=""
  for v in "$@"; do
    if ((max == min)); then __sp+=${blocks[3]}; else __sp+=${blocks[(v - min) * 7 / (max - min)]}; fi
  done
}

disk_history_lines() { # for System Overview
  local rows=() r d a first_d first_a last_d last_a days vals=() spark per_week weeks h1 h2 h3
  [[ -f $DISK_HISTORY ]] && mapfile -t rows < <(tail -n 30 "$DISK_HISTORY")
  printf '\n  %sFree space history%s\n' "$BOLD" "$NC"
  if ((${#rows[@]} < 2)); then
    printf '  %sRecorded once a day while you use the app — check back in a few days.%s\n' "$DIM" "$NC"
    return 0
  fi
  for r in "${rows[@]}"; do IFS=$'\t' read -r d a _ <<<"$r"; vals+=("$a"); done
  IFS=$'\t' read -r first_d first_a _ <<<"${rows[0]}"
  IFS=$'\t' read -r last_d last_a _ <<<"${rows[-1]}"
  sparkline spark "${vals[@]}"
  humanv h1 "$first_a"; humanv h2 "$last_a"
  printf '  %s%s%s  %s free on %s → %s on %s\n' "$ACCENT" "$spark" "$NC" "$h1" "$first_d" "$h2" "$last_d"
  days=$((($(date -d "$last_d" +%s) - $(date -d "$first_d" +%s)) / 86400))
  ((days > 0)) || return 0
  per_week=$(((last_a - first_a) * 7 / days))
  if ((per_week < -104857600)); then # losing more than 100 MB a week
    humanv h3 $((-per_week))
    weeks=$((last_a / -per_week))
    printf '  %sLosing about %s a week%s %s— at this rate / is full in ~%d weeks.%s\n' "$YELLOW" "$h3" "$NC" "$DIM" "$weeks" "$NC"
  elif ((per_week > 104857600)); then
    humanv h3 "$per_week"
    printf '  %sGaining about %s a week.%s\n' "$GREEN" "$h3" "$NC"
  else
    printf '  %sStable over the last %d days.%s\n' "$GREEN" "$days" "$NC"
  fi
}

# ───────────────────────────── scan engine ──────────────────────────────────

declare -A RES_BYTES RES_NOTE RES_RC RES_HUMAN RES_LOCK SEL SCAN_GOT

res_notev() { # VAR ID — the scan note, led by the program that has to be closed first
  local n=${RES_NOTE[$2]}
  [[ -n ${RES_LOCK[$2]:-} ]] && n="close ${RES_LOCK[$2]} first${n:+ · $n}"
  printf -v "$1" '%s' "$n"
}
SCAN_TIMEOUT=120

kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }

now_ms() { local t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000)); }

fs_avail() { # free bytes on the filesystems holding / and $HOME
  df -B1 --output=avail,target / "$HOME" 2>/dev/null | tail -n +2 | sort -u -k2,2 | sum_lines
}

progress_bar() { # VAR DONE TOTAL WIDTH
  local f=0 pa pb
  (($3 > 0)) && f=$(($2 * $4 / $3))
  repeatv pa █ "$f"; repeatv pb ░ $(($4 - f))
  printf -v "$1" '%s%s%s%s%s' "$ACCENT" "$pa" "$DIM" "$pb" "$NC"
}

draw_scan_frame() { # DONE TOTAL CURRENT
  local cat id n_done n_all bytes icon name pbar
  frame_begin; draw_header "$SCAN_TITLE"; fl ""
  fl "  ${BOLD}Scanning your system…${NC}"
  fl ""
  progress_bar pbar "$1" "$2" 36
  fl "  $pbar  ${BOLD}$1${NC}${DIM}/$2${NC}"
  fl ""
  for cat in "${SCAN_CATS[@]}"; do
    n_done=0 n_all=0 bytes=0
    for id in "${SCAN_IDS[@]}"; do
      [[ ${ITEM_CAT[$id]} == "$cat" ]] || continue
      ((++n_all))
      [[ -n ${SCAN_GOT[$id]} ]] || continue
      ((++n_done))
      ((RES_RC[$id] == 0)) && bytes=$((bytes + RES_BYTES[$id]))
    done
    if ((n_done == n_all)); then icon="${GREEN}✔${NC}"; else icon="${ACCENT}${SPINNER[SPIN_I % 10]}${NC}"; fi
    fitv name "${CAT_TITLE[$cat]}" 22
    fl "   $icon  $name ${DIM}$n_done/$n_all${NC}    $(human "$bytes")"
  done
  ((SPIN_I++))
  fl ""
  fl "  ${DIM}Checking ${3}…${NC}"
  hints q cancel
  draw_footer "$HINTS"; frame_flush
}

SCAN_BATCHES=4 # shared processes for the light items

scan_worker() { # FILE ID… — scan the items one after the other: a line each in FILE, then FILE.ok
  local _sw_id _sw_rc _sw_lock
  for _sw_id in "${@:2}"; do
    SCAN_BYTES=0 SCAN_NOTE="" _sw_lock=""
    "scan_$_sw_id" </dev/null >/dev/null 2>&1; _sw_rc=$?
    ((_sw_rc == 0)) && declare -F "lockedby_$_sw_id" >/dev/null && _sw_lock=$("lockedby_$_sw_id" </dev/null 2>/dev/null)
    # fields split by \x1f: tabs are IFS whitespace, so an empty lock would vanish
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$_sw_id" "$_sw_rc" "${SCAN_BYTES:-0}" "${_sw_lock%%$'\n'*}" "${SCAN_NOTE%%$'\n'*}"
  done >"$1"
  : >"$1.ok"
}

scan_collect() { # FILE — the results a worker wrote (only whole lines: one cut short by a kill is left out)
  local id rc bytes lock note
  [[ -f $1 ]] || return 0
  while IFS=$'\x1f' read -r id rc bytes lock note; do
    [[ -n ${ITEM_CAT[$id]:-} ]] || continue
    [[ -n ${SCAN_GOT[$id]:-} ]] || ((++SCAN_DONE))
    RES_RC[$id]=$rc RES_BYTES[$id]=${bytes:-0} RES_LOCK[$id]=$lock RES_NOTE[$id]=$note SCAN_GOT[$id]=1
  done <"$1"
}

# Scan all items of the given categories in parallel; fills SCANNED (ordered
# by category, junk first, biggest first), SCAN_MS and SCAN_COUNT.
scan_items() { # CATEGORY...
  SCANNED=() SCAN_CATS=("$@") SCAN_IDS=() SCAN_GOT=() SCAN_DONE=0
  local found=() id cat tmp t0 now pending first=0 k h i json_last=-1 wait_n=0 watch="" reaped light=()
  local -a w_ids=() w_pid=() w_done=()
  local -A live=() cat_n=()
  for cat in "$@"; do
    for id in "${ITEM_IDS[@]}"; do [[ ${ITEM_CAT[$id]} == "$cat" ]] && SCAN_IDS+=("$id"); done
  done
  tmp=$(mktemp -d -p "$SESSION_TMP") || return 1
  t0=$(now_ms)

  # a process for each item that runs other programs or walks big trees, a few for the rest
  for id in "${SCAN_IDS[@]}"; do
    if [[ -n ${ITEM_LIGHT[$id]:-} ]]; then light+=("$id"); else w_ids+=("$id"); fi
  done
  k=${#w_ids[@]}
  for ((i = 0; i < ${#light[@]}; i++)); do w_ids[k + i % SCAN_BATCHES]+="${w_ids[k + i % SCAN_BATCHES]:+ }${light[i]}"; done
  for k in "${!w_ids[@]}"; do
    # shellcheck disable=SC2086 # the IDs are words
    scan_worker "$tmp/$k" ${w_ids[k]} &
    w_pid[k]=$! live[$!]=$k
  done

  # Wake when a worker ends (wait -n, bash 5.1+); the terminal app also redraws
  # and reads keys, so it looks every 0.1 s.
  ((!UI_ACTIVE && (BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1)))) && wait_n=1
  while :; do
    for k in "${!w_ids[@]}"; do
      [[ -z ${w_done[k]:-} && -e $tmp/$k.ok ]] && { scan_collect "$tmp/$k"; w_done[k]=1; }
    done
    ((SCAN_DONE == ${#SCAN_IDS[@]})) && break
    while [[ -n ${SCAN_GOT[${SCAN_IDS[first]}]:-} ]]; do ((++first)); done
    pending=${ITEM_LABEL[${SCAN_IDS[first]}]}
    now=${EPOCHREALTIME/[.,]/}
    if ((now / 1000 - t0 >= SCAN_TIMEOUT * 1000)); then
      for k in "${!w_ids[@]}"; do
        [[ -n ${w_done[k]:-} ]] || { kill_tree "${w_pid[k]}"; scan_collect "$tmp/$k"; }
      done
      break
    fi
    if ((UI_ACTIVE)); then
      draw_scan_frame "$SCAN_DONE" "${#SCAN_IDS[@]}" "$pending"
      if read_key 0.1 && [[ $KEY == q || $KEY == esc ]]; then
        for k in "${!w_ids[@]}"; do [[ -n ${w_done[k]:-} ]] || kill_tree "${w_pid[k]}"; done
        rm -rf "$tmp"
        SCANNED=()
        toast "${YELLOW}!${NC} Scan cancelled."
        return 130
      fi
    else
      if ((JSON)); then
        if ((SCAN_DONE != json_last)); then
          json_str k "$pending"
          printf '{"event":"progress","done":%d,"total":%d,"current":%s}\n' "$SCAN_DONE" "${#SCAN_IDS[@]}" "$k"
          json_last=$SCAN_DONE
        fi
      elif [[ -t 1 ]]; then printf '\r\e[K  Scanning %d/%d  %s…' "$SCAN_DONE" "${#SCAN_IDS[@]}" "$pending"; fi
      if ((wait_n)); then
        [[ -n $watch ]] || { sleep "$SCAN_TIMEOUT" & watch=$!; } # wakes the wait at the time limit
        reaped=""
        wait -n -p reaped "${!live[@]}" "$watch"
        if [[ -n $reaped && -n ${live[$reaped]:-} ]]; then
          k=${live[$reaped]}
          unset "live[$reaped]"
          # ended without finishing (killed): what it found counts, the rest is reported as timed out
          [[ -n ${w_done[k]:-} || -e $tmp/$k.ok ]] || { scan_collect "$tmp/$k"; w_done[k]=1; }
        fi
      else sleep 0.1; fi
    fi
  done
  [[ -n $watch ]] && { kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null; }
  ((UI_ACTIVE)) || { [[ -t 1 ]] && printf '\r\e[K'; }
  SCAN_MS=$(($(now_ms) - t0))
  SCAN_COUNT=${#SCAN_IDS[@]}

  for id in "${SCAN_IDS[@]}"; do
    [[ -n ${SCAN_GOT[$id]} ]] || RES_RC[$id]=3 RES_BYTES[$id]=0 RES_LOCK[$id]="" RES_NOTE[$id]="scan timed out"
    ((RES_RC[$id] == 1)) && continue
    humanv h "${RES_BYTES[$id]}"
    RES_HUMAN[$id]=$h
    SEL[$id]=0
    if ((RES_RC[$id] == 0)); then
      if [[ -n ${ITEM_ONCE[$id]:-} ]]; then SEL[$id]=${ITEM_DEFAULT[$id]}
      else SEL[$id]=${PREF[$id]:-${ITEM_DEFAULT[$id]}}; fi
    fi
    found+=("$id")
  done
  rm -rf "$tmp"

  # categories in the order given, then found before clean, then biggest first (ties: by ID)
  i=0
  for cat in "$@"; do cat_n[$cat]=$((i++)); done
  while IFS=$'\t' read -r _ _ _ id; do SCANNED+=("$id"); done < <(
    for id in "${found[@]}"; do
      printf '%d\t%d\t%d\t%s\n' "${cat_n[${ITEM_CAT[$id]}]}" "$((RES_RC[$id] == 0 ? 0 : 1))" "${RES_BYTES[$id]}" "$id"
    done | sort -t$'\t' -k1,1n -k2,2n -k3,3rn
  )
  save_scan_cache
  record_disk_usage
  return 0
}

found_total() { # → FOUND_TOTAL, FOUND_N, SELECTED_TOTAL, SELECTED_N
  local id
  FOUND_TOTAL=0 FOUND_N=0 SELECTED_TOTAL=0 SELECTED_N=0
  for id in "${SCANNED[@]}"; do
    ((RES_RC[$id] == 0)) || continue
    FOUND_TOTAL=$((FOUND_TOTAL + RES_BYTES[$id])); ((++FOUND_N))
    ((SEL[$id])) && { SELECTED_TOTAL=$((SELECTED_TOTAL + RES_BYTES[$id])); ((++SELECTED_N)); }
  done
}

# ── plain output (--scan / --clean) ──

plain_results() {
  local i=0 id cat last="" box size note
  declare -A cat_total=()
  found_total
  if [[ ${SCAN_CATS[*]} == privacy ]]; then
    printf '  Found %s%d history lists%s with entries\n' "$BOLD" "$FOUND_N" "$NC"
  else
  printf '  Found %s%s%s of junk in %d items %s· scanned %d locations in %d.%ds%s\n' \
    "$BOLD$(size_color "$FOUND_TOTAL")" "$(human "$FOUND_TOTAL")" "$NC" "$FOUND_N" "$DIM" "$SCAN_COUNT" \
    $((SCAN_MS / 1000)) $((SCAN_MS % 1000 / 100)) "$NC"
  fi
  for id in "${SCANNED[@]}"; do
    ((RES_RC[$id] == 0)) && cat_total[${ITEM_CAT[$id]}]=$((${cat_total[${ITEM_CAT[$id]}]:-0} + RES_BYTES[$id]))
  done
  for id in "${SCANNED[@]}"; do
    cat=${ITEM_CAT[$id]}
    if [[ $cat != "$last" ]]; then
      printf '\n  %s%-42s %10s%s\n' "$BOLD$BLUE" "${CAT_TITLE[$cat]}" "$(human "${cat_total[$cat]:-0}")" "$NC"
      last=$cat
    fi
    ((++i))
    if ((RES_RC[$id] != 0)); then
      printf '  %s%2d)  ✓  %-34s %10s  %s%s\n' "$DIM" "$i" "${ITEM_LABEL[$id]}" "" \
        "$( ((RES_RC[$id] == 3)) || [[ ( $id == old_installers || $id == old_downloads || $id == old_runtimes || $id == jetbrains_old_versions || $id == vscode_old_extensions ) && -n ${RES_NOTE[$id]} ]] && echo "${RES_NOTE[$id]}" || echo clean)" "$NC"
      continue
    fi
    if ((SEL[$id])); then box="${GREEN}[x]${NC}"; else box="${DIM}[ ]${NC}"; fi
    if ((RES_BYTES[$id] > 0)); then size=${RES_HUMAN[$id]}; else size="—"; fi
    res_notev note "$id"
    printf '  %2d) %s %-34s %s%10s%s  %s%s%s\n' "$i" "$box" "${ITEM_LABEL[$id]}" \
      "$(size_color "${RES_BYTES[$id]}")" "$size" "$NC" "$DIM" "$note" "$NC"
  done
}

# ───────────────────────────── review screen ────────────────────────────────

SHOW_CLEAN=0 # review: list clean items one by one (h toggles) instead of one summary row

build_review_rows() { # rows: h = group header, i = item, c = "N more are clean", s = spacer
  R_KIND=() R_REF=() REVIEW_MAX=0
  local id last="" hidden=0
  for id in "${SCANNED[@]}"; do
    if [[ ${ITEM_CAT[$id]} != "$last" ]]; then
      ((hidden)) && { R_KIND+=(c); R_REF+=("$hidden"); hidden=0; }
      ((${#R_KIND[@]})) && { R_KIND+=(s); R_REF+=(""); }
      R_KIND+=(h); R_REF+=("${ITEM_CAT[$id]}")
      last=${ITEM_CAT[$id]}
    fi
    if ((RES_RC[$id] != 0 && !SHOW_CLEAN)); then ((++hidden)); continue; fi
    R_KIND+=(i); R_REF+=("$id")
    ((RES_RC[$id] == 0 && RES_BYTES[$id] > REVIEW_MAX)) && REVIEW_MAX=${RES_BYTES[$id]}
  done
  ((hidden)) && { R_KIND+=(c); R_REF+=("$hidden"); }
  return 0
}

review_index_of() { # KIND REF → index of that row in R_* (or 0)
  local i
  for i in "${!R_KIND[@]}"; do [[ ${R_KIND[i]} == "$1" && ${R_REF[i]} == "$2" ]] && { echo "$i"; return; }; done
  echo 0
}

review_text() {
  case ${R_KIND[$1]} in h) TEXT=${CAT_TITLE[${R_REF[$1]}]} ;; i) TEXT="${ITEM_LABEL[${R_REF[$1]}]} ${RES_NOTE[${R_REF[$1]}]}" ;; esac
}

review_focusable() {
  case ${R_KIND[$1]} in
    h) return 0 ;;
    i) ((RES_RC[${R_REF[$1]}] == 0)) ;;
    *) return 1 ;;
  esac
}

review_layout() { # column widths for the current terminal
  RV_LW=30 RV_BW=0
  ((UI_W >= 96)) && RV_BW=12
  ((UI_W < 70)) && RV_LW=22
  RV_NW=$((UI_W - 3 - 2 - RV_LW - 1 - (RV_BW ? RV_BW + 1 : 0) - 9 - 2 - 1))
}

review_row() {
  local kind=${R_KIND[$1]} ref=${R_REF[$1]} mark="  " lbl sz nt barv clr id n=0 s=0 tot=0 cnt hw
  case $kind in
    s) fl ""; return ;;
    c)
      local more them=them; pluralv more "$ref" "more item"; ((ref == 1)) && them=it
      fl "   ${DIM}✓ $more clean — press h to show $them${NC}"
      return ;;
    h)
      (($2)) && mark="${ACCENT}▸${NC} "
      for id in "${SCANNED[@]}"; do
        [[ ${ITEM_CAT[$id]} == "$ref" ]] && ((RES_RC[$id] == 0)) || continue
        ((++n)); tot=$((tot + RES_BYTES[$id]))
        ((SEL[$id])) && ((++s))
      done
      cnt="$s/$n selected"
      hw=$((2 + RV_LW + 1 + (RV_BW ? RV_BW + 1 : 0) - ${#cnt} - 2))
      fitv lbl "${CAT_TITLE[$ref]^^}" "$hw"
      humanv sz "$tot"; printf -v sz '%9s' "$sz"
      fl " $mark${BOLD}${BLUE}$lbl${NC}  ${DIM}$cnt${NC}${BOLD}$sz${NC}"
      ;;
    i)
      local id=$ref
      fitv lbl "${ITEM_LABEL[$id]}" "$RV_LW"
      res_notev nt "$id"
      fitv nt "$nt" "$RV_NW"
      if ((RES_RC[$id] != 0)); then
        printf -v sz '%9s' ""
        local st="clean"; ((RES_RC[$id] == 3)) && st="timed out"
        fitv nt "$st" "$RV_NW"
        repeatv barv ' ' $((RV_BW ? RV_BW + 1 : 0))
        fl "   ${DIM}✓ $lbl $barv$sz  $nt${NC}"
        return
      fi
      (($2)) && mark="${ACCENT}▸${NC} " lbl="${BOLD}$lbl${NC}"
      if ((SEL[$id])); then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
      if ((RES_BYTES[$id] > 0)); then printf -v sz '%9s' "${RES_HUMAN[$id]}"; else printf -v sz '%9s' "—"; fi
      size_colorv clr "${RES_BYTES[$id]}"
      barv=""
      ((RV_BW)) && { size_bar barv "${RES_BYTES[$id]}" "$REVIEW_MAX" "$RV_BW"; barv+=" "; }
      fl " $mark$box $lbl $barv$clr$sz$NC  ${DIM}$nt${NC}"
      ;;
  esac
}

review_top() {
  found_total
  fl ""
  if [[ ${SCAN_CATS[*]} == privacy ]]; then
    if ((FOUND_N)); then
      local hl; pluralv hl "$FOUND_N" "history list"
      fl_card "${BOLD}$hl with entries${NC}" \
        "${DIM}Select what to clear — nothing is cleared until you confirm.${NC}"
    else
      fl_card "${GREEN}${BOLD}✔ Nothing to clear${NC}" "${DIM}Your histories and recent lists are empty.${NC}"
    fi
  elif ((FOUND_TOTAL > 0 || FOUND_N > 0)); then
    local clr ft fn; size_colorv clr "$FOUND_TOTAL"; humanv ft "$FOUND_TOTAL"; pluralv fn "$FOUND_N" item
    fl_card "${clr}${BOLD}$ft${NC} ${BOLD}of junk found${NC} in $fn" \
      "${DIM}$SCAN_COUNT locations scanned in $((SCAN_MS / 1000)).$((SCAN_MS % 1000 / 100))s${NC}"
  else
    fl_card "${GREEN}${BOLD}✔ Your system is clean${NC}" "${DIM}Nothing worth removing was found.${NC}"
  fi
  review_layout
}

review_bottom() {
  local clr desc ref=${R_REF[$L_CUR]}
  size_colorv clr "$SELECTED_TOTAL"
  fl ""
  local st sn fa fb
  humanv st "$SELECTED_TOTAL"; pluralv sn "$SELECTED_N" item
  if ((UI_W >= 80)); then
    humanv fa "$REVIEW_AVAIL"; humanv fb $((REVIEW_AVAIL + SELECTED_TOTAL))
    fl "  ${BOLD}Selected${NC} ${clr}${BOLD}$st${NC} ${DIM}in $sn · free space $fa → ~$fb${NC}"
  else
    fl "  ${BOLD}Selected${NC} ${clr}${BOLD}$st${NC} ${DIM}in $sn${NC}"
  fi
  case ${R_KIND[$L_CUR]} in
    h) desc="Press space to select or deselect every item in this group." ;;
    i) desc=${ITEM_DESC[$ref]} ;;
  esac
  fitv desc "$desc" $((UI_W - 6))
  fl "  ${ACCENT}ℹ${NC} ${DIM}$desc${NC}"
}

set_sel() { # ID 0|1 — select and remember (except one-off items like AI models)
  ((RES_RC[$1] == 0)) || return 0
  SEL[$1]=$2
  [[ -n ${ITEM_ONCE[$1]:-} ]] || PREF[$1]=$2
}

group_toggle() { # CATEGORY
  local id any_off=0
  for id in "${SCANNED[@]}"; do
    [[ ${ITEM_CAT[$id]} == "$1" ]] && ((RES_RC[$id] == 0 && !SEL[$id])) && any_off=1
  done
  for id in "${SCANNED[@]}"; do [[ ${ITEM_CAT[$id]} == "$1" ]] && set_sel "$id" "$any_off"; done
}

scan_and_review() { # TITLE CATEGORY...
  local title=$1 cur scroll kind ref id
  shift
  SCAN_TITLE=$title
  [[ " $* " == *" system "* ]] && offer_sudo_for_scan
  scan_items "$@" || return
  build_review_rows
  REVIEW_AVAIL=$(fs_avail)
  cur=0 scroll=0
  while :; do
    L_TITLE=$title L_TOP=review_top L_BOTTOM=review_bottom L_ROW=review_row
    L_FOCUSABLE=review_focusable L_TEXT=review_text L_VIEW=0 L_COUNT=${#R_KIND[@]} L_CUR=$cur L_SCROLL=$scroll
    hints space select "!c" Clean "→" details q back a all n none h "$( ((SHOW_CLEAN)) && echo "hide clean" || echo "show clean")" r rescan
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL kind=${R_KIND[$L_CUR]} ref=${R_REF[$L_CUR]}
    case $KEY in
      h)
        SHOW_CLEAN=$((1 - SHOW_CLEAN))
        build_review_rows
        cur=$(review_index_of "$kind" "$ref") ;;
      space)
        if [[ $kind == h ]]; then group_toggle "$ref"
        elif [[ $kind == i ]]; then set_sel "$ref" $((1 - SEL[$ref])); fi
        save_prefs ;;
      enter | right | d)
        if [[ $kind == i ]]; then show_details "$ref"
        elif [[ $kind == h ]]; then group_toggle "$ref"; save_prefs; fi ;;
      a) for id in "${SCANNED[@]}"; do ((RES_RC[$id] == 0)) && SEL[$id]=1; done ;;
      n) for id in "${SCANNED[@]}"; do SEL[$id]=0; done ;;
      c)
        if start_cleanup; then
          build_review_rows; REVIEW_AVAIL=$(fs_avail)
          cur=$(review_index_of "$kind" "$ref")
        fi ;;
      r) scan_items "$@" || return; build_review_rows; REVIEW_AVAIL=$(fs_avail); cur=0 scroll=0 ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

# ── details ──

details_top() {
  local clr st note
  size_colorv clr "${RES_BYTES[$DETAIL_ID]}"
  res_notev note "$DETAIL_ID"
  if ((SEL[$DETAIL_ID])); then st="${GREEN}● selected${NC}"; else st="${DIM}○ not selected${NC}"; fi
  fl ""
  fl "  ${clr}${BOLD}${RES_HUMAN[$DETAIL_ID]}${NC}   $st   ${DIM}$note${NC}"
  fl "  ${DIM}${ITEM_DESC[$DETAIL_ID]}${NC}"
  fl ""
}

show_details() { # ID
  local id=$1 tmp
  DETAIL_ID=$id
  tmp=$(mktemp -p "$SESSION_TMP")
  if declare -F "details_$id" >/dev/null; then ("details_$id") >"$tmp" 2>/dev/null &
  else : >"$tmp" & fi
  UI_BUSY_TITLE=${ITEM_LABEL[$id]}
  ui_busy "Collecting details…" $! || { rm -f "$tmp"; return; }
  mapfile -t V_LINES <"$tmp"
  rm -f "$tmp"
  ((${#V_LINES[@]})) || V_LINES=("  ${DIM}Nothing more to show.${NC}")
  L_SCROLL=0
  while :; do
    L_TITLE="${ITEM_LABEL[$id]}" L_TOP=details_top L_BOTTOM="" L_ROW=view_row L_FOCUSABLE=""
    L_VIEW=1 L_COUNT=${#V_LINES[@]}
    hints "↑↓" scroll space "$( ((SEL[$id])) && echo deselect || echo select)" q back
    L_HINTS=$HINTS
    ui_list
    case $KEY in
      space) set_sel "$id" $((1 - SEL[$id])); save_prefs ;;
      q | esc | left | enter | backspace) L_VIEW=0; return ;;
    esac
  done
}

# ───────────────────────────── task runner ──────────────────────────────────
#
# Tasks are T_LABEL / T_FN / T_ARG. For each task, <fn>_pre ARG runs first in
# the foreground (may ask; non-zero skips), <fn> ARG runs in the background
# with its output captured, then <fn>_post ARG RC IDX OUTFILE may set T_INFO.

declare -a T_LABEL=() T_FN=() T_ARG=() T_STATE=() T_INFO=()
RUN_KIND=other RUN_FREED=0 T_CUR=-1

new_tasks() { T_LABEL=() T_FN=() T_ARG=() RUN_FREED=0 RUN_KIND=${1:-other}; }
add_task() { T_LABEL+=("$1") T_FN+=("$2") T_ARG+=("${3:-}"); }

draw_runner() { # TITLE OUTFILE
  local i n=${#T_LABEL[@]} d=0 pbar icon lbl info last start avail extra=""
  for ((i = 0; i < n; i++)); do [[ ${T_STATE[i]} == @(ok|skip|fail) ]] && ((d++)); done
  frame_begin; draw_header "$1"; fl ""
  progress_bar pbar "$d" "$n" 36
  [[ $RUN_KIND == clean ]] && extra=" · $(human "$RUN_FREED") $( ((DRY_RUN)) && echo "would be freed" || echo freed)"
  fl "  $pbar  ${BOLD}$d${NC}${DIM}/$n · $(((($(now_ms) - RUN_T0)) / 1000))s$extra${NC}"
  fl ""
  avail=$((TERM_ROWS - FRAME_N - 7))
  start=0
  ((n > avail && T_CUR > avail / 2)) && start=$((T_CUR - avail / 2))
  ((start > n - avail && n > avail)) && start=$((n - avail))
  for ((i = start; i < n && i < start + avail; i++)); do
    fitv lbl "${T_LABEL[i]}" 38
    info=${T_INFO[i]}
    case ${T_STATE[i]} in
      pending) icon="${DIM}○${NC}" lbl="${DIM}$lbl${NC}" ;;
      run) icon="${ACCENT}${SPINNER[SPIN_I % 10]}${NC}" lbl="${BOLD}$lbl${NC}" info="working…" ;;
      ok) icon="${GREEN}✔${NC}" ;;
      skip) icon="${YELLOW}–${NC}" ;;
      fail) icon="${RED}✘${NC}" ;;
    esac
    fl "   $icon  $lbl  ${DIM}$info${NC}"
  done
  ((SPIN_I++))
  if [[ -n $2 && -s $2 ]]; then
    last=$(grep -v '^@@' "$2" | grep -v '^\s*$' | tail -n 1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    fitv last "$last" $((UI_W - 8))
    fl ""
    fl "   ${DIM}│ $last${NC}"
  fi
  hints "ctrl+c" abort
  draw_footer "$HINTS"; frame_flush
}

run_tasks() { # TITLE
  local title=$1 i n=${#T_LABEL[@]} out pid rc
  mkdir -p "$LOG_DIR" && : >"$RUN_LOG"
  T_STATE=() T_INFO=()
  for ((i = 0; i < n; i++)); do T_STATE[i]=pending T_INFO[i]=""; done
  RUN_T0=$(now_ms)
  local keepalive=""
  if ((EUID != 0)) && sudo -n true 2>/dev/null; then # keep credentials fresh during long tasks
    (while sleep 45; do sudo -n -v 2>/dev/null || exit; done) &
    keepalive=$!
  fi
  for ((i = 0; i < n; i++)); do
    T_CUR=$i
    if declare -F "${T_FN[i]}_pre" >/dev/null && ! "${T_FN[i]}_pre" "${T_ARG[i]}"; then
      T_STATE[i]=skip T_INFO[i]="skipped"
      ((UI_ACTIVE)) || warn "${T_LABEL[i]}: skipped"
      continue
    fi
    T_STATE[i]=run
    out=$(mktemp -p "$SESSION_TMP")
    if ((UI_ACTIVE)); then
      ("${T_FN[i]}" "${T_ARG[i]}") >"$out" 2>&1 </dev/null &
      pid=$!
      while kill -0 "$pid" 2>/dev/null; do draw_runner "$title" "$out"; read_key 0.1; done
      wait "$pid"; rc=$?
    else
      printf '  %s→%s %s\n' "$CYAN" "$NC" "${T_LABEL[i]}"
      "${T_FN[i]}" "${T_ARG[i]}" >"$out" 2>&1 </dev/null; rc=$?
      grep -F '[dry-run]' "$out"
    fi
    if ((rc == 0)); then T_STATE[i]=ok; else T_STATE[i]=fail T_INFO[i]="failed (exit $rc) — see log"; fi
    declare -F "${T_FN[i]}_post" >/dev/null && "${T_FN[i]}_post" "${T_ARG[i]}" "$rc" "$i" "$out"
    [[ ${T_STATE[i]} == ok && -z ${T_INFO[i]} ]] && T_INFO[i]="done"
    if ((!UI_ACTIVE)); then
      if ((rc == 0)); then ok "${T_INFO[i]}"; else err "${T_INFO[i]}"; tail -n 5 "$out" | sed 's/^/    /'; fi
    fi
    { printf '━━ %s — exit %d\n' "${T_LABEL[i]}" "$rc"; grep -v '^@@' "$out"; printf '\n'; } >>"$RUN_LOG"
    rm -f "$out"
  done
  [[ -n $keepalive ]] && kill_tree "$keepalive"
  T_CUR=-1
  RUN_MS=$(($(now_ms) - RUN_T0))
  return 0
}

run_counts() { # → RC_OK RC_SKIP RC_FAIL
  local s
  RC_OK=0 RC_SKIP=0 RC_FAIL=0
  for s in "${T_STATE[@]}"; do
    case $s in ok) ((++RC_OK)) ;; skip) ((++RC_SKIP)) ;; fail) ((++RC_FAIL)) ;; esac
  done
}

results_top() {
  local head
  run_counts
  if [[ $RUN_KIND == clean && ${SCAN_CATS[*]} == privacy ]]; then
    if ((DRY_RUN)); then head="${MAGENTA}${BOLD}$(plural "$RC_OK" list) would be cleared${NC} ${DIM}(dry run)${NC}"
    else head="${GREEN}${BOLD}🔒 $(plural "$RC_OK" "history list") cleared${NC}"; fi
  elif [[ $RUN_KIND == clean ]]; then
    if ((DRY_RUN)); then head="${MAGENTA}${BOLD}$(human "$RUN_FREED") would be freed${NC} ${DIM}(dry run)${NC}"
    else head="${GREEN}${BOLD}🎉 $(human "$RUN_FREED") freed${NC}"; fi
  elif ((RC_FAIL)); then head="${YELLOW}${BOLD}! Finished with $(plural "$RC_FAIL" error)${NC}"
  else head="${GREEN}${BOLD}✔ All done${NC}"; fi
  fl ""
  if [[ $RUN_KIND == clean && ${SCAN_CATS[*]} != privacy ]] && ((!DRY_RUN)); then
    fl_card "$head" "${DIM}$RC_OK done · $RC_SKIP skipped · $RC_FAIL failed · took $((RUN_MS / 1000)).$((RUN_MS % 1000 / 100))s${NC}" \
      "${DIM}Free space $(human "$RUN_AVAIL0") → ${NC}${BOLD}$(human "$RUN_AVAIL1")${NC}"
  else
    fl_card "$head" "${DIM}$RC_OK done · $RC_SKIP skipped · $RC_FAIL failed · took $((RUN_MS / 1000)).$((RUN_MS % 1000 / 100))s${NC}"
  fi
  fl ""
}

result_row() {
  local i=$1 icon lbl
  fitv lbl "${T_LABEL[i]}" 38
  case ${T_STATE[i]} in
    ok) icon="${GREEN}✔${NC}" ;; skip) icon="${YELLOW}–${NC}" ;; fail) icon="${RED}✘${NC}" ;; *) icon="${DIM}○${NC}" ;;
  esac
  fl "   $icon  $lbl  ${DIM}${T_INFO[i]}${NC}"
}

show_run_results() { # TITLE
  if ((!UI_ACTIVE)); then
    run_counts
    if [[ $RUN_KIND == clean ]]; then
      printf '\n  %s%s🎉 Total %s: %s%s\n' "$BOLD" "$GREEN" "$( ((DRY_RUN)) && echo "that would be freed" || echo freed)" "$(human "$RUN_FREED")" "$NC"
      ((DRY_RUN)) || printf '  %sFree space: %s → %s%s\n' "$DIM" "$(human "$RUN_AVAIL0")" "$(human "$RUN_AVAIL1")" "$NC"
    fi
    printf '  %s%d done · %d skipped · %d failed — output in %s%s\n' "$DIM" "$RC_OK" "$RC_SKIP" "$RC_FAIL" "$RUN_LOG" "$NC"
    return
  fi
  L_SCROLL=0
  while :; do
    L_TITLE=$1 L_TOP=results_top L_BOTTOM="" L_ROW=result_row L_FOCUSABLE="" L_VIEW=1 L_COUNT=${#T_LABEL[@]}
    hints l "output log" "!enter" "done"
    L_HINTS=$HINTS
    ui_list
    case $KEY in
      l) mapfile -t V_LINES <"$RUN_LOG"; ((${#V_LINES[@]})) || V_LINES=("  (no output)"); ui_view "Output log" ;;
      enter | q | esc | left | backspace) L_VIEW=0; return ;;
    esac
  done
}

# ── cleanup tasks ──

task_clean_pre() { declare -F "precheck_$1" >/dev/null || return 0; "precheck_$1"; }

task_clean() { # clean, then re-measure so the parent can compute what was freed
  local rc src
  "clean_$1"; rc=$?
  if ((rc == 0 && !DRY_RUN)); then
    SCAN_BYTES=0 SCAN_NOTE=""
    "scan_$1" >/dev/null 2>&1; src=$?
    printf '\n@@scan\t%s\t%s\t%s\n' "$src" "${SCAN_BYTES:-0}" "$SCAN_NOTE"
  fi
  return "$rc"
}

task_clean_post() { # ID RC IDX OUTFILE
  local id=$1 i=$3 before=${RES_BYTES[$1]} freed src bytes note line
  while IFS= read -r line; do CLEAN_UNDO+=("${line#@@undo$'\t'}"); done < <(grep '^@@undo' "$4") # what went to the Trash
  (($2 == 0)) || return 0
  if [[ ${ITEM_CAT[$id]} == privacy ]]; then
    T_INFO[i]=$( ((DRY_RUN)) && echo "would be cleared" || echo "cleared")
    ((DRY_RUN)) || RES_RC[$id]=2 SEL[$id]=0 RES_NOTE[$id]=""
    return 0
  fi
  if ((DRY_RUN)); then
    freed=$before
    T_INFO[i]="$(human "$freed") would be freed"
    ((freed == 0)) && T_INFO[i]="would be cleaned"
  else
    IFS=$'\t' read -r _ src bytes note < <(grep '^@@scan' "$4" | tail -n 1)
    bytes=${bytes:-0}
    freed=$((before - bytes)); ((freed < 0)) && freed=0
    [[ ${src:-1} == 0 ]] || src=2
    RES_BYTES[$id]=$bytes RES_NOTE[$id]=$note RES_RC[$id]=$src RES_HUMAN[$id]=$(human "$bytes") SEL[$id]=0
    T_INFO[i]="$(human "$freed") freed"
    ((freed == 0 && before == 0)) && T_INFO[i]="cleaned"
  fi
  RUN_FREED=$((RUN_FREED + freed))
}

start_cleanup() { # cleans the selected SCANNED items; returns 1 if nothing ran
  local id ids=() keep=() needs_root=0 needs_root_hint=0
  found_total
  for id in "${SCANNED[@]}"; do ((SEL[$id])) && ids+=("$id"); done
  for id in "${ids[@]}"; do [[ -n ${ITEM_ROOT[$id]} ]] && needs_root_hint=1; done
  if ((${#ids[@]} == 0)); then
    if ((UI_ACTIVE)); then toast "${YELLOW}!${NC} Nothing selected — press space to select items."
    else warn "Nothing selected."; fi
    return 1
  fi
  local lbl line
  CONFIRM_LINES=()
  for id in "${ids[@]}"; do # what exactly will happen, shown in the dialog
    fitv lbl "${ITEM_LABEL[$id]}" 34
    if [[ ${ITEM_CAT[$id]} == privacy ]]; then line="• $lbl"
    else printf -v line '• %s %10s' "$lbl" "${RES_HUMAN[$id]}"; fi
    [[ -n ${ITEM_ROOT[$id]} ]] && line+=" ⚿"
    CONFIRM_LINES+=("$line")
  done
  if [[ ${SCAN_CATS[*]} == privacy ]]; then
    ui_confirm "Clear $(plural ${#ids[@]} "history list")?" "This can't be undone." y || return 1
  else
    ui_confirm "Clean $(plural ${#ids[@]} item)?" "About $(human "$SELECTED_TOTAL") will be removed.$( ((needs_root_hint)) && echo " ⚿ = needs sudo")" y || return 1
  fi
  for id in "${ids[@]}"; do [[ -n ${ITEM_ROOT[$id]} ]] && needs_root=1; done
  if ((needs_root)) && ! ensure_sudo "System items need administrator rights to clean."; then
    for id in "${ids[@]}"; do [[ -n ${ITEM_ROOT[$id]} ]] || keep+=("$id"); done
    ids=("${keep[@]}")
    toast "${YELLOW}!${NC} No sudo — system items were skipped."
    ((${#ids[@]})) || return 1
  fi

  new_tasks clean
  for id in "${ids[@]}"; do add_task "${ITEM_LABEL[$id]}" task_clean "$id"; done
  RUN_AVAIL0=$(fs_avail)
  CLEAN_UNDO=()
  run_tasks "Cleaning"
  ((${#CLEAN_UNDO[@]})) && UNDO_BATCH=("${CLEAN_UNDO[@]}") # z on the home screen puts them back
  RUN_AVAIL1=$(fs_avail)
  save_scan_cache
  record_disk_usage
  ((DRY_RUN)) || record_cleanup "$RUN_FREED"
  log "Cleanup finished — $(human "$RUN_FREED") freed (dry-run=$DRY_RUN)"
  refresh_sysinfo
  show_run_results "Cleanup complete"
  return 0
}

scan_report() { # --scan
  printf '%sCleanMate — scan report%s\n\n' "$BOLD" "$NC"
  scan_items "${CATEGORIES[@]}"
  plain_results
  found_total
  printf '\n  %s●%s = cleaned by --clean (%s)\n' "$GREEN" "$NC" "$(human "$SELECTED_TOTAL")"
}

smart_clean() { # --clean
  printf '%sCleanMate — smart clean%s\n\n' "$BOLD" "$NC"
  scan_items "${CATEGORIES[@]}"
  plain_results
  printf '\n'
  if [[ ! -t 0 ]] && ((!ASSUME_YES)); then
    err "Not a terminal: add --yes to clean without confirmation."; exit 1
  fi
  start_cleanup
}

# ───────────────────────────── large & old files ────────────────────────────

declare -A F_SEL=()

file_row() {
  local b d p mark="  " box lbl clr pw
  IFS=$'\t' read -r b d p <<<"${FOUND[$1]}"
  p=${p/#$HOME/\~}
  pw=$((UI_W - 30))
  ((${#p} > pw)) && p="…${p: -$((pw - 1))}"
  (($2)) && mark="${ACCENT}▸${NC} " p="${BOLD}$p${NC}"
  if [[ -n ${F_SEL[$1]} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  size_colorv clr "$b"
  humanv lbl "$b"; printf -v lbl '%9s' "$lbl"
  fl " $mark$box $clr$lbl$NC  ${DIM}$d${NC}  $p"
}

files_bottom() {
  local i n=0 tot=0 b d p
  for i in "${!F_SEL[@]}"; do IFS=$'\t' read -r b _ <<<"${FOUND[i]}"; tot=$((tot + b)); ((++n)); done
  IFS=$'\t' read -r b d p <<<"${FOUND[$L_CUR]}"
  fl ""
  local fn ft; pluralv fn "$n" "$PICK_NOUN"; humanv ft "$tot"
  fl "  ${BOLD}Selected${NC} $fn · ${BOLD}$ft${NC}"
  fl "  ${ACCENT}ℹ${NC} ${DIM}${p/#$HOME/\~}${NC}"
}

file_text() { TEXT=${FOUND[$1]##*$'\t'}; }
files_top() { fl ""; fl "  ${BOLD}$(plural ${#FOUND[@]} "$PICK_NOUN")${NC} ${DIM}— biggest first${NC}"; fl ""; }
PICK_NOUN="file" # what pick_files lists

pick_files() { # TITLE — FOUND holds "bytes<TAB>date<TAB>path"
  local title=$1 i b d p keep=() n tot cur=0 scroll=0
  F_SEL=()
  if ((${#FOUND[@]} == 0)); then toast "${GREEN}✔${NC} No matching ${PICK_NOUN}s found."; return; fi
  while :; do
    ((${#FOUND[@]} || ${#UNDO_BATCH[@]})) || return # stay while there's something to undo
    L_TITLE=$title L_TOP=files_top L_BOTTOM=files_bottom L_ROW=file_row L_FOCUSABLE="" L_TEXT=file_text
    L_VIEW=0 L_COUNT=${#FOUND[@]} L_CUR=$cur L_SCROLL=$scroll
    if ((${#UNDO_BATCH[@]})); then hints space select "!t" "move to Trash" z undo o "open folder" q back a all n none
    else hints space select "!t" "move to Trash" o "open folder" q back a all n none; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL
    case $KEY in
      space) if [[ -n ${F_SEL[$cur]} ]]; then unset "F_SEL[$cur]"; else F_SEL[$cur]=1; fi; list_move 1; cur=$L_CUR ;;
      a) for i in "${!FOUND[@]}"; do F_SEL[$i]=1; done ;;
      n) F_SEL=() ;;
      o)
        IFS=$'\t' read -r b d p <<<"${FOUND[cur]}"
        xdg-open "$(dirname "$p")" >/dev/null 2>&1 &
        disown 2>/dev/null
        toast "${ACCENT}↗${NC} Opened $(dirname "${p/#$HOME/\~}")" ;;
      t | delete)
        ((${#F_SEL[@]})) || F_SEL[$cur]=1
        n=0 tot=0
        for i in "${!F_SEL[@]}"; do IFS=$'\t' read -r b _ <<<"${FOUND[i]}"; tot=$((tot + b)); ((++n)); done
        ui_confirm "Move $(plural "$n" "$PICK_NOUN") to Trash?" "$(human "$tot") — press z to undo." y || continue
        keep=() FOUND_TRASHED=() UNDO_BATCH=()
        for i in "${!FOUND[@]}"; do
          IFS=$'\t' read -r b d p <<<"${FOUND[i]}"
          if [[ -n ${F_SEL[$i]} ]]; then
            if move_to_trash "$p" >/dev/null 2>&1; then FOUND_TRASHED+=("${FOUND[i]}"); else keep+=("${FOUND[i]}"); fi
          else keep+=("${FOUND[i]}"); fi
        done
        if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural "$n" "$PICK_NOUN") ($(human "$tot")) to Trash"
        else FOUND=("${keep[@]}"); toast "${GREEN}✔${NC} Moved $(plural "$n" "$PICK_NOUN") ($(human "$tot")) to Trash — press z to undo"; refresh_sysinfo; fi
        F_SEL=() ;;
      z)
        ((${#UNDO_BATCH[@]})) || continue
        undo_trash
        mapfile -t FOUND < <(printf '%s\n' "${FOUND[@]}" "${FOUND_TRASHED[@]}" | grep -v '^$' | sort -t$'\t' -k1,1rn)
        FOUND_TRASHED=() F_SEL=()
        refresh_sysinfo; undo_toast ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

find_files_bg() { # MESSAGE START... FIND-ARGS... — run find in the background with a spinner; skips excluded folders
  local msg=$1 tmp starts=()
  shift
  while (($#)) && [[ $1 != -* ]]; do starts+=("$1"); shift; done
  outside_exclusions starts "${starts[@]}"
  exclusion_prune
  FOUND=()
  ((${#starts[@]})) || return 0 # every folder is excluded: nothing to show
  tmp=$(mktemp -p "$SESSION_TMP")
  [[ ${1:-} == -xdev ]] && { XPRUNE=(-xdev "${XPRUNE[@]}"); shift; } # an option goes before the tests
  (find "${starts[@]}" "${XPRUNE[@]}" "$@" -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null >"$tmp") &
  UI_BUSY_TITLE="Large & Old Files"
  ui_busy "$msg" $! "$tmp" file || { rm -f "$tmp"; return 1; }
  mapfile -t FOUND < <(sort -t$'\t' -k1,1rn "$tmp" | head -n 200)
  rm -f "$tmp"
}

find_large() { # DIR MB
  find_files_bg "Looking for files over $2 MB in ${1/#$HOME/\~}…" "$1" -xdev -type f -size +"$2"M \
    -not -path '*/.cache/*' -not -path '*/Trash/*' -not -path '*/.git/*' || return
  pick_files "Files over $2 MB"
}

VM_DISK_NAMES=(-iname '*.vdi' -o -iname '*.vmdk' -o -iname '*.qcow2' -o -iname '*.vhd' -o -iname '*.vhdx')
find_vm_disks() { # your VM disks, plus the system libvirt/Multipass stores when they're readable
  local roots=("$HOME") d
  for d in /var/lib/libvirt/images /var/snap/multipass/common/data/multipassd/vault/instances; do
    [[ -r $d && -x $d ]] && roots+=("$d")
  done
  find_files_bg "Looking for virtual machine disks…" "${roots[@]}" -xdev -type f \( "${VM_DISK_NAMES[@]}" \) \
    -size +1M -not -path '*/Trash/*'
}

large_files_menu() {
  local dir min dl
  dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")
  while :; do
    M_KEY=(1 2 3 4 5)
    M_LABEL=("Large files" "Huge files" "Old downloads" "Virtual machine disks" "Custom search…")
    M_DESC=("Files over 100 MB in your home folder" "Files over 1 GB in your home folder"
      "Files in ${dl/#$HOME/\~} untouched for 90+ days" "VirtualBox, VMware, GNOME Boxes, virt-manager and Multipass disks"
      "Choose a folder and a minimum size")
    ui_menu "Large & Old Files" || return
    case $MENU_IDX in
      0) find_large "$HOME" 100 ;;
      1) find_large "$HOME" 1024 ;;
      2)
        [[ -d $dl ]] || { toast "${RED}✘${NC} Downloads folder not found."; continue; }
        find_files_bg "Looking for old downloads…" "$dl" -type f -mtime +90 || continue
        pick_files "Downloads older than 90 days" ;;
      3)
        find_vm_disks || continue
        pick_files "Virtual machine disks — delete the VM in its app when you can" ;;
      4)
        ui_input "Folder to search:" "$HOME" || continue
        dir=${REPLY_TEXT/#\~/$HOME}
        [[ -d $dir ]] || { toast "${RED}✘${NC} Not a folder: $dir"; continue; }
        ui_input "Minimum size in MB:" 100 || continue
        min=$REPLY_TEXT
        [[ $min =~ ^[0-9]+$ ]] || { toast "${RED}✘${NC} Invalid size: $min"; continue; }
        find_large "$dir" "$min" ;;
    esac
  done
}

# ───────────────────────────── uninstaller ──────────────────────────────────

declare -a U_SRC=() U_ID=() U_SIZE=()
declare -A U_SEL=()

app_search() { # QUERY → U_SRC U_ID U_SIZE
  local q=${1,,} id size name
  U_SRC=() U_ID=() U_SIZE=() U_SEL=()
  if have snap; then
    while read -r id; do
      U_SRC+=("snap") U_ID+=("$id") U_SIZE+=("$(du_sum /var/lib/snapd/snaps/"${id}"_*.snap)")
    done < <(snap list 2>/dev/null | awk -v q="$q" 'NR > 1 && index(tolower($1), q) {print $1}')
  fi
  if have flatpak; then
    while IFS=$'\t' read -r id name size; do
      U_SRC+=("flatpak") U_ID+=("$id") U_SIZE+=("$(si_to_bytes "${size// /}")")
    done < <(flatpak list --app --columns=application,name,size 2>/dev/null |
      awk -F'\t' -v q="$q" 'index(tolower($1), q) || index(tolower($2), q)')
  fi
  if have dpkg-query; then
    declare -A manual=()
    while read -r id; do manual[$id]=1; done < <(apt-mark showmanual 2>/dev/null)
    while IFS=$'\t' read -r id size; do
      U_SRC+=("apt$([[ -n ${manual[$id]} ]] || echo "*")") U_ID+=("$id") U_SIZE+=("$((size * 1024))")
    done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Installed-Size}\n' 2>/dev/null |
      awk -F'\t' -v q="$q" '$1 ~ /^ii/ && index(tolower($2), q) {print $2 "\t" ($3 + 0)}' |
      while IFS=$'\t' read -r id size; do printf '%d\t%s\t%s\n' "$([[ -n ${manual[$id]} ]] && echo 0 || echo 1)" "$id" "$size"; done |
      sort -t$'\t' -k1,1n -k2,2 | cut -f2- | head -n 60) # apps you installed first, then dependencies
  fi
}

app_row() {
  local i=$1 mark="  " box src lbl sz c
  (($2)) && mark="${ACCENT}▸${NC} "
  if [[ -n ${U_SEL[$i]} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  case ${U_SRC[i]} in snap) c=$MAGENTA ;; flatpak) c=$BLUE ;; *) c=$CYAN ;; esac
  fitv src "${U_SRC[i]}" 8
  fitv lbl "${U_ID[i]}" $((UI_W - 30))
  (($2)) && lbl="${BOLD}$lbl${NC}"
  if ((U_SIZE[i] > 0)); then humanv sz "${U_SIZE[i]}"; printf -v sz '%9s' "$sz"; else printf -v sz '%9s' "—"; fi
  fl " $mark$box $c$src$NC $lbl $sz"
}

app_text() { TEXT=${U_ID[$1]}; }
apps_top() { fl ""; fl "  ${BOLD}$(plural ${#U_ID[@]} app)${NC} ${DIM}matching “$APP_QUERY”${NC}"; fl ""; }

apps_bottom() {
  fl ""
  fl "  ${BOLD}Selected${NC} $(plural ${#U_SEL[@]} app)   ${DIM}apt* = installed automatically as a dependency${NC}"
}

# Folders that hold personal data even though they share a package's name.
LEFTOVER_DENY='^(ssh|openssh.*|gnupg.*|gpg.*|git|pki|mozilla|thunderbird|evolution|keyrings|systemd|dconf|autostart|applications|fonts|icons|themes|bash|zsh|fish|vim|nvim|neovim|emacs|steam|flatpak|containers|trash|pulse|pipewire|gtk-.*|gnome-shell|nautilus|recently-used.*|user-dirs.*|mime.*|menus)$'

find_leftovers() { # NAME... → LEFTOVERS
  local n p
  LEFTOVERS=()
  for n in "$@"; do
    [[ ${n,,} =~ $LEFTOVER_DENY ]] && continue
    for p in "$HOME/.config/$n" "$HOME/.local/share/$n" "$HOME/.cache/$n" "$HOME/.var/app/$n"; do
      [[ -e $p && ! -L $p ]] && ! is_protected "$p" && LEFTOVERS+=("$p")
    done
  done
}

task_uninstall() { # SRC:ID[:INDEX]
  local src=${1%%:*} id=${1#*:}
  id=${id%%:*}
  case $src in
    apt*) uninstall_batch apt "$id" ;;
    snap) uninstall_batch snap "$id" ;;
    flatpak) run flatpak uninstall -y --noninteractive --delete-data "$id" ;;
    appimage) # to the Trash, as you; @@undo lines let the terminal app put it back
      ((EUID != 0)) || { err "AppImage apps are removed as you, not as root"; return 1; }
      local file rc e
      urldecode_path file "$id"
      UNDO_BATCH=()
      appimage_remove "$file"; rc=$?
      for e in "${UNDO_BATCH[@]}"; do printf '@@undo\t%s\n' "$e"; done
      return "$rc" ;;
  esac
}

task_uninstall_post() { # SRC:ID RC IDX OUTFILE — what went to the Trash, for z on the home screen
  local line
  while IFS= read -r line; do APP_UNDO+=("${line#@@undo$'\t'}"); done < <(grep '^@@undo' "$4")
  return 0
}

uninstall_batch() { # apt|snap ID… — one command removes them all (needs root)
  local src=$1
  shift
  case $src in
    apt) run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" ;;
    snap) run_root snap remove --purge "$@" ;;
  esac
}

app_installed() { # SRC ID → still installed? (after a removal that failed, some apps of the batch may be gone)
  local s
  case $1 in
    apt) s=$(dpkg-query -W -f='${db:Status-Abbrev}' "$2" 2>/dev/null) && [[ $s =~ ^.[^nc] ]] ;;
    snap) snap list "$2" >/dev/null 2>&1 ;;
    flatpak) flatpak info "$2" >/dev/null 2>&1 ;;
    appimage) urldecode_path s "$2"; [[ -e $s ]] ;;
    *) return 1 ;;
  esac
}

# Removing an app while it runs can lose what is open in it, so a running app
# is skipped. Flatpak says which apps run (`flatpak ps`); a snap's processes
# sit in its own cgroups (snap.NAME.APP-….scope); an apt app runs a file of
# its package, or a command it ships under that name (a script); an AppImage
# runs as a process whose program (or first argument) is that file.
PROC_DIR=${CLEANMATE_PROC:-/proc} # tests: a fake process table
app_running() { # SRC ID → the name of its running program; fails when none runs
  local src=$1 id=$2 files f re c a
  case $src in
    appimage)
      urldecode_path f "$id"
      if [[ -z $(find "$PROC_DIR"/[0-9]*/exe -maxdepth 0 -printf '%l\n' 2>/dev/null | grep -m1 -xF -- "$f") ]]; then
        for c in "$PROC_DIR"/[0-9]*/cmdline; do
          a=""; [[ -r $c ]] && IFS= read -r -d '' a <"$c" 2>/dev/null
          [[ $a == "$f" ]] && break
        done
        [[ $a == "$f" ]] || return 1
      fi
      printf '%s\n' "${f##*/}" ;;
    flatpak)
      have flatpak && flatpak ps --columns=application 2>/dev/null | grep -qxF -- "$id" || return 1
      printf '%s\n' "$id" ;;
    snap)
      f=$(grep -lsE "(^|/)snap\.${id//./\\.}\.[^/]+\.(scope|service)\$" "$PROC_DIR"/[0-9]*/cgroup 2>/dev/null | head -n 1)
      [[ -n $f ]] || return 1
      f=$(head -c 64 "${f%/cgroup}/comm" 2>/dev/null)
      printf '%s\n' "${f:-$id}" ;;
    apt)
      have dpkg && files=$(dpkg -L "$id" 2>/dev/null | grep '^/') && [[ -n $files ]] || return 1
      f=$(find "$PROC_DIR"/[0-9]*/exe -maxdepth 0 -printf '%l\n' 2>/dev/null | grep -m1 -xF -f <(printf '%s\n' "$files"))
      [[ -n $f ]] && { printf '%s\n' "${f##*/}"; return 0; }
      re=$(grep -E '^/(usr/)?(s?bin|games)/[^/]+$' <<<"$files" | sed 's|.*/||; s/^\(.\{15\}\).*/\1/; s/[][\.*^$+?(){}|]/\\&/g' |
        sort -u | paste -sd'|' -) # the kernel keeps 15 characters of a program's name
      [[ -n $re ]] && running_proc -x "($re)" ;;
    *) return 1 ;;
  esac
}

uninstall_selected() {
  local i apt_pkgs=() names=() needs_root=0 extra=0 body p tot=0
  for i in "${!U_SEL[@]}"; do
    names+=("${U_ID[i]}")
    [[ ${U_SRC[i]} == apt* ]] && apt_pkgs+=("${U_ID[i]}")
    [[ ${U_SRC[i]} != flatpak ]] && needs_root=1
  done
  local title sim others
  body=$(printf '%s, ' "${names[@]}"); body=${body%, }
  title="Uninstall $(plural ${#names[@]} app)?"
  if ((${#apt_pkgs[@]})); then # simulate first: apt may refuse, or take other packages with it
    apt_check_removal "${apt_pkgs[@]}" || return
    if ((APT_EXTRA_N)); then
      title="⚠ Also removes $(plural "$APT_EXTRA_N" "other package")! Continue?"
      body=$APT_EXTRA_TEXT
    fi
  fi
  ui_confirm "$title" "$body" n || return
  ((needs_root)) && { ensure_sudo "Removing system packages needs administrator rights." || return; }
  new_tasks
  for i in "${!U_SEL[@]}"; do add_task "Uninstall ${U_ID[i]} (${U_SRC[i]%\*})" task_uninstall "${U_SRC[i]}:${U_ID[i]}"; done
  run_tasks "Uninstalling"
  refresh_sysinfo
  show_run_results "Uninstall complete"

  local removed=()
  for i in "${!T_STATE[@]}"; do # leftovers only for apps that were really removed
    [[ ${T_STATE[i]} == ok ]] && removed+=("${T_ARG[i]#*:}")
  done
  ((${#removed[@]})) && find_leftovers "${removed[@]}" || LEFTOVERS=()
  if ((${#LEFTOVERS[@]})); then
    for p in "${LEFTOVERS[@]}"; do tot=$((tot + $(du_sum "$p"))); done
    body=$(printf '%s, ' "${LEFTOVERS[@]/#$HOME/\~}"); body=${body%, }
    if ui_confirm "Trash $(plural ${#LEFTOVERS[@]} "leftover folder") ($(human "$tot"))?" "$body" n; then
      UNDO_BATCH=()
      for p in "${LEFTOVERS[@]}"; do move_to_trash "$p" >/dev/null 2>&1; done
      if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural ${#LEFTOVERS[@]} "leftover folder") to Trash"
      else toast "${GREEN}✔${NC} Moved $(plural ${#LEFTOVERS[@]} "leftover folder") to Trash"; fi
    fi
  fi
  U_SEL=()
  app_search "$APP_QUERY"
}

uninstaller_menu() { apps_menu; }

leftovers_menu() { # A_LEFT, none ticked: to the Trash, z puts them back
  local e kind b p PICK_NOUN=folder
  FOUND=()
  for e in "${A_LEFT[@]}"; do
    IFS=$'\t' read -r kind b p <<<"$e"
    case $kind in flatpak) kind="Flatpak   " ;; snap) kind="Snap      " ;; *) kind="no app    " ;; esac
    FOUND+=("$b"$'\t'"$kind"$'\t'"$p")
  done
  toast "${DIM}Folders no installed app uses. Nothing is ticked; the Trash keeps them until you empty it.${NC}"
  pick_files "Leftovers of removed apps"
}

pkg_search_menu() { # every installed package, libraries and command-line tools included
  local cur scroll
  while :; do
    frame_begin; draw_header "Uninstaller — all packages"; fl ""
    fl "  ${BOLD}Search every installed package${NC} ${DIM}— apt, snap and flatpak, libraries included${NC}"
    fl ""
    fl "  ${DIM}Type part of a name, e.g. “gimp”, “vlc” or “zoom”. Leave empty to go back.${NC}"
    draw_footer "$(hints enter search; echo "$HINTS")"; frame_flush
    ui_input "Search:" || return
    APP_QUERY=$REPLY_TEXT
    app_search "$APP_QUERY"
    if ((${#U_ID[@]} == 0)); then toast "${YELLOW}!${NC} No installed app matches “$APP_QUERY”."; continue; fi
    cur=0 scroll=0
    while :; do
      ((${#U_ID[@]})) || break
      L_TITLE="Uninstaller — all packages" L_TOP=apps_top L_BOTTOM=apps_bottom L_ROW=app_row L_FOCUSABLE="" L_TEXT=app_text
      L_VIEW=0 L_COUNT=${#U_ID[@]} L_CUR=$cur L_SCROLL=$scroll
      hints space select "!u" uninstall / "new search" q back "↑↓" move
      L_HINTS=$HINTS
      ui_list
      cur=$L_CUR scroll=$L_SCROLL
      case $KEY in
        space) if [[ -n ${U_SEL[$cur]} ]]; then unset "U_SEL[$cur]"; else U_SEL[$cur]=1; fi; list_move 1; cur=$L_CUR ;;
        u | enter)
          ((${#U_SEL[@]})) || U_SEL[$cur]=1
          uninstall_selected ;;
        / | q | esc | left | backspace) break ;;
      esac
    done
  done
}

# ── App list: real apps (from their launchers), not packages ──
#
# Built from .desktop files, so libraries, drivers and services never show up.
# Each app gets its owner (apt package, snap or flatpak), its package size, the
# folders it keeps in your home and when you last used it. Parts of Ubuntu
# itself (essential/required packages and what the desktop meta-package
# depends on) are left out.

APPS_DIR_USER=${XDG_DATA_HOME:-$HOME/.local/share}
APP_DESKTOP_DIRS=("$APPS_DIR_USER/applications" "$APPS_DIR_USER/flatpak/exports/share/applications"
  /var/lib/flatpak/exports/share/applications /var/lib/snapd/desktop/applications
  /usr/local/share/applications /usr/share/applications) # earlier folders override later ones
[[ -n ${CLEANMATE_APP_DIRS:-} ]] && IFS=: read -ra APP_DESKTOP_DIRS <<<"$CLEANMATE_APP_DIRS" # tests: other launchers
# never offered: removing these breaks the desktop, logins or package management
APP_CORE_RE='^(gnome-shell|gnome-shell-common|gdm3|gnome-session.*|ubuntu-session|systemd|systemd-sysv|sudo|apt|dpkg|network-manager|xserver-xorg-core|xwayland|snapd|polkitd|pkexec|policykit-1|plymouth|grub.*|shim.*|linux-image-.*|linux-generic.*)$'
APP_META_RE='^(ubuntu-desktop.*|ubuntu-minimal|ubuntu-standard|ubuntu-server|[a-z]+ubuntu-desktop|ubuntu-[a-z]+-desktop)$'
APP_EXEC_SKIP='^(env|sh|bash|dash|flatpak|snap|run|gtk-launch|gapplication|python3?|perl|java|exo-open|xdg-open|pkexec|sudo|wine|steam)$'
GNOME_APP_STATE=$APPS_DIR_USER/gnome-shell/application_state
APP_UNUSED_DAYS=90 APP_LARGE_MB=500

desktop_entries() { # → file name exec hidden snap flatpak (separated by \x1f: fields may be empty), per launcher
  local d files=()
  for d in "${APP_DESKTOP_DIRS[@]}"; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do [[ -f $f ]] && files+=("$f"); done
  done
  ((${#files[@]})) || return 0
  awk -v OFS=$'\x1f' '
    function out() { if (typ == "Application") print f, name, ex, hid, snap, fp }
    FNR == 1 { if (f != "") out(); f = FILENAME; sec = ""; name = ""; ex = ""; hid = 0; typ = ""; snap = ""; fp = "" }
    { sub(/\r$/, "") }
    /^\[/ { sec = $0; next }
    sec == "[Desktop Entry]" {
      if ($0 ~ /^Name=/ && name == "") name = substr($0, 6)
      else if ($0 ~ /^Exec=/ && ex == "") ex = substr($0, 6)
      else if ($0 ~ /^(NoDisplay|Hidden)=true/) hid = 1
      else if ($0 ~ /^Type=/) typ = substr($0, 6)
      else if ($0 ~ /^X-SnapInstanceName=/) snap = substr($0, 20)
      else if ($0 ~ /^X-Flatpak=/) fp = substr($0, 11)
    }
    END { if (f != "") out() }' "${files[@]}" 2>/dev/null
}

exec_name() { # Exec= line → the program's name (skipping env, flatpak run, …)
  local w
  for w in $1; do
    w=${w//\"/}; w=${w//\'/}
    [[ $w == *=* || $w == -* || $w == %* ]] && continue
    w=${w##*/}
    [[ ${w,,} =~ $APP_EXEC_SKIP ]] && continue
    printf '%s' "$w"; return
  done
}

# ── AppImage apps ──
#
# An AppImage is a single program file; a launcher in your own applications
# folder (made by hand, AppImageLauncher or Gear Lever) turns it into an app.
# Such an app is listed with kind "appimage" and ID = the file's path
# (urlencoded). Uninstalling moves the file, its launchers and the icons only
# they use (in ~/.local/share/icons, hicolor or the top) to the Trash, as you,
# so Restore puts it all back. AppImages without a launcher (in Downloads)
# belong to Old installers.

is_appimage() { # FILE → named *.AppImage, or an ELF program that says it is one
  local hex
  [[ ${1,,} == *.appimage ]] && return 0
  hex=$(head -c 11 -- "$1" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  [[ $hex == 7f454c46* ]] || return 1
  [[ ${hex:16:4} == 4149 ]] && return 0 # "AI" at byte 8: the AppImage magic (types 1 and 2)
  (($(LC_ALL=C head -c 4096 -- "$1" 2>/dev/null | grep -ac AppImage) > 0))
}

appimage_file() { # Exec= line → the AppImage file in your home it runs; fails when it runs anything else
  local cmd=$1 w
  while :; do
    cmd=${cmd#"${cmd%%[! ]*}"}
    [[ -n $cmd ]] || return 1
    if [[ $cmd == \"* ]]; then w=${cmd#\"} && w=${w%%\"*} && cmd=${cmd#\"*\"}
    else w=${cmd%% *} && cmd=${cmd#"$w"}; fi
    [[ $w == env || $w == *=* || $w == -* ]] || break # env VAR=1 /path/App.AppImage
  done
  [[ $w == "$HOME"/* && -f $w && ! -L $w && $(realpath -e -- "$w" 2>/dev/null) == "$w" ]] || return 1
  is_appimage "$w" || return 1
  printf '%s\n' "$w"
}

appimage_names() { # FILE NAME LAUNCHER → names its folders in your home may have (letters, digits, . _ -)
  local stem=${1##*/} desk=${3##*/} wm
  stem=${stem%.[Aa][Pp][Pp][Ii][Mm][Aa][Gg][Ee]}
  desk=${desk%.desktop}; desk=${desk#appimagekit_+([[:xdigit:]])-}
  wm=$(desktop_get "$3" StartupWMClass)
  printf '%s\n' "$stem" "$2" "${2// /-}" "${2// /}" "$desk" "$wm" |
    sed -E 's/[-_ .]+v?[0-9].*$//; s/[-_](x86_64|amd64|x64|aarch64|arm64|linux)$//I; s/[^A-Za-z0-9._-]//g' | sort -u
}

appimage_launchers() { # FILE → the launchers in your applications folder that run it
  local f
  for f in "$APPS_DIR_USER"/applications/*.desktop; do
    [[ -f $f && ! -L $f ]] || continue
    [[ $(appimage_file "$(desktop_get "$f" Exec)") == "$1" ]] && printf '%s\n' "$f"
  done
}

appimage_icons() { # LAUNCHER… → icon files in your icons folder that only these launchers name
  local f icon others=$'\n' dir=$APPS_DIR_USER/icons mine
  mine=$'\n'$(printf '%s\n' "$@")$'\n'
  for f in "$APPS_DIR_USER"/applications/*.desktop; do
    [[ -f $f && $mine != *$'\n'"$f"$'\n'* ]] || continue
    others+=$(desktop_get "$f" Icon)$'\n'
  done
  for f; do
    icon=$(desktop_get "$f" Icon)
    [[ -n $icon && $others != *$'\n'"$icon"$'\n'* ]] || continue # another app shows it too
    if [[ $icon == /* ]]; then
      [[ ($icon == "$dir"/+([!/]) || $icon == "$dir"/hicolor/*) && -f $icon && ! -L $icon ]] && printf '%s\n' "$icon"
    elif [[ $icon =~ ^[A-Za-z0-9._-]+$ && -d $dir ]]; then # a name: the files of that name (icon themes stay)
      find "$dir" -maxdepth 1 -type f \( -name "$icon.png" -o -name "$icon.svg" -o -name "$icon.svgz" -o -name "$icon.xpm" \) 2>/dev/null
      [[ -d $dir/hicolor ]] && find "$dir/hicolor" -path '*/apps/*' -type f \
        \( -name "$icon.png" -o -name "$icon.svg" -o -name "$icon.svgz" -o -name "$icon.xpm" \) 2>/dev/null
    fi
  done | sort -u
}

appimage_remove() { # FILE — the AppImage, then its launchers and their icons go to the Trash (UNDO_BATCH)
  local p rc=0 launchers=() icons=()
  mapfile -t launchers < <(appimage_launchers "$1")
  ((${#launchers[@]})) && mapfile -t icons < <(appimage_icons "${launchers[@]}")
  move_to_trash "$1" || return 1 # the file stays: so do its launchers
  for p in "${launchers[@]}" "${icons[@]}"; do move_to_trash "$p" || rc=1; done
  return "$rc"
}

gnome_last_seen() { # desktop-id<TAB>epoch, from GNOME Shell's own record of app use
  [[ -f $GNOME_APP_STATE ]] || return 0
  grep -o '<application [^>]*>' "$GNOME_APP_STATE" 2>/dev/null |
    sed -n 's/.*id="\([^"]*\)".*last-seen="\([0-9]*\)".*/\1\t\2/p'
}

app_inventory() { # → "#hidden<TAB>N", then src<TAB>id<TAB>name<TAB>pkg_bytes<TAB>data_bytes<TAB>last_used<TAB>launcher id<TAB>paths(\x1f)
  local file name ex hid snap fp base key src id line img
  local -A seen=() a_src=() a_id=() a_name=() a_desk=() a_exec=() owner=() psize=() pskip=() fpsize=() last_seen=() claims=()
  local -a keys=() debfiles=() others=()
  while IFS=$'\x1f' read -r file name ex hid snap fp; do
    base=${file##*/}
    [[ -n ${seen[$base]:-} ]] && continue # a launcher in your own folder overrides the system one
    seen[$base]=1
    img=""
    if ((!hid)) && [[ $file == "$APPS_DIR_USER/applications/"* && -z $fp && -z $snap ]]; then
      img=$(appimage_file "$ex") # your own launcher of an AppImage
    fi
    if [[ -z $img ]] && { ((hid)) || [[ $file == "$APPS_DIR_USER/applications/"* && -z $fp && -z $snap ]]; }; then
      others+=("${base%.desktop}" "$(exec_name "$ex")") # not listed, but its folders aren't "unshared"
      continue
    fi
    if [[ -n $img ]]; then src=appimage id=$(urlencode_path "$img")
    elif [[ -n $fp || $file == */flatpak/exports/* ]]; then src=flatpak id=${fp:-${base%.desktop}}
    elif [[ -n $snap || $file == /var/lib/snapd/desktop/* ]]; then src=snap id=${snap:-${base%%_*}}
    else src=apt id=""; debfiles+=("$file"); fi # if dpkg owns it
    key=$src:${id:-$file}
    if [[ -z ${a_src[$key]:-} ]]; then keys+=("$key"); a_src[$key]=$src a_id[$key]=$id a_name[$key]=$name; fi
    a_desk[$key]+="${base%.desktop}"$'\n'
    [[ $src == apt ]] && a_exec[$key]+="$(exec_name "$ex")"$'\n' # snaps/flatpaks keep their data in ~/snap, ~/.var/app
    [[ $src == appimage ]] && a_exec[$key]+="$(appimage_names "$img" "$name" "$file")"$'\n'
  done < <(desktop_entries)

  # apt: which package owns each launcher; then sizes and what must stay
  if ((${#debfiles[@]})) && have dpkg; then
    while IFS= read -r line; do
      [[ $line == *": /"* ]] || continue
      id=${line%%: /*}; id=${id%%,*}; id=${id%%:*}
      owner[/${line#*: /}]=$id
    done < <(dpkg -S "${debfiles[@]}" 2>/dev/null)
    local -a pkgs=() newkeys=()
    local -A merged=()
    for key in "${keys[@]}"; do
      if [[ ${a_src[$key]} == apt ]]; then
        id=${owner[${key#apt:}]:-}
        if [[ -z $id ]]; then # not a package (a personal launcher): its folders still count as claimed
          mapfile -t -O "${#others[@]}" others <<<"${a_desk[$key]}${a_exec[$key]}"; continue
        fi
        if [[ -n ${merged[$id]:-} ]]; then # several launchers, one package (LibreOffice, …)
          a_desk[${merged[$id]}]+=${a_desk[$key]} a_exec[${merged[$id]}]+=${a_exec[$key]}; continue
        fi
        merged[$id]=$key a_id[$key]=$id; pkgs+=("$id")
      fi
      newkeys+=("$key")
    done
    keys=("${newkeys[@]}")
    if ((${#pkgs[@]})); then
      while IFS=$'\t' read -r id b pri ess; do
        psize[$id]=$((b * 1024))
        [[ $pri == required || $pri == important || $ess == yes ]] && pskip[$id]=1
      done < <(dpkg-query -W -f='${Package}\t${Installed-Size}\t${Priority}\t${Essential}\n' "${pkgs[@]}" 2>/dev/null)
      local metas=()
      mapfile -t metas < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null |
        awk -v re="$APP_META_RE" '$1 ~ /^ii/ && $2 ~ re {print $2}')
      ((${#metas[@]})) && while read -r id; do pskip[$id]=1; done < <(apt-cache depends --installed --no-recommends \
        --no-suggests "${metas[@]}" 2>/dev/null | awk '$1 == "Depends:" {gsub(/[<>]/, "", $2); print $2}')
    fi
  fi
  if have flatpak; then
    while IFS=$'\t' read -r id b; do fpsize[$id]=$(si_to_bytes "${b// /}"); done < <(flatpak list --app --columns=application,size 2>/dev/null)
  fi
  while IFS=$'\t' read -r id b; do last_seen[${id%.desktop}]=$b; done < <(gnome_last_seen)

  # folders each app keeps in your home: by package, launcher and program name (case-insensitive)
  local -A idx=() app_paths=()
  local d e n
  for d in "${XDG_CONFIG_HOME:-$HOME/.config}" "$APPS_DIR_USER" "${XDG_STATE_HOME:-$HOME/.local/state}" "$HOME/.cache"; do
    for e in "$d"/*/; do e=${e%/}; [[ -d $e && ! -L $e ]] && n=${e##*/} && idx[${n,,}]+="$e"$'\n'; done
  done
  local hidden=0 nm p pkgb datab last t
  local -A ubuntu_part=()
  for nm in "${others[@]}"; do # launchers that aren't listed still share folders
    [[ ${#nm} -ge 3 && ! ${nm,,} =~ $LEFTOVER_DENY ]] || continue
    while IFS= read -r p; do [[ -n $p ]] && claims[$p]=$((${claims[$p]:-0} + 1)); done <<<"${idx[${nm,,}]:-}"
  done
  for key in "${keys[@]}"; do
    src=${a_src[$key]} id=${a_id[$key]}
    if [[ $src == apt ]] && [[ -n ${pskip[$id]:-} || $id =~ $APP_CORE_RE || $id =~ $APP_META_RE ]]; then
      ubuntu_part[$key]=1 hidden=$((hidden + 1)) # hidden, but its folders still count as claimed below
    fi
    local -A mine=()
    while IFS= read -r nm; do
      [[ ${#nm} -ge 3 && ! ${nm,,} =~ $LEFTOVER_DENY ]] || continue
      while IFS= read -r p; do [[ -n $p ]] && mine[$p]=1; done <<<"${idx[${nm,,}]:-}"
    done < <(printf '%s\n' "$id" ${a_desk[$key]} ${a_exec[$key]} | sort -u)
    [[ $src == flatpak && -d $HOME/.var/app/$id ]] && mine[$HOME/.var/app/$id]=1
    [[ $src == snap && -d $HOME/snap/$id ]] && mine[$HOME/snap/$id]=1
    for p in "${!mine[@]}"; do is_protected "$p" && unset "mine[$p]"; done
    app_paths[$key]=$(printf '%s\n' "${!mine[@]}")
    for p in "${!mine[@]}"; do claims[$p]=$((${claims[$p]:-0} + 1)); done
    unset mine
  done
  printf '#hidden\t%d\n' "$hidden"
  for key in "${keys[@]}"; do
    [[ -z ${ubuntu_part[$key]:-} ]] || continue # part of Ubuntu: not listed
    src=${a_src[$key]} id=${a_id[$key]}
    local list=()
    while IFS= read -r p; do [[ -n $p && ${claims[$p]} == 1 ]] && list+=("$p"); done <<<"${app_paths[$key]}" # shared folders stay
    case $src in
      apt) pkgb=${psize[$id]:-0} ;;
      snap) pkgb=$(du_sum /var/lib/snapd/snaps/"${id}"_*.snap) ;;
      flatpak) pkgb=${fpsize[$id]:-0} ;;
      appimage) urldecode_path img "$id"; pkgb=$(du_sum "$img") ;;
    esac
    datab=0 last=0
    ((${#list[@]})) && datab=$(du_sum "${list[@]}") &&
      last=$(find "${list[@]}" -maxdepth 1 -printf '%T@\n' 2>/dev/null | sort -n | tail -n1) && last=${last%.*}
    while IFS= read -r nm; do [[ -n $nm ]] && t=${last_seen[$nm]:-0} && ((t > last)) && last=$t; done <<<"${a_desk[$key]}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$src" "$id" "${a_name[$key]:-$id}" "${pkgb:-0}" "${datab:-0}" "${last:-0}" \
      "${a_desk[$key]%%$'\n'*}" "$(IFS=$'\x1f'; printf '%s' "${list[*]}")" # paths last: may be empty
  done
}

# ── Reset an app ──
#
# Resetting keeps the app installed and moves its data in your home to the
# Trash, so it starts as if new: the folders the Uninstaller finds for it (see
# app_inventory) — a Flatpak app's ~/.var/app/ID only its cache, config and data,
# a snap's ~/snap/NAME only the folder of its current revision and common (older
# revisions stay). Empty folders are left alone. Never as root, never while the
# app runs, and nothing else: not its launcher, its program or other folders.

reset_dir_ok() { # DIR → a real folder (not a symlink) with something in it, not protected
  [[ -d $1 && ! -L $1 ]] && ! is_protected "$1" && [[ -n $(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]
}

reset_paths() { # SRC ID PATHS(\x1f, from app_inventory) → the folders resetting the app moves to the Trash, one per line
  local src=$1 id=$2 p d rev
  local -a ps
  IFS=$'\x1f' read -ra ps <<<"$3"
  for p in "${ps[@]}"; do
    [[ -n $p ]] || continue
    if [[ $src == flatpak && $p == "$HOME/.var/app/$id" ]]; then
      for d in cache config data; do reset_dir_ok "$p/$d" && printf '%s\n' "$p/$d"; done
    elif [[ $src == snap && $p == "$HOME/snap/$id" ]]; then
      rev=$(readlink -- "$p/current" 2>/dev/null); rev=${rev#"$p"/}
      [[ $rev =~ ^[A-Za-z0-9._-]+$ && $rev != . && $rev != .. && $rev != common ]] && reset_dir_ok "$p/$rev" &&
        printf '%s\n' "$p/$rev"
      reset_dir_ok "$p/common" && printf '%s\n' "$p/common"
    elif reset_dir_ok "$p"; then printf '%s\n' "$p"; fi
  done
}

# ── Leftovers of removed apps ──
#
# Folders in your home that no installed app uses any more: ~/.var/app/ID of a
# Flatpak app and ~/snap/NAME of a snap that are no longer installed, and folders
# right inside ~/.config, ~/.local/share, ~/.local/state and ~/.cache whose name
# matches nothing installed. They are never ticked and only go to the Trash.
#
# A folder's name (ignoring case and anything but letters and digits) belongs to
# something installed when it equals, starts or shares its first 5 letters with
# the name of a package, snap, Flatpak app, launcher, command (also in the PATH
# your shell profile sets), running program, AppImage or folder in /opt,
# /usr/share, /usr/lib or /etc. Also never offered: the names below (the
# desktop's own folders, folders many apps share, tools CleanMate has its own
# items for), folders with programs in them, changed in the last ORPHAN_DAYS
# days, or with a file a program has open.

ORPHAN_SHARED='^(applications|autostart|desktop-directories|menus|mime|icons|themes|fonts|sounds|backgrounds|wallpapers|templates|color|icc|keyrings|password-store|gnupg|ssh|pki|nss|certs|trash|recently-used.*|user-dirs.*|dconf|gconf|glib-2\.0|gtk.*|qt[0-9]*ct|pulse|pipewire|wireplumber|systemd|environment\.d|user-tmpfiles\.d|dbus-1|xdg-.*|fontconfig|ibus.*|fcitx.*|enchant|hunspell|aspell|thumbnails|mesa_shader_cache.*|nvidia|vulkan|radv.*|gstreamer-.*|babl|gegl-.*|webkitgtk|xorg|session|sessions|tracker.*|gvfs.*|evolution|folks|geoclue|goa-.*|gnome.*|org\.gnome\..*|org\.freedesktop\..*|org\.kde\..*|kde.*|plasma.*|ubuntu.*|canonical.*|snap|snapd|flatpak|containers|docker|google|microsoft|mozilla|jetbrains|unity3d|electron|cleanmate|claude.*|codex|gemini|opencode|cursor|windsurf|codeium|kilo|mimocode|zed|zcode|cline|continue|github-copilot|copilot|lm-studio|lmstudio|huggingface|ollama|firebase|ms-playwright|puppeteer|cypress|pip|uv|go-build|yarn|npm|pnpm|node-gyp)$'
ORPHAN_DAYS=30
ORPHAN_SYSTEM_DIRS=(/usr/share /usr/local/share /usr/lib /usr/local/lib /usr/libexec /etc /etc/xdg)
ORPHAN_BIN_DIRS=(.local/bin bin .cargo/bin go/bin .go/bin .npm-global/bin .bun/bin .deno/bin .volta/bin .pyenv/shims
  .pyenv/bin .rbenv/shims .local/share/pnpm .yarn/bin .dotnet/tools .nix-profile/bin .linuxbrew/bin .juliaup/bin
  .ghcup/bin .local/share/flatpak/exports/bin) # inside your home; nvm and SDKMAN versions are added below

profile_path_dirs() { # folders in your home that your shell profile adds to PATH (read as text, never run)
  local f line v d parts
  for f in .profile .bash_profile .bash_login .bashrc .zshenv .zprofile .zshrc .config/fish/config.fish; do
    [[ -f $HOME/$f && ! -L $HOME/$f ]] || continue
    while IFS= read -r line; do
      v=${line#*PATH}; v=${v#=}
      v=${v%%#*}; v=${v//[\"\']/}
      IFS=': ' read -ra parts <<<"$v"
      for d in "${parts[@]}"; do
        d=${d/#\~/$HOME}; d=${d/#\$\{HOME\}/$HOME}; d=${d/#\$HOME/$HOME}
        [[ $d == "$HOME"/* && $d != *[\$\`\;\&\|\<\>\(\)\\]* && -d $d && ! -L $d ]] && printf '%s\n' "${d%/}"
      done
    done < <(grep -E '^[[:space:]]*((export[[:space:]]+)?PATH=|fish_add_path[[:space:]]|set[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*PATH[[:space:]])' \
      "$HOME/$f" 2>/dev/null)
  done
}

installed_names() { # every name that says something is installed, one per line (see above)
  local d f
  local -a bins=() files=()
  if have dpkg-query; then # installed only: a package removed without --purge doesn't count
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 !~ /^.[nc]/ && $2 != "" {print $2}'
  fi
  have snap && snap list 2>/dev/null | awk 'NR > 1 {print $1}'
  have flatpak && flatpak list --app --columns=application 2>/dev/null | cut -f1
  for d in /snap /var/lib/flatpak/app "$APPS_DIR_USER/flatpak/app" /opt "${ORPHAN_SYSTEM_DIRS[@]}"; do
    [[ -d $d ]] && find "$d" -mindepth 1 -maxdepth "$([[ $d == /opt ]] && echo 2 || echo 1)" -printf '%f\n' 2>/dev/null
  done
  # launchers (hidden ones too): file name, Name, Icon, StartupWMClass and every word of Exec/TryExec
  for d in "${APP_DESKTOP_DIRS[@]}" "${XDG_CONFIG_HOME:-$HOME/.config}/autostart" /etc/xdg/autostart; do
    [[ -d $d ]] || continue
    for f in "$d"/*.desktop; do [[ -f $f ]] && files+=("$f"); done
  done
  ((${#files[@]})) && awk '
    FNR == 1 { f = FILENAME; sub(/.*\//, "", f); sub(/\.desktop$/, "", f); print f }
    /^(Name|Icon|StartupWMClass)=/ { sub(/^[^=]*=/, ""); print }
    /^(Exec|TryExec)=/ {
      sub(/^[^=]*=/, ""); n = split($0, w, /[ \t]+/)
      for (i = 1; i <= n; i++) if (w[i] !~ /^(-|%)/ && w[i] !~ /=/) { gsub(/["\047]/, "", w[i]); sub(/.*\//, "", w[i]); print w[i] }
    }' "${files[@]}" 2>/dev/null
  # commands: PATH, the folders your profile adds, the usual tool folders
  IFS=: read -ra bins <<<"${PATH:-}"
  mapfile -t -O "${#bins[@]}" bins < <(profile_path_dirs)
  for d in "${ORPHAN_BIN_DIRS[@]}"; do bins+=("$HOME/$d"); done
  for d in "$HOME"/.nvm/versions/node/*/bin "$HOME"/.sdkman/candidates/*/current/bin \
    /usr/local/bin /usr/bin /bin /usr/sbin /sbin /usr/games /usr/local/games /snap/bin /var/lib/flatpak/exports/bin; do
    bins+=("$d")
  done
  for d in "${bins[@]}"; do [[ -d $d ]] && find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null; done
  have ps && ps -A -o comm= 2>/dev/null
  find "$HOME" -maxdepth 3 \( -path "$HOME/.local/share/Trash" -o -path "$HOME/.cache" \) -prune -o \
    -iname '*.appimage' -printf '%f\n' 2>/dev/null | sed 's/\.[Aa][Pp][Pp][Ii][Mm][Aa][Gg][Ee]$//'
  return 0
}

open_under() { # LIST PATH — LIST (newline-framed paths, as from open_files) has PATH or something inside it
  [[ $1 == *$'\n'"$2"$'\n'* || $1 == *$'\n'"$2"/* ]]
}

unclaimed_folders() { # NAMES-FILE < folder paths → the ones whose name matches nothing in NAMES-FILE
  awk '
    function norm(s) { s = tolower(s); gsub(/[^a-z0-9]/, "", s); return s }
    function add(s,   i, n) { s = norm(s); n = length(s); if (n < 2) return; K[s] = 1; for (i = 1; i <= n; i++) P[substr(s, 1, i)] = 1 }
    function claimed(s,   n, i) {
      s = norm(s); n = length(s)
      if (n < 3 || s in P) return 1                # too short to tell, or equal to / the start of a name
      if (n > 5 && substr(s, 1, 5) in P) return 1  # shares its first 5 letters with a name
      for (i = 4; i < n; i++) if (substr(s, 1, i) in K) return 1 # starts with a name
      return 0
    }
    FNR == NR {
      add($0)
      n = split(tolower($0), w, /[-_. ]+/)
      for (i = 1; i <= n; i++) if (i == 1 || length(w[i]) >= 3) add(w[i]) # parts of org.foo.Bar, gimp-2.10
      if (tolower($0) ~ /^lib./) add(substr($0, 4))                       # libgegl-0.4-0 → gegl
      next
    }
    {
      name = $0; sub(/.*\//, "", name)
      if (claimed(name)) next
      n = split(tolower(name), w, /[-_. ]+/)
      if (n > 1 && norm(w[1]) in K) next # go-build → go
      hit = 0
      for (i = 2; i <= n; i++) if (length(w[i]) >= 4 && claimed(w[i])) hit = 1
      if (!hit) print
    }' "$1" -
}

orphan_folders() { # → kind<TAB>bytes<TAB>path of folders no installed app uses, biggest first (kind: flatpak|snap|folder)
  local d p n out names cand=() open fp_ok=1 snap_ok=1
  local -A fps=() snaps=()
  if have flatpak; then # a list we can't read means we don't know: offer nothing
    if out=$(flatpak list --app --columns=application 2>/dev/null); then
      while IFS=$'\t' read -r n _; do [[ -n $n ]] && fps[$n]=1; done <<<"$out"
    else fp_ok=0; fi
  fi
  if have snap; then
    if out=$(snap list 2>/dev/null); then
      while read -r n _; do [[ -n $n ]] && snaps[$n]=1; done < <(tail -n +2 <<<"$out")
    else snap_ok=0; fi
  fi
  open=$'\n'$( { open_files; find /proc/[0-9]*/cwd -maxdepth 0 -type l -printf '%l\n' 2>/dev/null; } )$'\n'
  {
    if ((fp_ok)); then
      for p in "$HOME"/.var/app/*; do
        n=${p##*/}
        [[ -d $p && ! -L $p && $n =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
        [[ -n ${fps[$n]:-} || -d /var/lib/flatpak/app/$n || -d $APPS_DIR_USER/flatpak/app/$n ]] && continue
        open_under "$open" "$p" || printf 'flatpak\t%s\t%s\n' "$(du_sum "$p")" "$p"
      done
    fi
    if ((snap_ok)); then
      for p in "$HOME"/snap/*; do
        n=${p##*/}
        [[ -d $p && ! -L $p && $n =~ ^[a-z0-9][a-z0-9_-]*$ && $n != bin ]] || continue
        [[ -n ${snaps[$n]:-} || -e /snap/$n ]] && continue
        open_under "$open" "$p" || printf 'snap\t%s\t%s\n' "$(du_sum "$p")" "$p"
      done
    fi
    for d in "${XDG_CONFIG_HOME:-$HOME/.config}" "$APPS_DIR_USER" "${XDG_STATE_HOME:-$HOME/.local/state}" "${XDG_CACHE_HOME:-$HOME/.cache}"; do
      [[ $d == "$HOME"/* && -d $d && ! -L $d ]] || continue
      for p in "$d"/*; do
        n=${p##*/}
        [[ -d $p && ! -L $p && $n != *[[:cntrl:]]* && ! ${n,,} =~ $ORPHAN_SHARED && ! ${n,,} =~ $LEFTOVER_DENY ]] || continue
        is_protected "$p" || cand+=("$p")
      done
    done
    if ((${#cand[@]})); then
      names=$(mktemp -p "${SESSION_TMP:-/tmp}") || return 1
      installed_names >"$names"
      while IFS= read -r p; do
        # changed lately, holds programs, or open: something not on our lists still uses it
        [[ -z $(find "$p" -maxdepth 3 \( -mtime -"$ORPHAN_DAYS" -o -type f -perm /111 \) -print -quit 2>/dev/null) ]] || continue
        open_under "$open" "$p" || printf 'folder\t%s\t%s\n' "$(du_sum "$p")" "$p"
      done < <(printf '%s\n' "${cand[@]}" | unclaimed_folders "$names")
      rm -f "$names"
    fi
  } | sort -t$'\t' -k2,2rn
}

used_ago() { # EPOCH → "today" / "12 days ago" / "5 months ago" / "2 years ago" / "—"
  local d
  (($1 > 0)) || { printf '—'; return; }
  d=$(((EPOCHSECONDS - $1) / 86400))
  if ((d < 1)); then printf 'today'
  elif ((d < 60)); then printf '%d days ago' "$d"
  elif ((d < 730)); then printf '%d months ago' $((d / 30))
  else printf '%d years ago' $((d / 365)); fi
}

declare -a A_SRC=() A_ID=() A_NAME=() A_PKG=() A_DATA=() A_LAST=() A_PATHS=() A_VIEW=()
declare -a A_LEFT=() # kind<TAB>bytes<TAB>path from orphan_folders: the last row of the list
declare -a APP_UNDO=() # trash keys of the AppImage apps the last uninstall moved to the Trash
A_HIDDEN=0 A_SORT=size A_FILTER=all

load_apps() {
  local tmp line
  tmp=$(mktemp -p "$SESSION_TMP")
  (app_inventory >"$tmp"; orphan_folders >"$tmp.left") &
  UI_BUSY_TITLE="Uninstaller"
  ui_busy "Finding your apps and the space each one uses…" $! || { rm -f "$tmp" "$tmp.left"; return 1; }
  A_SRC=() A_ID=() A_NAME=() A_PKG=() A_DATA=() A_LAST=() A_PATHS=() U_SEL=()
  mapfile -t A_LEFT <"$tmp.left"
  rm -f "$tmp.left"
  while IFS=$'\t' read -r -a line; do
    if [[ ${line[0]} == '#hidden' ]]; then A_HIDDEN=${line[1]}; continue; fi
    A_SRC+=("${line[0]}") A_ID+=("${line[1]}") A_NAME+=("${line[2]}") A_PKG+=("${line[3]}")
    A_DATA+=("${line[4]}") A_LAST+=("${line[5]}") A_PATHS+=("${line[7]:-}")
  done <"$tmp"
  rm -f "$tmp"
}

apps_view() { # A_SORT / A_FILTER → A_VIEW (indices into A_*)
  local i cut=$((EPOCHSECONDS - APP_UNUSED_DAYS * 86400)) big=$((APP_LARGE_MB * 1024 * 1024))
  A_VIEW=()
  mapfile -t A_VIEW < <(for i in "${!A_ID[@]}"; do
    case $A_FILTER in
      unused) ((A_LAST[i] > 0 && A_LAST[i] < cut)) || continue ;;
      large) ((A_PKG[i] + A_DATA[i] >= big)) || continue ;;
    esac
    case $A_SORT in
      size) printf '%020d\t%s\n' $((A_PKG[i] + A_DATA[i])) "$i" ;;
      used) printf '%020d\t%s\n' $((A_LAST[i] > 0 ? A_LAST[i] : 1)) "$i" ;;
      name) printf '%s\t%s\n' "${A_NAME[i],,}" "$i" ;;
    esac
  done | if [[ $A_SORT == size ]]; then sort -r; else sort; fi | cut -f2)
}

applist_row() {
  local i=${A_VIEW[$1]:-} mark="  " box src lbl sz used c
  (($2)) && mark="${ACCENT}▸${NC} "
  if [[ -z $i ]]; then # the last row: leftovers of removed apps
    local e tot=0
    for e in "${A_LEFT[@]}"; do e=${e#*$'\t'}; tot=$((tot + ${e%%$'\t'*})); done
    fitv lbl "Leftovers of removed apps · $(plural ${#A_LEFT[@]} folder)" $((UI_W - 28))
    (($2)) && lbl="${BOLD}$lbl${NC}"
    humanv sz "$tot"; printf -v sz '%9s' "$sz"
    fl " $mark${DIM}⌂${NC} $lbl $sz  ${DIM}enter to review${NC}"
    return
  fi
  if [[ -n ${U_SEL[$i]:-} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  case ${A_SRC[i]} in snap) c=$MAGENTA ;; flatpak) c=$BLUE ;; appimage) c=$YELLOW ;; *) c=$CYAN ;; esac
  fitv src "${A_SRC[i]}" 8
  fitv lbl "${A_NAME[i]}" $((UI_W - 45))
  (($2)) && lbl="${BOLD}$lbl${NC}"
  humanv sz $((A_PKG[i] + A_DATA[i])); printf -v sz '%9s' "$sz"
  used=$(used_ago "${A_LAST[i]}"); printf -v used '%-14s' "$used"
  fl " $mark$box $c$src$NC $lbl $sz  ${DIM}$used${NC}"
}
applist_text() { if [[ -n ${A_VIEW[$1]:-} ]]; then TEXT=${A_NAME[${A_VIEW[$1]}]}; else TEXT="Leftovers of removed apps"; fi; }
applist_top() {
  local f
  case $A_FILTER in unused) f="not used for ${APP_UNUSED_DAYS}+ days" ;; large) f="${APP_LARGE_MB} MB or more" ;; *) f="all apps" ;; esac
  fl ""
  fl "  ${BOLD}$(plural ${#A_VIEW[@]} app)${NC} ${DIM}· $f · by $A_SORT${NC}"
  ((A_HIDDEN)) && fl "  ${DIM}Not shown: $(plural "$A_HIDDEN" part) of Ubuntu itself, which can't be removed safely${NC}"
  fl ""
}
applist_bottom() {
  local i tot=0
  for i in "${!U_SEL[@]}"; do tot=$((tot + A_PKG[i] + A_DATA[i])); done
  fl ""
  fl "  ${BOLD}Selected${NC} $(plural ${#U_SEL[@]} app)$( ((tot)) && echo " · $(human "$tot")")   ${DIM}size = app + its folders in your home${NC}"
}

app_details() { # INDEX
  local i=$1 p id=${A_ID[$1]}
  [[ ${A_SRC[i]} == appimage ]] && urldecode_path id "$id" && id=${id/#$HOME/\~}
  V_LINES=("" "  ${BOLD}${A_NAME[i]}${NC}  ${DIM}${A_SRC[i]} · $id${NC}" ""
    "  $(printf '%-14s' "App") $(human "${A_PKG[i]}")"
    "  $(printf '%-14s' "Your data") $(human "${A_DATA[i]}")"
    "  $(printf '%-14s' "Last used") $(used_ago "${A_LAST[i]}")" "")
  if [[ -n ${A_PATHS[i]} ]]; then
    V_LINES+=("  ${BOLD}Folders in your home${NC} ${DIM}(offered for the Trash after uninstalling)${NC}")
    while IFS= read -r p; do
      [[ -n $p ]] && V_LINES+=("  $(printf '%9s' "$(human "$(du_sum "$p")")")  ${p/#$HOME/\~}")
    done < <(tr '\037' '\n' <<<"${A_PATHS[i]}")
  else V_LINES+=("  ${DIM}No folders of its own found in your home.${NC}"); fi
  V_LINES+=("" "  ${DIM}“Last used” comes from GNOME's record of opened apps, or the newest change in the app's folders.${NC}"
    "  ${DIM}r on the list resets the app: its data in your home goes to the Trash, the app stays installed.${NC}")
  ui_view "${A_NAME[i]}"
}

uninstall_apps() { # uninstall U_SEL (indices into A_*), then offer their folders for the Trash
  local i apt_pkgs=() names=() needs_root=0 body title sim others extra core
  for i in "${!U_SEL[@]}"; do
    names+=("${A_NAME[i]}")
    [[ ${A_SRC[i]} == apt ]] && apt_pkgs+=("${A_ID[i]}")
    [[ ${A_SRC[i]} == apt || ${A_SRC[i]} == snap ]] && needs_root=1 # Flatpak and AppImage apps: as you
  done
  body=$(printf '%s, ' "${names[@]}"); body=${body%, }
  title="Uninstall $(plural ${#names[@]} app)?"
  if ((${#apt_pkgs[@]})); then
    apt_check_removal "${apt_pkgs[@]}" || return
    if ((APT_EXTRA_N)); then
      title="⚠ Also removes $(plural "$APT_EXTRA_N" "other package")! Continue?"
      body=$APT_EXTRA_TEXT
    fi
  fi
  ui_confirm "$title" "$body" n || return
  ((needs_root)) && { ensure_sudo "Removing apps needs administrator rights." || return; }
  new_tasks
  for i in "${!U_SEL[@]}"; do add_task "Uninstall ${A_NAME[i]} (${A_SRC[i]})" task_uninstall "${A_SRC[i]}:${A_ID[i]}:$i"; done
  APP_UNDO=() # AppImage apps go to the Trash: z on the home screen puts them back
  run_tasks "Uninstalling"
  ((${#APP_UNDO[@]})) && UNDO_BATCH=("${APP_UNDO[@]}")
  refresh_sysinfo
  show_run_results "Uninstall complete"
  local left=() p tot=0
  for i in "${!T_STATE[@]}"; do
    [[ ${T_STATE[i]} == ok ]] || continue
    while IFS= read -r p; do [[ -n $p && -e $p ]] && left+=("$p"); done < <(tr '\037' '\n' <<<"${A_PATHS[${T_ARG[i]##*:}]}")
  done
  if ((${#left[@]})); then
    for p in "${left[@]}"; do tot=$((tot + $(du_sum "$p"))); done
    body=$(printf '%s, ' "${left[@]/#$HOME/\~}"); body=${body%, }
    if ui_confirm "Move their $(plural ${#left[@]} folder) ($(human "$tot")) to the Trash?" "$body" n; then
      UNDO_BATCH=("${APP_UNDO[@]}")
      for p in "${left[@]}"; do move_to_trash "$p" >/dev/null 2>&1; done
      if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural ${#left[@]} folder) to Trash"
      else toast "${GREEN}✔${NC} Moved $(plural ${#left[@]} folder) to Trash — z on the home screen puts them back"; fi
    fi
  elif ((${#APP_UNDO[@]})); then
    toast "${GREEN}✔${NC} AppImage apps went to the Trash — z on the home screen puts them back"
  fi
  load_apps
  apps_view
}

reset_app() { # INDEX into A_* — keep the app, move its data in your home to the Trash (see reset_paths); z puts it back
  local i=$1 prog p tot=0 n=0 list=()
  ((EUID != 0)) || { toast "${RED}✘${NC} Resetting works on your home folder: run CleanMate as yourself, not as root"; return; }
  if prog=$(app_running "${A_SRC[i]}" "${A_ID[i]}"); then
    toast "${YELLOW}!${NC} Close $prog first: resetting ${A_NAME[i]} while it runs can lose what is open in it"; return
  fi
  mapfile -t list < <(reset_paths "${A_SRC[i]}" "${A_ID[i]}" "${A_PATHS[i]}")
  ((${#list[@]})) || { toast "${DIM}${A_NAME[i]} keeps no data in your home: nothing to reset.${NC}"; return; }
  CONFIRM_LINES=()
  for p in "${list[@]}"; do
    n=$(du_sum "$p"); tot=$((tot + n))
    CONFIRM_LINES+=("$(printf '%9s' "$(human "$n")")  ${p/#$HOME/\~}")
  done
  ui_confirm "Reset ${A_NAME[i]}?" "The app stays; its $(plural ${#list[@]} folder) ($(human "$tot")) go to the Trash" n || return
  UNDO_BATCH=() n=0
  for p in "${list[@]}"; do move_to_trash "$p" >/dev/null 2>&1 && n=$((n + 1)); done
  log "reset ${A_SRC[i]}:${A_ID[i]}"
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural ${#list[@]} folder) of ${A_NAME[i]} to Trash"
  elif ((n < ${#list[@]})); then toast "${YELLOW}!${NC} Reset ${A_NAME[i]}: moved $n of ${#list[@]} folders to Trash — z puts them back"
  else toast "${GREEN}✔${NC} Reset ${A_NAME[i]}: moved $(plural "$n" folder) to Trash — z puts them back"; fi
  load_apps
  apps_view
}

apps_menu() {
  local cur=0 scroll=0 i
  load_apps || return
  apps_view
  while :; do
    L_TITLE="Uninstaller" L_TOP=applist_top L_BOTTOM=applist_bottom L_ROW=applist_row L_FOCUSABLE="" L_TEXT=applist_text
    L_VIEW=0 L_COUNT=$((${#A_VIEW[@]} + (${#A_LEFT[@]} > 0))) L_CUR=$cur L_SCROLL=$scroll
    ((L_COUNT)) || L_VIEW=1
    if ((${#UNDO_BATCH[@]})); then hints space select "!u" uninstall r reset z undo enter details s sort f filter / find q back
    else hints space select "!u" uninstall r reset enter details s sort f filter / find p "all packages" q back; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL
    i=${A_VIEW[cur]:-}
    case $KEY in
      space) [[ -n $i ]] && { if [[ -n ${U_SEL[$i]:-} ]]; then unset "U_SEL[$i]"; else U_SEL[$i]=1; fi; list_move 1; cur=$L_CUR; } ;;
      u) [[ -n $i ]] || continue; ((${#U_SEL[@]})) || U_SEL[$i]=1; uninstall_apps; cur=0 scroll=0 ;;
      r) [[ -n $i ]] && reset_app "$i" ;;
      z) ((${#UNDO_BATCH[@]})) || continue; undo_trash; undo_toast; load_apps; apps_view ;;
      enter | right)
        if [[ -n $i ]]; then app_details "$i"
        elif ((${#A_LEFT[@]})); then leftovers_menu; load_apps; apps_view; cur=0 scroll=0; fi ;;
      s) case $A_SORT in size) A_SORT=used ;; used) A_SORT=name ;; *) A_SORT=size ;; esac; apps_view; cur=0 scroll=0 ;;
      f) case $A_FILTER in all) A_FILTER=unused ;; unused) A_FILTER=large ;; *) A_FILTER=all ;; esac; apps_view; cur=0 scroll=0 ;;
      p) U_SEL=(); pkg_search_menu; load_apps; apps_view; cur=0 scroll=0 ;;
      q | esc | left | backspace) U_SEL=(); return ;;
    esac
  done
}

# apt must remove exactly what was asked for — and never a part of Ubuntu itself.
apt_check_removal() { # PKG... → APT_EXTRA_N, APT_EXTRA_TEXT; returns 1 (with a toast, APT_ERR) when it must not go ahead
  local sim others core
  APT_EXTRA_N=0 APT_EXTRA_TEXT="" APT_ERR=""
  if ! sim=$(LC_ALL=C apt-get -s purge "$@" 2>&1); then
    APT_ERR="apt can't remove this cleanly: $(grep -m1 '^E:' <<<"$sim" | cut -c4-)"
    toast "${RED}✘${NC} $APT_ERR"
    return 1
  fi
  core=$(grep '^Purg' <<<"$sim" | awk '{print $2}' | grep -E "$APP_CORE_RE|^linux-image-$(uname -r)\$" | head -n 3 | paste -sd, - | sed 's/,/, /g')
  if [[ -n $core ]]; then
    APT_ERR="Not removed: apt would also take $core, which Ubuntu needs to run."
    toast "${RED}✘${NC} $APT_ERR"
    return 1
  fi
  local purg=()
  mapfile -t purg < <(grep '^Purg' <<<"$sim" | awk '{print $2}')
  core=$( ((${#purg[@]})) && dpkg-query -W -f='${Package} ${Priority} ${Essential}\n' "${purg[@]}" 2>/dev/null |
    awk '$2 == "required" || $2 == "important" || $3 == "yes" {print $1}' | head -n 3 | paste -sd, - | sed 's/,/, /g')
  if [[ -n $core ]]; then
    APT_ERR="Not removed: $core is marked as required by Ubuntu. Use apt yourself if you're sure."
    toast "${RED}✘${NC} $APT_ERR"
    return 1
  fi
  others=$(printf '%s\n' "${purg[@]}" | grep -vxF -f <(printf '%s\n' "$@"))
  APT_EXTRA_N=$(grep -c . <<<"$others")
  APT_EXTRA_TEXT="$(head -n 6 <<<"$others" | paste -sd, - | sed 's/,/, /g')$( ((APT_EXTRA_N > 6)) && echo ", …")"
  grep -qE "$APP_META_RE" <<<"$others" && APT_EXTRA_TEXT+=" — includes Ubuntu's desktop package list, so future release upgrades may skip apps"
  return 0
}

# ───────────────────────────── startup items ────────────────────────────────

desktop_get() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }

desktop_set() { # FILE KEY VALUE
  if grep -q "^$2=" "$1"; then run sed -i "s|^$2=.*|$2=$3|" "$1"
  else run sed -i "/^\[Desktop Entry\]/a $2=$3" "$1"; fi
}

is_disabled() {
  [[ $(desktop_get "$1" Hidden) == true || $(desktop_get "$1" X-GNOME-Autostart-enabled) == false ]]
}

AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
SYSTEM_AUTOSTART_DIR=${CLEANMATE_SYSTEM_AUTOSTART:-/etc/xdg/autostart} # tests: other system entries

load_startup() { # SHOW_ALL → S_FILE S_NAME S_ON S_HIDDEN
  declare -A eff=()
  local f b
  S_FILE=() S_NAME=() S_ON=() S_HIDDEN=0
  for f in "$SYSTEM_AUTOSTART_DIR"/*.desktop "$AUTOSTART_DIR"/*.desktop; do
    [[ -f $f ]] && eff[$(basename "$f")]=$f # a user entry overrides the system one
  done
  while read -r b; do
    [[ -n $b ]] || continue
    f=${eff[$b]}
    if (($1 == 0)) && [[ $(desktop_get "$f" NoDisplay) == true ]]; then ((++S_HIDDEN)); continue; fi
    S_FILE+=("$f")
    b=$(desktop_get "$f" Name); S_NAME+=("${b:-$(basename "$f" .desktop)}")
    if is_disabled "$f"; then S_ON+=(0); else S_ON+=(1); fi
  done < <(printf '%s\n' "${!eff[@]}" | sort)
}

startup_toggle() { # IDX — flip an entry, copying system entries to the user's autostart dir
  local f=${S_FILE[$1]} target
  target="$AUTOSTART_DIR/$(basename "$f")"
  if [[ $f != "$target" ]]; then run mkdir -p "$AUTOSTART_DIR"; run cp "$f" "$target"; fi
  ((DRY_RUN)) && target=$f
  if ((S_ON[$1])); then
    desktop_set "$target" Hidden true; desktop_set "$target" X-GNOME-Autostart-enabled false
  else
    desktop_set "$target" Hidden false; desktop_set "$target" X-GNOME-Autostart-enabled true
  fi
}

startup_row() {
  local i=$1 mark="  " st lbl src
  (($2)) && mark="${ACCENT}▸${NC} "
  if ((S_ON[i])); then st="${GREEN}● on ${NC}"; else st="${DIM}○ off${NC}"; fi
  fitv lbl "${S_NAME[i]}" 38
  (($2)) && lbl="${BOLD}$lbl${NC}"
  if [[ ${S_FILE[i]} == "$AUTOSTART_DIR"/* ]]; then src=user; else src=system; fi
  fl " $mark$st  $lbl ${DIM}$src${NC}"
}

startup_text() { TEXT=${S_NAME[$1]}; }
startup_top() {
  local i on=0
  for i in "${S_ON[@]}"; do ((i)) && ((++on)); done
  fl ""
  fl "  ${BOLD}$on of ${#S_ON[@]} apps start at login${NC} ${DIM}— fewer startup apps means a faster login${NC}"
  fl ""
}

startup_bottom() {
  local f=${S_FILE[$L_CUR]} c
  c=$(desktop_get "$f" Comment)
  fl ""
  fitv c "${c:-$(desktop_get "$f" Exec)}" $((UI_W - 6))
  fl "  ${ACCENT}ℹ${NC} ${DIM}$c${NC}"
  ((S_HIDDEN)) && fl "  ${DIM}$S_HIDDEN hidden system services not shown — press s to show them${NC}"
  return 0
}

startup_menu() {
  local show_all=0 cur=0 scroll=0
  load_startup "$show_all"
  while :; do
    L_TITLE="Startup Items" L_TOP=startup_top L_BOTTOM=startup_bottom L_ROW=startup_row L_FOCUSABLE="" L_TEXT=startup_text
    L_VIEW=0 L_COUNT=${#S_FILE[@]} L_CUR=$cur L_SCROLL=$scroll
    hints "!space" "on/off" s "$( ((show_all)) && echo "hide services" || echo "show services")" q back "↑↓" move
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL
    case $KEY in
      space | enter)
        ((${#S_FILE[@]})) || continue
        startup_toggle "$cur" >/dev/null 2>&1
        if ((DRY_RUN)); then
          toast "${MAGENTA}[dry-run]${NC} Would turn ${S_NAME[cur]} $( ((S_ON[cur])) && echo off || echo on)"
        else
          toast "${GREEN}✔${NC} ${S_NAME[cur]} will $( ((S_ON[cur])) && echo "no longer start" || echo "start") at login"
          load_startup "$show_all"
        fi ;;
      s) show_all=$((1 - show_all)); load_startup "$show_all"; cur=0 scroll=0 ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

# ───────────────────────────── maintenance ──────────────────────────────────

m_apt_update()     { run_root apt-get update; }
m_apt_upgrade()    { run_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; }
m_snap_refresh()   { run_root snap refresh; }
m_flatpak_update() { run flatpak update -y --noninteractive; }
m_dpkg_configure() { run_root dpkg --configure -a; }
m_apt_fix()        { run_root env DEBIAN_FRONTEND=noninteractive apt-get -f install -y; }
m_flatpak_unused() { run flatpak uninstall --unused -y --noninteractive; }
m_fstrim()         { run_root fstrim -av; }
m_fc_cache()       { run fc-cache -f; }
m_updatedb()       { run_root updatedb; }
m_drop_caches_pre() { MEM_BEFORE=$(free -b | awk '/^Mem:/ {print $7}'); }
m_drop_caches()    { run_root sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'; }
m_drop_caches_post() {
  local after
  after=$(free -b | awk '/^Mem:/ {print $7}')
  T_INFO[$3]="available RAM $(human "$MEM_BEFORE") → $(human "$after")"
}
m_fstrim_post() {
  (($2 == 0)) || return 0
  T_INFO[$3]="$(grep -c 'trimmed' "$4") filesystems trimmed"
}

# What "Update everything" would change, without changing anything. apt's list
# is as of its last refresh (the update itself refreshes first, so it may find more).
pending_updates() { # → source<TAB>name<TAB>new version
  have apt && LC_ALL=C apt list --upgradable 2>/dev/null | awk -F'[/ ]' '/upgradable from/ {print "apt\t" $1 "\t" $3}'
  have snap && LC_ALL=C timeout 30 snap refresh --list 2>/dev/null | awk 'NR > 1 && NF >= 2 {print "snap\t" $1 "\t" $2}'
  have flatpak && timeout 30 flatpak remote-ls --updates --columns=application,version 2>/dev/null |
    awk -F'\t' 'NF && $1 != "Application ID" {print "flatpak\t" $1 "\t" ($2 == "" ? "new build" : $2)}'
  return 0
}

update_preview() { # → 0 to go ahead; lists what will be updated in the confirmation
  local tmp n_apt n_snap n_flat total line src name ver summary
  tmp=$(mktemp -p "$SESSION_TMP")
  (pending_updates >"$tmp") &
  UI_BUSY_TITLE="Maintenance"
  ui_busy "Checking what has an update…" $! || { rm -f "$tmp"; return 1; }
  n_apt=$(grep -c $'^apt\t' "$tmp") n_snap=$(grep -c $'^snap\t' "$tmp") n_flat=$(grep -c $'^flatpak\t' "$tmp")
  total=$((n_apt + n_snap + n_flat))
  CONFIRM_LINES=()
  while IFS=$'\t' read -r src name ver; do CONFIRM_LINES+=("$(printf '%-8s %s %s' "$src" "$name" "${DIM}→ $ver${NC}")"); done <"$tmp"
  rm -f "$tmp"
  if ((total == 0)); then
    CONFIRM_LINES=()
    ui_confirm "Everything looks up to date" "apt's list may be a few days old — refresh and update anyway?" n
    return
  fi
  summary="$( ((n_apt)) && printf '%s apt · ' "$n_apt")$( ((n_snap)) && printf '%s snap · ' "$n_snap")$( ((n_flat)) && printf '%s flatpak · ' "$n_flat")"
  ui_confirm "Update $(plural "$total" package)?" "${summary% · } — no further questions" y
}

# Lasting limits, so the same junk doesn't pile up again after a clean.
snap_retain() { snap get system refresh.retain 2>/dev/null; } # empty = snapd's default
m_snap_retain()   { run_root snap set system refresh.retain=2; }
m_snap_unretain() { run_root snap unset system refresh.retain; }
m_snap_retain_post() { (($2 == 0)) && T_INFO[$3]="older versions go at the next snap refresh — or clean them now in System Junk"; return 0; }

JOURNALD_DROPIN=/etc/systemd/journald.conf.d/60-cleanmate.conf
journal_cap() { # MB, empty = no limit of ours
  sed -n 's/^SystemMaxUse=\([0-9]*\)M$/\1/p' "$JOURNALD_DROPIN" 2>/dev/null | head -n 1
}
m_journal_cap() { # writes a journald drop-in; journald applies it on restart
  run_root sh -c 'mkdir -p "${1%/*}" && printf "# Written by CleanMate (Maintenance)\n[Journal]\nSystemMaxUse=%sM\n" "$2" >"$1" && systemctl restart systemd-journald' \
    sh "$JOURNALD_DROPIN" "$JOURNAL_KEEP_MB"
}
m_journal_uncap() { run_root sh -c 'rm -f -- "$1" && systemctl restart systemd-journald' sh "$JOURNALD_DROPIN"; }

# The nine items, shared by the terminal menu and `--json maintenance|maintain`.
MAINT_IDS=(update repair flatpak_unused fstrim free_ram fonts locate snap_versions journal_limit)
declare -A MAINT_LABEL=([update]="Update everything" [repair]="Repair packages" [flatpak_unused]="Unused Flatpak runtimes"
  [fstrim]="TRIM SSDs" [free_ram]="Free up RAM" [fonts]="Rebuild font cache" [locate]="Update locate database"
  [snap_versions]="Keep fewer snap versions" [journal_limit]="Limit journal size")
declare -A MAINT_DESC=([update]="Upgrade apt, snap and flatpak packages"
  [repair]="Finish interrupted installs, fix broken dependencies" [flatpak_unused]="Remove runtimes no installed app uses"
  [fstrim]="Tell SSDs which blocks are free (fstrim)" [free_ram]="Drop the page cache — Linux reclaims it anyway"
  [fonts]="Fix missing or stale fonts (fc-cache)" [locate]="Refresh the index used by locate"
  [snap_versions]="Keep 2 versions of each snap instead of 3" [journal_limit]="Never let system logs grow past a size")
MAINT_USER_STEPS=" m_flatpak_update m_flatpak_unused m_fc_cache " # run as you; every other step needs root

maint_user_step() { [[ $MAINT_USER_STEPS == *" $1 "* ]]; }

maint_missing() { # ID → 0 and MAINT_WHY when the item's tool isn't on this system
  MAINT_WHY=""
  case $1 in
    update) have apt-get || MAINT_WHY="apt isn't available on this system." ;;
    repair) { have dpkg && have apt-get; } || MAINT_WHY="apt isn't available on this system." ;;
    flatpak_unused) have flatpak || MAINT_WHY="Flatpak is not installed." ;;
    fstrim) have fstrim || MAINT_WHY="fstrim is not installed." ;;
    fonts) have fc-cache || MAINT_WHY="fontconfig (fc-cache) is not installed." ;;
    locate) have updatedb || MAINT_WHY="locate/plocate is not installed." ;;
    snap_versions) have snap || MAINT_WHY="Snap is not installed." ;;
    journal_limit) have journalctl || MAINT_WHY="This system doesn't use the systemd journal." ;;
  esac
  [[ -n $MAINT_WHY ]]
}

maint_tasks() { # ID [on|off] → add_task for each step; on|off for the two lasting limits (default on)
  case $1 in
    update)
      add_task "Refresh package lists" m_apt_update
      add_task "Upgrade apt packages" m_apt_upgrade
      have snap && add_task "Refresh snaps" m_snap_refresh
      have flatpak && add_task "Update flatpaks" m_flatpak_update ;;
    repair) add_task "Configure unpacked packages" m_dpkg_configure; add_task "Fix broken dependencies" m_apt_fix ;;
    flatpak_unused) add_task "Remove unused Flatpak runtimes" m_flatpak_unused ;;
    fstrim) add_task "TRIM mounted filesystems" m_fstrim ;;
    free_ram) add_task "Drop page cache" m_drop_caches ;;
    fonts) add_task "Rebuild font cache" m_fc_cache ;;
    locate) add_task "Update locate database" m_updatedb ;;
    snap_versions)
      if [[ ${2:-on} == off ]]; then add_task "Use the default number of snap versions" m_snap_unretain
      else add_task "Keep 2 versions of each snap" m_snap_retain; fi ;;
    journal_limit)
      if [[ ${2:-on} == off ]]; then add_task "Remove journal size limit" m_journal_uncap
      else add_task "Limit journal to ${JOURNAL_KEEP_MB} MB" m_journal_cap; fi ;;
  esac
}

maintenance_menu() {
  local root id mode fn
  while :; do
    local retain cap
    retain=$(have snap && snap_retain) cap=$(journal_cap)
    M_KEY=(1 2 3 4 5 6 7 8 9) M_LABEL=() M_DESC=()
    for id in "${MAINT_IDS[@]}"; do M_LABEL+=("${MAINT_LABEL[$id]}") M_DESC+=("${MAINT_DESC[$id]}"); done
    M_DESC[7]="$([[ $retain == 2 ]] && echo "On: 2 versions per snap — choose to go back to the default" || echo "Keep 2 versions of each snap instead of 3${retain:+ (now: $retain)}")"
    M_DESC[8]="$([[ -n $cap ]] && echo "On: at most $cap MB — choose to change or remove" || echo "Never let system logs grow past ${JOURNAL_KEEP_MB} MB (Settings → Journal size limit)")"
    ui_menu "Maintenance" || return
    id=${MAINT_IDS[MENU_IDX]} mode=""
    if maint_missing "$id"; then toast "${YELLOW}!${NC} $MAINT_WHY"; continue; fi
    case $id in
      update) update_preview || continue ;;
      snap_versions)
        if [[ $retain == 2 ]]; then
          ui_confirm "Go back to snapd's default?" "Snap keeps its usual number of old versions again (3 on most systems)." n || continue
          mode=off
        else
          ui_confirm "Keep only 2 versions of each snap?" \
            "The running version and one to roll back to. Snap removes the extra ones itself at each refresh." y || continue
          mode=on
        fi ;;
      journal_limit)
        if [[ -n $cap && $cap == "$JOURNAL_KEEP_MB" ]]; then
          ui_confirm "Remove the journal size limit?" "systemd goes back to its default (up to 10% of the disk, at most 4 GB)." n || continue
          mode=off
        else
          ui_confirm "Limit system logs to ${JOURNAL_KEEP_MB} MB?" \
            "journald deletes its oldest logs to stay under the limit. Change the number in Settings → Journal size limit." y || continue
          mode=on
        fi ;;
    esac
    new_tasks
    maint_tasks "$id" "$mode"
    root=0
    for fn in "${T_FN[@]}"; do maint_user_step "$fn" || root=1; done
    ((root)) && { ensure_sudo "${M_LABEL[MENU_IDX]} needs administrator rights." || continue; }
    run_tasks "${M_LABEL[MENU_IDX]}"
    refresh_sysinfo
    show_run_results "${M_LABEL[MENU_IDX]}"
  done
}

# ───────────────────────────── overview ─────────────────────────────────────

# What System Overview shows, measured apart from how each app prints it.
sys_facts() { # → OV_OS OV_KERNEL OV_CPU OV_THREADS OV_UPTIME (seconds)
  OV_OS=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
  OV_KERNEL=$(uname -r)
  OV_CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2; exit}')
  OV_THREADS=$(nproc 2>/dev/null || echo 0)
  OV_UPTIME=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
}

pkg_counts() { # → OV_APT OV_SNAP OV_FLATPAK (empty when the tool isn't installed)
  OV_APT="" OV_SNAP="" OV_FLATPAK=""
  have dpkg-query && OV_APT=$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)
  have snap && OV_SNAP=$(snap list 2>/dev/null | tail -n +2 | wc -l)
  have flatpak && OV_FLATPAK=$(flatpak list 2>/dev/null | wc -l)
  return 0
}

disk_rows() { # → mount<TAB>size<TAB>used<TAB>avail<TAB>fstype<TAB>device per real filesystem
  df -B1 --output=target,size,used,avail,fstype,source -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null |
    awk 'NR > 1 && $2 > 0 {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}'
}

mem_facts() { # → OV_RAM_TOTAL OV_RAM_AVAIL OV_SWAP_TOTAL OV_SWAP_USED (bytes)
  read -r OV_RAM_TOTAL OV_RAM_AVAIL OV_SWAP_TOTAL OV_SWAP_USED < <(free -b 2>/dev/null |
    awk '/^Mem:/ {t = $2; a = $7} /^Swap:/ {st = $2; su = $3} END {print t + 0, a + 0, st + 0, su + 0}')
}

overview_lines() {
  local t s u a fs pct barv max=0 b p pk
  sys_facts; pkg_counts
  pk="${OV_APT:-0} apt${OV_SNAP:+, $OV_SNAP snap}${OV_FLATPAK:+, $OV_FLATPAK flatpak}"
  printf '  %sSystem%s\n' "$BOLD" "$NC"
  printf '  %s%-10s%s %s\n' "$DIM" "OS" "$NC" "$OV_OS" "$DIM" "Kernel" "$NC" "$OV_KERNEL" \
    "$DIM" "Uptime" "$NC" "$(uptime -p | sed 's/^up //')" "$DIM" "CPU" "$NC" "${OV_CPU:-unknown} ($OV_THREADS threads)" \
    "$DIM" "Packages" "$NC" "$pk"

  printf '\n  %sStorage%s\n' "$BOLD" "$NC"
  disk_rows | while IFS=$'\t' read -r t s u a fs _; do
    pct=$((u * 100 / s))
    mini_bar barv "$pct" 24
    printf '  %-18s %s %3d%%  %s free of %s  %s%s%s\n' "$t" "$barv" "$pct" "$(human "$a")" "$(human "$s")" "$DIM" "$fs" "$NC"
  done

  disk_history_lines
  hidden_space_lines

  printf '\n  %sLargest folders in your home%s\n' "$BOLD" "$NC"
  while IFS=$'\t' read -r -d '' b p; do
    ((max == 0)) && max=$b
    size_bar barv "$b" "$max" 24
    printf '  %s %9s  %s\n' "$barv" "$(human "$b")" "${p/#$HOME/\~}"
  done < <(top_home_dirs)

  protection_lines
}

TOP_DIRS=12 # the largest folders System Overview lists

top_home_dirs() { # → bytes<TAB>path, NUL-terminated, of the largest folders right in $HOME (du -x), biggest first
  du -0 -xb --max-depth=1 -- "$HOME" 2>/dev/null | sort -z -t$'\t' -k1,1rn |
    while IFS=$'\t' read -r -d '' b p; do [[ $p == "$HOME" ]] || printf '%s\t%s\0' "$b" "$p"; done | head -z -n "$TOP_DIRS"
}

timeshift_snapshot_dirs() { # rsync-mode Timeshift keeps snapshots in /timeshift on the backup disk
  local d
  for d in /timeshift/snapshots /run/timeshift/*/backup/timeshift/snapshots /run/timeshift/backup/timeshift/snapshots; do
    [[ -d $d ]] && printf '%s\n' "$d"
  done
  return 0
}

# Space that is in use but doesn't show up in any of your folders. Report only:
# each of these is a choice for the user, not junk.
hidden_space_rows() { # → kind<TAB>bytes (- unknown)<TAB>path<TAB>count<TAB>note, kind = reserved|swapfile|timeshift
  local s u a fs name type size d n b
  read -r s u a fs < <(df -B1 --output=size,used,avail,fstype / 2>/dev/null | tail -n1)
  # ext4 reserves 5% by default; a bigger gap means something else (a quota) limits "free"
  if [[ $fs == ext[234] && $s =~ ^[0-9]+$ && $u =~ ^[0-9]+$ && $a =~ ^[0-9]+$ ]] &&
    ((s > 0 && s - u - a > 0 && (s - u - a) * 100 / s <= 10)); then
    printf 'reserved\t%s\t/\t1\t%s\n' "$((s - u - a))" "ext4 keeps ~5% for root, so Ubuntu still runs when the disk is full"
  fi
  while read -r name type size; do
    [[ $type == file && $size =~ ^[0-9]+$ ]] &&
      printf 'swapfile\t%s\t%s\t1\t%s\n' "$size" "$name" "extra memory on disk; shrinking it is possible but needs care"
  done < <(swapon --show=NAME,TYPE,SIZE --bytes --noheadings 2>/dev/null)
  while IFS= read -r d; do
    n=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    ((n > 0)) || continue
    b=$(timeout 30 du -sb -- "$d" 2>/dev/null | cut -f1) # hard-linked files count once
    printf 'timeshift\t%s\t%s\t%d\t%s\n' "${b:--}" "$d" "$n" "delete old ones in Timeshift — never by hand$([[ -z $b ]] && echo " (size needs sudo)")"
  done < <(timeshift_snapshot_dirs)
  return 0
}

hidden_space_lines() {
  local rows=() kind b path n note name
  while IFS=$'\t' read -r kind b path n note; do
    case $kind in
      reserved) name="Reserved on / for the system" ;;
      swapfile) name="Swap file $path" ;;
      *) name="Timeshift: $(plural "$n" snapshot)" ;;
    esac
    [[ $b == - ]] && b=0
    rows+=("$name"$'\t'"$b"$'\t'"$note")
  done < <(hidden_space_rows)
  ((${#rows[@]})) || return 0
  printf '\n  %sSpace outside your folders%s\n' "$BOLD" "$NC"
  printf '%s\n' "${rows[@]}" | while IFS=$'\t' read -r name b note; do
    printf '  %-30s %9s  %s%s%s\n' "$name" "$( ((b > 0)) && human "$b" || echo "?")" "$DIM" "$note" "$NC"
  done
}

# System protection, read only: the firewall, AppArmor, automatic security
# updates and Secure Boot. Nothing here needs root or changes anything; when one
# is off the user gets the command to run. CLEANMATE_SYSROOT (tests) reads /etc,
# /sys, /run and /usr/bin under another folder.
SYSROOT=${CLEANMATE_SYSROOT:-}
SECURE_BOOT_VAR=SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c

unit_state() { # is-active|is-enabled UNIT → systemd's one-word answer; nothing when systemd isn't running
  [[ -d $SYSROOT/run/systemd/system ]] && have systemctl || return 0
  timeout 5 systemctl "$1" "$2" 2>/dev/null | head -n1
  return 0
}

apt_periodic() { # NAME → value of APT::Periodic::NAME as APT reads it (the last one set wins; empty when unset)
  local f files=() name
  for f in "$SYSROOT"/etc/apt/apt.conf.d/* "$SYSROOT/etc/apt/apt.conf"; do
    name=${f##*/}
    # APT skips names with other characters and extensions other than .conf (e.g. .dpkg-old)
    [[ -f $f && $name =~ ^[A-Za-z0-9_.-]+$ && ($name != *.* || $name == *.conf) ]] && files+=("$f")
  done
  ((${#files[@]})) || return 0
  sed -nE "s#^[[:space:]]*APT::Periodic::$1[[:space:]]+\"([^\"]*)\".*#\\1#Ip" "${files[@]}" 2>/dev/null | tail -n1
}

apt_settings_readable() { # apt-config answers, and APT's settings folder and files can be read
  local d=$SYSROOT/etc/apt/apt.conf.d f
  have apt-config && timeout 5 apt-config dump >/dev/null 2>&1 || return 1
  [[ ! -e $d || (-d $d && -r $d && -x $d) ]] || return 1
  for f in "$d"/* "$SYSROOT/etc/apt/apt.conf"; do
    [[ ! -f $f || -r $f ]] || return 1
  done
}

protection_rows() { # → id<TAB>on|off|unknown|na<TAB>reason<TAB>command that turns it on (may be empty)
  local f v s
  # firewall: `ufw status` needs root, its config and service don't
  f=$SYSROOT/etc/ufw/ufw.conf
  if [[ -f $f ]]; then
    v=$(sed -nE 's/^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*"?([A-Za-z]*)"?.*/\1/p' "$f" 2>/dev/null | tail -n1)
    s=$(unit_state is-active ufw)
    case $v in
      yes) if [[ $s == inactive || $s == failed ]]; then printf 'firewall\toff\tinactive\tsudo ufw enable\n'
           else printf 'firewall\ton\tufw\t\n'; fi ;;
      no) printf 'firewall\toff\tdisabled\tsudo ufw enable\n' ;;
      *) printf 'firewall\tunknown\tunreadable\t\n' ;;
    esac
  elif [[ $(unit_state is-active firewalld) == active ]]; then
    printf 'firewall\ton\tfirewalld\t\n'
  else
    printf 'firewall\toff\tmissing\tsudo apt install ufw && sudo ufw enable\n'
  fi

  # AppArmor: on in the kernel, and its profiles loaded at boot
  f=$SYSROOT/sys/module/apparmor/parameters/enabled
  v=""
  [[ -r $f ]] && read -r v <"$f" 2>/dev/null
  case $v in
    Y) s=$(unit_state is-active apparmor)
       if [[ $s == inactive || $s == failed ]]; then printf 'apparmor\toff\tservice\tsudo systemctl enable --now apparmor\n'
       else printf 'apparmor\ton\tloaded\t\n'; fi ;;
    N) printf 'apparmor\toff\tkernel\t\n' ;;
    *) printf 'apparmor\tunknown\tunreadable\t\n' ;;
  esac

  # automatic security updates: the package, APT's switch and the daily timer that runs it
  if [[ ! -d $SYSROOT/etc/apt ]]; then
    printf 'updates\tna\tno-apt\t\n'
  elif [[ ! -x $SYSROOT/usr/bin/unattended-upgrade ]]; then
    printf 'updates\toff\tmissing\tsudo apt install unattended-upgrades\n'
  elif ! apt_settings_readable; then
    printf 'updates\tunknown\tunreadable\t\n' # never "off" for settings we couldn't read
  else
    v=$(apt_periodic Unattended-Upgrade)
    if [[ -z $v || $v == 0 || $(apt_periodic Enable) == 0 ]]; then
      printf 'updates\toff\tdisabled\tsudo dpkg-reconfigure -plow unattended-upgrades\n'
    else
      s=$(unit_state is-enabled apt-daily-upgrade.timer)
      if [[ $s == disabled || $s == masked ]]; then
        printf 'updates\toff\ttimer\tsudo systemctl enable --now apt-daily-upgrade.timer\n'
      else printf 'updates\ton\ton\t\n'; fi
    fi
  fi

  # Secure Boot: only on UEFI; mokutil when installed, else the EFI variable (its last byte is the state)
  if [[ ! -d $SYSROOT/sys/firmware/efi ]]; then
    printf 'secureboot\tna\tlegacy\t\n'
  else
    v=""
    if have mokutil; then
      case $(timeout 5 mokutil --sb-state 2>/dev/null) in
        *"SecureBoot enabled"*) v=1 ;;
        *"SecureBoot disabled"*) v=0 ;;
      esac
    fi
    f=$SYSROOT/sys/firmware/efi/efivars/$SECURE_BOOT_VAR
    [[ -z $v && -r $f ]] && v=$(tail -c1 "$f" 2>/dev/null | od -An -tu1 | tr -d ' \n')
    case $v in
      1) printf 'secureboot\ton\ton\t\n' ;;
      0) printf 'secureboot\toff\tfirmware\t\n' ;;
      *) printf 'secureboot\tunknown\tunreadable\t\n' ;;
    esac
  fi
}

protection_text() { # ID STATE REASON → PT_NAME PT_VALUE PT_HINT in English (the desktop app has its own, translated)
  case $1 in
    firewall) PT_NAME="Firewall" ;;
    apparmor) PT_NAME="AppArmor" ;;
    updates) PT_NAME="Automatic security updates" ;;
    *) PT_NAME="Secure Boot" ;;
  esac
  case $2 in
    on) PT_VALUE="On" ;;
    off) PT_VALUE="Off" ;;
    na) PT_VALUE="Not applicable" ;;
    *) PT_VALUE="Unknown" ;;
  esac
  case $1:$3 in
    firewall:ufw) PT_VALUE="On (ufw)" PT_HINT="" ;;
    firewall:firewalld) PT_VALUE="On (firewalld)" PT_HINT="" ;;
    firewall:disabled) PT_HINT="ufw is turned off. To turn it on, run:" ;;
    firewall:inactive) PT_HINT="ufw is set to start but isn't running. To start it, run:" ;;
    firewall:missing) PT_HINT="No firewall is installed. To install ufw and turn it on, run:" ;;
    firewall:*) PT_HINT="Can't read /etc/ufw/ufw.conf." ;;
    apparmor:service) PT_HINT="AppArmor's profiles aren't loaded. To load them, run:" ;;
    apparmor:kernel) PT_HINT="Turned off when the computer starts: remove apparmor=0 from the kernel options in /etc/default/grub, then run sudo update-grub." ;;
    apparmor:unreadable) PT_HINT="Can't read AppArmor's state from the kernel." ;;
    updates:missing) PT_HINT="unattended-upgrades isn't installed. To install it, run:" ;;
    updates:disabled) PT_HINT="Turned off in APT's settings. To turn it on, run:" ;;
    updates:timer) PT_HINT="The daily upgrade timer is off. To turn it on, run:" ;;
    updates:no-apt) PT_HINT="This system doesn't use APT." ;;
    updates:unreadable) PT_HINT="Couldn't read APT's settings." ;;
    secureboot:firmware) PT_HINT="Turn it on in your computer's firmware (UEFI) settings." ;;
    secureboot:legacy) PT_HINT="This computer starts without UEFI, so there is no Secure Boot." ;;
    secureboot:unreadable) PT_HINT="Can't read the Secure Boot state." ;;
    *) PT_HINT="" ;;
  esac
}

protection_lines() {
  local id state reason cmd mark
  printf '\n  %sSystem protection%s %s(read only)%s\n' "$BOLD" "$NC" "$DIM" "$NC"
  while IFS=$'\t' read -r id state reason cmd; do
    protection_text "$id" "$state" "$reason"
    case $state in
      on) mark="${GREEN}✓${NC}" ;;
      off) mark="${YELLOW}!${NC}" ;;
      na) mark="${DIM}–${NC}" ;;
      *) mark="${DIM}?${NC}" ;;
    esac
    printf '  %s %-28s %s\n' "$mark" "$PT_NAME" "$PT_VALUE"
    [[ -n $PT_HINT ]] && printf '      %s%s%s\n' "$DIM" "$PT_HINT" "$NC"
    [[ -n $cmd ]] && printf '      %s\n' "$cmd"
  done < <(protection_rows)
  return 0
}

overview() {
  local tmp
  tmp=$(mktemp -p "$SESSION_TMP")
  (overview_lines >"$tmp") &
  UI_BUSY_TITLE="System Overview"
  ui_busy "Measuring your system… (large home folders take a moment)" $! || { rm -f "$tmp"; return; }
  mapfile -t V_LINES <"$tmp"
  rm -f "$tmp"
  V_LINES=("" "${V_LINES[@]}")
  ui_view "System Overview"
}

# ───────────────────────────── space lens ───────────────────────────────────
#
# Interactive disk map: entries of a folder sorted by size, drill in with →,
# go up with ←, select and move to Trash. Sizes are cached per folder.

SL_TMP=""
SL_DIR=""
SL_TOTAL=0
declare -A SL_CACHE=() SL_SEL=()
declare -a SL_SIZE=() SL_PATH=() SL_HUMAN=()

human_lines() { # bytes per line on stdin → human sizes, one awk process for all
  awk '{b = $1; split("B KB MB GB TB PB", u, " "); i = 1
        while (b >= 1024 && i < 6) {b /= 1024; i++}
        if (i == 1) printf "%d B\n", b; else printf "%.1f %s\n", b, u[i]}'
}

sl_load() { # DIR — load DIR's entries into SL_*; returns 1 if cancelled
  local dir=$1 f b p
  [[ -n $SL_TMP ]] || SL_TMP=$(mktemp -d -p "$SESSION_TMP") || return 1
  f=${SL_CACHE[$dir]:-}
  if [[ -z $f || ! -s $f ]]; then
    f=$(mktemp -p "$SL_TMP") || return 1
    (try_root du -xab --max-depth=1 -- "$dir" 2>/dev/null | sort -t$'\t' -k1,1rn >"$f") &
    UI_BUSY_TITLE="Space Lens"
    ui_busy "Measuring ${dir/#$HOME/\~}…" $! || { rm -f "$f"; return 1; }
    SL_CACHE[$dir]=$f
  fi
  SL_SIZE=() SL_PATH=() SL_SEL=() SL_TOTAL=0
  while IFS=$'\t' read -r b p; do
    if [[ $p == "$dir" ]]; then SL_TOTAL=$b; continue; fi
    SL_SIZE+=("$b") SL_PATH+=("$p")
    ((${#SL_PATH[@]} >= 500)) && break
  done <"$f"
  mapfile -t SL_HUMAN < <(((${#SL_SIZE[@]})) && printf '%s\n' "${SL_SIZE[@]}" | human_lines)
  SL_DIR=$dir
}

sl_row() {
  local i=$1 mark="  " box name barv sz pct clr nw
  (($2)) && mark="${ACCENT}▸${NC} "
  if [[ -n ${SL_SEL[$i]} ]]; then box="${GREEN}●${NC}"; else box="${DIM}○${NC}"; fi
  size_bar barv "${SL_SIZE[i]}" "${SL_SIZE[0]}" 20
  size_colorv clr "${SL_SIZE[i]}"
  printf -v sz '%9s' "${SL_HUMAN[i]}"
  printf -v pct '%3d%%' $((SL_SIZE[i] * 100 / (SL_TOTAL > 0 ? SL_TOTAL : 1)))
  nw=$((UI_W - 46)); ((nw < 12)) && nw=12
  name=${SL_PATH[i]##*/}
  if [[ -d ${SL_PATH[i]} && ! -L ${SL_PATH[i]} ]]; then
    fitv name "$name/" "$nw"; name="${BLUE}${BOLD}$name${NC}"
  else
    fitv name "$name" "$nw"; (($2)) && name="${BOLD}$name${NC}"
  fi
  fl " $mark$box $barv $clr$sz$NC ${DIM}$pct${NC}  $name"
}

sl_text() { TEXT=${SL_PATH[$1]##*/}; }
sl_top() {
  local crumb=${SL_DIR/#$HOME/\~}
  fl ""
  fitv crumb "$crumb" $((UI_W - 30))
  local tt ni; humanv tt "$SL_TOTAL"; pluralv ni ${#SL_PATH[@]} item
  fl "  ${BOLD}📁 ${crumb%%+( )}${NC}   ${DIM}$tt · $ni${NC}"
  fl ""
  ((${#SL_PATH[@]})) || fl "  ${DIM}This folder is empty — press ← to go up.${NC}"
  return 0
}

sl_bottom() {
  local i n=0 tot=0 p=${SL_PATH[$L_CUR]:-} kind info
  for i in "${!SL_SEL[@]}"; do tot=$((tot + SL_SIZE[i])); ((++n)); done
  fl ""
  local sn st; pluralv sn "$n" item; humanv st "$tot"
  fl "  ${BOLD}Selected${NC} $sn · ${BOLD}$st${NC}"
  if [[ -n $p ]]; then
    if [[ -L $p ]]; then kind="link"; elif [[ -d $p ]]; then kind="folder — press → to open"; else kind="file"; fi
    fitv info "${p/#$HOME/\~}  ($kind)" $((UI_W - 6))
    fl "  ${ACCENT}ℹ${NC} ${DIM}$info${NC}"
  fi
}

sl_trash() { # CURSOR
  local i p n=0 tot=0 bad=0 fail=0 paths=()
  ((${#SL_SEL[@]})) || SL_SEL[$1]=1
  for i in "${!SL_SEL[@]}"; do
    p=${SL_PATH[i]}
    if [[ $p != "$HOME"/* ]] || is_protected "$p" || touches_exclusion "$p"; then ((++bad)); continue; fi
    paths+=("$p"); tot=$((tot + SL_SIZE[i])); ((++n))
  done
  if ((n == 0)); then
    SL_SEL=()
    toast "${YELLOW}!${NC} Only items inside your home folder and not excluded in Settings can be moved to Trash here."
    return
  fi
  ui_confirm "Move $(plural "$n" item) to Trash?" "$(human "$tot")$( ((bad)) && echo " · $bad item(s) outside home or excluded skipped") — press z to undo." y || return
  UNDO_BATCH=()
  for p in "${paths[@]}"; do move_to_trash "$p" >/dev/null 2>&1 || ((++fail)); done
  if ((DRY_RUN)); then
    toast "${MAGENTA}[dry-run]${NC} Would move $(plural "$n" item) ($(human "$tot")) to Trash"
    SL_SEL=()
    return
  fi
  SL_CACHE=() # every ancestor's size changed
  sl_load "$SL_DIR"
  refresh_sysinfo
  if ((fail)); then toast "${YELLOW}!${NC} Moved $((n - fail)) of $n items to Trash ($fail failed) — z to undo."
  else toast "${GREEN}✔${NC} Moved $(plural "$n" item) ($(human "$tot")) to Trash — press z to undo"; fi
}

space_lens() { # START_DIR
  local cur=0 scroll=0 p prev i parent
  declare -A pos=()
  sl_load "$(realpath -- "$1")" || return
  while :; do
    L_TITLE="Space Lens" L_TOP=sl_top L_BOTTOM=sl_bottom L_ROW=sl_row L_FOCUSABLE="" L_TEXT=sl_text L_VIEW=0
    L_COUNT=${#SL_PATH[@]} L_CUR=$cur L_SCROLL=$scroll
    if ((${#UNDO_BATCH[@]})); then hints "→" open "←" up space select "!t" "move to Trash" z undo o "show in Files" q close
    else hints "→" open "←" up space select "!t" "move to Trash" o "show in Files" r refresh q close; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL p=${SL_PATH[cur]:-}
    case $KEY in
      enter | right)
        [[ -n $p && -d $p && ! -L $p ]] || continue
        pos[$SL_DIR]="$cur $scroll"
        sl_load "$p" && cur=0 scroll=0 ;;
      left | backspace)
        [[ $SL_DIR == / ]] && continue
        prev=$SL_DIR parent=$(dirname "$SL_DIR")
        sl_load "$parent" || continue
        if [[ -n ${pos[$parent]:-} ]]; then read -r cur scroll <<<"${pos[$parent]}"
        else
          cur=0 scroll=0
          for i in "${!SL_PATH[@]}"; do [[ ${SL_PATH[i]} == "$prev" ]] && { cur=$i; break; }; done
        fi ;;
      space)
        [[ -n $p ]] || continue
        if [[ -n ${SL_SEL[$cur]} ]]; then unset "SL_SEL[$cur]"; else SL_SEL[$cur]=1; fi
        list_move 1; cur=$L_CUR ;;
      o)
        [[ -n $p ]] || continue
        if [[ -d $p ]]; then xdg-open "$p" >/dev/null 2>&1 & else xdg-open "$(dirname "$p")" >/dev/null 2>&1 & fi
        disown 2>/dev/null
        toast "${ACCENT}↗${NC} Opened in Files" ;;
      r) unset "SL_CACHE[$SL_DIR]"; sl_load "$SL_DIR" ;;
      t | delete) sl_trash "$cur" ;;
      z)
        ((${#UNDO_BATCH[@]})) || continue
        undo_trash; SL_CACHE=(); sl_load "$SL_DIR"; refresh_sysinfo; undo_toast ;;
      q | esc) return ;;
    esac
  done
}

space_lens_menu() {
  while :; do
    M_KEY=(1 2 3)
    M_LABEL=("Home folder" "Whole disk" "Choose a folder…")
    M_DESC=("Explore ${HOME}" "Explore / — use sudo for exact sizes of system folders" "Any folder you like")
    ui_menu "Space Lens" || return
    case $MENU_IDX in
      0) space_lens "$HOME" ;;
      1) space_lens / ;;
      2)
        ui_input "Folder:" "$HOME" || continue
        REPLY_TEXT=${REPLY_TEXT/#\~/$HOME}
        if [[ -d $REPLY_TEXT ]]; then space_lens "$REPLY_TEXT"; else toast "${RED}✘${NC} Not a folder: $REPLY_TEXT"; fi ;;
    esac
  done
}

# ───────────────────────────── duplicate finder ─────────────────────────────
#
# Same size → same hash of the first 64 KB → same full MD5. Hidden folders
# and node_modules are skipped. The oldest copy of each group is kept.

dedupe_on() { # FIELDS — keep only lines whose key (first N tab fields) occurs more than once
  awk -F'\t' -v k="$1" '{key = $1; for (j = 2; j <= k; j++) key = key FS $j
                          n[key]++; line[NR] = $0; kk[NR] = key}
                        END {for (i = 1; i <= NR; i++) if (n[kk[i]] > 1) print line[i]}'
}

dup_scan() { # MIN_KB OUT STATUS DIR... — background worker; skips excluded folders
  local min=$1 out=$2 st=$3 size mt p h i=0 n dirs=()
  shift 3
  echo "Listing files…" >"$st"
  outside_exclusions dirs "$@"
  exclusion_prune
  ((${#dirs[@]})) || { : >"$out"; return 0; }
  find "${dirs[@]}" -xdev -mindepth 1 "${XPRUNE[@]}" \( -name '.*' -o -name node_modules \) -prune -o \
    -type f -size +"${min}"k -printf '%s\t%T@\t%p\n' 2>/dev/null | dedupe_on 1 >"$out.cand"
  n=$(wc -l <"$out.cand")
  while IFS=$'\t' read -r size mt p; do
    ((++i % 25 == 0)) && echo "Comparing $i of $n files with matching sizes…" >"$st"
    h=$(head -c 65536 -- "$p" 2>/dev/null | md5sum) || continue
    printf '%s\t%s\t%s\t%s\n' "$size" "${h%% *}" "$mt" "$p"
  done <"$out.cand" | dedupe_on 2 >"$out.part"
  n=$(wc -l <"$out.part") i=0
  while IFS=$'\t' read -r size h mt p; do
    ((++i % 5 == 0)) && echo "Verifying $i of $n likely duplicates…" >"$st"
    if ((size > 65536)); then
      h=$(md5sum -- "$p" 2>/dev/null) || continue
      h=${h%% *}; h=${h#\\}
    fi
    printf '%s\t%s\t%s\t%s\n' "$size" "$h" "$mt" "$p"
  done <"$out.part" | dedupe_on 2 | sort -t$'\t' -k1,1rn -k2,2 -k3,3n >"$out"
  rm -f "$out.cand" "$out.part"
}

declare -a D_SIZE=() D_HASH=() D_MT=() D_PATH=() DR_KIND=() DR_REF=()
declare -A D_SEL=()

dup_rows() { # rebuild display rows from D_* (group header, files, spacer)
  local i last=""
  DR_KIND=() DR_REF=()
  for i in "${!D_PATH[@]}"; do
    if [[ ${D_SIZE[i]}:${D_HASH[i]} != "$last" ]]; then
      ((${#DR_KIND[@]})) && { DR_KIND+=(s); DR_REF+=(""); }
      DR_KIND+=(g); DR_REF+=("$i")
      last=${D_SIZE[i]}:${D_HASH[i]}
    fi
    DR_KIND+=(f); DR_REF+=("$i")
  done
}


dup_autoselect() { # select every copy except the oldest of each group
  local i last=""
  D_SEL=()
  for i in "${!D_PATH[@]}"; do
    [[ ${D_SIZE[i]}:${D_HASH[i]} == "$last" ]] && D_SEL[$i]=1
    last=${D_SIZE[i]}:${D_HASH[i]}
  done
}

dup_text() { TEXT=${D_PATH[${DR_REF[$1]}]}; }
dup_focusable() { [[ ${DR_KIND[$1]} == f ]]; }

dup_row() {
  local kind=${DR_KIND[$1]} i=${DR_REF[$1]} mark="  " box d p n pw
  case $kind in
    s) fl "" ;;
    g)
      local j=$i each can
      n=0
      while ((j < ${#D_PATH[@]})) && [[ ${D_SIZE[j]}:${D_HASH[j]} == "${D_SIZE[i]}:${D_HASH[i]}" ]]; do ((++n, ++j)); done
      humanv each "${D_SIZE[i]}"; humanv can $(((n - 1) * D_SIZE[i]))
      fl "   ${BOLD}$n copies${NC} ${DIM}· $each each · $can can be freed${NC}" ;;
    f)
      (($2)) && mark="${ACCENT}▸${NC} "
      if [[ -n ${D_SEL[$i]} ]]; then box="${RED}●${NC}"; else box="${GREEN}○${NC}"; fi
      printf -v d '%(%Y-%m-%d)T' "${D_MT[i]%.*}"
      p=${D_PATH[i]/#$HOME/\~}
      pw=$((UI_W - 22))
      ((${#p} > pw)) && p="…${p: -$((pw - 1))}"
      (($2)) && p="${BOLD}$p${NC}"
      fl " $mark  $box ${DIM}$d${NC}  $p" ;;
  esac
}

dup_top() {
  local i tot=0 groups=0 last=""
  for i in "${!D_PATH[@]}"; do
    if [[ ${D_SIZE[i]}:${D_HASH[i]} == "$last" ]]; then tot=$((tot + D_SIZE[i])); else ((++groups)); fi
    last=${D_SIZE[i]}:${D_HASH[i]}
  done
  fl ""
  fl_card "${YELLOW}${BOLD}$(human "$tot")${NC} ${BOLD}can be freed by removing duplicates${NC}" \
    "${DIM}$(plural "$groups" group) · $(plural ${#D_PATH[@]} file) · ${GREEN}○${NC}${DIM} keep  ${RED}●${NC}${DIM} remove${NC}"
}

dup_bottom() {
  local i n=0 tot=0 r=${DR_REF[$L_CUR]}
  for i in "${!D_SEL[@]}"; do tot=$((tot + D_SIZE[i])); ((++n)); done
  fl ""
  local fn ft; pluralv fn "$n" file; humanv ft "$tot"
  fl "  ${BOLD}To remove${NC} $fn · ${BOLD}$ft${NC}"
  [[ -n $r ]] && fl "  ${ACCENT}ℹ${NC} ${DIM}${D_PATH[r]/#$HOME/\~}${NC}"
}

dup_trash() {
  local i j last="" kept=1 n=0 tot=0 bad=0 keep_s=() keep_h=() keep_m=() keep_p=()
  # every group must keep at least one copy
  for i in "${!D_PATH[@]}"; do
    if [[ ${D_SIZE[i]}:${D_HASH[i]} != "$last" ]]; then ((kept)) || bad=1; kept=0; fi
    [[ -n ${D_SEL[$i]} ]] || kept=1
    last=${D_SIZE[i]}:${D_HASH[i]}
  done
  ((kept)) || bad=1
  if ((bad)); then toast "${RED}✘${NC} Keep at least one copy in every group (○)."; return; fi
  for i in "${!D_SEL[@]}"; do tot=$((tot + D_SIZE[i])); ((++n)); done
  ((n)) || { toast "${YELLOW}!${NC} Nothing selected."; return; }
  ui_confirm "Move $(plural "$n" duplicate) to Trash?" "$(human "$tot") — one copy of each file is kept. z undoes it." y || return
  UNDO_BATCH=() DUP_TRASHED=()
  for i in "${!D_PATH[@]}"; do
    if [[ -n ${D_SEL[$i]} ]] && move_to_trash "${D_PATH[i]}" >/dev/null 2>&1 && ((!DRY_RUN)); then
      DUP_TRASHED+=("${D_SIZE[i]}"$'\t'"${D_HASH[i]}"$'\t'"${D_MT[i]}"$'\t'"${D_PATH[i]}")
      continue
    fi
    keep_s+=("${D_SIZE[i]}") keep_h+=("${D_HASH[i]}") keep_m+=("${D_MT[i]}") keep_p+=("${D_PATH[i]}")
  done
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would move $(plural "$n" file) ($(human "$tot")) to Trash"; return; fi
  # drop groups that are now down to one file
  D_SIZE=() D_HASH=() D_MT=() D_PATH=() D_SEL=()
  for i in "${!keep_p[@]}"; do
    j=0
    [[ $i -gt 0 && ${keep_s[i - 1]}:${keep_h[i - 1]} == "${keep_s[i]}:${keep_h[i]}" ]] && j=1
    [[ $((i + 1)) -lt ${#keep_p[@]} && ${keep_s[i + 1]}:${keep_h[i + 1]} == "${keep_s[i]}:${keep_h[i]}" ]] && j=1
    ((j)) && D_SIZE+=("${keep_s[i]}") D_HASH+=("${keep_h[i]}") D_MT+=("${keep_m[i]}") D_PATH+=("${keep_p[i]}")
  done
  dup_rows
  refresh_sysinfo
  toast "${GREEN}✔${NC} Moved $(plural "$n" duplicate) ($(human "$tot")) to Trash — press z to undo"
}

dup_undo() { # put the last batch back and show those files in their groups again
  local i rows=() a b c d
  undo_trash
  for i in "${!D_PATH[@]}"; do rows+=("${D_SIZE[i]}"$'\t'"${D_HASH[i]}"$'\t'"${D_MT[i]}"$'\t'"${D_PATH[i]}"); done
  D_SIZE=() D_HASH=() D_MT=() D_PATH=() D_SEL=()
  while IFS=$'\t' read -r a b c d; do
    [[ -e $d ]] && D_SIZE+=("$a") D_HASH+=("$b") D_MT+=("$c") D_PATH+=("$d")
  done < <(printf '%s\n' "${rows[@]}" "${DUP_TRASHED[@]}" | grep -v '^$' | sort -t$'\t' -k1,1rn -k2,2 -k3,3n)
  DUP_TRASHED=()
  dup_rows
  refresh_sysinfo
  undo_toast
}

find_duplicates() { # MIN_MB DIR...
  local tmp out st cur=0 scroll=0 r min=$1 where
  shift
  tmp=$(mktemp -d -p "$SESSION_TMP") || return
  out=$tmp/dups st=$tmp/status
  (dup_scan $((min * 1024)) "$out" "$st" "$@") &
  UI_BUSY_TITLE="Duplicates"
  UI_BUSY_STATUS=$st
  where=$(printf '%s, ' "${@/#$HOME/\~}"); where=${where%, }
  ui_busy "Looking for duplicates in $where…" $!
  r=$?
  UI_BUSY_STATUS=""
  ((r == 0)) || { rm -rf "$tmp"; return; }
  D_SIZE=() D_HASH=() D_MT=() D_PATH=()
  while IFS=$'\t' read -r a b c d; do D_SIZE+=("$a") D_HASH+=("$b") D_MT+=("$c") D_PATH+=("$d"); done <"$out"
  rm -rf "$tmp"
  if ((${#D_PATH[@]} == 0)); then toast "${GREEN}✔${NC} No duplicate files found."; return; fi
  dup_rows
  dup_autoselect
  while :; do
    if ((${#D_PATH[@]} == 0)); then
      ((${#UNDO_BATCH[@]})) || { toast "${GREEN}✔${NC} No duplicates left."; return; }
      : # everything was trashed — stay, so z can still put it back
    fi
    L_TITLE="Duplicates" L_TOP=dup_top L_BOTTOM=dup_bottom L_ROW=dup_row L_FOCUSABLE=dup_focusable L_TEXT=dup_text
    L_VIEW=0 L_COUNT=${#DR_KIND[@]} L_CUR=$cur L_SCROLL=$scroll
    if ((${#UNDO_BATCH[@]})); then hints space "keep/remove" "!t" "move to Trash" z undo a "auto-select" n none q back
    else hints space "keep/remove" "!t" "move to Trash" a "auto-select" n none o "show in Files" q back; fi
    L_HINTS=$HINTS
    ui_list
    cur=$L_CUR scroll=$L_SCROLL r=${DR_REF[cur]}
    case $KEY in
      space)
        if [[ -n ${D_SEL[$r]} ]]; then unset "D_SEL[$r]"; else D_SEL[$r]=1; fi
        list_move 1; cur=$L_CUR ;;
      a) dup_autoselect ;;
      n) D_SEL=() ;;
      o) xdg-open "$(dirname "${D_PATH[r]}")" >/dev/null 2>&1 & disown 2>/dev/null; toast "${ACCENT}↗${NC} Opened in Files" ;;
      t | delete) dup_trash; cur=0 scroll=0 ;;
      z) ((${#UNDO_BATCH[@]})) && { dup_undo; cur=0 scroll=0; } ;;
      q | esc | left | backspace) return ;;
    esac
  done
}

duplicates_menu() {
  local min
  while :; do
    M_KEY=(1 2 3)
    M_LABEL=("Home folder" "Pictures & Downloads" "Choose a folder…")
    M_DESC=("Files over 1 MB anywhere in your home" "Typical places for repeated photos and downloads" "Pick a folder and a minimum size")
    ui_menu "Duplicates" || return
    case $MENU_IDX in
      0) find_duplicates 1 "$HOME" ;;
      1)
        local d dirs=()
        for d in "$(xdg-user-dir PICTURES 2>/dev/null)" "$(xdg-user-dir DOWNLOAD 2>/dev/null)"; do
          [[ -d $d && $d != "$HOME" ]] && dirs+=("$d")
        done
        ((${#dirs[@]})) || { toast "${YELLOW}!${NC} No Pictures or Downloads folder found."; continue; }
        find_duplicates 0 "${dirs[@]}" ;;
      2)
        ui_input "Folder:" "$HOME" || continue
        REPLY_TEXT=${REPLY_TEXT/#\~/$HOME}
        [[ -d $REPLY_TEXT ]] || { toast "${RED}✘${NC} Not a folder: $REPLY_TEXT"; continue; }
        d=$REPLY_TEXT
        ui_input "Minimum file size in MB:" 1 || continue
        min=$REPLY_TEXT
        [[ $min =~ ^[0-9]+$ ]] || { toast "${RED}✘${NC} Invalid size: $min"; continue; }
        find_duplicates "$min" "$d" ;;
    esac
  done
}

# ───────────────────────────── settings & automation ────────────────────────

SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cleanmate/settings"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN_PATH="$HOME/.local/bin/cleanmate"
ALIAS_PATH="$HOME/.local/bin/cm" # shorthand
APP_ID="com.homielab.CleanMate" # also the desktop app's GApplication id — GNOME matches them
APP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_ID.desktop"
ICON_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/$APP_ID.svg"
SELF=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")
declare -A CFG=()

# The numbers in the settings file: KEY → "MIN MAX DEFAULT". The terminal app's Settings and
# `--json settings` / `settings-set` (the desktop app) read and write the same file.
declare -A SETTING_RANGE=(
  [update_check]="0 1 1" [low_disk_pct]="0 50 10" [journal_days]="1 365 7" [journal_mb]="16 10000 100"
  [log_max_mb]="10 100000 50" [app_log_days]="1 365 3" [tmp_days]="1 365 10" [cache_days]="1 365 30"
  [node_modules_days]="7 3650 90" [installer_days]="7 3650 30" [download_days]="7 3650 90"
  [ai_history_days]="1 3650 30")
SETTING_KEYS=(update_check low_disk_pct journal_days journal_mb log_max_mb app_log_days tmp_days cache_days
  node_modules_days installer_days download_days ai_history_days) # the order of the Settings screens
# Settings with a fixed list of values, the default first. `language` is the desktop app's (the terminal
# app stays English): it reads the file itself at start-up.
declare -A SETTING_CHOICES=([language]="system en vi")
SETTING_VALUE_RE='^[0-9a-z]+$' # what a line of the settings file may hold; each key checks its own values

setting_valid() { # KEY VALUE → a number within the key's range
  local -a r
  [[ -n ${SETTING_RANGE[$1]:-} && $2 =~ ^[0-9]{1,6}$ ]] || return 1
  read -ra r <<<"${SETTING_RANGE[$1]}"
  ((10#$2 >= r[0] && 10#$2 <= r[1]))
}

setting_choice() { # VAR KEY → VAR = the saved value when it is one of the key's choices, else the default
  local -a c
  read -ra c <<<"${SETTING_CHOICES[$2]}"
  if [[ " ${c[*]} " == *" ${CFG[$2]:-} "* && -n ${CFG[$2]:-} ]]; then printf -v "$1" '%s' "${CFG[$2]}"
  else printf -v "$1" '%s' "${c[0]}"; fi
}

setting() { # VAR KEY → VAR = the saved value, or the default when it's missing or out of range
  local -a r
  read -ra r <<<"${SETTING_RANGE[$2]}"
  if setting_valid "$2" "${CFG[$2]:-}"; then printf -v "$1" '%d' "$((10#${CFG[$2]}))"
  else printf -v "$1" '%d' "${r[2]}"; fi
}

apply_settings() {
  setting JOURNAL_KEEP_DAYS journal_days
  setting JOURNAL_KEEP_MB journal_mb
  JOURNAL_KEEP_BYTES=$((JOURNAL_KEEP_MB * 1024 * 1024))
  setting TMP_DAYS tmp_days
  setting CACHE_DAYS cache_days
  setting NM_DAYS node_modules_days
  setting OLD_INSTALLER_DAYS installer_days
  setting OLD_DOWNLOAD_DAYS download_days
  setting LOW_DISK_PCT low_disk_pct
  setting LOG_MAX_MB log_max_mb
  setting APPLOG_DAYS app_log_days
  setting AI_HISTORY_DAYS ai_history_days
  setting UPDATE_CHECK update_check
  local _i
  for _i in "${ITEM_IDS[@]}"; do # keep "older than N days" descriptions in sync
    [[ ${ITEM_CAT[$_i]} == ai ]] && ITEM_DESC[$_i]=${ITEM_DESC[$_i]//older than+([0-9]) days/older than $AI_HISTORY_DAYS days}
  done
  ITEM_DESC[old_installers]=${ITEM_DESC[old_installers]//more than +([0-9]) days/more than $OLD_INSTALLER_DAYS days}
  ITEM_DESC[old_downloads]=${ITEM_DESC[old_downloads]//more than +([0-9]) days/more than $OLD_DOWNLOAD_DAYS days}
  ITEM_DESC[old_screenshots]=${ITEM_DESC[old_screenshots]//more than +([0-9]) days/more than $OLD_DOWNLOAD_DAYS days}
  ITEM_DESC[big_logs]="Live logs in /var/log over ${LOG_MAX_MB} MB, emptied in place — services keep logging normally."
  ITEM_DESC[app_logs]="Log files of apps (VS Code, Slack, …) not written for ${APPLOG_DAYS}+ days."
  ITEM_LABEL[app_cache]="Stale app caches (>${CACHE_DAYS} days)"
  ITEM_DESC[app_cache]="Files under ~/.cache not modified or read for ${CACHE_DAYS}+ days."
  ITEM_DESC[journal]="Archived system logs. Keeps the last ${JOURNAL_KEEP_DAYS} days and at most ${JOURNAL_KEEP_MB} MB."
  ITEM_DESC[tmp]="Your files in /tmp and /var/tmp not touched for ${TMP_DAYS}+ days."
  ITEM_DESC[node_modules]="node_modules of projects untouched for ${NM_DAYS}+ days. Restore with npm/yarn/pnpm install."
  ITEM_DESC[stale_build_dirs]="Cargo target/, Python .venv/ and CocoaPods Pods/ folders of projects untouched for ${NM_DAYS}+ days. Moved to the Trash; rebuilt by cargo build, pip/uv install or pod install."
}

save_setting() { # KEY VALUE — change one line of the settings file; the other app may have changed others
  local k tmp
  local -A cur=()
  CFG[$1]=$2
  ((DRY_RUN)) && return 0
  load_kv "$SETTINGS_FILE" cur "$SETTING_VALUE_RE"
  cur[$1]=$2
  mkdir -p "${SETTINGS_FILE%/*}" && tmp=$(mktemp -p "${SETTINGS_FILE%/*}" .settings.XXXXXX) || return
  for k in "${!cur[@]}"; do printf '%s=%s\n' "$k" "${cur[$k]}"; done | sort >"$tmp" && mv -f -- "$tmp" "$SETTINGS_FILE" ||
    { rm -f -- "$tmp"; return 1; }
}

load_settings() { # the settings file and remembered selections, as saved (by either app)
  CFG=() PREF=()
  load_kv "$PREF_FILE" PREF '^[01]$'
  load_kv "$SETTINGS_FILE" CFG "$SETTING_VALUE_RE"
  apply_settings
  load_exclusions
}

# Never clean: folders in your home that Large & Old Files, Duplicates, Space Lens, stale
# node_modules and project build folders and old installers leave alone, and that nothing moves to
# the Trash. Smart Scan's caches and logs are rebuilt by their apps, so those items don't look here.
# One absolute path per line; your home folder, a folder above it, anything outside it and folders
# reached through a symbolic link are refused (and ignored when the file has them).
EXCLUDE_FILE="${SETTINGS_FILE%/*}/exclude"
EXCLUDES=()
EX_WHY="" EX_PATH=""
EX_HOME_REAL=""

exclusion_check() { # VAR PATH → VAR = PATH tidied; returns 1 with EX_WHY when it can't be excluded
  local -n __ex=$1
  local __p=$2
  EX_WHY="" __ex=""
  [[ $__p == /* ]] || { EX_WHY="Not a full path: $__p"; return 1; }
  [[ $__p != *[[:cntrl:]]* ]] || { EX_WHY="The folder's name has control characters"; return 1; }
  __p=$(realpath -m -s -- "$__p")
  __ex=$__p
  if [[ $__p == / || $__p == "$HOME" || $HOME == "$__p"/* ]]; then
    EX_WHY="Your home folder or a folder above it is too broad to exclude"; return 1
  fi
  [[ $__p == "$HOME"/* ]] || { EX_WHY="Only folders inside your home folder can be excluded"; return 1; }
  [[ -n $EX_HOME_REAL ]] || EX_HOME_REAL=$(realpath -m -- "$HOME")
  if [[ -L $__p || $(realpath -m -- "$__p") != "$EX_HOME_REAL${__p#"$HOME"}" ]]; then
    EX_WHY="Folders reached through a symbolic link can't be excluded"; return 1
  fi
}

load_exclusions() { # → EXCLUDES: the valid lines of EXCLUDE_FILE, each once
  local line p
  local -A seen=()
  EXCLUDES=()
  [[ -f $EXCLUDE_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] && exclusion_check p "$line" && [[ -z ${seen[$p]:-} ]] || continue
    seen[$p]=1 EXCLUDES+=("$p")
  done <"$EXCLUDE_FILE"
}

save_exclusions() { # EXCLUDES → EXCLUDE_FILE (written next to it, then renamed)
  local tmp
  mkdir -p "${EXCLUDE_FILE%/*}" && tmp=$(mktemp -p "${EXCLUDE_FILE%/*}" .exclude.XXXXXX) || return
  { ((${#EXCLUDES[@]} == 0)) || printf '%s\n' "${EXCLUDES[@]}"; } >"$tmp" && mv -f -- "$tmp" "$EXCLUDE_FILE" ||
    { rm -f -- "$tmp"; return 1; }
}

exclusion_add() { # PATH — EX_WHY says what happened, EX_PATH is PATH tidied; 1 when refused or not saved
  local p e
  load_exclusions # the other app may have changed the list
  exclusion_check p "$1"
  EX_PATH=$p
  [[ -z $EX_WHY ]] || return 1
  [[ -d $p ]] || { EX_WHY="Not a folder: $p"; return 1; }
  for e in "${EXCLUDES[@]}"; do [[ $e == "$p" ]] && { EX_WHY="already in the list"; return 0; }; done
  ((DRY_RUN)) && { EX_WHY="would be added"; return 0; }
  EXCLUDES+=("$p")
  save_exclusions || { load_exclusions; EX_WHY="Could not save ${EXCLUDE_FILE/#$HOME/\~}"; return 1; }
  EX_WHY="added"
}

exclusion_remove() { # PATH — EX_WHY says what happened; 1 when it isn't in the list or not saved
  local p=$1 e listed=0 kept=()
  load_exclusions
  [[ $p == /* ]] && p=$(realpath -m -s -- "$p")
  for e in "${EXCLUDES[@]}"; do if [[ $e == "$p" ]]; then listed=1; else kept+=("$e"); fi; done
  ((listed)) || { EX_WHY="Not in the list: $p"; return 1; }
  ((DRY_RUN)) && { EX_WHY="would be removed"; return 0; }
  EXCLUDES=("${kept[@]}")
  save_exclusions || { load_exclusions; EX_WHY="Could not save ${EXCLUDE_FILE/#$HOME/\~}"; return 1; }
  EX_WHY="removed"
}

in_exclusion() { # PATH (absolute, tidied) — one of your excluded folders or inside one
  local e
  for e in "${EXCLUDES[@]}"; do [[ $1 == "$e" || $1 == "$e"/* ]] && return 0; done
  return 1
}

touches_exclusion() { # PATH (absolute, tidied) — in an excluded folder, or holding one (moving it takes that along)
  local e
  for e in "${EXCLUDES[@]}"; do [[ $1 == "$e" || $1 == "$e"/* || $e == "$1"/* ]] && return 0; done
  return 1
}

exclusion_prune() { # → XPRUNE: find tests that skip your excluded folders, "( -path A -o … ) -prune -o"; empty without any
  local e g
  XPRUNE=()
  for e in "${EXCLUDES[@]}"; do
    g=${e//\\/\\\\} g=${g//\*/\\*} g=${g//\?/\\?} g=${g//\[/\\[} # the path itself, not a pattern
    XPRUNE+=(-o -path "$g")
  done
  ((${#XPRUNE[@]} == 0)) || XPRUNE=(\( "${XPRUNE[@]:1}" \) -prune -o)
}

outside_exclusions() { # VAR START… → VAR = the starting folders (tidied) that aren't in an excluded folder
  local -n __out=$1
  local __d
  shift
  __out=()
  for __d; do
    __d=$(realpath -m -s -- "$__d")
    in_exclusion "$__d" || __out+=("$__d")
  done
}

notify() { # TITLE BODY [ICON] [URGENCY]
  have notify-send || return 0
  notify-send -a "CleanMate" -i "${3:-user-trash-full}" -u "${4:-normal}" "$1" "$2" 2>/dev/null
  return 0
}

schedule_get() { # → off | daily | weekly | monthly
  local t=$SYSTEMD_USER_DIR/cleanmate.timer
  if [[ -f $t ]] && systemctl --user is-enabled -q cleanmate.timer 2>/dev/null; then
    sed -n 's/^OnCalendar=//p' "$t"
  else echo off; fi
}

schedule_set() { # off | daily | weekly | monthly
  local exe=$SELF
  have systemctl || { toast "${RED}✘${NC} systemd is not available."; return 1; }
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would set automatic cleaning to: $1"; return 0; fi
  if [[ $1 == off ]]; then
    systemctl --user disable --now cleanmate.timer >/dev/null 2>&1
    rm -f "$SYSTEMD_USER_DIR/cleanmate.timer" "$SYSTEMD_USER_DIR/cleanmate.service"
    systemctl --user daemon-reload 2>/dev/null
    toast "${GREEN}✔${NC} Automatic cleaning turned off."
    return 0
  fi
  [[ -x $BIN_PATH ]] && exe=$BIN_PATH
  mkdir -p "$SYSTEMD_USER_DIR" || return 1
  cat >"$SYSTEMD_USER_DIR/cleanmate.service" <<EOF
[Unit]
Description=CleanMate — automatic Smart Clean

[Service]
Type=oneshot
ExecStart="$exe" --auto
Nice=19
IOSchedulingClass=idle
EOF
  cat >"$SYSTEMD_USER_DIR/cleanmate.timer" <<EOF
[Unit]
Description=Run CleanMate automatically

[Timer]
OnCalendar=$1
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload &&
    systemctl --user enable --now cleanmate.timer >/dev/null 2>&1 ||
    { toast "${RED}✘${NC} Could not enable the systemd timer."; return 1; }
  if [[ $exe == "$BIN_PATH" ]]; then toast "${GREEN}✔${NC} Automatic cleaning: $1."
  else toast "${GREEN}✔${NC} Automatic cleaning: $1 — runs ${exe/#$HOME/\~}; install the launcher so moving it won't break this."; fi
}

# The desktop app (gui/) and the icon (data/) ship in the repository. A clone has
# them next to the script; a script downloaded on its own fetches them from GitHub.
BUNDLE_URL=${CLEANMATE_BUNDLE_URL:-https://github.com/$UPDATE_REPO/archive/refs/heads/$UPDATE_BRANCH.tar.gz}

bundle_fetch() { # → BUNDLE_ROOT: the app files from GitHub (fails quietly when offline)
  local dir top
  have tar || return 1
  dir=$(mktemp -d -p "$SESSION_TMP") || return 1
  fetch "$BUNDLE_URL" "$dir/app.tar.gz" || return 1
  tar -xzf "$dir/app.tar.gz" -C "$dir" --wildcards '*/gui/*' '*/data/*' 2>/dev/null || return 1
  for top in "$dir"/*/; do
    [[ -f $top/gui/cleanmate-gui && -d $top/gui/cleanmate_gui ]] && { BUNDLE_ROOT=${top%/}; return 0; }
  done
  return 1
}

app_files_root() { # → a folder with gui/ and data/: next to this script, or freshly downloaded
  local here
  here=$(dirname "$SELF")
  if [[ -f $here/gui/cleanmate-gui || -d $here/data/icons ]]; then printf '%s\n' "$here"; return 0; fi
  bundle_fetch && printf '%s\n' "$BUNDLE_ROOT"
}

install_app_files() { # ROOT — copy the desktop app and the icon into place
  local root=$1 svg="$1/data/icons/hicolor/scalable/apps/$APP_ID.svg"
  if [[ -f $root/gui/cleanmate-gui && $root/gui != "$GUI_HOME" ]]; then
    mkdir -p "$GUI_HOME" && cp -r -- "$root/gui/cleanmate-gui" "$root/gui/cleanmate_gui" "$GUI_HOME/" &&
      find "$GUI_HOME" -name __pycache__ -prune -exec rm -rf {} +
  fi
  if [[ -f $svg ]]; then
    mkdir -p "${ICON_FILE%/*}" && cp -- "$svg" "$ICON_FILE"
    touch "${ICON_FILE%/scalable/*}" 2>/dev/null # tell the shell the icon theme changed
  fi
  return 0
}

do_install() { # copy to ~/.local/bin, add the `cm` shorthand and an app-grid entry → INSTALL_LOG
  INSTALL_LOG=() INSTALL_CMD=cleanmate
  local bindir=${BIN_PATH%/*}
  bindir=${bindir/#$HOME/\~}
  if [[ ! -f $SELF || $SELF == /dev/* || $SELF == /proc/* ]]; then
    INSTALL_LOG+=("${RED}✘${NC} Download the script to a file first, then run it with --install.")
    return 1
  fi
  if ((DRY_RUN)); then
    INSTALL_LOG+=("${MAGENTA}[dry-run]${NC} Would install ${BIN_PATH/#$HOME/\~}, ${ALIAS_PATH/#$HOME/\~} and an app-grid entry")
    return 0
  fi
  mkdir -p "${BIN_PATH%/*}" "${APP_FILE%/*}" || return 1
  if [[ $SELF != "$BIN_PATH" ]]; then
    install -m 755 -- "$SELF" "$BIN_PATH" || { INSTALL_LOG+=("${RED}✘${NC} Could not copy to ${BIN_PATH/#$HOME/\~}"); return 1; }
  fi
  INSTALL_LOG+=("${GREEN}✔${NC} Installed ${BOLD}cleanmate${NC} $VERSION to $bindir")
  # `cm` — but never shadow a different program or replace a real file
  local other
  other=$(command -v cm 2>/dev/null)
  if [[ -L $ALIAS_PATH || ! -e $ALIAS_PATH ]] && [[ -z $other || $other == "$ALIAS_PATH" ]]; then
    ln -sfn cleanmate "$ALIAS_PATH" && INSTALL_LOG+=("${GREEN}✔${NC} Shorthand: ${BOLD}cm${NC}") INSTALL_CMD=cm
  else
    INSTALL_LOG+=("${YELLOW}!${NC} Skipped the ${BOLD}cm${NC} shorthand: ${other:-$ALIAS_PATH} already exists")
  fi
  # the desktop app and the icon: from this copy's folder (a clone), or downloaded from GitHub
  local root gui=0 icon=user-trash-full
  if root=$(app_files_root); then
    install_app_files "$root"
    [[ $root == "$SESSION_TMP"/* ]] && INSTALL_LOG+=("${GREEN}✔${NC} Downloaded the desktop app and icon from GitHub")
    [[ -f $GUI_HOME/cleanmate-gui ]] && INSTALL_LOG+=("${GREEN}✔${NC} Installed the desktop app (${BOLD}cm --gui${NC})")
  else
    INSTALL_LOG+=("${YELLOW}!${NC} Couldn't get the desktop app (offline?) — the terminal app is installed.")
  fi
  [[ -f $ICON_FILE ]] && icon=$APP_ID
  [[ -f $GUI_HOME/cleanmate-gui ]] && gui_supported && gui=1
  if ((gui)); then # app grid opens the desktop app; right-click offers the terminal app
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=CleanMate" \
      "Comment=Free up disk space and keep Ubuntu tidy" "Exec=$BIN_PATH --gui" "Icon=$icon" \
      "Terminal=false" "Categories=GTK;System;" "Keywords=clean;disk;space;junk;cache;duplicates;cm;" \
      "StartupNotify=true" "StartupWMClass=$APP_ID" "Actions=terminal;" "" \
      "[Desktop Action terminal]" "Name=Open in Terminal" "Exec=x-terminal-emulator -e $BIN_PATH" >"$APP_FILE"
  else
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=CleanMate" \
      "Comment=Free up disk space and keep Ubuntu tidy" "Exec=$BIN_PATH" "Icon=$icon" \
      "Terminal=true" "Categories=System;" "Keywords=clean;disk;space;junk;cache;duplicates;cm;" >"$APP_FILE"
  fi
  have update-desktop-database && update-desktop-database "${APP_FILE%/*}" >/dev/null 2>&1
  INSTALL_LOG+=("${GREEN}✔${NC} Added “CleanMate” to your app grid$( ((gui)) && echo " (desktop app)")")
  local sched; sched=$(schedule_get)
  [[ $sched != off ]] && schedule_set "$sched" # point the timer at the installed copy
  case ":$PATH:" in
    *":${BIN_PATH%/*}:"* | *":${BIN_PATH%/*}/:"*) ;; # with or without a trailing slash
    *) INSTALL_LOG+=("${YELLOW}!${NC} $bindir is not in your PATH yet — log out and back in, or run:"
         "    export PATH=\"\$HOME/.local/bin:\$PATH\"") ;;
  esac
  return 0
}

install_launcher() { # Settings → Install app launcher
  if packaged; then toast "${GREEN}✔${NC} Already installed by your package manager."; return; fi
  ui_confirm "Install CleanMate?" "Adds the cleanmate and cm commands and an app-grid entry." y || return
  if do_install; then toast "${GREEN}✔${NC} Installed — type ${BOLD}$INSTALL_CMD${NC} in any terminal, or find it in your apps"
  else toast "${INSTALL_LOG[-1]}"; fi
}

cli_install() { # --install
  local l rc
  if packaged; then
    ok "CleanMate is already installed as a package — find it in Show Apps, or run: cm"
    return 0
  fi
  do_install; rc=$?
  for l in "${INSTALL_LOG[@]}"; do printf '  %s\n' "$l"; done
  ((rc == 0 && !DRY_RUN)) && printf '\n  Start it any time with: %s%s%s\n\n' "$BOLD" "$INSTALL_CMD" "$NC"
  return "$rc"
}

cli_uninstall() { # --uninstall: remove commands, launcher, timer; optionally settings and logs
  local f
  if packaged; then
    info "CleanMate was installed as a package — remove it with:"
    if [[ -n ${SNAP:-} ]]; then printf '    sudo snap remove cleanmate\n'; else printf '    sudo apt remove cleanmate\n'; fi
    return 0
  fi
  printf '  This removes cleanmate, cm, the app-grid entry and automatic cleaning.\n'
  confirm "Uninstall CleanMate?" || return 1
  if have systemctl && ((!DRY_RUN)); then
    systemctl --user disable --now cleanmate.timer >/dev/null 2>&1
  fi
  for f in "$BIN_PATH" "$ALIAS_PATH" "$APP_FILE" "$ICON_FILE" \
    "$SYSTEMD_USER_DIR/cleanmate.timer" "$SYSTEMD_USER_DIR/cleanmate.service"; do
    [[ -e $f || -L $f ]] || continue
    [[ $f == "$ALIAS_PATH" && $(readlink "$f") != cleanmate ]] && continue # not ours
    run rm -f -- "$f" && ok "Removed ${f/#$HOME/\~}"
  done
  if [[ -d $GUI_HOME && $GUI_HOME == */cleanmate/gui ]]; then
    run rm -rf -- "$GUI_HOME" && ok "Removed the desktop app"
  fi
  ((DRY_RUN)) || { have systemctl && systemctl --user daemon-reload 2>/dev/null; }
  if confirm "Also delete your settings, remembered selections and logs?"; then
    run rm -rf -- "${PREF_FILE%/*}" "$LOG_DIR" "$CACHE_DIR" && ok "Removed settings and logs"
  fi
  printf '\n  Goodbye 👋  (this copy of the script itself was left in place)\n'
}

edit_number() { # KEY PROMPT — a number within the key's range (SETTING_RANGE)
  local -a r
  read -ra r <<<"${SETTING_RANGE[$1]}"
  ui_input "$2" "${CFG[$1]:-}" || return
  if setting_valid "$1" "$REPLY_TEXT"; then
    save_setting "$1" "$((10#$REPLY_TEXT))" || { toast "${RED}✘${NC} Could not save ${SETTINGS_FILE/#$HOME/\~}."; return; }
    apply_settings
    toast "${GREEN}✔${NC} Saved."
  else
    toast "${RED}✘${NC} Enter a number from ${r[0]} to ${r[1]}."
  fi
}

settings_menu() {
  local s
  while :; do
    ((DRY_RUN)) || load_settings # changes made in the desktop app meanwhile
    s=$(schedule_get)
    M_KEY=() M_LABEL=() M_DESC=()
    mh "General"
    mi 1 "Automatic cleaning" "${s^} $( [[ $s == off ]] && echo "— runs a Smart Clean of user & developer junk" || echo "— user & developer junk, you get a notification")"
    mi 2 "Low disk alert" "$( ((LOW_DISK_PCT)) && echo "Notify below ${LOW_DISK_PCT}% free (checked with automatic cleaning)" || echo "Off")"
    mi 3 "Recent files history" "$(recent_policy)"
    mi 4 "Install app launcher" "$(if packaged; then echo "Installed by your package manager"
      elif [[ -x $BIN_PATH && -f $APP_FILE ]]; then echo "Installed — run cleanmate or cm"
      else echo "Add cleanmate and cm commands and an app-grid entry"; fi)"
    mh "Updates"
    mi 5 "Check for updates now" "You have version $VERSION${UPDATE_LATEST:+ — $UPDATE_LATEST is available}"
    mi 6 "Daily update check" "$( ((UPDATE_CHECK)) && echo "On — a quiet check once a day" || echo "Off")"
    mh "Keep for"
    mi 7 "Journal logs" "Keep ${JOURNAL_KEEP_DAYS} days"
    mi 8 "Journal size limit" "Keep at most ${JOURNAL_KEEP_MB} MB"
    mi 9 "Oversized logs" "Empty live logs larger than ${LOG_MAX_MB} MB"
    mi 0 "App logs" "Clean when not written for ${APPLOG_DAYS} days"
    mi a "Temporary files" "Clean when older than ${TMP_DAYS} days"
    mi b "App caches" "Clean when older than ${CACHE_DAYS} days"
    mi c "Project build folders" "Clean when the project is idle for ${NM_DAYS} days"
    mi i "Old installers" "Offer installers in Downloads older than ${OLD_INSTALLER_DAYS} days"
    mi o "Old downloads" "Offer files and folders in Downloads, and screenshots, untouched for ${OLD_DOWNLOAD_DAYS} days"
    mi d "AI chat history" "Clean AI sessions older than ${AI_HISTORY_DAYS} days"
    mh "Your data"
    mi x "Never clean" "$( ((${#EXCLUDES[@]})) && plural ${#EXCLUDES[@]} folder || echo "No folders") that Large & Old Files, Duplicates, Space Lens, build folders, old installers and old downloads skip"
    mi e "Reset selections" "$(plural ${#PREF[@]} "remembered choice") for Smart Scan"
    mi f "Activity log" "What was cleaned and when"
    mh "About"
    mi g "Source code" "${REPO_URL#https://} — opens in your browser"
    mi h "Report a problem" "Questions, bugs and ideas are welcome"
    ui_menu "Settings" || return
    case ${M_LABEL[MENU_IDX]} in # dispatch by label: keys are only shortcuts
      "Automatic cleaning")
        M_KEY=(1 2 3 4) M_LABEL=("Off" "Daily" "Weekly" "Monthly")
        M_DESC=("Only clean when you run the app" "Every day" "Every week (recommended)" "Once a month")
        if ui_menu "Automatic cleaning"; then
          case $MENU_IDX in 0) schedule_set off ;; 1) schedule_set daily ;; 2) schedule_set weekly ;; 3) schedule_set monthly ;; esac
        fi ;;
      "Low disk alert") edit_number low_disk_pct "Warn below this % of free space (0 = off):" ;;
      "Recent files history") recent_menu ;;
      "Install app launcher") install_launcher ;;
      "Check for updates now") ui_update ;;
      "Daily update check")
        save_setting update_check $((1 - UPDATE_CHECK)) && apply_settings
        toast "${GREEN}✔${NC} Daily update check $( ((UPDATE_CHECK)) && echo on || echo off)." ;;
      "Journal logs") edit_number journal_days "Keep journal logs for how many days?" ;;
      "Journal size limit") edit_number journal_mb "Maximum journal size in MB:" ;;
      "Oversized logs") edit_number log_max_mb "Empty live logs larger than how many MB?" ;;
      "App logs") edit_number app_log_days "Clean app logs not written for how many days?" ;;
      "Temporary files") edit_number tmp_days "Clean temporary files older than how many days?" ;;
      "App caches") edit_number cache_days "Clean app caches older than how many days?" ;;
      "Project build folders") edit_number node_modules_days "Clean build folders of projects idle for how many days?" ;;
      "Old installers") edit_number installer_days "Offer installers in Downloads older than how many days?" ;;
      "Old downloads") edit_number download_days "Offer files and folders in Downloads, and screenshots, untouched for how many days?" ;;
      "AI chat history") edit_number ai_history_days "Clean AI chat sessions older than how many days?" ;;
      "Never clean") exclusions_menu ;;
      "Reset selections")
        ui_confirm "Forget remembered selections?" "Smart Scan goes back to its default choices." n || continue
        PREF=()
        ((DRY_RUN)) || rm -f "$PREF_FILE"
        toast "${GREEN}✔${NC} Selections reset to defaults." ;;
      "Activity log")
        if [[ -s $LOG_FILE ]]; then mapfile -t V_LINES < <(tac "$LOG_FILE" | head -n 1000 | sed 's/^/  /')
        else V_LINES=("  ${DIM}Nothing has been cleaned yet.${NC}"); fi
        ui_view "Activity log" ;;
      "Source code") open_url "$REPO_URL" ;;
      "Report a problem") open_url "$REPO_URL/issues" ;;
    esac
  done
}

exclusions_menu() { # Settings › Never clean: add a folder by its path, Enter on one removes it
  local i p first
  while :; do
    ((DRY_RUN)) || load_exclusions # changes made in the desktop app meanwhile
    M_KEY=(a) M_LABEL=("Add a folder…") M_DESC=("A folder inside your home that CleanMate never offers to clean")
    mh "Folders"
    first=${#M_KEY[@]}
    ((${#EXCLUDES[@]})) || mi "" "None yet" ""
    for i in "${!EXCLUDES[@]}"; do mi "" "${EXCLUDES[i]##*/}" "${EXCLUDES[i]/#$HOME/\~} — Enter removes it from the list"; done
    ui_menu "Never clean" || return
    if ((MENU_IDX == 0)); then
      ui_input "Folder to never clean:" "$HOME/" || continue
      p=${REPLY_TEXT/#\~/$HOME}
      if exclusion_add "$p"; then toast "${GREEN}✔${NC} ${EX_PATH/#$HOME/\~}: $EX_WHY."
      else toast "${RED}✘${NC} $EX_WHY."; fi
    elif ((MENU_IDX >= first && ${#EXCLUDES[@]})); then
      p=${EXCLUDES[MENU_IDX - first]}
      ui_confirm "Remove ${p/#$HOME/\~} from the list?" "CleanMate may offer what is in it again." n || continue
      if exclusion_remove "$p"; then toast "${GREEN}✔${NC} ${p/#$HOME/\~}: $EX_WHY."
      else toast "${RED}✘${NC} $EX_WHY."; fi
    fi
  done
}

open_url() { # URL — open in the browser; always show it too (SSH, no desktop)
  if have xdg-open && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
    xdg-open "$1" >/dev/null 2>&1 &
    disown 2>/dev/null
    toast "${ACCENT}↗${NC} Opened $1"
  else
    toast "${ACCENT}↗${NC} $1"
  fi
}

recent_policy() { # describe GNOME's recent-files setting
  have gsettings || { echo "Not available"; return; }
  local on age
  on=$(gsettings get org.gnome.desktop.privacy remember-recent-files 2>/dev/null)
  age=$(gsettings get org.gnome.desktop.privacy recent-files-max-age 2>/dev/null)
  if [[ $on == false ]]; then echo "Not remembered"
  elif [[ $age == -1 || -z $age ]]; then echo "Remembered forever (GNOME default)"
  else echo "Remembered for $(plural "$age" day)"; fi
}

recent_menu() {
  have gsettings || { toast "${RED}✘${NC} gsettings is not available."; return; }
  M_KEY=(1 2 3 4 5) M_LABEL=("Forever" "30 days" "7 days" "1 day" "Don't remember")
  M_DESC=("GNOME default" "Older entries drop off automatically" "" "" "Files and Open dialogs show no Recent list")
  ui_menu "Recent files history" || return
  if ((DRY_RUN)); then toast "${MAGENTA}[dry-run]${NC} Would set recent files to: ${M_LABEL[MENU_IDX]}"; return; fi
  local age=(-1 30 7 1 -1)
  gsettings set org.gnome.desktop.privacy remember-recent-files "$( ((MENU_IDX == 4)) && echo false || echo true)" &&
    gsettings set org.gnome.desktop.privacy recent-files-max-age "${age[MENU_IDX]}" &&
    toast "${GREEN}✔${NC} Recent files: ${M_LABEL[MENU_IDX]}"
}

# ───────────────────────────── updates ──────────────────────────────────────
#
# The latest version is the VERSION line of the script on the default branch.
# A download is only used if it is really this script and passes `bash -n`;
# it replaces the installed copy atomically (write next to it, then rename),
# so a copy that is currently running is never corrupted.

UPDATE_URL=${CLEANMATE_UPDATE_URL:-https://raw.githubusercontent.com/$UPDATE_REPO/$UPDATE_BRANCH/cleanmate.sh}
UPDATE_STATE="$LOG_DIR/update-check" # "<epoch>\t<latest version>"
UPDATE_LATEST=""

update_configured() { [[ -n ${CLEANMATE_UPDATE_URL:-} || $UPDATE_REPO == */* ]]; } # CLEANMATE_UPDATE_URL: mirrors, forks, tests

fetch() { # URL OUT → 0 ok, 22 not found / server error, 127 no downloader, other = network
  local rc
  if have curl; then curl -fsSL --max-time 20 -o "$2" -- "$1" 2>/dev/null; rc=$?
  elif have wget; then wget -q -T 20 -O "$2" -- "$1" 2>/dev/null; rc=$?; ((rc == 8)) && rc=22
  else return 127; fi
  return "$rc"
}

script_version() { sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

version_gt() { # A B → A is newer than B
  [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

load_update_state() { # → UPDATE_LATEST (from the last check)
  local t v
  UPDATE_LATEST=""
  [[ -n ${UPDATE_DONE:-} ]] && return 0 # already updated; this running copy is just old
  [[ -f $UPDATE_STATE ]] && IFS=$'\t' read -r t v <"$UPDATE_STATE" &&
    [[ $v =~ ^[0-9][0-9.]*$ ]] && version_gt "$v" "$VERSION" && UPDATE_LATEST=$v
  return 0
}

update_check_bg() { # at most once a day, in the background — never delays the app
  local t=0 v
  packaged && return 0 # apt / Software Updater handle updates
  ((UPDATE_CHECK)) && [[ -z ${CLEANMATE_NO_UPDATE_CHECK:-${CMU_NO_UPDATE_CHECK:-}} ]] && update_configured || return 0
  [[ -f $UPDATE_STATE ]] && IFS=$'\t' read -r t v <"$UPDATE_STATE"
  ((EPOCHSECONDS - ${t:-0} < 86400)) && return 0
  (
    tmp=$(mktemp) || exit
    trap 'rm -f "$tmp"' EXIT
    fetch "$UPDATE_URL" "$tmp" && v=$(script_version "$tmp") && [[ -n $v ]] &&
      mkdir -p "$LOG_DIR" && printf '%s\t%s\n' "$EPOCHSECONDS" "$v" >"$UPDATE_STATE"
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
  return 0
}

update_download() { # → UPDATE_FILE, UPDATE_NEW; 0 newer available, 1 error (UPDATE_MSG), 2 up to date
  local rc
  UPDATE_FILE=$(mktemp -p "$SESSION_TMP") UPDATE_NEW="" UPDATE_MSG=""
  if ! update_configured; then
    UPDATE_MSG="Update source not set yet (UPDATE_REPO in the script)."
    return 1
  fi
  if ((UI_ACTIVE)); then
    (fetch "$UPDATE_URL" "$UPDATE_FILE"; echo $? >"$UPDATE_FILE.rc") &
    UI_BUSY_TITLE="Updates"
    ui_busy "Checking for updates…" $! || { UPDATE_MSG="Cancelled."; return 1; }
    rc=$(<"$UPDATE_FILE.rc")
  else
    fetch "$UPDATE_URL" "$UPDATE_FILE"; rc=$?
  fi
  if ((rc == 127)); then UPDATE_MSG="Install curl or wget to check for updates."; return 1; fi
  if ((rc == 22)); then UPDATE_MSG="No published version found at github.com/$UPDATE_REPO yet."; return 1; fi
  if ((rc != 0)) || [[ ! -s $UPDATE_FILE ]]; then UPDATE_MSG="Could not reach GitHub — are you online?"; return 1; fi
  UPDATE_NEW=$(script_version "$UPDATE_FILE")
  if [[ -z $UPDATE_NEW ]] || ! grep -q 'cleanmate' "$UPDATE_FILE" || ! bash -n "$UPDATE_FILE" 2>/dev/null; then
    UPDATE_MSG="The download doesn't look like CleanMate — not installing it."
    return 1
  fi
  mkdir -p "$LOG_DIR" && printf '%s\t%s\n' "$EPOCHSECONDS" "$UPDATE_NEW" >"$UPDATE_STATE"
  if version_gt "$UPDATE_NEW" "$VERSION"; then return 0; fi
  UPDATE_MSG="You're up to date (version $VERSION)."
  UPDATE_LATEST=""
  return 2
}

update_apply() { # install UPDATE_FILE over the installed copy (or this file) → UPDATE_MSG
  local target=$SELF
  [[ -x $BIN_PATH ]] && target=$BIN_PATH
  if [[ ! -f $target || ! -w ${target%/*} ]]; then UPDATE_MSG="Can't write ${target/#$HOME/\~}."; return 1; fi
  if ((DRY_RUN)); then UPDATE_MSG="[dry-run] Would update ${target/#$HOME/\~} to $UPDATE_NEW"; return 0; fi
  cp -- "$UPDATE_FILE" "$target.new.$$" && chmod 755 "$target.new.$$" && mv -f -- "$target.new.$$" "$target" || {
    rm -f -- "$target.new.$$"; UPDATE_MSG="Update failed while writing ${target/#$HOME/\~}."; return 1
  }
  log "Updated from $VERSION to $UPDATE_NEW ($target)"
  UPDATE_LATEST="" UPDATE_DONE=$UPDATE_NEW
  if [[ -d $GUI_HOME || -f $ICON_FILE ]] && bundle_fetch; then # keep the desktop app in step
    install_app_files "$BUNDLE_ROOT"
  fi
  UPDATE_MSG="Updated to $UPDATE_NEW — restart cm to use it."
}

ui_update() { # check, confirm, install — from the menu or Settings
  update_download
  case $? in
    1) toast "${RED}✘${NC} $UPDATE_MSG"; return ;;
    2) toast "${GREEN}✔${NC} $UPDATE_MSG"; return ;;
  esac
  ui_confirm "Update to version $UPDATE_NEW?" "You have $VERSION. Release notes: github.com/$UPDATE_REPO/releases" y || return
  if update_apply; then toast "${GREEN}✔${NC} $UPDATE_MSG"; else toast "${RED}✘${NC} $UPDATE_MSG"; fi
}

cli_update() { # --update
  if packaged; then
    info "CleanMate was installed as a package — update it with Software Updater or:"
    pkg_update_hint
    return 0
  fi
  printf '  CleanMate %s — checking for updates…\n' "$VERSION"
  update_download
  case $? in
    1) err "$UPDATE_MSG"; return 1 ;;
    2) ok "$UPDATE_MSG"; return 0 ;;
  esac
  printf '  %s⬆ Version %s is available%s (you have %s)\n' "$BOLD" "$UPDATE_NEW" "$NC" "$VERSION"
  printf '  %sRelease notes: https://github.com/%s/releases%s\n' "$DIM" "$UPDATE_REPO" "$NC"
  confirm "Update now?" || return 0
  if update_apply; then ok "$UPDATE_MSG"; else err "$UPDATE_MSG"; return 1; fi
}

auto_mode() { # --auto: unattended Smart Clean of user & developer junk, run by the timer
  local avail size pct
  INTERACTIVE=0 ASSUME_YES=1
  local id b left=() body title
  printf 'CleanMate — automatic Smart Clean (%s)\n\n' "$(date '+%F %T')"
  scan_items "${CATEGORIES[@]}" # everything is scanned (read-only) …
  for id in "${SCANNED[@]}"; do # … but only user & developer junk is cleaned
    [[ ${ITEM_CAT[$id]} == user || ${ITEM_CAT[$id]} == dev ]] || SEL[$id]=0
  done
  SEL[trash]=0 SEL[trash_drives]=0 # never empty a Trash behind the user's back
  SEL[stale_build_dirs]=0 SEL[android_images]=0 SEL[android_avd_snapshots]=0 SEL[old_runtimes]=0 SEL[jetbrains_old_versions]=0 SEL[vscode_old_extensions]=0 # the user picks which projects to rebuild, images, runtimes or extension versions to download again and IDE versions to let go
  plain_results
  printf '\n'
  start_cleanup
  # the biggest things left for the user to decide about
  while IFS=$'\t' read -r b id; do
    left+=("${ITEM_LABEL[$id]} $(human "$b")")
  done < <(for id in "${SCANNED[@]}"; do
    ((RES_RC[$id] == 0 && !SEL[$id] && RES_BYTES[$id] >= 104857600)) && printf '%s\t%s\n' "${RES_BYTES[$id]}" "$id"
  done | sort -rn | head -n 3)
  if ((RUN_FREED > 0 || ${#left[@]})); then
    if ((RUN_FREED > 0)); then title="Freed $(human "$RUN_FREED")"; body="Caches and junk were cleaned automatically."
    else title="CleanMate"; body=""; fi
    if ((${#left[@]})); then
      body+="${body:+ }Worth a look: $(printf '%s, ' "${left[@]}")"
      body="${body%, } — run cm to review."
    fi
    printf '\n  %s: %s\n' "$title" "$body"
    notify "$title" "$body"
  fi
  read -r size avail < <(df -B1 --output=size,avail / | tail -n1)
  pct=$((avail * 100 / size))
  if ((LOW_DISK_PCT > 0 && pct < LOW_DISK_PCT)); then
    notify "Disk almost full" "Only $(human "$avail") ($pct%) free on /. Open CleanMate to free up space." drive-harddisk critical
  fi
}

# ───────────────────────────── JSON protocol (for the GUI) ──────────────────
#
# `cm --json items|scan|details|clean|large|lens|dupes|trash|restore|startup|startup-set|settings|settings-set|apps|uninstall|maintenance|maintain|overview …` prints one JSON object per line on
# stdout and nothing else. See docs/ROADMAP.md for the event list.

JSON=0
JSON_ARGS=()

json_str() { # VAR TEXT → a JSON string literal (colours and control characters removed)
  local s=$2
  s=${s//$'\e'\[*([0-9;])m/}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//[$'\x01'-$'\x1f']/}
  printf -v "$1" '"%s"' "$s"
}

json_item() { # ID [with scan results] → one "item" event (no subshells: called for every item)
  local id=$1 cat label desc note lock status=found def=false root=false trash=false sel=false ent=false
  json_str cat "${ITEM_CAT[$id]}"; json_str label "${ITEM_LABEL[$id]}"; json_str desc "${ITEM_DESC[$id]}"
  ((ITEM_DEFAULT[$id])) && def=true
  [[ -n ${ITEM_ROOT[$id]:-} ]] && root=true
  [[ -n ${ITEM_TRASH[$id]:-} ]] && trash=true
  if [[ ${2:-} == scanned ]]; then
    json_str note "${RES_NOTE[$id]}"; json_str lock "${RES_LOCK[$id]:-}"
    case ${RES_RC[$id]} in 0) status=found ;; 3) status=timeout ;; *) status=clean ;; esac
    ((${SEL[$id]:-0})) && sel=true
    has_entries "$id" && ent=true
    printf '{"event":"item","id":"%s","category":%s,"label":%s,"description":%s,"default":%s,"root":%s,"status":"%s","bytes":%d,"note":%s,"selected":%s,"locked":%s,"entries":%s,"trash":%s}\n' \
      "$id" "$cat" "$label" "$desc" "$def" "$root" "$status" "${RES_BYTES[$id]:-0}" "$note" "$sel" "$lock" "$ent" "$trash"
  else
    printf '{"event":"item","id":"%s","category":%s,"label":%s,"description":%s,"default":%s,"root":%s,"trash":%s}\n' \
      "$id" "$cat" "$label" "$desc" "$def" "$root" "$trash"
  fi
}

json_error() { local m; json_str m "$1"; printf '{"event":"error","message":%s}\n' "$m"; }

has_entries() { declare -F "entries_$1" >/dev/null; }

json_entries() { # ID → one "entry" event per part of the item that can be cleaned on its own
  local eid b sel label note
  has_entries "$1" || return 0
  while IFS=$'\t' read -r eid b sel label note; do
    json_str label "$label"
    json_str note "$note"
    printf '{"event":"entry","item":"%s","id":"%s","bytes":%d,"label":%s,"note":%s,"selected":%s}\n' \
      "$1" "$eid" "$b" "$label" "$note" "$( ((sel)) && echo true || echo false)"
  done < <("entries_$1" 2>/dev/null)
}

json_pick_entries() { # ID LIST → ENTRY_PICK: the comma-separated IDs, each checked by format
  local re_var="ENTRY_RE_$1" e
  ENTRY_PICK=()
  declare -F "clean_entries_$1" >/dev/null || { json_error "$1 can't be cleaned entry by entry"; return 2; }
  IFS=, read -ra ENTRY_PICK <<<"$2"
  ((${#ENTRY_PICK[@]})) || { json_error "No entries given."; return 2; }
  for e in "${ENTRY_PICK[@]}"; do
    [[ $e =~ ${!re_var} ]] || { json_error "Not an entry ID of $1: $e"; return 2; }
  done
}

json_task() { # ID STATE INFO FREED
  local info; json_str info "${3:-}"
  printf '{"event":"task","id":"%s","state":"%s","info":%s,"freed":%d}\n' "$1" "$2" "$info" "${4:-0}"
}

json_main() { # SUBCOMMAND ARGS…
  local cmd=${1:-} id
  shift || true
  case $cmd in
    items)
      for id in "${ITEM_IDS[@]}"; do json_item "$id"; done
      printf '{"event":"done"}\n' ;;
    scan)
      scan_items "${CATEGORIES[@]}"
      for id in "${SCANNED[@]}"; do json_item "$id" scanned; done
      found_total
      printf '{"event":"done","ms":%d,"total_bytes":%d,"locations":%d}\n' "$SCAN_MS" "$FOUND_TOTAL" "$SCAN_COUNT" ;;
    details)
      id=${1:-}
      [[ -n ${ITEM_CAT[$id]:-} ]] || { json_error "Unknown item: $id"; return 2; }
      local lines=() l out="" first=1
      if declare -F "details_$id" >/dev/null; then mapfile -t lines < <("details_$id" 2>/dev/null); fi
      json_entries "$id"
      for l in "${lines[@]}"; do
        json_str l "$l"
        ((first)) || out+=","
        out+=$l first=0
      done
      printf '{"event":"details","id":"%s","lines":[%s]}\n{"event":"done"}\n' "$id" "$out" ;;
    clean) json_clean "$@" ;;
    large) json_large "$@" ;;
    lens) json_lens "$@" ;;
    dupes) json_dupes "$@" ;;
    trash) json_trash "$@" ;;
    restore) json_restore "$@" ;;
    startup) json_startup "$@" ;;
    startup-set) json_startup_set "$@" ;;
    settings) json_settings ;;
    settings-set) json_settings_set "$@" ;;
    activity) json_activity "$@" ;;
    apps) json_apps ;;
    uninstall) json_uninstall "$@" ;;
    reset) json_reset "$@" ;;
    maintenance) json_maintenance ;;
    maintain) json_maintain "$@" ;;
    overview) json_overview ;;
    *) json_error "Usage: --json items|scan|details ID|clean ID…|large|lens|dupes|trash PATH…|restore KEY…|startup|startup-set ID enable|disable|remove|settings|settings-set KEY VALUE|activity [--limit N]|apps|uninstall [--check] ID…|reset [--check] ID [FOLDER…]|maintenance|maintain ID [on|off] [--user-steps]|overview"; return 2 ;;
  esac
}

# As root (through pkexec) only system items may be cleaned — your home folder
# is never cleaned as root.
json_allowed() { # ID UID
  (($2 != 0)) || [[ -n ${ITEM_ROOT[$1]:-} ]]
}

json_clean() { # ID… | ID --entries E1,E2… — clean exactly these items (or these entries of one), streaming "task" events
  local id ids=() out rc before freed total=0 avail0 avail1 src bytes note info entries="" e key keys trashed=""
  local -a ENTRY_PICK=()
  while (($#)); do
    case $1 in
      --entries) entries=${2:-}; [[ -n $entries ]] || { json_error "--entries needs a list of IDs"; return 2; }; shift 2; continue ;;
    esac
    id=$1
    shift
    [[ -n ${ITEM_CAT[$id]:-} ]] || { json_error "Unknown item: $id"; return 2; }
    json_allowed "$id" "$EUID" || { json_error "Refusing to clean $id as root (only system items are allowed)"; return 2; }
    ids+=("$id")
  done
  ((${#ids[@]})) || { json_error "No items given."; return 2; }
  if [[ -n $entries ]]; then
    ((${#ids[@]} == 1)) || { json_error "--entries works with one item at a time"; return 2; }
    json_pick_entries "${ids[0]}" "$entries" || return
  fi
  avail0=$(fs_avail)
  for id in "${ids[@]}"; do
    json_task "$id" run
    SCAN_BYTES=0 SCAN_NOTE=""
    "scan_$id" >/dev/null 2>&1; rc=$?
    before=$SCAN_BYTES
    if ((rc != 0)); then json_task "$id" ok "already clean" 0; continue; fi
    RES_BYTES[$id]=$before
    if declare -F "precheck_$id" >/dev/null && ! "precheck_$id" >/dev/null 2>&1; then
      json_task "$id" skip "Skipped: the app is running — close it and try again"; continue
    fi
    out=$(mktemp -p "$SESSION_TMP")
    if ((${#ENTRY_PICK[@]})); then
      json_clean_entries "$id" >"$out" 2>&1 </dev/null; rc=$?
      ((DRY_RUN)) && before=$ENTRY_BYTES # what these entries would free; a real run measures the item again
    else
      task_clean "$id" >"$out" 2>&1 </dev/null; rc=$?
    fi
    keys="" # what went to the Trash, also when the rest failed: `restore` puts these back
    while IFS=$'\t' read -r _ key _; do
      [[ -n $key ]] || continue
      json_str key "$key"; keys+=${keys:+,}$key
    done < <(grep '^@@undo' "$out")
    [[ -n $keys ]] && trashed+=${trashed:+,}"\"$id\":[$keys]"
    if ((rc != 0)); then
      info=$(grep -v '^@@' "$out" | grep -v '^\s*$' | tail -n 1)
      json_task "$id" fail "${info:-failed (exit $rc)}" 0
      log "json clean $id failed: $info"
      continue
    fi
    if [[ ${ITEM_CAT[$id]} == privacy ]]; then
      freed=0 info=$( ((DRY_RUN)) && echo "would be cleared" || echo "cleared")
    elif ((DRY_RUN)); then
      freed=$before info="$(human "$freed") would be freed"
    else
      IFS=$'\t' read -r _ src bytes note < <(grep '^@@scan' "$out" | tail -n 1)
      freed=$((before - ${bytes:-0})); ((freed < 0)) && freed=0
      info="$(human "$freed") freed"
    fi
    total=$((total + freed))
    json_task "$id" ok "$info" "$freed"
  done
  avail1=$(fs_avail)
  ((DRY_RUN)) || record_cleanup "$total"
  log "GUI cleanup finished — $(human "$total") freed (dry-run=$DRY_RUN)"
  printf '{"event":"done","freed":%d,"avail_before":%d,"avail_after":%d,"trash":{%s}}\n' "$total" "$avail0" "$avail1" "$trashed"
}

json_clean_entries() { # ID — clean ENTRY_PICK of ID (only entries entries_ID lists now) → ENTRY_BYTES, @@scan line
  local id=$1 eid b sel label pick=() src
  local -A listed=()
  ENTRY_BYTES=0
  while IFS=$'\t' read -r eid b sel label; do listed[$eid]=$b; done < <("entries_$id" 2>/dev/null)
  for eid in "${ENTRY_PICK[@]}"; do
    [[ -n ${listed[$eid]:-} ]] || { echo "Not found (any more): $eid"; continue; }
    pick+=("$eid") ENTRY_BYTES=$((ENTRY_BYTES + listed[$eid]))
  done
  ((${#pick[@]})) || { echo "None of the chosen entries is there any more"; return 1; }
  "clean_entries_$id" "${pick[@]}" || return
  if ((!DRY_RUN)); then
    SCAN_BYTES=0 SCAN_NOTE=""
    "scan_$id" >/dev/null 2>&1; src=$?
    printf '\n@@scan\t%s\t%s\t%s\n' "$src" "${SCAN_BYTES:-0}" "$SCAN_NOTE"
  fi
}

# ── Large & Old Files, Trash and undo for the desktop app ──

LARGE_LIMIT=500 # the biggest files listed by `--json large`

file_kind() { # VAR PATH → video|audio|image|archive|package|disk|document|other
  local -n __fk=$1
  local n=${2##*/} e=""
  [[ $n == ?*.* ]] && e=${n##*.}
  case ${e,,} in
    mp4 | mkv | avi | mov | wmv | flv | webm | m4v | mpg | mpeg | ts | 3gp) __fk=video ;;
    mp3 | flac | wav | ogg | oga | m4a | aac | opus | wma) __fk=audio ;;
    jpg | jpeg | png | gif | bmp | tif | tiff | heic | webp | raw | cr2 | nef | arw | dng | psd | xcf) __fk=image ;;
    zip | tar | gz | tgz | bz2 | xz | zst | 7z | rar) __fk=archive ;;
    deb | rpm | snap | flatpak | appimage) __fk=package ;;
    iso | img | vdi | vmdk | qcow2 | vhd | vhdx | dmg) __fk=disk ;;
    pdf | doc | docx | odt | xls | xlsx | ods | ppt | pptx | odp | epub | txt | csv) __fk=document ;;
    *) __fk=other ;;
  esac
}

urldecode_path() { # VAR TEXT — undoes urlencode_path (a Trash Path= value)
  local -n __ud=$1
  local s=$2 c pre out=""
  while [[ $s == *%[0-9A-Fa-f][0-9A-Fa-f]* ]]; do
    pre=${s%%%[0-9A-Fa-f][0-9A-Fa-f]*}
    out+=$pre s=${s:${#pre}}
    printf -v c "\\x${s:1:2}"
    out+=$c s=${s:3}
  done
  __ud=$out$s
}

json_large() { # [--min BYTES] [--days N] [--path DIR] — the biggest files first
  local min=$((100 * 1024 * 1024)) days=0 dir=$HOME tmp found b m a p kind jp listed=0 sum=0
  while (($#)); do
    case $1 in
      --min | --days | --path) (($# >= 2)) || { json_error "$1 needs a value."; return 2; } ;;&
      --min) min=$2 ;;
      --days) days=$2 ;;
      --path) dir=$2 ;;
      *) json_error "Unknown option for large: $1"; return 2 ;;
    esac
    shift 2
  done
  [[ $min =~ ^[0-9]+$ ]] || { json_error "Invalid size: $min"; return 2; }
  [[ $days =~ ^[0-9]+$ ]] || { json_error "Invalid number of days: $days"; return 2; }
  [[ -d $dir ]] || { json_error "Not a folder: $dir"; return 2; }
  dir=$(realpath -- "$dir")
  if in_exclusion "$dir"; then printf '{"event":"done","count":0,"found":0,"total_bytes":0}\n'; return 0; fi
  exclusion_prune
  local filt=(-type f)
  ((min > 0)) && filt+=(-size +$((min - 1))c)
  # old = neither changed nor opened for that long
  ((days > 0)) && filt+=(-mmin +$((days * 1440)) -amin +$((days * 1440)))
  tmp=$(mktemp -p "$SESSION_TMP") || return 1
  # skip caches (Smart Scan's job), Trash folders and git internals; stay on one file system
  find "$dir" -xdev "${XPRUNE[@]}" \( -type d \( -name .cache -o -name .git -o -name Trash -o -name .Trash -o -name '.Trash-*' \) \
    -not -path "$dir" -prune \) -o \( "${filt[@]}" -printf '%s\t%T@\t%A@\t%p\0' \) 2>/dev/null >"$tmp"
  found=$(tr -cd '\0' <"$tmp" | wc -c)
  # only names that are valid UTF-8 without control characters can round-trip through JSON
  while IFS=$'\t' read -r -d '' b m a p; do
    [[ $p == *[$'\x01'-$'\x1f\x7f']* ]] && continue
    file_kind kind "$p"
    json_str jp "$p"
    printf '{"event":"file","path":%s,"bytes":%d,"mtime":%d,"atime":%d,"kind":"%s"}\n' \
      "$jp" "$b" "${m%.*}" "${a%.*}" "$kind"
    listed=$((listed + 1)) sum=$((sum + b))
  done < <(LC_ALL=C.UTF-8 grep -zax '.*' "$tmp" | sort -z -t$'\t' -k1,1rn | head -z -n "$LARGE_LIMIT")
  rm -f "$tmp"
  printf '{"event":"done","count":%d,"found":%d,"total_bytes":%d}\n' "$listed" "$found" "$sum"
}

LENS_LIMIT=500 # the biggest entries listed by `--json lens`, like the terminal's Space Lens

# Space Lens moves what is in your home folder (not protected), or on a drive mounted for you (VOLUME_ROOTS)
# that is writable and not a network or FUSE file system — into that drive's own Trash, so Undo puts it back.
# Never a drive's top folder, its Trash, a Timeshift backup on it, another file system mounted inside it,
# something reached through a symlink to elsewhere, or a Never clean folder.
declare -A DRIVE_OK=() # drive_mount_ok answers, once per drive and run
lens_movable() { # PATH (normalised)
  touches_exclusion "$1" && return 1
  if [[ $1 == "$HOME"/* ]]; then ! is_protected "$1"; return; fi
  lens_drive_movable "$1"
}
lens_drive_movable() { # PATH (normalised) — inside a writable drive of yours, movable into its Trash
  local top parent
  volume_top top "$1" || return 1 # below a drive's top, same file system, not in a Trash
  case ${1#"$top"/} in timeshift | timeshift/* | timeshift-btrfs | timeshift-btrfs/*) return 1 ;; esac
  parent=$(realpath -e -- "${1%/*}" 2>/dev/null) && [[ $parent == "$top" || $parent == "$top"/* ]] || return 1
  if [[ -z ${DRIVE_OK[$top]:-} ]]; then
    if drive_mount_ok "$top"; then DRIVE_OK[$top]=1; else DRIVE_OK[$top]=0; fi
  fi
  ((DRIVE_OK[$top]))
}
lens_drive() { # VAR PATH (normalised) → VAR = the top folder of the drive PATH is on (or is), or ""
  local -n __dr=$1
  local __r __rest
  __dr=""
  for __r in "${VOLUME_ROOTS[@]}"; do
    [[ -n $__r && $2 == "$__r"/* ]] || continue
    __rest=${2#"$__r"/}
    volume_top_ok "$__r/${__rest%%/*}" && __dr=$__r/${__rest%%/*}
    return 0
  done
}

json_lens() { # [--path DIR] — DIR's files and folders with their size (du -x), biggest first
  local dir=$HOME tmp b p n kind jp movable excluded listed=0 found=0 total=0 items=0 drive drive_trash=false
  local -A count=()
  while (($#)); do
    case $1 in
      --path) (($# >= 2)) || { json_error "$1 needs a value."; return 2; }; dir=$2 ;;
      *) json_error "Unknown option for lens: $1"; return 2 ;;
    esac
    shift 2
  done
  [[ -d $dir ]] || { json_error "Not a folder: $dir"; return 2; }
  # tidy the path but keep symlinks (a linked home folder stays under $HOME); -D measures the target
  dir=$(realpath -m -s -- "$dir")
  tmp=$(mktemp -p "$SESSION_TMP") || return 1
  while IFS=$'\t' read -r -d '' n p; do count[$p]=$n; done < <(du -0 -x -a -D --inodes --max-depth=1 -- "$dir" 2>/dev/null)
  du -0 -x -a -D -b --max-depth=1 -- "$dir" 2>/dev/null >"$tmp"
  found=$(($(tr -cd '\0' <"$tmp" | wc -c) - 1)) # every entry; du's last line is the folder itself
  ((found >= 0)) || found=0
  # only names that are valid UTF-8 without control characters can round-trip through JSON
  while IFS=$'\t' read -r -d '' b p; do
    if [[ $p == "$dir" ]]; then total=$b items=$((${count[$p]:-1} - 1)); continue; fi
    ((listed < LENS_LIMIT)) || continue
    [[ $p == *[$'\x01'-$'\x1f\x7f']* ]] && continue
    if [[ -d $p && ! -L $p ]]; then kind=dir n=$((${count[$p]:-1} - 1)); else kind=file n=1; fi
    if lens_movable "$p"; then movable=true; else movable=false; fi
    if touches_exclusion "$p"; then excluded=true; else excluded=false; fi
    json_str jp "$p"
    printf '{"event":"entry","path":%s,"bytes":%d,"kind":"%s","count":%d,"movable":%s,"excluded":%s}\n' \
      "$jp" "$b" "$kind" "$n" "$movable" "$excluded"
    listed=$((listed + 1))
  done < <(LC_ALL=C.UTF-8 grep -zax '.*' "$tmp" | sort -z -t$'\t' -k1,1rn)
  rm -f "$tmp"
  json_str jp "$dir"
  if in_exclusion "$dir"; then excluded=true; else excluded=false; fi
  lens_drive drive "$dir"
  [[ -n $drive ]] && drive_mount_ok "$drive" && drive_trash=true
  json_str drive "$drive"
  printf '{"event":"done","path":%s,"bytes":%d,"items":%d,"count":%d,"found":%d,"excluded":%s,"drive":%s,"drive_trash":%s}\n' \
    "$jp" "$total" "$items" "$listed" "$found" "$excluded" "$drive" "$drive_trash"
}

DUPES_LIMIT=500 # the biggest groups listed by `--json dupes`

json_dupes_progress() { # STAGE DONE TOTAL
  printf '{"event":"progress","stage":"%s","done":%d,"total":%d}\n' "$1" "$2" "$3"
}

# Duplicates like the terminal app (dup_scan): same size → same MD5 of the first 64 KB →
# same full MD5; hidden folders and node_modules skipped. Hard links count once.
json_dupes() { # [--min BYTES] [--path DIR] — groups of identical files, biggest first
  local min=$((1024 * 1024)) dir=$HOME s id m p h i n k key jp files first listed=0 found=0 wasted=0 nfiles=0
  while (($#)); do
    case $1 in
      --min | --path) (($# >= 2)) || { json_error "$1 needs a value."; return 2; } ;;&
      --min) min=$2 ;;
      --path) dir=$2 ;;
      *) json_error "Unknown option for dupes: $1"; return 2 ;;
    esac
    shift 2
  done
  [[ $min =~ ^[0-9]+$ ]] || { json_error "Invalid size: $min"; return 2; }
  [[ -d $dir ]] || { json_error "Not a folder: $dir"; return 2; }
  ((min > 0)) || min=1 # empty files are all alike, never duplicates
  dir=$(realpath -m -s -- "$dir")
  if in_exclusion "$dir"; then printf '{"event":"done","groups":0,"found":0,"files":0,"total_bytes":0}\n'; return 0; fi
  exclusion_prune
  local -a S=() M=() P=() cand=() keys=()
  local -A seen=() nsize=() nhead=() hh=() group=()
  json_dupes_progress list 0 0
  while IFS=$'\t' read -r -d '' s id m p; do
    [[ -n ${seen[$id]:-} ]] && continue # another name of a file already listed
    seen[$id]=1
    [[ $p == *[$'\x01'-$'\x1f\x7f']* ]] && continue
    S+=("$s") M+=("${m%.*}") P+=("$p")
    nsize[$s]=$((${nsize[$s]:-0} + 1))
  done < <(find "$dir" -xdev -mindepth 1 "${XPRUNE[@]}" \( -name '.*' -o -name node_modules \) -prune -o \
    -type f -size +$((min - 1))c -printf '%s\t%D:%i\t%T@\t%p\0' 2>/dev/null | LC_ALL=C.UTF-8 grep -zax '.*')
  for i in "${!P[@]}"; do ((${nsize[${S[i]}]} > 1)) && cand+=("$i"); done
  n=${#cand[@]} k=0
  for i in "${cand[@]}"; do
    ((++k % 25 == 0)) && json_dupes_progress compare "$k" "$n"
    h=$(head -c 65536 -- "${P[i]}" 2>/dev/null | md5sum) || continue
    hh[$i]=${S[i]}:${h%% *}
    nhead[${hh[$i]}]=$((${nhead[${hh[$i]}]:-0} + 1))
  done
  cand=()
  for i in "${!hh[@]}"; do ((${nhead[${hh[$i]}]} > 1)) && cand+=("$i"); done
  n=${#cand[@]} k=0
  for i in "${cand[@]}"; do
    ((++k % 5 == 0)) && json_dupes_progress verify "$k" "$n"
    key=${hh[$i]}
    if ((S[i] > 65536)); then
      h=$(md5sum -- "${P[i]}" 2>/dev/null) || continue
      h=${h%% *}; key=${S[i]}:${h#\\}
    fi
    [[ -n ${group[$key]:-} ]] || keys+=("$key")
    group[$key]+=" $i"
  done
  # biggest files first; in a group the newest copy first
  while IFS= read -r key; do
    read -ra cand <<<"${group[$key]}"
    ((${#cand[@]} > 1)) || continue
    found=$((found + 1))
    ((listed < DUPES_LIMIT)) || continue
    files="" first=1
    while IFS=$'\t' read -r m i; do
      json_str jp "${P[i]}"
      ((first)) || files+=","
      files+="{\"path\":$jp,\"mtime\":$m}" first=0
    done < <(for i in "${cand[@]}"; do printf '%s\t%s\n' "${M[i]}" "$i"; done | sort -t$'\t' -k1,1rn -k2,2n)
    printf '{"event":"group","hash":"%s","bytes":%d,"files":[%s]}\n' "${key#*:}" "${key%%:*}" "$files"
    listed=$((listed + 1)) nfiles=$((nfiles + ${#cand[@]})) wasted=$((wasted + ${key%%:*} * (${#cand[@]} - 1)))
  done < <(((${#keys[@]})) && printf '%s\n' "${keys[@]}" | sort -t: -k1,1rn -k2,2)
  printf '{"event":"done","groups":%d,"found":%d,"files":%d,"total_bytes":%d}\n' "$listed" "$found" "$nfiles" "$wasted"
}

json_file_task() { # PATH STATE INFO BYTES [TRASH-NAME] → one "task" event about a file
  local id info name
  json_str id "$1"; json_str info "$3"; json_str name "${5:-}"
  printf '{"event":"task","id":%s,"state":"%s","info":%s,"freed":%d,"trash":%s}\n' "$id" "$2" "$info" "${4:-0}" "$name"
}

json_trash() { # [--home-only] PATH… — move these to the Trash; "trash" names what `restore` puts back
  ((EUID != 0)) || { json_error "Refusing to move files to the Trash as root"; return 2; }
  local home_only=0
  [[ ${1:-} == --home-only ]] && { home_only=1; shift; } # Space Lens: only what lens_movable allows
  (($#)) || { json_error "No files given."; return 2; }
  local p b moved=0 failed=0 freed=0 errf why name
  errf=$(mktemp -p "$SESSION_TMP") || return 1
  for p in "$@"; do
    if [[ $p != /* ]]; then json_file_task "$p" fail "Not an absolute path" 0; ((++failed)); continue; fi
    if ((home_only)) && ! lens_movable "$(realpath -m -s -- "$p")"; then
      if touches_exclusion "$(realpath -m -s -- "$p")"; then why="Excluded in Settings (Never clean)"
      else why="Only items inside your home folder or on a writable drive can be moved to the Trash here"; fi
      json_file_task "$p" fail "$why" 0; ((++failed)); continue
    fi
    if [[ ! -e $p && ! -L $p ]]; then json_file_task "$p" fail "Not found" 0; ((++failed)); continue; fi
    if [[ -d $p && ! -L $p ]]; then b=$(du -sb -- "$p" 2>/dev/null | cut -f1)
    else b=$(stat -c %s -- "$p" 2>/dev/null); fi
    UNDO_BATCH=()
    if move_to_trash "$p" >/dev/null 2>"$errf"; then
      name=""
      ((${#UNDO_BATCH[@]})) && name=${UNDO_BATCH[0]%%$'\t'*}
      if ((DRY_RUN)); then json_file_task "$p" ok "would be moved to the Trash" "${b:-0}"
      else json_file_task "$p" ok "moved to the Trash" "${b:-0}" "$name"; fi
      moved=$((moved + 1)) freed=$((freed + ${b:-0}))
    else
      why=$(tail -n 1 "$errf"); why=${why//$'\e'\[*([0-9;])m/}; why=${why#*✘ }
      json_file_task "$p" fail "${why:-Could not move it to the Trash}" 0
      ((++failed))
    fi
  done
  rm -f "$errf"
  printf '{"event":"done","moved":%d,"failed":%d,"freed":%d}\n' "$moved" "$failed" "$freed"
}

json_restore() { # KEY… — put these back from the Trash (keys from the "trash" field of `trash`)
  ((EUID != 0)) || { json_error "Refusing to restore files as root"; return 2; }
  (($#)) || { json_error "No files given."; return 2; }
  local key info orig raw ok=0 failed=0
  for key in "$@"; do
    orig=""
    if trash_locate "$key" && info=$TL_DIR/info/$TL_NAME.trashinfo && [[ -f $info && ! -L $info ]]; then
      raw=$(sed -n 's/^Path=//p' "$info" | head -n 1)
      urldecode_path orig "$raw"
      # a drive's Trash may store the path relative to the drive (the spec allows both)
      [[ -n $orig && $orig != /* && $TL_DIR != "$TRASH_DIR" ]] && orig=$TL_TOP/$orig
      [[ $orig == /* ]] && orig=$(realpath -m -s -- "$orig") # resolve ../ before the checks below
    fi
    # only back where it can have come from: your home folder, or the same drive (never into a Trash)
    if [[ -z $TL_TOP || $orig != "$TL_TOP"/* || $orig == "$TL_DIR" || $orig == "$TL_DIR"/* ]] || is_protected "$orig"; then
      json_file_task "${orig:-$key}" fail "Not in the Trash any more" 0 "$key"; ((++failed)); continue
    fi
    if ((DRY_RUN)); then json_file_task "$orig" ok "would be put back" 0 "$key"; ((++ok)); continue; fi
    UNDO_BATCH=("$key"$'\t'"$orig")
    undo_trash
    if ((UNDO_OK)); then json_file_task "$orig" ok "put back" 0 "$key"; ((++ok))
    elif [[ -e $orig || -L $orig ]]; then json_file_task "$orig" fail "A file with this name is already there" 0 "$key"; ((++failed))
    else json_file_task "$orig" fail "Not in the Trash any more" 0 "$key"; ((++failed)); fi
  done
  printf '{"event":"done","restored":%d,"failed":%d}\n' "$ok" "$failed"
}

# ── Startup Items for the desktop app ──
#
# Login apps (your ~/.config/autostart, and the system's entries, which are turned off for
# you by a copy in your folder like the terminal app does) and systemd user services and
# timers. Units that come with the system are only shown. Nothing runs as root; a removed
# entry goes to the Trash.

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_RE='^[A-Za-z0-9_][A-Za-z0-9@._:-]*\.(service|timer)$'

systemd_user_units() { # → "UNIT\tSTATE\tPATH" for services and timers that are enabled or disabled; 1 = no systemd
  local out unit state rest d p
  have systemctl || return 1
  out=$(systemctl --user list-unit-files --type=service --type=timer --no-legend --no-pager 2>/dev/null) || return 1
  while read -r unit state rest; do
    [[ $state == enabled || $state == disabled ]] || continue
    [[ $unit =~ $UNIT_RE && $unit != *@.* ]] || continue # templates have no instance to start
    p=""
    for d in "$SYSTEMD_USER_DIR" "${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user" /etc/systemd/user \
      /usr/local/lib/systemd/user /usr/lib/systemd/user /usr/share/systemd/user; do
      [[ -f $d/$unit ]] && { p=$d/$unit; break; }
    done
    printf '%s\t%s\t%s\n' "$unit" "$state" "$p"
  done <<<"$out"
}

unit_is_yours() { # PATH — a unit file in your own systemd folders
  [[ $1 == "$SYSTEMD_USER_DIR"/* || $1 == "${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"/* ]]
}

json_bool() { if "$@"; then echo true; else echo false; fi; }

json_unit() { # ID KIND NAME ENABLED PATH SYSTEM HIDDEN TOGGLE REMOVABLE DESCRIPTION COMMAND
  local jid jn jp jd jc
  json_str jid "$1"; json_str jn "$3"; json_str jp "$5"; json_str jd "${10}"; json_str jc "${11}"
  printf '{"event":"unit","id":%s,"kind":"%s","name":%s,"enabled":%s,"path":%s,"system":%s,"hidden":%s,"toggle":%s,"removable":%s,"description":%s,"command":%s}\n' \
    "$jid" "$2" "$jn" "$4" "$jp" "$6" "$7" "$8" "$9" "$jd" "$jc"
}

json_startup() {
  ((EUID != 0)) || { json_error "Startup items are per user: run this as yourself, not as root"; return 2; }
  local f b name n=0 units systemd=true unit state p desc
  local -A eff=()
  for f in "$SYSTEM_AUTOSTART_DIR"/*.desktop "$AUTOSTART_DIR"/*.desktop; do
    [[ -f $f ]] && eff[${f##*/}]=$f # your entry overrides the system one
  done
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    f=${eff[$b]} name=$(desktop_get "${eff[$b]}" Name)
    json_unit "autostart:$b" autostart "${name:-${b%.desktop}}" "$(is_disabled "$f" && echo false || echo true)" "$f" \
      "$(json_bool test -f "$SYSTEM_AUTOSTART_DIR/$b")" "$(json_bool test "$(desktop_get "$f" NoDisplay)" = true)" true \
      "$(json_bool test ! -f "$SYSTEM_AUTOSTART_DIR/$b" -a "$f" = "$AUTOSTART_DIR/$b")" \
      "$(desktop_get "$f" Comment)" "$(desktop_get "$f" Exec)"
    n=$((n + 1))
  done < <(((${#eff[@]})) && printf '%s\n' "${!eff[@]}" | sort)
  if units=$(systemd_user_units); then
    while IFS=$'\t' read -r unit state p; do
      [[ -n $unit ]] || continue
      if unit_is_yours "$p"; then
        desc=$(desktop_get "$p" Description)
        json_unit "systemd:$unit" systemd-user "${desc:-$unit}" "$(json_bool test "$state" = enabled)" "$p" false false \
          true "$(json_bool test "$p" != "${p#"$SYSTEMD_USER_DIR"/}")" "$desc" "$(desktop_get "$p" ExecStart)"
      elif [[ $state == enabled ]]; then # the system's own: shown, never changed here
        desc=$( [[ -n $p ]] && desktop_get "$p" Description)
        json_unit "systemd:$unit" systemd-user "${desc:-$unit}" true "$p" true true false false "$desc" \
          "$( [[ -n $p ]] && desktop_get "$p" ExecStart)"
      else continue; fi
      n=$((n + 1))
    done <<<"$units"
  else systemd=false; fi
  printf '{"event":"done","count":%d,"systemd":%s}\n' "$n" "$systemd"
}

json_startup_task() { # ID STATE INFO [TRASH-NAME]
  local id info name
  json_str id "$1"; json_str info "$3"; json_str name "${4:-}"
  printf '{"event":"task","id":%s,"state":"%s","info":%s,"trash":%s}\n' "$id" "$2" "$info" "$name"
}

startup_set_autostart() { # ID FILE-NAME ACTION
  local id=$1 b=$2 act=$3 user sys name
  user=$AUTOSTART_DIR/$b sys=$SYSTEM_AUTOSTART_DIR/$b
  [[ -f $user || -f $sys ]] || { json_startup_task "$id" fail "Not found"; return; }
  if [[ $act == remove ]]; then
    if [[ -f $sys || ! -f $user ]]; then json_startup_task "$id" fail "It comes with the system: turn it off instead"; return; fi
    if ((DRY_RUN)); then json_startup_task "$id" ok "would be moved to the Trash"; return; fi
    UNDO_BATCH=()
    move_to_trash "$user" >/dev/null 2>&1 || { json_startup_task "$id" fail "Could not move it to the Trash"; return; }
    name=""; ((${#UNDO_BATCH[@]})) && name=${UNDO_BATCH[0]%%$'\t'*}
    json_startup_task "$id" ok "moved to the Trash" "$name"; return
  fi
  if ((DRY_RUN)); then json_startup_task "$id" ok "would be turned $( [[ $act == enable ]] && echo on || echo off)"; return; fi
  if [[ ! -f $user ]]; then # a system entry: your own copy overrides it
    mkdir -p -- "$AUTOSTART_DIR" && cp -- "$sys" "$user" || { json_startup_task "$id" fail "Could not write $user"; return; }
  fi
  if [[ $act == disable ]]; then desktop_set "$user" Hidden true >/dev/null
  else run sed -i -e '/^Hidden=/d' -e '/^X-GNOME-Autostart-enabled=false/d' "$user"; fi
  if { [[ $act == disable ]] && is_disabled "$user"; } || { [[ $act == enable ]] && ! is_disabled "$user"; }; then
    json_startup_task "$id" ok "turned $( [[ $act == enable ]] && echo on || echo off)"
  else json_startup_task "$id" fail "Could not change $user"; fi
}

startup_set_systemd() { # ID UNIT ACTION
  local id=$1 unit=$2 act=$3 u state p found="" name err
  [[ $unit =~ $UNIT_RE ]] || { json_startup_task "$id" fail "Not a service or timer"; return; }
  while IFS=$'\t' read -r u state p; do [[ $u == "$unit" ]] && { found=1; break; }; done < <(systemd_user_units)
  [[ -n $found ]] || { json_startup_task "$id" fail "Not found"; return; }
  unit_is_yours "$p" || { json_startup_task "$id" fail "It comes with the system: only shown here"; return; }
  if [[ $act == remove && $p != "$SYSTEMD_USER_DIR"/* ]]; then
    json_startup_task "$id" fail "Only units in ${SYSTEMD_USER_DIR/#$HOME/\~} can be removed"; return
  fi
  if ((DRY_RUN)); then
    if [[ $act == remove ]]; then json_startup_task "$id" ok "would be moved to the Trash"
    else json_startup_task "$id" ok "would be turned $( [[ $act == enable ]] && echo on || echo off)"; fi
    return
  fi
  if [[ $act == remove ]]; then
    [[ $state == enabled ]] && systemctl --user disable --now "$unit" >/dev/null 2>&1
    UNDO_BATCH=()
    move_to_trash "$p" >/dev/null 2>&1 || { json_startup_task "$id" fail "Could not move it to the Trash"; return; }
    name=""; ((${#UNDO_BATCH[@]})) && name=${UNDO_BATCH[0]%%$'\t'*}
    systemctl --user daemon-reload >/dev/null 2>&1
    log "startup: removed $unit"
    json_startup_task "$id" ok "moved to the Trash" "$name"; return
  fi
  # --now: a timer or service starts or stops right away, not only at the next login
  if err=$(systemctl --user "$act" --now "$unit" 2>&1 >/dev/null); then
    log "startup: $act $unit"
    json_startup_task "$id" ok "turned $( [[ $act == enable ]] && echo on || echo off)"
  else json_startup_task "$id" fail "${err:-systemctl --user $act failed}"; fi
}

json_startup_set() { # ID enable|disable|remove
  ((EUID != 0)) || { json_error "Startup items are per user: run this as yourself, not as root"; return 2; }
  (($# == 2)) || { json_error "Usage: --json startup-set ID enable|disable|remove"; return 2; }
  local id=$1 act=$2
  case $act in enable | disable | remove) ;; *) json_error "Unknown action: $act"; return 2 ;; esac
  case $id in
    autostart:*.desktop)
      local b=${id#autostart:}
      [[ $b != */* && $b != .* ]] || { json_error "Unknown startup item: $id"; return 2; }
      startup_set_autostart "$id" "$b" "$act" ;;
    systemd:*) startup_set_systemd "$id" "${id#systemd:}" "$act" ;;
    *) json_error "Unknown startup item: $id"; return 2 ;;
  esac
  printf '{"event":"done"}\n'
}

# ── Settings for the desktop app ──
#
# The same settings file, timer and remembered selections as the terminal app's
# Settings, with the same ranges; nothing else can be set through here.

SCHEDULES=(off daily weekly monthly)

json_setting() { # KEY → one "setting" event with what is in effect now
  local -a r
  local v
  case $1 in
    schedule)
      json_str v "$(schedule_get | head -n 1)"
      printf '{"event":"setting","key":"schedule","value":%s,"choices":["off","daily","weekly","monthly"],"default":"off"}\n' "$v" ;;
    selections) printf '{"event":"setting","key":"selections","value":%d}\n' "${#PREF[@]}" ;;
    recent_files) # GNOME's own setting, as in the terminal app; nothing when gsettings can't read it
      have gsettings || return 0
      case $(gsettings get org.gnome.desktop.privacy remember-recent-files 2>/dev/null) in
        true) v=1 ;; false) v=0 ;; *) return 0 ;;
      esac
      printf '{"event":"setting","key":"recent_files","value":%d}\n' "$v" ;;
    language)
      setting_choice v language
      printf '{"event":"setting","key":"language","value":"%s","choices":["system","en","vi"],"default":"system"}\n' "$v" ;;
    exclusions)
      local e xjson=""
      for e in "${EXCLUDES[@]}"; do json_str v "$e"; xjson+=${xjson:+,}$v; done
      printf '{"event":"setting","key":"exclusions","value":[%s]}\n' "$xjson" ;;
    *)
      read -ra r <<<"${SETTING_RANGE[$1]}"
      setting v "$1"
      printf '{"event":"setting","key":"%s","value":%d,"min":%d,"max":%d,"default":%d}\n' "$1" "$v" "${r[@]}" ;;
  esac
}

json_settings() {
  ((EUID != 0)) || { json_error "Settings are per user: run this as yourself, not as root"; return 2; }
  local k
  for k in language schedule "${SETTING_KEYS[@]}" selections recent_files exclusions; do json_setting "$k"; done
  printf '{"event":"done","systemd":%s,"packaged":%s}\n' "$(json_bool have systemctl)" "$(json_bool packaged)"
}

json_settings_set() { # KEY VALUE — schedule off|daily|weekly|monthly, language system|en|vi, selections reset, recent_files 0|1,
  # exclusions add|remove PATH, or a number in range
  ((EUID != 0)) || { json_error "Settings are per user: run this as yourself, not as root"; return 2; }
  if [[ ${1:-} == exclusions ]]; then
    (($# == 3)) && [[ $2 == add || $2 == remove ]] ||
      { json_error "Usage: --json settings-set exclusions add|remove PATH"; return 2; }
  else
    (($# == 2)) || { json_error "Usage: --json settings-set KEY VALUE"; return 2; }
  fi
  local key=$1 val=$2 state=ok info
  local -a r
  case $key in
    exclusions)
      "exclusion_$val" "$3" || state=fail
      info=$EX_WHY ;;
    schedule)
      [[ " ${SCHEDULES[*]} " == *" $val "* ]] || { json_error "schedule must be one of: ${SCHEDULES[*]}"; return 2; }
      UI_TOAST=""
      schedule_set "$val" || state=fail
      info=${UI_TOAST//$'\e'\[*([0-9;])m/}
      info=${info#"✔ "} info=${info#"✘ "} ;;
    language)
      [[ " ${SETTING_CHOICES[language]} " == *" $val "* ]] ||
        { json_error "language must be one of: ${SETTING_CHOICES[language]}"; return 2; }
      if ((DRY_RUN)); then info="would be set to $val"
      elif save_setting language "$val"; then info="set to $val"
      else state=fail info="Could not save ${SETTINGS_FILE/#$HOME/\~}"; fi ;;
    selections)
      [[ $val == reset ]] || { json_error "selections can only be reset"; return 2; }
      if ((DRY_RUN)); then info="would be forgotten"
      else PREF=(); rm -f -- "$PREF_FILE" && info="forgotten" || state=fail info="Could not remove ${PREF_FILE/#$HOME/\~}"; fi ;;
    recent_files)
      [[ $val == [01] ]] || { json_error "recent_files must be 0 or 1"; return 2; }
      have gsettings || { json_error "gsettings is not available"; return 2; }
      local on=false; ((val)) && on=true
      if ((DRY_RUN)); then info="would be set to $val"
      elif gsettings set org.gnome.desktop.privacy remember-recent-files "$on" 2>/dev/null; then info="set to $val"
      else state=fail info="gsettings could not change it"; fi ;;
    *)
      [[ -n ${SETTING_RANGE[$key]:-} ]] || { json_error "Unknown setting: $key"; return 2; }
      read -ra r <<<"${SETTING_RANGE[$key]}"
      setting_valid "$key" "$val" || { json_error "$key must be a number from ${r[0]} to ${r[1]}"; return 2; }
      val=$((10#$val))
      if ((DRY_RUN)); then info="would be set to $val"
      elif save_setting "$key" "$val"; then info="set to $val"
      else state=fail info="Could not save ${SETTINGS_FILE/#$HOME/\~}"; fi ;;
  esac
  json_str info "$info"
  printf '{"event":"task","id":"%s","state":"%s","info":%s}\n' "$key" "$state" "$info"
  ((DRY_RUN)) && load_settings # show what is saved, not what would be
  json_setting "$key"
  printf '{"event":"done"}\n'
}

json_activity() { # [--limit N] — the activity log the terminal app shows, newest first
  local limit=1000 n=0 epoch text
  while (($#)); do
    case $1 in
      --limit) (($# >= 2)) || { json_error "--limit needs a value."; return 2; }; limit=$2 ;;
      *) json_error "Unknown option for activity: $1"; return 2 ;;
    esac
    shift 2
  done
  [[ $limit =~ ^[0-9]{1,6}$ ]] || { json_error "Invalid limit: $limit"; return 2; }
  if [[ -s $LOG_FILE ]] && ((limit > 0)); then
    # each line is "YYYY-MM-DD HH:MM:SS text"; one `date -f` turns all the times into epochs
    local re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} '
    local -a lines epochs
    mapfile -t lines < <(tac -- "$LOG_FILE" | grep -aE "$re" | head -n "$limit")
    if ((${#lines[@]})); then
      mapfile -t epochs < <(printf '%s\n' "${lines[@]}" | cut -c1-19 | date -f - +%s 2>/dev/null)
      ((${#epochs[@]} == ${#lines[@]})) || epochs=()
      for text in "${lines[@]}"; do
        epoch=${epochs[n]:-0}
        json_str text "${text:20}"
        printf '{"event":"activity","epoch":%d,"text":%s}\n' "$epoch" "$text"
        n=$((n + 1))
      done
    fi
  fi
  json_str text "$LOG_FILE"
  printf '{"event":"done","count":%d,"path":%s}\n' "$n" "$text"
}

# ── Uninstaller for the desktop app ──
#
# `apps` lists exactly what the terminal app's Uninstaller offers (parts of
# Ubuntu are never listed), and `uninstall` only removes apps on that list.
# apt and Snap need root (the app runs this through pkexec), and each takes
# one command for all of its apps; Flatpak apps are removed as you. An app that
# is running is skipped (`check` lists them). Leftover folders go to the Trash with `trash`, as you, after
# the app is gone. After the apps, `leftover` events list the folders of apps
# that are already gone (`orphan_folders`), offered for the Trash on their own.

json_apps() {
  local src id name pkgb datab last paths desk p b jp left jn jid jd hidden=0
  local -a ps
  while IFS=$'\t' read -r src id name pkgb datab last desk paths; do
    if [[ $src == '#hidden' ]]; then hidden=$id; continue; fi
    left=""
    IFS=$'\x1f' read -ra ps <<<"$paths"
    for p in "${ps[@]}"; do
      [[ -n $p ]] || continue
      b=$(du_sum "$p"); json_str jp "$p"
      left+="${left:+,}{\"path\":$jp,\"bytes\":${b:-0}}"
    done
    json_str jid "$src:$id"; json_str jn "$name"; json_str jd "$desk"
    printf '{"event":"app","id":%s,"kind":"%s","name":%s,"bytes":%d,"data_bytes":%d,"last_used":%d,"desktop":%s,"leftovers":[%s]}\n' \
      "$jid" "$src" "$jn" "${pkgb:-0}" "${datab:-0}" "${last:-0}" "$jd" "$left"
  done < <(app_inventory 2>/dev/null)
  while IFS=$'\t' read -r src b p; do # folders of apps that are already gone
    [[ -n $p ]] || continue
    json_str jp "$p"; json_str jn "${p##*/}"
    printf '{"event":"leftover","path":%s,"name":%s,"kind":"%s","bytes":%d}\n' "$jp" "$jn" "$src" "${b:-0}"
  done < <(orphan_folders 2>/dev/null)
  printf '{"event":"done","hidden":%d}\n' "$hidden"
}

json_uninstall() { # [--check] KIND:ID… — remove these apps; --check only says what apt would do and what runs
  local check=0 a src id apt=() ids=() out rc why gone=0 failed=0 skipped=0 msg extra prog jr="" ji jp
  local -A known=() busy=() rc_of=() out_of=()
  [[ ${1:-} == --check ]] && { check=1; shift; }
  (($#)) || { json_error "No apps given."; return 2; }
  while IFS=$'\t' read -r src id _; do [[ $src == '#hidden' ]] || known[$src:$id]=1; done < <(app_inventory 2>/dev/null)
  for a in "$@"; do
    [[ -n ${known[$a]:-} ]] || { json_error "Not an app CleanMate can remove: $a"; return 2; }
    src=${a%%:*}
    if ((EUID == 0 && !check)) && [[ $src == flatpak ]]; then json_error "Flatpak apps are removed as you, not as root: $a"; return 2; fi
    if ((EUID == 0 && !check)) && [[ $src == appimage ]]; then json_error "AppImage apps are removed as you, not as root: $a"; return 2; fi
  done
  for a in "$@"; do # a running app is skipped
    prog=$(app_running "${a%%:*}" "${a#*:}") || continue
    busy[$a]=$prog
    json_str ji "$a"; json_str jp "$prog"
    jr+="${jr:+,}{\"id\":$ji,\"program\":$jp}"
  done
  for a in "$@"; do [[ ${a%%:*} == apt && -z ${busy[$a]:-} ]] && apt+=("${a#*:}"); done
  msg="" extra=0
  if ((${#apt[@]})); then # simulate first: apt may refuse, or take other packages with it
    if apt_check_removal "${apt[@]}"; then extra=$APT_EXTRA_N; else msg=$APT_ERR; fi
  fi
  if ((check)); then
    local jm je
    json_str jm "$msg"; json_str je "$( ((extra)) && printf '%s' "$APT_EXTRA_TEXT")"
    printf '{"event":"check","ok":%s,"message":%s,"extra":%d,"extra_text":%s,"running":[%s]}\n{"event":"done"}\n' \
      "$([[ -z $msg ]] && echo true || echo false)" "$jm" "$extra" "$je" "$jr"
    return
  fi
  [[ -z $msg ]] || { json_error "$msg"; return 2; }
  for a in "$@"; do
    [[ -n ${busy[$a]:-} ]] || continue
    json_file_task "$a" skip "Skipped: ${busy[$a]} is running — close it and try again" 0; ((++skipped))
  done
  for src in apt snap flatpak appimage; do # apt and Snap: one command for all of them; Flatpak and AppImage one by one
    ids=() rc_of=() out_of=()
    for a in "$@"; do [[ ${a%%:*} == "$src" && -z ${busy[$a]:-} ]] && ids+=("${a#*:}"); done
    ((${#ids[@]})) || continue
    for id in "${ids[@]}"; do json_file_task "$src:$id" run "" 0; done
    if [[ $src == flatpak ]]; then
      for id in "${ids[@]}"; do out_of[$id]=$(task_uninstall "flatpak:$id" 2>&1 </dev/null); rc_of[$id]=$?; done
    elif [[ $src == appimage ]]; then # to the Trash: a "trashed" event per file, for Restore
      local file e errf ja jt
      errf=$(mktemp -p "$SESSION_TMP") || return 1
      for id in "${ids[@]}"; do
        urldecode_path file "$id"
        UNDO_BATCH=()
        appimage_remove "$file" >/dev/null 2>"$errf" </dev/null; rc_of[$id]=$?
        out_of[$id]=$(sed 's/\x1b\[[0-9;]*m//g; s/^ *✘ //' "$errf")
        json_str ja "appimage:$id"
        for e in "${UNDO_BATCH[@]}"; do
          json_str jp "${e#*$'\t'}"; json_str jt "${e%%$'\t'*}"
          printf '{"event":"trashed","app":%s,"path":%s,"trash":%s}\n' "$ja" "$jp" "$jt"
        done
      done
      rm -f "$errf"
    else
      out=$(uninstall_batch "$src" "${ids[@]}" 2>&1 </dev/null); rc=$?
      for id in "${ids[@]}"; do out_of[$id]=$out rc_of[$id]=$rc; done
      if ((rc != 0 && !DRY_RUN && ${#ids[@]} > 1)); then # one app stopped the batch: retry each one still
        for id in "${ids[@]}"; do # installed on its own (same root session), so each gets its own error
          app_installed "$src" "$id" || continue
          out_of[$id]=$(uninstall_batch "$src" "$id" 2>&1 </dev/null); rc_of[$id]=$?
        done
      fi
    fi
    for id in "${ids[@]}"; do
      rc=${rc_of[$id]}
      ((rc == 0 || DRY_RUN)) || app_installed "$src" "$id" || rc=0 # the batch failed, but this one is gone
      if ((rc == 0)); then
        json_file_task "$src:$id" ok "$( ((DRY_RUN)) && echo "would be uninstalled" || echo "uninstalled")" 0; ((++gone))
      else
        why=$(grep -v '^\s*$' <<<"${out_of[$id]}" | tail -n 1)
        json_file_task "$src:$id" fail "${why:-failed (exit $rc)}" 0; ((++failed))
        log "json uninstall $src:$id failed: $why"
      fi
    done
  done
  printf '{"event":"done","removed":%d,"failed":%d,"skipped":%d}\n' "$gone" "$failed" "$skipped"
}

json_reset() { # [--check] KIND:ID [FOLDER…] — keep the app, move its data (or these folders of it) to the Trash;
  # --check lists the folders ("data" events) and says which program of it runs
  local check=0 a src id name pkgb datab last desk paths="" found=0 prog="" p b jp total=0
  local -a list=() pick=()
  [[ ${1:-} == --check ]] && { check=1; shift; }
  a=${1:-}
  [[ -n $a ]] || { json_error "No app given."; return 2; }
  shift
  ((check || EUID != 0)) || { json_error "Refusing to reset an app as root: its data is in your home"; return 2; }
  while IFS=$'\t' read -r src id name pkgb datab last desk p; do
    [[ $src:$id == "$a" ]] && found=1 paths=$p
  done < <(app_inventory 2>/dev/null)
  ((found)) || { json_error "Not an app CleanMate can reset: $a"; return 2; }
  src=${a%%:*} id=${a#*:}
  mapfile -t list < <(reset_paths "$src" "$id" "$paths")
  prog=$(app_running "$src" "$id") || prog=""
  if ((check)); then
    for p in "${list[@]}"; do
      b=$(du_sum "$p"); total=$((total + ${b:-0})); json_str jp "$p"
      printf '{"event":"data","path":%s,"bytes":%d}\n' "$jp" "${b:-0}"
    done
    json_str jp "$prog"
    printf '{"event":"done","count":%d,"bytes":%d,"running":%s}\n' "${#list[@]}" "$total" "$jp"
    return
  fi
  [[ -z $prog ]] || { json_error "Close $prog first: resetting an app while it runs can lose what is open in it"; return 2; }
  if (($#)); then # only folders of this app that resetting it would take
    for p in "$@"; do
      printf '%s\n' "${list[@]}" | grep -qxF -- "$p" || { json_error "Not a data folder of $a: $p"; return 2; }
      pick+=("$p")
    done
  else pick=("${list[@]}"); fi
  ((${#pick[@]})) || { json_error "Nothing to reset: this app keeps no data in your home."; return 2; }
  log "reset $a"
  json_trash "${pick[@]}"
}

# Maintenance: `maintenance` lists the items with their state, `maintain ID` runs
# one, streaming each step ("task") and its output ("log"). Steps that need root
# run when the engine is root (pkexec); the others only as you — the desktop app
# runs an item in two parts when it has both (`--user-steps` = only yours).

json_maint_item() { # ID → one "maint" event
  local id=$1 fn label desc why root=false user=false toggle=false on=false value="" target=""
  maint_missing "$id"
  json_str why "$MAINT_WHY"; json_str label "${MAINT_LABEL[$id]}"; json_str desc "${MAINT_DESC[$id]}"
  new_tasks; maint_tasks "$id" on
  for fn in "${T_FN[@]}"; do if maint_user_step "$fn"; then user=true; else root=true; fi; done
  case $id in
    snap_versions) toggle=true target=2; [[ -z $MAINT_WHY ]] && value=$(snap_retain); [[ $value == 2 ]] && on=true ;;
    journal_limit) toggle=true target=$JOURNAL_KEEP_MB value=$(journal_cap); [[ -n $value ]] && on=true ;;
  esac
  value=${value//[^0-9]/}
  printf '{"event":"maint","id":"%s","label":%s,"description":%s,"available":%s,"reason":%s,"root":%s,"user":%s,"toggle":%s,"on":%s,"value":"%s","target":"%s"}\n' \
    "$id" "$label" "$desc" "$([[ -z $MAINT_WHY ]] && echo true || echo false)" "$why" "$root" "$user" "$toggle" "$on" "$value" "$target"
}

json_maintenance() {
  local id
  for id in "${MAINT_IDS[@]}"; do json_maint_item "$id"; done
  printf '{"event":"done"}\n'
}

json_log_lines() { # stdin → one "log" event per non-empty line (a progress line keeps its last \r part)
  local l
  while IFS= read -r l || [[ -n $l ]]; do
    l=${l%$'\r'}; l=${l##*$'\r'}
    [[ -n ${l//[[:space:]]/} ]] || continue
    json_str l "$l"
    printf '{"event":"log","line":%s}\n' "$l"
  done
}

json_step() { # INDEX STATE INFO → one "task" event about a step of T_FN
  local label info
  json_str label "${T_LABEL[$1]}"; json_str info "${3:-}"
  printf '{"event":"task","id":"%s","label":%s,"state":"%s","info":%s}\n' "${T_FN[$1]#m_}" "$label" "$2" "$info"
}

json_maintain() { # ID [on|off] [--user-steps]
  local id=${1:-} a mode="" user_only=0 i fn out rc n_ok=0 n_fail=0 n_skip=0
  local -a steps=()
  shift || true
  [[ -n ${MAINT_LABEL[$id]:-} ]] || { json_error "Unknown maintenance item: $id"; return 2; }
  for a in "$@"; do
    case $a in
      on | off) mode=$a ;;
      --user-steps) user_only=1 ;;
      *) json_error "Unknown option: $a"; return 2 ;;
    esac
  done
  if [[ $id == @(snap_versions|journal_limit) ]]; then
    [[ -n $mode ]] || { json_error "$id needs on or off"; return 2; }
  elif [[ -n $mode ]]; then json_error "$id has no on or off"; return 2; fi
  if maint_missing "$id"; then json_error "$MAINT_WHY"; return 2; fi
  new_tasks
  maint_tasks "$id" "$mode"
  for i in "${!T_FN[@]}"; do
    if maint_user_step "${T_FN[i]}"; then ((EUID == 0)) || steps+=("$i")
    elif ((!user_only)); then steps+=("$i"); fi
  done
  if ((${#steps[@]} == 0 && EUID == 0)); then json_error "${MAINT_LABEL[$id]} runs as you, not as root"; return 2; fi
  T_STATE=() T_INFO=()
  for i in "${steps[@]}"; do
    fn=${T_FN[i]} T_INFO[i]=""
    json_step "$i" run
    if declare -F "${fn}_pre" >/dev/null && ! "${fn}_pre" "${T_ARG[i]}"; then
      json_step "$i" skip "skipped"; ((++n_skip)); continue
    fi
    out=$(mktemp -p "$SESSION_TMP")
    "$fn" "${T_ARG[i]}" </dev/null 2>&1 | tee "$out" | json_log_lines
    rc=${PIPESTATUS[0]}
    ((rc == 0)) || T_INFO[i]="failed (exit $rc)"
    declare -F "${fn}_post" >/dev/null && "${fn}_post" "${T_ARG[i]}" "$rc" "$i" "$out"
    if ((rc == 0)); then
      [[ -n ${T_INFO[i]} ]] || T_INFO[i]=$( ((DRY_RUN)) && echo "would run" || echo "done")
      json_step "$i" ok "${T_INFO[i]}"; ((++n_ok))
    else
      json_step "$i" fail "${T_INFO[i]}"; ((++n_fail))
      log "json maintain $id: ${T_LABEL[i]} failed (exit $rc)"
    fi
    rm -f "$out"
  done
  log "GUI maintenance $id finished — $n_ok ok, $n_fail failed, $n_skip skipped (dry-run=$DRY_RUN)"
  printf '{"event":"done","ok":%d,"failed":%d,"skipped":%d}\n' "$n_ok" "$n_fail" "$n_skip"
}

# System Overview for the desktop app: the same facts as the terminal app's,
# as numbers. "freed" comes only once a cleanup was recorded.

json_overview() {
  local t s u a fs dev jt jf jd j1 j2 j3 since=0 n30=0 b30=0 e b cut kind path n note top="" d by_day="" days=()
  local -A day_b=() day_n=()
  sys_facts; pkg_counts; mem_facts
  json_str j1 "$OV_OS"; json_str j2 "$OV_KERNEL"; json_str j3 "$OV_CPU"
  printf '{"event":"system","os":%s,"kernel":%s,"cpu":%s,"threads":%d,"uptime":%d,"apt":%s,"snap":%s,"flatpak":%s}\n' \
    "$j1" "$j2" "$j3" "${OV_THREADS:-0}" "${OV_UPTIME:-0}" "${OV_APT:-null}" "${OV_SNAP:-null}" "${OV_FLATPAK:-null}"
  while IFS=$'\t' read -r t s u a fs dev; do
    [[ $s =~ ^[0-9]+$ && $u =~ ^[0-9]+$ && $a =~ ^[0-9]+$ ]] || continue
    json_str jt "$t"; json_str jf "$fs"; json_str jd "$dev"
    printf '{"event":"disk","mount":%s,"fstype":%s,"device":%s,"size":%d,"used":%d,"avail":%d}\n' "$jt" "$jf" "$jd" "$s" "$u" "$a"
  done < <(disk_rows)
  printf '{"event":"memory","ram_total":%d,"ram_used":%d,"ram_avail":%d,"swap_total":%d,"swap_used":%d}\n' \
    "$OV_RAM_TOTAL" "$((OV_RAM_TOTAL - OV_RAM_AVAIL))" "$OV_RAM_AVAIL" "$OV_SWAP_TOTAL" "$OV_SWAP_USED"
  if [[ -f $CLEANUP_HISTORY || -n ${STATS[runs]:-} ]]; then
    cut=$((EPOCHSECONDS - 30 * 86400))
    # the last 30 calendar days, today last: noon of each day, so a DST change never skips one
    printf -v t '%(%H %M %S)T' "$EPOCHSECONDS"; read -r s u a <<<"$t"
    t=$((EPOCHSECONDS - 10#$s * 3600 - 10#$u * 60 - 10#$a + 43200))
    for ((n = 29; n >= 0; n--)); do printf -v d '%(%F)T' $((t - n * 86400)); days+=("$d"); day_b[$d]=0 day_n[$d]=0; done
    if [[ -f $CLEANUP_HISTORY ]]; then
      while IFS=$'\t' read -r e b; do
        [[ $e =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || continue
        ((since == 0)) && since=$e
        ((e >= cut)) && { ((++n30)); b30=$((b30 + b)); }
        printf -v d '%(%F)T' "$e"
        [[ -n ${day_b[$d]:-} ]] && { day_b[$d]=$((day_b[$d] + b)); day_n[$d]=$((day_n[$d] + 1)); }
      done <"$CLEANUP_HISTORY"
    fi
    ((since)) && for d in "${days[@]}"; do
      by_day+="${by_day:+,}{\"date\":\"$d\",\"bytes\":${day_b[$d]},\"cleanups\":${day_n[$d]}}"
    done
    printf '{"event":"freed","days":30,"bytes":%d,"cleanups":%d,"since":%d,"lifetime":%d,"runs":%d,"last_time":%d,"last_bytes":%d,"freed_by_day":[%s]}\n' \
      "$b30" "$n30" "$since" "${STATS[lifetime]:-0}" "${STATS[runs]:-0}" "${STATS[last_time]:-0}" "${STATS[last_freed]:-0}" "$by_day"
  fi
  while IFS=$'\t' read -r t s u a; do
    json_str jd "$a"
    printf '{"event":"protection","id":"%s","state":"%s","reason":"%s","command":%s}\n' "$t" "$s" "$u" "$jd"
  done < <(protection_rows)
  record_disk_usage # opening the app counts as a use, like a scan in the terminal app
  json_history
  # the slow part last (du), so the app shows everything above meanwhile
  while IFS=$'\t' read -r kind b path n note; do
    json_str jt "$path"; json_str jd "$note"
    [[ $b == - ]] && b=null
    printf '{"event":"outside","kind":"%s","bytes":%s,"path":%s,"count":%d,"note":%s}\n' "$kind" "$b" "$jt" "$n" "$jd"
  done < <(hidden_space_rows)
  while IFS=$'\t' read -r -d '' b path; do
    [[ $path == *[$'\x01'-$'\x1f\x7f']* ]] && continue # only names that round-trip through JSON
    json_str jt "$path"
    top+="${top:+,}{\"path\":$jt,\"bytes\":$b}"
  done < <(top_home_dirs | LC_ALL=C.UTF-8 grep -zax '.*')
  json_str jt "$HOME"
  printf '{"event":"top_dirs","home":%s,"dirs":[%s]}\n' "$jt" "$top"
  printf '{"event":"done"}\n'
}

json_history() { # free space on / for the last 30 recorded days → one "history" event
  local rows=() epochs=() i d a sz pts="" each=0
  [[ -f $DISK_HISTORY ]] &&
    mapfile -t rows < <(grep -E $'^[0-9]{4}-[0-9]{2}-[0-9]{2}\t[0-9]+\t[0-9]+$' "$DISK_HISTORY" | tail -n 30)
  # one date call for all the days; a day it can't read leaves a gap, so then one call per day
  ((${#rows[@]})) && mapfile -t epochs < <(printf '%s\n' "${rows[@]}" | cut -f1 | date -f - +%s 2>/dev/null)
  ((${#epochs[@]} == ${#rows[@]})) || each=1
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r d a sz <<<"${rows[i]}"
    ((each)) && epochs[i]=$(date -d "$d" +%s 2>/dev/null)
    [[ ${epochs[i]:-} =~ ^[0-9]+$ ]] || continue
    pts+="${pts:+,}{\"time\":${epochs[i]},\"avail\":$a,\"size\":$sz}"
  done
  printf '{"event":"history","points":[%s]}\n' "$pts"
}

# ───────────────────────────── desktop app ──────────────────────────────────

GUI_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/cleanmate/gui"

# Installed by a package (.deb): files live in ../share/cleanmate next to the
# command, and apt — not this script — handles updates and removal.
PKG_SHARE="$(dirname "$SELF")/../share/cleanmate"
packaged() { [[ -f $PKG_SHARE/packaged || -n ${SNAP:-} ]]; }
pkg_update_hint() { # how this copy gets updates
  if [[ -n ${SNAP:-} ]]; then printf '    Snaps update automatically (or: sudo snap refresh cleanmate)\n'
  else printf '    sudo apt update && sudo apt upgrade\n'; fi
}

gui_dir() { # where the desktop app lives: next to this script (a clone), installed, or packaged
  local d
  for d in "$(dirname "$SELF")/gui" "$GUI_HOME" "$PKG_SHARE/gui"; do
    [[ -f $d/cleanmate-gui && -d $d/cleanmate_gui ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

gui_supported() { # Python + PyGObject + GTK 4 + libadwaita ≥ 1.5
  python3 - 2>/dev/null <<'PY'
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw
raise SystemExit(0 if (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5) else 1)
PY
}

launch_gui() {
  local dir
  if ! dir=$(gui_dir); then
    err "The desktop app isn't installed. Get it from $REPO_URL (folder gui/) and run --install from there."
    return 1
  fi
  if ! gui_supported; then
    err "The desktop app needs GTK 4 + libadwaita 1.5 (Ubuntu 24.04 or newer)."
    err "On older systems use the terminal app: cm"
    return 1
  fi
  local extra=()
  ((DRY_RUN)) && extra=(--dry-run)
  exec python3 "$dir/cleanmate-gui" --engine "$SELF" "${extra[@]}"
}

# ───────────────────────────── main ─────────────────────────────────────────

usage() {
  cat <<EOF
CleanMate $VERSION — free up disk space and keep Ubuntu tidy. Inspired by CleanMyMac.

Usage: $(basename "$0") [options]        (installed as: cm)

Run
  (no option)       Open the terminal app
      --gui         Open the desktop app (Ubuntu 24.04 or newer)
  -n, --dry-run     Show what would happen; delete nothing (works with everything)
      --no-mouse    Terminal app: don't capture the mouse

Scan & clean without the app
  -s, --scan        Print what a Smart Scan finds
  -c, --clean       Smart Scan, then clean the selected items (asks once)
  -y, --yes         With --clean: don't ask (running apps are skipped)
      --only LIST   Only these groups: system,logs,user,browser,apps,ai,models,dev,privacy
                    (privacy is only included when named)
      --auto        What automatic cleaning runs: user & developer junk, then a
                    desktop notification

Install & update
      --install     Install the cm command, the desktop app and the app-grid entry
      --update      Check for a new version and install it (asks first)
      --uninstall   Remove everything --install added
  -v, --version     Print the version

For the desktop app
      --json CMD    Machine-readable engine: items, scan, details ID, clean ID…,
                    large [--min BYTES] [--days N] [--path DIR], lens [--path DIR],
                    dupes [--min BYTES] [--path DIR], startup, startup-set ID enable|disable|remove,
                    trash [--home-only] PATH…, restore KEY…, apps, uninstall [--check] KIND:ID…,
                    reset [--check] KIND:ID [FOLDER…]

Keys: ↑↓ or j/k move · space select · enter/→ open · / find · z undo · q back · ? help

Activity log:         $LOG_FILE
Remembered choices:   $PREF_FILE
Source & bug reports: $REPO_URL — made by HomieLab (https://homielab.com)
EOF
}

home_top() {
  local msg
  fl ""
  if [[ -n ${UPDATE_DONE:-} ]]; then
    fl "  ${GREEN}✔${NC} ${BOLD}Updated to $UPDATE_DONE.${NC} ${DIM}Quit and start cm again to use the new version.${NC}"
  elif [[ -n ${STATS[last_time]} ]]; then
    local when last total runs
    agov when "${STATS[last_time]}"; humanv last "${STATS[last_freed]}"; humanv total "${STATS[lifetime]}"
    pluralv runs "${STATS[runs]}" cleanup
    fitv msg "Last cleanup $when freed $last · $total freed over $runs" $((UI_W - 18))
    fl "  ${BOLD}Welcome back.${NC} ${DIM}$msg${NC}"
  else
    fitv msg "Start with a Smart Scan — nothing is deleted until you confirm." $((UI_W - 14))
    fl "  ${BOLD}Welcome!${NC} ${DIM}$msg${NC}"
  fi
  fl ""
}

# Menu builders: mi KEY LABEL [DESC] [BADGE] adds an item, mh TITLE a section
# header (mh "" a blank line). Badges stay attached to their own row.
mi() { M_KEY+=("$1") M_LABEL+=("$2") M_DESC+=("${3:-}"); [[ -n ${4:-} ]] && M_BADGE[${#M_KEY[@]} - 1]=$4; return 0; }
mh() { # TITLE — a blank row, then the header row (each row is exactly one line)
  M_KEY+=("") M_LABEL+=("") M_DESC+=("")
  [[ -n $1 ]] && M_KEY+=("#") M_LABEL+=("$1") M_DESC+=("")
  return 0
}

main_menu() {
  while :; do
    M_KEY=() M_LABEL=() M_DESC=() M_BADGE=()
    load_update_state
    cat_badge "${CATEGORIES[@]}"; mi 1 "Smart Scan" "Scan everything and clean in one go" "$BADGE"
    mh "Cleanup"
    cat_badge system;            mi 2 "System Junk" "Package cache, old kernels, leftover configs, snaps, temp files" "$BADGE"
    cat_badge logs;              mi 3 "Logs" "Journal, oversized and rotated logs, crash reports, app logs" "$BADGE"
    cat_badge user browser apps; mi 4 "User & App Junk" "Trash, thumbnails, browser and app caches" "$BADGE"
    cat_badge ai models;         mi 5 "AI Tools" "Claude, Codex, Gemini, opencode, Zed: caches, old chats, models" "$BADGE"
    cat_badge dev;               mi 6 "Developer Junk" "Stale node_modules, npm, pip, Go, Cargo, Conda, Docker…" "$BADGE"
    cat_badge privacy;           mi 7 "Privacy" "Browser & terminal history, recent files…" "$BADGE"
    mh "Files"
    mi 8 "Space Lens" "Explore what takes up space, folder by folder"
    mi 9 "Large & Old Files" "Find space hogs and forgotten downloads"
    mi 0 "Duplicates" "Find identical files and keep one copy"
    mh "Apps & System"
    mi u "Uninstaller" "Remove apps and their leftovers"
    mi t "Startup Items" "Choose what launches at login"
    mi m "Maintenance" "Updates, repairs, TRIM, free RAM"
    mi i "System Overview" "Storage, memory and your biggest folders"
    mh ""
    ((${#UNDO_BATCH[@]})) && mi z "↶ Undo last Trash" "Put back the $(plural ${#UNDO_BATCH[@]} item) you just moved to the Trash"
    mi s "Settings" "Automatic cleaning, updates, retention, about"
    [[ -n $UPDATE_LATEST ]] && mi n "⬆ Update to $UPDATE_LATEST" "You have $VERSION — install the new version"
    mi q "Quit"
    ui_menu "Home" home_top || return 0
    case ${M_KEY[MENU_IDX]} in
      1) scan_and_review "Smart Scan" "${CATEGORIES[@]}" ;;
      2) scan_and_review "System Junk" system ;;
      3) scan_and_review "Logs" logs ;;
      4) scan_and_review "User & App Junk" user browser apps ;;
      5) scan_and_review "AI Tools" ai models ;;
      6) scan_and_review "Developer Junk" dev ;;
      7) scan_and_review "Privacy" privacy ;;
      8) space_lens_menu ;;
      9) large_files_menu ;;
      0) duplicates_menu ;;
      u) uninstaller_menu ;;
      t) startup_menu ;;
      m) maintenance_menu ;;
      i) overview ;;
      s) settings_menu ;;
      n) ui_update ;;
      z) undo_trash; undo_toast ;;
      q) return 0 ;;
    esac
    refresh_sysinfo
  done
}

# Sourced (e.g. by tests/run.sh)? Stop here: only define functions and defaults.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

while (($#)); do
  case $1 in
    -n | --dry-run) DRY_RUN=1 ;;
    -s | --scan) MODE=scan ;;
    -c | --clean) MODE=clean ;;
    -y | --yes) ASSUME_YES=1 ;;
    --auto) MODE=auto ;;
    --no-mouse) MOUSE=0 ;;
    --only)
      shift
      IFS=, read -ra CATEGORIES <<<"${1:-}"
      for _c in "${CATEGORIES[@]}"; do
        [[ -n ${CAT_TITLE[$_c]:-} ]] || { err "Unknown category: $_c (use system, logs, user, browser, apps, ai, models, dev, privacy)"; exit 2; }
      done ;;
    -h | --help) usage; exit 0 ;;
    -v | --version) echo "cleanmate $VERSION"; exit 0 ;;
    --install) MODE=install ;;
    --uninstall) MODE=uninstall ;;
    --update) MODE=update ;;
    --json) MODE=json ;;
    --gui) MODE=gui ;;
    -*)
      [[ $MODE == json && ${#JSON_ARGS[@]} -gt 0 ]] || { err "Unknown option: $1"; usage; exit 2; }
      JSON_ARGS+=("$1") ;; # an option of the JSON command, e.g. large --min
    *)
      [[ $MODE == json ]] || { err "Unknown argument: $1"; usage; exit 2; }
      JSON_ARGS+=("$1") ;;
  esac
  shift
done

on_interrupt() { # stop every background job and its children (they ignore SIGINT)
  local p
  for p in $(jobs -p); do kill_tree "$p"; done
  ui_stop
  printf '%s\n' "$NC"
  exit 130
}

SESSION_TMP=$(mktemp -d -t cleanmate.XXXXXX) || exit 1
trap 'rm -rf "$SESSION_TMP"' EXIT
trap 'on_interrupt' INT TERM

load_kv "$STATS_FILE" STATS '^[0-9]+$'
load_settings
load_scan_cache

case $MODE in
  scan) INTERACTIVE=0; scan_report; exit 0 ;;
  clean) INTERACTIVE=0; smart_clean; exit 0 ;;
  auto) auto_mode; exit 0 ;;
  install) INTERACTIVE=0; cli_install; exit ;;
  uninstall) INTERACTIVE=0; cli_uninstall; exit ;;
  update) INTERACTIVE=0; cli_update; exit ;;
  json) INTERACTIVE=0 ASSUME_YES=1 JSON=1; json_main "${JSON_ARGS[@]}"; exit ;;
  gui) launch_gui; exit ;;
esac
((ASSUME_YES)) && { err "--yes only works together with --clean."; exit 2; }

[[ -t 0 && -t 1 ]] || { err "This script is interactive; run it from a terminal (or use --scan)."; exit 1; }

if ((EUID == 0)); then
  warn "Running as root: user-level cleanup will target /root, not your account."
  confirm "Continue anyway? (Recommended: run as your user, sudo is requested when needed)" || exit 1
fi

trap 'ui_stop; rm -rf "$SESSION_TMP"' EXIT
refresh_sysinfo
update_check_bg
ui_start
main_menu
ui_stop
printf '\n  %sBye! Keep it clean. ✨%s\n\n' "$ACCENT" "$NC"
