# optiplex-llm — portable llama.cpp inference server

The container form of the Ansible OptiPlex deployment in
`ansible/playbooks/llm/optiplex-llm-setup-v2.1.yml`. The playbook
compiles llama.cpp from source on one apt-based x86-64 desktop,
downloads a GGUF model, and serves it under a systemd unit. This
stack runs the same server from the official llama.cpp image: no
source build, no systemd, no host assumptions. It runs on any
x86_64 Docker host.

| Ansible original | This stack |
| --- | --- |
| `optiplex-llm-setup-v2.1.yml` (source build, systemd unit) | `docker-compose.yml` (single service) |
| Model preset `llama3.2-3b`, downloaded by `get_url` | Same model, downloaded on first start by `entrypoint.sh` |
| Unit flags: ctx 4096, temp 0.2, top-p 0.95, min-p 0.01, `--mlock` | Same flags, assembled from the environment; `--mlock` is passed as `--load-mode mmap+mlock` (see below) |
| `LimitMEMLOCK=infinity` | `ulimits: memlock: -1` |
| `bind_addr: 127.0.0.1`, API key required | Loopback-only publish; API key via env (below) |

## See it running

The stack running at home: llama-ui, the web front end the llama.cpp
server ships with, serving Meta-Llama-3.1 8B Instruct (Q4_K_M).
Screenshot from my own deployment, May 2026.

![llama-ui serving Meta-Llama-3.1 8B Instruct on this stack](llama-ui-screenshot-2026-05-29.png)

## 🚀 Quickstart

```bash
cd containers/optiplex-llm
docker compose up -d
```

No `.env` is needed. On first start the entrypoint downloads the
default model (Llama-3.2-3B-Instruct Q4_K_M, 2,019,377,696 bytes)
into the `optiplex_llm_models` volume, verifies it against a pinned
SHA-256, and only then starts the server on
`http://127.0.0.1:8080`. The first start takes as long as the
download takes; later starts re-verify the volume copy (a few
seconds) and load the model.

```bash
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}'
```

## 🔧 How it works

One image only: `ghcr.io/ggml-org/llama.cpp:server-b11681`, the
same pin the `containers/llm` stack uses. The compose file replaces
the image entrypoint (`/app/llama-server` itself) with
`entrypoint.sh`, bind-mounted read-only, because the image ships
everything the fetch-and-verify step needs (`curl`, `sha256sum`,
`sh`). The script:

- downloads the model to a `.part` file and moves it into place
  only when the transfer completes, so an interrupted download is
  never served; interrupted transfers resume (`curl -C -`) across
  attempts and restarts, and an attempt that makes no progress
  discards the partial and starts fresh;
- verifies the model against `MODEL_SHA256` on every start and
  exits non-zero on a mismatch — an unverified model is never
  served (deleting the bad file from the volume, or fixing the
  hash, is the recovery);
- assembles the server flags from the environment and `exec`s
  `/app/llama-server` from `/app`. The working directory is load
  bearing: the launcher's `RUNPATH` ends in an empty element, so
  `libllama-server-impl.so` resolves relative to the working
  directory, and the image's `WorkingDir` is `/app`.

One translation the version pin forces: current llama.cpp removed
the boolean `--mlock` flag the playbook's unit uses; locking is now
a load mode. `MLOCK=1` passes `--load-mode mmap+mlock`, the old
flag's exact semantics (memory-map the model, then lock its
pages). `MLOCK=0` omits it and the server uses its default plain
mmap load.

## ⚙️ Configuration

Every knob lives in `.env` (see `.env.example` for the annotated
list); every one has the default below shipped in
`docker-compose.yml`, so the `.env` is only for changes.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODEL_URL` | bartowski Llama-3.2-3B Q4_K_M | GGUF download URL |
| `MODEL_NAME` | `Llama-3.2-3B-Instruct-Q4_K_M` | File stem under `/models` |
| `MODEL_SHA256` | pinned hash of the default model | Verified every start |
| `CTX_SIZE` | `4096` | Context size |
| `MLOCK` | `1` | Lock the model in RAM (`--load-mode mmap+mlock`) |
| `THREADS` | `0` | 0 = all cores; else `--threads`/`--threads-batch` |
| `TEMP` / `TOP_P` / `MIN_P` | `0.2` / `0.95` / `0.01` | Sampling defaults |
| `HOST_BIND` | `127.0.0.1` | Host interface to publish on |
| `HOST_PORT` | `8080` | Host port |
| `API_KEY` | empty | Required for LAN exposure (below) |
| `CORS_ORIGINS` | empty | Passed as `--cors-origins` when set |

Extra llama-server flags can be appended after the assembled defaults by setting `command:` in a compose override; the entrypoint places them after the base flags so they win over those, though the environment-derived `--threads`/`--load-mode`/`--api-key`/`--cors-origins` flags are appended after them.

### The 8B preset

The playbook's second preset is Meta-Llama-3.1-8B-Instruct Q4_K_M
(~4.9 GB download, ~5.1 GiB resident). Set `MODEL_URL` and
`MODEL_NAME` to the values commented in `.env.example`, plus
`CTX_SIZE=2048` and `MLOCK=0`. Its `MODEL_SHA256` is deliberately
not pinned here: capture it from a known-good download of the file
(the playbook's OPEN-1 note — no upstream checksum manifest exists)
and set it before first start.

## ✅ The checksum story

The playbook leaves its `model_sha256` empty (its OPEN-1 note): the
model downloads unverified and a warning is all you get. This stack
closes that gap for the default preset. The pinned hash was
captured from the actual bartowski file on 2026-10-17
(SHA-256 `6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff`) and is verified on every start, not
just the first.

## LAN exposure (opt-in)

The default publishes on loopback only, like the playbook's bind.
To serve the LAN, set all three in `.env`:

```ini
HOST_BIND=0.0.0.0
API_KEY=<output of: openssl rand -hex 32>
CORS_ORIGINS=localhost
```

With an `API_KEY` set, llama-server demands it on its API
endpoints (the playbook's posture: a key is always required there).
Do not expose the port beyond a trusted LAN; there is no TLS in
this stack — put it behind the monitoring stack's Traefik if it
ever needs one.

## Performance note

The playbook builds with `GGML_NATIVE=ON`, tuned to the exact host
CPU (AVX2 and friends). The official image is a generic build: it
ships several `libggml-cpu-*.so` backends (haswell, skylakex, zen4,
and others) and dispatches to the closest one at runtime, which is
close but not identical to a native build. On the OptiPlex itself
the bare-metal install may benchmark faster; the container trades
that margin for running anywhere. `llama-bench` ships in the same
image if you want the number.

## 🔒 Hardening and limits

- `cap_drop: ALL`, `read_only` root filesystem, `no-new-privileges`;
  the model volume and a small `/tmp` tmpfs are the only writable
  paths.
- Deploy limits: 4 CPUs / 6 GiB (reservations 1 CPU / 3 GiB),
  sized for the 3B preset with mlock on a desktop-class host.
- The container runs as the image's default user (root): the image
  ships no unprivileged service user, and the single-purpose
  container's only writable surface is the model volume. The
  playbook's `llm` system user has no container analogue without
  building a derived image.
- Healthcheck is the image's own: `curl -f
  http://localhost:8080/health`. It reports healthy only once the
  model has loaded; `start_period` covers the first-start download.

The image is published for arm64 as well as amd64 (verified in the
registry), and the compose file is architecture-neutral, but the
tested target is amd64 — the OptiPlex class this mirrors.
