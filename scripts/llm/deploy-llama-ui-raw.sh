#!/bin/bash
# llama-ui standalone container deployment — raw docker run
# Target: GPU Box (Nobara, 192.168.0.227)
# Inference backend: Ollama bare metal (127.0.0.1:11434)
# Frontend: SvelteKit WebUI (:9999)

set -e

echo "Starting llama-ui container..."
sudo docker run -d \
  --name llama-ui \
  --restart always \
  --network host \
  -e OLLAMA_BASE_URL="http://127.0.0.1:11434" \
  -e PORT="9999" \
  ghcr.io/ggml-org/llama.cpp:server

# Wait for startup
sleep 3

# Verify both containers running
echo ""
echo "=== Container Status ==="
sudo docker ps | grep -E "open-webui|llama-ui" || echo "⚠ Check docker ps manually"

# Test endpoints
echo ""
echo "=== Endpoint Tests ==="
curl -s http://127.0.0.1:8080 > /dev/null && echo "✓ Open WebUI (8080)" || echo "✗ Open WebUI (8080)"
curl -s http://127.0.0.1:9999 > /dev/null && echo "✓ llama-ui (9999)" || echo "✗ llama-ui (9999)"

# Access URLs
echo ""
echo "=== Browser Access ==="
echo "Open WebUI:  http://192.168.0.227:8080"
echo "llama-ui:    http://192.168.0.227:9999"
echo ""
echo "Models discovered from Ollama:"
echo "  - DeepSeek-R1 14B"
echo "  - Qwen 2.5 Coder 14B"
