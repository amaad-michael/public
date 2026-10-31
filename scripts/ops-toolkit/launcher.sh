#!/usr/bin/env bash
#
# launcher.sh — a menu front end for the Ops Toolkit.
#
# Presents the toolkit's six jobs (sys-health, backup-verify,
# log-clean, cert-expiry-audit, service-uptime, tmp-clean) as one
# numbered list with each job's one-line purpose, and dispatches to
# the chosen job. On a terminal the list is an arrow-key panel; off
# a terminal (or with TERM=dumb) the same list is printed as a
# numbered text menu and the choice is read as a line, so the
# launcher stays usable in pipes and scripts.
#
# Each job finds its own configuration without the launcher's
# help: every job sources common.sh from its own directory and
# load_config reads /etc/ops/ops.conf by absolute path, so no job
# depends on the caller's working directory and the launcher
# dispatches by absolute path, leaving the caller's directory
# untouched. None of the six jobs takes command-line arguments
# today (all tuning lives in /etc/ops/ops.conf); arguments given
# to the launcher are still forwarded to the chosen job unchanged,
# and with no launcher arguments the operator is prompted for them
# after choosing, exactly as if typed after the job's name on the
# command line. The launcher adds no confirmation semantics of its
# own and no sudo of its own: each job keeps its own behavior and
# exit codes, and the launcher exits with the job's exit status.
# The jobs themselves are not modified.
#
# Usage: launcher.sh [--] [args forwarded to the chosen job]
#        launcher.sh --help
#
# Ops Toolkit launcher (2026-10-31).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# --- Job table -------------------------------------------------------
# One entry per job, in the README "Included jobs" order. NUM is the
# number shown on the row (and the number typed to jump to it); NAME
# is the job's script basename (the script is NAME.sh in this
# folder); PURPOSE is the job's one-line purpose, trimmed from its
# own header. Keep this table in step with the README's job list,
# which is the cross-check. common.sh is the jobs' shared library,
# not a job, and is deliberately not listed.
TOOL_NUM=(1 2 3 4 5 6)
TOOL_NAME=(sys-health backup-verify log-clean cert-expiry-audit \
  service-uptime tmp-clean)
TOOL_PURPOSE=(
  "Sample host health once; append a CSV row and top-process snapshot"
  "Scan the backup log for failures; weekly restore spot-check"
  "Rotate and gzip logs, delete old archives, prune tmp and cache"
  "Fetch each TLS endpoint's cert; flag any expiring soon"
  "Check listed services are up; dump priority journal entries"
  "Delete stale files from /tmp, /var/tmp and /var/cache"
)

usage() {
  cat <<'EOF'
Usage: launcher.sh [--] [args forwarded to the chosen job]
       launcher.sh --help

A menu front end for the Ops Toolkit. On a terminal it opens an
arrow-key panel listing the six jobs; off a terminal (or with
TERM=dumb) it prints the same list as a numbered text menu and
reads the choice as a line.

Panel keys: arrows or j/k move, Enter runs the highlighted job,
typing a job number and Enter jumps straight to it, q quits.

After a job is chosen, any arguments given to the launcher are
forwarded to the job unchanged; with no launcher arguments, you
are prompted for the job's arguments (blank for none; the line
is split on whitespace, quoting is not honored). None of the six
jobs takes arguments today (all tuning is in /etc/ops/ops.conf),
so forwarded arguments are passed through exactly as they would
be on the job's own command line. The launcher is one-shot: it
runs the chosen job in the foreground and exits with the job's
exit status. The jobs themselves are unchanged.
EOF
}

# --- Display rows ----------------------------------------------------
# ROWS holds the printable lines in README job order. ROW_TOOL maps
# a display row to a job-table index. Both front ends render these
# same rows, so the panel and the printed list can never drift
# apart.
ROWS=()
ROW_TOOL=()

build_rows() {
  local ti row
  ROWS=()
  ROW_TOOL=()
  for ti in "${!TOOL_NUM[@]}"; do
    printf -v row '%s  %-17s %s' "${TOOL_NUM[$ti]}" "${TOOL_NAME[$ti]}" "${TOOL_PURPOSE[$ti]}"
    if [[ ! -x $(tool_path "$ti") ]]; then
      row="${row} [missing]"
    fi
    ROWS+=("$row")
    ROW_TOOL+=("$ti")
  done
}

tool_path() {
  local ti=$1
  printf '%s/%s.sh' "$SCRIPT_DIR" "${TOOL_NAME[$ti]}"
}

# --- Dispatch --------------------------------------------------------
# Runs job-table entry $1 in the foreground and exits with its
# status. Arguments: the launcher's own arguments if any were
# given, otherwise a line read from the operator (blank = none).
FORWARD_ARGS=()

dispatch() {
  local ti=$1 path line rc=0
  local -a args=()
  path=$(tool_path "$ti")
  if [[ ! -x $path ]]; then
    printf 'launcher: job script missing or not executable: %s\n' "$path" >&2
    exit 2
  fi
  if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
    args=("${FORWARD_ARGS[@]}")
  else
    line=""
    IFS= read -r -e -p "Arguments for ${TOOL_NUM[$ti]} ${TOOL_NAME[$ti]} (blank for none): " line || line=""
    if [[ -n $line ]]; then
      read -r -a args <<< "$line"
    fi
  fi
  printf 'launcher: running %s.sh' "${TOOL_NAME[$ti]}" >&2
  if [[ ${#args[@]} -gt 0 ]]; then
    printf ' %s' "${args[@]}" >&2
  fi
  printf '\n' >&2
  "$path" "${args[@]}" || rc=$?
  exit "$rc"
}

# --- Numbered text menu (off-terminal form) --------------------------
text_menu() {
  local row choice ti
  printf 'Ops Toolkit -- 6 jobs\n'
  printf 'Type a job number and press Enter; blank or q quits.\n\n'
  for row in "${ROWS[@]}"; do
    printf '%s\n' "$row"
  done
  choice=""
  IFS= read -r -p 'Job number: ' choice || choice=""
  choice="${choice//[[:space:]]/}"
  case $choice in
    '' | q | Q)
      return 0
      ;;
  esac
  if [[ ! $choice =~ ^[0-9]+$ ]] || [[ $((10#$choice)) -lt 1 ]] || [[ $((10#$choice)) -gt 6 ]]; then
    printf "launcher: '%s' is not a job number (1-6)\n" "$choice" >&2
    exit 2
  fi
  ti=$(tool_index_for_num "$((10#$choice))")
  dispatch "$ti"
}

tool_index_for_num() {
  local want=$1 ti
  for ti in "${!TOOL_NUM[@]}"; do
    if [[ $((10#${TOOL_NUM[$ti]})) -eq $want ]]; then
      printf '%s' "$ti"
      return 0
    fi
  done
  printf '%s' "-1"
}

# --- Interactive panel (begin) ---------------------------------------
# Pure bash and ANSI in the repo's panel conventions: no external
# TUI tool, an ASCII frame, a reverse-video cursor row, the cursor
# hidden while the panel is drawn and restored on every exit from
# it, and a trap on INT/TERM that restores the cursor and exits
# 130. The six display rows fit the viewport whole, so the frame
# is the same height on every redraw and is redrawn in place.
# Movement wraps at both ends. Typing digits starts a jump buffer
# shown in the footer; Enter with a buffer pending runs that job
# number instead of the highlighted row.
PANEL_VIEW=6
PANEL_CURSOR=0
PANEL_TOP=0
PANEL_FIRST=1
PANEL_FRAME_LINES=0
PANEL_WIDTH=0
PANEL_DIGITS=""
PANEL_NOTE=""

panel_init() {
  local line len
  PANEL_WIDTH=0
  for line in "${ROWS[@]}" "Ops Toolkit -- 6 jobs" \
    "arrows or j/k move, enter runs, digits + enter jump, q quits"; do
    len=${#line}
    if [[ $len -gt $PANEL_WIDTH ]]; then
      PANEL_WIDTH=$len
    fi
  done
  PANEL_CURSOR=0
  while [[ ${ROW_TOOL[$PANEL_CURSOR]} -eq -1 ]]; do
    PANEL_CURSOR=$((PANEL_CURSOR + 1))
  done
  PANEL_TOP=0
  PANEL_FIRST=1
  PANEL_DIGITS=""
  PANEL_NOTE=""
}

panel_erase() {
  local i
  printf '\033[%dA' "$PANEL_FRAME_LINES"
  for ((i = 0; i < PANEL_FRAME_LINES; i++)); do
    printf '\033[2K'
    if [[ $i -lt $((PANEL_FRAME_LINES - 1)) ]]; then
      printf '\n'
    fi
  done
  printf '\033[%dA' $((PANEL_FRAME_LINES - 1))
  printf '\033[?25h'
}

panel_draw() {
  local -a frame=()
  local line="" dashes="" border="" footer=""
  local i ri
  printf -v dashes '%*s' $((PANEL_WIDTH + 2)) ''
  dashes="${dashes// /-}"
  border="+${dashes}+"
  frame+=("$border")
  printf -v line '| %-*s |' "$PANEL_WIDTH" "Ops Toolkit -- 6 jobs"
  frame+=("$line")
  frame+=("$border")
  for ((i = 0; i < PANEL_VIEW; i++)); do
    ri=$((PANEL_TOP + i))
    printf -v line '| %-*s |' "$PANEL_WIDTH" "${ROWS[$ri]}"
    frame+=("$line")
  done
  frame+=("$border")
  if [[ -n $PANEL_DIGITS ]]; then
    footer="job: ${PANEL_DIGITS}_  (enter runs it, backspace edits)"
  elif [[ -n $PANEL_NOTE ]]; then
    footer=$PANEL_NOTE
  else
    footer="arrows or j/k move, enter runs, digits + enter jump, q quits"
  fi
  printf -v line '| %-*s |' "$PANEL_WIDTH" "$footer"
  frame+=("$line")
  frame+=("$border")
  PANEL_FRAME_LINES=${#frame[@]}
  if [[ $PANEL_FIRST -eq 1 ]]; then
    PANEL_FIRST=0
  else
    printf '\033[%dA' "${#frame[@]}"
  fi
  for i in "${!frame[@]}"; do
    if [[ $i -eq $((3 + PANEL_CURSOR - PANEL_TOP)) ]]; then
      printf '\r\033[7m%s\033[0m\n' "${frame[$i]}"
    else
      printf '\r%s\n' "${frame[$i]}"
    fi
  done
  PANEL_NOTE=""
}

panel_step() {
  local dir=$1 n=${#ROWS[@]} next=$PANEL_CURSOR
  while true; do
    next=$(((next + dir + n) % n))
    if [[ ${ROW_TOOL[$next]} -ne -1 ]]; then
      PANEL_CURSOR=$next
      return 0
    fi
  done
}

panel_keep_visible() {
  if [[ $PANEL_CURSOR -lt $PANEL_TOP ]]; then
    PANEL_TOP=$PANEL_CURSOR
  elif [[ $PANEL_CURSOR -gt $((PANEL_TOP + PANEL_VIEW - 1)) ]]; then
    PANEL_TOP=$((PANEL_CURSOR - PANEL_VIEW + 1))
  fi
  if [[ $PANEL_TOP -gt $(( ${#ROWS[@]} - PANEL_VIEW )) ]]; then
    PANEL_TOP=$((${#ROWS[@]} - PANEL_VIEW))
  fi
  if [[ $PANEL_TOP -lt 0 ]]; then
    PANEL_TOP=0
  fi
}

panel() {
  local key="" rest="" ti=-1
  panel_init
  printf '\033[?25l'
  trap 'printf "\033[?25h" >&2; exit 130' INT TERM
  while true; do
    panel_keep_visible
    panel_draw
    key=""
    rest=""
    IFS= read -rsn1 key || key=""
    if [[ $key == $'\033' ]]; then
      IFS= read -rsn2 -t 0.1 rest || rest=""
      key="${key}${rest}"
    fi
    case $key in
      $'\033[A' | k)
        PANEL_DIGITS=""
        panel_step -1
        ;;
      $'\033[B' | j)
        PANEL_DIGITS=""
        panel_step 1
        ;;
      q)
        panel_erase
        trap - INT TERM
        return 0
        ;;
      '' | $'\n' | $'\r')
        if [[ -n $PANEL_DIGITS ]]; then
          ti=$(tool_index_for_num "$((10#$PANEL_DIGITS))")
          if [[ $ti -eq -1 ]]; then
            PANEL_NOTE="No job ${PANEL_DIGITS} -- pick a number from 1 to 6"
            PANEL_DIGITS=""
          else
            panel_erase
            trap - INT TERM
            dispatch "$ti"
          fi
        else
          panel_erase
          trap - INT TERM
          dispatch "${ROW_TOOL[$PANEL_CURSOR]}"
        fi
        ;;
      $'\177' | $'\010')
        PANEL_DIGITS=${PANEL_DIGITS%?}
        ;;
      [0-9])
        if [[ ${#PANEL_DIGITS} -lt 2 ]]; then
          PANEL_DIGITS="${PANEL_DIGITS}${key}"
        fi
        ;;
    esac
  done
}
# --- Interactive panel (end) -----------------------------------------

main() {
  if [[ $# -eq 1 && ( $1 == "--help" || $1 == "-h" ) ]]; then
    usage
    return 0
  fi
  if [[ $# -gt 0 && $1 == "--" ]]; then
    shift
  fi
  FORWARD_ARGS=("$@")
  build_rows
  if [[ -t 0 && -t 1 && ${TERM:-} != "dumb" ]]; then
    panel
  else
    text_menu
  fi
}

main "$@"
