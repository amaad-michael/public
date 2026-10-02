#!/usr/bin/env bash
#
# uptime-report-local.sh — read-only uptime and reboot history report.
#
# Reports:
#   1. Current uptime (uptime)
#   2. Boot time (uptime -s, falling back to who -b)
#   3. Recent reboot history (last reboot, bounded to last 10 entries)
#
# Read-only: changes nothing. Always exits 0.
#
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: uptime-report-local.sh

Report current uptime, boot time, and the last 10 reboot/shutdown entries
from wtmp. Read-only; always exits 0.

Supports RHEL-family and Debian-family distros.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# --- Distro detection (RHEL-family or Debian-family only) ---
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
ID="${ID:-}"
ID_LIKE="${ID_LIKE:-}"
OS_FAM=""
case "$ID" in
    rhel|centos|rocky|alma|fedora|ol) OS_FAM="RedHat" ;;
    debian|ubuntu)                    OS_FAM="Debian" ;;
    *)
        case "$ID_LIKE" in
            *rhel*|*fedora*|*centos*) OS_FAM="RedHat" ;;
            *debian*|*ubuntu*)       OS_FAM="Debian" ;;
        esac
        ;;
esac
if [[ -z "$OS_FAM" ]]; then
    echo "ERROR: unsupported distro (ID='$ID' ID_LIKE='$ID_LIKE'); need RHEL or Debian family." >&2
    exit 1
fi

echo "=== 1. Current uptime ==="
uptime
echo

echo "=== 2. Boot time ==="
if BOOT="$(uptime -s 2>/dev/null)"; then
    echo "$BOOT"
elif command -v who >/dev/null 2>&1 && who -b >/dev/null 2>&1; then
    who -b
else
    echo "(boot time unavailable: uptime -s and who -b both failed)"
fi
echo

echo "=== 3. Recent reboot history (last 10 entries) ==="
if command -v last >/dev/null 2>&1; then
    # 'last reboot' reads /var/log/wtmp; bound output to the last 10 entries.
    REBOOTS="$(last reboot 2>/dev/null | head -10 || true)"
    if [[ -z "$REBOOTS" ]]; then
        echo "(no reboot records found in wtmp)"
    else
        echo "$REBOOTS"
    fi
else
    echo "(NOTE: 'last' is not installed; reboot history unavailable)"
fi
echo

echo "uptime-report complete (read-only, nothing changed)."
exit 0
