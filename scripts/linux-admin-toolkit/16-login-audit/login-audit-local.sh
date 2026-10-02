#!/usr/bin/env bash
# login-audit — summarize failed login attempts per IP and per username.
# Read-only. Usage: login-audit-local.sh [--days N] [--threshold N] [--help]
set -euo pipefail

DAYS=7
THRESHOLD=10

usage() {
  cat <<'EOF'
login-audit-local.sh — Summarize failed logins (possible brute force).

Usage: login-audit-local.sh [--days N] [--threshold N]

Options:
  --days N       Look back N days (default 7).
  --threshold N  Flag source IPs with more than N failures as possible
                 brute-force (default 10).
  --help         Show this help.

Reads `journalctl _COMM=sshd` when available, else /var/log/auth.log
(Debian-family) or /var/log/secure (RedHat-family), including rotated
.gz logs when present. Read-only.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --days)      DAYS="${2:?--days needs a number}"; shift 2 ;;
    --threshold) THRESHOLD="${2:?--threshold needs a number}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$DAYS $THRESHOLD" in *[!0-9\ ]*) echo "ERROR: --days/--threshold must be integers" >&2; exit 2 ;; esac

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

# ---- collect log lines ----
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
SOURCE=""
if command -v journalctl >/dev/null 2>&1 && journalctl --no-pager --since "-${DAYS} days" _COMM=sshd -o cat >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  SOURCE="journalctl _COMM=sshd (last ${DAYS}d)"
else
  : >"$tmp"
  case "$FAMILY" in
    redhat) logs="/var/log/secure" ;;
    debian) logs="/var/log/auth.log" ;;
  esac
  for f in "$logs" "$logs".1 "$logs".2*; do
    [ -r "$f" ] || continue
    case "$f" in *.gz) zcat "$f" 2>/dev/null >>"$tmp" || true ;; *) cat "$f" >>"$tmp" || true ;; esac
  done
  if [ -s "$tmp" ]; then
    SOURCE="log file(s) under $logs (last ${DAYS}d filter best-effort; rotated logs included)"
  else
    echo "Distro: ${PRETTY_NAME:-$ID}"
    echo "NOTE: no sshd journal entries and no readable $logs — no login data available (sshd may not run here, or logs are elsewhere). Nothing to audit."
    exit 0
  fi
fi

echo "Distro: ${PRETTY_NAME:-$ID}"
echo "Source: $SOURCE"
echo "Window: last $DAYS day(s); brute-force threshold: >$THRESHOLD failures per IP"
echo

# ---- parse failures: sshd 'Failed ...' lines ----
# Covers: "Failed password for root from 1.2.3.4 port 5", "Failed password for invalid user bob from ...",
#         "authentication failure; ... rhost=1.2.3.4 ... user=root"
awk_out="$(mktemp)"; trap 'rm -f "$tmp" "$awk_out"' EXIT
grep -aE 'Failed|authentication failure' "$tmp" >"$awk_out" || true

total="$(wc -l <"$awk_out" | tr -d ' ')"
echo "Total failed-login lines matched: $total"
if [ "$total" -eq 0 ]; then
  echo "No failed logins found in the window."
  exit 0
fi
echo

echo "=== Failures per source IP ==="
grep -aoE 'from [0-9a-fA-F:.]+' "$awk_out" | awk '{print $2}' \
  | sort | uniq -c | sort -rn | head -30 | while read -r cnt ip; do
  flag=""; [ "$cnt" -gt "$THRESHOLD" ] && flag="  <-- POSSIBLE BRUTE FORCE (>$THRESHOLD)"
  printf '%6s  %-40s%s\n' "$cnt" "$ip" "$flag"
done
echo
echo "=== Failures per username ==="
grep -aE 'Failed' "$awk_out" \
  | grep -aoE 'for (invalid user )?[A-Za-z0-9._-]+ from' \
  | sed -E 's/^for (invalid user )?//; s/ from$//' \
  | sort | uniq -c | sort -rn | head -30 | awk '{printf "%6s  %s\n", $1, $2}'
exit 0
