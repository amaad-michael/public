#!/bin/bash
#
# NAME: setup_key_access.sh
# WHAT: Installs this machine's SSH public key into a single remote host's
#       authorized_keys (creating ~/.ssh with correct perms if needed).
# WHY:  One-off version of send_keys.sh for a host outside the homelab fleet
#       — e.g. a new VPS or a rebuilt box — where you don't want to loop the
#       whole IP list.
# HOW:  ./setup_key_access.sh <remote_ip>
#       Logs in as 'michael'; idempotent-ish (re-running appends a duplicate
#       key line, harmless but untidy).

# Variables
USER="michael"
PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub
REMOTE_IP=$1

if [ -z "$REMOTE_IP" ]; then
    echo "Usage: $0 <remote_ip>"
    exit 1
fi

# Ensure the public key exists
if [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Error: Public key file ($PUBLIC_KEY_FILE) not found!"
    exit 1
fi

# Read the public key
PUBLIC_KEY_CONTENT=$(cat "$PUBLIC_KEY_FILE")

# Execute commands on the remote server
# shellcheck disable=SC2087 # expansions intentionally happen client-side: key material is injected into the remote command
ssh "$USER@$REMOTE_IP" bash -s <<EOF
    # Create the .ssh directory if it doesn't exist
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Add the public key to authorized_keys
    echo "$PUBLIC_KEY_CONTENT" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

    # Ensure ownership is correct
    chown -R $USER:$USER ~/.ssh
    echo "Key added and permissions set for $USER on $REMOTE_IP."
EOF
