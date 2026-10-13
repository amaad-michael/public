#!/usr/bin/env bash
#
# NAME: ssh-setup-new-box-v1.0.sh
# WHAT: Provisions SSH access from a new controller box to the homelab:
#       installs keychain, generates an ed25519 keypair if missing, loads
#       it into a persistent agent, and copies the public key to pi0-pi4
#       plus neo1 (192.168.0.100-105) as user michael.
# WHY:  One run replaces the manual key and agent setup repeated on every
#       new controller box before ansible can reach the fleet.
# HOW:  ./ssh-setup-new-box-v1.0.sh
#       Idempotent: safe to re-run. Rocky-family (dnf) boxes.
set -euo pipefail

KEY="$HOME/.ssh/id_ed25519"
SSH_USER="michael"
NODES=(192.168.0.100 192.168.0.101 192.168.0.102 192.168.0.103 192.168.0.104 192.168.0.105)

# --- 1. keychain: one ssh-agent reused across logins (no orphan agents) ---
if ! command -v keychain >/dev/null 2>&1; then
    echo "installing keychain..."
    if ! sudo dnf install -y keychain; then
        echo "keychain not in enabled repos, enabling EPEL..."
        sudo dnf install -y epel-release
        sudo dnf install -y keychain
    fi
fi
if ! grep -qF "keychain --eval" "$HOME/.bashrc"; then
    # The eval line must reach .bashrc literally; it expands at shell startup, not now.
    # shellcheck disable=SC2016
    echo 'eval $(keychain --eval --quiet ~/.ssh/id_ed25519)' >> "$HOME/.bashrc"
    echo "added keychain line to ~/.bashrc"
fi

# --- 2. ed25519 keypair (generate only if missing) ---
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t ed25519 -C "michael@homelab" -f "$KEY"
else
    echo "keeping existing $KEY"
fi
chmod 600 "$KEY"

# --- 3. load the key into the agent (passphrase asked once) ---
eval "$(keychain --eval --quiet "$KEY")"

# --- 4. copy the public key to every node ---
for ip in "${NODES[@]}"; do
    echo "--- $ip ---"
    ssh-copy-id -i "$KEY.pub" "$SSH_USER@$ip"
done

echo "done. verify with: ansible pi_all -i ~/git/ansible/hosts -m ping"
