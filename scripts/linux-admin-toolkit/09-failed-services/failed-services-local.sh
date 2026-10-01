#!/usr/bin/env bash
#
# failed-services-local.sh — read-only report of failed systemd units.
#
# If systemd is PID 1 and systemctl is available, lists failed units
# (`systemctl --failed`). Otherwise prints a clear note and falls back to
# a trivial pgrep check of a few common daemons.
#
# Read-only: changes nothing. Always exits 0.
#
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: failed-services-local.sh

List failed systemd units. If systemd is not PID 1 (or systemctl is
unavailable), prints a note and falls back to a trivial check of a few
common daemons. Read-only; always exits 0.

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

# --- Is systemd actually running as PID 1? ---
PID1="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
HAS_SYSTEMD=0
if [[ "$PID1" == "systemd" && -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    HAS_SYSTEMD=1
fi

if [[ "$HAS_SYSTEMD" -eq 1 ]]; then
    echo "=== Failed systemd units (systemctl --failed) ==="
    FAILED="$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)"
    if [[ -z "$FAILED" ]]; then
        echo "No failed units."
    else
        echo "$FAILED"
    fi
    echo
    echo "failed-services check complete (read-only, nothing changed)."
    exit 0
fi

# --- Graceful degradation: no systemd as PID 1 ---
echo "NOTE: systemd is not running as PID 1 (PID 1 is '${PID1}'; systemctl $(command -v systemctl >/dev/null 2>&1 && echo available || echo unavailable))."
echo "Cannot query failed units without systemd; falling back to a trivial"
echo "check of a few common daemons instead."
echo
if ! command -v pgrep >/dev/null 2>&1; then
    echo "NOTE: pgrep is not available, so even the trivial fallback cannot run."
    echo "failed-services check complete (read-only, nothing changed)."
    exit 0
fi
echo "=== Trivial daemon check (pgrep) ==="
for svc in sshd cron crond systemd-journald dbus-daemon; do
    if pgrep -x "$svc" >/dev/null 2>&1; then
        echo "  ${svc}: running"
    else
        echo "  ${svc}: not running"
    fi
done
echo
echo "failed-services check complete (read-only, nothing changed)."
exit 0
