#!/bin/bash
# update-gpu-box.sh
# FINAL: Official nobara-sync, robust error handling, volume checks
# Target: Nobara (Fedora-based)

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/gpu-box-update.log"
DRY_RUN="${DRY_RUN:-false}"

# Nobara Official Sync Options
# --no-reboot: Prevent automatic reboot
# --skip-kernel: Uncomment to exclude kernel updates (safer for GPU drivers)
NOBARA_SYNC_FLAGS="--no-reboot"
# NOBARA_SYNC_FLAGS="--no-reboot --skip-kernel"

# Ports
OLLAMA_PORT="11434"
WEBUI_PORT="8080"
SEARXNG_PORT="8888"

MODELS=(
    "qwen2.5-coder:14b"
    "qwen2.5-coder:7b"
    "deepseek-r1:14b"
    "nomic-embed-text"
    "llava:13b"
)

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

wait_for_port() {
    local port=$1
    local name=$2
    local max_attempts=12
    local attempt=1

    log "Waiting for $name to release port $port..."
    while [[ $attempt -le $max_attempts ]]; do
        if ! ss -tulpn | grep -qE "LISTEN.*:${port}[[:space:]]"; then
            log "✓ Port $port is free."
            return 0
        fi
        log "Port $port still in use (attempt $attempt/$max_attempts)..."
        sleep 2
        ((attempt++))
    done
    error "Timeout: Port $port did not release for $name."
}

ensure_volume() {
    local vol_name=$1
    if ! docker volume inspect "$vol_name" &>/dev/null; then
        log "Creating volume: $vol_name"
        run_cmd docker volume create "$vol_name"
    else
        log "Volume $vol_name exists."
    fi
}

# ────────────────────────────────────────────────────────────────────────────
# MAIN LOGIC
# ────────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Starting GPU Box Update (Nobara Official Method)"
log "Mode: $([ "$DRY_RUN" == "true" ] && echo 'DRY-RUN' || echo 'APPLY')"
log "Reference: https://wiki.nobaraproject.org/general-usage/troubleshooting/update-system"
log "════════════════════════════════════════════════════════════════"

# 1. OS Updates (Nobara Official: nobara-sync)
log ""
log ">>> Step 1: Updating OS with nobara-sync..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] nobara-sync --dry-run --no-reboot"
else
    # Official Nobara sync command.
    # NOTE: run_cmd() exits the script on failure, so it cannot be used here —
    # we need nobara-sync's exit code to decide whether to fall back to dnf.
    # The if/else form is safe under set -e; a bare call would abort before
    # exit_code=$? is reached.
    log "Executing: nobara-sync $NOBARA_SYNC_FLAGS -y"
    if nobara-sync $NOBARA_SYNC_FLAGS -y; then
        log "✓ OS update complete via nobara-sync"
    else
        exit_code=$?
        warn "nobara-sync failed (exit code: $exit_code)."
        warn "Check log: ~/.local/share/nobara-updater/nobara-sync.log"

        # Only fallback to dnf distro-sync if it's a dependency conflict, not network
        if [[ $exit_code -eq 1 ]]; then
            warn "Attempting fallback: dnf distro-sync --refresh"
            run_cmd dnf distro-sync --refresh -y || error "Both nobara-sync and dnf distro-sync failed"
        else
            error "nobara-sync failed with non-conflict error. Aborting."
        fi
    fi
fi

# 2. Repository Keys
log ""
log ">>> Step 2: Updating Repository Keys..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] dnf update -y nobara-repos nobara-gpg-keys fedora-repos"
else
    run_cmd dnf update -y nobara-repos nobara-gpg-keys fedora-repos || warn "Repo key update skipped"
fi

# 3. Ollama Binary
log ""
log ">>> Step 3: Updating Ollama..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] download ollama install.sh, verify sha256 if OLLAMA_INSTALL_SHA256 is set, then run"
else
    _ollama_installer="$(mktemp)"
    run_cmd curl -fsSL -o "$_ollama_installer" https://ollama.com/install.sh
    if [[ -n "${OLLAMA_INSTALL_SHA256:-}" ]]; then
        echo "${OLLAMA_INSTALL_SHA256}  $_ollama_installer" | sha256sum -c - \
            || error "Ollama installer checksum mismatch — refusing to run"
    else
        warn "OLLAMA_INSTALL_SHA256 not set — running ollama.com/install.sh without checksum verification"
    fi
    run_cmd bash "$_ollama_installer"
    rm -f "$_ollama_installer"
    run_cmd systemctl restart ollama
    log "Ollama restarted."
fi

# 4. Docker Updates
log ""
log ">>> Step 4: Pulling Docker Images..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] docker pull searxng/searxng:latest"
    log "[DRY-RUN] docker pull ghcr.io/open-webui/open-webui:v0.5.20"
else
    run_cmd docker pull docker.io/searxng/searxng:latest
    run_cmd docker pull ghcr.io/open-webui/open-webui:v0.5.20
fi

# 5. Container Recreation
log ""
log ">>> Step 5: Recreating Containers..."

LAN_IP=$(ip -4 addr show | awk '/inet / && !/127\.0\.0\.1/ && !/172\./ {print $2}' | cut -d/ -f1 | head -1)
[[ -z "$LAN_IP" ]] && error "Could not detect LAN IP."

# Ensure config directory exists
if [[ ! -d "/etc/searxng" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "[DRY-RUN] /etc/searxng not found; APPLY mode would fail here."
    else
        error "SearXNG config directory /etc/searxng not found. Run setup script first."
    fi
fi

# Ensure volumes exist
ensure_volume "searxng-data"
ensure_volume "open-webui-storage"

if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would recreate containers."
else
    # --- SearXNG ---
    if docker ps --filter name=searxng --format '{{.Names}}' | grep -q "^searxng$"; then
        log "Stopping SearXNG..."
        run_cmd docker rm -f searxng
        wait_for_port $SEARXNG_PORT "SearXNG"
    fi

    log "Starting SearXNG..."
    run_cmd docker run -d \
        --name searxng \
        --restart always \
        --network host \
        -v /etc/searxng:/etc/searxng:rw \
        -v searxng-data:/var/cache/searxng:rw \
        -e SEARXNG_BASE_URL="http://${LAN_IP}:${SEARXNG_PORT}" \
        -e SEARXNG_PORT="${SEARXNG_PORT}" \
        -e SEARXNG_BIND_ADDRESS="0.0.0.0" \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add SETGID \
        --cap-add SETUID \
        docker.io/searxng/searxng:latest

    # --- Open WebUI ---
    if docker ps --filter name=open-webui --format '{{.Names}}' | grep -q "^open-webui$"; then
        log "Stopping Open WebUI..."
        run_cmd docker rm -f open-webui
        wait_for_port $WEBUI_PORT "Open WebUI"
    fi

    log "Starting Open WebUI..."
    SEARXNG_QUERY_URL="http://127.0.0.1:${SEARXNG_PORT}/search?q=<query>&format=json"
    run_cmd docker run -d \
        --name open-webui \
        --restart always \
        --network host \
        -v open-webui-storage:/app/backend/data \
        -e OLLAMA_BASE_URL="http://${LAN_IP}:11434" \
        -e ENABLE_R1_THINKING="true" \
        -e ENABLE_RAG_WEB_SEARCH="True" \
        -e RAG_WEB_SEARCH_ENGINE="searxng" \
        -e "SEARXNG_QUERY_URL=${SEARXNG_QUERY_URL}" \
        -e RAG_WEB_SEARCH_RESULT_COUNT="5" \
        -e RAG_WEB_SEARCH_CONCURRENT_REQUESTS="10" \
        ghcr.io/open-webui/open-webui:v0.5.20
fi

# 6. Models
log ""
log ">>> Step 6: Updating Models..."
for model in "${MODELS[@]}"; do
    log "Updating: $model"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] ollama pull $model"
    else
        run_cmd OLLAMA_HOST="${LAN_IP}:11434" ollama pull "$model" || warn "Failed to update $model"
    fi
done

# 7. Verification
log ""
log ">>> Step 7: Verifying..."
if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Verification skipped."
else
    sleep 5
    if ss -tulpn | grep -qE "LISTEN.*:${OLLAMA_PORT}"; then log "✓ Ollama OK"; else warn "⚠ Ollama Down"; fi
    if ss -tulpn | grep -qE "LISTEN.*:${WEBUI_PORT}"; then log "✓ WebUI OK"; else warn "⚠ WebUI Down"; fi
    if ss -tulpn | grep -qE "LISTEN.*:${SEARXNG_PORT}"; then log "✓ SearXNG OK"; else warn "⚠ SearXNG Down"; fi

    if curl -s "http://${LAN_IP}:${OLLAMA_PORT}/api/tags" > /dev/null; then
        log "✓ API Responding"
    else
        warn "⚠ API Not Responding"
    fi
fi

log ""
log "════════════════════════════════════════════════════════════════"
log "Update Complete."
log "Log: $LOG_FILE"
log "Nobara Sync Log: ~/.local/share/nobara-updater/nobara-sync.log"
log "════════════════════════════════════════════════════════════════"
