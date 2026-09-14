#!/bin/bash
## Michael Tatum; LOCAL CRONJOB CHECKER

# Configurable log directory
LOG_DIR="/var/log/cron_audit"
mkdir -p "$LOG_DIR"

# Output log file with timestamp
LOG_FILE="$LOG_DIR/local_cronjobs_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Start logging
{
    echo "Collecting all local cron jobs..."
    echo "Timestamp: $(date)"
    echo "Hostname: $(hostname)"
    echo "================================="
} > "$LOG_FILE"

# Filtered user crontabs (UID >= 1000 and valid shell)
echo "--- User Crontabs ---" >> "$LOG_FILE"
getent passwd | awk -F: '$3 >= 1000 && $7 ~ /bash|sh/ {print $1}' | while read -r user; do
    echo "User: $user" >> "$LOG_FILE"
    crontab -u "$user" -l 2>/dev/null || echo "No crontab for $user" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
done

# System-wide crontab
echo "--- /etc/crontab ---" >> "$LOG_FILE"
cat /etc/crontab 2>/dev/null || echo "No /etc/crontab found" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# /etc/cron.d/
echo "--- /etc/cron.d/ ---" >> "$LOG_FILE"
for file in /etc/cron.d/*; do
    [ -f "$file" ] && {
        echo "File: $file"
        cat "$file"
        echo ""
    } >> "$LOG_FILE"
done

# /etc/cron.{hourly,daily,weekly,monthly}
for dir in hourly daily weekly monthly; do
    echo "--- /etc/cron.$dir/ ---" >> "$LOG_FILE"
    ls -l "/etc/cron.$dir" 2>/dev/null || echo "/etc/cron.$dir not found" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
done

echo "Cron job collection complete. Log saved to $LOG_FILE"
