#!/usr/bin/env bash
#
# launcher.sh — a menu front end for the Linux Admin Toolkit.
#
# Presents the toolkit's 27 tools as one grouped list (audit, manage,
# report) with each tool's number, name, and one-line purpose, and
# dispatches to the chosen tool. On a terminal the list is an
# arrow-key panel; off a terminal (or with TERM=dumb) the same list
# is printed as a numbered text menu and the choice is read as a
# line, so the launcher stays usable in pipes and scripts.
#
# Arguments given to the launcher are forwarded to the chosen tool
# unchanged; with no launcher arguments, the operator is prompted
# for the tool's arguments after choosing. The launcher adds no
# confirmation semantics of its own: each tool keeps its own flags,
# prompts, and exit codes, and the launcher exits with the tool's
# exit status. The tools themselves are not modified.
#
# Usage: launcher.sh [--] [args forwarded to the chosen tool]
#        launcher.sh --help
#
# Toolkit v1.2 (2026-10-31).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# --- Tool table ------------------------------------------------------
# One entry per tool, in the toolkit's numbering. NUM is the number
# shown on the row (and the number typed to jump to it); DIR and
# FILE locate the tool's local script relative to this folder;
# GROUP is audit, manage, or report; PURPOSE is the tool's one-line
# purpose from its own header. Keep this table in step with the
# toolkit's numbering (the README task index is the cross-check).
TOOL_NUM=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27)
TOOL_NAME=(user-add sudo-manage password-policy user-audit system-update \
  update-report disk-audit health-check failed-services uptime-report \
  log-errors logrotate-check ssh-audit firewall-audit ports-audit \
  login-audit perm-audit backup-run backup-verify service-manage \
  cron-inventory time-sync cert-expiry net-inventory container-hygiene \
  kernel-cleanup cockpit-install)
TOOL_GROUP=(manage manage manage audit manage report audit report report \
  report report audit audit audit audit audit audit manage audit manage \
  report manage audit report manage manage manage)
TOOL_PURPOSE=(
  "Create or remove a user; SSH key and optional sudo"
  "Grant or revoke sudo via a /etc/sudoers.d drop-in"
  "Enforce password aging and a password-quality baseline"
  "Dormant users, empty passwords, duplicate UID 0 (read-only)"
  "Apply OS package updates, full or security-only"
  "List pending updates; flag reboot-required (read-only)"
  "Filesystems, inodes, largest dirs and files (read-only)"
  "CPU, memory and load vs cores, warn/crit thresholds (read-only)"
  "List failed systemd units (read-only)"
  "Uptime, boot time and reboot history (read-only)"
  "Errors and warnings logged since yesterday (read-only)"
  "Verify logrotate configs parse and key logs are covered (read-only)"
  "Audit sshd config against a hardening baseline (read-only)"
  "Detect the firewall stack and summarize its rules (read-only)"
  "Listening TCP/UDP ports, flag all-interface listeners (read-only)"
  "Failed logins per IP and user; brute-force flags (read-only)"
  "World-writable files, SUID/SGID outside standard paths (read-only)"
  "rsync a directory into a timestamped backup, prune old"
  "Verify the latest backup exists and is intact (read-only)"
  "Enable, start, restart or status a systemd service"
  "Every crontab, /etc/cron.d and cron.* dirs (read-only)"
  "Report time-sync health; optionally fix it"
  "Scan for TLS certs expiring within N days (read-only)"
  "Interfaces, IPs, routes and DNS resolvers (read-only)"
  "Report container clutter; prune with --yes"
  "Remove old kernels; keep N newest, never the running one"
  "Install Cockpit, enable cockpit.socket, open 9090/tcp"
)

usage() {
  cat <<'EOF'
Usage: launcher.sh [--] [args forwarded to the chosen tool]
       launcher.sh --help

A menu front end for the Linux Admin Toolkit. On a terminal it
opens an arrow-key panel listing the 27 tools grouped audit /
manage / report; off a terminal (or with TERM=dumb) it prints the
same list as a numbered text menu and reads the choice as a line.

Panel keys: arrows or j/k move, Enter runs the highlighted tool,
typing a tool number and Enter jumps straight to it, q quits.

After a tool is chosen, any arguments given to the launcher are
forwarded to the tool unchanged; with no launcher arguments, you
are prompted for the tool's arguments (blank for none; the line
is split on whitespace, quoting is not honored). The launcher is
one-shot: it runs the chosen tool in the foreground and exits
with the tool's exit status. The tools themselves are unchanged.
EOF
}

# --- Display rows ----------------------------------------------------
# ROWS holds the printable lines (group headers and tool rows) in
# group order audit, manage, report, numbers ascending inside each
# group. ROW_TOOL maps a display row to a tool-table index, or -1
# for a group header. Both front ends render these same rows, so
# the panel and the printed list can never drift apart.
ROWS=()
ROW_TOOL=()

build_rows() {
  local group ti row
  ROWS=()
  ROW_TOOL=()
  for group in audit manage report; do
    ROWS+=("${group^^}")
    ROW_TOOL+=(-1)
    for ti in "${!TOOL_NUM[@]}"; do
      if [[ ${TOOL_GROUP[$ti]} == "$group" ]]; then
        printf -v row '%s  %-18s %s' "${TOOL_NUM[$ti]}" "${TOOL_NAME[$ti]}" "${TOOL_PURPOSE[$ti]}"
        if [[ ! -x $(tool_path "$ti") ]]; then
          row="${row} [missing]"
        fi
        ROWS+=("$row")
        ROW_TOOL+=("$ti")
      fi
    done
  done
}

tool_path() {
  local ti=$1
  printf '%s/%s-%s/%s-local.sh' "$SCRIPT_DIR" "${TOOL_NUM[$ti]}" "${TOOL_NAME[$ti]}" "${TOOL_NAME[$ti]}"
}

# --- Dispatch --------------------------------------------------------
# Runs tool-table entry $1 in the foreground and exits with its
# status. Arguments: the launcher's own arguments if any were
# given, otherwise a line read from the operator (blank = none).
FORWARD_ARGS=()

dispatch() {
  local ti=$1 path line rc=0
  local -a args=()
  path=$(tool_path "$ti")
  if [[ ! -x $path ]]; then
    printf 'launcher: tool script missing or not executable: %s\n' "$path" >&2
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
  printf 'launcher: running %s-%s/%s-local.sh' "${TOOL_NUM[$ti]}" "${TOOL_NAME[$ti]}" "${TOOL_NAME[$ti]}" >&2
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
  printf 'Linux Admin Toolkit -- 27 tools (toolkit v1.2)\n'
  printf 'Type a tool number and press Enter; blank or q quits.\n\n'
  for row in "${ROWS[@]}"; do
    printf '%s\n' "$row"
  done
  choice=""
  IFS= read -r -p 'Tool number: ' choice || choice=""
  choice="${choice//[[:space:]]/}"
  case $choice in
    '' | q | Q)
      return 0
      ;;
  esac
  if [[ ! $choice =~ ^[0-9]+$ ]] || [[ $((10#$choice)) -lt 1 ]] || [[ $((10#$choice)) -gt 27 ]]; then
    printf "launcher: '%s' is not a tool number (1-27)\n" "$choice" >&2
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
# 130. The 30 display rows scroll through a fixed-height viewport,
# so the frame is the same height on every redraw and is redrawn
# in place. Group headers are not selectable; movement skips them
# and wraps at both ends. Typing digits starts a jump buffer shown
# in the footer; Enter with a buffer pending runs that tool number
# instead of the highlighted row.
PANEL_VIEW=12
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
  for line in "${ROWS[@]}" "Linux Admin Toolkit -- 27 tools" \
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
  printf -v line '| %-*s |' "$PANEL_WIDTH" "Linux Admin Toolkit -- 27 tools"
  frame+=("$line")
  frame+=("$border")
  for ((i = 0; i < PANEL_VIEW; i++)); do
    ri=$((PANEL_TOP + i))
    printf -v line '| %-*s |' "$PANEL_WIDTH" "${ROWS[$ri]}"
    frame+=("$line")
  done
  frame+=("$border")
  if [[ -n $PANEL_DIGITS ]]; then
    footer="tool: ${PANEL_DIGITS}_  (enter runs it, backspace edits)"
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
            PANEL_NOTE="No tool ${PANEL_DIGITS} -- pick a number from 1 to 27"
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
