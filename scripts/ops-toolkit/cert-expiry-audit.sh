#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

assert_cmd openssl
assert_cmd timeout

CSV="${LOG_DIR}/cert-expiry.csv"
[ -f "$CSV" ] || echo "timestamp,target,days_remaining,valid,notes" > "$CSV"

TS=$(date -Iseconds)
ALERT=0

if [ ! -f "$SSL_ENDPOINTS_FILE" ]; then
  echo "$TS ERROR: endpoints file not found: $SSL_ENDPOINTS_FILE" >&2
  exit 2
fi

while IFS= read -r LINE; do
  TARGET=$(echo "$LINE" | sed 's/[#].*$//' | xargs)
  [ -z "$TARGET" ] && continue
  HOST=${TARGET%%:*}
  PORT=${TARGET##*:}
  if [ -z "$HOST" ] || [ -z "$PORT" ]; then
    echo "$TS WARN: Invalid endpoint: $LINE" >&2
    echo "$TS,$TARGET,,false,invalid endpoint" >> "$CSV"
    continue
  fi
  EXP_RAW=$(timeout "$SSL_CONNECT_TIMEOUT" bash -c "</dev/null openssl s_client -servername $HOST -connect $TARGET 2>/dev/null | openssl x509 -noout -enddate" || true)
  if [[ "$EXP_RAW" != notAfter=* ]]; then
    echo "$TS,$TARGET,,false,unable to fetch cert" >> "$CSV"
    echo "$TS WARN: Unable to fetch cert for $TARGET" >&2
    ALERT=1
    continue
  fi
  EXP_DATE=${EXP_RAW#notAfter=}
  EXPTS=$(date -d "$EXP_DATE" +%s 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$EXPTS" -le 0 ]; then
    echo "$TS,$TARGET,,false,parse error" >> "$CSV"
    ALERT=1
    continue
  fi
  DAYS=$(( (EXPTS - NOW) / 86400 ))
  VALID=true
  NOTES=""
  if [ "$DAYS" -lt "$SSL_EXPIRY_THRESHOLD_DAYS" ]; then
    NOTES="expiring soon"
    ALERT=1
  fi
  echo "$TS,$TARGET,$DAYS,$VALID,$NOTES" >> "$CSV"
  echo "$TS $TARGET expires in $DAYS days"

done < "$SSL_ENDPOINTS_FILE"

exit $ALERT
