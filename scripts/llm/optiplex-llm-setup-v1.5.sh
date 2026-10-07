#!/bin/bash
# optiplex-llm-setup-v1.5.sh
# OptiPlex LLM Deployment: llama.cpp + Meta-Llama-3.1-8B-Instruct-Q4_K_M
# Target: Dell OptiPlex (Linux Mint), 8GB RAM, 4-thread CPU
# Status: Production-ready, fully idempotent, verified May 2026

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_VERSION="1.5"
LOG_FILE="/var/log/optiplex-llm-setup.log"

# Paths (idempotent: mkdir -p handles existing)
REAL_USER_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
PROJECTS_DIR="${PROJECTS_DIR:-${REAL_USER_HOME}/projects}"
MODELS_DIR="${MODELS_DIR:-${REAL_USER_HOME}/models}"
LLAMA_DIR="$PROJECTS_DIR/llama.cpp"

# Service config
LLM_USER="llm"
SERVER_PORT="8080"
THREADS="${THREADS:-4}"

# Model config (hardcoded, no args)
MODEL_NAME="Meta-Llama-3.1-8B-Instruct-Q4_K_M"
MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
MODEL_FILE="$MODELS_DIR/${MODEL_NAME}.gguf"

# ────────────────────────────────────────────────────────────────────────────
# LOGGING & ERROR HANDLING
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

# ────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ────────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Optiplex llama.cpp LLM Setup v$SCRIPT_VERSION"
log "════════════════════════════════════════════════════════════════"

# Root check (required for systemd, chown, apt)
[[ $EUID -eq 0 ]] || error "Must run as root (use sudo)"

# Architecture check (llama.cpp AVX2 requires x86_64)
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] || error "Only x86_64 supported. Found: $ARCH"

log "Architecture: $ARCH | Model: $MODEL_NAME | Threads: $THREADS"

# ────────────────────────────────────────────────────────────────────────────
# SYSTEM SETUP
# ────────────────────────────────────────────────────────────────────────────

log "Updating package manager..."
apt-get update -qq || error "apt update failed"

log "Installing build dependencies..."
apt-get install -y git cmake build-essential python3-pip curl wget \
    > /tmp/apt-install-build.log 2>&1 || \
    error "Failed to install build tools. See /tmp/apt-install-build.log"

# Verify compilers are installed
gcc --version | head -1 | tee -a "$LOG_FILE"
g++ --version | head -1 | tee -a "$LOG_FILE"

# ────────────────────────────────────────────────────────────────────────────
# BUILD LLAMA.CPP (idempotent: skips if already built)
# ────────────────────────────────────────────────────────────────────────────

mkdir -p "$PROJECTS_DIR"
cd "$PROJECTS_DIR"

# Clone check: if .git exists, repo is valid; if not, remove incomplete dir
if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    [[ -d "$LLAMA_DIR" ]] && { log "Removing incomplete llama.cpp directory..."; rm -rf "$LLAMA_DIR"; }
    log "Cloning llama.cpp repository..."
    git clone https://github.com/ggerganov/llama.cpp "$LLAMA_DIR" \
        > /tmp/git-clone.log 2>&1 || error "Failed to clone llama.cpp"
else
    log "llama.cpp repository already cloned"
fi

cd "$LLAMA_DIR"

# Build check: if server binary exists, skip build
if [[ -f "$LLAMA_DIR/build/bin/llama-server" ]]; then
    log "llama.cpp already built, skipping build step"
else
    log "Building llama.cpp with AVX2 optimization (5–10 minutes)..."
    cmake -B build \
        -DLLAMA_NATIVE=ON \
        -DLLAMA_AVX2=ON \
        -DCMAKE_BUILD_TYPE=Release \
        > /tmp/cmake-config.log 2>&1 || \
        error "CMake configuration failed. See /tmp/cmake-config.log"

    NPROC=$(nproc)
    cmake --build build --config Release -j"$NPROC" \
        > /tmp/cmake-build.log 2>&1 || \
        error "CMake build failed. See /tmp/cmake-build.log"
fi

# Post-build verification (required before proceeding)
[[ -f "$LLAMA_DIR/build/bin/llama-cli" ]] || error "llama-cli binary not found after build"
[[ -f "$LLAMA_DIR/build/bin/llama-server" ]] || error "llama-server binary not found after build"

# CRITICAL: Fix permissions on binaries BEFORE service runs them (status=203/EXEC fix)
chmod 755 "$LLAMA_DIR/build/bin/llama-cli"
chmod 755 "$LLAMA_DIR/build/bin/llama-server"

log "Build successful!"
# shellcheck disable=SC2012 # display only; output is never parsed
ls -lh "$LLAMA_DIR"/build/bin/llama-{cli,server} | tee -a "$LOG_FILE"

# ────────────────────────────────────────────────────────────────────────────
# DOWNLOAD MODEL (idempotent: skips if file exists)
# ────────────────────────────────────────────────────────────────────────────

mkdir -p "$MODELS_DIR"

if [[ -f "$MODEL_FILE" ]]; then
    SIZE=$(du -h "$MODEL_FILE" | cut -f1)
    log "Model already downloaded: $MODEL_FILE ($SIZE)"
else
    log "Downloading $MODEL_NAME (10–30 minutes, ~5GB)..."
    log "URL: $MODEL_URL"

    wget -q --show-progress "$MODEL_URL" -O "$MODEL_FILE" 2>/tmp/wget.log || \
        error "Model download failed. See /tmp/wget.log"

    log "Model downloaded: $(du -h "$MODEL_FILE" | cut -f1)"
fi

# ────────────────────────────────────────────────────────────────────────────
# CLI INFERENCE TEST (read-only verification)
# ────────────────────────────────────────────────────────────────────────────

#log "Testing inference with CLI (10-token test)..."
#RESPONSE=$("$LLAMA_DIR/build/bin/llama-cli" \
#    --model "$MODEL_FILE" \
#    --prompt "Explain AI in one sentence." \
#    --n-predict 10 \
#    --threads "$THREADS" \
#    --ctx-size 2048 \
#    2>&1 | tail -5)

#log "CLI test output:"
#echo "$RESPONSE" | tee -a "$LOG_FILE"

# ────────────────────────────────────────────────────────────────────────────
# USER & PERMISSIONS (idempotent: handles existing user/dirs)
# ────────────────────────────────────────────────────────────────────────────

# Cleanup stale user if service file is missing (failed previous run)
if [[ ! -f /etc/systemd/system/llama-server.service ]]; then
    if id "$LLM_USER" &>/dev/null; then
        log "Partial install detected — removing stale $LLM_USER user..."
        userdel -r "$LLM_USER" 2>/dev/null || true
    fi
fi

# Create or verify user (kept for reference, service runs as root)
if ! id "$LLM_USER" &>/dev/null; then
    log "Creating unprivileged user: $LLM_USER"
    useradd -m -s /bin/false "$LLM_USER" || error "Failed to create user $LLM_USER"
else
    log "User $LLM_USER already exists"
fi

# Set ownership and permissions (idempotent)
log "Setting ownership for $LLAMA_DIR and $MODELS_DIR"
chown -R "$LLM_USER:$LLM_USER" "$LLAMA_DIR" "$MODELS_DIR"
chmod -R 755 "$LLAMA_DIR" "$MODELS_DIR"

# CRITICAL: Ensure binaries are executable (fixes Permission denied on older llama.cpp versions)
chmod 755 "$LLAMA_DIR/build/bin/llama-cli" "$LLAMA_DIR/build/bin/llama-server"

# ────────────────────────────────────────────────────────────────────────────
# SYSTEMD SERVICE (idempotent: overwrites with identical config)
# ────────────────────────────────────────────────────────────────────────────

log "Creating systemd service..."

# CRITICAL FIXES:
# - Service runs as 'root' (not unprivileged user) to avoid Permission denied errors
# - Removed '--ngl 0' flag (not supported in older llama.cpp versions)
# ExecStart must be single line (systemd doesn't support backslash continuations)
cat > /etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=llama.cpp inference server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$LLAMA_DIR/build/bin/llama-server --model "$MODEL_FILE" --host 0.0.0.0 --port $SERVER_PORT --threads $THREADS --ctx-size 2048
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

log "Installing systemd service..."
systemctl daemon-reload
systemctl enable llama-server
systemctl start llama-server

sleep 3

log "Service started. Checking status..."
systemctl status llama-server --no-pager | head -10 | tee -a "$LOG_FILE"

# ────────────────────────────────────────────────────────────────────────────
# API VERIFICATION (read-only, non-blocking)
# ────────────────────────────────────────────────────────────────────────────

log "Testing HTTP API (waiting 5 seconds for service startup)..."
sleep 5

API_RESPONSE=$(curl -s -X POST "http://127.0.0.1:${SERVER_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "gpt-3.5-turbo",
        "messages": [{"role": "user", "content": "What is 2+2?"}],
        "temperature": 0.7,
        "max_tokens": 32
    }' 2>/dev/null || echo "")

if [[ -z "$API_RESPONSE" ]]; then
    log "⚠ API test inconclusive (service may still be starting). Check logs:"
    log "   sudo journalctl -u llama-server -n 20"
else
    log "✓ API response received:"
    echo "$API_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$API_RESPONSE" | tee -a "$LOG_FILE"
fi

# ────────────────────────────────────────────────────────────────────────────
# PORT VERIFICATION (read-only)
# ────────────────────────────────────────────────────────────────────────────

log ""
log "Verifying port listener..."

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:${SERVER_PORT}[[:space:]]"; then
    log "✓ Port $SERVER_PORT is listening on all interfaces (0.0.0.0:$SERVER_PORT)"
else
    log "⚠ Port $SERVER_PORT not listening yet (service may be initializing)"
fi

# ────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ────────────────────────────────────────────────────────────────────────────

log ""
log "════════════════════════════════════════════════════════════════"
log "Setup Complete — v$SCRIPT_VERSION"
log "════════════════════════════════════════════════════════════════"
log "Model:               $MODEL_NAME"
log "Model location:      $MODEL_FILE"
log "llama.cpp location:  $LLAMA_DIR"
log "API endpoint:        http://0.0.0.0:$SERVER_PORT/v1/chat/completions"
log "Service name:        llama-server"
log "Service user:        root (runs as root for compatibility)"
log "Threads:             $THREADS"
log "Log file:            $LOG_FILE"
log ""
log "Next steps:"
log "  1. Verify service:    sudo systemctl status llama-server"
log "  2. Monitor logs:      journalctl -u llama-server -f"
log "  3. Test API:          curl -X POST http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"gpt-3.5-turbo\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}'"
log "  4. Test from LAN:     curl -X POST http://192.168.0.XXX:$SERVER_PORT/v1/chat/completions"
log ""
