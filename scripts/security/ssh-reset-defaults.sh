#!/bin/bash

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
