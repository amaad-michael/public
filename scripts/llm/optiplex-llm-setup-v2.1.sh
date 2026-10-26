#!/bin/bash
# optiplex-llm-setup-v2.1.sh
# OptiPlex llama.cpp deployment — Sandy Bridge / dual-channel DDR3 @ 1067 MT/s / CPU-only

set -euo pipefail

# Root check runs BEFORE anything touches $LOG_FILE (log() writes via tee).
[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)" >&2; exit 1; }

# ────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_VERSION="2.1.0"
LOG_FILE="/var/log/optiplex-llm-setup.log"

# Install locations. Deliberately outside any user home: home-directory
# permissions were the real cause of the 203/EXEC and "Permission denied"
# failures that v1.5 worked around by running the service as root.
LLAMA_DIR="/opt/llama.cpp"
MODELS_DIR="/var/lib/llm/models"
CONF_DIR="/etc/llm"

LLM_USER="llm"
SERVER_PORT="8080"

# i5-2400 is 4 cores / 4 threads. No hyperthreading — 4 is the ceiling.
THREADS="${THREADS:-$(nproc)}"

# 127.0.0.1 keeps the inference API off the LAN. Set to 0.0.0.0 to expose it;
# a LAN-scoped ufw rule and a CORS restriction are then added. The API key is
# governed separately by REQUIRE_API_KEY and is generated either way.
BIND_ADDR="127.0.0.1"
REQUIRE_API_KEY="yes"

# Model selection. See the bandwidth table: at the measured 1067 MT/s the 8B
# preset is bounded near 2.6 t/s and the 3B preset near 6.3 t/s.
MODEL_PRESET="${MODEL_PRESET:-llama3.2-3b}"

# BLAS accelerates prompt ingestion above batch 32; it does NOT change token
# generation speed on a CPU-only build. Off by default.
ENABLE_BLAS="no"

# Page-lock the weights. Defaults per preset (see Memory Budget); override to
# "yes"/"no" to force. Locking prevents the model being paged out, at the cost
# of making everything else the first thing evicted.
USE_MLOCK="${USE_MLOCK:-}"

# RISK-1 closed 2026-10-26: pinned to a release tag instead of the moving
# master branch. Bump deliberately — change this one default and re-run.
# The resolved commit is written to $LOG_FILE on every run.
LLAMA_CPP_REF="${LLAMA_CPP_REF:-b11907}"
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp"

case "$MODEL_PRESET" in
    llama3.2-3b)
        MODEL_NAME="Llama-3.2-3B-Instruct-Q4_K_M"
        MODEL_URL="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        CTX_SIZE="4096"
        # ~2.6 GiB resident against ~6.3 GiB free: locking is safe.
        PRESET_MLOCK="yes"
        ;;
    llama3.1-8b)
        MODEL_NAME="Meta-Llama-3.1-8B-Instruct-Q4_K_M"
        MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
        CTX_SIZE="2048"
        # ~5.1 GiB resident against ~6.3 GiB free on this 8GB box. Locking
        # 4.58 GiB would push every other process out under pressure.
        PRESET_MLOCK="no"
        ;;
    *)
        echo "ERROR: unknown MODEL_PRESET '$MODEL_PRESET' (llama3.2-3b | llama3.1-8b)" >&2
        exit 1
        ;;
esac
MODEL_FILE="$MODELS_DIR/${MODEL_NAME}.gguf"
[[ -n "$USE_MLOCK" ]] || USE_MLOCK="$PRESET_MLOCK"

# Expected SHA-256 of the .gguf. Empty on first run: the script hashes the
# file once, logs the value and caches it beside the model as <model>.sha256,
# then warns on later runs instead of re-hashing. Paste the value back here to
# turn the warning into real verification.
# INSUFFICIENT CONTEXT — upstream publishes no checksum manifest for these
# files, so this must be captured from a known-good download.
MODEL_SHA256=""

# ────────────────────────────────────────────────────────────────────────────
# LOGGING
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

log "════════════════════════════════════════════════════════════════"
log "OptiPlex llama.cpp Setup v$SCRIPT_VERSION"
log "════════════════════════════════════════════════════════════════"

# ────────────────────────────────────────────────────────────────────────────
# PLATFORM VALIDATION
# ────────────────────────────────────────────────────────────────────────────

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] || error "Only x86_64 supported. Found: $ARCH"
command -v apt-get &>/dev/null || error "This script targets apt-based systems (Ubuntu / Linux Mint)"

# Report the actual instruction set rather than assuming anything. On an
# i5-2400 this is AVX only — no AVX2 (Haswell), no F16C (Ivy Bridge), no FMA
# (Haswell). GGML_NATIVE selects the right kernels from what is present.
CPU_MODEL=$(awk -F: '/^model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
CPU_FLAGS=$(awk '/^flags/ {print; exit}' /proc/cpuinfo)
HAVE_AVX="no"; HAVE_AVX2="no"; HAVE_F16C="no"
grep -qw avx  <<<"$CPU_FLAGS" && HAVE_AVX="yes"
grep -qw avx2 <<<"$CPU_FLAGS" && HAVE_AVX2="yes"
grep -qw f16c <<<"$CPU_FLAGS" && HAVE_F16C="yes"

log "CPU:        $CPU_MODEL"
log "Cores:      $(nproc) (threads configured: $THREADS)"
log "SIMD:       AVX=$HAVE_AVX AVX2=$HAVE_AVX2 F16C=$HAVE_F16C"
log "Model:      $MODEL_NAME  (preset: $MODEL_PRESET)"

if [[ "$HAVE_AVX2" == "no" ]]; then
    log "Note: no AVX2 on this CPU — expected on Sandy Bridge. GGML_NATIVE selects"
    log "      the widest kernels this CPU actually has (AVX on an i5-2400: no"
    log "      F16C, no FMA either). Do not add AVX2/FMA build flags."
fi

MEM_GIB=$(awk '/^MemTotal:/ {printf "%.1f", $2/1048576}' /proc/meminfo)
log "RAM:        ${MEM_GIB} GiB total"

# ────────────────────────────────────────────────────────────────────────────
# DEPENDENCIES
# ────────────────────────────────────────────────────────────────────────────

log "Installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /tmp/apt-update.log 2>&1 || error "apt update failed. See /tmp/apt-update.log"

# libcurl4-openssl-dev: current upstream CMakeLists.txt marks LLAMA_CURL as
# deprecated-and-ignored, so this is no longer a hard build requirement on
# master. Kept for pinned older refs (see RISK-1) that still honour the option.
APT_PKGS=(git cmake build-essential pkg-config libcurl4-openssl-dev curl ca-certificates)
[[ "$ENABLE_BLAS" == "yes" ]] && APT_PKGS+=(libopenblas-dev)

apt-get install -y "${APT_PKGS[@]}" > /tmp/apt-install.log 2>&1 \
    || error "Failed to install build tools. See /tmp/apt-install.log"

log "Toolchain: $(gcc --version | head -1 || true)"

# ────────────────────────────────────────────────────────────────────────────
# SERVICE USER
# ────────────────────────────────────────────────────────────────────────────

if id "$LLM_USER" &>/dev/null; then
    log "Service user '$LLM_USER' already exists"
else
    log "Creating system user '$LLM_USER'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$LLM_USER" \
        || error "Failed to create user $LLM_USER"
fi

install -d -m 0755 -o root -g root "$LLAMA_DIR"
install -d -m 0755 -o root -g "$LLM_USER" "$MODELS_DIR"
install -d -m 0750 -o root -g "$LLM_USER" "$CONF_DIR"

# ────────────────────────────────────────────────────────────────────────────
# BUILD LLAMA.CPP
# ────────────────────────────────────────────────────────────────────────────

SRC_DIR="/usr/local/src/llama.cpp"

if [[ -d "$SRC_DIR/.git" ]]; then
    log "Updating llama.cpp source..."
    git -C "$SRC_DIR" fetch --quiet origin || error "git fetch failed"
    git -C "$SRC_DIR" checkout --quiet "$LLAMA_CPP_REF" || error "git checkout $LLAMA_CPP_REF failed"
    git -C "$SRC_DIR" pull --quiet --ff-only origin "$LLAMA_CPP_REF" > /dev/null 2>&1 || true
else
    [[ -d "$SRC_DIR" ]] && rm -rf "$SRC_DIR"
    log "Cloning llama.cpp ($LLAMA_CPP_REF)..."
    git clone --quiet --branch "$LLAMA_CPP_REF" "$LLAMA_CPP_REPO" "$SRC_DIR" \
        > /tmp/git-clone.log 2>&1 || error "Failed to clone llama.cpp. See /tmp/git-clone.log"
fi

LLAMA_COMMIT=$(git -C "$SRC_DIR" rev-parse HEAD)
log "llama.cpp commit: $LLAMA_COMMIT"

# Rebuild when the source moved. BUILD_STAMP records what the current install
# was produced from.
BUILD_STAMP="$LLAMA_DIR/.build-commit"
NEED_BUILD="yes"
if [[ -x "$LLAMA_DIR/bin/llama-server" && -f "$BUILD_STAMP" ]]; then
    if [[ "$(cat "$BUILD_STAMP")" == "$LLAMA_COMMIT" ]]; then
        NEED_BUILD="no"
        log "llama.cpp already built at this commit — skipping build"
    else
        log "Source commit changed — rebuilding"
    fi
fi

if [[ "$NEED_BUILD" == "yes" ]]; then
    log "Configuring build (GGML_NATIVE=ON, BLAS=$ENABLE_BLAS)..."
    # Only documented, verified options. Current upstream keeps examples/,
    # tools/ and app/ side by side, and LLAMA_BUILD_EXAMPLES / LLAMA_BUILD_TOOLS /
    # LLAMA_BUILD_SERVER / LLAMA_BUILD_APP still gate their own trees (see the
    # add_subdirectory guards in the top-level CMakeLists.txt). The defaults
    # already build the server, so no build-tree toggles are needed here.
    CMAKE_ARGS=(
        -B "$SRC_DIR/build"
        -S "$SRC_DIR"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$LLAMA_DIR"
        -DGGML_NATIVE=ON
    )
    if [[ "$ENABLE_BLAS" == "yes" ]]; then
        CMAKE_ARGS+=(-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS)
    fi

    cmake "${CMAKE_ARGS[@]}" > /tmp/cmake-config.log 2>&1 \
        || error "CMake configuration failed. See /tmp/cmake-config.log"

    log "Compiling (10–25 minutes on this hardware)..."
    cmake --build "$SRC_DIR/build" --config Release -j"$(nproc)" \
        > /tmp/cmake-build.log 2>&1 \
        || error "Build failed. See /tmp/cmake-build.log"

    cmake --install "$SRC_DIR/build" > /tmp/cmake-install.log 2>&1 \
        || error "Install failed. See /tmp/cmake-install.log"

    echo "$LLAMA_COMMIT" > "$BUILD_STAMP"
fi

# `cmake --install` does not necessarily cover every tool. Reconcile from the
# build tree rather than assuming the install manifest matches expectations.
install -d -m 0755 "$LLAMA_DIR/bin"
for bin in llama-server llama-cli llama-bench; do
    if [[ ! -x "$LLAMA_DIR/bin/$bin" && -x "$SRC_DIR/build/bin/$bin" ]]; then
        install -m 0755 "$SRC_DIR/build/bin/$bin" "$LLAMA_DIR/bin/$bin"
        log "Copied $bin from the build tree (not covered by the install target)"
    fi
done

for bin in llama-server llama-cli; do
    [[ -x "$LLAMA_DIR/bin/$bin" ]] || error "$bin missing after build+install — see /tmp/cmake-build.log"
done
if [[ ! -x "$LLAMA_DIR/bin/llama-bench" ]]; then
    log "⚠ llama-bench not present — benchmarking guidance in the doc will not work"
fi
log "Binaries: $("$LLAMA_DIR/bin/llama-server" --version 2>&1 | head -1 || true)"

# ────────────────────────────────────────────────────────────────────────────
# MODEL DOWNLOAD (integrity-checked)
# ────────────────────────────────────────────────────────────────────────────

# Hashing a 2-5GB file on a 7200rpm SATA disk costs minutes. Only do it when
# there is something to check against, or once to capture the value.
HASH_MARKER="${MODEL_FILE}.sha256"

verify_model() {
    local computed
    if [[ -z "$MODEL_SHA256" ]]; then
        # -nt guards against a stale marker: if the model was replaced after
        # the marker was written, the cache is invalid and must be recomputed.
        if [[ -f "$HASH_MARKER" && "$HASH_MARKER" -nt "$MODEL_FILE" ]]; then
            log "⚠ MODEL_SHA256 unset; cached hash: $(cat "$HASH_MARKER")"
            log "  Paste it into MODEL_SHA256 to enable verification."
            return 0
        fi
        computed=$(sha256sum "$MODEL_FILE" | awk '{print $1}')
        printf '%s\n' "$computed" > "$HASH_MARKER"
        chmod 0644 "$HASH_MARKER"
        log "⚠ MODEL_SHA256 is unset. Computed hash for this file:"
        log "    $computed"
        log "  Paste it into MODEL_SHA256 to enable verification on future runs."
        return 0
    fi
    computed=$(sha256sum "$MODEL_FILE" | awk '{print $1}')
    [[ "$computed" == "$MODEL_SHA256" ]] \
        || error "Model checksum mismatch. Expected $MODEL_SHA256, got $computed. Delete $MODEL_FILE and re-run."
    log "✓ Model checksum verified"
}

if [[ -f "$MODEL_FILE" ]]; then
    log "Model present: $MODEL_FILE ($(du -h "$MODEL_FILE" | cut -f1))"
    verify_model
else
    log "Downloading $MODEL_NAME ..."
    # -L follows the HF CDN redirect; --fail turns an HTML error page into a
    # non-zero exit instead of a corrupt .gguf. Download to .part and rename
    # only on success so an interrupted run cannot leave a "valid" model.
    # -C - resumes a partial .part instead of restarting a multi-GB transfer.
    # --progress-bar gives visible feedback; v1.5's `wget --show-progress` wrote
    # to a stderr that was redirected away, so it showed nothing.
    curl -fL -C - --retry 3 --retry-delay 5 --progress-bar \
        -o "${MODEL_FILE}.part" "$MODEL_URL" \
        || error "Model download failed. Re-run to resume from ${MODEL_FILE}.part"

    mv "${MODEL_FILE}.part" "$MODEL_FILE"
    rm -f "$HASH_MARKER"        # new file: any cached hash is now stale
    log "Downloaded: $(du -h "$MODEL_FILE" | cut -f1)"
    verify_model
fi

chown root:"$LLM_USER" "$MODEL_FILE"
chmod 0640 "$MODEL_FILE"

# ────────────────────────────────────────────────────────────────────────────
# API KEY
# ────────────────────────────────────────────────────────────────────────────

API_KEY_FILE="$CONF_DIR/api-key"
EXEC_AUTH=""

if [[ "$BIND_ADDR" != "127.0.0.1" && "$REQUIRE_API_KEY" != "yes" ]]; then
    log "⚠ API exposed on $BIND_ADDR with REQUIRE_API_KEY=no — unauthenticated inference endpoint"
fi

if [[ "$REQUIRE_API_KEY" == "yes" ]]; then
    if [[ ! -f "$API_KEY_FILE" ]]; then
        # Create with final ownership and mode BEFORE writing: a plain
        # redirect would create the file at the prevailing umask (typically
        # 0644) and leave the key world-readable until the chmod landed.
        install -m 0640 -o root -g "$LLM_USER" /dev/null "$API_KEY_FILE"
        openssl rand -hex 32 > "$API_KEY_FILE"
        log "✓ API key generated: $API_KEY_FILE (root:$LLM_USER 0640)"
    else
        log "API key already present: $API_KEY_FILE"
        chown root:"$LLM_USER" "$API_KEY_FILE"
        chmod 0640 "$API_KEY_FILE"
    fi
    EXEC_AUTH="--api-key-file $API_KEY_FILE"
fi

# ────────────────────────────────────────────────────────────────────────────
# FIREWALL (only when the API leaves loopback)
# ────────────────────────────────────────────────────────────────────────────

if [[ "$BIND_ADDR" != "127.0.0.1" ]]; then
    # awk consumes all input and prints in END — an early exit would close the
    # pipe on `ip` and risk a SIGPIPE abort under pipefail.
    LAN_ADDR=$(ip -4 -o addr show scope global \
        | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap)/ && addr == "" { addr = $4 }
               END { print addr }')
    if [[ -n "$LAN_ADDR" ]]; then
        LAN_NET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$LAN_ADDR")
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow from "$LAN_NET" to any port "$SERVER_PORT" proto tcp > /dev/null \
                || error "ufw rule for ${SERVER_PORT}/tcp failed"
            log "✓ ufw: ${SERVER_PORT}/tcp allowed from $LAN_NET"
        else
            log "⚠ ufw not active — port $SERVER_PORT is open to anything that can route here"
        fi
    else
        log "⚠ Could not detect a LAN address — skipping firewall rule"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# SYSTEMD SERVICE
# ────────────────────────────────────────────────────────────────────────────

# CORS defaults to '*'. --cors-origins is a verified llama-server flag
# (tools/server/README.md); the special value 'localhost' reflects the Origin
# header only when it is localhost. Restrict it whenever the endpoint leaves
# loopback.
EXEC_CORS=""
[[ "$BIND_ADDR" != "127.0.0.1" ]] && EXEC_CORS="--cors-origins localhost"

# LimitMEMLOCK below is only meaningful when --mlock is actually passed.
EXEC_MLOCK=""
if [[ "$USE_MLOCK" == "yes" ]]; then
    EXEC_MLOCK="--mlock"
    log "Page-locking weights (--mlock) — preset: $MODEL_PRESET"
elif [[ "$USE_MLOCK" == "$PRESET_MLOCK" ]]; then
    log "Not page-locking weights — preset default for ${MODEL_PRESET}"
else
    log "Not page-locking weights — USE_MLOCK=no overrides the ${MODEL_PRESET} default"
fi

UNIT_FILE="/etc/systemd/system/llama-server.service"
UNIT_TMP="$(mktemp)"
trap 'rm -f "$UNIT_TMP"' EXIT

cat > "$UNIT_TMP" <<EOF
[Unit]
Description=llama.cpp inference server
Documentation=https://github.com/ggml-org/llama.cpp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$LLM_USER
Group=$LLM_USER
ExecStart=$LLAMA_DIR/bin/llama-server --model $MODEL_FILE --host $BIND_ADDR --port $SERVER_PORT --threads $THREADS --threads-batch $THREADS --ctx-size $CTX_SIZE --temp 0.2 --top-p 0.95 --min-p 0.01 $EXEC_MLOCK $EXEC_AUTH $EXEC_CORS
Restart=on-failure
RestartSec=10

# Only has effect when --mlock is in ExecStart; harmless otherwise.
LimitMEMLOCK=infinity

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if cmp -s "$UNIT_TMP" "$UNIT_FILE" 2>/dev/null; then
    rm -f "$UNIT_TMP"
    log "systemd unit already current"
    UNIT_CHANGED="no"
else
    install -m 0644 -o root -g root "$UNIT_TMP" "$UNIT_FILE"
    rm -f "$UNIT_TMP"
    log "✓ systemd unit written: $UNIT_FILE"
    UNIT_CHANGED="yes"
fi

systemctl daemon-reload || error "systemctl daemon-reload failed"
systemctl enable llama-server > /dev/null 2>&1 || error "Failed to enable llama-server"

if [[ "$UNIT_CHANGED" == "yes" ]]; then
    systemctl restart llama-server || error "Failed to restart llama-server"
else
    systemctl start llama-server || error "Failed to start llama-server"
fi

# ────────────────────────────────────────────────────────────────────────────
# READINESS
# ────────────────────────────────────────────────────────────────────────────

# Poll rather than sleep: loading a multi-GB model from a 7200rpm SATA disk on
# this hardware routinely exceeds any fixed wait.
log "Waiting for llama-server to load the model..."
READY="no"
for i in {1..60}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/health" 2>/dev/null; then
        READY="yes"
        break
    fi
    if ! systemctl is-active --quiet llama-server; then
        error "llama-server exited during startup. Check: journalctl -u llama-server -n 50"
    fi
    [[ $((i % 6)) -eq 0 ]] && log "  still loading (${i}0s elapsed)..."
    sleep 10
done

[[ "$READY" == "yes" ]] || error "Server did not become healthy within 10 minutes. Check: journalctl -u llama-server -n 50"
log "✓ llama-server healthy on ${BIND_ADDR}:${SERVER_PORT}"

# ────────────────────────────────────────────────────────────────────────────
# VERIFICATION
# ────────────────────────────────────────────────────────────────────────────

# The key must not appear in curl's argv, where any local user can read it
# from `ps`. --config takes it on a file descriptor instead.
CURL_CONF=$(mktemp)
trap 'rm -f "$UNIT_TMP" "$CURL_CONF"' EXIT
chmod 0600 "$CURL_CONF"
if [[ "$REQUIRE_API_KEY" == "yes" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$(cat "$API_KEY_FILE")" > "$CURL_CONF"
fi

API_RESPONSE=$(curl -fsS --config "$CURL_CONF" -X POST "http://127.0.0.1:${SERVER_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":8}' \
    2>/dev/null || echo "")

if [[ -n "$API_RESPONSE" ]]; then
    log "✓ Chat completion endpoint responding"
    printf '%s' "$API_RESPONSE" | python3 -m json.tool 2>/dev/null | head -20 | tee -a "$LOG_FILE" || true
else
    log "⚠ Chat completion test failed — check: journalctl -u llama-server -n 30"
fi

LISTEN_LINE=$(ss -tlnp 2>/dev/null | grep -E "LISTEN.*:${SERVER_PORT}[[:space:]]" || true)
if [[ -n "$LISTEN_LINE" ]]; then
    log "✓ Listening: $(awk '{print $4}' <<<"$LISTEN_LINE" | head -1)"
else
    log "⚠ Port $SERVER_PORT not listening"
fi

# ────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ────────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Setup Complete — v$SCRIPT_VERSION"
log "════════════════════════════════════════════════════════════════"
log "Model:          $MODEL_NAME"
log "Model file:     $MODEL_FILE"
log "llama.cpp:      $LLAMA_DIR  (commit $LLAMA_COMMIT)"
log "API:            http://${BIND_ADDR}:${SERVER_PORT}/v1/chat/completions"
log "Auth:           $([[ "$REQUIRE_API_KEY" == "yes" ]] && echo "API key at $API_KEY_FILE" || echo "NONE")"
log "Service user:   $LLM_USER"
log "Threads:        $THREADS"
log "Context:        $CTX_SIZE"
log "mlock:          $USE_MLOCK"
log "Log file:       $LOG_FILE"
log ""
log "Next steps:"
log "  1. Baseline throughput. Stop the service first so only one copy of the"
log "     model is resident, and use sudo — the model is 0640 root:$LLM_USER:"
log "       sudo systemctl stop llama-server"
log "       sudo $LLAMA_DIR/bin/llama-bench -m $MODEL_FILE -t $THREADS"
log "       sudo systemctl start llama-server"
log "  2. Follow logs:         journalctl -u llama-server -f"
log "  3. Record the tok/s from step 1 before changing any tuning knob"
