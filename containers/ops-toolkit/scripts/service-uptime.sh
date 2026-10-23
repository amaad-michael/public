#!/usr/bin/env bash
#
# NAME: service-uptime.sh
# WHAT: Checks that every service in the services list is running (systemctl,
#       falling back to the `service` command) and dumps recent high-priority
#       journal entries to ${LOG_DIR}/service-issues-week.txt.
# WHY:  Quick "is everything up" probe for cron — exits 1 if any listed
#       service is down, so a monitor can alert on it.
# HOW:  ./service-uptime.sh
#       Services file: /etc/ops/services.txt (override: SERVICES_FILE in
#       /etc/ops/ops.conf). One service name per line; '#' starts a comment;
#       blank lines ignored. Example:
#         sshd
#         pihole-FTL   # Pi-hole DNS
#         cron
#
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

TS=$(date -Iseconds)
RET=0

if [ ! -f "$SERVICES_FILE" ]; then
  echo "$TS ERROR: services file not found: $SERVICES_FILE" >&2
  exit 2
fi

if command -v systemctl >/dev/null 2>&1; then
  while IFS= read -r LINE; do
    SVC=$(echo "$LINE" | sed 's/[#].*$//' | xargs)
    [ -z "$SVC" ] && continue
    if ! systemctl is-active --quiet "$SVC"; then
      echo "$TS DOWN: $SVC"
      RET=1
    fi
  done < "$SERVICES_FILE"
else
  # Fallback to service command
  while IFS= read -r LINE; do
    SVC=$(echo "$LINE" | sed 's/[#].*$//' | xargs)
    [ -z "$SVC" ] && continue
    if ! service "$SVC" status >/dev/null 2>&1; then
      echo "$TS DOWN: $SVC"
      RET=1
    fi
  done < "$SERVICES_FILE"
fi

# High-priority logs from the last N days
journalctl -p "$JOURNAL_PRIORITY" --since "${JOURNAL_SINCE_DAYS} days ago" > "${LOG_DIR}/service-issues-week.txt" 2>/dev/null || true

exit $RET
