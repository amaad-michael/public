# OptiPlex llama.cpp Deployment & Tuning v2.3.0

> **Supersedes:** `optiplex-llm-setup-v1.5.md`, `optiplex-llm-setup-v1.5.sh`, `optiplex-cpu-optimization-v1.0.md`
> **Target:** Dell OptiPlex 790 (`OptiPlex790-LLM`), Intel Core i5-2400 (Sandy Bridge, 4C/4T), **8GB as 4 × 2GB DDR3, dual channel, clamped to 1067 MT/s by one mismatched module**, no GPU
> **OS:** Linux Mint 22.2, kernel 6.14 (HWE per the official 22.2 release notes — confirm on-host with `uname -r`)
> **SIMD:** AVX only — no AVX2, no F16C, no FMA (verified on-host)
> **Runtime:** llama.cpp `llama-server`, OpenAI-compatible HTTP API
> **Port:** 8080, **loopback by default**; API key required on every deployment, LAN exposure opt-in
> **Status:** Idempotent. Performance expectations rewritten from measured platform limits — read *Hardware Reality* before anything else.

---

## Table of Contents

- [Hardware Reality — read this first](#hardware-reality--read-this-first)
   - [What actually bounds throughput](#what-actually-bounds-throughput)
   - [[DECISION — DECLINED] Memory upgrade](#decision--declined-memory-upgrade)
   - [Memory budget — 8GB is a second, independent constraint](#memory-budget--8gb-is-a-second-independent-constraint)
   - [[DECISION] Model choice is the only *software* lever with real headroom](#decision-model-choice-is-the-only-software-lever-with-real-headroom)
- [Change Control — v1.5 + v1.0 → v2.0.x](#change-control--v15--v10--v20x)
   - [Corrections to verified defects](#corrections-to-verified-defects)
   - [[DECISION] Behaviour changes](#decision-behaviour-changes)
   - [RISK-1 — llama.cpp pinned to a moving branch (OPEN, accepted)](#risk-1--llamacpp-pinned-to-a-moving-branch-open-accepted)
- [Security posture](#security-posture)
- [Prerequisites](#prerequisites)
- [Deployment Script](#deployment-script)
- [Ansible Playbook](#ansible-playbook)
- [Build flags — what actually matters](#build-flags--what-actually-matters)
- [Tuning, ranked by actual effect](#tuning-ranked-by-actual-effect)
   - [Thread count](#thread-count)
   - [Editing the unit correctly](#editing-the-unit-correctly)
- [Generation parameters](#generation-parameters)
- [Benchmarking](#benchmarking)
- [Verification Checklist](#verification-checklist)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Open items](#open-items)
- [Version History](#version-history)

## Hardware Reality — read this first

The two source documents were built on five hardware assumptions that do not hold for an OptiPlex 790. Every performance figure in them followed from those assumptions, so the figures were wrong too.

| Claim in v1.5 / v1.0 | Actual | Consequence |
|---|---|---|
| "AVX2 optimization" build | **Verified on-host:** `grep -o -w -E 'avx\|avx2\|f16c\|fma' /proc/cpuinfo \| sort -u` returns `avx` and nothing else. AVX shipped with Sandy Bridge in 2011; AVX2 with Haswell in 2013; F16C with Ivy Bridge; FMA with Haswell | Every AVX2 build flag and every "AVX2: ✓" expected-output block is unreachable. The v1.5 script never crashed on this only because `-DLLAMA_AVX2=ON` is a renamed, ignored option — nothing ever tried to emit an AVX2 instruction — `-DLLAMA_AVX2=ON` is not a recognised CMake option (upstream sets `CMAKE_WARN_UNUSED_CLI`, so it warns and is ignored) |
| "16GB RAM" (optimization guide) / "8GB RAM minimum" (script header) | **8GB installed** — `7821 MiB total, 1380 MiB in use at idle`. The two source documents contradicted each other | The guide's "if memory approaches 14GB on a 16GB system, reduce batch-size" heuristic has no meaning here. See *Memory Budget* |
| "Do not exceed thread count of 8 on a quad-core (hyperthreading)" | i5-2400 is **4 cores / 4 threads. No hyperthreading** | `--threads 6/8/12` oversubscribes. 4 is the ceiling, not the floor |
| "Your OptiPlex likely has DDR4-3200 or DDR4-2400 … upgrading to DDR4-3200+ can yield 10–15%" | Platform is **DDR3, dual channel, 1333 supported**; currently populated with 4 × 2GB running at **1067 MT/s**. 4 slots / 16GB max on Mini-Tower, Desktop and SFF — the Ultra Small Form Factor has 2 slots / 8GB max (Dell OptiPlex 790 Owner's Manual). DDR4 is not physically installable | The DDR4 advice is inapplicable, but the *instinct* was not wrong — see *Memory upgrade*. The distinction the guide missed: RAM capacity and RAM bandwidth are separate levers, and only bandwidth moves tokens/sec |
| "BLAS rebuild yields 5–10x speedup (8 t/s → 50 t/s)" | llama.cpp's own build documentation states that BLAS may improve prompt processing at batch sizes above 32, and that CPU-only BLAS implementations do not affect normal generation performance | A BLAS rebuild will not change your tokens/sec for chat-style generation. See *Build flags* |

### What actually bounds throughput

Token generation streams the entire quantised weight set from RAM once per token. On this platform that is the whole story:

```
memory clock × 8 bytes × channels = theoretical bandwidth
tokens/sec ceiling = effective bandwidth ÷ resident weight size
```

**Measured configuration** — `dmidecode -t memory`:

```
ChannelA-DIMM0  2 GB  1067 MT/s
ChannelA-DIMM1  2 GB  1067 MT/s
ChannelB-DIMM0  2 GB  1067 MT/s
ChannelB-DIMM1  2 GB  1067 MT/s
```

This DMI table carries no `Configured Memory Speed` field, so `Speed:` here is the **operating** clock, not each module's rating — all four run at the array speed. Three of the four are in fact DDR3-1333 parts; see *Memory upgrade* for the per-module breakdown.

Dual channel is populated correctly. But the array runs at **1067 MT/s, not the 1333 the platform supports**, so the real figure is:

```
1067 MT/s × 8 bytes × 2 channels = 17.1 GB/s theoretical
Realistic sustained (~75%)       ≈ 12.8 GB/s
```

That is **20% below** the DDR3-1333 assumption this document was originally written against. The table below has been recomputed.

| Model | Q4_K_M size | Theoretical | **Realistic (75%) — operating baseline** | Conservative (65%) | At 1333 (declined, reference only) |
|---|---|---|---|---|---|
| Llama 3.1 8B | 4.92 GB | 3.5 t/s | **2.6 t/s** | 2.3 t/s | 3.3 t/s |
| Qwen2.5-Coder 7B | 4.68 GB | 3.6 t/s | 2.7 t/s | 2.4 t/s | 3.4 t/s |
| Llama 3.2 3B | 2.02 GB | 8.5 t/s | **6.3 t/s** | 5.5 t/s | 7.9 t/s |
| Qwen2.5-Coder 3B | 1.93 GB | 8.8 t/s | 6.6 t/s | 5.7 t/s | 8.3 t/s |
| Llama 3.2 1B | 0.81 GB | 21.1 t/s | 15.8 t/s | 13.7 t/s | 19.7 t/s |

These are **derived ceilings, not measurements** — arithmetic from the memory spec, which is the binding constraint. Only the **Llama 3.1 8B** and **Llama 3.2 3B** rows correspond to implemented presets; the others show how the ceiling scales with model size. Confirm with `llama-bench` (*Benchmarking*) before treating any of them as fact.

The v1.0 document's own "baseline without optimization: 2–5 t/s (unacceptable)" brackets the truth — the bottom of that range, ~2.6 t/s, is the correct steady-state figure for 8B on this hardware. The "8–15 t/s with BLAS" target it told you to chase does not exist on a 17 GB/s memory subsystem. No build flag, thread count, batch size, governor setting or affinity mask moves a memory-bound workload past its bandwidth ceiling.

### [DECISION — DECLINED] Memory upgrade

**Decision: keep all four modules and the 8GB capacity. The 1067 MT/s clock and the ~25% throughput cost are accepted.** Nothing below is an outstanding action item; it is recorded so the number is explained rather than mysterious, and so the option is costed if the trade is ever revisited.

Operating baseline: **17.1 GB/s, ~6.3 t/s on the 3B preset.**

#### Why the clock is 1067

Module inventory, decoded from `dmidecode -t memory`:

| Slot | Part number | Rated speed | Rank (per on-host dmidecode) |
|---|---|---|---|
| ChannelA-DIMM0 | Elpida `EBJ20UF8BCF0-DJ-F` | PC3-10600 / **DDR3-1333** CL9 | 1 |
| ChannelA-DIMM1 | Elpida `EBJ20UF8BCF0-DJ-F` | PC3-10600 / **DDR3-1333** CL9 | 1 |
| **ChannelB-DIMM0** | Hynix `HMT125U6TFR8C-`**`G7`** | PC3-8500 / **DDR3-1066** CL7 | **2** |
| ChannelB-DIMM1 | Hynix `HMT325U6BFR8C-`**`H9`** | PC3-10600 / **DDR3-1333** | 1 |

The Hynix `-G7` suffix denotes PC3-8500 DDR3-1066, CL7; `-H9` on the otherwise identical Hynix part denotes PC3-10600 DDR3-1333. The Elpida part is PC3-10600 DDR3-1333 CL9. Those are the speed grades, confirmed against vendor documentation. The rank column above is as reported by the on-host `dmidecode` output — rank was not independently confirmed against a manufacturer datasheet.

**Three of the four modules are DDR3-1333. One DDR3-1066 stick in ChannelB-DIMM0 is clamping the whole array to 1067 MT/s** — a memory controller runs every channel at the slowest installed module's speed. That single stick is costing ~25% of inference throughput.

Per that same dmidecode output it is also the only dual-rank module, which would put three ranks on channel B against two on channel A — an electrical asymmetry on top of the speed mismatch, if the rank reporting is accurate.

#### If revisited later

The zero-capacity-loss path is replacing the single G7 module with any 2GB DDR3-1333 1Rx8 stick — that keeps 8GB and recovers the 25%. Pulling the G7 outright would confirm the diagnosis for free but drops the box to 6GB, which is why it was declined.

#### Options, for reference

| Option | Capacity | Expected clock | Bandwidth | 3B throughput | Cost |
|---|---|---|---|---|---|
| **Leave as-is — SELECTED** | **8GB** | **1067** | **17.1 GB/s** | **~6.3 t/s** | **—** |
| **Replace the G7 with any 2GB DDR3-1333 1Rx8** | 8GB | 1333 | 21.3 GB/s | **~7.9 t/s** | one cheap stick |
| **2 × 4GB DDR3-1333, one per channel** | 8GB | 1333 | 21.3 GB/s | **~7.9 t/s** | two sticks, cleanest electrically |
| 4 × 4GB DDR3-1333 | 16GB | 1333 (2 DPC may drop it) | 17.1–21.3 GB/s | 6.3–7.9 t/s | four sticks |

> **Caveat if revisited:** SPD-rated speed is what the part numbers establish. Whether the board actually clocks to 1333 with two DIMMs per channel is empirical and would need testing.

Note for expectation-setting: this was the only *hardware* change on this box that moves tokens/sec. With it declined, **~6.3 t/s on the 3B preset is the ceiling**, and no software knob in *Tuning* will beat it. Measure against that number, not against the 1333 column.

### Memory budget — 8GB is a second, independent constraint

Measured idle: **7821 MiB total, 1380 MiB in use**, leaving ~6.3 GiB for inference.

| | 3B preset | 8B preset |
|---|---|---|
| Weights (Q4_K_M) | 1.88 GiB | 4.58 GiB |
| KV cache | 0.44 GiB @ 4096 ctx | 0.25 GiB @ 2048 ctx |
| Compute buffers | ~0.25 GiB | ~0.30 GiB |
| **Resident total** | **~2.6 GiB** | **~5.1 GiB** |
| Headroom from 6.3 GiB | 3.7 GiB | **1.2 GiB** |

The 8B preset fits, but with roughly 1.2 GiB of slack — a package upgrade or a build erases that. And `--mlock` pins 4.58 GiB, so under pressure the kernel has only that 1.2 GiB to reclaim from before it starts killing things. Pinning is a good trade when there is comfortable slack behind it and a bad one when there is not; at 3B there is, at 8B there is not.

`--mlock` is therefore enabled for the 3B preset and disabled for the 8B preset by default. Override with `USE_MLOCK`.

If the 8B model ever does get paged, throughput does not degrade gracefully — it collapses, because every token then waits on disk instead of RAM.

### [DECISION] Model choice is the only *software* lever with real headroom

Everything in the old optimization guide's Section 12 added up to a claimed 10–15%. Dropping from 8B to 3B is worth roughly **2.4x** — ~2.6 t/s to ~6.3 t/s at the current memory clock. That is the difference between unusable and usable for interactive work.

`MODEL_PRESET` at the top of the script selects between them. Default is `llama3.2-3b`: ~6.3 t/s of a competent 3B beats ~2.6 t/s of a stronger 8B for shell/Ansible scripting, and on 8GB it is the difference between comfortable and one browser tab away from swapping. Set `MODEL_PRESET="llama3.1-8b"` to keep the v1.5 model — it fits, but see *Memory Budget* first.

---

## Change Control — v1.5 + v1.0 → v2.0.x

### Corrections to verified defects

| # | Change | Reason |
|---|---|---|
| 1 | `-DLLAMA_NATIVE=ON -DLLAMA_AVX2=ON` → `-DGGML_NATIVE=ON` | Some legacy `LLAMA_*` build options were remapped to `GGML_*` — `LLAMA_NATIVE` → `GGML_NATIVE` emits a deprecation warning and is honoured through the new name, not ignored. The rename was not blanket: many legitimate `LLAMA_*` options remain (e.g. `LLAMA_BUILD_SERVER`, `LLAMA_BUILD_EXAMPLES`). `-DLLAMA_AVX2=ON` was never a recognised option at all — upstream sets `CMAKE_WARN_UNUSED_CLI`, so it warns and is ignored. Either way, the v1.5 build was never configured the way its comments claimed |
| 2 | Clone URL `ggerganov/llama.cpp` → `ggml-org/llama.cpp` | Upstream org renamed. The old URL still redirects, but the canonical path is `ggml-org` |
| 3 | AVX2 references removed throughout | Not present on Sandy Bridge. Build now detects and logs the actual CPU flag set |
| 4 | `libcurl4-openssl-dev` retained in build dependencies | The old claim — "recent llama.cpp defaults `LLAMA_CURL=ON`, so CMake fails without the headers" — is stale: current upstream `CMakeLists.txt` marks `LLAMA_CURL` as deprecated and ignored. The package is kept only for pinned older refs that still honour the option |
| 5 | Service no longer runs as `root` | v1.5 ran as root "to avoid Permission denied errors". The actual cause was installing under `$SUDO_USER`'s home with `ProtectHome`-hostile paths and a `chown -R llm:llm` that fought the service user. v2.0 installs to `/opt/llama.cpp` and `/var/lib/llm`, which removes the cause instead of escalating around it |
| 6 | Contradictory paths reconciled | v1.5 installed to `~/projects` and `~/models`; v1.0's systemd template hardcoded `/home/llm/projects` and `/home/llm/models`. Neither matched the other, so v1.0's service file could not have started against a v1.5 install |
| 7 | Model filename reconciled | v1.5 wrote `Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf`; v1.0's `ExecStart` referenced `Llama-3.1-8B-Instruct-Q4_K_M.gguf` (no `Meta-` prefix). Applying v1.0's template to a v1.5 install would fail on a missing model file |
| 8 | `sudo systemctl edit llama-server` guidance corrected | A drop-in that sets `ExecStart=` without first clearing it with an empty `ExecStart=` produces a second entry and a `Type=simple` unit fails to start. The v1.0 guide's thread-configuration section told you to add the line directly |
| 9 | `llama-cli --info` replaced with `llama-cli --version` and `llama-bench` | `--info` is not a llama.cpp flag. The "Expected output: BLAS: ✓ OpenBLAS enabled / AVX2: ✓" block does not correspond to any llama.cpp output format |
| 10 | `--batch-size 32` removed | Two problems: BLAS only engages **above** batch 32, so v1.0 simultaneously told you to enable BLAS and to configure the one value that disables it; and shrinking the logical batch slows prompt ingestion for no generation benefit. Defaults are correct here |
| 11 | `IOSchedulingClass=realtime` removed | Realtime I/O priority can starve every other process on a single-disk box, and requires privileges the hardened unit no longer has. Not worth 1–2% on a memory-bound workload |
| 12 | `LimitMEMLOCK=infinity` retained but `--mlock` made conditional | v1.0 raised the limit without ever passing `--mlock`, so it did nothing. v2.0 keeps the limit (harmless when unused) and passes `--mlock` only for the 3B preset — see *Memory Budget*. On the 8B preset the directive is deliberately inert |
| 13 | `CPUAffinity=0-3` + `taskset -c 0,1,2,3` de-duplicated | Both were specified; on a 4-core box pinning to all 4 cores is a no-op anyway |
| 14 | "systemd doesn't support backslash continuations" comment deleted | It does. The single-line `ExecStart` is fine, but the stated reason was false |
| 15 | Unguarded pipelines given `\|\| true`; root check moved above first `log` | `gcc --version \| head -1 \| tee`, `ls \| tee`, `systemctl status \| head \| tee` each abort under `set -euo pipefail`. `log()` writes through `tee -a /var/log/...`, so as non-root it failed silently before ever printing "Must run as root" |
| 16 | `REAL_USER_HOME=$(getent passwd … \| cut -d: -f6)` guarded | Under `pipefail`, getent's exit 2 for an unknown user propagates and aborts the script on line 20 |
| 17 | `sleep 3` / `sleep 5` readiness replaced with polling on `/health` | An 8B model takes far longer than 8 seconds to mmap and warm on this hardware, so the v1.5 API test was structurally guaranteed to report "inconclusive" |
| 18 | Model download now verified by SHA-256 | v1.5 accepted any 5GB blob wget produced, including a truncated one or an HTML error page |
| 19 | `wget -q --show-progress … 2>/tmp/wget.log` fixed | `--show-progress` writes to stderr, which was redirected — the progress bar it was asking for could never appear |
| 20 | Commented-out CLI test block deleted | Dead code |
| 21 | Ansible: `ansible_user_dir` under `become: yes` no longer used for paths | Resolves to root's home when privilege escalation is active, so the playbook and the script installed to different locations |
| 22 | RAM figure corrected to the measured 8GB; `--mlock` made preset-conditional; the guide's 14GB-of-16GB batch-size heuristic removed | Sources claimed 8GB and 16GB in different places. At 8GB the 8B preset leaves ~1.2 GiB headroom, so unconditionally pinning 4.58 GiB was the wrong default |
| 23 | Self-certification removed | "Accuracy: 98% (verified against 25+ sources)", "60+ technical claims validated" — unverifiable, and five of the load-bearing claims were wrong |

### [DECISION] Behaviour changes

| # | Change | Default | Revert |
|---|---|---|---|
| A | Default model 8B → 3B | `MODEL_PRESET="llama3.2-3b"` | `MODEL_PRESET="llama3.1-8b"` |
| B | API bound to loopback, not `0.0.0.0` | `BIND_ADDR="127.0.0.1"` | `BIND_ADDR="0.0.0.0"` — also adds a LAN-scoped ufw rule **if ufw is active**, and restricts CORS. It does not change `REQUIRE_API_KEY`, which is independent |
| C | API key generated and required **on every deployment, loopback included** | `REQUIRE_API_KEY="yes"`; key auto-generated to `/etc/llm/api-key`, `root:llm` mode 0640 (the service user must read it) | `REQUIRE_API_KEY="no"` |
| D | Install paths moved to `/opt/llama.cpp` + `/var/lib/llm` | — | — |
| E | BLAS not built by default | `ENABLE_BLAS="no"` | `ENABLE_BLAS="yes"` (helps prompt ingestion only) |

### RISK-1 — llama.cpp pinned to a moving branch (OPEN, accepted)

`LLAMA_CPP_REF` defaults to `master`. Every run records the resolved commit to the log, so the exact tree that produced a working binary is always recoverable. To pin, set `LLAMA_CPP_REF` to a release tag (`git ls-remote --tags --sort=-v:refname https://github.com/ggml-org/llama.cpp | head -20` — plain `ls-remote | tail` sorts lexicographically, so it returns `b9xx`, not the newest build) and re-run.

---

## Security posture

`llama-server` defaults to binding `127.0.0.1`, and with no API key configured it responds to every request. Both source documents overrode the safe default with `--host 0.0.0.0` while adding neither an API key nor a firewall rule — an unauthenticated inference endpoint reachable by anything on the LAN, with CORS defaulting to `*`.

v2.0 defaults to loopback **and** generates a required API key on every deployment, exposed or not. If you need the GPU box to reach this endpoint, set `BIND_ADDR="0.0.0.0"`; the script additionally restricts CORS and adds a ufw rule scoped to the detected LAN network rather than opening the port to the world.

---

## Prerequisites

- Dell OptiPlex 790 (or any Sandy-Bridge-era x86-64 box), Linux Mint 22.2 / Ubuntu 24.04
- Root or passwordless sudo
- **8GB RAM** — confirmed installed. Comfortable for the 3B preset; see *Memory Budget* before selecting 8B
- **~15GB free disk** — build tree ≈ 3GB, 3B model ≈ 2GB, 8B model ≈ 5GB
- Network access to `github.com` and `huggingface.co`
- For the Ansible path only: `ansible-galaxy collection install community.general`

> Both source documents were wrong about RAM in opposite directions — 8GB in the script header, 16GB in the optimization guide, with tuning advice keyed to the latter. 8GB is the measured figure.

---

## Deployment Script

Save as `optiplex-llm-setup-v2.1.sh`:

```bash
sudo bash optiplex-llm-setup-v2.1.sh
```

**Full script:**

```bash
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

# TODO(RISK-1): moving branch. Pin to a release tag once one is selected.
# The resolved commit is written to $LOG_FILE on every run.
LLAMA_CPP_REF="${LLAMA_CPP_REF:-master}"
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
```

---

## Ansible Playbook

Same end state, for repeatable runs.

**Requires one collection beyond `ansible-core`:**

```bash
ansible-galaxy collection install community.general
```

`community.general` supplies the `random_string` lookup and the `ufw` module. The `ufw` task only runs when the API is exposed off loopback, so a loopback-only deployment exercises the lookup alone.

```yaml
---
- name: OptiPlex llama.cpp deployment v2.1.0
  hosts: optiplex
  become: true
  gather_facts: true

  vars:
    llama_dir: /opt/llama.cpp
    src_dir: /usr/local/src/llama.cpp
    models_dir: /var/lib/llm/models
    conf_dir: /etc/llm
    llm_user: llm
    server_port: 8080
    bind_addr: "127.0.0.1"
    require_api_key: true
    enable_blas: false
    llama_cpp_ref: master            # TODO(RISK-1): pin to a release tag
    model_preset: llama3.2-3b
    # OPEN-1: no upstream checksum manifest exists; capture from a known-good
    # download and paste the hash here to enable verification.
    model_sha256: ""
    model_presets:
      llama3.2-3b:
        name: Llama-3.2-3B-Instruct-Q4_K_M
        url: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        ctx_size: 4096
        mlock: true          # ~2.6 GiB resident against ~6.3 GiB free
      llama3.1-8b:
        name: Meta-Llama-3.1-8B-Instruct-Q4_K_M
        url: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
        ctx_size: 2048
        mlock: false         # ~5.1 GiB resident: locking starves everything else

  pre_tasks:
    - name: Resolve model preset
      set_fact:
        model: "{{ model_presets[model_preset] }}"

    - name: Assert apt-based x86-64 host
      assert:
        that:
          - ansible_os_family == "Debian"
          - ansible_architecture == "x86_64"
        fail_msg: "Requires an apt-based x86-64 host"

    # ansible_processor / ansible_processor_vcpus / ansible_processor_flags are
    # gathered facts and are not guaranteed on every platform — the flag checks
    # below fall back to [] rather than failing.
    - name: Report CPU SIMD support
      debug:
        msg: >-
          CPU={{ ansible_processor[2] if ansible_processor | length > 2 else 'unknown' }}
          cores={{ ansible_processor_vcpus }}
          avx={{ 'avx' in ansible_processor_flags | default([]) }}
          avx2={{ 'avx2' in ansible_processor_flags | default([]) }}

  tasks:
    # libcurl4-openssl-dev: current upstream CMakeLists.txt marks LLAMA_CURL as
    # deprecated-and-ignored — no longer a hard build requirement on master.
    # Kept for pinned older refs that still honour the option.
    - name: Install build dependencies
      apt:
        name: "{{ base_pkgs + (blas_pkgs if enable_blas else []) }}"
        state: present
        update_cache: true
        cache_valid_time: 3600
      vars:
        base_pkgs: [git, cmake, build-essential, pkg-config, libcurl4-openssl-dev, curl, ca-certificates]
        blas_pkgs: [libopenblas-dev]

    - name: Create service user
      user:
        name: "{{ llm_user }}"
        system: true
        create_home: false
        shell: /usr/sbin/nologin
        state: present

    - name: Create directories
      file:
        path: "{{ item.path }}"
        state: directory
        owner: root
        group: "{{ item.group }}"
        mode: "{{ item.mode }}"
      loop:
        - { path: "{{ llama_dir }}", group: root, mode: '0755' }
        - { path: "{{ models_dir }}", group: "{{ llm_user }}", mode: '0755' }
        - { path: "{{ conf_dir }}", group: "{{ llm_user }}", mode: '0750' }

    - name: Clone or update llama.cpp
      git:
        repo: https://github.com/ggml-org/llama.cpp
        dest: "{{ src_dir }}"
        version: "{{ llama_cpp_ref }}"
        force: true
      register: llama_src

    - name: Read previously built commit
      slurp:
        src: "{{ llama_dir }}/.build-commit"
      register: build_stamp
      failed_when: false

    - name: Decide whether a rebuild is required
      set_fact:
        need_build: >-
          {{ (build_stamp.content is not defined)
             or ((build_stamp.content | b64decode | trim) != llama_src.after) }}

    - name: Configure, build and install llama.cpp
      when: need_build | bool
      block:
        - name: Configure CMake
          command:
            argv: >-
              {{ ['cmake', '-B', src_dir + '/build', '-S', src_dir,
                  '-DCMAKE_BUILD_TYPE=Release',
                  '-DCMAKE_INSTALL_PREFIX=' + llama_dir,
                  '-DGGML_NATIVE=ON']
                 + (['-DGGML_BLAS=ON', '-DGGML_BLAS_VENDOR=OpenBLAS'] if enable_blas else []) }}

        - name: Compile
          command: "cmake --build {{ src_dir }}/build --config Release -j{{ ansible_processor_vcpus }}"

        - name: Install
          command: "cmake --install {{ src_dir }}/build"

        # The install manifest does not necessarily cover every tool.
        - name: Reconcile binaries from the build tree
          copy:
            src: "{{ src_dir }}/build/bin/{{ item }}"
            dest: "{{ llama_dir }}/bin/{{ item }}"
            remote_src: true
            mode: '0755'
            force: false
          loop: [llama-server, llama-cli, llama-bench]
          failed_when: false

        - name: Record built commit
          copy:
            dest: "{{ llama_dir }}/.build-commit"
            content: "{{ llama_src.after }}\n"
            owner: root
            group: root
            mode: '0644'

    # OPEN-1: set model_sha256 to enable verification. get_url will delete a
    # file that fails the checksum, so a corrupt download cannot be left behind.
    - name: Download model
      get_url:
        url: "{{ model.url }}"
        dest: "{{ models_dir }}/{{ model.name }}.gguf"
        checksum: "{{ ('sha256:' + model_sha256) if model_sha256 | length > 0 else omit }}"
        owner: root
        group: "{{ llm_user }}"
        mode: '0640'
        timeout: 60
      register: model_dl
      retries: 3
      delay: 10
      until: model_dl is succeeded

    # KNOWN DIVERGENCE: get_url does not resume a partial transfer the way the
    # bash path's `curl -C -` does. An interrupted multi-GB download restarts.
    - name: Warn when the model is unverified
      debug:
        msg: "MODEL CHECKSUM NOT VERIFIED — set model_sha256 (see OPEN-1)"
      when: model_sha256 | length == 0

    - name: Generate API key
      when: require_api_key | bool
      block:
        - name: Check for an existing key
          stat:
            path: "{{ conf_dir }}/api-key"
          register: api_key_stat

        - name: Create API key
          when: not api_key_stat.stat.exists
          copy:
            dest: "{{ conf_dir }}/api-key"
            content: "{{ lookup('community.general.random_string', length=64, chars=['ascii_letters','digits']) }}\n"
            owner: root
            group: "{{ llm_user }}"
            mode: '0640'

    # NOTE: ansible_default_ipv4.prefix is not a documented gathered fact, so
    # the CIDR is derived from the documented address/netmask via python3
    # rather than trusting an undocumented field.
    - name: Derive LAN CIDR from address and netmask
      when: bind_addr != '127.0.0.1'
      ansible.builtin.command:
        argv:
          - python3
          - -c
          - "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1] + '/' + sys.argv[2], strict=False))"
          - "{{ ansible_default_ipv4.address }}"
          - "{{ ansible_default_ipv4.netmask }}"
      register: lan_cidr
      changed_when: false

    - name: Allow LAN access when the API is not loopback-only
      when: bind_addr != '127.0.0.1'
      community.general.ufw:
        rule: allow
        port: "{{ server_port }}"
        proto: tcp
        src: "{{ lan_cidr.stdout }}"

    - name: Deploy systemd unit
      copy:
        dest: /etc/systemd/system/llama-server.service
        owner: root
        group: root
        mode: '0644'
        content: |
          [Unit]
          Description=llama.cpp inference server
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          User={{ llm_user }}
          Group={{ llm_user }}
          ExecStart={{ llama_dir }}/bin/llama-server --model {{ models_dir }}/{{ model.name }}.gguf --host {{ bind_addr }} --port {{ server_port }} --threads {{ ansible_processor_vcpus }} --threads-batch {{ ansible_processor_vcpus }} --ctx-size {{ model.ctx_size }} --temp 0.2 --top-p 0.95 --min-p 0.01{{ ' --mlock' if model.mlock else '' }}{{ ' --api-key-file ' + conf_dir + '/api-key' if require_api_key else '' }}{{ ' --cors-origins localhost' if bind_addr != '127.0.0.1' else '' }}
          Restart=on-failure
          RestartSec=10
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
      register: unit_file

    - name: Enable and (re)start llama-server
      systemd:
        name: llama-server
        state: "{{ 'restarted' if (unit_file is changed or need_build | bool) else 'started' }}"
        enabled: true
        daemon_reload: true

    - name: Wait for the model to load
      uri:
        url: "http://127.0.0.1:{{ server_port }}/health"
        status_code: [200]
      register: health
      retries: 60
      delay: 10
      until: health is succeeded
```

---

## Build flags — what actually matters

**Use exactly this:**

```bash
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
```

`GGML_NATIVE=ON` compiles with `-march=native`, which on the i5-2400 selects AVX — the only 256-bit extension this CPU has — and nothing that would `SIGILL`. It is on by default; specifying it is documentation, not configuration.

**Do not use:**

| Flag | Why not |
|---|---|
| `-DLLAMA_NATIVE=ON` | Deprecated in favour of `GGML_NATIVE` — still honoured through the remap (with a warning), not ignored. Pass `GGML_NATIVE` directly |
| `-DLLAMA_AVX2=ON` | Not a recognised CMake option — warned-and-ignored via `CMAKE_WARN_UNUSED_CLI`. **And** the instruction set does not exist on this CPU |
| `-DGGML_AVX2=ON` | Would produce `SIGILL` on first inference. This is the live-ammunition version of the ignored flag v1.5 was passing |
| `-DGGML_FMA=ON`, `-DGGML_F16C=ON` | Also absent on this CPU. Same failure mode |

**BLAS, honestly:** llama.cpp's build documentation is explicit that BLAS support may improve prompt processing at batch sizes above 32, and that CPU-only BLAS does not affect normal generation performance. Independent reports put the prompt-ingestion gain at roughly 2–3x for prompt ingestion, with no effect on subsequent generation.

So: if you paste 2,000-token files into the model regularly, `ENABLE_BLAS="yes"` will shorten the wait before the first token. If you chat, it changes nothing. It will never turn 3 t/s into 50 t/s, and the v1.0 guide's simultaneous advice to enable BLAS *and* set `--batch-size 32` cancelled itself out — 32 is the threshold below which BLAS is not used at all.

Verify what you built with:

```bash
/opt/llama.cpp/bin/llama-server --version
/opt/llama.cpp/bin/llama-cli -m <model> -p "x" -n 1 2>&1 | grep -i "system_info"
```

There is no `--info` flag.

---

## Tuning, ranked by actual effect

| Lever | Realistic effect | Notes |
|---|---|---|
| **Smaller model** (8B → 3B) | **~2.4x** | The only large software lever. Bandwidth-bound throughput scales inversely with model size |
| `--threads 4` | baseline | 4 physical cores, no HT. More threads contend for the same memory bus |
| `--ctx-size` | indirect | Larger context grows the KV cache and the per-token attention read. 2048 for 8B, 4096 for 3B |
| `--mlock` | prevents cliff | Stops weights being paged out. Adds no speed; avoids losing all of it. On 8GB, enabled for 3B, disabled for 8B — see *Memory Budget* |
| BLAS | prompt only | See *Build flags* |
| CPU governor `performance` | 2–5% | Real but small. Costs power and heat |
| CPU affinity / `taskset` | ~0% on 4 cores | Pinning 4 threads to 4 cores is what the scheduler already does |
| `OPENBLAS_NUM_THREADS=1` | only if BLAS built | Prevents OpenBLAS spawning threads that fight llama.cpp's. Irrelevant without BLAS |
| ~~RAM re-clock~~ | ~~~25%~~ | **Declined** — 8GB capacity kept, 1067 MT/s accepted. See *Memory upgrade* |

### Thread count

```bash
# The service already uses nproc. To test alternatives without editing the unit:
sudo systemctl stop llama-server
# sudo required: the model is 0640 root:llm
sudo /opt/llama.cpp/bin/llama-bench -m /var/lib/llm/models/<model>.gguf -t 2,4,8
```

Expect 4 to win and 8 to be worse or equal — there are only 4 hardware threads.

### Editing the unit correctly

`systemctl edit` creates a drop-in. For a `Type=simple` unit, `ExecStart` must be cleared before it is set again, or systemd reports more than one `ExecStart` and the service refuses to start:

```ini
[Service]
ExecStart=
ExecStart=/opt/llama.cpp/bin/llama-server --model ... --threads 4
```

The empty first line is mandatory. The v1.0 guide omitted it.

---

## Generation parameters

Already set in the unit; these are for API-side overrides.

```
--temp 0.2      deterministic enough for shell/Ansible generation
--top-p 0.95
--min-p 0.01
```

These affect output quality, not speed. Sampling is a rounding error next to the per-token memory read.

---

## Benchmarking

Use `llama-bench`, not `curl` + `time`. It separates prompt processing (`pp`) from token generation (`tg`), which is the exact distinction that made the BLAS claims in v1.0 wrong, and it excludes HTTP and JSON overhead.

```bash
sudo systemctl stop llama-server

# sudo required: the model is 0640 root:llm
sudo /opt/llama.cpp/bin/llama-bench \
  -m /var/lib/llm/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
  -t 4 -p 512 -n 128 -r 3

sudo systemctl start llama-server
```

Read the `tg128` row. That is your real tokens/sec. Compare it against the ceiling table in *Hardware Reality*: if you are within ~20% of the 75% column, the build is fine and there is nothing left to tune. If you are far below, check that nothing else is competing for RAM, and — on the 3B preset only — that `--mlock` took effect.

End-to-end HTTP timing, once you have a `tg` baseline to compare against:

```bash
KEY=$(sudo cat /etc/llm/api-key)
time curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KEY" \
  -d '{"messages":[{"role":"user","content":"Write a bash function to parse a CSV"}],"max_tokens":200}' \
  | python3 -m json.tool | tail -20
```

---

## Verification Checklist

- [ ] Service active: `systemctl status llama-server` → `active (running)`
- [ ] Running as `llm`, not root: `ps -o user= -C llama-server`
- [ ] Bound where you expect: `sudo ss -tlnp | grep 8080` → `127.0.0.1:8080` unless deliberately exposed
- [ ] Health endpoint: `curl -fsS http://127.0.0.1:8080/health`
- [ ] Public-by-design endpoints stay open: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v1/models` → `200`. Upstream intentionally leaves `/v1/models`, `/health` and `/models` unauthenticated, so a 401 here would mean something else broke
- [ ] Auth enforced on inference: same shape against `/v1/chat/completions` with no key → `401`
- [ ] Auth accepted: same call with `-H "Authorization: Bearer $(sudo cat /etc/llm/api-key)"` → `200` (fine interactively; the script itself passes the key via `curl --config` so it never reaches `ps`)
- [ ] Built commit recorded: `cat /opt/llama.cpp/.build-commit`
- [ ] Model checksum recorded in the log: `grep -A1 "Computed hash" /var/log/optiplex-llm-setup.log`
- [ ] Baseline captured: `llama-bench` `tg128` figure written down
- [ ] Weights locked in RAM (3B preset only): `grep VmLck /proc/$(pgrep -x llama-server | head -1)/status` → non-zero
- [ ] Resident size within budget: `ps -o rss= -C llama-server` → ~2.6 GiB (3B) or ~5.1 GiB (8B)
- [ ] Not swapping under load: `vmstat 1 5` during a generation, `si`/`so` stay at 0

---

## Troubleshooting

```bash
# Service won't start
journalctl -u llama-server -n 50 --no-pager

# status=203/EXEC
# Binary missing or not executable, or a hardening directive blocks its path.
ls -l /opt/llama.cpp/bin/llama-server
sudo -u llm /opt/llama.cpp/bin/llama-server --version    # run it as the service user

# status=226/NAMESPACE
# ProtectSystem/ProtectHome blocking a path. If you moved the model back under
# a user home, that is the cause — keep it in /var/lib/llm.
systemd-analyze security llama-server

# "Permission denied" reading the model
ls -l /var/lib/llm/models/          # expect root:llm 0640
id llm

# CMake warns "LLAMA_CURL is deprecated and will be ignored"
# Expected on current master — the option does nothing there. Only add
# libcurl4-openssl-dev back if you pinned an older ref that still uses it.

# CMake warns "LLAMA_NATIVE is deprecated"
# You are passing a renamed option. Use GGML_NATIVE.

# Inference is far slower than the ceiling table predicts
grep VmLck /proc/$(pgrep -x llama-server | head -1)/status   # 0 is expected on the 8B preset
free -h                                            # swap in use = throughput collapse
ps -o rss=,vsz= -C llama-server                    # compare against the Memory Budget table
sudo systemctl stop llama-server                        # avoid a 2nd resident copy
sudo /opt/llama.cpp/bin/llama-bench -m <model> -t 4      # sudo: model is 0640 root:llm
sudo systemctl start llama-server

# 401 on every request
sudo cat /etc/llm/api-key
# Header must be:  Authorization: Bearer <key>

# Port in use
sudo lsof -i :8080
```

---

## Uninstall

```bash
sudo systemctl stop llama-server
sudo systemctl disable llama-server
sudo rm -f /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload

sudo rm -rf /opt/llama.cpp /usr/local/src/llama.cpp

# WARNING: removes the downloaded model (2–5GB depending on preset)
sudo rm -rf /var/lib/llm

sudo rm -rf /etc/llm
sudo userdel llm 2>/dev/null || true

# Firewall rule, only if the API was exposed
sudo ufw status numbered | grep 8080     # then: sudo ufw delete <number>

sudo rm -f /var/log/optiplex-llm-setup.log
```

---

## Open items

| ID | Item | Resolution |
|---|---|---|
| RISK-1 | `llama.cpp` tracks `master` | Pin `LLAMA_CPP_REF` to a release tag. Resolved commit is logged every run |
| OPEN-1 | `MODEL_SHA256` / `model_sha256` unset | 3B preset RESOLVED 2026-10-17: `Llama-3.2-3B-Instruct-Q4_K_M.gguf` (2,019,377,696 bytes) SHA-256 `6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff`, captured from the verified download used for the OptiPlex container stack and matching the Hugging Face published hash for the file — paste it into both the script and the playbook to enable verification on the 3B preset. 8B preset still uncaptured: no upstream checksum manifest exists for these GGUF files, so capture the hash from a first known-good download. Until then both paths warn and proceed |
| OPEN-2 | Ceiling table is derived, not measured | Run `llama-bench` and replace the table's estimates with real `tg` figures for this box |
| ~~OPEN-3~~ | ~~Actual RAM unconfirmed~~ | **CLOSED** — 8GB measured (7821 MiB total). Budget table added; `--mlock` defaults now derive from it |
| ~~OPEN-4~~ | ~~SIMD capability assumed~~ | **CLOSED** — verified on-host: `avx` only. No AVX2, F16C or FMA |
| ~~OPEN-5~~ | ~~Memory channel population unverified~~ | **CLOSED** — dual channel confirmed (ChannelA-DIMM0/1, ChannelB-DIMM0/1), 4 × 2GB @ 1067 MT/s. Ceilings recomputed at 17.1 GB/s, 20% below the original DDR3-1333 assumption |
| ~~OPEN-6~~ | ~~Memory running at 1067, not 1333~~ | **CLOSED — root cause found.** Three modules are DDR3-1333; one Hynix `HMT125U6TFR8C-G7` (DDR3-1066, dual rank) in ChannelB-DIMM0 clamps the array. See *Memory upgrade* |
| ~~OPEN-7~~ | ~~Does the board hold 1333 with 2 DIMMs per channel?~~ | **CLOSED — not pursued.** Memory upgrade declined; 8GB @ 1067 accepted as the operating configuration |

---

## Version History

- **v2.3 (2026-10-17):** OPEN-1 updated for the 3B preset: the model's SHA-256 was captured from the verified download used for the OptiPlex container stack (see Open items). No deployment changes; scripts and procedures unchanged.
- **v2.2 (2026-10-07):** Added table of contents. No deployment changes; scripts and procedures unchanged.

| Version | Date | Summary |
|---|---|---|
| 2.1.0 | 2026-09 | Nine verification corrections: kernel 6.17 → 6.14 HWE (verify with `uname -r`); `LLAMA_CURL` deprecated-and-ignored upstream, hard-dependency claim removed; `LLAMA_*`→`GGML_*` rename claim narrowed (remap is not blanket; `-DLLAMA_AVX2=ON` was never a recognised option); upstream `examples/`+`tools/`+`app/` trees and their build toggles confirmed still gating; `--cors-origins` verified in the current server README; auth checklist fixed (`/v1/models` is public by design — 401 check moved to `/v1/chat/completions`); Ansible CIDR derived from documented `address`/`netmask` via python3 instead of undocumented `prefix`; memory rank column attributed to on-host dmidecode, electrical-asymmetry claim hedged; OptiPlex 790 slot/capacity qualified by form factor (USFF: 2 slots / 8GB) |
| 2.0.8 | 2026-07 | Full-file lint pass: fixed a stale-hash defect introduced in 2.0.7 (the cached `<model>.sha256` marker was never invalidated when the model was replaced — now guarded by `-nt` and dropped on re-download); corrected the last three places still claiming the API key arrives with LAN exposure rather than on every deployment (frontmatter, script comment, security prose); refreshed the `MODEL_SHA256` comment to describe the caching behaviour |
| 2.0.7 | 2026-07 | Full-file lint pass: model checksum no longer re-hashes 2–5GB on every idempotent run; API key removed from `curl` argv (`--config` instead of `-H`); `llama-bench` invocations corrected to use `sudo` (the model is 0640 root:llm) at three sites; bench warning corrected — two 3B copies do fit in 8GB, two 8B copies do not; `Configured Memory Speed` absence explained so the dmidecode block is not misread as four 1066 parts; behaviour-change rows B and C corrected (the API key is required on loopback too, and ufw is conditional on ufw being active); sentence-case typo, "requesting for", off-by-one claim count, heading version drift, and an `ss` flag inconsistency |
| 2.0.6 | 2026-07 | Ansible lint pass: corrected the false "requires nothing beyond ansible-core" claim (the play needs `community.general`); removed the `ansible.utils.ipaddr` dependency in favour of gathered `network`/`prefix` facts; added `model_sha256` checksum parity with the bash path; fixed an `ansible_processor[2]` IndexError path; play name version aligned; non-resuming `get_url` documented as a known divergence |
| 2.0.5 | 2026-07 | Lint pass: preset-row reference in the ceiling table corrected; `pgrep -f` replaced with `pgrep -x \| head -1` in two checklist/troubleshooting commands; auth-check caveat corrected (a key is required on loopback too); thread-sweep command aligned with its prose; "Section N" numbering replaced with named anchors to stop it colliding with references to the v1.0 document; open-items table reordered |
| 2.0.4 | 2026-07 | Memory upgrade formally declined; 8GB @ 1067 MT/s recorded as the operating baseline and ~6.3 t/s (3B) as the throughput ceiling. OPEN-7 closed |
| 2.0.3 | 2026-07 | Memory clock root-caused to a single mismatched DDR3-1066 dual-rank module in ChannelB-DIMM0; module inventory decoded and upgrade options ranked |
| 2.0.2 | 2026-07 | Memory subsystem measured: dual channel confirmed, but 4 × 2GB @ 1067 MT/s rather than the assumed 1333. All throughput ceilings recomputed 20% downward; memory upgrade path added as the only hardware lever that moves tokens/sec |
| 2.0.1 | 2026-07 | On-host verification pass: SIMD confirmed AVX-only (no F16C/FMA — corrects an assumption in 2.0); RAM confirmed at 8GB; memory budget table added; `--mlock` made preset-conditional. Lint pass: unverified `LLAMA_BUILD_*` cmake toggles removed and binary reconciliation added; API key no longer transiently world-readable; model download made resumable; `llama-bench` guidance corrected to stop the service first (two model copies do not fit in 8GB); memory-channel population raised as OPEN-5 |
| 2.0 | 2026-07 | Consolidates `optiplex-llm-setup-v1.5.md`, `optiplex-llm-setup-v1.5.sh` and `optiplex-cpu-optimization-v1.0.md`. Performance expectations rebuilt from the platform's actual memory bandwidth; AVX2/DDR4/hyperthreading assumptions removed; deprecated build flags corrected; service de-escalated from root; API authentication and firewall scoping added; model integrity verification added |
| 1.5 / 1.0 | — | Superseded — see Change Control |
