#!/bin/bash
# Pi-hole blocklist initialization script
# Runs automatically on first container startup via docker-compose
# Idempotent - safe to re-run (uses INSERT OR IGNORE)

set -euo pipefail

PIHOLE_DB="/etc/pihole/gravity.db"

# Wait for Pi-hole to be ready
max_attempts=30
attempt=1
while [ ! -f "$PIHOLE_DB" ]; do
    if [ $attempt -ge $max_attempts ]; then
        echo "ERROR: gravity.db not found after $max_attempts attempts"
        exit 1
    fi
    echo "Waiting for Pi-hole database... (attempt $attempt/$max_attempts)"
    sleep 2
    ((attempt++))
done

echo "Pi-hole database found. Adding blocklists..."
echo ""

# Array of blocklists: URL|Name
BLOCKLISTS=(
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.mini.txt|Hagezi Pro Mini"
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.mini.txt|Hagezi TIF Mini"
    "https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/multi.txt|Hagezi Multi Normal"
    "https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/adblock/tif.medium.txt|Hagezi TIF Medium"
    "https://big.oisd.nl|OISD Big"
)

# Add each blocklist to gravity database
for blocklist in "${BLOCKLISTS[@]}"; do
    URL="${blocklist%|*}"
    NAME="${blocklist#*|}"

    # INSERT OR IGNORE - safely re-runnable
    if sqlite3 "$PIHOLE_DB" \
        "INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES ('$URL', 1, '$NAME');"; then
        echo "✓ Added: $NAME"
    else
        echo "✗ Failed: $NAME"
    fi
done

echo ""
echo "Blocklists initialization complete."
echo ""

# Trigger gravity update (force reload of blocklists)
echo "Updating gravity database..."
if /usr/local/bin/pihole -g > /dev/null 2>&1; then
    echo "✓ Gravity updated successfully"
else
    echo "⚠ Gravity update returned non-zero, but blocklists should be added"
fi

echo ""
echo "Blocklist counts:"
sqlite3 "$PIHOLE_DB" "SELECT COUNT(*) as total_adlists FROM adlist;"
sqlite3 "$PIHOLE_DB" "SELECT COUNT(*) as total_domains FROM gravity;" 2>/dev/null || echo "Gravity domains: (calculating...)"

exit 0
