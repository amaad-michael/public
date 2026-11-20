#!/bin/bash

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# GPU Box Ollama + Open WebUI Deployment v1.9  (AMD / ROCm only)
# 16GB VRAM (Qwen 14B, Qwen 7B, DeepSeek-R1 14B, LLaVA 13B, nomic-embed)
# ────────────────────────────────────────────────────────────────────────────

# Root check runs BEFORE anything touches $LOG_FILE.
[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)" >&2; exit 1; }

SCRIPT_VERSION="1.9"
LOG_FILE="/var/log/gpu-box-llm-setup.log"
WEBUI_PORT="8080"
SEARXNG_PORT="8888"
SEARXNG_CONFIG_DIR="/etc/searxng"

# Publish address for SearXNG. 127.0.0.1 keeps the unauthenticated metasearch
# proxy off the LAN; Open WebUI reaches it over loopback. Set to 0.0.0.0 to
# expose the SearXNG UI on the LAN (a firewalld rule is then added for it).
SEARXNG_LISTEN_ADDR="127.0.0.1"

# Model residency. "-1" pins models forever; on 16GB with five models that
# maximises eviction churn and never frees VRAM at idle.
OLLAMA_KEEP_ALIVE="30m"

# ROCm gfx override. Empty = let ROCm autodetect. 11.0.0 = RDNA3, 10.3.0 = RDNA2.
HSA_OVERRIDE_GFX_VERSION=""

# Set to "yes" to proceed on a host with no usable AMD compute device.
ALLOW_CPU_FALLBACK="no"

# TODO(RISK-1): floating tags, accepted as a temporary placeholder. Replace both
# with digest references once a target version is selected. The resolved digest
# of whatever is actually running is written to $LOG_FILE on every run.
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"
SEARXNG_IMAGE="docker.io/searxng/searxng:latest"

OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_DROPIN="${OLLAMA_DROPIN_DIR}/10-gpu-box.conf"

declare -a REQUIRED_MODELS=(
    "qwen2.5-coder:14b"
    "qwen2.5-coder:7b"
    "deepseek-r1:14b"
    "nomic-embed-text:latest"
    "llava:13b"
)

# ────────────────────────────────────────────────────────────────────────────
# Logging & Error Handling
# ────────────────────────────────────────────────────────────────────────────

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

error() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] ERROR: $*" | tee -a "$LOG_FILE" >&2
    exit 1
}

container_exists() { docker ps -a --format '{{.Names}}' | grep -x "$1" >/dev/null; }
container_running() { docker ps --format '{{.Names}}' | grep -x "$1" >/dev/null; }

log "GPU Box Ollama + Open WebUI Setup v$SCRIPT_VERSION starting (AMD/ROCm)..."

# ────────────────────────────────────────────────────────────────────────────
# AMD GPU Validation
# ────────────────────────────────────────────────────────────────────────────

if [[ -e /dev/kfd && -d /sys/class/kfd ]]; then
    log "✓ AMD KFD compute device present (/dev/kfd)"
else
    if [[ "$ALLOW_CPU_FALLBACK" == "yes" ]]; then
        log "⚠ No AMD compute device — continuing in CPU mode (14B inference will be unusable)"
    else
        error "No AMD compute device (/dev/kfd absent). amdgpu/KFD not loaded, or the card is unsupported. Set ALLOW_CPU_FALLBACK=yes to override."
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# System Package Installation
# ────────────────────────────────────────────────────────────────────────────

log "Installing system dependencies..."
dnf install -y git curl wget pciutils python3 > /tmp/dnf-install.log 2>&1 \
    || error "Failed to install dependencies. See /tmp/dnf-install.log"

if command -v lspci &>/dev/null; then
    GPU_PCI=$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display' | grep -Ei 'amd|ati|radeon' || true)
    [[ -n "$GPU_PCI" ]] && log "AMD GPU on PCI bus: ${GPU_PCI%%$'\n'*}"
fi

if ! command -v docker &>/dev/null; then
    log "Installing moby-engine (Docker) from Nobara repo..."
    dnf install -y moby-engine >> /tmp/dnf-install.log 2>&1 \
        || error "Failed to install moby-engine. See /tmp/dnf-install.log"
    log "✓ moby-engine installed: $(docker --version)"
else
    log "✓ Docker already present: $(docker --version)"
fi

# ────────────────────────────────────────────────────────────────────────────
# Docker Service
# ────────────────────────────────────────────────────────────────────────────

log "Enabling and starting Docker..."
systemctl enable docker > /tmp/systemctl-enable-docker.log 2>&1 || error "Failed to enable Docker"

if systemctl is-active --quiet docker; then
    log "Docker already running"
else
    systemctl start docker > /tmp/systemctl-start-docker.log 2>&1 || error "Failed to start Docker"
    log "Docker started"
fi

# SELinux volume labelling is only meaningful if the daemon has it enabled.
MOUNT_OPTS="rw"
if docker info --format '{{join .SecurityOptions ","}}' 2>/dev/null | grep -q selinux; then
    MOUNT_OPTS="rw,Z"
    log "Docker reports SELinux support — bind mounts will be relabelled (:Z)"
fi

# ────────────────────────────────────────────────────────────────────────────
# LAN Address Detection
# ────────────────────────────────────────────────────────────────────────────

# Global-scope IPv4 on a physical interface. Excludes docker/bridge/veth/virt
# interfaces by name rather than by address range, so RFC1918 172.16-31 works.
# awk consumes all input and prints in END — an early `exit` would close the
# pipe on `ip` exactly like `head -1` does, which is a SIGPIPE abort waiting
# to happen under pipefail.
LAN_ADDR=$(ip -4 -o addr show scope global \
    | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|cni|flannel)/ && addr == "" { addr = $4 }
           END { print addr }')
[[ -n "$LAN_ADDR" ]] || error "Could not detect a LAN IPv4 address. Set LAN_ADDR manually."

LAN_IP="${LAN_ADDR%%/*}"
LAN_NET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$LAN_ADDR") \
    || error "Could not derive LAN network from $LAN_ADDR"

log "LAN IP: $LAN_IP   LAN network: $LAN_NET"

# Persist OLLAMA_HOST for interactive CLI use (the service binds the LAN IP).
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    REAL_USER=$(logname 2>/dev/null || true)
fi
if [[ -n "$REAL_USER" ]]; then
    # pipefail would propagate getent's exit 2 for an unknown user and abort.
    REAL_USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 || true)
    if [[ -n "$REAL_USER_HOME" && -d "$REAL_USER_HOME" ]]; then
        if grep -qF "OLLAMA_HOST" "${REAL_USER_HOME}/.bashrc" 2>/dev/null; then
            sed -i "s|^export OLLAMA_HOST=.*|export OLLAMA_HOST=${LAN_IP}:11434|" "${REAL_USER_HOME}/.bashrc"
            log "✓ OLLAMA_HOST refreshed in ${REAL_USER_HOME}/.bashrc"
        else
            echo "export OLLAMA_HOST=${LAN_IP}:11434" >> "${REAL_USER_HOME}/.bashrc"
            log "✓ OLLAMA_HOST added to ${REAL_USER_HOME}/.bashrc"
        fi
    fi
else
    log "⚠ Could not determine invoking user — skipping .bashrc update"
fi

# ────────────────────────────────────────────────────────────────────────────
# Firewall (firewalld) — LAN-scoped, deny by default elsewhere
# ────────────────────────────────────────────────────────────────────────────

open_lan_port() {
    local port="$1" rule
    rule="rule family=ipv4 source address=${LAN_NET} port port=${port} protocol=tcp accept"
    if firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
        log "firewalld: ${port}/tcp already allowed from ${LAN_NET}"
    else
        firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null \
            || error "firewalld: failed to add rule for ${port}/tcp"
        log "✓ firewalld: ${port}/tcp opened to ${LAN_NET}"
    fi
}

if systemctl is-active --quiet firewalld; then
    open_lan_port 11434
    open_lan_port "$WEBUI_PORT"
    if [[ "$SEARXNG_LISTEN_ADDR" == "0.0.0.0" ]]; then
        open_lan_port "$SEARXNG_PORT"
    fi
    firewall-cmd --reload >/dev/null || error "firewalld reload failed"
    log "✓ firewalld reloaded"
else
    log "⚠ firewalld not active — skipping firewall configuration"
fi

# ────────────────────────────────────────────────────────────────────────────
# Ollama Installation (official install script — ROCm build for AMD)
# ────────────────────────────────────────────────────────────────────────────

# Clear partial install artefacts that would make the installer's useradd fail.
if [[ ! -f /etc/systemd/system/ollama.service ]]; then
    log "No ollama unit found — clearing partial install state..."
    userdel ollama 2>/dev/null || true
    groupdel ollama 2>/dev/null || true
    rm -f /usr/local/bin/ollama /usr/local/sbin/ollama
fi

if command -v ollama &>/dev/null && [[ -f /etc/systemd/system/ollama.service ]]; then
    log "Ollama already installed"
else
    log "Installing Ollama via official install script (ROCm build)..."
    _ollama_installer="$(mktemp)"
    curl -fsSL -o "$_ollama_installer" https://ollama.com/install.sh >> /tmp/ollama-install.log 2>&1 \
        || error "Ollama installer download failed. See /tmp/ollama-install.log"
    if [[ -n "${OLLAMA_INSTALL_SHA256:-}" ]]; then
        echo "${OLLAMA_INSTALL_SHA256}  $_ollama_installer" | sha256sum -c - >> /tmp/ollama-install.log 2>&1 \
            || error "Ollama installer checksum mismatch — refusing to run"
    else
        log "⚠ OLLAMA_INSTALL_SHA256 not set — running ollama.com/install.sh without checksum verification"
    fi
    sh "$_ollama_installer" >> /tmp/ollama-install.log 2>&1 \
        || error "Ollama install script failed. See /tmp/ollama-install.log"
    rm -f "$_ollama_installer"
    log "✓ Ollama installed"
fi

# The installer rewrites ollama.service on every upgrade. Configure via a
# drop-in so the settings survive.
mkdir -p "$OLLAMA_DROPIN_DIR"
{
    echo "[Service]"
    echo "Environment=\"OLLAMA_HOST=${LAN_IP}:11434\""
    echo "Environment=\"OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}\""
    if [[ -n "$HSA_OVERRIDE_GFX_VERSION" ]]; then
        echo "Environment=\"HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION}\""
    fi
} > "${OLLAMA_DROPIN}.new"

if cmp -s "${OLLAMA_DROPIN}.new" "$OLLAMA_DROPIN" 2>/dev/null; then
    rm -f "${OLLAMA_DROPIN}.new"
    log "Ollama drop-in already current"
else
    mv "${OLLAMA_DROPIN}.new" "$OLLAMA_DROPIN"
    log "✓ Ollama drop-in written: $OLLAMA_DROPIN"
fi

systemctl daemon-reload || error "systemctl daemon-reload failed"
systemctl enable ollama > /dev/null 2>&1 || error "Failed to enable ollama service"
systemctl restart ollama || error "Failed to restart ollama service"

# Poll the API instead of sleeping blind.
log "Waiting for Ollama API..."
OLLAMA_READY="no"
for i in {1..12}; do
    if curl -fsS "http://${LAN_IP}:11434/api/tags" >/dev/null 2>&1; then
        OLLAMA_READY="yes"
        break
    fi
    log "Ollama not ready yet (attempt $i/12), waiting 5s..."
    sleep 5
done
[[ "$OLLAMA_READY" == "yes" ]] || error "Ollama API did not come up. Check: journalctl -u ollama -n 50"
log "✓ Ollama API responding on ${LAN_IP}:11434"

# ────────────────────────────────────────────────────────────────────────────
# Model Pulling (idempotent, tag-normalised)
# ────────────────────────────────────────────────────────────────────────────

log "Pulling required models (30–60 minutes on first run)..."

EXISTING_MODELS=$(OLLAMA_HOST="${LAN_IP}:11434" ollama list 2>/dev/null | awk 'NR>1 {print $1}' || true)

for model in "${REQUIRED_MODELS[@]}"; do
    # Compare with the :latest suffix stripped from both sides — `ollama list`
    # always prints it, so a literal match on "nomic-embed-text" never fires.
    if printf '%s\n' "$EXISTING_MODELS" | sed 's/:latest$//' | grep -qxF "${model%:latest}"; then
        log "✓ Model already installed: $model"
    else
        log "Pulling model: $model ..."
        OLLAMA_HOST="${LAN_IP}:11434" ollama pull "$model" \
            > "/tmp/ollama-pull-${model//:/-}.log" 2>&1 \
            || error "Failed to pull $model. See /tmp/ollama-pull-${model//:/-}.log"
        log "✓ Model pulled: $model"
    fi
done

log "Installed models:"
OLLAMA_HOST="${LAN_IP}:11434" ollama list | tee -a "$LOG_FILE" || true

# ────────────────────────────────────────────────────────────────────────────
# SearXNG Web Search Container
# ────────────────────────────────────────────────────────────────────────────

log "Deploying SearXNG container..."

mkdir -p "$SEARXNG_CONFIG_DIR"
SEARXNG_RESTART_NEEDED="no"

if [[ ! -f "$SEARXNG_CONFIG_DIR/settings.yml" ]]; then
    log "Writing SearXNG settings.yml..."
    SEARXNG_SECRET=$(openssl rand -hex 32)
    # NOTE: server.port / server.bind_address are deliberately absent. They are
    # inert inside the container (Granian owns the socket); the published
    # Docker port is the only thing that decides where this is reachable.
    cat > "$SEARXNG_CONFIG_DIR/settings.yml" << EOF
use_default_settings:
  engines:
    keep_only:
      - google
      - duckduckgo
      - bing
      - wikipedia

server:
  secret_key: "$SEARXNG_SECRET"
  limiter: false
  image_proxy: false

ui:
  static_use_hash: true

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json

outgoing:
  request_timeout: 10.0
  max_request_timeout: 20.0
  useragent_suffix: ""
  pool_connections: 100
  pool_maxsize: 20
EOF
    chmod 0644 "$SEARXNG_CONFIG_DIR/settings.yml"
    log "✓ SearXNG settings.yml written"
else
    log "SearXNG settings.yml already exists — checking JSON format..."
    if ! grep -qE "^[[:space:]]*- json" "$SEARXNG_CONFIG_DIR/settings.yml"; then
        sed -i '/^[[:space:]]*formats:/a\    - json' "$SEARXNG_CONFIG_DIR/settings.yml"
        SEARXNG_RESTART_NEEDED="yes"
        log "✓ json format added to existing settings.yml (restart required)"
    fi
fi

# base_url must match where SearXNG is actually reachable, not where the
# rest of the stack lives — it is loopback-only unless deliberately exposed.
if [[ "$SEARXNG_LISTEN_ADDR" == "0.0.0.0" ]]; then
    SEARXNG_BASE_HOST="$LAN_IP"
else
    SEARXNG_BASE_HOST="$SEARXNG_LISTEN_ADDR"
fi

docker volume create searxng-data > /dev/null

if container_exists searxng; then
    if container_running searxng; then
        log "SearXNG container already running"
    else
        docker start searxng > /dev/null || error "Failed to start existing SearXNG container"
        log "✓ SearXNG container started (pre-existing)"
    fi
    if [[ "$SEARXNG_RESTART_NEEDED" == "yes" ]]; then
        docker restart searxng > /dev/null || error "Failed to restart SearXNG"
        log "✓ SearXNG restarted to pick up settings.yml change"
    fi
else
    # Bridge networking with an explicit published port. The container listens on
    # 8080 internally unless SEARXNG_PORT is passed (the entrypoint honours it by
    # aliasing to GRANIAN_PORT); SEARXNG_BIND_ADDRESS and settings.yml
    # server.port / server.bind_address have no effect on current images.
    # Docker decides the host-side port via the -p mapping below.
    docker run -d \
        --name searxng \
        --restart always \
        -p "${SEARXNG_LISTEN_ADDR}:${SEARXNG_PORT}:8080" \
        -v "${SEARXNG_CONFIG_DIR}:/etc/searxng:${MOUNT_OPTS}" \
        -v searxng-data:/var/cache/searxng:rw \
        -e SEARXNG_BASE_URL="http://${SEARXNG_BASE_HOST}:${SEARXNG_PORT}/" \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add SETGID \
        --cap-add SETUID \
        --cap-add DAC_OVERRIDE \
        --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
        "$SEARXNG_IMAGE" > /tmp/searxng-run.log 2>&1 \
        || error "Failed to start SearXNG. See /tmp/searxng-run.log"
    log "✓ SearXNG container started"
fi

log "Waiting for SearXNG JSON API..."
SEARCH_TEST="failed"
for i in {1..12}; do
    SEARCH_TEST=$(curl -s "http://127.0.0.1:${SEARXNG_PORT}/search?q=test&format=json" 2>/dev/null || echo "failed")
    if printf '%s' "$SEARCH_TEST" | grep -q '"results"'; then
        break
    fi
    log "SearXNG not ready yet (attempt $i/12), waiting 5s..."
    sleep 5
done

if printf '%s' "$SEARCH_TEST" | grep -q '"results"'; then
    log "✓ SearXNG JSON API responding"
else
    log "⚠ SearXNG JSON API not responding — check: docker logs searxng"
fi

# ────────────────────────────────────────────────────────────────────────────
# Open WebUI Container
# ────────────────────────────────────────────────────────────────────────────

log "Deploying Open WebUI container..."

docker volume create open-webui-storage > /dev/null

SEARXNG_QUERY_URL="http://127.0.0.1:${SEARXNG_PORT}/search?q=<query>"

# WEB_SEARCH_CONCURRENT_REQUESTS now controls search-engine request concurrency
# (0 = unlimited) — repurposed from the old RAG-era page-fetch concurrency
# variable of the same name. 10 is still a sane value.

webui_config_current() {
    local env_lines image
    env_lines=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' open-webui 2>/dev/null) || return 1
    image=$(docker inspect -f '{{.Config.Image}}' open-webui 2>/dev/null) || return 1
    [[ "$image" == "$OPENWEBUI_IMAGE" ]] || return 1
    printf '%s' "$env_lines" | grep -qxF "ENABLE_WEB_SEARCH=True" || return 1
    printf '%s' "$env_lines" | grep -qxF "WEB_SEARCH_ENGINE=searxng" || return 1
    printf '%s' "$env_lines" | grep -qxF "ENABLE_PERSISTENT_CONFIG=False" || return 1
    printf '%s' "$env_lines" | grep -qxF "SEARXNG_QUERY_URL=${SEARXNG_QUERY_URL}" || return 1
    return 0
}

if container_running open-webui && webui_config_current; then
    log "Open WebUI already running with the expected image and configuration"
else
    if container_exists open-webui; then
        BACKUP="/var/log/open-webui-env-$(date +%Y%m%d-%H%M%S).txt"
        docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' open-webui > "$BACKUP" 2>/dev/null || true
        log "Existing Open WebUI environment backed up to $BACKUP"
        log "Recreating Open WebUI — any env vars not set by this script will be lost"
        docker rm -f open-webui > /dev/null 2>&1 || true
    fi

    docker run -d \
        --name open-webui \
        --restart always \
        --network host \
        -v open-webui-storage:/app/backend/data \
        -e OLLAMA_BASE_URL="http://${LAN_IP}:11434" \
        -e ENABLE_PERSISTENT_CONFIG="False" \
        -e ENABLE_WEB_SEARCH="True" \
        -e WEB_SEARCH_ENGINE="searxng" \
        -e "SEARXNG_QUERY_URL=${SEARXNG_QUERY_URL}" \
        -e WEB_SEARCH_RESULT_COUNT="5" \
        -e WEB_SEARCH_CONCURRENT_REQUESTS="10" \
        "$OPENWEBUI_IMAGE" > /tmp/docker-run.log 2>&1 \
        || error "Failed to start Open WebUI. See /tmp/docker-run.log"
    log "✓ Open WebUI container started"
fi

log "Waiting for Open WebUI HTTP endpoint..."
WEBUI_READY="no"
for i in {1..18}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${WEBUI_PORT}/health" 2>/dev/null \
       || curl -fsS -o /dev/null "http://127.0.0.1:${WEBUI_PORT}/" 2>/dev/null; then
        WEBUI_READY="yes"
        break
    fi
    log "Open WebUI not ready yet (attempt $i/18), waiting 5s..."
    sleep 5
done

if [[ "$WEBUI_READY" == "yes" ]]; then
    log "✓ Open WebUI responding on :${WEBUI_PORT}"
else
    log "⚠ Open WebUI endpoint timeout — check: docker logs open-webui"
fi

# ────────────────────────────────────────────────────────────────────────────
# Verification
# ────────────────────────────────────────────────────────────────────────────

log "Verifying inference stack..."

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:11434[[:space:]]"; then
    log "✓ Ollama API listening on ${LAN_IP}:11434"
else
    log "⚠ Ollama API not listening"
fi

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:${SEARXNG_PORT}[[:space:]]"; then
    log "✓ SearXNG listening on ${SEARXNG_LISTEN_ADDR}:${SEARXNG_PORT}"
else
    log "⚠ SearXNG not listening on :${SEARXNG_PORT}"
fi

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:${WEBUI_PORT}[[:space:]]"; then
    log "✓ Open WebUI listening on :${WEBUI_PORT}"
else
    log "⚠ Open WebUI not listening"
fi

log "Ollama service state: $(systemctl is-active ollama 2>/dev/null || echo unknown)"

API_TEST=$(curl -fsS "http://${LAN_IP}:11434/api/tags" 2>/dev/null || echo "")
if [[ -n "$API_TEST" ]]; then
    log "✓ Ollama API responding"
    printf '%s' "$API_TEST" | python3 -m json.tool 2>/dev/null | head -20 | tee -a "$LOG_FILE" || true
else
    log "⚠ Ollama API not responding"
fi

# ────────────────────────────────────────────────────────────────────────────
# VRAM (ROCm)
# ────────────────────────────────────────────────────────────────────────────

log "GPU VRAM status:"
if command -v rocm-smi &>/dev/null; then
    rocm-smi --showmeminfo vram 2>/dev/null | tee -a "$LOG_FILE" || true
else
    log "⚠ rocm-smi not installed — install ROCm userspace tools for VRAM reporting"
    log "  Ollama bundles its own ROCm runtime; rocm-smi is only needed for monitoring."
fi

# ────────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Setup Complete — v$SCRIPT_VERSION"
log "════════════════════════════════════════════════════════════════"
log "Ollama API:       http://${LAN_IP}:11434   (LAN: ${LAN_NET})"
log "Open WebUI:       http://${LAN_IP}:${WEBUI_PORT}"
log "SearXNG:          http://${SEARXNG_LISTEN_ADDR}:${SEARXNG_PORT}"
log "Models:           ${#REQUIRED_MODELS[@]} configured"
log "Keep-alive:       ${OLLAMA_KEEP_ALIVE}"
log "Log file:         $LOG_FILE"
log ""
# RISK-1 mitigation: the tags float, so record exactly which image is in service.
# This is the audit trail that makes a floating tag recoverable after the fact.
log "Images in service (tags float — record these):"
for ctr in open-webui searxng; do
    CTR_TAG=$(docker inspect -f '{{.Config.Image}}' "$ctr" 2>/dev/null || echo "unknown")
    CTR_ID=$(docker inspect -f '{{.Image}}' "$ctr" 2>/dev/null || echo "unknown")
    CTR_DIGEST=$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}no-digest{{end}}' "$CTR_ID" 2>/dev/null || echo "unknown")
    log "  ${ctr}: tag=${CTR_TAG}"
    log "  ${ctr}: digest=${CTR_DIGEST}"
done
log ""
log "Next steps:"
log "  1. curl http://${LAN_IP}:11434/api/tags"
log "  2. Open http://${LAN_IP}:${WEBUI_PORT}"
log "  3. Enable Web Search per chat via the Integrations control in the input bar"
log "  4. journalctl -u ollama -f"
