#!/usr/bin/env bash
#
# logrotate-check-local.sh — READ-ONLY: verify logrotate configuration.
#
#  1. Checks that the logrotate config parses:
#       logrotate --debug /etc/logrotate.conf
#     (--debug validates the config without rotating anything;
#      a non-zero exit is reported as a config failure.)
#  2. Lists the entries in /etc/logrotate.d.
#  3. Checks that key logs (/var/log/syslog|messages, /var/log/auth.log|secure)
#     are covered by at least one config (direct path or glob pattern).
#     Uncovered key logs are reported as gaps.
#
# Changes nothing on the system.

set -euo pipefail

CONF="/etc/logrotate.conf"
FAIL=0
PARSE_STATE="skipped"   # ok | fail | skipped

usage() {
    cat <<'EOF'
Usage: logrotate-check-local.sh [--help]

  READ-ONLY: verify the logrotate configuration parses
  (`logrotate --debug /etc/logrotate.conf`, which rotates nothing),
  list /etc/logrotate.d entries, and check that key logs
  (/var/log/syslog|messages, /var/log/auth.log|secure) are covered
  by some config. Reports gaps.

  Exit status: 0 unless the logrotate config fails to parse.

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

echo "== logrotate binary =="
if command -v logrotate >/dev/null 2>&1; then
    echo "found: $(command -v logrotate)"
else
    echo "WARNING: logrotate is not installed — cannot parse-check the config."
fi
echo

echo "== config parse check =="
if command -v logrotate >/dev/null 2>&1; then
    if [[ -r "$CONF" ]]; then
        DBG="$(mktemp)"
        trap 'rm -f "$DBG"' EXIT
        # --debug validates the config and prints what would happen; it does
        # not rotate logs or touch the state file.
        if logrotate --debug "$CONF" >"$DBG" 2>&1; then
            echo "OK: ${CONF} parses cleanly (logrotate --debug exited 0)."
            PARSE_STATE="ok"
        else
            echo "FAILURE: ${CONF} did not parse (logrotate --debug exited non-zero)."
            echo "--- debug output ---"
            cat "$DBG"
            FAIL=1
            PARSE_STATE="fail"
        fi
    else
        echo "WARNING: ${CONF} is not readable — cannot parse-check."
    fi
else
    echo "(skipped: logrotate not installed)"
fi
echo

echo "== /etc/logrotate.d entries =="
if [[ -d /etc/logrotate.d ]]; then
    ENTRIES="$(ls -1 /etc/logrotate.d 2>/dev/null || true)"
    if [[ -n "$ENTRIES" ]]; then
        sed 's/^/  /' <<< "$ENTRIES"
    else
        echo "  (empty)"
    fi
else
    echo "  (directory /etc/logrotate.d does not exist)"
fi
echo

echo "== key-log coverage =="
# Collect every log-path token from the configs: unindented lines hold log
# paths (possibly several per line, possibly globs like /var/log/*.log).
# Tokens without a '/' are directives (weekly, rotate, create, ...) — skip them.
PATTERNS="$(grep -hE '^[^[:space:]#]' "$CONF" /etc/logrotate.d/* 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\//) print $i }' || true)"

GAPS=0
for keylog in /var/log/syslog /var/log/messages /var/log/auth.log /var/log/secure; do
    if [[ ! -e "$keylog" ]]; then
        echo "N/A (absent on this host): ${keylog}"
        continue
    fi
    hit=""
    while IFS= read -r pat; do
        [[ -n "$pat" ]] || continue
        # Unquoted $pat on the right side of `case ... in` = glob match,
        # so patterns like /var/log/*.log cover /var/log/syslog.
        # shellcheck disable=SC2254
        case "$keylog" in $pat) hit="$pat"; break ;; esac
    done <<< "$PATTERNS"
    if [[ -n "$hit" ]]; then
        echo "COVERED: ${keylog}  (pattern: ${hit})"
    else
        echo "GAP: ${keylog} is not covered by any logrotate config"
        GAPS=$((GAPS + 1))
    fi
done

echo
if [[ "$FAIL" -ne 0 ]]; then
    echo "RESULT: FAILURE — logrotate config does not parse."
elif [[ "$GAPS" -gt 0 ]]; then
    echo "RESULT: WARNING — ${GAPS} key log(s) present but not covered by any logrotate config (see above)."
else
    echo "RESULT: OK — no parse errors and no coverage gaps among present key logs."
fi
[[ "$PARSE_STATE" == "skipped" ]] && echo "NOTE: the parse check was skipped because logrotate is not installed."

exit "$FAIL"
