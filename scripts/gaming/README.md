# lsfg-vk — Lossless Scaling Frame Generation on Nobara Linux

> **Frame generation for every game on Linux — native Vulkan, no Windows required.**

This package gets lsfg-vk running on a **Nobara Linux** machine with an **AMD hybrid GPU setup** (integrated Radeon iGPU + discrete RX 9060 XT). It includes an automated install script and base configuration.

---

## 📋 Table of Contents

1. [What Is This?](#what-is-this)
1. [Prerequisites](#prerequisites)
1. [Quick Start](#quick-start)
1. [How the Script Works](#how-the-script-works)
1. [Steam Launch Options](#steam-launch-options)
1. [Configuration](#configuration)
1. [Per-Game Profile Setup](#per-game-profile-setup)
1. [Tuning Reference](#tuning-reference)
1. [GPU Selection (Hybrid Setup)](#gpu-selection-hybrid-setup)
1. [Troubleshooting](#troubleshooting)
1. [Uninstall](#uninstall)
1. [Resources](#resources)

---

## What Is This

**Lossless Scaling** is a Steam app that generates additional frames in real time using AI motion estimation — similar to DLSS 3 Frame Gen or AMD Fluid Motion Frames, but works on **any game, any GPU**.

The official app is Windows-only and cannot run under Proton. **lsfg-vk** is an open-source Vulkan layer that ports the frame generation algorithm to native Linux, hooking into your games using the `.dll` assets from your Steam installation of Lossless Scaling.

```
Your Game → Vulkan → lsfg-vk layer → Frame Gen (2x/3x/4x) → Display
```

---

## Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| **OS** | Nobara Linux (Fedora-based) | Script uses `dnf` and `rpm` |
| **Kernel** | 6.14+ | Required for RDNA 4 (RX 9060 XT) |
| **Mesa** | 25.0+ | Mesa 25.1+ preferred for best RDNA 4 perf |
| **GPU** | Any Vulkan-capable GPU | RX 9060 XT confirmed working |
| **Lossless Scaling** | Purchased on Steam | Free/demo version will not work |
| **Architecture** | x86_64 | ARM not supported |

### Verify your kernel and Mesa before running

```bash
# Kernel version — must be 6.14 or higher
uname -r

# Mesa version — must be 25.0 or higher
glxinfo | grep "Mesa"
```

If Nobara is up to date, both requirements are met out of the box.

---

## Quick Start

```bash
# 1 — Make the script executable
chmod +x install-lsfg-vk.sh

# 2 — Run it (do NOT use sudo)
./install-lsfg-vk.sh

# 3 — Follow the prompts
```

That's it. The script handles everything from there.

---

## How the Script Works

The installer runs these steps in order:

```
[1] Root guard          — Refuses to run as root
[2] Steam detection     — Scans standard Steam paths
[3] Lossless.dll find   — Searches all Steam library folders
[4] Kernel check        — Validates 6.14+ for RDNA 4 support
[5] Mesa check          — Validates 25.0+ via glxinfo (skipped with a warning if glxinfo is missing)
[6] GPU check           — Checks for an AMD GPU (warns and continues if it cannot confirm one)
[7] Qt6 deps            — Installs qt6-qtbase, qt6-qtdeclarative, qt6-qtwayland
[8] RPM download        — Fetches latest lsfg-vk release from GitHub API
[9] RPM integrity       — Verifies the RPM digest (rpm -K); also checks a pinned SHA-256 if LSFG_VK_SHA256 is set
[10] RPM install        — Installs via rpm -Uvh (upgrades if already installed)
[11] Verify             — Checks lsfg-vk-ui is accessible (warns if it is not found)
[12] Base config write  — Creates ~/.config/lsfg-vk/conf.toml with your DLL path
[13] Launch UI prompt   — Optionally opens the config UI immediately
```

Most failures stop the script with a clear error message; the Mesa, GPU, and verify checks above warn and continue instead.

> **The script will NOT overwrite an existing `conf.toml`.** If you've already configured lsfg-vk, your settings are safe.

---

## Steam Launch Options

Set these in **Steam → Right-click game → Properties → Launch Options**.

### Standard (Proton or Native games)

```
ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%
```

### With explicit discrete GPU (if game defaults to iGPU)

```
DRI_PRIME=1 ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%
```

### With FPS cap (recommended to prevent screen tearing)

```
ENABLE_LSFG=1 LSFG_MULTIPLIER=2 DXVK_FRAME_RATE=60 %command%
```

> 💡 **Tip:** Set an in-game FPS cap or use MangoHud's frame limiter. Without a cap, the multiplier math doesn't work cleanly (e.g. 2x on uncapped 90fps gives inconsistent pacing).

---

## Configuration

The config file lives at:

```
~/.config/lsfg-vk/conf.toml
```

Open it with any text editor. The install script writes a base version with your detected `Lossless.dll` path already filled in.

### Open the GUI instead

```bash
lsfg-vk-ui
# or if not in PATH:
~/.local/bin/lsfg-vk-ui
```

The GUI lets you manage profiles, browse for the DLL path, and set multiplier/flow scale without touching the config file.

---

## Per-Game Profile Setup

Each game gets its own `[[profile]]` block in `conf.toml`. The profile activates automatically when that game's executable is running.

### Example: Proton (Windows) game

```toml
[[profile]]
active_in = ["Cyberpunk2077.exe"]
multiplier = 2
flow_scale = 0.75
performance_mode = true
```

### Example: Native Linux game

```toml
[[profile]]
active_in = ["game"]    # use the binary name, not .exe
multiplier = 2
flow_scale = 1.0
performance_mode = false
```

### Finding the correct executable name

```bash
# Check the process name while the game is running
ps aux | grep -i "game_name"

# Or use the process picker button in lsfg-vk-ui
# (launch the game first, then click the picker)
```

---

## Tuning Reference

| Setting | Values | Default | What It Does |
|---|---|---|---|
| `multiplier` | 2, 3, 4 | `2` | Frames generated per real frame. 2x is most stable. |
| `flow_scale` | 0.5 – 1.0 | `1.0` | Resolution for motion estimation. Lower = faster but softer. |
| `performance_mode` | true/false | `false` | Uses a lighter AI model. Minor quality trade, big perf gain on lower-end setups. |
| `pacing` | `"none"` | `"none"` | Frame pacing mode. Leave default unless you see visible stutter. |

### Recommended starting points

| Scenario | Multiplier | Flow Scale | Performance Mode |
|---|---|---|---|
| High GPU load, 60fps target | `2` | `0.75` | `true` |
| Comfortable headroom | `2` | `1.0` | `false` |
| Very high framerates (120+) | `3` | `0.65` | `true` |

> ⚠️ `flow_scale` and `multiplier` hot-reload in real time. `pacing` changes require a game restart.

---

## GPU Selection (Hybrid Setup)

Your machine has two GPUs: the AMD Radeon iGPU (in the processor) and the discrete RX 9060 XT.

### Check which GPU a game is using

```bash
glxinfo | grep "OpenGL renderer"
```

You want to see your **RX 9060 XT (Navi 44 / RDNA 4)** listed, not the integrated Radeon.

### Force discrete GPU

Add `DRI_PRIME=1` to the Steam launch options:

```
DRI_PRIME=1 ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%
```

> 💡 Most games already default to the discrete GPU on Nobara. Only add `DRI_PRIME=1` if you confirm the iGPU is being used.

### The `gpu` config option

If you want to pin the frame generation to a specific GPU in the config:

```toml
[global]
dll = "/path/to/Lossless.dll"
gpu = "AMD Radeon RX 9060 XT"    # must match the card name exactly
```

---

## Troubleshooting

### lsfg-vk-ui not found after install

```bash
# Add ~/.local/bin to your PATH if not already there
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Game launches but no frame gen active

1. Confirm `ENABLE_LSFG=1` is in the launch options
1. Check that the `active_in` executable name in your profile matches the actual process name
1. Run with MangoHud to verify FPS: `MANGOHUD=1 ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%`
1. Check for errors: `ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command% 2>&1 | grep -i lsfg`

### Lossless.dll not found by lsfg-vk

Verify the path in your config:

```bash
cat ~/.config/lsfg-vk/conf.toml | grep dll

# Confirm the file actually exists there
ls -la "$(cat ~/.config/lsfg-vk/conf.toml | grep dll | grep -oP '= "\K[^"]+')"
```

### Screen tearing / frame pacing issues

Enable V-Sync in-game or add a frame cap:

```
# Cap at 60fps using DXVK (Proton games)
DXVK_FRAME_RATE=60 ENABLE_LSFG=1 LSFG_MULTIPLIER=2 %command%
```

### Do not stack with in-game frame generation

Do **not** combine lsfg-vk with:

- AMD Fluid Motion Frames (AFMF)
- DLSS Frame Generation
- Any other frame gen tech

Pick one. Stacking causes artifacting and instability.

### RPM install fails / conflicts

```bash
# Force reinstall if a previous version is broken
sudo rpm -Uvh --force /tmp/lsfg-vk-*.rpm
```

---

## Uninstall

```bash
# Remove the RPM package
sudo rpm -e lsfg-vk

# Remove config (optional — only do this if you want a clean slate)
rm -rf ~/.config/lsfg-vk
```

---

## Resources

| Resource | Link |
|---|---|
| lsfg-vk GitHub | https://github.com/PancakeTAS/lsfg-vk |
| lsfg-vk Wiki | https://github.com/PancakeTAS/lsfg-vk/wiki |
| Configuration Docs | https://github.com/PancakeTAS/lsfg-vk/wiki/Configuring-lsfg-vk |
| Lossless Scaling (Steam) | https://store.steampowered.com/app/993090 |
| Phoronix RX 9060 XT Linux Review | https://www.phoronix.com/review/radeon-rx-9060xt-amd-linux |
| Lossless Scaling Discord | Join via the Steam community page |

---

*Script targets Nobara Linux (Fedora/RPM-based). Kernel 6.14+, Mesa 25.0+, RX 9060 XT (RDNA 4).*
