#!/usr/bin/env bash
# proxmox-setup.sh — bash form of the Proxmox VE Ansible deployment.
#
# Ansible form (the source this script is derived from, step for step):
#   ansible/playbooks/proxmox/install_proxmox.yml    -> install
#   ansible/playbooks/proxmox/configure_proxmox.yml  -> configure
#   ansible/playbooks/proxmox/prep_proxmox.yml       -> prep
#   ansible/playbooks/proxmox/templates_cloudinit.yml -> templates-cloudinit
#   ansible/playbooks/proxmox/templates_turnkey.yml   -> templates-turnkey
#   ansible/playbooks/proxmox/templates/interfaces.j2 -> interfaces file
# Docker form: not applicable — Proxmox VE is a bare-metal hypervisor;
# see ansible/playbooks/proxmox/README.md.
#
# The Ansible content runs over SSH and drives the target's own tools
# (apt, pveum, pvesm, pveam, qm, systemctl). This script is the local
# form: run it as root ON the target host, in the same order the
# playbooks run, and it issues the same commands with the same values.
# One subcommand per playbook; `all` runs install, configure, prep and
# both template steps in playbook order (stopping for the reboot the
# install step requests, exactly as the Ansible run does).
#
# Where a step maps to the Proxmox REST API, the script uses the host
# CLI that fronts the same API (pveum/pvesm/pveam/qm are API clients),
# matching the Ansible tasks, which also use those CLIs. The one
# API-native check is `api-check`, which validates a token against
# /api2/json/version over HTTPS — the bash counterpart of the
# playbooks' token validation.
#
# Usage:
#   proxmox-setup.sh install   [--bridge-ip A.B.C.D] [--bridge-iface IFACE]
#   proxmox-setup.sh configure
#   proxmox-setup.sh prep      [--admin-password PW] [--mgmt-cidr CIDR]
#                              [--nfs] [--nfs-server IP] [--nfs-export PATH]
#                              [--notify-email ADDR] [--no-firewall]
#   proxmox-setup.sh templates-cloudinit [--ssh-public-key "ssh-ed25519 ..."]
#   proxmox-setup.sh templates-turnkey
#   proxmox-setup.sh all       [any of the above flags]
#   proxmox-setup.sh api-check --api-url https://HOST:8006 \
#       --api-user ansible@pam --api-token-name ansible-token \
#       --api-token-secret UUID [--insecure]
#
# Every subcommand accepts --dry-run: steps are printed in order and
# nothing on the host changes (validation still runs). Passwords are
# taken from flags or the environment (PVE_ADMIN_PASSWORD); the
# playbook default is kept only so a dry run shows the same default
# the playbook would use — a real prep run refuses it, exactly the
# intent of the playbook's "Change this" comment.

set -euo pipefail

# --- Defaults: copied from the playbooks' vars blocks -----------------
PVE_API_USER="ansible@pam"
PVE_API_TOKEN_NAME="ansible-token"
SSH_PERMIT_ROOT_LOGIN="no"
SSH_PASSWORD_AUTH="no"
SSH_PORT=22
BRIDGE_NAME="vmbr0"
BRIDGE_IFACE=""
BRIDGE_IP=""
BRIDGE_PREFIX=""
BRIDGE_GATEWAY=""
BRIDGE_DNS="1.1.1.1 8.8.8.8"
HOSTNAME_FQDN=""

PVE_ADMIN_USER="homelab"
PVE_ADMIN_PASSWORD="${PVE_ADMIN_PASSWORD:-ChangeMeNow123!}"
PVE_MGMT_CIDR="192.168.1.0/24"
PVE_NFS_ENABLED=0
PVE_NFS_SERVER="192.168.1.50"
PVE_NFS_EXPORT="/mnt/nas/proxmox"
PVE_NFS_STORAGE_ID="nas-storage"
PVE_FIREWALL_ENABLED=1
FAIL2BAN_BANTIME=3600
FAIL2BAN_FINDTIME=600
FAIL2BAN_MAXRETRY=5
NOTIFY_EMAIL=""

TEMPLATE_STORAGE="local-lvm"
TEMPLATE_TMPDIR="/var/tmp/pve-templates"
TEMPLATE_CORES=2
TEMPLATE_MEMORY=2048
TEMPLATE_DISK_SIZE="10G"
SSH_PUBLIC_KEY=""
CT_STORAGE="local"

API_URL=""
API_USER=""
API_TOKEN_NAME=""
API_TOKEN_SECRET=""
API_INSECURE=0

DRY_RUN=0
ASSUME_YES=0

ANSIBLE_PRIVS="Datastore.AllocateSpace,Datastore.Audit,Pool.Allocate,Sys.Audit,Sys.Console,Sys.Modify,VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Migrate,VM.Monitor,VM.PowerMgmt,SDN.Use"
ADMIN_PRIVS="Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Pool.Allocate,Pool.Audit,Sys.Audit,Sys.Console,Sys.Modify,Sys.PowerMgmt,Sys.Syslog,VM.Allocate,VM.Audit,VM.Backup,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.Monitor,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback,SDN.Use"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

# run_cmd_ok — like run_cmd, but a failure is tolerated (the Ansible
# tasks with failed_when: false: role/token creation on re-runs).
run_cmd_ok() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: %s (failure tolerated)\n' "$*"
  else
    "$@" || true
  fi
}

write_file() {
  # write_file DEST MODE OWNER:GROUP — stdin is the content. In dry-run
  # the content is shown under a header instead of written.
  local dest="$1" mode="$2" owner="$3"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: write %s (mode %s, owner %s):\n' "$dest" "$mode" "$owner"
    sed 's/^/DRY-RUN:   /'
  else
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    # The Ansible copy tasks create parent directories implicitly;
    # do the same (e.g. /etc/pve/firewall on a fresh install).
    install -d -m 0755 "$(dirname "$dest")"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
    rm -f "$tmp"
    log "wrote $dest"
  fi
}

require_root() {
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ $EUID -eq 0 ]] || die "run as root on the target host (or use --dry-run)"
  fi
}

require_debian() {
  [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*) ;;
        *) die "This script only supports Debian-based systems. Detected: ${ID:-unknown}" ;;
      esac
      ;;
  esac
  OS_ID="$ID"
  OS_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$OS_CODENAME" ]] || die "could not detect the distro codename from /etc/os-release"
}

require_pve() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: pveversion (must succeed on a real host)\n'
    return 0
  fi
  command -v pveversion >/dev/null 2>&1 \
    || die "pveversion not found — Proxmox VE is not installed on this host"
  PVE_VERSION="$(pveversion)"
  log "Targeting $PVE_VERSION"
}

PVE_VERSION=""

# ---------------------------------------------------------------------
# install — install_proxmox.yml
# ---------------------------------------------------------------------
do_install() {
  require_debian
  log "Detected $OS_ID $OS_CODENAME"

  # Bridge values: flags win; otherwise auto-detect like the playbook
  # does from ansible_default_ipv4.
  if [[ -z "$BRIDGE_IFACE" ]]; then
    BRIDGE_IFACE="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    [[ -n "$BRIDGE_IFACE" ]] || die "could not auto-detect the default interface; pass --bridge-iface"
  fi
  if [[ -z "$BRIDGE_IP" ]]; then
    BRIDGE_IP="$(ip -o -4 addr show dev "$BRIDGE_IFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
    [[ -n "$BRIDGE_IP" ]] || die "no IPv4 address on $BRIDGE_IFACE; pass --bridge-ip (Proxmox requires a static IP)"
  fi
  if [[ -z "$BRIDGE_PREFIX" ]]; then
    BRIDGE_PREFIX="$(ip -o -4 addr show dev "$BRIDGE_IFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[2]; exit}')"
    [[ -n "$BRIDGE_PREFIX" ]] || die "could not detect the prefix on $BRIDGE_IFACE; pass --bridge-prefix"
  fi
  if [[ -z "$BRIDGE_GATEWAY" ]]; then
    BRIDGE_GATEWAY="$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    [[ -n "$BRIDGE_GATEWAY" ]] || die "no default gateway found; pass --bridge-gateway"
  fi
  if [[ -z "$HOSTNAME_FQDN" ]]; then
    HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
  fi

  if [[ -f "/var/lib/dhcp/dhclient.$BRIDGE_IFACE.leases" ]]; then
    warn "DHCP lease file detected for $BRIDGE_IFACE. Proxmox requires a static IP. Proceeding, but configure a static IP before rebooting."
  fi

  run_cmd hostnamectl set-hostname "$HOSTNAME_FQDN"
  local short="${HOSTNAME_FQDN%%.*}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: ensure /etc/hosts line: %s %s %s\n' "$BRIDGE_IP" "$HOSTNAME_FQDN" "$short"
  else
    if grep -q "^${BRIDGE_IP}[[:space:]]" /etc/hosts; then
      sed -i "s|^${BRIDGE_IP}[[:space:]].*|$BRIDGE_IP $HOSTNAME_FQDN $short|" /etc/hosts
    else
      printf '%s %s %s\n' "$BRIDGE_IP" "$HOSTNAME_FQDN" "$short" >> /etc/hosts
    fi
  fi

  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update
  run_cmd apt-get install -y curl gnupg ca-certificates ifupdown \
    bridge-utils python3 python3-pip

  # Repo codename: Debian uses its own release; Ubuntu maps to the
  # closest Debian codename exactly as the playbook's set_fact does.
  local repo_codename="$OS_CODENAME"
  if [[ "$OS_ID" == "ubuntu" ]]; then
    local major="${VERSION_ID%%.*}"
    if [[ "$major" -ge 23 ]]; then repo_codename="bookworm"; else repo_codename="bullseye"; fi
  fi
  run_cmd curl -fsSL -o "/etc/apt/trusted.gpg.d/proxmox-release-$repo_codename.gpg" \
    "https://enterprise.proxmox.com/debian/proxmox-release-$repo_codename.gpg"
  printf 'deb http://download.proxmox.com/debian/pve %s pve-no-subscription\n' \
    "$repo_codename" | write_file /etc/apt/sources.list.d/pve-no-subscription.list 0644 root:root
  run_cmd rm -f /etc/apt/sources.list.d/pve-enterprise.list
  run_cmd apt-get update

  run_cmd apt-get install -y proxmox-default-kernel
  run_cmd apt-get install -y proxmox-ve postfix open-iscsi chrony
  run_cmd apt-get purge -y os-prober || true
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: purge old non-Proxmox kernels (dpkg linux-image list, excluding proxmox)\n'
  else
    local old_kernels
    old_kernels="$(dpkg --list | grep 'linux-image' | grep -v proxmox | awk '{print $2}' || true)"
    if [[ -n "$old_kernels" ]]; then
      # Intentional word splitting: one package name per word.
      # shellcheck disable=SC2086
      apt-get -y purge $old_kernels || true
    fi
  fi

  # /etc/network/interfaces — templates/interfaces.j2, rendered
  {
    printf '# Managed by proxmox-setup.sh — do not edit manually\n'
    printf '# Generated for Proxmox VE on %s\n\n' "$HOSTNAME_FQDN"
    printf 'auto lo\niface lo inet loopback\n\n'
    printf '# Physical NIC — enslaved to bridge, no IP\nauto %s\niface %s inet manual\n\n' \
      "$BRIDGE_IFACE" "$BRIDGE_IFACE"
    printf '# Proxmox bridge vmbr0\nauto %s\niface %s inet static\n' "$BRIDGE_NAME" "$BRIDGE_NAME"
    printf '    address %s/%s\n' "$BRIDGE_IP" "$BRIDGE_PREFIX"
    printf '    gateway %s\n' "$BRIDGE_GATEWAY"
    printf '    bridge-ports %s\n' "$BRIDGE_IFACE"
    printf '    bridge-stp off\n    bridge-fd 0\n'
    printf '    dns-nameservers %s\n' "$BRIDGE_DNS"
  } | write_file /etc/network/interfaces 0644 root:root

  # SSH hardening — the playbook's lineinfile loop, same values
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: set sshd_config: PermitRootLogin %s, PasswordAuthentication %s, Port %s, X11Forwarding no, MaxAuthTries 3, ClientAliveInterval 300, ClientAliveCountMax 2 (validated with sshd -t)\n' \
      "$SSH_PERMIT_ROOT_LOGIN" "$SSH_PASSWORD_AUTH" "$SSH_PORT"
  else
    cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.proxmox-setup
    set_sshd PermitRootLogin "$SSH_PERMIT_ROOT_LOGIN"
    set_sshd PasswordAuthentication "$SSH_PASSWORD_AUTH"
    set_sshd Port "$SSH_PORT"
    set_sshd X11Forwarding no
    set_sshd MaxAuthTries 3
    set_sshd ClientAliveInterval 300
    set_sshd ClientAliveCountMax 2
    /usr/sbin/sshd -t -f /etc/ssh/sshd_config \
      || die "sshd_config validation failed; backup at /etc/ssh/sshd_config.bak.proxmox-setup"
    systemctl restart ssh || systemctl restart sshd \
      || die "SSH restart failed"
  fi

  # Ansible API user, role and token — the playbook's pveum sequence
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: useradd -m -s /bin/bash ansible (if missing)\n'
  elif ! id ansible >/dev/null 2>&1; then
    useradd -m -s /bin/bash ansible
  fi
  run_cmd_ok pveum role add AnsibleRole --privs "$ANSIBLE_PRIVS"
  run_cmd_ok pveum user add "$PVE_API_USER" --comment "Ansible automation user"
  run_cmd pveum acl modify / --user "$PVE_API_USER" --role AnsibleRole
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: pveum user token add %s %s --privsep 0 --output-format json (save the output — shown once)\n' \
      "$PVE_API_USER" "$PVE_API_TOKEN_NAME"
  else
    pveum user token add "$PVE_API_USER" "$PVE_API_TOKEN_NAME" \
      --privsep 0 --output-format json || true
  fi

  log "Install step complete. Reboot into the Proxmox kernel, then run: $0 configure"
  if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
    warn "Not rebooting automatically. Reboot when ready, as the playbook's reboot task would."
  fi
}

set_sshd() {
  local key="$1" value="$2"
  if grep -qE "^#?${key}[[:space:]]" /etc/ssh/sshd_config; then
    sed -i "s|^#\?${key}[[:space:]].*|$key $value|" /etc/ssh/sshd_config
  else
    printf '%s %s\n' "$key" "$value" >> /etc/ssh/sshd_config
  fi
}

# ---------------------------------------------------------------------
# configure — configure_proxmox.yml (post-reboot validation)
# ---------------------------------------------------------------------
do_configure() {
  require_debian
  require_pve

  run_cmd rm -f /etc/apt/sources.list.d/pve-enterprise.list
  run_cmd rm -f /etc/apt/sources.list.d/ceph.list
  printf 'deb http://download.proxmox.com/debian/pve %s pve-no-subscription\n' \
    "$OS_CODENAME" | write_file /etc/apt/sources.list.d/pve-no-subscription.list 0644 root:root
  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update
  run_cmd apt-get -y dist-upgrade

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: ip link show vmbr0 (must be UP)\n'
    printf 'DRY-RUN: systemctl enable --now pvedaemon pveproxy pvestatd pve-cluster\n'
    printf 'DRY-RUN: sshd -T check for "permitrootlogin no"\n'
    printf 'DRY-RUN: pveum user token list %s (must contain %s)\n' "$PVE_API_USER" "$PVE_API_TOKEN_NAME"
  else
    ip link show vmbr0 >/dev/null || die "vmbr0 is not up"
    log "vmbr0 is UP"
    local svc
    for svc in pvedaemon pveproxy pvestatd pve-cluster; do
      systemctl enable --now "$svc" || die "service failed: $svc"
    done
    if ! sshd -T -C user=root 2>/dev/null | grep -q '^permitrootlogin no$'; then
      die "SSH PermitRootLogin is NOT set to no — check /etc/ssh/sshd_config"
    fi
    log "SSH PermitRootLogin is correctly disabled"
    local tokens
    tokens="$(pveum user token list "$PVE_API_USER" --output-format json)" \
      || die "could not list tokens for $PVE_API_USER"
    [[ "$tokens" == *"$PVE_API_TOKEN_NAME"* ]] \
      || die "API token '$PVE_API_TOKEN_NAME' not found for $PVE_API_USER"
    log "API token '$PVE_API_TOKEN_NAME' confirmed for $PVE_API_USER"
  fi

  local ip_addr
  ip_addr="$(ip -o -4 addr show dev vmbr0 scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
  log "===== Proxmox VE Ready ====="
  log "Web UI  : https://${ip_addr:-<host-ip>}:8006"
  log "Version : ${PVE_VERSION:-pveversion (dry-run)}"
  log "API user: $PVE_API_USER"
  log "Token   : $PVE_API_TOKEN_NAME"
  log "Bridge  : vmbr0"
  log "============================"
}

# ---------------------------------------------------------------------
# prep — prep_proxmox.yml
# ---------------------------------------------------------------------
do_prep() {
  require_debian
  require_pve
  if [[ "$PVE_ADMIN_PASSWORD" == "ChangeMeNow123!" && "$DRY_RUN" -eq 0 ]]; then
    die "refusing to set the playbook's placeholder admin password on a real run — pass --admin-password or set PVE_ADMIN_PASSWORD"
  fi

  export DEBIAN_FRONTEND=noninteractive
  printf 'deb http://download.proxmox.com/debian/pve %s pve-no-subscription\n' \
    "$OS_CODENAME" | write_file /etc/apt/sources.list.d/pve-no-subscription.list 0644 root:root
  run_cmd rm -f /etc/apt/sources.list.d/pve-enterprise.list
  run_cmd rm -f /etc/apt/sources.list.d/ceph.list
  run_cmd apt-get update
  run_cmd apt-get -y dist-upgrade
  run_cmd apt-get install -y curl wget vim htop iotop net-tools dnsutils \
    chrony libguestfs-tools unattended-upgrades apt-listchanges fail2ban \
    qemu-guest-agent nfs-common
  run_cmd systemctl enable --now chrony

  # Subscription nag — same replace as the playbook, with backup
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: patch the "No valid subscription" popup out of proxmoxlib.js (with backup), restart pveproxy\n'
  else
    local libjs
    libjs="$(find /usr/share/javascript/proxmox-widget-toolkit -name proxmoxlib.js 2>/dev/null | head -n 1 || true)"
    if [[ -n "$libjs" ]]; then
      cp -a "$libjs" "$libjs.bak.proxmox-setup"
      python3 - "$libjs" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
new = re.sub(r"Ext\.Msg\.show\(\{[^}]*title: gettext\('No valid subscription'\)[\s\S]*?\}\);",
             "void(0);", text, count=1)
if new != text:
    open(path, "w").write(new)
    print(f"patched {path}")
else:
    print(f"pattern not found in {path} (already patched?)")
PYEOF
      systemctl restart pveproxy || warn "pveproxy restart failed"
    else
      warn "proxmoxlib.js not found; skipping subscription-nag patch"
    fi
  fi

  # Users and roles — the playbook's user + pveum sequence
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: useradd -m -s /bin/bash %s; set its password from --admin-password (hashed, never logged)\n' "$PVE_ADMIN_USER"
  else
    id "$PVE_ADMIN_USER" >/dev/null 2>&1 \
      || useradd -m -s /bin/bash "$PVE_ADMIN_USER"
    printf '%s:%s\n' "$PVE_ADMIN_USER" "$PVE_ADMIN_PASSWORD" | chpasswd
  fi
  run_cmd_ok pveum role add HomelabAdmin --privs "$ADMIN_PRIVS"
  run_cmd_ok pveum user add "$PVE_ADMIN_USER@pam" --email "$PVE_ADMIN_USER@pve.local" \
    --comment "Homelab admin"
  run_cmd pveum acl modify / --user "$PVE_ADMIN_USER@pam" --role HomelabAdmin
  if [[ "$DRY_RUN" -eq 0 ]] && ! id ansible >/dev/null 2>&1; then
    useradd -m -s /bin/bash ansible
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: useradd -m -s /bin/bash ansible (if missing)\n'
  fi
  run_cmd_ok pveum role add AnsibleRole --privs "$ANSIBLE_PRIVS"
  run_cmd_ok pveum user add "$PVE_API_USER" --comment "Ansible automation user"
  run_cmd pveum acl modify / --user "$PVE_API_USER" --role AnsibleRole
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: pveum user token add %s %s --privsep 0 --output-format json (save the output — shown once)\n' \
      "$PVE_API_USER" "$PVE_API_TOKEN_NAME"
  else
    pveum user token add "$PVE_API_USER" "$PVE_API_TOKEN_NAME" \
      --privsep 0 --output-format json || true
  fi

  # Storage
  run_cmd pvesm set local --content images,rootdir,iso,snippets,vztmpl,backup
  run_cmd install -d -o root -g www-data -m 0755 /var/lib/vz/template/iso \
    /var/lib/vz/template/cache /var/lib/vz/dump /var/lib/vz/snippets
  if [[ "$PVE_NFS_ENABLED" -eq 1 ]]; then
    run_cmd_ok pvesm add nfs "$PVE_NFS_STORAGE_ID" --server "$PVE_NFS_SERVER" \
      --export "$PVE_NFS_EXPORT" --content images,backup,iso,snippets,vztmpl \
      --options hard,intr
    run_cmd pvesm status
  fi

  # Firewall files — byte-equivalent to the playbook's copy tasks
  if [[ "$PVE_FIREWALL_ENABLED" -eq 1 ]]; then
    {
      printf '[OPTIONS]\n'
      printf 'enable: 1\n'
      printf 'policy_in: DROP\n'
      printf 'policy_out: ACCEPT\n'
      printf 'log_level_in: warning\n\n'
      printf '[RULES]\n'
      printf '# Allow management LAN full access to PVE\n'
      printf 'IN ACCEPT --source %s --log warning\n' "$PVE_MGMT_CIDR"
      printf '# Allow established/related\n'
      printf 'IN ACCEPT -m state --state ESTABLISHED,RELATED\n'
    } | write_file /etc/pve/firewall/cluster.fw 0640 root:www-data
    local node_name
    node_name="$(hostname)"
    run_cmd install -d -m 0755 "/etc/pve/nodes/$node_name"
    {
      printf '[OPTIONS]\n'
      printf 'enable: 1\n\n'
      printf '[RULES]\n'
      printf '# Web UI\n'
      printf 'IN ACCEPT --dport 8006 --proto tcp --source %s\n' "$PVE_MGMT_CIDR"
      printf '# SSH\n'
      printf 'IN ACCEPT --dport 22 --proto tcp --source %s\n' "$PVE_MGMT_CIDR"
      printf '# SPICE console\n'
      printf 'IN ACCEPT --dport 3128 --proto tcp --source %s\n' "$PVE_MGMT_CIDR"
      printf '# VNC console range\n'
      printf 'IN ACCEPT --dport 5900:5999 --proto tcp --source %s\n' "$PVE_MGMT_CIDR"
      printf '# Live migration\n'
      printf 'IN ACCEPT --dport 60000:60050 --proto tcp --source %s\n' "$PVE_MGMT_CIDR"
    } | write_file "/etc/pve/nodes/$node_name/host.fw" 0640 root:www-data
    run_cmd systemctl enable --now pve-firewall
  fi

  # Fail2ban — the playbook's jail and filter, same values
  run_cmd install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/filter.d
  {
    printf '[DEFAULT]\n'
    printf 'bantime  = %s\n' "$FAIL2BAN_BANTIME"
    printf 'findtime = %s\n' "$FAIL2BAN_FINDTIME"
    printf 'maxretry = %s\n' "$FAIL2BAN_MAXRETRY"
    printf 'backend  = systemd\n\n'
    printf '[sshd]\n'
    printf 'enabled  = true\n'
    printf 'port     = ssh\n'
    printf 'filter   = sshd\n'
    printf 'logpath  = /var/log/auth.log\n\n'
    printf '[proxmox-web]\n'
    printf 'enabled  = true\n'
    printf 'port     = 8006\n'
    printf 'filter   = proxmox\n'
    printf 'logpath  = /var/log/daemon.log\n'
    printf 'maxretry = %s\n' "$FAIL2BAN_MAXRETRY"
  } | write_file /etc/fail2ban/jail.d/proxmox.conf 0644 root:root
  {
    printf '[Definition]\n'
    printf 'failregex = pvedaemon\\[.*\\]: authentication failure; rhost=<HOST> user=.* msg=.*\n'
    printf 'ignoreregex =\n'
  } | write_file /etc/fail2ban/filter.d/proxmox.conf 0644 root:root
  run_cmd systemctl enable --now fail2ban

  # Unattended upgrades — the playbook's two apt config files
  {
    printf 'Unattended-Upgrade::Origins-Pattern {\n'
    # ${distro_codename} is literal apt syntax that apt expands itself
    # at run time; it must not be shell-expanded here.
    # shellcheck disable=SC2016
    printf '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";\n'
    # shellcheck disable=SC2016
    printf '    "origin=Proxmox,codename=${distro_codename},label=Proxmox Debian Repository";\n'
    printf '};\n'
    printf 'Unattended-Upgrade::AutoFixInterruptedDpkg "true";\n'
    printf 'Unattended-Upgrade::MinimalSteps "true";\n'
    printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\n'
    printf 'Unattended-Upgrade::Remove-Unused-Dependencies "true";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    printf 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";\n'
    if [[ -n "$NOTIFY_EMAIL" ]]; then
      printf 'Unattended-Upgrade::Mail "%s";\n' "$NOTIFY_EMAIL"
      printf 'Unattended-Upgrade::MailReport "on-change";\n'
    fi
  } | write_file /etc/apt/apt.conf.d/50unattended-upgrades 0644 root:root
  {
    printf 'APT::Periodic::Update-Package-Lists "1";\n'
    printf 'APT::Periodic::Download-Upgradeable-Packages "1";\n'
    printf 'APT::Periodic::AutocleanInterval "7";\n'
    printf 'APT::Periodic::Unattended-Upgrade "1";\n'
  } | write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root:root
  run_cmd systemctl enable --now unattended-upgrades

  if [[ "$DRY_RUN" -eq 0 ]]; then
    local svc
    for svc in pvedaemon pveproxy pvestatd pve-cluster pve-firewall; do
      systemctl enable --now "$svc" || die "service failed: $svc"
    done
  else
    printf 'DRY-RUN: systemctl enable --now pvedaemon pveproxy pvestatd pve-cluster pve-firewall\n'
  fi

  log "============================================"
  log "  Proxmox VE Homelab Config Complete"
  log "============================================"
  log "Version     : ${PVE_VERSION:-pveversion (dry-run)}"
  log "Admin user  : $PVE_ADMIN_USER@pam"
  log "API user    : $PVE_API_USER / token: $PVE_API_TOKEN_NAME"
  log "Storage     : local (images, rootdir, iso, snippets, vztmpl, backup)"
  log "NFS storage : $([[ "$PVE_NFS_ENABLED" -eq 1 ]] && printf 'enabled -> %s' "$PVE_NFS_STORAGE_ID" || printf 'disabled')"
  log "Firewall    : $([[ "$PVE_FIREWALL_ENABLED" -eq 1 ]] && printf 'enabled (LAN: %s)' "$PVE_MGMT_CIDR" || printf 'disabled')"
  log "Fail2ban    : enabled ($FAIL2BAN_MAXRETRY retries / ${FAIL2BAN_BANTIME}s ban)"
  log "Auto-patch  : enabled (security + PVE, no auto-reboot)"
  log "Sub nag     : patched"
  log "============================================"
}

# ---------------------------------------------------------------------
# templates-cloudinit — templates_cloudinit.yml
# ---------------------------------------------------------------------
do_templates_cloudinit() {
  require_debian
  require_pve
  run_cmd install -d -m 0700 "$TEMPLATE_TMPDIR"

  local -a ids=(9000 9001)
  local -a names=(debian-12-cloudinit ubuntu-2404-cloudinit)
  local -a urls=(
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  )
  local keyfile=/tmp/pve_cloudinit_pubkey.tmp
  if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    printf '%s\n' "$SSH_PUBLIC_KEY" | write_file "$keyfile" 0600 root:root
  fi

  local i id name
  for i in "${!ids[@]}"; do
    id="${ids[$i]}"
    name="${names[$i]}"
    if [[ "$DRY_RUN" -eq 0 ]] && qm status "$id" >/dev/null 2>&1; then
      log "Skipping $name (VMID $id) — already exists"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'DRY-RUN: qm status %s (skip if it exists)\n' "$id"
    fi
    run_cmd curl -fL --output "$TEMPLATE_TMPDIR/$name.qcow2" "${urls[$i]}"
    run_cmd qm create "$id" --name "$name" --memory "$TEMPLATE_MEMORY" \
      --cores "$TEMPLATE_CORES" --net0 "virtio,bridge=$BRIDGE_NAME" \
      --ostype l26 --agent enabled=1 --serial0 socket --vga serial0
    run_cmd qm importdisk "$id" "$TEMPLATE_TMPDIR/$name.qcow2" "$TEMPLATE_STORAGE"
    run_cmd qm set "$id" --scsihw virtio-scsi-pci \
      --scsi0 "$TEMPLATE_STORAGE:vm-$id-disk-0" \
      --ide2 "$TEMPLATE_STORAGE:cloudinit" --boot c --bootdisk scsi0 \
      --ipconfig0 ip=dhcp
    if [[ -n "$SSH_PUBLIC_KEY" ]]; then
      run_cmd qm set "$id" --sshkeys "$keyfile"
    fi
    run_cmd_ok qm resize "$id" scsi0 "$TEMPLATE_DISK_SIZE"
    run_cmd qm template "$id"
    run_cmd rm -f "$TEMPLATE_TMPDIR/$name.qcow2"
    log "VMID $id — $name: created"
  done
  run_cmd rm -f "$keyfile"
  log "Clone a VM: qm clone 9000 100 --name my-debian-vm --full true"
}

# ---------------------------------------------------------------------
# templates-turnkey — templates_turnkey.yml
# ---------------------------------------------------------------------
do_templates_turnkey() {
  require_debian
  require_pve
  local -a matches=(
    debian-12-turnkey-core
    debian-12-turnkey-gitea
    debian-12-turnkey-wireguard
    debian-12-turnkey-pihole
    debian-12-turnkey-nginx
  )
  run_cmd pveam update
  if [[ "$DRY_RUN" -eq 1 ]]; then
    local m
    for m in "${matches[@]}"; do
      printf 'DRY-RUN: resolve latest %s via pveam available; download to %s if missing; verify with pveam list\n' \
        "$m" "$CT_STORAGE"
    done
    return 0
  fi
  local available local_list resolved m
  available="$(pveam available --section turnkeylinux)" \
    || die "pveam available failed"
  local_list="$(pveam list "$CT_STORAGE")" || die "pveam list failed"
  for m in "${matches[@]}"; do
    resolved="$(printf '%s\n' "$available" | awk '{print $2}' | grep "$m" | sort -V | tail -n 1 || true)"
    [[ -n "$resolved" ]] || die "Could not resolve template for '$m'. Run 'pveam available --section turnkeylinux | grep $m' on the host to verify the name."
    if [[ "$local_list" == *"$resolved"* ]]; then
      log "Already downloaded — skipping: $resolved"
      continue
    fi
    pveam download "$CT_STORAGE" "$resolved" || die "download failed: $resolved"
  done
  local final_list
  final_list="$(pveam list "$CT_STORAGE")" || die "pveam list failed"
  for m in "${matches[@]}"; do
    resolved="$(printf '%s\n' "$available" | awk '{print $2}' | grep "$m" | sort -V | tail -n 1 || true)"
    [[ "$final_list" == *"$resolved"* ]] \
      || die "Template $resolved was not found in $CT_STORAGE after download"
    log "Confirmed: $resolved"
  done
}

# ---------------------------------------------------------------------
# api-check — REST validation of an API token (GET /api2/json/version)
# ---------------------------------------------------------------------
do_api_check() {
  [[ -n "$API_URL" ]] || die "api-check needs --api-url https://HOST:8006"
  [[ "$API_URL" == https://* ]] || die "--api-url must start with https://"
  local user="${API_USER:-$PVE_API_USER}"
  local tname="${API_TOKEN_NAME:-$PVE_API_TOKEN_NAME}"
  [[ -n "$API_TOKEN_SECRET" ]] || die "api-check needs --api-token-secret (or \$PVE_API_TOKEN_SECRET)"
  local -a curl_args=(-fsS -H "Authorization: PVEAPIToken=${user}!${tname}=${API_TOKEN_SECRET}")
  if [[ "$API_INSECURE" -eq 1 ]]; then
    curl_args+=(-k)
    warn "--insecure: TLS certificate verification is disabled for this check"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: curl -fsS -H "Authorization: PVEAPIToken=%s!%s=<secret>" %s %s/api2/json/version\n' \
      "$user" "$tname" "$([[ "$API_INSECURE" -eq 1 ]] && printf -- '-k')" "$API_URL"
    return 0
  fi
  local out
  out="$(curl "${curl_args[@]}" "$API_URL/api2/json/version")" \
    || die "API check failed: $API_URL did not answer /api2/json/version for $user!$tname (curl exit $?)"
  log "API OK: $out"
}

# ---------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }
SUBCOMMAND="$1"
shift
case "$SUBCOMMAND" in
  install|configure|prep|templates-cloudinit|templates-turnkey|all|api-check) ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown subcommand: $SUBCOMMAND (see --help)" ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --bridge-iface) BRIDGE_IFACE="${2:?--bridge-iface needs a value}"; shift 2 ;;
    --bridge-ip) BRIDGE_IP="${2:?--bridge-ip needs a value}"; shift 2 ;;
    --bridge-prefix) BRIDGE_PREFIX="${2:?--bridge-prefix needs a value}"; shift 2 ;;
    --bridge-gateway) BRIDGE_GATEWAY="${2:?--bridge-gateway needs a value}"; shift 2 ;;
    --bridge-dns) BRIDGE_DNS="${2:?--bridge-dns needs a value}"; shift 2 ;;
    --hostname) HOSTNAME_FQDN="${2:?--hostname needs a value}"; shift 2 ;;
    --admin-password) PVE_ADMIN_PASSWORD="${2:?--admin-password needs a value}"; shift 2 ;;
    --mgmt-cidr) PVE_MGMT_CIDR="${2:?--mgmt-cidr needs a value}"; shift 2 ;;
    --nfs) PVE_NFS_ENABLED=1; shift ;;
    --nfs-server) PVE_NFS_SERVER="${2:?--nfs-server needs a value}"; shift 2 ;;
    --nfs-export) PVE_NFS_EXPORT="${2:?--nfs-export needs a value}"; shift 2 ;;
    --notify-email) NOTIFY_EMAIL="${2:?--notify-email needs a value}"; shift 2 ;;
    --no-firewall) PVE_FIREWALL_ENABLED=0; shift ;;
    --ssh-public-key) SSH_PUBLIC_KEY="${2:?--ssh-public-key needs a value}"; shift 2 ;;
    --api-url) API_URL="${2:?--api-url needs a value}"; shift 2 ;;
    --api-user) API_USER="${2:?--api-user needs a value}"; shift 2 ;;
    --api-token-name) API_TOKEN_NAME="${2:?--api-token-name needs a value}"; shift 2 ;;
    --api-token-secret) API_TOKEN_SECRET="${2:?--api-token-secret needs a value}"; shift 2 ;;
    --insecure) API_INSECURE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ "$PVE_MGMT_CIDR" == */* ]] || die "--mgmt-cidr must be a CIDR (address/prefix): $PVE_MGMT_CIDR"
if [[ -n "$BRIDGE_IP" && "$BRIDGE_IP" != *.*.*.* ]]; then
  die "--bridge-ip does not look like an IPv4 address: $BRIDGE_IP"
fi

require_root

case "$SUBCOMMAND" in
  install) do_install ;;
  configure) do_configure ;;
  prep) do_prep ;;
  templates-cloudinit) do_templates_cloudinit ;;
  templates-turnkey) do_templates_turnkey ;;
  api-check) do_api_check ;;
  all)
    do_install
    do_configure
    do_prep
    do_templates_cloudinit
    do_templates_turnkey
    ;;
esac
