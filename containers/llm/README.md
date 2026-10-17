# llm — llama.cpp inference pool

The container form of the Ansible LLM stack in
`ansible/playbooks/llm/`: llama.cpp inference backends behind an nginx
load balancer. Same architecture, same config design, no source build
and no systemd.

| Ansible original | This stack |
| --- | --- |
| `llm-server-setup.yml` (per-board llama-server, port 8080) | `llm-heavy` and `llm-light` services |
| `llama-server.service.j2` (model, host, port, threads, ctx, n-predict) | compose `command:` + `.env` values |
| `llm-lb-setup.yml` + `llm-lb.conf.j2` (nginx LB, `least_conn`) | `llm-lb` service + `llm-lb.conf` |
| Models downloaded to `~/models` on each board | Host models directory mounted read-only at `/models` |

The two backends mirror his two NanoPi boards: the heavy node serves
the 7B model the 4GB board runs, the light node the 1.5B model from
the 2GB board. The load balancer prefers whichever backend is least
busy (`least_conn`, the Jinja original's choice, made so heavy
requests avoid the lighter board). Only the LB publishes a host port;
the backends are reachable only on the stack network.

Two deliberate adaptations from the bare-metal original, both in
`llm-lb.conf`: nginx listens on 8080 inside the container instead of
80 (so it needs no privileged port; the host port is mapped), and the
proxy speaks HTTP/1.1 with an empty `Connection` header so
llama-server's chunked token streams are not de-chunked and buffered
by the nginx HTTP/1.0 proxy default.

## Images

- Inference: `ghcr.io/ggml-org/llama.cpp:server-b11681` — the official
  llama.cpp server image at a pinned build (the project publishes a
  floating `server` tag; this stack pins the build instead). CPU
  build, multi-arch (amd64 and arm64), so it runs on the ARM boards
  and on x86 hosts alike. Entrypoint is `llama-server` itself,
  defaulting to `0.0.0.0:8080`.
- Load balancer: `nginx:1.30.6-alpine` — the stable branch, pinned.

GPU acceleration is out of scope for this stack, the same as the
NanoPi original: these are the CPU builds. Upstream also publishes
`server-cuda` and `server-vulkan` variants for the GPU box; swapping
one in is an image change plus a device reservation, and is not part
of this mirror.

## Models

Models are large host files and are never baked into an image.
Download them into one directory on the host (the playbooks fetch
them from Hugging Face; the names below are theirs):

```bash
mkdir -p ~/models
cd ~/models
curl -LO https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf
curl -LO https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf
```

Any GGUF files work — set the filenames in `.env` to whatever you
placed in the models directory.

## 🛠️ Setup

1. Copy `llm-env.example` to `.env`, set `LLM_MODELS_DIR` to the
   models directory, confirm the two model filenames, and
   `chmod 600 .env`. Compose refuses to render or start while a model
   filename is unset, so a missing value fails closed instead of
   starting a backend against the wrong file.
1. Start the stack: `docker compose up -d`. The backends publish no
   host ports; the LB waits for both backends to report healthy
   before it starts.
1. Verify with the canary below before trusting it.

## ✅ Verification (canary)

The LB health endpoint answers without touching a backend:

```bash
curl http://localhost:8090/lb-health
```

Expected: `llm-lb ok`.

Backend health, through the LB (returns llama-server's JSON health
once a backend has loaded its model):

```bash
curl http://localhost:8090/health
```

A completion smoke test through the LB:

```bash
curl http://localhost:8090/completion \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "The capital of Texas is", "n_predict": 16}'
```

Expected: a JSON response whose `content` continues the prompt. For a
first run before the Qwen models are downloaded, the tiny
`stories15M-q4_0.gguf` test model from the `ggml-org/tiny-llamas`
Hugging Face repo (about 19 MB) proves the whole path — point both
model variables at it, run the same three checks, then switch back.

## 🔧 Operations

- One backend only: delete or comment the other backend service and
  its `llm-lb.conf` upstream line, and drop the matching `depends_on`
  entry. The pool works with a single server line.
- Logs: `docker compose logs -f llm-heavy llm-light llm-lb`.
- Updates: bump the pinned tags in `docker-compose.yml`, then
  `docker compose pull && docker compose up -d`. Models are host
  files; replacing one never rebuilds anything.
- Port map: host 8090 (or `LLM_LB_PORT`) to the LB only. If another
  stack ever claims 8090 on the same host, change `LLM_LB_PORT` in
  `.env` — nothing else references the host port.
