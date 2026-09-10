#!/usr/bin/env bash
# install-gitea.sh — hardened Gitea deployment (built-in SSH mode)
# Version pin: Gitea 1.26.4 | Arch: amd64/arm64/arm-6 | OS: Debian-family, RHEL-family
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

echo "==> Installing dependencies..."
if [ "$OS" = "debian" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git wget sqlite3 ca-certificates
elif [ "$OS" = "rhel" ]; then
    dnf install -y git wget sqlite ca-certificates
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
mkdir -p /var/lib/gitea/{custom,data,log}
chown -R git:git /var/lib/gitea
chmod -R 750 /var/lib/gitea
mkdir -p /etc/gitea
chown root:git /etc/gitea
chmod 750 /etc/gitea

echo "==> Seeding app.ini (built-in SSH server)..."
# Pre-seeds [server] so the first-run web installer inherits these values.
# TIGHTEN AFTER SETUP: chmod 640 /etc/gitea/app.ini and remove /etc/gitea
# from ReadWritePaths in the unit.
if [ ! -f /etc/gitea/app.ini ]; then
    cat <<'EOF' > /etc/gitea/app.ini
[server]
PROTOCOL         = http
HTTP_PORT        = 3000
START_SSH_SERVER = true
SSH_PORT         = 2222
SSH_LISTEN_PORT  = 2222
DISABLE_SSH      = false
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
# NOTE: remove /etc/gitea after first-run setup completes
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
echo "NOTE: No firewall changes were made."
echo "POST-SETUP: chmod 640 /etc/gitea/app.ini; remove /etc/gitea from"
echo "            ReadWritePaths in gitea.service; daemon-reload + restart."
