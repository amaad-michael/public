#!/bin/bash

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# GPU Box Firewall Setup — firewalld Rules (Nobara) (v1.1)
# Target: 192.168.0.0/24 on ports 22, 11434, 3000, 9090
# ────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/gpu-box-firewall-setup.log"
SUBNET="192.168.0.0/24"
ZONE="home"

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

log "Starting GPU box (Nobara) firewall setup..."

[[ $EUID -eq 0 ]] || error "Must run as root"

# ────────────────────────────────────────────────────────────────────────────
# firewalld Installation
# ────────────────────────────────────────────────────────────────────────────

if ! command -v firewall-cmd &>/dev/null; then
    log "firewalld not found. Installing..."
    dnf install -y firewalld > /tmp/dnf-install-firewalld.log 2>&1 || error "firewalld installation failed"
    log "firewalld installed successfully"
else
    log "firewalld already installed"
fi

# ────────────────────────────────────────────────────────────────────────────
# Enable and start firewalld (idempotent)
# ────────────────────────────────────────────────────────────────────────────

log "Enabling firewalld service..."
systemctl enable firewalld > /tmp/systemctl-enable-firewalld.log 2>&1 || error "Failed to enable firewalld"

if ! systemctl is-active --quiet firewalld; then
    log "Starting firewalld..."
    systemctl start firewalld > /tmp/systemctl-start-firewalld.log 2>&1 || error "Failed to start firewalld"
    log "firewalld started"
else
    log "firewalld already running"
fi

# ────────────────────────────────────────────────────────────────────────────
# Add source-based rules to 'home' zone (Native Idempotency)
# ────────────────────────────────────────────────────────────────────────────

declare -a PORTS=(22 11434 3000 9090)

log "Applying source $SUBNET to zone $ZONE"
firewall-cmd --zone="$ZONE" --add-source="$SUBNET" --permanent > /tmp/firewall-add-source.log 2>&1 || error "Failed to add source to zone"

for port in "${PORTS[@]}"; do
    log "Applying port $port/tcp to zone $ZONE"
    firewall-cmd --zone="$ZONE" --add-port="$port/tcp" --permanent > /tmp/firewall-add-port-"$port".log 2>&1 || error "Failed to add port $port/tcp"
done

# ────────────────────────────────────────────────────────────────────────────
# Reload firewalld to apply permanent changes
# ────────────────────────────────────────────────────────────────────────────

log "Reloading firewalld to apply rules..."
firewall-cmd --reload > /tmp/firewall-reload.log 2>&1 || error "Failed to reload firewalld"
log "firewalld rules reloaded"

# ────────────────────────────────────────────────────────────────────────────
# Verification
# ────────────────────────────────────────────────────────────────────────────

log "Current firewalld status:"
log ""
log "Zone: $ZONE"
log "Sources:"
firewall-cmd --zone="$ZONE" --list-sources | tee -a "$LOG_FILE"
log ""
log "Ports:"
firewall-cmd --zone="$ZONE" --list-ports | tee -a "$LOG_FILE"
log ""

log "════════════════════════════════════════════════════════════════"
log "Setup Complete!"
log "════════════════════════════════════════════════════════════════"
log "Zone:         $ZONE"
log "Subnet:       $SUBNET"
log "Ports:        22 (SSH), 11434 (Ollama), 3000 (Open WebUI), 9090 (Cockpit)"
log "Log file:     $LOG_FILE"
log ""
