#!/bin/bash

# --- Configuration ---
TARGET="192.168.0.0/24"
LOG_DIR="/var/log/netwatch"

# Files
CURRENT_RAW="$LOG_DIR/scan_raw.txt"
CURRENT_CLEAN="$LOG_DIR/scan_clean.txt"
PREV_CLEAN="$LOG_DIR/scan_previous.txt"

HISTORY_LOG="$LOG_DIR/history.log"
CHANGE_LOG="$LOG_DIR/changes.log"

DATE=$(date +%Y-%m-%d_%H-%M)

# Dependencies check (No ndiff needed anymore)
command -v nmap >/dev/null 2>&1 || { echo "nmap missing"; exit 1; }

mkdir -p "$LOG_DIR"

# --- Rotation ---
# We keep the previous 'clean' scan for comparison
if [ -f "$CURRENT_CLEAN" ]; then
    cp "$CURRENT_CLEAN" "$PREV_CLEAN"
fi

# --- Scanning ---
# -oN: Normal text output
nmap -T4 -F --open -R --system-dns -oN "$CURRENT_RAW" $TARGET > /dev/null 2>&1

# --- Sanitization ---
# We must strip variable data (Latency and Timestamps) so diff only catches REAL changes.
# 1. Remove 'Nmap done' (contains time elapsed)
# 2. Remove 'scanned in' lines
# 3. Normalize 'Host is up' (remove latency duration)
grep -vE "Nmap done|scanned in" "$CURRENT_RAW" | \
sed 's/Host is up .*/Host is up./' > "$CURRENT_CLEAN"

# --- Log All Results (History) ---
{
    echo "--------------------------------------------------"
    echo "SCAN TIMESTAMP: $DATE"
    cat "$CURRENT_RAW"
    echo ""
} >> "$HISTORY_LOG"

# --- Highlight Changes (Standard Diff) ---
if [ -f "$PREV_CLEAN" ]; then
    # -U0 means "Unity Diff with 0 context lines" (cleaner output)
    DIFF_OUT=$(diff -U0 "$PREV_CLEAN" "$CURRENT_CLEAN")

    # Check if diff found changes (Exit code 1 means differences found)
    if [ $? -eq 1 ]; then
        {
            echo "========================================="
            echo "CHANGE DETECTED: $DATE"
            # Skip the first 2 lines of diff header (--- and +++)
            echo "$DIFF_OUT" | tail -n +3
            echo "========================================="
        } >> "$CHANGE_LOG"
    fi
fi
