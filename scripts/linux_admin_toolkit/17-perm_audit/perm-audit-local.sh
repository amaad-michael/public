#!/usr/bin/env bash
# perm-audit — find world-writable files and SUID/SGID binaries outside an allowlist.
# Read-only. Usage: perm-audit-local.sh [--top N] [--help]
set -euo pipefail

TOP=50

usage() {
  cat <<'EOF'
perm-audit-local.sh — Audit risky file permissions (report only).

Usage: perm-audit-local.sh [--top N]

Options:
  --top N   Show at most N world-writable files (default 50); full count
            is always reported.
  --help    Show this help.

Exit status: 1 if any findings were reported, 0 if the audit is clean.

Finds world-writable regular files under / (pruning /proc, /sys, /dev)
and SUID/SGID binaries, flagging SUID/SGID binaries outside a
standard-path allowlist (/usr/bin, /usr/sbin, /bin, /sbin, /usr/libexec
and distro equivalents). Report-only; never changes anything.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --top) TOP="${2:?--top needs a number}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$TOP" in *[!0-9]*) echo "ERROR: --top must be an integer" >&2; exit 2 ;; esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  echo "ERROR: cannot detect distro (/etc/os-release missing)" >&2; exit 2
fi
case "${ID_LIKE:-$ID} ${ID}" in
  *rhel*|*fedora*|*centos*) FAMILY=redhat ;;
  *debian*|*ubuntu*)        FAMILY=debian ;;
  *) echo "ERROR: unsupported distro (ID=${ID})" >&2; exit 2 ;;
esac
echo "Distro: ${PRETTY_NAME:-$ID} (family: $FAMILY)"
echo

# standard-path allowlist for SUID/SGID binaries (incl. distro equivalents)
ALLOW='/usr/bin/ /usr/sbin/ /bin/ /sbin/ /usr/libexec/ /usr/lib/ /usr/lib64/ /lib/ /lib64/ /usr/local/bin/ /usr/local/sbin/ /opt/ /snap/'

in_allowlist() {
  local f="$1" p
  for p in $ALLOW; do
    case "$f" in "$p"*) return 0 ;; esac
  done
  return 1
}

echo "=== World-writable regular files (top $TOP, / pruned of /proc /sys /dev) ==="
ww_tmp="$(mktemp)"; trap 'rm -f "$ww_tmp"' EXIT
# errors (permission denied) go to stderr suppressed; run is read-only
find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f -perm -0002 -print 2>/dev/null >"$ww_tmp" || true
ww_count="$(wc -l <"$ww_tmp" | tr -d ' ')"
echo "Total world-writable regular files: $ww_count"
if [ "$ww_count" -gt 0 ]; then
  head -n "$TOP" "$ww_tmp" | while IFS= read -r f; do
    ls -ld -- "$f" 2>/dev/null || printf '? %s\n' "$f"
  done
  [ "$ww_count" -gt "$TOP" ] && echo "... and $((ww_count - TOP)) more (use --top N to show more)"
fi
echo

echo "=== SUID binaries ==="
suid_count=0; suid_flag=0
while IFS= read -r f; do
  suid_count=$((suid_count+1))
  if in_allowlist "$f"; then
    printf 'ok        %s\n' "$f"
  else
    suid_flag=$((suid_flag+1))
    printf 'FLAGGED   %s   <-- outside standard-path allowlist\n' "$f"
  fi
done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f -perm -4000 -print 2>/dev/null | sort)
echo "SUID total: $suid_count, flagged outside allowlist: $suid_flag"
echo

echo "=== SGID binaries ==="
sgid_count=0; sgid_flag=0
while IFS= read -r f; do
  sgid_count=$((sgid_count+1))
  if in_allowlist "$f"; then
    printf 'ok        %s\n' "$f"
  else
    sgid_flag=$((sgid_flag+1))
    printf 'FLAGGED   %s   <-- outside standard-path allowlist\n' "$f"
  fi
done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f -perm -2000 -print 2>/dev/null | sort)
echo "SGID total: $sgid_count, flagged outside allowlist: $sgid_flag"
echo
echo "Result: $ww_count world-writable file(s); $suid_flag SUID + $sgid_flag SGID binary(ies) outside allowlist."
[ "$suid_flag$sgid_flag" = "00" ] && [ "$ww_count" = 0 ] && exit 0 || exit 1
