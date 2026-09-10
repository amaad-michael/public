#!/bin/bash

# A script to scan the fixed 192.168.1.0/24 subnet for hosts and open ports.

# 1. Check if nmap is installed
if ! command -v nmap &> /dev/null; then
    echo "Error: nmap is not installed."
    echo "Please install it to continue (e.g., 'sudo apt install nmap' or 'sudo dnf install nmap')."
    exit 1
fi

# 2. Define the target subnet
SUBNET="192.168.0.0/24"

# 3. Run the scan
echo "🔍 Scanning fixed subnet: $SUBNET"
echo "This may take a moment..."
echo "----------------------------------------"

#   -F:  Fast mode (scans the 100 most common ports)
#   -T4: Aggressive timing (for faster execution on a local network)
nmap -F -T4 "$SUBNET"
