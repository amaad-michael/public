#!/usr/bin/env bash
#
# disk-audit-local.sh — read-only disk usage audit.
#
# Reports:
#   1. Filesystem usage (df -h) with WARN flag at --warn % (default 80)
#   2. Inode usage (df -i) with WARN flag at --warn % (default 80)
#   3. Largest directories up to --depth (default 2) under /,
#      excluding /proc, /sys, /dev (bounded du scan)
#   4. Top 20 largest files on the root filesystem
#
# Read-only: changes nothing. Exit 0 on success.
#
set -euo pipefail

WARN=80
DEPTH=2

usage() {
    cat <<'EOF'
Usage: disk-audit-local.sh [--warn PCT] [--depth N]

  --warn PCT   Flag filesystems/inodes at or above PCT percent full (default 80)
  --depth N    du scan depth under / for largest directories (default 2)
  -h, --help   Show this help

Read-only disk audit. Supports RHEL-family and Debian-family distros.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn)  WARN="${2:?--warn requires a value}"; shift 2 ;;
        --depth) DEPTH="${2:?--depth requires a value}"; shift 2 ;;
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

# --- Optional bounded-run helper ---
if command -v timeout >/dev/null 2>&1; then
    BOUND="timeout 180"
else
    BOUND=""
fi

humanize() {
    # Humanize the first whitespace-separated field (bytes) if numfmt exists.
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B --field=1
    else
        cat
    fi
}

flag_pct() {
    # stdin: df output; flags rows whose Use% column >= $1.
    local warn="$1"
    awk -v warn="$warn" '
        NR==1 { print; next }
        { line=$0; gsub(/%/,"",$5)
          printf "%s%s\n", line, (($5+0) >= warn ? "  <-- WARN (>= " warn "%)" : "") }'
}

echo "=== 1. Filesystem usage (df -h) — WARN at >= ${WARN}% ==="
df -h | flag_pct "$WARN"
echo

echo "=== 2. Inode usage (df -i) — WARN at >= ${WARN}% ==="
df -i | flag_pct "$WARN"
echo

echo "=== 3. Largest directories (depth <= ${DEPTH} under /, excl. /proc /sys /dev) ==="
# -x: stay on the root filesystem (skips /proc, /sys, /dev even without excludes).
# timeout keeps the scan bounded; '|| true' tolerates the timeout under pipefail.
{ ${BOUND} du -x -d "$DEPTH" / --exclude=/proc --exclude=/sys --exclude=/dev 2>/dev/null || true; } \
    | sort -rn | head -25 | humanize || true
echo

echo "=== 4. Top 20 largest files (root filesystem) ==="
{ ${BOUND} find / -xdev -type f -printf '%s\t%p\n' 2>/dev/null || true; } \
    | sort -rn | head -20 | humanize || true
echo

echo "disk-audit complete (read-only, nothing changed)."
exit 0
