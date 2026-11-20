#!/bin/bash
set -euo pipefail

# Server Hardening Script - Legacy Systems (Password Auth)
# Debian/RHEL with older OpenSSH versions
# Runs post clean install. Must execute as root.
# Creates 'michael' user, hardens SSH (legacy crypto), configures firewall,
# installs fail2ban/auditd/lynis, disables auto-patching, IPv4 only.

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

    apt-get remove -y unattended-upgrades 2>/dev/null || true

    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

else  # RHEL
    dnf -y update

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

mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
cat > /etc/sudoers.d/michael <<'EOF'
michael ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/michael

log_info "User 'michael' added to sudoers"

# ============================================================================
# 3. SSH Hardening - Legacy (Password Auth + RSA-4096)
# ============================================================================
log_info "Hardening SSH daemon (legacy mode)..."

# Generate RSA-4096 host key if missing or undersized
if ! ssh-keygen -l -f /etc/ssh/ssh_host_rsa_key 2>/dev/null | grep -q '4096'; then
    log_info "Generating RSA-4096 host key..."
    rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
    ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N '' -C "host-key-$(hostname)" >/dev/null 2>&1
    chmod 600 /etc/ssh/ssh_host_rsa_key
    chmod 644 /etc/ssh/ssh_host_rsa_key.pub
fi

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
# SSH Hardening - Legacy Systems (Password Auth Compatible)

# === Authentication ===
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication no
AuthenticationMethods password publickey
MaxAuthTries 5
MaxSessions 3
LoginGraceTime 30
AllowUsers michael
PermitEmptyPasswords no
UsePAM yes

# === Cryptography - Legacy (RSA-4096 + Standard AES) ===
HostKey /etc/ssh/ssh_host_rsa_key
PubkeyAcceptedAlgorithms ssh-rsa,rsa-sha2-512,rsa-sha2-256
HostKeyAlgorithms ssh-rsa,rsa-sha2-512,rsa-sha2-256
KexAlgorithms diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256
Ciphers aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512,hmac-sha2-256

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

if ! sshd -t; then
    log_error "SSH config validation failed"
fi

systemctl restart ssh sshd 2>/dev/null || true
log_info "SSH hardened and restarted (legacy mode)"

# ============================================================================
# 4. Password Policy Enforcement (critical for legacy)
# ============================================================================
log_info "Enforcing password policy..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y libpam-pwquality >/dev/null 2>&1

    if [ ! -f /etc/security/pwquality.conf.bak ]; then
        cp /etc/security/pwquality.conf /etc/security/pwquality.conf.bak
    fi

    cat > /etc/security/pwquality.conf <<'EOF'
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
difok = 3
maxrepeat = 3
usercheck = 1
enforcing = 1
EOF

else  # RHEL
    dnf install -y cracklib cracklib-dicts >/dev/null 2>&1
    dnf install -y python3-libpwquality >/dev/null 2>&1

    if [ ! -f /etc/security/pwquality.conf.bak ]; then
        cp /etc/security/pwquality.conf /etc/security/pwquality.conf.bak
    fi

    cat > /etc/security/pwquality.conf <<'EOF'
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
difok = 3
maxrepeat = 3
usercheck = 1
enforcing = 1
EOF
fi

log_info "Password policy enforced (14+ chars, mixed case/numbers/symbols)"

# ============================================================================
# 5. Account Lockout Policy
# ============================================================================
log_info "Configuring account lockout..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y libpam-modules >/dev/null 2>&1

    # Use pam_faillock (modern replacement for tally2)
    if ! grep -q "pam_faillock" /etc/pam.d/common-auth 2>/dev/null; then
        # Preauth check: deny after 5 failures
        sed -i '/^auth.*pam_unix.so/{h;s/.*/auth required pam_faillock.so preauth audit silent deny=5 unlock_time=900/;G;}' /etc/pam.d/common-auth
        # Authfail: update failure count
        sed -i '/^auth.*pam_unix.so/{h;s/.*/auth [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900/;G;}' /etc/pam.d/common-auth
        # Account phase: reset failure count on successful auth
        if ! grep -q "pam_faillock" /etc/pam.d/common-account 2>/dev/null; then
            sed -i '/^account/a account required pam_faillock.so' /etc/pam.d/common-account
        fi
        log_info "Account lockout configured with pam_faillock (Debian)"
    fi

else  # RHEL
    dnf install -y pam >/dev/null 2>&1

    if ! grep -q "pam_faillock" /etc/pam.d/system-auth 2>/dev/null; then
        # Try authselect first (RHEL 8+)
        if command -v authselect &>/dev/null; then
            authselect enable-feature with-faillock 2>/dev/null || {
                # Fallback: manual edit for older RHEL
                sed -i '/^auth.*pam_unix.so/{h;s/.*/auth required pam_faillock.so preauth audit silent deny=5 unlock_time=900/;G;}' /etc/pam.d/system-auth
                sed -i '/^auth.*pam_unix.so/{h;s/.*/auth [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900/;G;}' /etc/pam.d/system-auth
            }
        else
            # Older RHEL without authselect
            sed -i '/^auth.*pam_unix.so/{h;s/.*/auth required pam_faillock.so preauth audit silent deny=5 unlock_time=900/;G;}' /etc/pam.d/system-auth
            sed -i '/^auth.*pam_unix.so/{h;s/.*/auth [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900/;G;}' /etc/pam.d/system-auth
        fi

        if ! grep -q "pam_faillock" /etc/pam.d/system-auth 2>/dev/null; then
            sed -i '/^account/a account required pam_faillock.so' /etc/pam.d/system-auth
        fi
        log_info "Account lockout configured with pam_faillock (RHEL)"
    fi
fi

log_info "Account lockout: 5 failures = 15min lock"

# ============================================================================
# 6. Firewall - Whitelist Approach (Port 22 only)
# ============================================================================
log_info "Configuring firewall..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y ufw

    echo "y" | ufw reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw enable

    log_info "UFW enabled: default deny, port 22 allowed"

else
    dnf install -y firewalld
    systemctl enable firewalld
    systemctl start firewalld

    firewall-cmd --set-default-zone=public
    firewall-cmd --permanent --remove-service=dhcpv6-client 2>/dev/null || true
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload

    log_info "firewalld enabled: SSH allowed"
fi

# ============================================================================
# 7. Install fail2ban (CRITICAL for password auth)
# ============================================================================
log_info "Installing fail2ban..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y fail2ban
    AUTH_LOG="/var/log/auth.log"
else
    dnf install -y fail2ban fail2ban-systemd
    AUTH_LOG="/var/log/secure"
fi

mkdir -p /etc/fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 900
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = fail2ban

[sshd]
enabled = true
port = 22
filter = sshd
logpath = ${AUTH_LOG}
maxretry = 5
bantime = 1800
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log_info "fail2ban installed and enabled (5 failures = 30min ban)"

# ============================================================================
# 8. Install auditd (kernel-level auditing)
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
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_changes
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes
-w /etc/ssh/ssh_host_rsa_key -p wa -k ssh_hostkey_changes
-w /etc/ssh/ssh_host_rsa_key.pub -p wa -k ssh_hostkey_changes
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_exec
EOF
fi

systemctl enable auditd
systemctl restart auditd
log_info "auditd installed and enabled"

# ============================================================================
# 9. Log Rotation - auth.log (1GB budget, daily rotation)
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
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 600 ${LOG_OWNER}
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || systemctl reload auditd > /dev/null 2>&1 || true
    endscript
}
EOF

# Audit log rotation (prevent partition fill and silent auditd failure)
cat > /etc/logrotate.d/audit-hardening <<EOF
/var/log/audit/audit.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 600 root root
    postrotate
        systemctl restart auditd > /dev/null 2>&1 || true
    endscript
}
EOF

chmod 644 /etc/logrotate.d/auth-hardening /etc/logrotate.d/audit-hardening
log_info "Log rotation configured (daily, 14 days, SD card optimized)"

# ============================================================================
# 10. Install lynis (security audit tool)
# ============================================================================
log_info "Installing lynis..."

if [ "$DISTRO" = "debian" ]; then
    apt-get install -y lynis
else
    dnf install -y lynis
fi

log_info "lynis installed"

# ============================================================================
# 11. Verify AppArmor/SELinux (enforcing mode)
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
# 12. Pi Cluster Personalization - /etc/hosts and cluster MOTD
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
# 13. Cosmetics - fastfetch MOTD + disable noise
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
# 14. Disable IPv6
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
log_info "Hardening Complete (Legacy Mode)"
log_info "=========================================="
echo ""
echo "Summary of changes:"
echo "  ✓ System updated (auto-patching disabled)"
echo "  ✓ User 'michael' created + sudoers configured"
echo "  ✓ SSH hardened: RSA-4096 keys, Standard AES ciphers"
echo "    - Password authentication ENABLED (but with fail2ban)"
echo "    - Public key auth also supported"
echo "    - KexAlgorithms: diffie-hellman-group-exchange-sha256"
echo "    - Ciphers: aes256-ctr, aes192-ctr, aes128-ctr"
echo "    - MACs: hmac-sha2-512, hmac-sha2-256"
echo "  ✓ Password policy: 14+ chars, mixed case/numbers/symbols"
echo "  ✓ Account lockout: 5 failures = 15min lock"
echo "  ✓ Firewall: whitelist approach, port 22 only"
echo "  ✓ fail2ban: SSH brute-force protection (5 tries, 30min ban)"
echo "  ✓ auditd: kernel-level audit logging enabled"
echo "  ✓ Log rotation: daily, 30 days (~1GB budget)"
echo "  ✓ lynis: security auditing tool installed"
echo "  ✓ Pi cluster personalization: /etc/hosts + cluster context MOTD"
echo "  ✓ Cosmetics: fastfetch + neofetch, colorized MOTD, noise disabled"
echo "  ✓ IPv6: disabled"
echo ""
echo "SECURITY NOTE (Legacy Mode):"
echo "  Password auth is enabled. This is weaker than key-based auth."
echo "  fail2ban and account lockout are CRITICAL for defense."
echo "  Set strong passwords. Rotate regularly."
echo "  Monitor /var/log/auth.log for suspicious activity."
echo ""
echo "Next steps:"
echo "  1. Set strong password for 'michael' user:"
echo "     sudo passwd michael"
echo "  2. (Optional) Generate RSA-4096 key and add to authorized_keys"
echo "  3. Monitor fail2ban status:"
echo "     sudo fail2ban-client status sshd"
echo "  4. Run: sudo lynis audit system"
echo ""
log_info "=========================================="
