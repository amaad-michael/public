#!/usr/bin/env bash
# ---
# Safer Log Cleanup Script (no backups)
#
# WARNING: This script is DESTRUCTIVE and will permanently remove logs.
# It intentionally omits any backup step. Use --dry-run to preview actions.
#
# Usage:
#   sudo ./cleanup_no_backup.sh [--dry-run] [--yes]
# ---

set -euo pipefail

DRY_RUN=false
AUTO_YES=false

# Adjust to your environment
SERVICES=(pihole-FTL rsyslog systemd-journald unbound)
SHRED_FILES=(
  "/var/log/pihole/pihole.log"
  "/var/log/pihole/FTL.log"
  "/var/log/unbound.log"
)
TRUNCATE_FILES=(
  "/var/log/auth.log"
  "/var/log/syslog"
  "/var/log/ufw.log"
)
# Format: path:owner:group:mode
RECREATE_FILES=(
  "/var/log/pihole/pihole.log:pihole:pihole:0644"
  "/var/log/pihole/FTL.log:pihole:pihole:0644"
)
SHRED_PASSES=3

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "ERROR: $*" >&2; }
confirm() {
  if $AUTO_YES; then return 0; fi
  printf "Proceed with destructive cleanup? This cannot be undone. [y/N]: "
  read -r ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--yes]
  --dry-run   Show actions without performing destructive operations
  --yes       Skip interactive confirmation
EOF
  exit 2
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes) AUTO_YES=true; shift ;;
    -h|--help) usage ;;
    *) err "Unknown arg: $1"; usage ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root."
  exit 1
fi

log "Dry-run: ${DRY_RUN}"
log "Services targeted: ${SERVICES[*]}"
log "Files to shred: ${SHRED_FILES[*]}"
log "Files to truncate: ${TRUNCATE_FILES[*]}"

if ! confirm; then
  log "Aborting on user request."
  exit 0
fi

# Helpers
stop_service_if_exists() {
  local svc="$1"
  if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -q "^${svc}.service$"; then
    log "Stopping ${svc}.service"
    if $DRY_RUN; then log "[DRY-RUN] systemctl stop ${svc}.service"; else systemctl stop "${svc}.service" || log "Warning: failed to stop ${svc}.service"; fi
  else
    log "Service ${svc}.service not present, skipping"
  fi
}
start_service_if_exists() {
  local svc="$1"
  if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -q "^${svc}.service$"; then
    log "Starting ${svc}.service"
    if $DRY_RUN; then log "[DRY-RUN] systemctl start ${svc}.service"; else systemctl start "${svc}.service" || log "Warning: failed to start ${svc}.service"; fi
  else
    log "Service ${svc}.service not present, skipping"
  fi
}

# Stop services
for svc in "${SERVICES[@]}"; do stop_service_if_exists "$svc"; done

# Manage systemd journal
log "Rotating systemd journal"
if $DRY_RUN; then log "[DRY-RUN] journalctl --rotate"; else journalctl --rotate || log "journalctl --rotate returned non-zero"; fi

log "Vacuuming journal to minimal retention (1s)"
if $DRY_RUN; then log "[DRY-RUN] journalctl --vacuum-time=1s"; else journalctl --vacuum-time=1s || log "journalctl --vacuum-time returned non-zero"; fi

# Remove persistent journal files if present (only when not dry-run)
if [ -d /var/log/journal ]; then
  if $DRY_RUN; then log "[DRY-RUN] Would rm -rf /var/log/journal/*"; else
    log "Removing persistent journal files under /var/log/journal (irreversible)"
    rm -rf /var/log/journal/* || log "Warning: rm -rf /var/log/journal/* failed or partially failed"
  fi
fi

# Shred specified files if they exist
shred_if_exists() {
  local f
  for f in "$@"; do
    if [ -e "$f" ]; then
      log "Shredding ${f} with ${SHRED_PASSES} passes"
      if $DRY_RUN; then log "[DRY-RUN] shred -n ${SHRED_PASSES} -z -u -- '${f}'"; else shred -n "${SHRED_PASSES}" -z -u -- "$f" || log "Warning: shred failed for ${f}"; fi
    else
      log "Skipping shred, not found: ${f}"
    fi
  done
}
shred_if_exists "${SHRED_FILES[@]}"

# Truncate files safely
truncate_if_exists() {
  local f
  for f in "$@"; do
    if [ -e "$f" ]; then
      log "Truncating ${f}"
      if $DRY_RUN; then log "[DRY-RUN] : > ${f}"; else : > "$f" || log "Warning: failed to truncate ${f}"; fi
    else
      log "Skipping truncate, not found: ${f}"
    fi
  done
}
truncate_if_exists "${TRUNCATE_FILES[@]}"

# Recreate files and set ownership/permissions
for entry in "${RECREATE_FILES[@]}"; do
  IFS=':' read -r path owner group mode <<< "$entry"
  if $DRY_RUN; then
    log "[DRY-RUN] mkdir -p $(dirname "$path")"
    log "[DRY-RUN] touch ${path}"
    log "[DRY-RUN] chown ${owner}:${group} ${path}"
    log "[DRY-RUN] chmod ${mode} ${path}"
  else
    mkdir -p "$(dirname "$path")"
    touch "$path"
    chown "${owner}:${group}" "$path" || log "Warning: chown ${owner}:${group} failed for ${path}"
    chmod "${mode}" "$path" || log "Warning: chmod ${mode} failed for ${path}"
  fi
done

# Clear root shell history
if $DRY_RUN; then
  log "[DRY-RUN] history -c; : > /root/.bash_history"
else
  if [ -f /root/.bash_history ]; then
    log "Clearing /root/.bash_history"
    history -c || true
    : > /root/.bash_history || log "Warning: could not truncate /root/.bash_history"
  else
    log "/root/.bash_history not present, skipping"
  fi
fi

# Restart services
for svc in "${SERVICES[@]}"; do start_service_if_exists "$svc"; done

# Verification
log ""
log "Verification:"
if $DRY_RUN; then
  log "[DRY-RUN] Would check systemctl is-active for services and journalctl --disk-usage"
else
  for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -q "^${svc}.service$"; then
      status=$(systemctl is-active "${svc}.service" || true)
      log " - ${svc}.service is-active: ${status}"
    fi
  done
  log " - journal disk usage:"
  journalctl --disk-usage || true
fi

log ""
log "Cleanup finished. No backups were created. This operation is irreversible."
