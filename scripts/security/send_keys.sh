#!/bin/bash

# Define the list of IP addresses
declare -a IPs=(
    "192.168.0.100"  # pi0
    "192.168.0.101"  # pi1
    "192.168.0.102"  # pi2
    "192.168.0.103"  # pi3
    "192.168.0.104"  # pi4
    "192.168.0.105"  # neo1
)

# Path to your SSH public key file
PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub

# Check if the public key file exists
if [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Error: Public key file ($PUBLIC_KEY_FILE) not found!"
    exit 1
fi

# Loop through each IP and copy the public key using ssh-copy-id
for ip in "${IPs[@]}"; do
    echo "Copying SSH key to $ip..."
    if ssh-copy-id -i "$PUBLIC_KEY_FILE" michael@"$ip" 2>/dev/null; then
        echo "SSH key successfully copied to $ip."
    else
        echo "Failed to copy SSH key to $ip. Check connectivity or permissions."
    fi
done

echo "All done!"
