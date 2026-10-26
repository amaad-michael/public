#!/usr/bin/env bash
# Version: 1.0 (2026-10-22)
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

main() {
  if [[ $# -lt 1 ]]; then
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
