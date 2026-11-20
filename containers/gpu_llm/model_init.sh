#!/bin/sh
# model-init — pull every model in $OLLAMA_MODELS into the Ollama
# service, once, then exit.
#
# Runs in the Ollama image itself (bind-mounted by docker-compose.yml)
# and drives the image's own CLI against the ollama service on the
# compose network ($OLLAMA_HOST, set in the compose file). `ollama
# pull` is idempotent — a model already present in the server's
# volume is a fast no-op — so re-running this service after editing
# OLLAMA_MODELS only fetches what is missing. A failed pull aborts
# the run with a nonzero exit; nothing is half-configured.
set -eu

: "${OLLAMA_HOST:?OLLAMA_HOST must point at the ollama service}"
export OLLAMA_HOST

models=${OLLAMA_MODELS:-qwen2.5-coder:14b,qwen2.5-coder:7b,deepseek-r1:14b,nomic-embed-text:latest,llava:13b}

# Split the comma-separated list. Word splitting is the mechanism
# here, not an accident: model names never contain spaces or globs.
# shellcheck disable=SC2046
set -- $(printf '%s' "$models" | tr ',' ' ')

for model in "$@"; do
    echo "model-init: pulling $model"
    ollama pull "$model"
done

echo "model-init: all models present"
ollama list
