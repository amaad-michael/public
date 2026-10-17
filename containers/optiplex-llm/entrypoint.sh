#!/bin/sh
# optiplex-llm entrypoint: fetch + verify the model, then serve it.
#
# Runs in the llama.cpp server image itself (the image ships curl and
# sha256sum), so the stack stays a single pinned image. On every start:
#   1. If the model file is missing from the /models volume, download
#      it to a .part file and move it into place only when complete.
#      Interrupted transfers resume (curl -C -) across attempts and
#      across restarts; an attempt that makes no progress discards
#      the partial and starts fresh.
#   2. Verify the model against MODEL_SHA256. A mismatch is fatal:
#      the stack never serves an unverified model.
#   3. Assemble the llama-server flags from the environment (the same
#      flags the OptiPlex playbook's systemd unit uses) and exec.
#
# Working directory matters: the llama-server launcher's RUNPATH ends
# in an empty element, so libllama-server-impl.so resolves relative to
# the working directory. The image's WorkingDir is /app and the impl
# libraries live there; cd to /app before exec or the binary cannot
# load its own libraries.
set -eu

MODELS_DIR=/models
MODEL_NAME=${MODEL_NAME:-Llama-3.2-3B-Instruct-Q4_K_M}
MODEL_URL=${MODEL_URL:-https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf}
MODEL_SHA256=${MODEL_SHA256:-6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff}
CTX_SIZE=${CTX_SIZE:-4096}
TEMP=${TEMP:-0.2}
TOP_P=${TOP_P:-0.95}
MIN_P=${MIN_P:-0.01}
MLOCK=${MLOCK:-1}
THREADS=${THREADS:-0}
API_KEY=${API_KEY:-}
CORS_ORIGINS=${CORS_ORIGINS:-}
MODEL_FILE=$MODELS_DIR/$MODEL_NAME.gguf

verify_model() {
    if [ -z "$MODEL_SHA256" ]; then
        echo "WARNING: MODEL_SHA256 is empty - model is NOT verified" >&2
        return 0
    fi
    printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_FILE" | sha256sum -c -
}

if [ -f "$MODEL_FILE" ]; then
    echo "Model present in volume: $MODEL_FILE"
    if ! verify_model; then
        echo "ERROR: existing model failed SHA-256 verification." >&2
        echo "Refusing to serve an unverified model. Fix MODEL_SHA256," >&2
        echo "or remove the file from the volume to force a fresh download:" >&2
        echo "  $MODEL_FILE" >&2
        exit 1
    fi
else
    part_file=$MODEL_FILE.part
    echo "Downloading model: $MODEL_URL"
    downloaded=0
    attempt=1
    last_size=0
    while [ "$attempt" -le 5 ]; do
        if curl -fSL -C - --output "$part_file" "$MODEL_URL"; then
            downloaded=1
            break
        fi
        size=0
        if [ -f "$part_file" ]; then
            size=$(wc -c < "$part_file")
        fi
        echo "Download attempt $attempt failed (bytes so far: $size)" >&2
        if [ "$size" -le "$last_size" ]; then
            rm -f "$part_file"
            last_size=0
        else
            last_size=$size
        fi
        attempt=$((attempt + 1))
        sleep 3
    done
    if [ "$downloaded" -ne 1 ]; then
        echo "ERROR: model download did not complete after 5 attempts." >&2
        exit 1
    fi
    mv "$part_file" "$MODEL_FILE"
    if ! verify_model; then
        echo "ERROR: downloaded model failed SHA-256 verification." >&2
        echo "Removing the unverified file and refusing to serve it." >&2
        rm -f "$MODEL_FILE"
        exit 1
    fi
fi

# "$@" at this point holds any extra llama-server flags passed as the
# compose command; they are appended last so they win over the defaults
# assembled here.
set -- --model "$MODEL_FILE" \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size "$CTX_SIZE" \
    --temp "$TEMP" \
    --top-p "$TOP_P" \
    --min-p "$MIN_P" \
    "$@"

if [ "$THREADS" -gt 0 ]; then
    set -- "$@" --threads "$THREADS" --threads-batch "$THREADS"
fi

if [ "$MLOCK" = "1" ]; then
    # llama.cpp b11681 removed the old --mlock flag; the playbook-era
    # behavior (mmap the model, then lock the pages) is now a load mode.
    set -- "$@" --load-mode mmap+mlock
fi

if [ -n "$API_KEY" ]; then
    set -- "$@" --api-key "$API_KEY"
fi

if [ -n "$CORS_ORIGINS" ]; then
    set -- "$@" --cors-origins "$CORS_ORIGINS"
fi

cd /app
exec ./llama-server "$@"
