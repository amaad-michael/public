#!/usr/bin/env bash
#
# health-check-local.sh — read-only system health report.
#
# Reports:
#   1. CPU: core count (nproc) and load averages 1/5/15 vs core count
#   2. Memory: free -m plus % used (of total-available)
#   3. Swap: usage % (or "none configured")
#
# Each metric gets OK / WARN / CRIT against --warn (default 80) and
# --crit (default 90) percent thresholds.
#
# Read-only: changes nothing. Always exits 0 (report, don't alarm).
#
set -euo pipefail

WARN=80
CRIT=90

usage() {
    cat <<'EOF'
Usage: health-check-local.sh [--warn PCT] [--crit PCT]

  --warn PCT   WARN threshold in percent (default 80)
  --crit PCT   CRIT threshold in percent (default 90)
  -h, --help   Show this help

Read-only health report. Supports RHEL-family and Debian-family distros.
Always exits 0.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn) WARN="${2:?--warn requires a value}"; shift 2 ;;
        --crit) CRIT="${2:?--crit requires a value}"; shift 2 ;;
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

# Classify a percent value against warn/crit thresholds.
classify() {
    local pct="$1" warn="$2" crit="$3"
    awk -v p="$pct" -v w="$warn" -v c="$crit" 'BEGIN {
        if (p >= c) print "CRIT";
        else if (p >= w) print "WARN";
        else print "OK";
    }'
}

echo "=== 1. CPU ==="
CORES="$(nproc)"
# shellcheck disable=SC2034
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
echo "Cores: ${CORES}"
echo "Load averages (1/5/15 min): ${LOAD1} ${LOAD5} ${LOAD15}"
for pair in "1-min:${LOAD1}" "5-min:${LOAD5}" "15-min:${LOAD15}"; do
    label="${pair%%:*}"; load="${pair##*:}"
    pct="$(awk -v l="$load" -v c="$CORES" 'BEGIN { printf "%.1f", (c>0 ? l/c*100 : 0) }')"
    echo "  load ${label}: ${load} (${pct}% of ${CORES} cores) -> $(classify "$pct" "$WARN" "$CRIT")"
done
echo

echo "=== 2. Memory ==="
free -m
# % used computed from available (excludes reclaimable buffers/cache).
MEM_TOTAL="$(free -m | awk '/^Mem:/ {print $2}')"
MEM_AVAIL="$(free -m | awk '/^Mem:/ {print $7}')"
MEM_PCT="$(awk -v t="$MEM_TOTAL" -v a="$MEM_AVAIL" 'BEGIN { printf "%.1f", (t>0 ? (t-a)/t*100 : 0) }')"
echo "Memory used: ${MEM_PCT}% of ${MEM_TOTAL} MiB -> $(classify "$MEM_PCT" "$WARN" "$CRIT")"
echo

echo "=== 3. Swap ==="
SWAP_TOTAL="$(free -m | awk '/^Swap:/ {print $2}')"
SWAP_USED="$(free -m | awk '/^Swap:/ {print $3}')"
if [[ "${SWAP_TOTAL:-0}" -eq 0 ]]; then
    echo "No swap configured -> OK"
else
    SWAP_PCT="$(awk -v u="$SWAP_USED" -v t="$SWAP_TOTAL" 'BEGIN { printf "%.1f", (t>0 ? u/t*100 : 0) }')"
    echo "Swap used: ${SWAP_USED} of ${SWAP_TOTAL} MiB (${SWAP_PCT}%) -> $(classify "$SWAP_PCT" "$WARN" "$CRIT")"
fi
echo

echo "health-check complete (read-only, nothing changed)."
exit 0
