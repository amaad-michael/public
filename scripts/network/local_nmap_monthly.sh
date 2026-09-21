#!/bin/bash

# --- Configuration ---
TARGET="192.168.0.0/24"
LOG_DIR="/var/log/netwatch"
DATE=$(date +%Y-%m-%d_%H-%M)
REPORT_FILE="$LOG_DIR/deep_scan_${DATE}.log"

# Dependencies check
command -v nmap >/dev/null 2>&1 || { echo "nmap missing"; exit 1; }

mkdir -p "$LOG_DIR"

# --- Header ---
{
    echo "=================================================="
    echo "MONTHLY DEEP SCAN REPORT: $DATE"
    echo "Target: $TARGET | Scope: All 65,535 Ports | Mode: Version Detection"
    echo "=================================================="
} > "$REPORT_FILE"

# --- The Deep Scan ---
# -T4: Aggressive timing (Critical for full port scans)
# -p-: Scan ALL 65,535 ports (0-65535)
# -sV: Version Detection (Interrogate open ports to identify service versions)
# --open: Only show open ports (Don't list 65,000 "closed" lines)
# -R --system-dns: Resolve hostnames
# -oN: Append normal output to the report file
nmap -T4 -p- -sV --open -R --system-dns -oN - $TARGET >> "$REPORT_FILE" 2>&1

# --- Footer ---
{
    echo ""
    echo "Scan Completed at $(date)"
    echo "=================================================="
} >> "$REPORT_FILE"
