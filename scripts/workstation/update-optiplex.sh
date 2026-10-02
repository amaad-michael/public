#!/bin/bash
# update-optiplex.sh
# FINAL: Robust path resolution, build safety, service verification
# Target: Linux Mint (Debian-based)

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/optiplex-update.log"
DRY_RUN="${DRY_RUN:-false}"

# Path Resolution (Matches original setup exactly)
# Uses getent to find the REAL user home, with fallback to /root
REAL_USER_HOME="${SUDO_USER:-root}"
if [[ -n "$REAL_USER_HOME" ]]; then
    REAL_USER_HOME=$(getent passwd "$REAL_USER_HOME" 2>/dev/null | cut -d: -f6)
    if [[ -z "$REAL_USER_HOME" ]]; then
        REAL_USER_HOME="/root"
    fi
else
    REAL_USER_HOME="/root"
fi

PROJECTS_DIR="${PROJECTS_DIR:-${REAL_USER_HOME}/projects}"
MODELS_DIR="${MODELS_DIR:-${REAL_USER_HOME}/models}"
LLAMA_DIR="$PROJECTS_DIR/llama.cpp"
MODEL_FILE="$MODELS_DIR/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
SERVICE_NAME="llama-server"
THREADS="${THREADS:-4}"

# Safety Check
if [[ "$LLAMA_DIR" == "/" ]]; then
    error "CRITICAL: LLAMA_DIR resolved to root (/). Aborting to prevent data loss."
fi

# ────────────────────────────────────────────────────────────────────────────
# UTILITIES
# ────────────────────────────────────────────────────────────────────────────

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

warn() { log "⚠ WARNING: $*"; }
error() { log "❌ ERROR: $*"; exit 1; }

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would execute: $*"
    else
        log "Executing: $*"
        "$@" || error "Command failed: $*"
    fi
}

wait_for_service() {
    local svc=$1
    local max_attempts=10
    local attempt=1

    log "Waiting for $svc to be active..."
    while [[ $attempt -le $max_attempts ]]; do
        if systemctl is-active --quiet "$svc"; then
            log "✓ $svc is active."
            return 0
        fi
        log "$svc not active yet (attempt $attempt/$max_attempts)..."
        sleep 2
        ((attempt++))
    done
    error "Timeout: $svc did not become active."
}

# ────────────────────────────────────────────────────────────────────────────
# MAIN LOGIC
# ────────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Starting Optiplex Update (Safe Build Mode)"
log "Mode: $([ "$DRY_RUN" == "true" ] && echo 'DRY-RUN' || echo 'APPLY')"
log "User Home: $REAL_USER_HOME"
log "Llama Dir: $LLAMA_DIR"
log "════════════════════════════════════════════════════════════════"

# 1. OS Updates
log ""
log ">>> Step 1: Updating OS (APT)..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] apt update && apt upgrade -y"
else
    run_cmd apt-get update -qq
    run_cmd apt-get upgrade -y || warn "OS update failed."
fi

# 2. llama.cpp Update (Source)
log ""
log ">>> Step 2: Updating llama.cpp (Source)..."

if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    error "llama.cpp directory not found at $LLAMA_DIR. Aborting."
fi

cd "$LLAMA_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] git pull origin main"
    log "[DRY-RUN] rm -rf build && cmake ... && make"
else
    log "Pulling latest source..."
    run_cmd git pull origin main

    # CRITICAL: Clean build directory to prevent partial build corruption
    log "Cleaning old build artifacts..."
    run_cmd rm -rf build

    log "Configuring CMake (AVX2 only, NATIVE disabled for safety)..."
    run_cmd cmake -B build \
        -DLLAMA_NATIVE=OFF \
        -DLLAMA_AVX2=ON \
        -DCMAKE_BUILD_TYPE=Release

    log "Building..."
    NPROC=$(nproc)
    run_cmd cmake --build build --config Release -j"$NPROC"

    # Permissions
    run_cmd chmod 755 build/bin/llama-cli build/bin/llama-server

    log "Restarting service..."
    run_cmd systemctl restart "$SERVICE_NAME"

    # Wait for service to be truly active
    wait_for_service "$SERVICE_NAME"
fi

# 3. Model Check
log ""
log ">>> Step 3: Model Status..."
log "Current: $MODEL_FILE"
log "Action: Manual update required. Download new .gguf and update service file."

# 4. Verification
log ""
log ">>> Step 4: Verifying Service..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Verification skipped."
else
    sleep 2
    if ss -tulpn | grep -qE "LISTEN.*:8080"; then
        log "✓ Port 8080 listening."
    else
        warn "⚠ Port 8080 NOT listening."
    fi

    if curl -s -X POST "http://127.0.0.1:8080/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model":"test","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' \
        > /dev/null 2>&1; then
        log "✓ API Responding."
    else
        warn "⚠ API Not Responding."
    fi
fi

log "════════════════════════════════════════════════════════════════"
log "Update Complete. Log: $LOG_FILE"
log "════════════════════════════════════════════════════════════════"
