#!/usr/bin/env bash
# llama-hot-swap-v1.0.sh — hot-swap a llama-server systemd unit to any GGUF model
#
# Generalized 2026-11-10 (at Michael's direction) from
# phi-4-mini-hot-swap-v1.0.sh, the 2026-11-09 cleanup of the original phi.sh
# Michael ran on cpu-llm (OptiPlex 790, Linux Mint). The original is kept
# forever, byte for byte, at ~/workspace/user/files/phi.sh, and the
# Phi-specific refinement stays beside this file. Same job as both, same
# safety machinery; the model is now a parameter instead of a constant.
#
# What it does: resolves the requested model (registry name, Hugging Face
# spec, direct URL, or a local .gguf file), downloads it atomically if it is
# not already present, pins its SHA-256 trust-on-first-use and verifies it on
# every later run, stops llama-server, rewrites its systemd unit (the old
# unit is backed up first) to serve the model, restarts, polls /health, reads
# the served model id from /v1/models, and runs a test completion. Any
# failure after the unit write rolls back to the backed-up unit and restarts
# the old service.
#
# Usage:
#   sudo ./llama-hot-swap-v1.0.sh [--check] [MODEL_SPEC]
#
# MODEL_SPEC forms:
#   (none)                    the default registry model, phi-4-mini
#   phi-4-mini                a registry name (the registry is below; add
#                             models to it as MODEL_URL lines)
#   hf:owner/repo:file.gguf   any GGUF on Hugging Face, in llama.cpp's own
#                             -hf notation; the file part is required
#                             because the download URL names the exact file
#   https://.../file.gguf     a direct download URL
#   /path/to/file.gguf        a local file already on disk (no download)
# MODEL_URL and MODEL_NAME environment variables override the spec.
#
# Portability notes (what changed from the Phi-only script):
#   - The downloader is curl when present, wget otherwise (the Phi script
#     required wget); the checksum tool is sha256sum, falling back to
#     shasum -a 256.
#   - The binary probe tries PATH first, then the known layouts (the v1.5
#     per-user build trees and the repo v2.1 /opt layout).
#   - The unit's WorkingDirectory follows SERVICE_USER (root: /root, any
#     other user: /home/<user>) instead of being hard-coded to /root;
#     WORK_DIR overrides it.
#   - CTX_SIZE, BATCH_SIZE, and HOST_BIND are environment-overridable like
#     the existing SERVICE_USER, MODELS_DIR, THREADS, and SERVER_PORT.
#   - UNIT_FILE and LOG_FILE are overridable, which is also what lets the
#     test battery run the script end to end against stubs.
#
# Environment overrides: SERVICE_USER, MODELS_DIR, THREADS, SERVER_PORT,
# CTX_SIZE, BATCH_SIZE, HOST_BIND, WORK_DIR, UNIT_FILE, LOG_FILE,
# MODEL_URL, MODEL_NAME.
#
# Top models for cpu-llm (OptiPlex 790: Core i5-2400, 4 cores/4 threads,
# 8 GB RAM, CPU-only, no AVX2). All are bartowski GGUF builds at Q4_K_M;
# repo ids, file names, and sizes verified against the Hugging Face API
# on 2026-11-10. The ceiling on this box is RAM: model file plus the
# 4096-token KV cache plus the OS must fit in 8 GB, and every extra
# billion parameters costs generation speed on 4 Sandy Bridge threads.
# Each name below is a registry key: swap with
#   sudo ./llama-hot-swap-v1.0.sh <name>
#
#   phi-4-mini    microsoft Phi-4-mini-instruct, 2.49 GB. The incumbent:
#                 what cpu-llm serves today and the script's default.
#                 Strongest reasoning of the 2-3B class at this size.
#   qwen2.5-7b    Qwen2.5 7B Instruct, 4.68 GB. The quality ceiling for
#                 this box: the largest model that fits with OS headroom.
#                 Also the slowest here; expect a few tokens a second.
#   llama-3.2-3b  Meta Llama 3.2 3B Instruct, 2.02 GB. Fast, well-rounded
#                 chat model; the broadest tooling and prompt ecosystem.
#   qwen2.5-3b    Qwen2.5 3B Instruct, 1.93 GB. Best coding and math of
#                 the small tier, and the only one here whose native
#                 context goes far past this script's 4096 default.
#   gemma-2-2b    Google Gemma 2 2B it, 1.71 GB. Light and quick; good
#                 when responsiveness matters more than depth.
#   llama-3.2-1b  Meta Llama 3.2 1B Instruct, 0.81 GB. Smoke-test model:
#                 the fastest possible end-to-end check of the serving
#                 stack when quality does not matter.

set -euo pipefail

readonly SERVICE_NAME="llama-server"
readonly SERVICE_USER="${SERVICE_USER:-root}"
readonly SERVER_PORT="${SERVER_PORT:-8080}"
readonly HOST_BIND="${HOST_BIND:-0.0.0.0}"
readonly THREADS="${THREADS:-$(nproc)}"
readonly CTX_SIZE="${CTX_SIZE:-4096}"
readonly BATCH_SIZE="${BATCH_SIZE:-512}"
readonly LOG_FILE="${LOG_FILE:-/var/log/llama-hot-swap.log}"
readonly UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"

# The service user's home, for WorkingDirectory: root is /root, everyone
# else is /home/<user> on every layout this fleet uses.
if [[ -n "${WORK_DIR:-}" ]]; then
  readonly WORK_DIR
elif [[ "$SERVICE_USER" == "root" ]]; then
  readonly WORK_DIR="/root"
else
  readonly WORK_DIR="/home/${SERVICE_USER}"
fi

# The model registry: name -> direct GGUF download URL. Add a line per
# model you swap to often; anything else works via the hf:, URL, and
# local-file spec forms.
declare -A MODEL_REGISTRY=(
  ["phi-4-mini"]="https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"
  ["llama-3.2-3b"]="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
  ["llama-3.2-1b"]="https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
  ["qwen2.5-3b"]="https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
  ["qwen2.5-7b"]="https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
  ["gemma-2-2b"]="https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
)
readonly DEFAULT_MODEL="phi-4-mini"

DRY_RUN=0
SPEC=""
for arg in "$@"; do
  case "$arg" in
    --check) DRY_RUN=1 ;;
    -*) echo "usage: $0 [--check] [MODEL_SPEC]" >&2; exit 2 ;;
    *)
      [[ -z "$SPEC" ]] || { echo "usage: $0 [--check] [MODEL_SPEC]" >&2; exit 2; }
      SPEC="$arg"
      ;;
  esac
done
SPEC="${SPEC:-$DEFAULT_MODEL}"

refuse() { echo "REFUSING: $*" >&2; exit 1; }

# --- Resolve the spec to MODEL_NAME + MODEL_URL (or a local file) ---
LOCAL_FILE=""
if [[ -n "${MODEL_URL:-}" ]]; then
  : "${MODEL_NAME:?MODEL_NAME must be set when MODEL_URL is}"
elif [[ -v MODEL_REGISTRY["$SPEC"] ]]; then
  MODEL_URL="${MODEL_REGISTRY[$SPEC]}"
  MODEL_NAME="$(basename "${MODEL_URL%.gguf}")"
elif [[ "$SPEC" == hf:* ]]; then
  hf="${SPEC#hf:}"
  repo="${hf%:*}"
  file="${hf##*:}"
  [[ "$repo" != "$file" && "$file" == *.gguf ]] || refuse "hf: spec must be hf:owner/repo:file.gguf (got: $SPEC)."
  MODEL_URL="https://huggingface.co/${repo}/resolve/main/${file}"
  MODEL_NAME="${file%.gguf}"
elif [[ "$SPEC" == http://* || "$SPEC" == https://* ]]; then
  MODEL_URL="$SPEC"
  MODEL_NAME="$(basename "${SPEC%.gguf}")"
elif [[ "$SPEC" == *.gguf ]]; then
  [[ -f "$SPEC" ]] || refuse "local model file not found: $SPEC"
  LOCAL_FILE="$SPEC"
  MODEL_NAME="$(basename "${SPEC%.gguf}")"
else
  refuse "unknown model spec: $SPEC (registry names: ${!MODEL_REGISTRY[*]}; or hf:owner/repo:file.gguf, a URL, or a local .gguf path)."
fi
readonly MODEL_NAME
[[ -n "$LOCAL_FILE" ]] || readonly MODEL_URL

# The models dir follows the invoking user: sudo's target user first,
# then the current user. Overridable via MODELS_DIR.
if [[ -n "${MODELS_DIR:-}" ]]; then
  readonly MODELS_DIR
elif [[ -n "${SUDO_USER:-}" ]]; then
  readonly MODELS_DIR="/home/${SUDO_USER}/models"
else
  readonly MODELS_DIR="${HOME:-/root}/models"
fi
if [[ -n "$LOCAL_FILE" ]]; then
  readonly MODEL_FILE="$LOCAL_FILE"
else
  readonly MODEL_FILE="${MODELS_DIR}/${MODEL_NAME}.gguf"
fi
readonly HASH_FILE="${MODEL_FILE}.sha256"

# Checksum tool: sha256sum, falling back to shasum -a 256.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  refuse "no checksum tool found (need sha256sum or shasum)."
fi

run() {
  printf '+ %s\n' "$*"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "$msg"
  else
    echo "$msg" | tee -a "$LOG_FILE"
  fi
}

[[ "$EUID" -eq 0 ]] || refuse "run as root (sudo)."

# Find the llama-server binary: PATH first, then the known layouts (the
# v1.5 per-user build trees, then the repo v2.1 /opt layout).
BINARY_PATH=""
if command -v llama-server >/dev/null 2>&1; then
  BINARY_PATH="$(command -v llama-server)"
else
  for p in "/root/projects/llama.cpp/build/bin/llama-server" \
           "${HOME:-/root}/projects/llama.cpp/build/bin/llama-server" \
           "/opt/llama.cpp/bin/llama-server" \
           "/usr/local/bin/llama-server" "/usr/bin/llama-server"; do
    if [[ -f "$p" ]]; then
      BINARY_PATH="$p"
      break
    fi
  done
fi
[[ -n "$BINARY_PATH" ]] || refuse "llama-server binary not found on PATH or in any known layout."

log "Starting hot-swap to ${MODEL_NAME}..."
log "Binary: $BINARY_PATH"
log "Model: $MODEL_FILE"

# --- Model: atomic download, SHA-256 pinned on first fetch ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -f "$MODEL_FILE" ]]; then
    echo "+ model present at $MODEL_FILE; verify its SHA-256 against $HASH_FILE"
  else
    echo "+ download $MODEL_URL to ${MODEL_FILE}.part, move into place, pin its SHA-256 to $HASH_FILE"
  fi
else
  run mkdir -p "$MODELS_DIR"
  if [[ -f "$MODEL_FILE" ]]; then
    if [[ -f "$HASH_FILE" ]]; then
      expected="$(cat "$HASH_FILE")"
      actual="$(sha256_of "$MODEL_FILE")"
      [[ "$actual" == "$expected" ]] || refuse "model checksum mismatch: $MODEL_FILE does not match $HASH_FILE. Delete the file and re-run."
      log "Model already present, checksum verified."
    else
      actual="$(sha256_of "$MODEL_FILE")"
      echo "$actual" > "$HASH_FILE"
      log "Model already present; pinned its SHA-256 to $HASH_FILE."
    fi
  else
    log "Downloading model..."
    log "URL: $MODEL_URL"
    if command -v curl >/dev/null 2>&1; then
      run curl -fL --progress-bar "$MODEL_URL" -o "${MODEL_FILE}.part" || refuse "download failed. Try manual: curl -fL $MODEL_URL -o $MODEL_FILE"
    elif command -v wget >/dev/null 2>&1; then
      run wget --show-progress "$MODEL_URL" -O "${MODEL_FILE}.part" || refuse "download failed. Try manual: wget $MODEL_URL"
    else
      refuse "no downloader found (need curl or wget)."
    fi
    run mv "${MODEL_FILE}.part" "$MODEL_FILE"
    actual="$(sha256_of "$MODEL_FILE")"
    echo "$actual" > "$HASH_FILE"
    log "Download complete; SHA-256 pinned to $HASH_FILE."
  fi
fi

# --- Stop, rewrite the unit (backed up), restart ---
BACKUP=""
if [[ -f "$UNIT_FILE" ]]; then
  BACKUP="${UNIT_FILE}.bak-$(date '+%Y%m%d-%H%M%S')"
  run cp "$UNIT_FILE" "$BACKUP"
  log "Backed up existing unit to $BACKUP"
fi

log "Stopping current service..."
run systemctl stop "$SERVICE_NAME" || refuse "failed to stop $SERVICE_NAME."

write_unit() {
  cat > "$1" <<SVCEOF
[Unit]
Description=llama.cpp inference server (${MODEL_NAME})
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$WORK_DIR
ExecStart=$BINARY_PATH --model "$MODEL_FILE" --host $HOST_BIND --port $SERVER_PORT --threads $THREADS --ctx-size $CTX_SIZE --batch-size $BATCH_SIZE
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  # Render the unit to a throwaway file only: --check must never touch the
  # real unit path, not even briefly.
  preview="$(mktemp)"
  write_unit "$preview"
  echo "+ write $UNIT_FILE with this content:"
  cat "$preview"
  rm -f "$preview"
else
  write_unit "$UNIT_FILE"
fi

run systemctl daemon-reload
log "Starting service with new model..."
rollback() {
  if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    cp "$BACKUP" "$UNIT_FILE"
    systemctl daemon-reload
    systemctl start "$SERVICE_NAME" || true
    log "Rolled back to the previous unit ($BACKUP)."
  fi
}

if ! run systemctl start "$SERVICE_NAME"; then
  log "systemctl start failed; rolling back."
  rollback
  exit 1
fi

# --- Verify: poll /health, then a test completion ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "+ poll http://127.0.0.1:$SERVER_PORT/health, then POST /v1/chat/completions"
  log "Dry run complete; nothing was changed."
  exit 0
fi

healthy=0
for _ in $(seq 1 15); do
  if curl -sf "http://127.0.0.1:$SERVER_PORT/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [[ "$healthy" -eq 0 ]]; then
  log "Service did not answer /health; rolling back."
  rollback
  log "Check logs: journalctl -u $SERVICE_NAME -n 20"
  exit 1
fi

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  log "Service is not active; rolling back."
  rollback
  log "Check logs: journalctl -u $SERVICE_NAME -n 20"
  exit 1
fi

log "Service is running."
MODEL_TAG="$(curl -s "http://127.0.0.1:$SERVER_PORT/v1/models" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
MODEL_TAG="${MODEL_TAG:-$MODEL_NAME}"
log "Detected model name: $MODEL_TAG"
log "Testing API..."
response="$(curl -s -X POST "http://127.0.0.1:$SERVER_PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_TAG\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello, verify connection.\"}],\"max_tokens\":10}")"
echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
case "$response" in
  *'"choices"'*) log "Hot-swap complete." ;;
  *) log "Test completion returned no choices; rolling back."; rollback; exit 1 ;;
esac
