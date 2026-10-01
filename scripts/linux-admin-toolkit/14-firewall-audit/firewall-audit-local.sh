#!/usr/bin/env bash
# firewall-audit — detect the active firewall stack and summarize its rules.
# Read-only. Usage: firewall-audit-local.sh [--help]
set -euo pipefail

usage() {
  cat <<'EOF'
firewall-audit-local.sh — Detect the active firewall stack and report its state.

Usage: firewall-audit-local.sh

Checks, in order: firewalld, ufw, nftables, iptables/ip6tables.
Dumps the active ruleset and summarizes default policies and open
ports/services. Read-only; never changes firewall state.
EOF
}

[ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] && { usage; exit 0; }
[ $# -gt 0 ] && { echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2; }

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

ACTIVE=0

# ---- firewalld ----
if command -v firewall-cmd >/dev/null 2>&1; then
  state="$(firewall-cmd --state 2>/dev/null || true)"
  echo "firewalld: state=$state"
  if [ "$state" = "running" ]; then
    ACTIVE=1
    echo "--- default zone: $(firewall-cmd --get-default-zone 2>/dev/null) ---"
    firewall-cmd --list-all 2>/dev/null || echo "(could not list zone details)"
    echo "--- all zones ---"
    for z in $(firewall-cmd --get-zones 2>/dev/null); do
      echo "zone $z:"
      firewall-cmd --zone="$z" --list-all 2>/dev/null | sed 's/^/  /'
    done
  fi
else
  echo "firewalld: not installed"
fi
echo

# ---- ufw ----
if command -v ufw >/dev/null 2>&1; then
  ufw_out="$(ufw status verbose 2>/dev/null || true)"
  ufw_state="$(printf '%s' "$ufw_out" | head -1)"
  echo "ufw: $ufw_state"
  case "$ufw_state" in
    *active*) ACTIVE=1; printf '%s\n' "$ufw_out" ;;
    *) echo "(ufw present but inactive — rules shown are not enforced)" ;;
  esac
else
  echo "ufw: not installed"
fi
echo

# ---- nftables / iptables fallback ----
have_ruleset=0
if command -v nft >/dev/null 2>&1; then
  ruleset="$(nft list ruleset 2>/dev/null || true)"
  # filter/table/chain definitions with no rules == effectively empty
  n_rules="$(printf '%s' "$ruleset" | grep -cE '^\s+(tcp|udp|ip|meta|ct|limit|log|accept|drop|reject|jump|goto|return)' || true)"
  echo "nftables: $([ "$n_rules" -gt 0 ] && echo "active with $n_rules rule line(s)" || echo "no effective rules")"
  if [ "$n_rules" -gt 0 ]; then
    ACTIVE=1; have_ruleset=1
    echo "--- nft ruleset ---"
    printf '%s\n' "$ruleset"
  fi
else
  echo "nftables: not installed"
fi
echo

for v in 4 6; do
  if [ "$v" = 4 ]; then cmd=iptables; else cmd=ip6tables; fi
  if command -v "$cmd" >/dev/null 2>&1; then
    dump="$("$cmd" -S 2>/dev/null || true)"
    n_rules="$(printf '%s' "$dump" | grep -c '^-A' || true)"
    echo "$cmd: $([ "$n_rules" -gt 0 ] && echo "$n_rules rule(s)" || echo "no rules")"
    printf '%s\n' "$dump" | grep -E '^-P' | sed 's/^/  default policy: /' || true
    if [ "$n_rules" -gt 0 ]; then
      ACTIVE=1; have_ruleset=1
      echo "--- $cmd -S ---"
      printf '%s\n' "$dump"
      echo "--- open ports (from $cmd) ---"
      printf '%s\n' "$dump" | grep -oE '\-\-dport [0-9:]+' | sort -u | sed 's/^/  /' || echo "  (none extractable)"
    fi
  else
    echo "$cmd: not installed"
  fi
  echo
done

if [ "$ACTIVE" -eq 0 ]; then
  echo "RESULT: no active firewall detected on this host (checked firewalld, ufw, nftables, iptables/ip6tables)."
elif [ "$have_ruleset" -eq 1 ]; then
  echo "RESULT: firewall ACTIVE (ruleset dumped above)."
else
  echo "RESULT: firewall ACTIVE (backend reports active but no ruleset dump was available)."
fi
exit 0
