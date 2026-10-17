# GPU Box LLM Deployment v2.1

> **Target:** Nobara (Fedora-based GPU box), **AMD GPU only (ROCm)**, Ollama + Open WebUI
> **Models:** Qwen 2.5 Coder 14B, Qwen 2.5 Coder 7B, DeepSeek-R1 14B, LLaVA 13B, nomic-embed-text (5 total)
> **Ports:** 11434 (Ollama API, LAN), 8080 (Open WebUI, LAN), 8888 (SearXNG, **loopback only** by default)
> **VRAM:** 16GB — sufficient for one 14B model resident at a time, not for the full library concurrently
> **Status:** Idempotent. Container images run on floating `:latest` tags by explicit decision — see *Known Risk Register*.

---

## Change Control — v2.0 → v2.1

Security fix (2026-10-15), applied to both deployment paths in this guide and to the public repo copies in the same change (public repo PR #25, merged 2026-10-15). The Ollama installer is no longer piped from curl straight into a root shell. The bash script and the Ansible playbook now download <https://ollama.com/install.sh> to a temporary file first and verify it against a pinned SHA-256 when one is configured (`OLLAMA_INSTALL_SHA256` in the script, `ollama_install_sha256` in the playbook). With no pin configured they warn loudly and proceed; on a checksum mismatch they refuse to run. No pin is set by default, because upstream revises the installer and a stale default would fail closed on the next legitimate revision. Same pattern as the earlier fix in the workstation GPU update script. No other behaviour changes.

## Change Control — v1.9 → v2.0

Added table of contents (2026-10-07). No behaviour changes; the deployment the scripts produce is identical.

## Change Control — v1.8 → v1.9

Corrections from an independent verification pass (2026-09-16) against primary sources. No behaviour changes; the deployment the scripts produce is identical.

| # | Correction | Source |
|---|------------|--------|
| 1 | v1.8 item #1 overstated the SearXNG port defect: `SEARXNG_PORT` **is** honoured on current images (the container entrypoint aliases it to `GRANIAN_PORT`). Only `SEARXNG_BIND_ADDRESS` and settings.yml `server.port` / `server.bind_address` are inert. The deployment still uses bridge networking with an explicit `-p` mapping, which is unchanged | searxng `container/entrypoint.sh`; searxng issue #5934 |
| 2 | The `HSA_OVERRIDE_GFX_VERSION` values (`11.0.0` RDNA3 / `10.3.0` RDNA2) are community-sourced, not AMD-documented — no ROCm docs page mentions the variable. Wording hedged to say so | rocm.docs.amd.com (no hits); llama.cpp build docs |
| 3 | "Nobara ships firewalld enabled" is unverified — Nobara's own wiki never states the default. The firewalld tasks are already guarded by `systemctl is-active`, so a wrong assumption degrades to skipped rules, but confirm on the box with `systemctl is-enabled firewalld` | wiki.nobaraproject.org (no mention); stock Fedora ships firewalld active |
| 4 | `WEB_SEARCH_CONCURRENT_REQUESTS=10` now means search-engine request concurrency, not the old RAG-era page-fetch concurrency. Value still valid; semantics noted | Open WebUI env reference |

## Change Control — v1.7 → v1.8

Every change below is a correction to a verified defect or a deliberate behaviour change. Behaviour changes are marked **[DECISION]** and require sign-off.

<!-- MD056 disabled for the table below: mdl 0.13.0 counts escaped pipes in cells as column delimiters, so rows documenting shell pipelines report phantom columns. The rows render correctly on GitHub. -->
<!-- markdownlint-disable MD056 -->
| # | Change | Reason |
|---|--------|--------|
| 1 | SearXNG moved from `--network host` + `SEARXNG_PORT` to bridge networking with `-p 127.0.0.1:8888:8080` | `SEARXNG_BIND_ADDRESS` and `settings.yml server.port` / `server.bind_address` are inert on the current image (Granian replaced uWSGI in container build 2025.7.4). Note: `SEARXNG_PORT` itself **is** honoured — the entrypoint aliases it to `GRANIAN_PORT` (upstream issue #5934) — so the defect was the unscoped bind address under `--network host`, not the port override. Bridge + explicit `-p` removes the question entirely |
| 2 | **[DECISION]** SearXNG published to `127.0.0.1` instead of the LAN | SearXNG has no authentication and runs with `limiter: false` (required for the JSON API). Publishing it to the LAN exposes an open metasearch proxy. Open WebUI is the only consumer and reaches it over loopback. Set `SEARXNG_LISTEN_ADDR="0.0.0.0"` to restore v1.7 behaviour |
| 3 | Open WebUI env vars renamed `RAG_WEB_SEARCH_*` → `ENABLE_WEB_SEARCH` / `WEB_SEARCH_*` | Current variable names per upstream docs |
| 4 | `ENABLE_R1_THINKING` removed | No such variable exists in any documented Open WebUI release. Reasoning-tag parsing is automatic |
| 5 | **[DECISION]** `ENABLE_PERSISTENT_CONFIG=False` added | Web-search settings are ConfigVars: on an existing `open-webui-storage` volume the database wins and env changes are ignored. Without this the script's env vars are decorative. Tradeoff: admin-UI changes to those settings no longer persist across container recreation — the script becomes the single source of truth |
| 6 | `&format=json` dropped from `SEARXNG_QUERY_URL` | Documented form is `/search?q=<query>`; Open WebUI supplies the format itself |
| 7 | Ollama service configured via systemd **drop-in** instead of `sed`-patching the unit file | The Ollama install script rewrites `/etc/systemd/system/ollama.service` on every upgrade, silently discarding v1.7's patch |
| 8 | firewalld rich rules added for 11434 and 8080, scoped to the detected LAN network | Nobara is Fedora-based and typically ships firewalld enabled, but Nobara's own documentation never states the default — confirm on the box with `systemctl is-enabled firewalld`. The tasks are guarded by `systemctl is-active`, so an inactive firewalld degrades to skipped rules, not a failure |
| 9 | All NVIDIA detection and `nvidia-smi` paths removed | AMD-only fleet |
| 10 | AMD detection changed from `lspci` grep to `/dev/kfd` + `/sys/class/kfd`, with `pciutils` installed for the fallback | `lspci` was never installed, so v1.7's AMD branch could not fire. Presence on the PCI bus also does not mean the KFD compute device is usable |
| 11 | **[DECISION]** `OLLAMA_KEEP_ALIVE` changed from `-1` to `30m` | `-1` pins every loaded model indefinitely. With five models against 16GB VRAM this maximises eviction churn and never releases VRAM at idle. Set `OLLAMA_KEEP_ALIVE="-1"` to restore |
| 12 | `nomic-embed-text` → `nomic-embed-text:latest`, plus tag-normalising comparison | `ollama list` prints the `:latest` suffix; the v1.7 exact-match test never hit, re-pulling on every run |
| 13 | Container existence checks use `docker ps -a`, with start-if-stopped | v1.7 checked `docker ps` only; a stopped container caused `docker run --name` to fail on name collision and abort the script |
| 14 | `settings.yml` JSON-format patch now restarts the container | v1.7 edited the file with no restart, so the change never took effect |
| 15 | Unguarded pipelines given `\|\| true`; `sleep`-based readiness replaced with polling | Under `set -euo pipefail`, `docker ps \| grep`, `systemctl status \| head`, `rocm-smi \| grep` and `json.tool \| head` each abort the script on an ordinary non-match |
| 16 | Root check moved above the first `log` call | `log()` writes through `tee -a /var/log/...`; as non-root it failed under `pipefail` and exited silently, never printing "Must run as root" |
| 17 | LAN IP detection rewritten | v1.7 excluded all of `172.0.0.0/8` (including legitimate RFC1918 172.16–31), applied no interface filter, and risked SIGPIPE via `head -1` under `pipefail` |
| 18 | Ansible: `OLLAMA_HOST` added to the `ollama list` / `ollama pull` task environment | The service binds `LAN_IP:11434`; the CLI defaulted to `127.0.0.1:11434` → connection refused → play aborted |
| 19 | Ansible: orphaned handlers replaced with an explicit `daemon_reload` + `state: restarted` task | `Reload systemd` was defined but never notified, and `state: started` is a no-op on a running unit, so the patched environment never applied |
| 20 | Ansible: collection and target-package requirements declared | `community.docker`, `community.general`, `ansible.posix`, `python3-docker` |
| 21 | **[DECISION]** SearXNG engine set restricted via `use_default_settings.engines.keep_only` | A bare `engines:` list under `use_default_settings: true` merges rather than restricts — v1.7 kept the full default engine set. `use_mobile_ui` also dropped (removed upstream) |
| 22 | Disk requirement corrected 150GB → 40GB; frontmatter model count corrected 4 → 5 | The listed set is ≈31GB |
| 23 | `ping huggingface.co` → `curl -I https://registry.ollama.ai` | Ollama pulls from its own registry |
| 24 | Uninstall warns that `userdel -r ollama` destroys `/usr/share/ollama` (all model blobs); adds drop-in, firewalld and `.bashrc` cleanup | Silent data loss |
| 25 | **[DECISION]** Both container images remain on floating `:latest`; version selection deferred. Compensating controls added: `pull: false` on both Ansible container tasks, no implicit pull in the bash path, and per-run digest capture to the log | Accepted temporary placeholder. The mitigations make the floating tag auditable and stop a re-run from silently upgrading. Tracked as RISK-1 |

---

## Table of Contents

- [Known Risk Register](#known-risk-register)
   - [RISK-1 — Container images run on floating `:latest` tags (OPEN, accepted)](#risk-1--container-images-run-on-floating-latest-tags-open-accepted)
   - [RISK-2 — ROCm gfx target unverified (OPEN)](#risk-2--rocm-gfx-target-unverified-open)
- [Prerequisites](#prerequisites)
   - [GPU compatibility knob](#gpu-compatibility-knob)
- [Bash Script](#bash-script)
- [Ansible Playbook](#ansible-playbook)
- [Verification Checklist](#verification-checklist)
- [Deployment](#deployment)
   - [Option 1: Bash (direct execution)](#option-1-bash-direct-execution)
   - [Option 2: Ansible (orchestrated)](#option-2-ansible-orchestrated)
- [Model Management](#model-management)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Version History](#version-history)

## Known Risk Register

### RISK-1 — Container images run on floating `:latest` tags (OPEN, accepted)

| | |
|---|---|
| **Status** | Accepted as a temporary placeholder; tag selection deferred pending research |
| **Applies to** | `ghcr.io/open-webui/open-webui:latest`, `docker.io/searxng/searxng:latest` |
| **Exposure** | The image under a floating tag can change on any `docker pull` or any recreate that misses the local cache. The C1 defect this revision fixes was exactly that: SearXNG swapped uWSGI for Granian in container build 2025.7.4, which silently invalidated the port configuration of a working deployment |
| **Secondary exposure** | An Open WebUI major-version jump runs irreversible database migrations against `open-webui-storage`. Rolling the container back does **not** roll the schema back |
| **Mitigation in place** | Every run records the resolved image digest of both containers to `/var/log/gpu-box-llm-setup.log`, so the exact image in service is always recoverable after the fact. Neither script pulls automatically — an existing healthy container is left alone |
| **Resolution** | Read the digests out of the log (or the commands below), set `OPENWEBUI_IMAGE` / `SEARXNG_IMAGE` to those values, re-run |

```bash
# Capture what is actually in service right now
docker inspect --format '{{.Name}} {{.Image}}' open-webui searxng
docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/open-webui/open-webui:latest
docker inspect --format '{{index .RepoDigests 0}}' docker.io/searxng/searxng:latest

# Back up before any deliberate Open WebUI version change
docker run --rm -v open-webui-storage:/data -v "$PWD:/backup" alpine \
  tar czf /backup/open-webui-storage-$(date +%F).tar.gz -C /data .
```

**Review trigger:** before the next Open WebUI upgrade, or on any unexplained web-search or port regression — check RISK-1 first.

### RISK-2 — ROCm gfx target unverified (OPEN)

`HSA_OVERRIDE_GFX_VERSION` is empty; the card's gfx target has not been checked against ROCm's supported list. If Ollama falls back to CPU, resolve with `rocminfo | grep -i gfx`, then set `11.0.0` (RDNA3) or `10.3.0` (RDNA2) at the top of the script. Note: those values are community-sourced (e.g. llama.cpp build docs) — no AMD/ROCm documentation page mentions this variable, so treat them as a fallback knob, not verified vendor guidance.

---

## Prerequisites

- **GPU box running Nobara** (Fedora-based, x86-64, **AMD GPU**)
- **amdgpu / KFD loaded** — `/dev/kfd` must exist. Verify: `ls -l /dev/kfd /dev/dri/renderD*`
- **Root or passwordless sudo access**
- **16GB VRAM**, **32GB RAM**, **~40GB free disk**
- **Docker** installed (or installed by the scripts)
- **For the Ansible path:**
   - Control machine: `ansible-core` 2.15+
   - Collections: `ansible-galaxy collection install community.docker community.general ansible.posix`
   - Target: `python3-docker` (installed by the play)

### GPU compatibility knob

If `rocminfo` reports a gfx target ROCm does not officially cover, set `HSA_OVERRIDE_GFX_VERSION` at the top of the script (`11.0.0` for RDNA3, `10.3.0` for RDNA2 — community-sourced values, not AMD-documented). Leave empty otherwise.

**INSUFFICIENT CONTEXT** — the specific AMD card in this box is unknown, so no default is set. Resolve with:

```bash
rocminfo | grep -i gfx
```

---

## Bash Script

Save as `gpu-box-llm-setup-v1.9.sh` and execute:

```bash
sudo bash gpu-box-llm-setup-v1.9.sh
```

**Full script:**

```bash
#!/bin/bash

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────
# GPU Box Ollama + Open WebUI Deployment v1.9  (AMD / ROCm only)
# 16GB VRAM (Qwen 14B, Qwen 7B, DeepSeek-R1 14B, LLaVA 13B, nomic-embed)
# ────────────────────────────────────────────────────────────────────────────

# Root check runs BEFORE anything touches $LOG_FILE.
[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root (use sudo)" >&2; exit 1; }

SCRIPT_VERSION="1.9"
LOG_FILE="/var/log/gpu-box-llm-setup.log"
WEBUI_PORT="8080"
SEARXNG_PORT="8888"
SEARXNG_CONFIG_DIR="/etc/searxng"

# Publish address for SearXNG. 127.0.0.1 keeps the unauthenticated metasearch
# proxy off the LAN; Open WebUI reaches it over loopback. Set to 0.0.0.0 to
# expose the SearXNG UI on the LAN (a firewalld rule is then added for it).
SEARXNG_LISTEN_ADDR="127.0.0.1"

# Model residency. "-1" pins models forever; on 16GB with five models that
# maximises eviction churn and never frees VRAM at idle.
OLLAMA_KEEP_ALIVE="30m"

# ROCm gfx override. Empty = let ROCm autodetect. 11.0.0 = RDNA3, 10.3.0 = RDNA2.
HSA_OVERRIDE_GFX_VERSION=""

# Set to "yes" to proceed on a host with no usable AMD compute device.
ALLOW_CPU_FALLBACK="no"

# TODO(RISK-1): floating tags, accepted as a temporary placeholder. Replace both
# with digest references once a target version is selected. The resolved digest
# of whatever is actually running is written to $LOG_FILE on every run.
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:latest"
SEARXNG_IMAGE="docker.io/searxng/searxng:latest"

OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
OLLAMA_DROPIN="${OLLAMA_DROPIN_DIR}/10-gpu-box.conf"

declare -a REQUIRED_MODELS=(
    "qwen2.5-coder:14b"
    "qwen2.5-coder:7b"
    "deepseek-r1:14b"
    "nomic-embed-text:latest"
    "llava:13b"
)

# ────────────────────────────────────────────────────────────────────────────
# Logging & Error Handling
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

container_exists() { docker ps -a --format '{{.Names}}' | grep -qx "$1"; }
container_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }

log "GPU Box Ollama + Open WebUI Setup v$SCRIPT_VERSION starting (AMD/ROCm)..."

# ────────────────────────────────────────────────────────────────────────────
# AMD GPU Validation
# ────────────────────────────────────────────────────────────────────────────

if [[ -e /dev/kfd && -d /sys/class/kfd ]]; then
    log "✓ AMD KFD compute device present (/dev/kfd)"
else
    if [[ "$ALLOW_CPU_FALLBACK" == "yes" ]]; then
        log "⚠ No AMD compute device — continuing in CPU mode (14B inference will be unusable)"
    else
        error "No AMD compute device (/dev/kfd absent). amdgpu/KFD not loaded, or the card is unsupported. Set ALLOW_CPU_FALLBACK=yes to override."
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
# System Package Installation
# ────────────────────────────────────────────────────────────────────────────

log "Installing system dependencies..."
dnf install -y git curl wget pciutils python3 > /tmp/dnf-install.log 2>&1 \
    || error "Failed to install dependencies. See /tmp/dnf-install.log"

if command -v lspci &>/dev/null; then
    GPU_PCI=$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display' | grep -Ei 'amd|ati|radeon' || true)
    [[ -n "$GPU_PCI" ]] && log "AMD GPU on PCI bus: ${GPU_PCI%%$'\n'*}"
fi

if ! command -v docker &>/dev/null; then
    log "Installing moby-engine (Docker) from Nobara repo..."
    dnf install -y moby-engine >> /tmp/dnf-install.log 2>&1 \
        || error "Failed to install moby-engine. See /tmp/dnf-install.log"
    log "✓ moby-engine installed: $(docker --version)"
else
    log "✓ Docker already present: $(docker --version)"
fi

# ────────────────────────────────────────────────────────────────────────────
# Docker Service
# ────────────────────────────────────────────────────────────────────────────

log "Enabling and starting Docker..."
systemctl enable docker > /tmp/systemctl-enable-docker.log 2>&1 || error "Failed to enable Docker"

if systemctl is-active --quiet docker; then
    log "Docker already running"
else
    systemctl start docker > /tmp/systemctl-start-docker.log 2>&1 || error "Failed to start Docker"
    log "Docker started"
fi

# SELinux volume labelling is only meaningful if the daemon has it enabled.
MOUNT_OPTS="rw"
if docker info --format '{{join .SecurityOptions ","}}' 2>/dev/null | grep -q selinux; then
    MOUNT_OPTS="rw,Z"
    log "Docker reports SELinux support — bind mounts will be relabelled (:Z)"
fi

# ────────────────────────────────────────────────────────────────────────────
# LAN Address Detection
# ────────────────────────────────────────────────────────────────────────────

# Global-scope IPv4 on a physical interface. Excludes docker/bridge/veth/virt
# interfaces by name rather than by address range, so RFC1918 172.16-31 works.
# awk consumes all input and prints in END — an early `exit` would close the
# pipe on `ip` exactly like `head -1` does, which is a SIGPIPE abort waiting
# to happen under pipefail.
LAN_ADDR=$(ip -4 -o addr show scope global \
    | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|cni|flannel)/ && addr == "" { addr = $4 }
           END { print addr }')
[[ -n "$LAN_ADDR" ]] || error "Could not detect a LAN IPv4 address. Set LAN_ADDR manually."

LAN_IP="${LAN_ADDR%%/*}"
LAN_NET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$LAN_ADDR") \
    || error "Could not derive LAN network from $LAN_ADDR"

log "LAN IP: $LAN_IP   LAN network: $LAN_NET"

# Persist OLLAMA_HOST for interactive CLI use (the service binds the LAN IP).
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    REAL_USER=$(logname 2>/dev/null || true)
fi
if [[ -n "$REAL_USER" ]]; then
    # pipefail would propagate getent's exit 2 for an unknown user and abort.
    REAL_USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 || true)
    if [[ -n "$REAL_USER_HOME" && -d "$REAL_USER_HOME" ]]; then
        if grep -qF "OLLAMA_HOST" "${REAL_USER_HOME}/.bashrc" 2>/dev/null; then
            sed -i "s|^export OLLAMA_HOST=.*|export OLLAMA_HOST=${LAN_IP}:11434|" "${REAL_USER_HOME}/.bashrc"
            log "✓ OLLAMA_HOST refreshed in ${REAL_USER_HOME}/.bashrc"
        else
            echo "export OLLAMA_HOST=${LAN_IP}:11434" >> "${REAL_USER_HOME}/.bashrc"
            log "✓ OLLAMA_HOST added to ${REAL_USER_HOME}/.bashrc"
        fi
    fi
else
    log "⚠ Could not determine invoking user — skipping .bashrc update"
fi

# ────────────────────────────────────────────────────────────────────────────
# Firewall (firewalld) — LAN-scoped, deny by default elsewhere
# ────────────────────────────────────────────────────────────────────────────

open_lan_port() {
    local port="$1" rule
    rule="rule family=ipv4 source address=${LAN_NET} port port=${port} protocol=tcp accept"
    if firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
        log "firewalld: ${port}/tcp already allowed from ${LAN_NET}"
    else
        firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null \
            || error "firewalld: failed to add rule for ${port}/tcp"
        log "✓ firewalld: ${port}/tcp opened to ${LAN_NET}"
    fi
}

if systemctl is-active --quiet firewalld; then
    open_lan_port 11434
    open_lan_port "$WEBUI_PORT"
    if [[ "$SEARXNG_LISTEN_ADDR" == "0.0.0.0" ]]; then
        open_lan_port "$SEARXNG_PORT"
    fi
    firewall-cmd --reload >/dev/null || error "firewalld reload failed"
    log "✓ firewalld reloaded"
else
    log "⚠ firewalld not active — skipping firewall configuration"
fi

# ────────────────────────────────────────────────────────────────────────────
# Ollama Installation (official install script — ROCm build for AMD)
# ────────────────────────────────────────────────────────────────────────────

# Clear partial install artefacts that would make the installer's useradd fail.
if [[ ! -f /etc/systemd/system/ollama.service ]]; then
    log "No ollama unit found — clearing partial install state..."
    userdel ollama 2>/dev/null || true
    groupdel ollama 2>/dev/null || true
    rm -f /usr/local/bin/ollama /usr/local/sbin/ollama
fi

if command -v ollama &>/dev/null && [[ -f /etc/systemd/system/ollama.service ]]; then
    log "Ollama already installed"
else
    log "Installing Ollama via official install script (ROCm build)..."
    _ollama_installer="$(mktemp)"
    curl -fsSL -o "$_ollama_installer" https://ollama.com/install.sh >> /tmp/ollama-install.log 2>&1 \
        || error "Ollama installer download failed. See /tmp/ollama-install.log"
    if [[ -n "${OLLAMA_INSTALL_SHA256:-}" ]]; then
        echo "${OLLAMA_INSTALL_SHA256}  $_ollama_installer" | sha256sum -c - >> /tmp/ollama-install.log 2>&1 \
            || error "Ollama installer checksum mismatch — refusing to run"
    else
        log "⚠ OLLAMA_INSTALL_SHA256 not set — running ollama.com/install.sh without checksum verification"
    fi
    sh "$_ollama_installer" >> /tmp/ollama-install.log 2>&1 \
        || error "Ollama install script failed. See /tmp/ollama-install.log"
    rm -f "$_ollama_installer"
    log "✓ Ollama installed"
fi

# The installer rewrites ollama.service on every upgrade. Configure via a
# drop-in so the settings survive.
mkdir -p "$OLLAMA_DROPIN_DIR"
{
    echo "[Service]"
    echo "Environment=\"OLLAMA_HOST=${LAN_IP}:11434\""
    echo "Environment=\"OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}\""
    if [[ -n "$HSA_OVERRIDE_GFX_VERSION" ]]; then
        echo "Environment=\"HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION}\""
    fi
} > "${OLLAMA_DROPIN}.new"

if cmp -s "${OLLAMA_DROPIN}.new" "$OLLAMA_DROPIN" 2>/dev/null; then
    rm -f "${OLLAMA_DROPIN}.new"
    log "Ollama drop-in already current"
else
    mv "${OLLAMA_DROPIN}.new" "$OLLAMA_DROPIN"
    log "✓ Ollama drop-in written: $OLLAMA_DROPIN"
fi

systemctl daemon-reload || error "systemctl daemon-reload failed"
systemctl enable ollama > /dev/null 2>&1 || error "Failed to enable ollama service"
systemctl restart ollama || error "Failed to restart ollama service"

# Poll the API instead of sleeping blind.
log "Waiting for Ollama API..."
OLLAMA_READY="no"
for i in {1..12}; do
    if curl -fsS "http://${LAN_IP}:11434/api/tags" >/dev/null 2>&1; then
        OLLAMA_READY="yes"
        break
    fi
    log "Ollama not ready yet (attempt $i/12), waiting 5s..."
    sleep 5
done
[[ "$OLLAMA_READY" == "yes" ]] || error "Ollama API did not come up. Check: journalctl -u ollama -n 50"
log "✓ Ollama API responding on ${LAN_IP}:11434"

# ────────────────────────────────────────────────────────────────────────────
# Model Pulling (idempotent, tag-normalised)
# ────────────────────────────────────────────────────────────────────────────

log "Pulling required models (30–60 minutes on first run)..."

EXISTING_MODELS=$(OLLAMA_HOST="${LAN_IP}:11434" ollama list 2>/dev/null | awk 'NR>1 {print $1}' || true)

for model in "${REQUIRED_MODELS[@]}"; do
    # Compare with the :latest suffix stripped from both sides — `ollama list`
    # always prints it, so a literal match on "nomic-embed-text" never fires.
    if printf '%s\n' "$EXISTING_MODELS" | sed 's/:latest$//' | grep -qxF "${model%:latest}"; then
        log "✓ Model already installed: $model"
    else
        log "Pulling model: $model ..."
        OLLAMA_HOST="${LAN_IP}:11434" ollama pull "$model" \
            > "/tmp/ollama-pull-${model//:/-}.log" 2>&1 \
            || error "Failed to pull $model. See /tmp/ollama-pull-${model//:/-}.log"
        log "✓ Model pulled: $model"
    fi
done

log "Installed models:"
OLLAMA_HOST="${LAN_IP}:11434" ollama list | tee -a "$LOG_FILE" || true

# ────────────────────────────────────────────────────────────────────────────
# SearXNG Web Search Container
# ────────────────────────────────────────────────────────────────────────────

log "Deploying SearXNG container..."

mkdir -p "$SEARXNG_CONFIG_DIR"
SEARXNG_RESTART_NEEDED="no"

if [[ ! -f "$SEARXNG_CONFIG_DIR/settings.yml" ]]; then
    log "Writing SearXNG settings.yml..."
    SEARXNG_SECRET=$(openssl rand -hex 32)
    # NOTE: server.port / server.bind_address are deliberately absent. They are
    # inert inside the container (Granian owns the socket); the published
    # Docker port is the only thing that decides where this is reachable.
    cat > "$SEARXNG_CONFIG_DIR/settings.yml" << EOF
use_default_settings:
  engines:
    keep_only:
      - google
      - duckduckgo
      - bing
      - wikipedia

server:
  secret_key: "$SEARXNG_SECRET"
  limiter: false
  image_proxy: false

ui:
  static_use_hash: true

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json

outgoing:
  request_timeout: 10.0
  max_request_timeout: 20.0
  useragent_suffix: ""
  pool_connections: 100
  pool_maxsize: 20
EOF
    chmod 0644 "$SEARXNG_CONFIG_DIR/settings.yml"
    log "✓ SearXNG settings.yml written"
else
    log "SearXNG settings.yml already exists — checking JSON format..."
    if ! grep -qE "^[[:space:]]*- json" "$SEARXNG_CONFIG_DIR/settings.yml"; then
        sed -i '/^[[:space:]]*formats:/a\    - json' "$SEARXNG_CONFIG_DIR/settings.yml"
        SEARXNG_RESTART_NEEDED="yes"
        log "✓ json format added to existing settings.yml (restart required)"
    fi
fi

# base_url must match where SearXNG is actually reachable, not where the
# rest of the stack lives — it is loopback-only unless deliberately exposed.
if [[ "$SEARXNG_LISTEN_ADDR" == "0.0.0.0" ]]; then
    SEARXNG_BASE_HOST="$LAN_IP"
else
    SEARXNG_BASE_HOST="$SEARXNG_LISTEN_ADDR"
fi

docker volume create searxng-data > /dev/null

if container_exists searxng; then
    if container_running searxng; then
        log "SearXNG container already running"
    else
        docker start searxng > /dev/null || error "Failed to start existing SearXNG container"
        log "✓ SearXNG container started (pre-existing)"
    fi
    if [[ "$SEARXNG_RESTART_NEEDED" == "yes" ]]; then
        docker restart searxng > /dev/null || error "Failed to restart SearXNG"
        log "✓ SearXNG restarted to pick up settings.yml change"
    fi
else
    # Bridge networking with an explicit published port. The container listens on
    # 8080 internally unless SEARXNG_PORT is passed (the entrypoint honours it by
    # aliasing to GRANIAN_PORT); SEARXNG_BIND_ADDRESS and settings.yml
    # server.port / server.bind_address have no effect on current images.
    # Docker decides the host-side port via the -p mapping below.
    docker run -d \
        --name searxng \
        --restart always \
        -p "${SEARXNG_LISTEN_ADDR}:${SEARXNG_PORT}:8080" \
        -v "${SEARXNG_CONFIG_DIR}:/etc/searxng:${MOUNT_OPTS}" \
        -v searxng-data:/var/cache/searxng:rw \
        -e SEARXNG_BASE_URL="http://${SEARXNG_BASE_HOST}:${SEARXNG_PORT}/" \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add SETGID \
        --cap-add SETUID \
        --cap-add DAC_OVERRIDE \
        --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
        "$SEARXNG_IMAGE" > /tmp/searxng-run.log 2>&1 \
        || error "Failed to start SearXNG. See /tmp/searxng-run.log"
    log "✓ SearXNG container started"
fi

log "Waiting for SearXNG JSON API..."
SEARCH_TEST="failed"
for i in {1..12}; do
    SEARCH_TEST=$(curl -s "http://127.0.0.1:${SEARXNG_PORT}/search?q=test&format=json" 2>/dev/null || echo "failed")
    if printf '%s' "$SEARCH_TEST" | grep -q '"results"'; then
        break
    fi
    log "SearXNG not ready yet (attempt $i/12), waiting 5s..."
    sleep 5
done

if printf '%s' "$SEARCH_TEST" | grep -q '"results"'; then
    log "✓ SearXNG JSON API responding"
else
    log "⚠ SearXNG JSON API not responding — check: docker logs searxng"
fi

# ────────────────────────────────────────────────────────────────────────────
# Open WebUI Container
# ────────────────────────────────────────────────────────────────────────────

log "Deploying Open WebUI container..."

docker volume create open-webui-storage > /dev/null

SEARXNG_QUERY_URL="http://127.0.0.1:${SEARXNG_PORT}/search?q=<query>"

# WEB_SEARCH_CONCURRENT_REQUESTS now controls search-engine request concurrency
# (0 = unlimited) — repurposed from the old RAG-era page-fetch concurrency
# variable of the same name. 10 is still a sane value.

webui_config_current() {
    local env_lines image
    env_lines=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' open-webui 2>/dev/null) || return 1
    image=$(docker inspect -f '{{.Config.Image}}' open-webui 2>/dev/null) || return 1
    [[ "$image" == "$OPENWEBUI_IMAGE" ]] || return 1
    printf '%s' "$env_lines" | grep -qxF "ENABLE_WEB_SEARCH=True" || return 1
    printf '%s' "$env_lines" | grep -qxF "WEB_SEARCH_ENGINE=searxng" || return 1
    printf '%s' "$env_lines" | grep -qxF "ENABLE_PERSISTENT_CONFIG=False" || return 1
    printf '%s' "$env_lines" | grep -qxF "SEARXNG_QUERY_URL=${SEARXNG_QUERY_URL}" || return 1
    return 0
}

if container_running open-webui && webui_config_current; then
    log "Open WebUI already running with the expected image and configuration"
else
    if container_exists open-webui; then
        BACKUP="/var/log/open-webui-env-$(date +%Y%m%d-%H%M%S).txt"
        docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' open-webui > "$BACKUP" 2>/dev/null || true
        log "Existing Open WebUI environment backed up to $BACKUP"
        log "Recreating Open WebUI — any env vars not set by this script will be lost"
        docker rm -f open-webui > /dev/null 2>&1 || true
    fi

    docker run -d \
        --name open-webui \
        --restart always \
        --network host \
        -v open-webui-storage:/app/backend/data \
        -e OLLAMA_BASE_URL="http://${LAN_IP}:11434" \
        -e ENABLE_PERSISTENT_CONFIG="False" \
        -e ENABLE_WEB_SEARCH="True" \
        -e WEB_SEARCH_ENGINE="searxng" \
        -e "SEARXNG_QUERY_URL=${SEARXNG_QUERY_URL}" \
        -e WEB_SEARCH_RESULT_COUNT="5" \
        -e WEB_SEARCH_CONCURRENT_REQUESTS="10" \
        "$OPENWEBUI_IMAGE" > /tmp/docker-run.log 2>&1 \
        || error "Failed to start Open WebUI. See /tmp/docker-run.log"
    log "✓ Open WebUI container started"
fi

log "Waiting for Open WebUI HTTP endpoint..."
WEBUI_READY="no"
for i in {1..18}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${WEBUI_PORT}/health" 2>/dev/null \
       || curl -fsS -o /dev/null "http://127.0.0.1:${WEBUI_PORT}/" 2>/dev/null; then
        WEBUI_READY="yes"
        break
    fi
    log "Open WebUI not ready yet (attempt $i/18), waiting 5s..."
    sleep 5
done

if [[ "$WEBUI_READY" == "yes" ]]; then
    log "✓ Open WebUI responding on :${WEBUI_PORT}"
else
    log "⚠ Open WebUI endpoint timeout — check: docker logs open-webui"
fi

# ────────────────────────────────────────────────────────────────────────────
# Verification
# ────────────────────────────────────────────────────────────────────────────

log "Verifying inference stack..."

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:11434[[:space:]]"; then
    log "✓ Ollama API listening on ${LAN_IP}:11434"
else
    log "⚠ Ollama API not listening"
fi

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:${SEARXNG_PORT}[[:space:]]"; then
    log "✓ SearXNG listening on ${SEARXNG_LISTEN_ADDR}:${SEARXNG_PORT}"
else
    log "⚠ SearXNG not listening on :${SEARXNG_PORT}"
fi

if ss -tulpn 2>/dev/null | grep -qE "LISTEN.*:${WEBUI_PORT}[[:space:]]"; then
    log "✓ Open WebUI listening on :${WEBUI_PORT}"
else
    log "⚠ Open WebUI not listening"
fi

log "Ollama service state: $(systemctl is-active ollama 2>/dev/null || echo unknown)"

API_TEST=$(curl -fsS "http://${LAN_IP}:11434/api/tags" 2>/dev/null || echo "")
if [[ -n "$API_TEST" ]]; then
    log "✓ Ollama API responding"
    printf '%s' "$API_TEST" | python3 -m json.tool 2>/dev/null | head -20 | tee -a "$LOG_FILE" || true
else
    log "⚠ Ollama API not responding"
fi

# ────────────────────────────────────────────────────────────────────────────
# VRAM (ROCm)
# ────────────────────────────────────────────────────────────────────────────

log "GPU VRAM status:"
if command -v rocm-smi &>/dev/null; then
    rocm-smi --showmeminfo vram 2>/dev/null | tee -a "$LOG_FILE" || true
else
    log "⚠ rocm-smi not installed — install ROCm userspace tools for VRAM reporting"
    log "  Ollama bundles its own ROCm runtime; rocm-smi is only needed for monitoring."
fi

# ────────────────────────────────────────────────────────────────────────────
# Summary
# ────────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Setup Complete — v$SCRIPT_VERSION"
log "════════════════════════════════════════════════════════════════"
log "Ollama API:       http://${LAN_IP}:11434   (LAN: ${LAN_NET})"
log "Open WebUI:       http://${LAN_IP}:${WEBUI_PORT}"
log "SearXNG:          http://${SEARXNG_LISTEN_ADDR}:${SEARXNG_PORT}"
log "Models:           ${#REQUIRED_MODELS[@]} configured"
log "Keep-alive:       ${OLLAMA_KEEP_ALIVE}"
log "Log file:         $LOG_FILE"
log ""
# RISK-1 mitigation: the tags float, so record exactly which image is in service.
# This is the audit trail that makes a floating tag recoverable after the fact.
log "Images in service (tags float — record these):"
for ctr in open-webui searxng; do
    CTR_TAG=$(docker inspect -f '{{.Config.Image}}' "$ctr" 2>/dev/null || echo "unknown")
    CTR_ID=$(docker inspect -f '{{.Image}}' "$ctr" 2>/dev/null || echo "unknown")
    CTR_DIGEST=$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}no-digest{{end}}' "$CTR_ID" 2>/dev/null || echo "unknown")
    log "  ${ctr}: tag=${CTR_TAG}"
    log "  ${ctr}: digest=${CTR_DIGEST}"
done
log ""
log "Next steps:"
log "  1. curl http://${LAN_IP}:11434/api/tags"
log "  2. Open http://${LAN_IP}:${WEBUI_PORT}"
log "  3. Enable Web Search per chat via the Integrations control in the input bar"
log "  4. journalctl -u ollama -f"
```

---

## Ansible Playbook

Requires, on the control machine:

```bash
ansible-galaxy collection install community.docker community.general ansible.posix
```

Save as `gpu-box-llm-setup-v1.9.yml` and execute:

```bash
ansible-playbook -i <gpu-box-ip>, -u <user> -K gpu-box-llm-setup-v1.9.yml
```

**Full playbook:**

```yaml
---
- name: GPU Box Ollama + Open WebUI Deployment v1.9 (AMD/ROCm)
  hosts: all
  become: true
  gather_facts: true

  vars:
    webui_port: 8080
    searxng_port: 8888
    searxng_listen_addr: "127.0.0.1"
    searxng_config_dir: "/etc/searxng"
    ollama_keep_alive: "30m"
    hsa_override_gfx_version: ""
    # TODO(RISK-1): floating tags, accepted as a temporary placeholder.
    openwebui_image: "ghcr.io/open-webui/open-webui:latest"
    searxng_image: "docker.io/searxng/searxng:latest"
    ollama_dropin_dir: "/etc/systemd/system/ollama.service.d"
    # Optional pin for the Ollama installer (same pattern as F2 in
    # scripts/workstation/update-gpu-box.sh): when set, the downloaded
    # installer is verified against this SHA-256 before it runs; when
    # empty, the install task warns that it is running unverified.
    ollama_install_sha256: ""
    required_models:
      - "qwen2.5-coder:14b"
      - "qwen2.5-coder:7b"
      - "deepseek-r1:14b"
      - "nomic-embed-text:latest"
      - "llava:13b"

  pre_tasks:
    - name: Validate OS is Fedora-based
      assert:
        that:
          - ansible_os_family == "RedHat"
        fail_msg: "This playbook requires a Fedora-based distro"

    - name: Check for AMD KFD compute device
      stat:
        path: /dev/kfd
      register: kfd_dev

    - name: Fail if no AMD compute device
      assert:
        that:
          - kfd_dev.stat.exists
        fail_msg: "/dev/kfd absent — amdgpu/KFD not loaded or GPU unsupported"

    # gather_facts does NOT populate ansible_facts.services. Without this task
    # the firewalld gate below is never true and the play silently skips
    # firewall configuration, diverging from the bash path.
    - name: Gather service facts
      service_facts:

  tasks:
    - name: Install base system dependencies
      dnf:
        name:
          - git
          - curl
          - wget
          - pciutils
          - python3
          - python3-docker
          - moby-engine
        state: present

    - name: Enable Docker service
      systemd:
        name: docker
        enabled: true
        state: started

    - name: Get LAN IPv4 address and prefix
      shell: |
        set -o pipefail
        ip -4 -o addr show scope global \
          | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|cni|flannel)/ && addr == "" { addr = $4 }
                 END { print addr }'
      args:
        executable: /bin/bash
      register: lan_addr
      changed_when: false
      failed_when: lan_addr.stdout | length == 0

    - name: Derive LAN network CIDR
      command: >-
        python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))"
        {{ lan_addr.stdout }}
      register: lan_net
      changed_when: false

    - name: Set address facts
      set_fact:
        lan_ip: "{{ lan_addr.stdout.split('/')[0] }}"
        lan_cidr: "{{ lan_net.stdout }}"

    - name: Open LAN-scoped firewall ports
      ansible.posix.firewalld:
        rich_rule: "rule family=ipv4 source address={{ lan_cidr }} port port={{ item }} protocol=tcp accept"
        permanent: true
        immediate: true
        state: enabled
      loop: "{{ [11434, webui_port] + ([searxng_port] if searxng_listen_addr == '0.0.0.0' else []) }}"
      when:
        - "'firewalld.service' in ansible_facts.services"
        - ansible_facts.services['firewalld.service'].state == 'running'

    - name: Install Ollama via official install script (ROCm build)
      shell: |
        set -o pipefail
        tmp_installer=$(mktemp)
        trap 'rm -f "$tmp_installer"' EXIT
        curl -fsSL -o "$tmp_installer" https://ollama.com/install.sh
        {% if ollama_install_sha256 | length > 0 %}
        echo "{{ ollama_install_sha256 }}  $tmp_installer" | sha256sum -c -
        {% else %}
        echo "WARNING: ollama_install_sha256 is not set — running ollama.com/install.sh without checksum verification" >&2
        {% endif %}
        sh "$tmp_installer"
      args:
        executable: /bin/bash
        creates: /usr/local/bin/ollama

    - name: Create Ollama systemd drop-in directory
      file:
        path: "{{ ollama_dropin_dir }}"
        state: directory
        mode: '0755'

    # A drop-in survives the installer rewriting ollama.service on upgrade.
    - name: Write Ollama systemd drop-in
      copy:
        dest: "{{ ollama_dropin_dir }}/10-gpu-box.conf"
        owner: root
        group: root
        mode: '0644'
        content: |
          [Service]
          Environment="OLLAMA_HOST={{ lan_ip }}:11434"
          Environment="OLLAMA_KEEP_ALIVE={{ ollama_keep_alive }}"
          {% if hsa_override_gfx_version | length > 0 %}
          Environment="HSA_OVERRIDE_GFX_VERSION={{ hsa_override_gfx_version }}"
          {% endif %}
      register: ollama_dropin

    - name: Reload systemd and (re)start Ollama
      systemd:
        name: ollama
        state: "{{ 'restarted' if ollama_dropin is changed else 'started' }}"
        enabled: true
        daemon_reload: true

    - name: Wait for Ollama API
      uri:
        url: "http://{{ lan_ip }}:11434/api/tags"
        method: GET
        status_code: [200]
      register: ollama_wait
      retries: 12
      delay: 5
      until: ollama_wait is succeeded

    - name: Get list of installed models
      shell: |
        set -o pipefail
        /usr/local/bin/ollama list | awk 'NR>1 {sub(/:latest$/,"",$1); print $1}'
      args:
        executable: /bin/bash
      environment:
        OLLAMA_HOST: "{{ lan_ip }}:11434"
      register: ollama_list_output
      changed_when: false

    - name: Pull required models
      command: "/usr/local/bin/ollama pull {{ item }}"
      environment:
        OLLAMA_HOST: "{{ lan_ip }}:11434"
      loop: "{{ required_models }}"
      when: item | regex_replace(':latest$', '') not in ollama_list_output.stdout_lines
      register: model_pull_jobs
      async: 3600
      poll: 0

    - name: Wait for model pulls to complete
      async_status:
        jid: "{{ item.ansible_job_id }}"
      loop: "{{ model_pull_jobs.results }}"
      when: item.ansible_job_id is defined
      register: model_pull_results
      until: model_pull_results.finished
      retries: 120
      delay: 30

    - name: Create SearXNG config directory
      file:
        path: "{{ searxng_config_dir }}"
        state: directory
        mode: '0755'

    # server.port / bind_address omitted deliberately: inert in the container.
    # KNOWN DIVERGENCE: force:false means a pre-existing settings.yml is never
    # touched, so unlike the bash path this play will not repair a file that is
    # missing the `json` format. On a clean box the two paths are equivalent.
    - name: Write SearXNG settings.yml
      copy:
        dest: "{{ searxng_config_dir }}/settings.yml"
        force: false
        owner: root
        group: root
        mode: '0644'
        content: |
          use_default_settings:
            engines:
              keep_only:
                - google
                - duckduckgo
                - bing
                - wikipedia

          server:
            secret_key: "{{ lookup('community.general.random_string', length=64, chars=['ascii_letters', 'digits']) }}"
            limiter: false
            image_proxy: false

          ui:
            static_use_hash: true

          search:
            safe_search: 0
            autocomplete: ""
            default_lang: "en"
            formats:
              - html
              - json

          outgoing:
            request_timeout: 10.0
            max_request_timeout: 20.0
            pool_connections: 100
            pool_maxsize: 20
      register: searxng_settings

    - name: Create SearXNG data volume
      community.docker.docker_volume:
        name: searxng-data
        state: present

    - name: Deploy SearXNG container
      community.docker.docker_container:
        name: searxng
        image: "{{ searxng_image }}"
        state: started
        restart_policy: always
        # RISK-1: the tag floats. Pull only when the image is absent locally,
        # so a re-run can never silently swap the image underneath a working
        # deployment. First run on a clean box still pulls normally.
        pull: false
        recreate: "{{ searxng_settings is changed }}"
        published_ports:
          - "{{ searxng_listen_addr }}:{{ searxng_port }}:8080"
        volumes:
          - "{{ searxng_config_dir }}:/etc/searxng:rw"
          - "searxng-data:/var/cache/searxng:rw"
        env:
          SEARXNG_BASE_URL: "http://{{ lan_ip if searxng_listen_addr == '0.0.0.0' else searxng_listen_addr }}:{{ searxng_port }}/"
        cap_drop:
          - ALL
        capabilities:
          - CHOWN
          - SETGID
          - SETUID
          - DAC_OVERRIDE
        log_driver: json-file
        log_options:
          max-size: "1m"
          max-file: "1"

    - name: Create Docker volume for Open WebUI
      community.docker.docker_volume:
        name: open-webui-storage
        state: present

    - name: Deploy Open WebUI container
      community.docker.docker_container:
        name: open-webui
        image: "{{ openwebui_image }}"
        state: started
        restart_policy: always
        network_mode: host
        # RISK-1: see above. Also guards the storage volume against an
        # unintended major-version jump and its irreversible DB migration.
        # Pulls on first run (image absent); never re-pulls afterwards.
        pull: false
        comparisons:
          env: strict
          image: strict
        volumes:
          - "open-webui-storage:/app/backend/data"
        env:
          OLLAMA_BASE_URL: "http://{{ lan_ip }}:11434"
          ENABLE_PERSISTENT_CONFIG: "False"
          ENABLE_WEB_SEARCH: "True"
          WEB_SEARCH_ENGINE: "searxng"
          SEARXNG_QUERY_URL: "http://127.0.0.1:{{ searxng_port }}/search?q=<query>"
          WEB_SEARCH_RESULT_COUNT: "5"
          # Search-engine request concurrency (repurposed from the old RAG-era
          # page-fetch variable of the same name). 10 is still a sane value.
          WEB_SEARCH_CONCURRENT_REQUESTS: "10"

    # ────────────────────────────────────────────────────────────────────────
    # Verification
    # ────────────────────────────────────────────────────────────────────────

    - name: Wait for Open WebUI HTTP endpoint
      uri:
        url: "http://127.0.0.1:{{ webui_port }}/"
        method: GET
        status_code: [200, 302, 401]
      register: webui_wait
      retries: 18
      delay: 5
      until: webui_wait is succeeded
      ignore_errors: true

    - name: Test SearXNG JSON API
      uri:
        url: "http://127.0.0.1:{{ searxng_port }}/search?q=test&format=json"
        method: GET
        status_code: [200]
        return_content: true
      register: searxng_api_test
      retries: 12
      delay: 5
      until: searxng_api_test is succeeded
      ignore_errors: true

    - name: Test Ollama API
      uri:
        url: "http://{{ lan_ip }}:11434/api/tags"
        method: GET
        status_code: [200]
        timeout: 30
      register: ollama_api_test
      ignore_errors: true

    # RISK-1 mitigation: tags float, so record exactly which image is in service.
    - name: Inspect running containers
      community.docker.docker_container_info:
        name: "{{ item }}"
      loop:
        - open-webui
        - searxng
      register: ctr_info

    - name: Resolve image digests
      community.docker.docker_image_info:
        name: "{{ item.container.Image }}"
      loop: "{{ ctr_info.results | selectattr('exists') | list }}"
      loop_control:
        label: "{{ item.item }}"
      register: image_digests

    - name: Display final status
      debug:
        msg: |
          ════════════════════════════════════════════════════════════════
          GPU Box Ollama + Open WebUI Deployment v1.9 — Complete
          ════════════════════════════════════════════════════════════════
          Ollama API:       http://{{ lan_ip }}:11434
          Open WebUI:       http://{{ lan_ip }}:{{ webui_port }}
          SearXNG:          http://{{ searxng_listen_addr }}:{{ searxng_port }}
          LAN scope:        {{ lan_cidr }}
          Models:           {{ required_models | length }} configured
          Ollama API test:  {{ 'responding' if (ollama_api_test.status | default(0)) == 200 else 'NOT responding' }}
          SearXNG JSON:     {{ 'responding' if (searxng_api_test.status | default(0)) == 200 else 'NOT responding' }}
          Open WebUI HTTP:  {{ 'responding' if (webui_wait.status | default(0)) in [200, 302, 401] else 'NOT responding' }}
          ────────────────────────────────────────────────────────────────
          Images in service (tags float — record these):
          {% for r in image_digests.results %}
          {{ r.item.item }}: {{ (r.images | first).RepoDigests | default(['no-digest']) | first }}
          {% endfor %}
          ════════════════════════════════════════════════════════════════
```

---

## Verification Checklist

Substitute the LAN IP the script reported (it is auto-detected, not hard-coded).

- [ ] AMD compute device: `ls -l /dev/kfd /dev/dri/renderD*`
- [ ] Ollama service running: `sudo systemctl status ollama`
- [ ] Drop-in applied: `systemctl show ollama -p Environment`
- [ ] Ollama API listening: `ss -tulpn | grep 11434`
- [ ] Models installed: `ollama list` (expect 5)
- [ ] LAN API test: `curl http://<LAN_IP>:11434/api/tags`
- [ ] firewalld rules: `sudo firewall-cmd --list-rich-rules`
- [ ] Open WebUI container: `docker ps | grep open-webui`
- [ ] Image digests recorded (RISK-1): `grep "digest=" /var/log/gpu-box-llm-setup.log | tail -2`
- [ ] WebUI port listening: `ss -tulpn | grep 8080`
- [ ] LAN WebUI: `http://<LAN_IP>:8080`
- [ ] SearXNG running: `sudo docker ps | grep searxng`
- [ ] SearXNG bound to loopback only: `ss -tulpn | grep 8888` → expect `127.0.0.1:8888`
- [ ] SearXNG JSON API: `curl -s "http://127.0.0.1:8888/search?q=test&format=json" | head -c 100`
- [ ] SearXNG **not** reachable off loopback (run from the box or a peer): `curl --max-time 3 http://<LAN_IP>:8888` → expect connection refused
- [ ] Web Search toggle present under the Integrations control in the Open WebUI input bar
- [ ] GPU VRAM: `rocm-smi --showmeminfo vram`
- [ ] VRAM climbs during `ollama run qwen2.5-coder:14b` (confirms GPU offload, not CPU)

---

## Deployment

### Option 1: Bash (direct execution)

```bash
sudo bash gpu-box-llm-setup-v1.9.sh
```

### Option 2: Ansible (orchestrated)

```bash
ansible-galaxy collection install community.docker community.general ansible.posix

# Single host
ansible-playbook -i <gpu-box-ip>, -u <user> -K gpu-box-llm-setup-v1.9.yml

# Or from inventory
ansible-playbook -i inventory.ini gpu-box-llm-setup-v1.9.yml -l gpu-box
```

---

## Model Management

```bash
# Add another model
ollama pull mistral:7b

# List all models
ollama list

# Remove a model
ollama rm deepseek-r1:14b

# Check model details
ollama show qwen2.5-coder:14b

# Show what is currently resident in VRAM
ollama ps
```

---

## Troubleshooting

```bash
# Ollama won't start
sudo journalctl -u ollama -n 50

# Confirm the drop-in is actually in effect
systemctl show ollama -p Environment

# Open WebUI won't start
docker logs -f open-webui

# Models won't pull
df -h                                  # disk space
curl -I https://registry.ollama.ai     # Ollama's registry (not HuggingFace)

# Out of VRAM / model running on CPU
ollama ps                              # PROCESSOR column shows GPU vs CPU
rocm-smi --showmeminfo vram
rocminfo | grep -i gfx                 # then set HSA_OVERRIDE_GFX_VERSION if unsupported
# Reduce num_ctx or use a smaller model if the split is a capacity problem

# AMD GPU present but unused
ls -l /dev/kfd /dev/dri/renderD*       # device nodes must exist
id ollama                              # must be in render and video groups
sudo systemctl restart ollama

# SearXNG on the wrong port
# SEARXNG_BIND_ADDRESS and settings.yml server.port / server.bind_address are
# inert on current images. SEARXNG_PORT is honoured (entrypoint aliases it to
# GRANIAN_PORT), but this deployment doesn't pass it — the container listens on
# 8080 internally and the published Docker port decides the host port. If you
# insist on --network host, use Granian's variables:
#   -e GRANIAN_HOST=0.0.0.0 -e GRANIAN_PORT=8888
docker port searxng

# SearXNG returns 403 / HTML instead of JSON
grep -A5 "formats:" /etc/searxng/settings.yml    # 'json' must be present
docker restart searxng                            # config changes need a restart

# Open WebUI ignores the web-search env vars
# Those settings are ConfigVars persisted in the database. This deployment sets
# ENABLE_PERSISTENT_CONFIG=False so env wins. Confirm:
docker inspect open-webui | grep -i persistent_config

# LAN clients can't reach the stack
sudo firewall-cmd --list-rich-rules
sudo ss -tulpn | grep -E "11434|8080|8888"
```

---

## Uninstall

```bash
# Stop services
sudo systemctl stop ollama
sudo systemctl disable ollama
docker rm -f open-webui searxng

# Remove volumes  (open-webui-storage holds all chat history and settings)
docker volume rm searxng-data open-webui-storage
sudo rm -rf /etc/searxng

# Remove systemd unit and drop-in
sudo rm -f /etc/systemd/system/ollama.service
sudo rm -rf /etc/systemd/system/ollama.service.d
sudo systemctl daemon-reload

# Remove binary
sudo rm -f /usr/local/bin/ollama

# Remove firewall rules  (substitute your LAN network)
for p in 11434 8080 8888; do
  sudo firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 source address=192.168.0.0/24 port port=${p} protocol=tcp accept" 2>/dev/null
done
sudo firewall-cmd --reload

# Remove the CLI export
sed -i '/^export OLLAMA_HOST=/d' ~/.bashrc

# WARNING: `userdel -r` deletes /usr/share/ollama, which contains every pulled
# model blob (~31GB). Omit -r to keep them for a future reinstall.
sudo userdel -r ollama
sudo groupdel ollama 2>/dev/null || true

# Log file
sudo rm -f /var/log/gpu-box-llm-setup.log
```

---

## Version History

| Version | Date | Summary |
|---------|------|---------|
| 2.1 | 2026-10-15 | Ollama installer verification: the bash script and the Ansible playbook download the installer to a temp file and check it against an optional pinned SHA-256 (warn loudly when unset, refuse on mismatch) instead of piping curl into sh as root. Applied together with the public repo copies (PR #25) |
| 2.0 | 2026-10-07 | Added table of contents. No behaviour changes |
| 1.9 | 2026-09 | Verification corrections: SEARXNG_PORT honoured on current images (only SEARXNG_BIND_ADDRESS and settings.yml server.port/bind_address inert); HSA_OVERRIDE_GFX_VERSION values flagged as community-sourced; Nobara firewalld default unverified; WEB_SEARCH_CONCURRENT_REQUESTS semantics noted. No behaviour changes |
| 1.8 | 2026-07 | AMD-only. SearXNG port defect fixed (bridge + published port); Open WebUI env vars corrected and made authoritative; systemd drop-in; firewalld; pipefail guards; model idempotency; container lifecycle handling; Ansible Ollama-host and handler defects fixed. Image versions deliberately left floating (RISK-1) with digest capture and no-implicit-pull as compensating controls |
| 1.7 | — | Superseded — see Change Control |
