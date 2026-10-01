#!/usr/bin/env bash
# ports-audit — list listening TCP/UDP ports, flag all-interface listeners.
# Read-only. Usage: ports-audit-local.sh [--expect-file FILE] [--help]
set -euo pipefail

EXPECT_FILE=""

usage() {
  cat <<'EOF'
ports-audit-local.sh — Audit listening network ports.

Usage: ports-audit-local.sh [--expect-file FILE]

Options:
  --expect-file FILE  File with allowed listeners, one per line:
                      PORT, PORT/proto, or ADDR:PORT (e.g. "80", "53/udp",
                      "127.0.0.1:3306"). Anything listening that is not
                      listed is flagged as UNEXPECTED.
  --help              Show this help.

Lists listening TCP and UDP sockets via `ss -tulnp` (process name/PID),
flags listeners bound to all interfaces (0.0.0.0 / ::) vs localhost-only.
Read-only.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-file) EXPECT_FILE="${2:?--expect-file needs a file}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$EXPECT_FILE" ] && [ ! -r "$EXPECT_FILE" ] && { echo "ERROR: cannot read $EXPECT_FILE" >&2; exit 2; }

command -v ss >/dev/null 2>&1 || { echo "ERROR: 'ss' not found (iproute2 missing)" >&2; exit 2; }

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
ss -tulnpH >"$tmp" 2>/dev/null || true

echo "=== Listening sockets (ss -tulnp) ==="
printf '%-5s %-23s %-10s %s\n' PROTO ADDR:PORT SCOPE PROCESS
echo "--------------------------------------------------------------"

n=0; unexpected=0
while read -r proto _state _recv _send local _peer proc; do
  [ -z "${proto:-}" ] && continue
  # local looks like "0.0.0.0:80", "[::]:443", "127.0.0.1:3306", "[::1]:631"
  addr="${local%:*}"; port="${local##*:}"
  scope="other"
  case "$addr" in
    "0.0.0.0"|"::"|"[::]"|"*") scope="ALL-IF" ;;
    "127.0.0.1"|"::1"|"[::1]")  scope="localhost" ;;
  esac
  pname="$(printf '%s' "$proc" | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)"
  pid="$(printf '%s' "$proc" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
  [ -z "$pname" ] && pname="-"; [ -z "$pid" ] && pid="-"
  n=$((n+1))
  printf '%-5s %-23s %-10s %s(%s)\n' "$proto" "$local" "$scope" "$pname" "$pid"

  if [ -n "$EXPECT_FILE" ]; then
    pnorm="${proto,,}"
    match=0
    while IFS= read -r e || [ -n "$e" ]; do
      e="$(printf '%s' "$e" | tr -d '[:space:]')"
      case "$e" in ''|\#*) continue ;; esac
      case "$e" in
        "$local"|"$port"|"$port/$pnorm"|"$addr:$port") match=1; break ;;
      esac
    done < "$EXPECT_FILE"
    if [ "$match" = 0 ]; then
      echo "  ^^ UNEXPECTED listener (not in expect file)"
      unexpected=$((unexpected+1))
    fi
  fi
done < "$tmp"

echo
echo "Total listeners: $n"
echo "Scope legend: ALL-IF = bound to all interfaces (0.0.0.0 / ::); localhost = loopback only."
if [ -n "$EXPECT_FILE" ]; then
  echo "Expect-file diff: $unexpected UNEXPECTED listener(s) vs $EXPECT_FILE"
  [ "$unexpected" -gt 0 ] && exit 1 || true
fi
exit 0
