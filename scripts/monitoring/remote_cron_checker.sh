#!/bin/bash
## Michael Tatum; REMOTE CRONJOB CHECKER

# Configurable log directory
LOG_DIR="/var/log/cron_audit"
mkdir -p "$LOG_DIR"

# Output log file
LOG_FILE="$LOG_DIR/cronjobs_full_$(date +%Y%m%d_%H%M%S).log"

# List of servers
## SERVERS=("server1.example.com" "server2.example.com")
SERVERS=("192.168.0.101" "192.168.0.103")

# Start logging
echo "Collecting all cron jobs from remote servers..." > "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

# Loop through each server
for SERVER in "${SERVERS[@]}"; do
    echo "Fetching cron jobs from $SERVER..." | tee -a "$LOG_FILE"

    # Check SSH connectivity
    if ! ssh -o ConnectTimeout=10 "$SERVER" "echo OK" &>/dev/null; then
        echo "ERROR: Unable to connect to $SERVER" | tee -a "$LOG_FILE"
        continue
    fi

    {
        echo "========== $SERVER =========="
        echo "Timestamp: $(date)"
        echo ""

        echo "--- User Crontabs ---"
        ssh "$SERVER" 'getent passwd | awk -F: '\''$3 >= 1000 {print $1}'\'' | while read user; do
            echo "User: $user"
            crontab -u "$user" -l 2>/dev/null || echo "No crontab for $user"
            echo ""
        done'

        echo "--- /etc/crontab ---"
        ssh "$SERVER" 'cat /etc/crontab 2>/dev/null || echo "No /etc/crontab found"'

        echo "--- /etc/cron.d/ ---"
        ssh "$SERVER" 'for file in /etc/cron.d/*; do
            [ -f "$file" ] && {
                echo "File: $file"
                cat "$file"
                echo ""
            }
        done'

        echo "--- /etc/cron.* directories ---"
        for dir in hourly daily weekly monthly; do
            echo "/etc/cron.$dir:"
            # shellcheck disable=SC2029 # $dir is a loop variable: client-side expansion is intentional
            ssh "$SERVER" "ls -l /etc/cron.$dir 2>/dev/null || echo 'Directory not found'"
            echo ""
        done

        echo ""
    } >> "$LOG_FILE"
done

echo "Cron job collection complete. Log saved to $LOG_FILE"
