#!/bin/bash
set -e

# ==============================================================================
# SCRIPT: export_ssh.sh
# PURPOSE: Securely export SSH host identity and user access keys.
# COMPATIBILITY: RHEL Family (distro-like) and Debian/Ubuntu Family.
# ==============================================================================

# 1. Configuration & Naming
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME_S=$(hostname -s)
EXPORT_ID="ssh-backup-${HOSTNAME_S}-${TIMESTAMP}"
BACKUP_DIR="/tmp/${EXPORT_ID}"
OUTPUT_FILE="${EXPORT_ID}.tar.gz"
CHECKSUM_FILE="${OUTPUT_FILE}.sha256"

# 2. Root Privilege Check
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script requires root privileges to read /etc/ssh/ private keys."
   exit 1
fi

# 3. Environment Detection
# shellcheck disable=SC1091 # /etc/os-release is a system file, absent at lint time
[ -f /etc/os-release ] && . /etc/os-release
DISTRO_NAME=${PRETTY_NAME:-"Unknown Linux"}

echo "--- Starting SSH Export: ${HOSTNAME_S} ---"
echo "--- Source OS: ${DISTRO_NAME} ---"

# 4. Workspace Setup
mkdir -p "$BACKUP_DIR/host_keys"
mkdir -p "$BACKUP_DIR/user_keys"
chmod 700 "$BACKUP_DIR"

# 5. Generate Identity Metadata
{
    echo "Source_Hostname: $(hostname -f)"
    echo "Export_Date:     $(date)"
    echo "OS_Version:      $DISTRO_NAME"
    echo "SSH_Version:     $(ssh -V 2>&1)"
} > "$BACKUP_DIR/SOURCE_IDENTITY.txt"

# 6. Export Host Identity (The Server's "Fingerprint")
echo "[1/5] Extracting host keys..."
cp /etc/ssh/ssh_host_* "$BACKUP_DIR/host_keys/"
cp /etc/ssh/sshd_config "$BACKUP_DIR/host_keys/"

# 7. Export User Access (Authorized Keys Only)
echo "[2/5] Extracting authorized_keys..."
shopt -s nullglob
for user_ssh in /root/.ssh /home/*/.ssh; do
    if [ -f "$user_ssh/authorized_keys" ]; then
        if [[ "$user_ssh" == "/root/.ssh" ]]; then
            username="root"
        else
            username=$(basename "$(dirname "$user_ssh")")
        fi
        mkdir -p "$BACKUP_DIR/user_keys/$username"
        cp "$user_ssh/authorized_keys" "$BACKUP_DIR/user_keys/$username/"
    fi
done
shopt -u nullglob

# 8. RHEL-specific Logic (SELinux)
if [[ "$ID_LIKE" == *"rhel"* || "$ID" == "fedora" || "$ID" == "centos" ]]; then
    echo "[INFO] RHEL-family detected. Logging SELinux contexts..."
    ls -Z /etc/ssh/ssh_host_* > "$BACKUP_DIR/selinux_contexts.txt" 2>/dev/null || true
fi

# 9. Archive & Secure
echo "[3/5] Creating secure tarball..."
tar -czf "$OUTPUT_FILE" -C /tmp "$EXPORT_ID"
chmod 600 "$OUTPUT_FILE"

# 10. Integrity Verification
echo "[4/5] Verifying archive integrity..."
tar -tzf "$OUTPUT_FILE" > /dev/null

# 11. Checksum Generation
echo "[5/5] Generating SHA256 checksum..."
sha256sum "$OUTPUT_FILE" > "$CHECKSUM_FILE"

# Cleanup
rm -rf "$BACKUP_DIR"

echo "------------------------------------------------"
echo "SUCCESS: Export stored in $(pwd)/$OUTPUT_FILE"
echo "CHECKSUM: $(cat "$CHECKSUM_FILE")"
echo "------------------------------------------------"
