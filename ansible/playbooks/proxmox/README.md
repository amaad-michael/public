# Proxmox VE Homelab Automation

**Author:** Michael Tatum — [HarborSonar](https://michaeltatum.xyz)
**Updated:** 2025-03-14
**Stack:** Ansible · Proxmox VE · Turnkey Linux · Debian

Fully automated Proxmox VE deployment and configuration for homelab use.
Takes a bare Debian machine to a hardened, production-ready hypervisor with
cloud-init VM templates and Turnkey LXC appliances ready to deploy.

---

## 📁 Project Structure

```
proxmox-homelab/
│
├── inventory.ini                 # Target host definitions
│
├── install_proxmox.yml           # STEP 1 — Install PVE on bare Debian host
├── configure_proxmox.yml         # STEP 2 — Post-reboot validation, repo cleanup, and upgrade
├── prep_proxmox.yml              # STEP 3 — Harden, users, storage, firewall
├── templates_cloudinit.yml       # STEP 4a — Debian 12 + Ubuntu 24.04 VM templates
├── templates_turnkey.yml         # STEP 4b — Turnkey Linux LXC appliance downloads
│
├── templates/
│   └── interfaces.j2             # Jinja2 — vmbr0 network bridge config
│
└── README.md                     # This file

```

---

## 📋 Prerequisites

**Control node (machine you run Ansible from):**

```bash
pip install ansible
ansible-galaxy collection install community.general community.proxmox

```

**Target host:**

- Debian 11/12 or Ubuntu 22.04/24.04
- Static IP configured before running
- SSH key-based access to a root or sudo user
- FQDN set or added to `/etc/hosts`

**Pre-flight — set a static IP on the target:**

```bash

# On the target host (Debian/Ubuntu with NetworkManager)

nmcli con mod "Wired connection 1" \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "1.1.1.1 8.8.8.8" \
  ipv4.method manual
nmcli con up "Wired connection 1"

```

---

## 🛠️ Bash form

The same deployment also ships as a local bash script,
`scripts/provisioning/proxmox-setup.sh`, for a run made by hand on
the target host instead of over SSH from a control node. There is
no Docker form: Proxmox VE is a bare-metal hypervisor.

One subcommand per playbook, run in the same order, with the same
values, checks, and defaults:

| Bash subcommand | Playbook |
|---|---|
| `install` | `install_proxmox.yml` |
| `configure` | `configure_proxmox.yml` |
| `prep` | `prep_proxmox.yml` |
| `templates-cloudinit` | `templates_cloudinit.yml` |
| `templates-turnkey` | `templates_turnkey.yml` |
| `all` | All five, in order |

```bash
sudo scripts/provisioning/proxmox-setup.sh install
# reboot into the PVE kernel, then:
sudo scripts/provisioning/proxmox-setup.sh configure
sudo scripts/provisioning/proxmox-setup.sh prep --admin-password "YourPassword" --mgmt-cidr "192.168.1.0/24"
sudo scripts/provisioning/proxmox-setup.sh templates-cloudinit --ssh-public-key "ssh-ed25519 AAAA..."
sudo scripts/provisioning/proxmox-setup.sh templates-turnkey
```

Every subcommand accepts `--dry-run`, which prints each step in
order (including the full contents of every file it would write)
and changes nothing. A real `prep` run refuses the playbook's
placeholder admin password. The script's `api-check` subcommand
validates an API token directly against the REST API
(`GET /api2/json/version` with a `PVEAPIToken` header); the
deployment steps themselves use the host CLIs (`pveum`, `pvesm`,
`pveam`, `qm`), which are clients of the same API, exactly as the
playbooks do. Run `proxmox-setup.sh --help` for all flags.

---

## 🔗 Playbook Reference

### Step 1 — `install_proxmox.yml`

**Use when:** You have a bare Debian/Ubuntu machine and want to install Proxmox VE from scratch.

```bash
ansible-playbook -i inventory.ini install_proxmox.yml --ask-become-pass

```

| What it configures |
|---|
| OS detection — fails fast if not Debian-based |
| PVE no-subscription repo, enterprise repo removed |
| Proxmox VE kernel + packages installed |
| Old non-PVE kernels purged |
| `vmbr0` network bridge (auto-detects NIC) |
| SSH hardening (no root login, no password auth) |
| `ansible@pam` user + API token (**save token output — shown once**) |
| Reboot into PVE kernel |

---

### Step 2 — `configure_proxmox.yml`

**Use when:** Host has rebooted after `install_proxmox.yml`. Validates everything before you proceed.

```bash
ansible-playbook -i inventory.ini configure_proxmox.yml --ask-become-pass

```

| What it does |
|---|
| PVE version; ensures all core services are started and enabled |
| `vmbr0` bridge is up |
| SSH `PermitRootLogin no` confirmed |
| `ansible@pam` API token present |
| Ensures the enterprise and Ceph enterprise repo files are absent, and the no-subscription repo is present |
| Runs a full apt dist-upgrade |
| Prints Web UI URL + access summary |

---

### Step 3 — `prep_proxmox.yml`

**Use when:** PVE is installed (fresh or pre-existing). Configures it for homelab use.

```bash
ansible-playbook -i inventory.ini prep_proxmox.yml \
  -e pve_admin_password="YourPassword" \
  -e pve_allowed_mgmt_cidr="192.168.1.0/24"

```

| What it configures |
|---|
| Full dist-upgrade, baseline packages, NTP |
| Subscription nag popup patched out |
| `homelab@pam` admin user with `HomelabAdmin` role |
| `ansible@pam` with scoped `AnsibleRole` + API token |
| Local storage configured for all content types |
| Optional NFS storage (`pve_nfs_enabled: true`) |
| `pve-firewall` — DROP inbound, LAN CIDR allowed |
| Fail2ban — SSH + PVE web UI brute-force protection |
| Unattended upgrades — security + PVE, no auto-reboot |

**Key variables:**

| Variable | Default | Description |
|---|---|---|
| `pve_admin_password` | `ChangeMeNow123!` | **Change this** |
| `pve_allowed_mgmt_cidr` | `192.168.1.0/24` | Your LAN range |
| `pve_nfs_enabled` | `false` | Enable NAS storage |
| `pve_nfs_server` | `192.168.1.50` | NFS server IP |
| `pve_nfs_export` | `/mnt/nas/proxmox` | NFS export path |
| `unattended_upgrades_email` | `""` | Patch notification email |

---

### Step 4a — `templates_cloudinit.yml`

**Use when:** You want blank Debian/Ubuntu VM templates to clone full VMs from.

```bash
ansible-playbook -i inventory.ini templates_cloudinit.yml \
  -e pve_ssh_public_key="ssh-ed25519 AAAA..."

```

| Creates | VMID | Base image |
|---|---|---|
| `debian-12-cloudinit` | 9000 | Debian 12 Bookworm generic cloud |
| `ubuntu-2404-cloudinit` | 9001 | Ubuntu 24.04 LTS cloud |

Re-run safe — skips any VMID that already exists.

**Clone a VM from a template:**

```bash
qm clone 9000 100 --name my-debian-vm --full true
qm set 100 --ipconfig0 ip=dhcp && qm start 100

```

---

### Step 4b — `templates_turnkey.yml`

**Use when:** You want pre-built LXC appliance templates ready to spin up as containers.

```bash
ansible-playbook -i inventory.ini templates_turnkey.yml

```

| Downloads | Description |
|---|---|
| `debian-12-turnkey-core` | Clean Debian baseline |
| `debian-12-turnkey-gitea` | Self-hosted Git |
| `debian-12-turnkey-wireguard` | VPN server |
| `debian-12-turnkey-pihole` | DNS ad-blocker |
| `debian-12-turnkey-nginx` | Web server / reverse proxy |

Re-run safe — skips templates already in storage. Does **not** create containers automatically.

**Add more templates:** edit `pve_turnkey_templates` in the playbook vars, or browse the full catalog:

```bash
pveam available --section turnkeylinux

# https://www.turnkeylinux.org/all

```

**Create a container from a downloaded template:**

```bash
pct create 201 local:vztmpl/debian-12-turnkey-core_17.1-1_amd64.tar.gz \
  --hostname core-01 \
  --storage local-lvm --rootfs local-lvm:8 \
  --memory 512 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=1 \
  --unprivileged 1 --onboot 1 --start 1

```

---

## Full Run Order

```bash

# ── Control node setup (once) ─────────────────────────────────

pip install ansible
ansible-galaxy collection install community.general community.proxmox

# ── Edit inventory ─────────────────────────────────────────────

vim inventory.ini   # set ansible_host and ansible_user

# ── Fresh bare metal ──────────────────────────────────────────

ansible-playbook -i inventory.ini install_proxmox.yml --ask-become-pass

# (host reboots — wait for it to come back)

ansible-playbook -i inventory.ini configure_proxmox.yml --ask-become-pass

# ── Any PVE server (fresh or existing) ───────────────────────

ansible-playbook -i inventory.ini prep_proxmox.yml \
  -e pve_admin_password="YourPassword" \
  -e pve_allowed_mgmt_cidr="192.168.1.0/24"

# ── Templates (independent, re-run any time) ─────────────────

ansible-playbook -i inventory.ini templates_cloudinit.yml \
  -e pve_ssh_public_key="ssh-ed25519 AAAA..."
ansible-playbook -i inventory.ini templates_turnkey.yml

```

---

## VMID Convention

| Range | Purpose |
|---|---|
| `100–199` | Virtual machines (KVM/QEMU) |
| `200–299` | Infrastructure LXC containers (DNS, VPN, proxy) |
| `300–399` | Dev/DevOps LXC containers (Gitea, Jenkins, Ansible) |
| `400–499` | Data/monitoring LXC containers (Grafana, DB, Nextcloud) |
| `9000+` | VM templates (cloud-init) |

---

## 🛠️ After Install

| Item | Value |
|---|---|
| Web UI | `https://<host-ip>:8006` |
| Admin user | `homelab@pam` |
| API user | `ansible@pam` |
| API token | `ansible-token` (saved from install/prep output) |
| Bridge | `vmbr0` on primary NIC |

---

## 🔗 Documentation

- [Proxmox VE Docs](https://pve.proxmox.com/pve-docs/)
- [Turnkey Linux Appliance Catalog](https://www.turnkeylinux.org/all)
- [community.proxmox Ansible Collection](https://docs.ansible.com/ansible/latest/collections/community/proxmox/)
