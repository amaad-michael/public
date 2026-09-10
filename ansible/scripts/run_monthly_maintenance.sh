#!/bin/bash
# Monthly maintenance wrapper
# Logs append to ~/git/ansible/logs/maintenance.log

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="$HOME/git/ansible/hosts"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/maintenance.log"

# ── Logging ──────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# ── Trap: catch failures and log before exit ──────────────────────────────────
on_error() {
    log "ERROR: Script failed at line $1 — aborting."
    unset SSHPASS
    exit 1
}
trap 'on_error $LINENO' ERR

# ── Session header ────────────────────────────────────────────────────────────
{
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Maintenance Run: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════"
} | tee -a "$LOG_FILE"

# ── Pre-flight ────────────────────────────────────────────────────────────────
if [[ ! -f "$INVENTORY" ]]; then
    log "ERROR: Inventory not found at $INVENTORY"
    exit 1
fi

# ── Password ──────────────────────────────────────────────────────────────────
read -r -s -p "Enter SSH password: " SSHPASS
echo ""
export SSHPASS

# ── Helper: run a playbook and log outcome ────────────────────────────────────
run_playbook() {
    local label="$1"
    local playbook="$2"
    local limit="$3"

    log "START: $label"
    sshpass -e ansible-playbook "$playbook" -i "$INVENTORY" --limit "$limit" -k 2>&1 | tee -a "$LOG_FILE"
    log "DONE:  $label"
}

# ── Execution sequence ────────────────────────────────────────────────────────
run_playbook "Monthly Maintenance" \
    "playbooks/maintenance/MM/monthly_maint.yml" \
    "pi_all"

run_playbook "Pi-hole Maintenance" \
    "playbooks/maintenance/MM/monthly_maint_pihole.yml" \
    "pi4"

run_playbook "Simple Reboot" \
    "playbooks/maintenance/reboots/reboot_simple.yml" \
    "pi0,pi2,pi3,pi4"

# ── Cleanup ───────────────────────────────────────────────────────────────────
unset SSHPASS
log "All maintenance tasks completed successfully."
