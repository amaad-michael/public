# GPU LLM Server (Ollama + Open WebUI + SearXNG)

The container equivalent of the GPU-box LLM deployment in
`ansible/playbooks/llm/gpu-box-llm-setup-v1.9.yml`. The playbook installs
Ollama bare-metal on a Fedora host with an AMD GPU and runs Open WebUI and
SearXNG as containers; this stack runs all three as containers, with every
image pinned to a version tag and digest, and replicates the playbook's
wiring, model list, and port posture.

## Services

| Service | Image | Role |
| --- | --- | --- |
| `ollama` | `ollama/ollama:0.40.6-rocm` | LLM inference on the AMD GPU (ROCm build) |
| `model-init` | `ollama/ollama:0.40.6-rocm` | One-shot: pulls the models in `OLLAMA_MODELS`, then exits |
| `open-webui` | `ghcr.io/open-webui/open-webui:v0.12.3` | Chat UI, wired to Ollama and SearXNG |
| `searxng` | `searxng/searxng:2026.10.16-8252c0bf6` | Web search backend for Open WebUI, loopback only |

Pinned digests:

- `ollama/ollama:0.40.6-rocm` at
  `sha256:e31d0bc9436bba21098c3cd078767c48303f854059f2ae3ce3698ac2fb2d5ba1`
- `ghcr.io/open-webui/open-webui:v0.12.3` at
  `sha256:a537bbe1e6b428820f52ed4a029d7fff97062e24d5cf32c365fba36fd0542def`
- `searxng/searxng:2026.10.16-8252c0bf6` at
  `sha256:3619192d55f19eaec4b01892bdf10f80c67e8592fafd14b26ca504e52229210f`

## 📋 Requirements

- A host with an AMD GPU supported by ROCm, with `/dev/kfd` and `/dev/dri`
  present (the playbook targets Fedora; any Docker host with the AMD
  kernel driver works).
- Docker Engine with the Compose plugin.
- About 31 GB of free disk for the default model list, plus the images
  (about 8 GB).

## 🛠️ Setup

```sh
cd containers/gpu-llm
cp .env.example .env
```

Fill in the four required values in `.env`:

- `RENDER_GID` and `VIDEO_GID`: the numeric IDs of the host's `render` and
  `video` groups. Get them on the deployment host with
  `getent group render` and `getent group video`. The compose file refuses
  to render without them.
- `WEBUI_SECRET_KEY` and `SEARXNG_SECRET`: generate each with
  `openssl rand -hex 32`. The compose file refuses to render without them.

Then start the stack:

```sh
docker compose up -d
```

## GPU group IDs: the silent failure mode

The Ollama container runs as root but reaches the GPU through the device
nodes, whose permissions come from the host's `render` and `video` groups.
`group_add` in the compose file adds those two host group IDs to the
container process. If the IDs are wrong for the host the stack is deployed
on, the container cannot open the GPU and **Ollama silently falls back to
CPU inference** — no error, just slow completions. Verify offload after the
first start:

```sh
docker compose exec ollama ollama ps
docker compose logs ollama | grep -i gpu
```

`ollama ps` shows a `PROCESSOR` column: it must say `GPU` (or a CPU/GPU
split) for a loaded model, not `100% CPU`. The server log also prints the
detected GPU and its VRAM at startup.

## 🚀 First start downloads about 31 GB of models

On first start, the one-shot `model-init` service waits for Ollama to be
healthy, then pulls every model in `OLLAMA_MODELS` and exits. With the
default list (the playbook's `required_models`) that is 30,944,883,012
bytes, about 31 GB:

| Model | Download size |
| --- | --- |
| `qwen2.5-coder:14b` | 8,988,124,298 bytes |
| `qwen2.5-coder:7b` | 4,683,087,561 bytes |
| `deepseek-r1:14b` | 8,988,112,209 bytes |
| `nomic-embed-text:latest` | 274,302,450 bytes |
| `llava:13b` | 8,011,256,494 bytes |

Models land in the `ollama_data` volume, so this happens once. Pulls are
idempotent: re-running `docker compose up -d` (or
`docker compose run --rm model-init`) after the first start is a fast
no-op. To trim the download, set `OLLAMA_MODELS` in `.env` to a
comma-separated list with only the models you want before the first start.

Loaded models stay in VRAM for 30 minutes after their last request
(`OLLAMA_KEEP_ALIVE`, the playbook's value); override it in `.env` if the
GPU's VRAM is shared with other work.

### Unsupported GPU generations

Some consumer cards need an architecture override before ROCm will use
them. If the Ollama log shows no GPU detected on a card you know is
present, set `HSA_OVERRIDE_GFX_VERSION` in `.env` to your card's
generation (for example `11.0.0` for RDNA 3 / gfx1100, `10.3.0` for
RDNA 2 / gfx1030) and restart the `ollama` service. Leave it empty
otherwise; it is empty in the playbook by default too.

## 🌐 Ports and exposure

| Port | Published | Notes |
| --- | --- | --- |
| 11434 | All interfaces | Ollama API, same posture as the playbook deployment |
| `${WEBUI_PORT:-8080}` | All interfaces | Open WebUI |
| `${SEARXNG_PORT:-8888}` | `127.0.0.1` only | SearXNG, loopback only, as in the playbook |

**The Ollama API has no authentication.** Anyone who can reach port 11434
can run inference and manage models. This matches the playbook deployment,
which accepts the risk because the host firewall scopes 11434 and 8080 to
the LAN. Keep the same discipline here: do not expose this stack to the
internet, and keep the host firewall's rules for these ports LAN-scoped,
as the playbook configures them.

Port collision note: `containers/optiplex-llm` also defaults to host port
8080 (on localhost). If both stacks run on the same host, set `WEBUI_PORT`
here to something else, for example 8081.

## ⚙️ SearXNG settings

`settings.yml` is the SearXNG configuration from the playbook's settings
task, extracted from the playbook rather than re-typed. It differs from the
playbook block in exactly one line: the playbook generates a random
`secret_key` on the host at deploy time, while the shipped file keeps
upstream's placeholder value and the real secret is injected through the
`SEARXNG_SECRET` environment variable, which SearXNG reads in preference
to the file. The settings enable the JSON format Open WebUI queries, cap
outgoing requests at 10 seconds, and disable the limiter and image proxy,
all as the playbook writes them.

One known divergence between the playbook and
`scripts/llm/gpu-box-llm-setup-v1.9.sh`: the script's settings carry
`outgoing.useragent_suffix: ""` and the playbook's do not. This stack
follows the playbook.

## Differences from the playbook deployment

- Ollama moves from a bare-metal systemd service to the official ROCm
  container image; `OLLAMA_HOST` is `0.0.0.0:11434` inside the container
  instead of the host's LAN address, with the same port published.
- Open WebUI used host networking in the playbook to reach the bare-metal
  Ollama and the loopback SearXNG. Here all three services share the
  project network and WebUI uses the service names `ollama` and
  `searxng`; the environment values are otherwise the playbook's, verbatim.
- The playbook pulls models through the Ollama API from an Ansible wait
  task; here the `model-init` one-shot service does it with the Ollama
  CLI.
- The playbook's floating `:latest` tags (its own TODO(RISK-1) flags
  them) are replaced by the pinned tags and digests above.

## Updating

Bump the image tags and digests in `docker-compose.yml` deliberately,
then:

```sh
docker compose pull
docker compose up -d
```
