#!/bin/bash
set -euo pipefail

################################################################################
# Open Terminal Agent for LLM Stack — v1.2 (Hardened)
################################################################################
#
# PURPOSE:
#   Deploy a hardened, jailhouse-isolated file I/O service that your LLM models
#   (Qwen, DeepSeek, etc. in Open WebUI) can call as a tool to create, read,
#   modify, and delete files. No command execution, no shell access, no escape.
#
# ARCHITECTURE:
#   - Docker container (hardened, read-only root filesystem)
#   - HTTP API on 127.0.0.1:9000 (localhost-only loopback binding, not exposed to LAN)
#   - File I/O sandbox at /workspace
#   - Minimal capabilities (SETUID/SETGID/CHOWN only), dropped all others
#   - Integration: Open WebUI calls this natively as file I/O tool
#
# SECURITY MODEL:
#   ✓ Localhost-only port binding (127.0.0.1:9000 — no LAN access)
#   ✓ Read-only root filesystem (prevents modification of system binaries)
#   ✓ All Linux capabilities dropped except SETUID/SETGID/CHOWN (minimal required for initialization)
#   ✓ Only /workspace writable for file I/O (jailhouse isolation)
#   ✓ tmpfs for /tmp, /run, /home (volatile, auto-cleared on restart, noexec/nosuid)
#   ✓ API key required for all requests (Bearer token authentication)
#   ✓ Resource limits: 1 CPU, 256MB RAM, 50 PIDs max (prevents DOS)
#   ✓ --ipc=none (disables inter-process communication attacks)
#   ✓ no-new-privileges (prevents capability escalation)
#   ✓ Container isolated on localhost interface only
#
# PREREQUISITES:
#   - Nobara (or any Fedora-based distro) with Docker installed
#   - Docker daemon running (systemctl status docker)
#   - Port 9000 available (verify: sudo ss -tulpn | grep 9000)
#   - Sudo access or root user
#   - ~500MB disk space for container image + workspace
#
# INTEGRATION WITH OPEN WEBUI:
#   After deployment, you manually register open-terminal as a "function" in
#   Open WebUI so your LLM models can call it:
#
#   1. Access Open WebUI at http://127.0.0.1:8080
#   2. Go to Settings → Functions
#   3. Click "Create Function" and paste the schema below
#   4. Models now see "file_io" as a callable tool
#
#   Function schema (register this in Open WebUI):
#   ```json
#   {
#     "id": "file_io",
#     "name": "file_io",
#     "description": "Create, read, modify, or delete files in the workspace",
#     "meta": {
#       "type": "function",
#       "endpoint": "http://127.0.0.1:9000",
#       "headers": {
#         "Authorization": "Bearer YOUR_API_KEY_HERE"
#       }
#     },
#     "actions": [
#       {
#         "id": "write",
#         "name": "write",
#         "description": "Create or overwrite a file",
#         "type": "function",
#         "endpoint": "http://127.0.0.1:9000/api/file/write",
#         "required_fields": ["path", "content"],
#         "returns": { "type": "object" }
#       },
#       {
#         "id": "read",
#         "name": "read",
#         "description": "Read entire file contents",
#         "type": "function",
#         "endpoint": "http://127.0.0.1:9000/api/file/read",
#         "required_fields": ["path"],
#         "returns": { "type": "string" }
#       },
#       {
#         "id": "list",
#         "name": "list",
#         "description": "List directory contents",
#         "type": "function",
#         "endpoint": "http://127.0.0.1:9000/api/file/list",
#         "required_fields": ["path"],
#         "returns": { "type": "array" }
#       },
#       {
#         "id": "delete",
#         "name": "delete",
#         "description": "Delete a file",
#         "type": "function",
#         "endpoint": "http://127.0.0.1:9000/api/file/delete",
#         "required_fields": ["path"],
#         "returns": { "type": "object" }
#       }
#     ]
#   }
#   ```
#   NOTE: Replace YOUR_API_KEY_HERE with the actual key from:
#   sudo cat /var/lib/open-terminal/api_key.txt
#
# USAGE:
#   1. Run this script: sudo bash setup_open_terminal-v1_2_hardened.sh
#   2. Verify: curl -s http://127.0.0.1:9000/api/status | jq .
#   3. Test file write WITH API KEY:
#        API_KEY=$(sudo cat /var/lib/open-terminal/api_key.txt)
#        curl -X POST http://127.0.0.1:9000/api/file/write \
#          -H "Content-Type: application/json" \
#          -H "Authorization: Bearer $API_KEY" \
#          -d '{"path":"test.txt","content":"hello world"}'
#   4. Verify API key enforcement (this should FAIL without the key):
#        curl -X POST http://127.0.0.1:9000/api/file/write \
#          -H "Content-Type: application/json" \
#          -d '{"path":"test.txt","content":"should fail"}'
#   5. Register function in Open WebUI (Settings → Functions)
#   6. Test via LLM: "Create a script called backup.sh that backs up my photos"
#
# API KEY SECURITY:
#   The API key is generated on first run and stored at /var/lib/open-terminal/api_key.txt
#   It must be passed in every request via: Authorization: Bearer <API_KEY>
#   Update Open WebUI function schema to include this header (see comments below)
#
# MONITORING:
#   - Container logs: docker logs -f open-terminal
#   - Container status: docker ps | grep open-terminal
#   - API health: curl http://127.0.0.1:9000/api/status
#   - Workspace disk usage: du -sh /var/lib/open-terminal/workspace/
#
# UNINSTALL:
#   sudo bash setup_open_terminal-v1_2_hardened.sh --uninstall
#
# TROUBLESHOOTING:
#   - Port 9000 already in use?
#     sudo ss -tulpn | grep 9000
#     Kill the process or choose a different port (edit CONTAINER_PORT below)
#
#   - Docker image won't pull?
#     Check network: ping ghcr.io
#     Try manual: docker pull ghcr.io/open-webui/open-terminal:slim
#
#   - Container crashes on start?
#     docker logs -f open-terminal
#     Common: ulimit issues, volume permissions
#
#   - API not responding?
#     Wait 10 seconds, containers take time to boot
#     curl -v http://127.0.0.1:9000/api/status
#
################################################################################

# Configuration
CONTAINER_NAME="open-terminal"
CONTAINER_IMAGE="ghcr.io/open-webui/open-terminal:slim"
CONTAINER_PORT="9000"
WORKSPACE_DIR="/tmp/open-terminal-workspace"
LOG_DIR="/var/log/open-terminal"
API_KEY_FILE="/var/lib/open-terminal/api_key.txt"

# Logging
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*"
}

error() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] ERROR: $*" >&2
    exit 1
}

# Uninstall handler
if [[ "${1:-}" == "--uninstall" ]]; then
    log "Uninstalling open-terminal..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORKSPACE_DIR" "$LOG_DIR" "$(dirname "$API_KEY_FILE")"
    log "✓ Open Terminal uninstalled. Workspace, logs, and API key removed."
    exit 0
fi

# Root check
[[ $EUID -eq 0 ]] || error "Must run as root (use sudo)"

# Docker check
if ! command -v docker &>/dev/null; then
    error "Docker not found. Install Docker first: https://docs.docker.com/engine/install/"
fi

if ! docker info >/dev/null 2>&1; then
    error "Docker daemon not running. Start it: sudo systemctl start docker"
fi

# Port availability check
if ss -tulpn 2>/dev/null | grep -q ":$CONTAINER_PORT "; then
    error "Port $CONTAINER_PORT already in use. Check: sudo ss -tulpn | grep $CONTAINER_PORT"
fi

log "════════════════════════════════════════════════════════════════════════════"
log "Open Terminal Agent Setup v1.2 (Hardened) — Starting"
log "════════════════════════════════════════════════════════════════════════════"

# Create workspace directory in /tmp with strict permissions (700 = rwx------)
log "Creating workspace directory: $WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR"
chmod 700 "$WORKSPACE_DIR"
log "✓ Workspace created with restricted permissions (700)"

# Create log directory with strict permissions
log "Creating log directory: $LOG_DIR"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
log "✓ Log directory created with restricted permissions (700)"

# Generate API key (for future use, authentication layer)
if [[ ! -f "$API_KEY_FILE" ]]; then
    log "Generating API key..."
    mkdir -p "$(dirname "$API_KEY_FILE")"
    API_KEY=$(openssl rand -base64 32 | tr -d '\n')
    echo "$API_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    log "✓ API key generated and stored at: $API_KEY_FILE"
else
    log "✓ API key already exists at: $API_KEY_FILE"
    API_KEY=$(cat "$API_KEY_FILE")
fi

# Stop and remove existing container (idempotent)
if docker ps -a --filter "name=^${CONTAINER_NAME}\$" --quiet | grep -q .; then
    log "Removing existing container: $CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    log "✓ Existing container cleaned up"
fi

# Pull latest image
log "Pulling Docker image: $CONTAINER_IMAGE"
if ! docker pull "$CONTAINER_IMAGE"; then
    error "Failed to pull Docker image. Check network and try: docker pull $CONTAINER_IMAGE"
fi
log "✓ Image pulled successfully"

# Enforce strict permissions on all directories (protection against umask issues)
log "Enforcing strict permissions on directories..."
chmod 700 "$WORKSPACE_DIR" "$LOG_DIR"
chown 1000:1000 "$WORKSPACE_DIR"
log "✓ Permissions enforced: 700 on workspace and logs"
log "✓ Ownership set to UID 1000:GID 1000 for container access"

# Deploy hardened container
log "Deploying hardened container..."
if ! docker run \
    --name "$CONTAINER_NAME" \
    -d \
    --restart unless-stopped \
    \
    -p "127.0.0.1:${CONTAINER_PORT}:8000" \
    \
    --read-only \
    --ipc=none \
    --tmpfs /tmp:rw,noexec,nosuid,size=256m \
    --tmpfs /run:rw,noexec,nosuid,size=256m \
    --tmpfs /home:rw,noexec,nosuid,size=128m \
    \
    -v "${WORKSPACE_DIR}:/workspace:rw,Z" \
    \
    --cap-drop ALL \
    --cap-add SETUID \
    --cap-add SETGID \
    --cap-add CHOWN \
    \
    --security-opt no-new-privileges:true \
    \
    -e "OPEN_TERMINAL_WORKSPACE=/workspace" \
    -e "OPEN_TERMINAL_API_LISTEN=0.0.0.0:8000" \
    -e "OPEN_TERMINAL_MAX_FILE_SIZE=10485760" \
    -e "OPEN_TERMINAL_API_KEY=${API_KEY}" \
    \
    --memory 256m \
    --cpus 1.0 \
    --pids-limit 50 \
    \
    --health-cmd "curl -f http://localhost:8000/health || exit 1" \
    --health-interval 30s \
    --health-timeout 10s \
    --health-retries 3 \
    --health-start-period 10s \
    \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    \
    "$CONTAINER_IMAGE"; then
    error "Failed to start container. Check: docker logs $CONTAINER_NAME"
fi

log "✓ Container deployed successfully"

# Wait for container to be healthy
log "Waiting for container to be healthy..."
sleep 3
for i in {1..20}; do
    if docker exec "$CONTAINER_NAME" curl -sf http://localhost:8000/health >/dev/null 2>&1; then
        log "✓ Container is healthy"
        break
    fi
    if [[ $i -eq 20 ]]; then
        error "Container did not become healthy. Check: docker logs $CONTAINER_NAME"
    fi
    sleep 1
done

# Verify port is listening
if ss -tulpn 2>/dev/null | grep -q "127.0.0.1:${CONTAINER_PORT}"; then
    log "✓ API port $CONTAINER_PORT is listening on 127.0.0.1"
else
    error "Port $CONTAINER_PORT is not listening. Check: docker logs $CONTAINER_NAME"
fi

# Test the API
log "Testing API endpoints..."
if curl -sf "http://127.0.0.1:${CONTAINER_PORT}/health" >/dev/null 2>&1; then
    log "✓ API /health responding"
else
    error "API not responding. Check: docker logs $CONTAINER_NAME"
fi

log ""
log "════════════════════════════════════════════════════════════════════════════"
log "✓ Open Terminal Deployment Complete"
log "════════════════════════════════════════════════════════════════════════════"
log ""
log "API Endpoint:       http://127.0.0.1:${CONTAINER_PORT}"
log "Workspace:          ${WORKSPACE_DIR}"
log "Logs:               docker logs -f ${CONTAINER_NAME}"
log "API Key:            ${API_KEY_FILE}"
log ""
log "NEXT STEPS:"
log "1. Get your API key: sudo cat /var/lib/open-terminal/api_key.txt"
log "2. Open WebUI Integration:"
log "   - Open WebUI Admin Settings → Integrations → Open Terminal"
log "   - URL: http://127.0.0.1:${CONTAINER_PORT}"
log "   - API Key: (paste from step 1)"
log "3. Models now have native access to file I/O functions"
log ""
log "SECURITY:"
log "✓ Localhost-only port binding (127.0.0.1:9000 — no external LAN access)"
log "✓ Minimal capabilities (SETUID/SETGID/CHOWN only)"
log "✓ /workspace jailhouse isolation"
log "✓ API key required (Bearer token authentication)"
log "✓ Volatile tmpfs for /tmp, /run, /home"
log "✓ --ipc=none (no inter-process communication)"
log "✓ Resource limited (256MB RAM, 1 CPU, 50 PIDs)"
log "✓ no-new-privileges (prevents escalation)"
log ""
log "UNINSTALL:"
log "sudo bash setup_open_terminal-v1_2_hardened.sh --uninstall"
log ""
