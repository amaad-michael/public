#!/bin/bash

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
