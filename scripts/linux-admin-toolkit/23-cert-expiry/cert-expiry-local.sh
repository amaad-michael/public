#!/usr/bin/env bash
#
# cert-expiry-local.sh — READ-ONLY: scan for TLS certificates expiring soon.
#
# Scans common locations (/etc/ssl/certs, /etc/pki/tls/certs,
# /etc/letsencrypt/live, plus any --dir additions) for *.crt/*.pem files,
# checks each with `openssl x509 -enddate -noout`, and warns on certs
# expiring within N days (--days, default 30). Non-certificate PEM files
# are skipped gracefully. Changes nothing on the system.

set -euo pipefail

DAYS=30
EXTRA_DIRS=()

usage() {
    cat <<'EOF'
Usage: cert-expiry-local.sh [--days N] [--dir DIR]... [--help]

  READ-ONLY: scan certificate directories for certs expiring soon.

  Scans /etc/ssl/certs, /etc/pki/tls/certs and /etc/letsencrypt/live
  (plus any --dir additions) for *.crt/*.pem files, checks each with
  `openssl x509 -enddate -noout`, and warns on certs expiring within
  N days. Non-certificate PEM files are skipped, not treated as errors.

Options:
  --days N   Warn on certs expiring within N days (default: 30).
  --dir DIR  Add a directory to the scan (repeatable).
  -h, --help Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            [[ $# -ge 2 ]] || { echo "ERROR: --days needs a number" >&2; exit 2; }
            DAYS="$2"; shift 2 ;;
        --days=*)
            DAYS="${1#*=}"; shift ;;
        --dir)
            [[ $# -ge 2 ]] || { echo "ERROR: --dir needs a directory" >&2; exit 2; }
            EXTRA_DIRS+=("$2"); shift 2 ;;
        --dir=*)
            EXTRA_DIRS+=("${1#*=}"); shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: --days must be a non-negative integer" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: 'openssl' not found in PATH" >&2; exit 2; }

DIRS=(/etc/ssl/certs /etc/pki/tls/certs /etc/letsencrypt/live)
DIRS+=("${EXTRA_DIRS[@]:-}")

NOW="$(date +%s)"
CHECKED=0
EXPIRED=0
SOON=0
SKIPPED=0
FOUND_ANY_DIR=0

WARNLIST="$(mktemp)"
trap 'rm -f "$WARNLIST"' EXIT

for d in "${DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    FOUND_ANY_DIR=1
    while IFS= read -r -d '' f; do
        # Not every *.pem is a certificate (keys, CRLs, bundles of mixed
        # content): openssl fails on those and we skip gracefully.
        end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null)" \
            || { SKIPPED=$((SKIPPED + 1)); continue; }
        end="${end#notAfter=}"
        eepoch="$(date -d "$end" +%s 2>/dev/null)" \
            || { SKIPPED=$((SKIPPED + 1)); continue; }
        left=$(( (eepoch - NOW) / 86400 ))
        CHECKED=$((CHECKED + 1))
        if [[ "$left" -lt 0 ]]; then
            EXPIRED=$((EXPIRED + 1))
            printf 'EXPIRED  %6d days  %s\n' "$left" "$f" >>"$WARNLIST"
        elif [[ "$left" -le "$DAYS" ]]; then
            SOON=$((SOON + 1))
            printf 'EXPIRING %6d days  %s\n' "$left" "$f" >>"$WARNLIST"
        fi
    done < <(find "$d" \( -type f -o -type l \) \( -name '*.crt' -o -name '*.pem' \) -print0 2>/dev/null)
done

echo "scanned directories: ${DIRS[*]}"
echo "certificates checked: ${CHECKED}   expired: ${EXPIRED}   expiring within ${DAYS}d: ${SOON}   skipped (non-cert PEM): ${SKIPPED}"
echo

if [[ "$FOUND_ANY_DIR" -eq 0 ]]; then
    echo "NOTE: none of the scanned directories exist on this host."
elif [[ "$CHECKED" -eq 0 ]]; then
    echo "none found: no certificate files (*.crt/*.pem) in the scanned directories."
elif [[ "$EXPIRED" -eq 0 && "$SOON" -eq 0 ]]; then
    echo "OK: no certificates expiring within ${DAYS} days."
else
    echo "== certificates needing attention (sorted by days remaining) =="
    sort -t' ' -k2 -n "$WARNLIST"
fi
