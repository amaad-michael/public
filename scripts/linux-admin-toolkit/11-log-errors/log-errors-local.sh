#!/usr/bin/env bash
#
# log-errors-local.sh — READ-ONLY: show errors/warnings logged since yesterday.
#
# Prefers the systemd journal when it is usable:
#   journalctl -p err..warning --since yesterday
# Otherwise falls back to grepping the syslog text file
# (/var/log/syslog on Debian-family, /var/log/messages on RHEL-family).
#
# Prints a per-unit/service summary at the top, then the matching lines.
# Changes nothing on the system.

set -euo pipefail

LINES=50

usage() {
    cat <<'EOF'
Usage: log-errors-local.sh [--lines N] [--help]

  READ-ONLY: show errors/warnings logged since yesterday.

  Prefers `journalctl -p err..warning --since yesterday` when the systemd
  journal is available; otherwise greps /var/log/syslog (Debian-family) or
  /var/log/messages (RHEL-family) for error|fail|warn|crit|alert|emerg.

Options:
  --lines N   Show at most N matching lines (default: 50).
  -h, --help  Show this help and exit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lines)
            [[ $# -ge 2 ]] || { echo "ERROR: --lines needs a number" >&2; exit 2; }
            LINES="$2"; shift 2 ;;
        --lines=*)
            LINES="${1#*=}"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$LINES" =~ ^[0-9]+$ ]] || { echo "ERROR: --lines must be a non-negative integer" >&2; exit 2; }
command -v date >/dev/null 2>&1 || { echo "ERROR: 'date' not found in PATH" >&2; exit 2; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Extract the syslog identifier / systemd unit from a "short"-format line:
#   Sep 15 22:20:20 hostname ident[pid]: message
unit_of() {
    awk '{ id=$5; sub(/:$/, "", id); sub(/\[[0-9]+\]$/, "", id); print id }'
}

SOURCE=""
if command -v journalctl >/dev/null 2>&1 \
    && journalctl --no-pager -n 1 >/dev/null 2>&1; then
    if journalctl -p err..warning --since yesterday --no-pager -o short \
            2>/dev/null | grep -v '^-- ' >"$TMP" || true; then
        SOURCE="systemd journal (journalctl -p err..warning --since yesterday)"
    fi
fi

if [[ -z "$SOURCE" ]]; then
    LOGFILE=""
    for cand in /var/log/syslog /var/log/messages; do
        if [[ -r "$cand" ]]; then LOGFILE="$cand"; break; fi
    done
    [[ -n "$LOGFILE" ]] || {
        echo "ERROR: no usable systemd journal, and neither /var/log/syslog nor /var/log/messages is readable" >&2
        exit 2
    }
    # %e is space-padded day-of-month, matching syslog's "Sep  5" format.
    TODAY="$(date '+%b %e')"
    YESTERDAY="$(date -d 'yesterday' '+%b %e')"
    grep -E "^(${TODAY}|${YESTERDAY})" "$LOGFILE" 2>/dev/null \
        | grep -iE 'error|fail|warn|crit|alert|emerg' >"$TMP" || true
    SOURCE="text log ${LOGFILE} (grep -iE 'error|fail|warn|crit|alert|emerg', since yesterday)"
fi

TOTAL="$(wc -l <"$TMP" | tr -d ' ')"

echo "source: ${SOURCE}"
echo "matching lines since yesterday: ${TOTAL}"
echo
echo "== counts per unit/service (top 20) =="
if [[ "$TOTAL" -gt 0 ]]; then
    unit_of <"$TMP" | sort | uniq -c | sort -rn | head -20
else
    echo "(none)"
fi
echo
echo "== last ${LINES} matching lines =="
if [[ "$TOTAL" -gt 0 ]]; then
    tail -n "$LINES" "$TMP"
else
    echo "(none)"
fi
