#!/bin/bash
set -euo pipefail

# Usage: ./nmap-vuln-scan.sh targets.txt
# OR:    ./nmap-vuln-scan.sh 192.168.1.1
#
# Runs an nmap service/version scan with the built-in "vuln" NSE
# script category against a single host or every target listed in a
# file (one per line), writing one report per target into a
# timestamped results directory.

# Check if Nmap is installed
if ! command -v nmap &>/dev/null; then
  echo "Nmap is not installed. Please install it and try again."
  exit 1
fi

# Check for input
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <IP or file with IPs>"
  exit 1
fi

# Make a timestamped results directory
RESULTS_DIR="nmap_vuln_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# Read IPs or file
if [[ -f "$1" ]]; then
  mapfile -t TARGETS < "$1"
else
  TARGETS=("$1")
fi

echo "Starting vulnerability scan on targets..."
for IP in "${TARGETS[@]}"; do
  if [ -z "$IP" ]; then
    continue
  fi
  echo "Scanning $IP..."
  OUTPUT_FILE="${RESULTS_DIR}/${IP}_vuln_scan.txt"

  nmap -sV --script vuln -T4 -oN "$OUTPUT_FILE" "$IP"

  echo "Scan for $IP complete. Results saved to $OUTPUT_FILE"
done

echo "All scans complete. Results stored in $RESULTS_DIR"
