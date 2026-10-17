#!/bin/bash
#
# NAME: add_known_hosts.sh
# WHAT: Populates ~/.ssh/known_hosts with ssh-keyscan results for every
#       homelab host, so first-time SSH connections don't stop on the
#       "are you sure you want to continue connecting" prompt.
# WHY:  Run once on a fresh workstation (or after rebuilding a host, when its
#       key changes) to pre-trust the fleet. Companion to send_keys.sh, which
#       handles the authorized_keys side.
# HOW:  ./add_known_hosts.sh
#       Appends to ~/.ssh/known_hosts; re-running may duplicate entries —
#       clean the file first if a host was rebuilt.
#
# Define the list of IP addresses
# Current fleet (2026-10): pi0-pi4 + neo1 on 192.168.0.100-105.
# The old 192.168.4.x entries were Michael's prior apartment; nanopi0/1/2 were
# replaced by neo1 (Armbian NanoPi, observability node).
declare -a IPs=(
    "192.168.0.100"  # pi0
    "192.168.0.101"  # pi1
    "192.168.0.102"  # pi2
    "192.168.0.103"  # pi3
    "192.168.0.104"  # pi4
    "192.168.0.105"  # neo1
)

# File to store known hosts
KNOWN_HOSTS_FILE=~/.ssh/known_hosts

# Loop through each IP and perform ssh-keyscan
for ip in "${IPs[@]}"; do
    echo "Adding $ip to known hosts..."
    if ssh-keyscan -H "$ip" >> "$KNOWN_HOSTS_FILE" 2>/dev/null; then
        echo "$ip added successfully."
    else
        echo "Failed to add $ip. Check connectivity or permissions."
    fi
done

echo "All done!"
