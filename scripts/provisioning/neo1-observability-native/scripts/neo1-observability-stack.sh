#!/usr/bin/env bash
# Version: 1.1 (2026-10-31)
# neo1-observability-stack.sh - bring the neo1 native observability stack up or down
#
# Controls the bare-metal systemd units installed by the neo1 observability
# kit (v2.6.1, native form). Runtime state only: this script starts and stops
# units, it never enables or disables them, so boot behaviour stays exactly
# as the kit installer left it.
#
# Core stack (enabled at install, normally always on):
#   ntfy               :8081  alert push server (Alertmanager sends here)
#   node_exporter      :9100  neo1 host metrics
#   blackbox_exporter  :9115  probe exporter (loopback)
#   alertmanager       :9093  alert routing (loopback)
#   prometheus         :9091  metrics core
#
# On-demand member:
#   grafana            :3002  dashboard sessions only; the kit leaves it
#                             stopped. "up" starts it only with
#                             --with-grafana; "down" always stops it if it
#                             is running.
#
# Out of scope on purpose: the pihole-backup and unbound-backup services and
# timers (the DNS spare pair's backup path, a separate decision), and the
# Docker warm-spare Pi-hole/Unbound pair.
#
# Usage:
#   neo1-observability-stack.sh up [--with-grafana] [--dry-run]
#   neo1-observability-stack.sh down [--dry-run]
#   neo1-observability-stack.sh restart [--with-grafana] [--dry-run]
#   neo1-observability-stack.sh status
#   neo1-observability-stack.sh          (no arguments, on a terminal:
#                                          the interactive panel below)
#
# Exit codes: 0 = stack in the requested state, 1 = a unit did not reach it
# (or status found a core unit down), 2 = usage error.

set -euo pipefail

CORE_UP_ORDER=(ntfy node_exporter blackbox_exporter alertmanager prometheus)
CORE_DOWN_ORDER=(prometheus alertmanager blackbox_exporter node_exporter ntfy)
GRAFANA_UNIT=grafana

declare -A PORTS=(
  [ntfy]=8081
  [node_exporter]=9100
  [blackbox_exporter]=9115
  [alertmanager]=9093
  [prometheus]=9091
  [grafana]=3002
)

SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

DRY_RUN=0
WITH_GRAFANA=0

usage() {
  cat <<'EOF'
Usage:
  neo1-observability-stack.sh up [--with-grafana] [--dry-run]
  neo1-observability-stack.sh down [--dry-run]
  neo1-observability-stack.sh restart [--with-grafana] [--dry-run]
  neo1-observability-stack.sh status

  up       Start the core stack (ntfy, node_exporter, blackbox_exporter,
           alertmanager, prometheus). Grafana stays down unless
           --with-grafana is given.
  down     Stop Grafana (if running) and the whole core stack.
  restart  down, then up.
  status   Show each unit's state; exit 1 if any core unit is not active.
  --dry-run  Print the systemctl commands without running them.
EOF
}

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

unit_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

start_unit() {
  local unit=$1
  if unit_active "$unit"; then
    printf '%-18s already active\n' "$unit"
    return 0
  fi
  printf '%-18s starting (port %s)\n' "$unit" "${PORTS[$unit]}"
  # $SUDO is intentionally unquoted: it is empty (root) or the single word sudo.
  # shellcheck disable=SC2086
  if ! run $SUDO systemctl start "$unit"; then
    printf '%-18s start command FAILED\n' "$unit"
    return 1
  fi
}

stop_unit() {
  local unit=$1
  if ! unit_active "$unit"; then
    printf '%-18s already stopped\n' "$unit"
    return 0
  fi
  printf '%-18s stopping\n' "$unit"
  # $SUDO is intentionally unquoted: it is empty (root) or the single word sudo.
  # shellcheck disable=SC2086
  if ! run $SUDO systemctl stop "$unit"; then
    printf '%-18s stop command FAILED\n' "$unit"
    return 1
  fi
}

verify_units() {
  local want=$1
  shift
  local unit state failed=0
  for unit in "$@"; do
    if unit_active "$unit"; then
      state=active
    else
      state=inactive
    fi
    if [[ $state != "$want" ]]; then
      printf '%-18s FAILED: expected %s, is %s\n' "$unit" "$want" "$state"
      failed=1
    fi
  done
  return $failed
}

do_up() {
  local unit failures=0
  for unit in "${CORE_UP_ORDER[@]}"; do
    start_unit "$unit" || failures=$((failures + 1))
  done
  if [[ $WITH_GRAFANA -eq 1 ]]; then
    start_unit "$GRAFANA_UNIT" || failures=$((failures + 1))
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  echo "Verifying:"
  if ! verify_units active "${CORE_UP_ORDER[@]}"; then
    failures=$((failures + 1))
  fi
  if [[ $WITH_GRAFANA -eq 1 ]] && ! unit_active "$GRAFANA_UNIT"; then
    echo "Grafana did not start." >&2
    failures=$((failures + 1))
  fi
  if [[ $failures -gt 0 ]]; then
    echo "Stack did not come up cleanly." >&2
    return 1
  fi
  echo "Observability stack is up."
}

do_down() {
  local unit failures=0
  stop_unit "$GRAFANA_UNIT" || failures=$((failures + 1))
  for unit in "${CORE_DOWN_ORDER[@]}"; do
    stop_unit "$unit" || failures=$((failures + 1))
  done
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  echo "Verifying:"
  if ! verify_units inactive "$GRAFANA_UNIT" "${CORE_DOWN_ORDER[@]}"; then
    failures=$((failures + 1))
  fi
  if [[ $failures -gt 0 ]]; then
    echo "Stack did not go down cleanly." >&2
    return 1
  fi
  echo "Observability stack is down."
}

do_status() {
  local unit state failed=0
  printf '%-18s %-10s %s\n' "UNIT" "STATE" "PORT"
  for unit in "${CORE_UP_ORDER[@]}" "$GRAFANA_UNIT"; do
    if unit_active "$unit"; then
      state=active
    else
      state=inactive
      if [[ $unit != "$GRAFANA_UNIT" ]]; then
        failed=1
      fi
    fi
    printf '%-18s %-10s %s\n' "$unit" "$state" "${PORTS[$unit]}"
  done
  if [[ $failed -eq 1 ]]; then
    echo "One or more core units are down."
    return 1
  fi
  echo "Core stack is fully active (Grafana is on-demand)."
}

# --- Interactive panel (begin) ---------------------------------------
# With no arguments on a terminal, the script opens a panel instead
# of printing usage: the live status table on top (the status
# subcommand's own output, captured verbatim) and an action menu
# below it. The panel is an added entry path only. Any argument,
# no terminal, or TERM=dumb takes the exact paths the script has
# always taken, byte for byte, and the status subcommand's exit
# code contract is untouched. Pure bash and ANSI in the new-box
# runner's panel conventions: no external TUI tool, an ASCII
# frame, a reverse-video cursor row, the cursor hidden while the
# panel is drawn and restored on every exit from it, and a trap
# on INT/TERM that restores the cursor and exits 130. The actions
# call the same do_up/do_down functions the subcommands call,
# with the same flag defaults: Up is do_up without Grafana, Up
# with Grafana is do_up with it, Down is do_down, and Restart is
# do_down then do_up (stopping there if the down half fails,
# exactly as the restart subcommand does under set -e). Refresh
# re-reads the status table; after an action its output stays on
# screen until a keypress, then the panel redraws with fresh
# status. Quit (or q) erases the panel and exits 0.

PANEL_ITEMS=("Up" "Up with Grafana" "Down" "Restart" "Refresh" "Quit")
PANEL_ROWS=()
PANEL_CURSOR=0
PANEL_FIRST=1
PANEL_FRAME_LINES=0

panel_status_rows() {
  mapfile -t PANEL_ROWS < <(do_status)
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
  local line="" dashes="" border=""
  local width=44 len i mark=""
  for line in "${PANEL_ROWS[@]}"; do
    len=${#line}
    if [[ $len -gt $width ]]; then
      width=$len
    fi
  done
  printf -v dashes '%*s' $((width + 2)) ''
  dashes="${dashes// /-}"
  border="+${dashes}+"
  frame+=("$border")
  printf -v line '| %-*s |' "$width" "neo1 observability stack"
  frame+=("$line")
  frame+=("$border")
  for line in "${PANEL_ROWS[@]}"; do
    printf -v line '| %-*s |' "$width" "$line"
    frame+=("$line")
  done
  frame+=("$border")
  for i in "${!PANEL_ITEMS[@]}"; do
    mark="  "
    if [[ $i -eq $PANEL_CURSOR ]]; then
      mark="> "
    fi
    printf -v line '| %-*s |' "$width" "${mark}${PANEL_ITEMS[$i]}"
    frame+=("$line")
  done
  frame+=("$border")
  printf -v line '| %-*s |' "$width" "arrows or j/k move, enter selects, q quits"
  frame+=("$line")
  frame+=("$border")
  PANEL_FRAME_LINES=${#frame[@]}
  if [[ $PANEL_FIRST -eq 1 ]]; then
    PANEL_FIRST=0
  else
    printf '\033[%dA' "${#frame[@]}"
  fi
  for i in "${!frame[@]}"; do
    if [[ $i -eq $((PANEL_CURSOR + 4 + ${#PANEL_ROWS[@]})) ]]; then
      printf '\r\033[7m%s\033[0m\n' "${frame[$i]}"
    else
      printf '\r%s\n' "${frame[$i]}"
    fi
  done
}

panel_run_action() {
  local choice=$1 rc=0
  panel_erase
  trap - INT TERM
  WITH_GRAFANA=0
  case $choice in
    0)
      do_up || rc=$?
      ;;
    1)
      WITH_GRAFANA=1
      do_up || rc=$?
      ;;
    2)
      do_down || rc=$?
      ;;
    3)
      do_down || rc=$?
      if [[ $rc -eq 0 ]]; then
        do_up || rc=$?
      fi
      ;;
  esac
  WITH_GRAFANA=0
  if [[ $rc -ne 0 ]]; then
    printf 'Action exited with status %d.\n' "$rc"
  fi
  printf 'Press Enter to return to the panel.'
  IFS= read -rsn1 _ || true
  printf '\n'
}

panel() {
  local key="" rest=""
  PANEL_CURSOR=0
  PANEL_FIRST=1
  panel_status_rows
  printf '\033[?25l'
  trap 'printf "\033[?25h" >&2; exit 130' INT TERM
  while true; do
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
        PANEL_CURSOR=$(((PANEL_CURSOR + 5) % 6))
        ;;
      $'\033[B' | j)
        PANEL_CURSOR=$(((PANEL_CURSOR + 1) % 6))
        ;;
      q)
        break
        ;;
      '' | $'\n' | $'\r')
        if [[ $PANEL_CURSOR -eq 5 ]]; then
          break
        elif [[ $PANEL_CURSOR -eq 4 ]]; then
          panel_status_rows
        else
          panel_run_action "$PANEL_CURSOR"
          panel_status_rows
          PANEL_FIRST=1
          printf '\033[?25l'
          trap 'printf "\033[?25h" >&2; exit 130' INT TERM
        fi
        ;;
    esac
  done
  panel_erase
  trap - INT TERM
  return 0
}
# --- Interactive panel (end) -----------------------------------------

main() {
  if [[ $# -lt 1 ]]; then
    if [[ -t 0 && -t 1 && ${TERM:-} != "dumb" ]]; then
      panel
      return
    fi
    usage >&2
    return 2
  fi
  local cmd=$1
  shift
  local arg
  for arg in "$@"; do
    case $arg in
      --with-grafana) WITH_GRAFANA=1 ;;
      --dry-run) DRY_RUN=1 ;;
      *)
        echo "Unknown option: $arg" >&2
        usage >&2
        return 2
        ;;
    esac
  done
  case $cmd in
    up) do_up ;;
    down) do_down ;;
    restart)
      do_down
      do_up
      ;;
    status)
      if [[ $DRY_RUN -eq 1 || $WITH_GRAFANA -eq 1 ]]; then
        echo "status takes no options." >&2
        usage >&2
        return 2
      fi
      do_status
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
