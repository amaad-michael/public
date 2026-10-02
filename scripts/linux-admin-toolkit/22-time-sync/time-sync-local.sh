#!/usr/bin/env bash
#
# time-sync-local.sh — time synchronization health check (default: READ-ONLY).
#
#   Default: report sync health via chronyc tracking (chrony),
#            timedatectl show-timesync (systemd-timesyncd), or ntpq -p.
#   --fix:   enable and start the appropriate time service (idempotent).
#   --check: dry-run for --fix — print what would be done, change nothing.
#
# If no time service tooling exists, prints per-distro install instructions.

set -euo pipefail

FIX=0
DRYRUN=0

usage() {
    cat <<'EOF'
Usage: time-sync-local.sh [--fix] [--check] [--help]

  Default (no flags): READ-ONLY time sync health check. Reports sync status
  via `chronyc tracking` (chrony), `timedatectl show-timesync`
  (systemd-timesyncd), or `ntpq -p` (ntp), whichever backend is present.
  If none is present, prints per-distro install instructions.

Options:
  --fix    Enable and start the appropriate time service (chrony preferred
           when installed, else systemd-timesyncd). Idempotent: already
           enabled/running services are left alone. Requires root.
  --check  Dry-run for --fix: print the actions that would be taken,
           change nothing.
  -h, --help  Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix) FIX=1; shift ;;
        --check) DRYRUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# --- distro detection (portable RHEL-family / Debian-family) ---
FAM=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian|linuxmint|pop|raspbian|kali) FAM="debian" ;;
        rhel|centos|rocky|almalinux|fedora|ol)     FAM="redhat" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*) FAM="debian" ;;
                *rhel*|*fedora*) FAM="redhat" ;;
            esac ;;
    esac
fi
[[ -n "$FAM" ]] || { echo "ERROR: unsupported distro (ID='${ID:-?}', ID_LIKE='${ID_LIKE:-?}'); expected a RHEL- or Debian-family system" >&2; exit 2; }

install_instructions() {
    echo "No time-sync tooling found on this host. Install chrony:"
    if [[ "$FAM" == "debian" ]]; then
        echo "  sudo apt-get update && sudo apt-get install -y chrony"
    else
        echo "  sudo dnf install -y chrony   # or: sudo yum install -y chrony"
    fi
}

# --- backend detection ---
# chrony preferred when its client exists, else systemd-timesyncd (when
# systemd is actually running), else classic ntp.
BACKEND="none"
if command -v chronyc >/dev/null 2>&1; then
    BACKEND="chrony"
elif command -v timedatectl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    BACKEND="timesyncd"
elif command -v ntpq >/dev/null 2>&1; then
    BACKEND="ntp"
fi

service_name() {
    case "$BACKEND" in
        chrony)    [[ "$FAM" == "redhat" ]] && echo "chronyd" || echo "chrony" ;;
        timesyncd) echo "systemd-timesyncd" ;;
        ntp)      [[ "$FAM" == "redhat" ]] && echo "ntpd"    || echo "ntp" ;;
        *)        echo "" ;;
    esac
}

run_check() {
    echo "== time sync health (backend: ${BACKEND}) =="
    case "$BACKEND" in
        chrony)
            if chronyc tracking 2>/dev/null; then
                echo
                chronyc sources 2>/dev/null || true
            else
                echo "chronyc is installed but the chrony daemon is not responding."
                echo "Run with --fix (as root) to enable and start it."
                return 1
            fi
            ;;
        timesyncd)
            ERR="$(timedatectl show-timesync --all 2>&1)" && { echo "$ERR"; return 0; }
            ERR="$(timedatectl status 2>&1)" && { echo "$ERR"; return 0; }
            echo "timedatectl is not responding (is systemd/D-Bus running on this host?)."
            echo "Last error: $ERR"
            return 1
            ;;
        ntp)
            ntpq -pn 2>/dev/null || { echo "ntpq is installed but ntpd is not responding."; return 1; }
            ;;
        none)
            install_instructions
            return 1
            ;;
    esac
}

if [[ "$FIX" -eq 0 ]]; then
    # Default: read-only check. Changes nothing.
    run_check
    exit $?
fi

# --- --fix path ---
SVC="$(service_name)"
if [[ -z "$SVC" ]]; then
    install_instructions
    exit 2
fi

if [[ "$DRYRUN" -eq 1 ]]; then
    echo "DRY-RUN (--check): no changes made. --fix would execute:"
    echo "  systemctl is-enabled --quiet ${SVC} || systemctl enable ${SVC}"
    echo "  systemctl is-active  --quiet ${SVC} || systemctl start  ${SVC}"
    echo "(then re-run the sync health check)"
    exit 0
fi

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "ERROR: --fix requires root (re-run with sudo)" >&2; exit 2; }
command -v systemctl >/dev/null 2>&1 || { echo "ERROR: systemctl not found; cannot manage ${SVC}" >&2; exit 2; }

# Idempotent: only enable/start when not already enabled/active.
if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
    echo "${SVC} is already enabled."
else
    echo "Enabling ${SVC}..."
    systemctl enable "$SVC"
fi
if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    echo "${SVC} is already running."
else
    echo "Starting ${SVC}..."
    systemctl start "$SVC"
fi

echo
echo "== post-fix health check =="
run_check
