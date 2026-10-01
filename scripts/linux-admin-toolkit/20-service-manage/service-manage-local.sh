#!/usr/bin/env bash
# Manage a systemd service consistently across RHEL- and Debian-family hosts.
# Idempotent: states that already match the request are reported, not re-applied.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: service-manage-local.sh SERVICE [--action ACTION] [--now] [--check] [--help]

  Manage a systemd service and verify the desired end state.

  SERVICE               Unit name, e.g. sshd (".service" is appended when no
                        suffix is given).
  --action ACTION       start | stop | restart | reload | enable | disable |
                        status   (default: status)
  --now                 With --action enable: also start the service now.
                        With --action disable: also stop it now.
  --check               Dry-run: describe what would change, change nothing.
  --help                Show this help.

  Every mutating action verifies its end state afterwards (e.g. after
  --action restart the unit must be active). Requires systemd as PID 1.

  Exit codes: 0 ok, 1 action failed verification, 2 usage/platform error.

Examples:
  service-manage-local.sh sshd --action status
  service-manage-local.sh nginx --action restart
  service-manage-local.sh cron --action enable --now
  service-manage-local.sh apache2 --action stop --check
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

SERVICE=""
ACTION="status"
NOW=0
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="${2:?--action requires a value}"; shift 2 ;;
    --now)    NOW=1; shift ;;
    --check)  CHECK=1; shift ;;
    --help)   usage; exit 0 ;;
    --*)      warn "unknown option: $1"; usage; exit 2 ;;
    *)        if [[ -n "$SERVICE" ]]; then warn "unexpected argument: $1"; usage; exit 2; fi
              SERVICE="$1"; shift ;;
  esac
done

[[ -n "$SERVICE" ]] || { warn "SERVICE is required"; usage; exit 2; }

case "$ACTION" in
  start|stop|restart|reload|enable|disable|status) ;;
  *) warn "invalid --action: $ACTION (want start|stop|restart|reload|enable|disable|status)"; exit 2 ;;
esac

if [[ "$NOW" -eq 1 && "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
  warn "--now only applies with --action enable|disable"
  exit 2
fi

# --- Platform checks -------------------------------------------------------
if ! command -v systemctl >/dev/null 2>&1; then
  warn "systemctl not found; this host cannot manage systemd services"
  exit 2
fi
if [[ ! -d /run/systemd/system ]]; then
  warn "systemd is not running as PID 1 on this host; refusing to manage services"
  exit 2
fi

DISTRO_ID=""; DISTRO_ID_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-}"; DISTRO_ID_LIKE="${ID_LIKE:-}"
fi
DISTRO="unknown"
case " ${DISTRO_ID} ${DISTRO_ID_LIKE} " in
  *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" alma "*|*" fedora "*|*" ol "*|*" oracle "*)
    DISTRO="rhel" ;;
  *" debian "*|*" ubuntu "*)
    DISTRO="debian" ;;
esac
if [[ "$DISTRO" == "unknown" ]]; then
  warn "unsupported distribution (ID='${DISTRO_ID}' ID_LIKE='${DISTRO_ID_LIKE}'); only RHEL- and Debian-family hosts are supported"
  exit 2
fi

# --- Unit resolution -------------------------------------------------------
UNIT="$SERVICE"
[[ "$UNIT" == *.* ]] || UNIT="$UNIT.service"

LOAD_STATE="$(systemctl show -p LoadState --value "$UNIT" 2>/dev/null || true)"
if [[ "$LOAD_STATE" == "not-found" ]]; then
  warn "unit $UNIT not found"
  exit 2
fi

is_active()  { systemctl is-active --quiet "$UNIT"; }
enabled_state() { systemctl is-enabled "$UNIT" 2>/dev/null || true; }

verify_active() {
  if is_active; then log "verified: $UNIT is active";
  else warn "failed to bring $UNIT to the active state"; exit 1; fi
}
verify_inactive() {
  if is_active; then warn "failed to stop $UNIT; it is still active"; exit 1;
  else log "verified: $UNIT is inactive"; fi
}
verify_enabled() {
  local st; st="$(enabled_state)"
  if [[ "$st" == enabled* ]]; then log "verified: $UNIT is enabled";
  else warn "failed to enable $UNIT (is-enabled reports: ${st:-unknown})"; exit 1; fi
}
verify_disabled() {
  local st; st="$(enabled_state)"
  if [[ "$st" == "disabled" ]]; then log "verified: $UNIT is disabled";
  else warn "failed to disable $UNIT (is-enabled reports: ${st:-unknown})"; exit 1; fi
}

# --- Actions (idempotent; --check only describes) ---------------------------
do_status() {
  # Read-only; always queries live state even with --check.
  printf 'unit:    %s\n' "$UNIT"
  printf 'loaded:  %s\n' "$LOAD_STATE"
  printf 'active:  %s\n' "$(systemctl is-active "$UNIT" 2>/dev/null || true)"
  printf 'enabled: %s\n' "$(enabled_state)"
}

do_start() {
  if is_active; then log "$UNIT is already active; nothing to do"; return 0; fi
  if [[ "$CHECK" -eq 1 ]]; then log "[check] would run: systemctl start $UNIT"; return 0; fi
  systemctl start "$UNIT"
  verify_active
}

do_stop() {
  if ! is_active; then log "$UNIT is already inactive; nothing to do"; return 0; fi
  if [[ "$CHECK" -eq 1 ]]; then log "[check] would run: systemctl stop $UNIT"; return 0; fi
  systemctl stop "$UNIT"
  verify_inactive
}

do_restart() {
  # Desired end state is active; systemctl restart also starts an inactive unit.
  if [[ "$CHECK" -eq 1 ]]; then log "[check] would run: systemctl restart $UNIT"; return 0; fi
  systemctl restart "$UNIT"
  verify_active
}

do_reload() {
  local can_reload
  can_reload="$(systemctl show -p CanReload --value "$UNIT" 2>/dev/null || true)"
  if [[ "$can_reload" != "yes" ]]; then
    warn "$UNIT does not support reload (CanReload=${can_reload:-unknown}); use --action restart instead"
    exit 2
  fi
  if ! is_active; then
    warn "$UNIT is not active; reload requires a running service (use --action restart to start it)"
    exit 2
  fi
  if [[ "$CHECK" -eq 1 ]]; then log "[check] would run: systemctl reload $UNIT"; return 0; fi
  systemctl reload "$UNIT"
  verify_active
}

do_enable() {
  local st; st="$(enabled_state)"
  if [[ "$st" == "static" || "$st" == "indirect" ]]; then
    warn "$UNIT is a static unit and cannot be enabled/disabled"
    exit 2
  fi
  if [[ "$st" == enabled* ]]; then
    log "$UNIT is already enabled; nothing to do"
  elif [[ "$CHECK" -eq 1 ]]; then
    log "[check] would run: systemctl enable $UNIT"
  else
    systemctl enable "$UNIT"
    verify_enabled
  fi
  if [[ "$NOW" -eq 1 ]]; then
    if is_active; then log "$UNIT is already active; nothing to do"
    elif [[ "$CHECK" -eq 1 ]]; then log "[check] would run: systemctl start $UNIT"
    else systemctl start "$UNIT"; verify_active; fi
  fi
}

do_disable() {
  local st; st="$(enabled_state)"
  if [[ "$st" == "static" || "$st" == "indirect" ]]; then
    warn "$UNIT is a static unit and cannot be enabled/disabled"
    exit 2
  fi
  if [[ "$st" == "disabled" ]]; then
    log "$UNIT is already disabled; nothing to do"
  elif [[ "$CHECK" -eq 1 ]]; then
    log "[check] would run: systemctl disable $UNIT"
  else
    systemctl disable "$UNIT"
    verify_disabled
  fi
  if [[ "$NOW" -eq 1 ]]; then
    if ! is_active; then log "$UNIT is already inactive; nothing to do"
    elif [[ "$CHECK" -eq 1 ]]; then log "[check] would run: systemctl stop $UNIT"
    else systemctl stop "$UNIT"; verify_inactive; fi
  fi
}

case "$ACTION" in
  status)  do_status ;;
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_restart ;;
  reload)  do_reload ;;
  enable)  do_enable ;;
  disable) do_disable ;;
esac
