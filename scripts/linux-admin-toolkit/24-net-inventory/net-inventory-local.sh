#!/usr/bin/env bash
#
# net-inventory-local.sh — READ-ONLY: network inventory snapshot.
#
# Reports interfaces and IPs (`ip -brief address`), default routes
# (`ip route show default`), and DNS resolvers (nameservers from
# /etc/resolv.conf, with a note when the systemd-resolved stub is in use).
# Changes nothing on the system.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: net-inventory-local.sh [--help]

  READ-ONLY: network inventory snapshot.

  Shows interfaces and IPs (`ip -brief address`), default routes
  (`ip route show default`), and DNS resolvers (nameservers from
  /etc/resolv.conf; notes when the systemd-resolved stub 127.0.0.53
  is in use and shows the real upstream servers via resolvectl).

Options:
  -h, --help  Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v ip >/dev/null 2>&1 || { echo "ERROR: 'ip' (iproute2) not found in PATH" >&2; exit 2; }

echo "== interfaces and IPs (ip -brief address) =="
ip -brief address
echo

echo "== default routes (ip route show default) =="
ROUTES="$(ip route show default 2>/dev/null || true)"
if [[ -n "$ROUTES" ]]; then
    echo "$ROUTES"
else
    echo "(no default route)"
fi
echo

echo "== DNS resolvers (/etc/resolv.conf) =="
if [[ -r /etc/resolv.conf ]]; then
    NS="$(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null | awk '{ print $2 }' | sort -u || true)"
    if [[ -n "$NS" ]]; then
        # shellcheck disable=SC2001
        sed 's/^/  nameserver: /' <<< "$NS"
    else
        echo "  (no nameserver entries in /etc/resolv.conf)"
    fi
    # systemd-resolved stub resolver: the real upstreams live in resolvectl.
    if echo "$NS" | grep -Eq '^(127\.0\.0\.53|::1)$' \
        && command -v resolvectl >/dev/null 2>&1; then
        echo
        echo "  NOTE: systemd-resolved stub resolver in use; upstream servers:"
        resolvectl dns 2>/dev/null | sed 's/^/    /' \
            || resolvectl status 2>/dev/null | sed 's/^/    /' \
            || echo "    (resolvectl not responding)"
    fi
else
    echo "  WARNING: /etc/resolv.conf is not readable"
fi
