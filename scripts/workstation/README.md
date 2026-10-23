# scripts/workstation

First-boot setup and recurring update scripts for the two workstation
hosts: the Nobara GPU box and the Linux Mint OptiPlex, plus a
role-prep checklist and setup script for a personal Linux laptop.
The Ansible patching counterpart for Nobara lives in
`ansible/playbooks/monthly/monthly_maint_nobara.yml`.

## 🛠️ New Nobara setup

One script for the first-boot job: `new-nobara-setup-v1.1.sh`, run
as root on a fresh Nobara install. It:

- Finds the discrete AMD GPU (amdgpu driver, device class 0x030000,
  so the iGPU is skipped) and locks it to high performance by writing
  `high` to its `power_dpm_force_performance_level`. It exits with
  an error if no discrete AMD GPU is found.
- Installs the Cinnamon desktop group and downloads a placeholder
  wallpaper to `/usr/share/backgrounds/nobara-cinnamon`.

The GPU lock is a runtime sysfs setting and does not persist across
a reboot. Revert it by writing `auto` to the same file; the script
prints the exact path.

A single linear, interactive run: GPU tuning first, then a press
Enter prompt, then the desktop part. It updates with `nobara-sync
cli`, falling back to `dnf update -y` if nobara-sync is missing. The
wallpaper downloads at 3840x2160, and a failed download only warns.
It ends with post-setup instructions: log out, pick Cinnamon from
the gear menu on the login screen, then set themes and wallpaper.

For GPU tuning alone, without the setup:

```bash
sudo ./new-nobara-setup-v1.1.sh gpu-high
```

(The retired `new-nobara-setup-alt-v1.1.sh` variant, whose
`gpu-high` subcommand was folded into the script above, is in
`deprecated/`.)

## Laptop role prep

A checklist and its companion setup script for a personal Linux
laptop that has to walk into either a classroom or a server
environment ready. The checklist is the specification; the script
produces every CLI-able part of it and prints the rest as a manual
list.

### linux-laptop-role-prep-checklist-v1.4.md

The checklist itself: base system, separation of personal and work
lives, the security core, the Linux administrator kit, the coding
instructor kit, the developer environment, communications, the
carry kit, a dry run before day one, and ongoing hygiene. Full-disk
encryption, per-role accounts, SSH keys, and git identities, and a
tested bare-metal restore are the load-bearing items. The setup
script is embedded in section 11, byte-identical to the standalone
file below.

### laptop-role-prep-setup-v1.2.sh

Run as root (`sudo ./laptop-role-prep-setup-v1.2.sh`). It creates
the per-role user accounts, installs the admin and instructor
tooling, wires the per-role SSH and git separation, sets the screen
lock and the host firewall, and prints whatever still needs hands,
hardware, or a sign-in as a manual list. The toolchain installs on
both package families (apt and dnf) and includes the three vendor
apps from the checklist: Proton Pass (no repository; the newest
Stable release is taken from Proton's version feed and installed
only after its SHA512 checksum verifies), Proton VPN (Proton's
signed repository on the apt family and on Fedora; RHEL-family
systems get the manual WireGuard path instead, since Proton
supports Fedora only on the RPM side), and TickTick (the official
download endpoint, with an `rpm --replacefiles` fallback for the
Proton Pass / TickTick build-id collision on the RPM side). Docker
on the Debian family, Podman on the RHEL family. Tested on Ubuntu
24.04 and Rocky 10: both distro branches passed two consecutive
live runs during the script's 2026-10-18 build, the second run
converging.

## update-gpu-box.sh

Recurring update pass for the Nobara GPU box. Run as root: it writes
`/var/log/gpu-box-update.log` and drives dnf, systemctl, and Docker.

1. OS update with `nobara-sync --no-reboot -y`. On a
   dependency-conflict exit it falls back to
   `dnf distro-sync --refresh`; other failures abort the run.
1. Repository key packages (`nobara-repos`, `nobara-gpg-keys`,
   `fedora-repos`).
1. Ollama reinstall through the official installer, with the same
   optional `OLLAMA_INSTALL_SHA256` checksum pin as the setup
   script, then an Ollama service restart.
1. Image pulls: SearXNG `:latest` and Open WebUI `v0.5.20`.
1. Recreation of the SearXNG and Open WebUI containers.
1. Pulls of the five models.
1. Port and API verification.

Set `DRY_RUN=true` to log every action without executing it. The
script requires the GPU box setup to have run first; it aborts if
`/etc/searxng` does not exist. One divergence to know about: the
recreated containers use this script's older conventions (host
networking for SearXNG, the `RAG_WEB_SEARCH_*` environment names for
Open WebUI), while `scripts/llm/gpu-box-llm-setup-v1.9.sh` now uses
bridge networking with a loopback publish for SearXNG and the
`ENABLE_WEB_SEARCH` / `WEB_SEARCH_*` names.

## update-optiplex.sh

Recurring update pass for the OptiPlex, in the older home-directory
layout. Run as root (log: `/var/log/optiplex-update.log`).

1. `apt-get update` and `apt-get upgrade`.
1. A clean rebuild of the llama.cpp checkout at `~/projects/llama.cpp`
   (under the invoking user's home; `PROJECTS_DIR` and `MODELS_DIR`
   override the roots): pull, delete the build directory, rebuild,
   restart the `llama-server` service, and wait for it to be active.
1. Model status. The model (a Meta-Llama-3.1-8B GGUF in `~/models`)
   is not updated by the script; it prints that a model change is a
   manual step.
1. Port 8080 and chat API verification.

`DRY_RUN=true` logs the actions without executing them. Note the
scope limit: this script's paths and build flags match the older
home-directory setup, not `scripts/llm/optiplex-llm-setup-v2.1.sh`,
which installs to `/opt/llama.cpp` and builds with `GGML_NATIVE`.
Use this updater only on a host set up the home-directory way.

## Ansible counterpart

`ansible/playbooks/workstation/nobara_first_boot.yml` is the
Ansible form of the first-boot setup above
(`new-nobara-setup-v1.1.sh`): the same discrete-AMD-GPU detection
and high-performance lock, the nobara-sync update with the dnf
fallback, the Cinnamon desktop group install, and the placeholder
wallpaper. Its usage header is the guide.

`ansible/playbooks/monthly/monthly_maint_nobara.yml` patches Nobara
desktops through Ansible instead of by hand (target group `nobara`,
`become: true`):

```bash
ansible-playbook -i inventory.ini monthly_maint_nobara.yml
ansible-playbook -i inventory.ini monthly_maint_nobara.yml --tags flatpak
```

It runs `nobara-sync --no-reboot`, a full dnf upgrade and
autoremove, system and per-user Flatpak updates, and a snap refresh.
Firmware is check-only: it prints a notification if updates are
available rather than applying them. It never reboots; if the
running kernel differs from the installed one it prints a
reboot-required notice. Tags (`nobara_sync`, `dnf`, `flatpak`,
`snap`, `firmware`, `reboot_check`) run individual parts. Each run
logs to `/var/log/ansible-patch/nobara_patch_<date>.log` on the
target.

On hosts where the GPU box setup has run (`/etc/searxng` exists),
the playbook also performs the LLM-stack refresh from
`update-gpu-box.sh` steps 3-7, in the same order and with the same
safeguards (tag `llm`): the Ollama reinstall through the official
installer (with the same optional sha256 pin, here the
`ollama_install_sha256` variable), the SearXNG `:latest` and Open
WebUI `v0.5.20` image pulls, recreation of both containers with the
updater's exact volume, environment, and capability sets, pulls of
the five models (a failed model warns and never aborts the run),
and port/API verification (warnings only). One deliberate
difference: the bash updater aborts when `/etc/searxng` is missing,
while the playbook skips the refresh on such hosts, because it
serves the whole `nobara` group; set `llm_refresh_enabled=false`
to skip it explicitly. Container removal is existence-based (the
updater removes only running containers, so a stopped container
would make its `docker run` fail; the playbook removes a stopped
container too and proceeds).
