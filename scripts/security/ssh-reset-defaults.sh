#!/bin/bash
#
# NAME: ssh-reset-defaults.sh
# WHAT: Restores this machine's SSH configuration to distro defaults:
#       - /etc/ssh/sshd_config, /etc/ssh/ssh_config, /etc/ssh/moduli
#         are overwritten from /usr/share/openssh/sshd_config
#       - host key pairs (rsa/ecdsa/ed25519) are regenerated if missing
#       - /etc/ssh/ssh_known_hosts and /root/.ssh/authorized_keys are EMPTIED
#       - sshd is restarted
# WHY:  Last-resort recovery when SSH config is mangled beyond repair and you
#       want a known-good baseline to re-harden from.
# HOW:  sudo ./ssh-reset-defaults.sh   (must run as root)
#
# *** WARNING — DESTRUCTIVE ***
# This script WIPES your current SSH hardening: custom sshd_config settings,
# existing host keys (clients will see key-change warnings), the system-wide
# known_hosts, and root's authorized_keys (you WILL be locked out of key-based
# root login until you re-add keys). Originals are copied to /root/ssh_backup/
# before anything is touched — verify that backup exists before proceeding.
# Run only on the local console or via an out-of-band method, never over the
# same SSH session you are about to restart.

# Set strict mode
set -euo pipefail

# Define default SSH config files
DEFAULT_SSH_CONFIG_FILES=(
  "/etc/ssh/sshd_config"
  "/etc/ssh/ssh_config"
  "/etc/ssh/moduli"
)

# Define default SSH key files (private keys only)
DEFAULT_SSH_KEY_FILES=(
  "/etc/ssh/ssh_host_rsa_key"
  "/etc/ssh/ssh_host_ecdsa_key"
  "/etc/ssh/ssh_host_ed25519_key"
)

# Define known hosts and authorized keys files
KNOWN_HOSTS_FILE="/etc/ssh/ssh_known_hosts"
AUTHORIZED_KEYS_FILE="/root/.ssh/authorized_keys"

# Backup existing SSH files
BACKUP_DIR="/root/ssh_backup"
mkdir -p "$BACKUP_DIR"

for file in "${DEFAULT_SSH_CONFIG_FILES[@]}" "${DEFAULT_SSH_KEY_FILES[@]/%_key}"; do
  if [ -f "$file" ] || [ -f "$file.pub" ]; then
    echo "Backing up SSH file: $file"
    cp -p "$file" "$BACKUP_DIR/"
    if [ -f "$file.pub" ]; then
        cp -p "$file.pub" "$BACKUP_DIR/"
    fi
  fi
done

# Backup known hosts and authorized keys files
if [ -f "$KNOWN_HOSTS_FILE" ]; then
  echo "Backing up known hosts file: $KNOWN_HOSTS_FILE"
  cp -p "$KNOWN_HOSTS_FILE" "$BACKUP_DIR/"
fi
if [ -f "$AUTHORIZED_KEYS_FILE" ]; then
  echo "Backing up authorized keys file: $AUTHORIZED_KEYS_FILE"
  cp -p "$AUTHORIZED_KEYS_FILE" "$BACKUP_DIR/"
fi

# Restore default SSH config files
for file in "${DEFAULT_SSH_CONFIG_FILES[@]}"; do
  if [ -f "$file" ]; then
    echo "Restoring default SSH config file: $file"
    cp -f "/usr/share/openssh/sshd_config" "$file"
  fi
done

# Regenerate SSH key pairs
for key in "${DEFAULT_SSH_KEY_FILES[@]}"; do
  if [ ! -f "$key" ]; then
    echo "Generating new SSH key pair: $key"
    ssh-keygen -q -N "" -t "${key##*_}" -f "$key"
  fi
done

# Clear known hosts and authorized keys files
echo "Clearing known hosts file: $KNOWN_HOSTS_FILE"
truncate -s 0 "$KNOWN_HOSTS_FILE"

echo "Clearing authorized keys file: $AUTHORIZED_KEYS_FILE"
truncate -s 0 "$AUTHORIZED_KEYS_FILE"

# Restart SSH service
echo "Restarting SSH service..."
systemctl restart sshd

echo "SSH configuration has been restored to its default state."
