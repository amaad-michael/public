#!/bin/bash
set -euo pipefail

# ============================================================================
# PRE-FLIGHT CHECK: SSH KEY REQUIREMENT
# ============================================================================
# This script disables password authentication. You MUST have SSH key-based
# access configured BEFORE running this script, or you will be locked out.
#
# ABORT if you do NOT have an existing SSH key:
#   1. On your LOCAL machine, check for existing key:
#      ls -la ~/.ssh/id_ed25519.pub  (or similar)
#
#   2. If NO key exists, generate one BEFORE running this script:
#      ssh-keygen -t ed25519 -a 100 -C 'michael@hostname'
#
#   3. Copy the PUBLIC key to the target server BEFORE running this script:
#      ssh-copy-id -i ~/.ssh/id_ed25519.pub michael@<server-ip>
#
#   4. Test key-based login in a SEPARATE terminal:
#      ssh -i ~/.ssh/id_ed25519 michael@<server-ip>
#
#   5. ONLY RUN THIS SCRIPT after confirming key-based login works.
#
# WARNING: If you run this script without key access pre-configured,
#          SSH password authentication will be DISABLED and you will
#          be UNABLE to log in. Emergency recovery requires physical
#          access or console access to the machine.
# ============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Detect OS
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091 # /etc/os-release is a system file, absent at lint time
    . /etc/os-release
    OS_ID="$ID"
else
    log_error "Cannot detect OS"
fi

case "$OS_ID" in
    debian|ubuntu) DISTRO="debian" ;;
    rhel|rocky|almalinux|centos|fedora) DISTRO="rhel" ;;
    *) log_error "Unsupported distro: $OS_ID" ;;
esac

log_info "Detected: $OS_ID (${DISTRO^^})"

# ============================================================================
# 1. System Updates (no automatic patching)
# ============================================================================
log_info "Updating package manager..."
if [ "$DISTRO" = "debian" ]; then
    apt-get update
    apt-get upgrade -y

    # Disable unattended-upgrades
    apt-get remove -y unattended-upgrades 2>/dev/null || true

    # Disable automatic updates in apt
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

else  # RHEL
    dnf -y update

    # Disable dnf-automatic
    dnf remove -y dnf-automatic 2>/dev/null || true
    systemctl disable dnf-automatic-install.timer 2>/dev/null || true
fi

log_info "Auto-patching disabled"

# ============================================================================
# 2. Create 'michael' user
# ============================================================================
log_info "Creating user 'michael'..."
if ! id -u michael &>/dev/null; then
    useradd -m -s /bin/bash michael
    log_info "User 'michael' created"
else
    log_warn "User 'michael' already exists"
fi

# Add to sudoers (NOPASSWD for now; remove if you want password prompt)
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
cat > /etc/sudoers.d/michael <<'EOF'
michael ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/michael

log_info "User 'michael' added to sudoers"

# ============================================================================
# 3. SSH Hardening - Bernstein Crypto Stack
# ============================================================================
log_info "Hardening SSH daemon..."

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
# SSH Hardening - Bernstein Crypto Stack (Conservative) + Security Best Practices

# === Authentication ===
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 4
MaxSessions 3
LoginGraceTime 30
AllowUsers michael
PermitEmptyPasswords no

# === Cryptography - Bernstein Stack (Conservative) ===
HostKey /etc/ssh/ssh_host_ed25519_key
PubkeyAcceptedAlgorithms ssh-ed25519
HostKeyAlgorithms ssh-ed25519
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-256

# === Network ===
Port 22
AddressFamily inet
ListenAddress 0.0.0.0
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2

# === Restrictions ===
DisableForwarding yes
PermitTunnel no
PermitUserEnvironment no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no

# === Logging ===
LogLevel INFO
SyslogFacility AUTH
EOF

chmod 644 /etc/ssh/sshd_config.d/99-hardening.conf

# Validate SSH config
if ! sshd -t; then
    log_error "SSH config validation failed"
fi

# Restart SSH
systemctl restart ssh sshd 2>/dev/null || true
log_info "SSH hardened and restarted"

# ============================================================================
# 4. Firewall - Whitelist Approach (Port 22 only)
# ============================================================================
log_info "Configuring firewall..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y ufw

    # Reset and enable
    echo "y" | ufw reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw enable

    log_info "UFW enabled: default deny, port 22 allowed"

else  # RHEL
    dnf install -y firewalld
    systemctl enable firewalld
    systemctl start firewalld

    # Set default and allow SSH
    firewall-cmd --set-default-zone=public
    firewall-cmd --permanent --remove-service=dhcpv6-client 2>/dev/null || true
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload

    log_info "firewalld enabled: SSH allowed"
fi

# ============================================================================
# 5. Install fail2ban (SSH brute-force protection)
# ============================================================================
log_info "Installing fail2ban..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y fail2ban
    AUTH_LOG="/var/log/auth.log"
else
    dnf install -y fail2ban fail2ban-systemd
    AUTH_LOG="/var/log/secure"
fi

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = fail2ban

[sshd]
enabled = true
port = 22
filter = sshd
logpath = ${AUTH_LOG}
maxretry = 3
bantime = 1200
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log_info "fail2ban installed and enabled"

# ============================================================================
# 6. Install auditd (kernel-level auditing)
# ============================================================================
log_info "Installing auditd..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y auditd audispd-plugins
else
    dnf install -y audit audit-libs
fi

mkdir -p /etc/audit/rules.d

# Idempotent: only write if marker not present
if ! grep -q 'passwd_changes' /etc/audit/rules.d/hardening.rules 2>/dev/null; then
    cat > /etc/audit/rules.d/hardening.rules <<'EOF'
# Monitor authentication
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_changes

# Monitor SSH configuration
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes

# Monitor privileged commands only (avoid audit flood)
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_exec
EOF
fi

systemctl enable auditd
systemctl restart auditd
log_info "auditd installed and enabled"

# ============================================================================
# 7. Log Rotation - auth.log (1GB budget, daily rotation)
# ============================================================================
log_info "Configuring log rotation..."

if [ "$DISTRO" = "debian" ]; then
    LOG_FILE="/var/log/auth.log"
    LOG_OWNER="syslog adm"
else
    LOG_FILE="/var/log/secure"
    LOG_OWNER="root root"
fi

cat > /etc/logrotate.d/auth-hardening <<EOF
${LOG_FILE} {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 640 ${LOG_OWNER}
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || systemctl reload auditd > /dev/null 2>&1 || true
    endscript
}
EOF

chmod 644 /etc/logrotate.d/auth-hardening
log_info "Log rotation configured (daily, 30 days, ~1GB budget)"

# ============================================================================
# 8. Install lynis (security audit tool)
# ============================================================================
log_info "Installing lynis..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y lynis
else
    dnf install -y lynis
fi

log_info "lynis installed"

# ============================================================================
# 9. Verify AppArmor/SELinux (enforcing mode)
# ============================================================================
log_info "Verifying MAC enforcement..."

if [ "$DISTRO" = "debian" ]; then
    if command -v aa-status &>/dev/null; then
        status=$(aa-status 2>/dev/null | head -1 || echo "unknown")
        log_info "AppArmor: $status"
    fi
else
    if command -v getenforce &>/dev/null; then
        status=$(getenforce)
        log_info "SELinux: $status"
    fi
fi

# ============================================================================
# 10. Pi Cluster Personalization - /etc/hosts and cluster MOTD
# ============================================================================
log_info "Configuring Pi cluster networking and MOTD..."

# Update /etc/hosts with cluster entries (idempotent)
if ! grep -q 'pi0' /etc/hosts 2>/dev/null; then
    cat >> /etc/hosts <<'EOF'

## local subnet
192.168.0.100   pi0
192.168.0.101   pi1
192.168.0.102   pi2
192.168.0.103   pi3
192.168.0.104   pi4
192.168.0.105   neo1
EOF
fi

log_info "/etc/hosts updated with Pi cluster entries"

# ============================================================================
# 11. Cosmetics - fastfetch MOTD + disable noise
# ============================================================================
log_info "Installing fastfetch and neofetch..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y fastfetch neofetch >/dev/null 2>&1

    log_info "Disabling noisy MOTD scripts..."
    chmod -x /etc/update-motd.d/80-esm-announce 2>/dev/null || true
    chmod -x /etc/update-motd.d/91-contract-ua-esm-status 2>/dev/null || true
    chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
    chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
    chmod -x /etc/update-motd.d/80-livepatch 2>/dev/null || true
    chmod -x /etc/update-motd.d/95-hwe-eol 2>/dev/null || true
    chmod -x /etc/update-motd.d/98-fsck-at-reboot 2>/dev/null || true

    MOTD_DIR="/etc/update-motd.d"
else
    dnf install -y fastfetch neofetch >/dev/null 2>&1
    MOTD_DIR="/etc/motd.d"
    mkdir -p "$MOTD_DIR"
    chmod 755 "$MOTD_DIR"

    log_warn "RHEL MOTD Caveat: /etc/motd.d is created, but sourcing depends"
    log_warn "on PAM configuration. If custom MOTD does not appear after login,"
    log_warn "verify that /etc/pam.d/login includes: session optional pam_motd.so"
fi

# Create cluster context header + fastfetch MOTD
cat > "$MOTD_DIR/05-system-info" <<'EOFMOTD'
#!/bin/bash
echo "▄▀▄     █▄ ▄█ █ ▄▀▀ █▄█ ▄▀▄ ██▀ █      ▀█▀ ▄▀▄ ▀█▀ █ █ █▄ ▄█"
echo "█▀█ ▄   █ ▀ █ █ ▀▄▄ █ █ █▀█ █▄▄ █▄▄     █  █▀█  █  ▀▄█ █ ▀ █"
echo ""
echo "## local subnet"
echo "192.168.0.100   pi0"
echo "192.168.0.101   pi1"
echo "192.168.0.102   pi2"
echo "192.168.0.103   pi3"
echo "192.168.0.104   pi4"
echo "192.168.0.105   neo1"
echo ""
if command -v fastfetch &>/dev/null; then
    fastfetch --logo small --color-keys blue --color-title yellow
elif command -v neofetch &>/dev/null; then
    neofetch
fi
EOFMOTD

chmod +x "$MOTD_DIR/05-system-info"

if ! grep -q "^PrintMotd yes" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null; then
    echo "PrintMotd yes" >> /etc/ssh/sshd_config.d/99-hardening.conf
fi

log_info "Cosmetics configured (cluster context + fastfetch/neofetch, colorized MOTD)"

# ============================================================================
# 12. Disable IPv6
# ============================================================================
log_info "Disabling IPv6..."

if [ ! -f /etc/sysctl.d/99-disable-ipv6.conf ]; then
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null
fi

log_info "IPv6 disabled"

# ============================================================================
# Summary
# ============================================================================
log_info "=========================================="
log_info "Hardening Complete (Conservative Variant)"
log_info "=========================================="
echo ""
echo "Summary of changes:"
echo "  ✓ System updated (auto-patching disabled)"
echo "  ✓ User 'michael' created + sudoers configured"
echo "  ✓ SSH hardened: Ed25519 keys, Conservative Bernstein crypto stack"
echo "    - KexAlgorithms: curve25519-sha256 (no post-quantum)"
echo "    - Ciphers: chacha20-poly1305@openssh.com (single cipher)"
echo "    - MACs: hmac-sha2-256-etm (SHA2-256 only)"
echo "    - PermitRootLogin: prohibit-password (key-based root access allowed)"
echo "  ✓ Firewall: whitelist approach, port 22 only"
echo "  ✓ fail2ban: SSH brute-force protection (3 tries, 20min ban)"
echo "  ✓ auditd: kernel-level audit logging enabled"
echo "  ✓ Log rotation: daily, 30 days (~1GB budget)"
echo "  ✓ lynis: security auditing tool installed"
echo "  ✓ Pi cluster personalization: /etc/hosts + cluster context MOTD"
echo "  ✓ Cosmetics: fastfetch + neofetch, colorized MOTD, noise disabled"
echo "  ✓ IPv6: disabled"
echo ""
echo "⚠️  CRITICAL: SSH Key Setup Required"
echo "======================================"
echo "This script disables password authentication."
echo "You MUST set up key-based auth BEFORE closing your SSH session:"
echo ""
echo "  1. On your LOCAL machine, generate an Ed25519 key:"
echo "     ssh-keygen -t ed25519 -a 100 -C 'michael@hostname'"
echo ""
echo "  2. Copy public key to server (while still connected):"
echo "     ssh-copy-id -i ~/.ssh/id_ed25519.pub michael@<server-ip>"
echo ""
echo "  3. TEST the new key in a SECOND terminal:"
echo "     ssh -i ~/.ssh/id_ed25519 michael@<server-ip>"
echo ""
echo "  4. ONLY THEN close your current SSH session."
echo ""
echo "If you close without testing, you will be LOCKED OUT."
echo "======================================"
echo ""
echo "This variant prioritizes compatibility over post-quantum resistance."
echo ""
echo "Next steps:"
echo "  1. Generate SSH key on your LOCAL machine:"
echo "     ssh-keygen -t ed25519 -a 100 -C 'michael@hostname'"
echo "  2. Copy public key to server:"
echo "     ssh-copy-id -i ~/.ssh/id_ed25519.pub michael@<server-ip>"
echo "  3. Test key-based login in SECOND terminal before closing this session"
echo "  4. Run: sudo lynis audit system"
echo ""
log_info "=========================================="
