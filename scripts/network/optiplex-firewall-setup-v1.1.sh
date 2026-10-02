#!/bin/bash

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# Optiplex Firewall Setup — UFW Installation + LAN Rules (v1.1)
# Target: 192.168.0.0/24 on ports 22, 8080, 9090
# ────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/optiplex-firewall-setup.log"
SUBNET="192.168.0.0/24"

# ────────────────────────────────────────────────────────────────────────────
# Logging
# ────────────────────────────────────────────────────────────────────────────

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $*" | tee -a "$LOG_FILE" >&2
    exit 1
}

# ────────────────────────────────────────────────────────────────────────────
# Validation
# ────────────────────────────────────────────────────────────────────────────

log "Starting Optiplex firewall setup..."

[[ $EUID -eq 0 ]] || error "Must run as root"

# ────────────────────────────────────────────────────────────────────────────
# UFW Installation
# ────────────────────────────────────────────────────────────────────────────

if ! command -v ufw &>/dev/null; then
    log "UFW not found. Installing..."
    apt-get update > /tmp/apt-update.log 2>&1 || error "apt update failed"
    apt-get install -y ufw > /tmp/apt-install-ufw.log 2>&1 || error "UFW installation failed"
    log "UFW installed successfully"
else
    log "UFW already installed"
fi

# ────────────────────────────────────────────────────────────────────────────
# Enable UFW (idempotent)
# ────────────────────────────────────────────────────────────────────────────

if ufw status | grep -q "Status: inactive"; then
    log "Enabling UFW..."
    echo "y" | ufw enable > /tmp/ufw-enable.log 2>&1 || error "Failed to enable UFW"
    log "UFW enabled"
else
    log "UFW already enabled"
fi

# ────────────────────────────────────────────────────────────────────────────
# Add Firewall Rules (Native Idempotency)
# ────────────────────────────────────────────────────────────────────────────

declare -a RULES=(
    "allow from $SUBNET to any port 22 proto tcp"
    "allow from $SUBNET to any port 8080 proto tcp"
    "allow from $SUBNET to any port 9090 proto tcp"
)

for rule in "${RULES[@]}"; do
    port=${rule##*port }
    port=${port%% *}

    log "Applying rule: $rule"
    # shellcheck disable=SC2086 # $rule intentionally word-splits into ufw arguments (e.g. "allow from 192.168.0.0/24 to any port 9090")
    ufw $rule > /tmp/ufw-rule-"$port".log 2>&1 || error "Failed to add rule: $rule"
    log "Rule verified: $rule"
done

# ────────────────────────────────────────────────────────────────────────────
# Verification
# ────────────────────────────────────────────────────────────────────────────

log "Current UFW status:"
ufw status numbered | tee -a "$LOG_FILE"

log ""
log "════════════════════════════════════════════════════════════════"
log "Setup Complete!"
log "════════════════════════════════════════════════════════════════"
log "Subnet:       $SUBNET"
log "Ports:        22 (SSH), 8080 (llama-server), 9090 (Cockpit)"
log "Log file:     $LOG_FILE"
log ""
