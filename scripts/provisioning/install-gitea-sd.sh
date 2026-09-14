#!/usr/bin/env bash
#===============================================================================
# install-gitea.sh v2.0-sd — hardened Gitea deployment, SD-endurance edition
#
# TARGETS
#   Debian-family (Armbian/RaspiOS/Debian/Ubuntu) and RHEL-family
#   (Rocky/Alma 8-10). Arch: amd64 / arm64 / arm-6. Gitea pinned: 1.26.4.
#
# SD-CARD ENDURANCE (auto-gated)
#   Flash measures apply ONLY when the root filesystem lives on an SD/MMC
#   device (/dev/mmcblk*), or when forced with SD_OPTIMIZE=1. On NVMe/SSD
#   nodes the script behaves like the stock hardened installer.
#   Override: SD_OPTIMIZE=0 skips them even on MMC.
#
#   Measures, and the write class each eliminates:
#     1. zram swap (native unit, zero package deps) — replaces SD-backed
#        swap; kills paging writes entirely. Skipped gracefully if the
#        kernel lacks the zram module.
#     2. noatime on /              — kills one metadata write per file read.
#     3. journald cap (100M/1mo)   — bounds log growth; journal stays
#        PERSISTENT because post-setup-tighten.sh sweeps it for denials.
#     4. tmpfs /tmp (512M)         — Gitea archive/upload temp I/O goes to
#        RAM (PrivateTmp namespaces live under /tmp on the real fs).
#     5. app.ini seeded with SQLITE_JOURNAL_MODE=WAL — sequential WAL
#        appends instead of rollback-journal create/sync/delete per txn;
#        the single biggest sqlite-on-SD win.
#     6. app.ini seeded with [log] console/Warn — one bounded log sink
#        (journald), no duplicate file logs on flash.
#     7. /var/lib/gitea/dump/ staging dir — wear mitigation extends card
#        life; the dump/backup cycle (installed by post-setup-tighten.sh)
#        is what makes card death a reflash, not an incident.
#
#   DECLINED (documented so you don't re-litigate later):
#     - ext4 commit=60 / vm.dirty_* stretching: trades a 60s power-loss
#       data window for modest wear savings. Rejected — no UPS on Pi
#       nodes, git object durability wins.
#     - Storage=volatile journald: would blind the canary's denial sweep.
#
# FSTAB SAFETY
#   /etc/fstab edits are staged to fstab.new, gated by `findmnt --verify`,
#   and only then swapped in. Original preserved at /etc/fstab.bak.<epoch>.
#   noatime takes effect at next reboot (mount -o remount does not
#   reliably re-read fstab); the post-install `dnf upgrade` reboot covers it.
#
# USAGE
#   bash install-gitea.sh              # auto-detect everything
#   SD_OPTIMIZE=0 bash install-gitea.sh   # force-skip flash measures
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

GITEA_VERSION="1.26.4"
HTTP_PORT="3000"
SSH_PORT="2222"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

echo "==> Detecting OS..."
. /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *debian*|*ubuntu*|*raspbian*)
    OS="debian"
    ;;
  *rhel*|*centos*|*rocky*|*almalinux*|*fedora*)
    OS="rhel"
    ;;
  *)
    echo "Unsupported OS: ${ID:-unknown}"
    exit 1
    ;;
esac

echo "==> Detecting architecture..."
case "$(uname -m)" in
  x86_64)        ARCH="amd64" ;;
  aarch64)       ARCH="arm64" ;;
  armv7l|armv6l) ARCH="arm-6" ;;
  *)
    echo "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

echo "==> Detecting storage medium..."
ROOT_DEV=$(findmnt -no SOURCE /)
if [ "${SD_OPTIMIZE:-auto}" = "auto" ]; then
    # lsblk -s walks the device's ANCESTOR chain: catches LUKS2/LVM roots
    # stacked on SD (/dev/mapper/* over mmcblk), not just raw mmcblk
    # partitions. Falls through to 0 if lsblk can't resolve the source.
    if lsblk -sno NAME "$ROOT_DEV" 2>/dev/null | grep -q '^mmcblk'; then
        SD_OPTIMIZE=1
    else
        SD_OPTIMIZE=0
    fi
fi
echo "    root on ${ROOT_DEV} — SD endurance measures: $([ "$SD_OPTIMIZE" = 1 ] && echo ON || echo off)"

echo "==> Installing dependencies..."
if [ "$OS" = "debian" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git wget sqlite3 ca-certificates
elif [ "$OS" = "rhel" ]; then
    # sqlite: CLI needed by post-setup-tighten.sh to verify WAL mode.
    dnf install -y git wget sqlite ca-certificates
fi

if [ "$SD_OPTIMIZE" = 1 ]; then
    echo "==> [SD 1/4] zram swap (replacing flash-backed swap)..."
    if modprobe zram 2>/dev/null; then
        cat <<'EOF' > /usr/local/sbin/zram-swap-on
#!/bin/sh
# zram-swap-on — idempotent zram0 swap bring-up (invoked by zram-swap.service)
set -e
modprobe zram
# comp_algorithm must be set BEFORE disksize; zstd if kernel offers it,
# otherwise kernel default (lzo) — both fine, zstd just compresses better.
grep -qw zstd /sys/block/zram0/comp_algorithm 2>/dev/null \
    && echo zstd > /sys/block/zram0/comp_algorithm
echo 1G > /sys/block/zram0/disksize
mkswap -q /dev/zram0
# priority 100: always preferred over any residual disk swap
swapon -p 100 /dev/zram0
EOF
        cat <<'EOF' > /usr/local/sbin/zram-swap-off
#!/bin/sh
set -e
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
EOF
        chmod 0755 /usr/local/sbin/zram-swap-on /usr/local/sbin/zram-swap-off
        cat <<'EOF' > /etc/systemd/system/zram-swap.service
[Unit]
Description=Compressed RAM swap on zram0
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap-on
ExecStop=/usr/local/sbin/zram-swap-off

[Install]
WantedBy=multi-user.target
EOF
        # Retire flash-backed swap: disable now, comment out of fstab below.
        swapoff -a 2>/dev/null || true
        systemctl daemon-reload
        systemctl enable --now zram-swap.service
        echo "    active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
    else
        echo "    NOTICE: kernel lacks zram module — swap left as-is, continuing"
    fi

    echo "==> [SD 2/4] fstab: noatime on /, retire flash swap (verified swap-in)..."
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    awk '
        /^[[:space:]]*#/ { print; next }                 # comments untouched
        NF >= 4 && $3 == "swap" { print "#" $0; next }   # retire disk swap
        NF >= 4 && $2 == "/" && $4 !~ /noatime/ { $4 = $4",noatime" }
        { print }
    ' /etc/fstab > /etc/fstab.new
    if findmnt --verify --tab-file /etc/fstab.new >/dev/null 2>&1; then
        mv /etc/fstab.new /etc/fstab
        echo "    fstab updated (noatime applies at next reboot)"
    else
        rm -f /etc/fstab.new
        echo "    NOTICE: staged fstab failed findmnt --verify — original kept, continuing"
    fi

    echo "==> [SD 3/4] journald: bounded persistent journal..."
    mkdir -p /etc/systemd/journald.conf.d
    cat <<'EOF' > /etc/systemd/journald.conf.d/sd-card.conf
[Journal]
# Persistent (NOT volatile): post-setup-tighten.sh sweeps the journal for
# seccomp/namespace denials across the restart boundary. Bounded instead.
SystemMaxUse=100M
MaxRetentionSec=1month
EOF
    systemctl restart systemd-journald

    echo "==> [SD 4/4] tmpfs /tmp..."
    if systemctl enable tmp.mount 2>/dev/null; then
        systemctl start tmp.mount 2>/dev/null || true
        echo "    tmp.mount enabled"
    elif ! grep -qE '^[^#]*\s/tmp\s+tmpfs' /etc/fstab; then
        # size cap: Gitea archive generation is the main tenant; 512M is
        # ample and can't crowd the 3.7G-class Pi nodes.
        echo 'tmpfs /tmp tmpfs defaults,nosuid,nodev,size=512m 0 0' >> /etc/fstab
        echo "    fstab tmpfs entry added (mounts at next reboot)"
    else
        echo "    /tmp already tmpfs-configured"
    fi
fi

echo "==> Creating git user..."
# Built-in SSH mode: no interactive shell required.
if ! id git >/dev/null 2>&1; then
    if [ "$OS" = "debian" ]; then
        adduser --system --shell /usr/sbin/nologin \
            --gecos 'Git Version Control' \
            --group --disabled-password \
            --home /home/git git
    else
        useradd --system --user-group --shell /usr/sbin/nologin \
            --comment 'Git Version Control' \
            --create-home git
    fi
fi

echo "==> Creating directories..."
# dump/: staging for gitea-dump backups (timer installed by
# post-setup-tighten.sh). Inside ReadWritePaths — no unit change needed.
# Dumps on the SAME card are staging only; pull them off-node.
mkdir -p /var/lib/gitea/{custom,data,log,dump}
chown -R git:git /var/lib/gitea
chmod -R 750 /var/lib/gitea
mkdir -p /etc/gitea
chown root:git /etc/gitea
chmod 750 /etc/gitea

echo "==> Seeding app.ini (built-in SSH, WAL, single log sink)..."
# Pre-seeds values the first-run web installer will inherit.
# TIGHTEN AFTER SETUP: handled by post-setup-tighten.sh.
if [ ! -f /etc/gitea/app.ini ]; then
    cat <<'EOF' > /etc/gitea/app.ini
[server]
PROTOCOL         = http
HTTP_PORT        = 3000
START_SSH_SERVER = true
SSH_PORT         = 2222
SSH_LISTEN_PORT  = 2222
DISABLE_SSH      = false

[database]
; WAL: sequential appends + periodic checkpoints instead of a
; create/fsync/delete rollback-journal cycle per transaction.
; The dominant sqlite write-pattern fix for SD media.
SQLITE_JOURNAL_MODE = WAL

[log]
; Single sink: journald (bounded by the SD journald cap). No duplicate
; file logs under /var/lib/gitea/log on flash. Warn keeps volume low;
; raise to Info temporarily when debugging.
MODE  = console
LEVEL = Warn
EOF
    chown root:git /etc/gitea/app.ini
    chmod 660 /etc/gitea/app.ini
fi

echo "==> Downloading Gitea ${GITEA_VERSION} (${ARCH})..."
BIN="gitea-${GITEA_VERSION}-linux-${ARCH}"
TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT
cd "$TMPDIR_DL"
wget -q --https-only --timeout=30 --tries=3 \
    "https://dl.gitea.com/gitea/${GITEA_VERSION}/${BIN}"
wget -q --https-only --timeout=30 --tries=3 \
    "https://dl.gitea.com/gitea/${GITEA_VERSION}/${BIN}.sha256"

echo "==> Verifying checksum..."
sha256sum -c "${BIN}.sha256"

echo "==> Installing binary..."
systemctl stop gitea 2>/dev/null || true
install -o root -g root -m 0755 "$BIN" /usr/local/bin/gitea

echo "==> Creating hardened systemd service..."
cat <<'EOF' > /etc/systemd/system/gitea.service
[Unit]
Description=Gitea
After=network-online.target
Wants=network-online.target

[Service]
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini --work-path /var/lib/gitea
Restart=always
RestartSec=2
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea
UMask=0027

# 🔐 Hardening Options
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true

# Allow writes only where needed
# NOTE: post-setup-tighten.sh removes /etc/gitea after first-run setup
ReadWritePaths=/var/lib/gitea /etc/gitea

# Kernel protections
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true

# Device isolation
PrivateDevices=true

# Capability restrictions
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=true

# Networking restrictions
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Namespace + exploit mitigations
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Hide /proc details
ProtectProc=invisible

[Install]
WantedBy=multi-user.target
EOF

echo "==> Handling SELinux if present..."
if command -v getenforce >/dev/null 2>&1; then
    if getenforce | grep -q Enforcing; then
        echo "SELinux is enforcing — restoring contexts"
        restorecon -R /usr/local/bin/gitea /var/lib/gitea /etc/gitea
    fi
fi

echo "==> Enabling and starting Gitea..."
systemctl daemon-reload
systemctl enable --now gitea

echo ""
IP_ADDR=$(ip route get 1 2>/dev/null | awk '{print $7; exit}') || IP_ADDR="<host-ip>"
echo "✅ Gitea ${GITEA_VERSION} installed with hardened systemd!"
echo "👉 Web:  http://${IP_ADDR}:${HTTP_PORT}"
echo "👉 SSH:  ssh://git@${IP_ADDR}:${SSH_PORT}/<user>/<repo>.git"
echo ""
echo "NOTE: No firewall changes were made. On firewalld nodes (Rocky):"
echo "      firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp --add-port=${SSH_PORT}/tcp && firewall-cmd --reload"
if [ "$SD_OPTIMIZE" = 1 ]; then
echo "SD:   reboot required for noatime/tmpfs to take effect (fold into the"
echo "      post-install 'dnf -y upgrade && reboot' you already run)."
fi
echo "NEXT: web installer at :${HTTP_PORT} -> upload SSH key + create canary"
echo "      repo -> run post-setup-tighten.sh"
