#!/bin/bash

# DNS Testing Suite for Pi-hole/Unbound Infrastructure
# Best-practice implementation using explicit execution strings
# Targets: pihole-backup, unbound-backup

PIHOLE="pihole-backup"
UNBOUND="unbound-backup"

# Store tests as a clean list
TESTS=(
    "$UNBOUND:dig @localhost pi.hole"
    "$UNBOUND:dig @localhost google.com"
    "$PIHOLE:dig @172.20.0.3 google.com"
    "$PIHOLE:dig @172.20.0.3#5335 google.com"
    "$PIHOLE:dig @172.20.0.3 -p 5335 google.com"
    "$PIHOLE:dig @172.20.0.3 -p 5335 dnssec-failed.org +dnssec"
    "$PIHOLE:dig @172.20.0.3 -p 5335 google.com +dnssec"
    "$PIHOLE:dig @localhost doubleclick.net"
)

echo "Executing optimized DNS diagnostic suite..."

for entry in "${TESTS[@]}"; do
    container="${entry%%:*}"
    cmd_string="${entry#*:}"

    echo -e "\n>>> Testing $container: $cmd_string"

    # Use bash -c to safely handle the command string within the container environment
    if ! sudo docker exec "$container" bash -c "$cmd_string"; then
        echo "Error: Command failed on $container"
    fi
done

echo -e "\nDiagnostic run complete."
