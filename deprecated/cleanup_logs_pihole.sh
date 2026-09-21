#!/bin/bash
set -euo pipefail

# ---
# Log Cleanup Script
#
# WARNING: This script is DESTRUCTIVE and will permanently erase log history
# from your system. It is designed to leave no historical logs behind,
# as per the request.
#
# Run this script as root or with sudo:
# sudo ./cleanup_logs.sh
# ---

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

echo "Starting log cleanup... This is your last chance to cancel (Ctrl+C)."
sleep 5

echo "--- Clearing Pi-hole Logs ---"

# Securely shred and then remove the main Pi-hole log files
# Using shred to overwrite data first, making recovery difficult.
shred -n 1 -z -u /var/log/pihole/pihole.log*
shred -n 1 -z -u /var/log/pihole/FTL.log*

# Re-create empty files to ensure services can still write to them
touch /var/log/pihole/pihole.log
touch /var/log/pihole/FTL.log

# Set appropriate permissions (adjust if your setup differs)
chown pihole:pihole /var/log/pihole/pihole.log
chown pihole:pihole /var/log/pihole/FTL.log
chmod 644 /var/log/pihole/pihole.log
chmod 644 /var/log/pihole/FTL.log

echo "--- Clearing Unbound Custom Log (if it exists) ---"

# Check if the custom log file exists before trying to shred it
if [ -f /var/log/unbound.log ]; then
  shred -n 1 -z -u /var/log/unbound.log*
  touch /var/log/unbound.log
  # Adjust ownership if unbound runs as a specific user
  # chown unbound:unbound /var/log/unbound.log
  # chmod 640 /var/log/unbound.log
fi

echo "--- Clearing Systemd Journal ---"

# The 'journalctl' logs are the primary log source for many services,
# including unbound (by default) and sshd.

echo "Rotating journal files..."
# Force rotation of journal files
journalctl --rotate

echo "Vacuuming journal files to 1 second (effectively clearing)..."
# Remove all archived journal files, keeping only 1 second of history.
journalctl --vacuum-time=1s

echo "--- Clearing Traditional System Logs ---"

# For traditional syslog files, we can truncate them by redirecting
# /dev/null. This empties the file without deleting it,
# which can break logging services.

# Truncate Authentication Log
: > /var/log/auth.log

# Truncate General System Log
: > /var/log/syslog

# Truncate Firewall Log
: > /var/log/ufw.log

# Securely remove rotated/archived versions of these logs
shred -n 1 -z -u /var/log/auth.log.*
shred -n 1 -z -u /var/log/syslog.*
shred -n 1 -z -u /var/log/ufw.log.*

echo "--- Clearing Bash History ---"
# Also clear the command history for the current user (root)
: > ~/.bash_history
rm -f ~/.bash_history
ln -s /dev/null ~/.bash_history

echo "Log cleanup complete."
echo "WARNING: Services may need to be restarted to resume logging correctly."
echo "You may also want to log out and log back in to clear session history."
