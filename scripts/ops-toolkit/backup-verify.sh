#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

TS=$(date -Iseconds)
RET=0

if [ ! -f "$BACKUP_LOG" ]; then
  echo "$TS ERROR: Backup log not found: $BACKUP_LOG" >&2
  exit 2
fi

if grep -qiE '(fail|error)' "$BACKUP_LOG"; then
  echo "$TS ERROR: Failures found in backup log: $BACKUP_LOG" >&2
  RET=1
else
  echo "$TS OK: Backup logs clean"
fi

# Weekly restore test on configured weekday
if [ "$(date +%u)" -eq "${RESTORE_TEST_WEEKDAY}" ]; then
  if [ ! -f "$BACKUP_SAMPLE_ARCHIVE" ]; then
    echo "$TS ERROR: Sample archive not found: $BACKUP_SAMPLE_ARCHIVE" >&2
    exit 3
  fi
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  set +e
  tar -xzf "$BACKUP_SAMPLE_ARCHIVE" -C "$TMP" 2>>"${LOG_DIR}/backup-verify-errors.log"
  TAR_RET=$?
  set -e
  if [ $TAR_RET -ne 0 ]; then
    echo "$TS ERROR: tar extraction failed for $BACKUP_SAMPLE_ARCHIVE" >&2
    exit 4
  fi
  if [ ! -f "$TMP/$BACKUP_SAMPLE_VERIFY_PATH" ]; then
    echo "$TS ERROR: Restore test failed; file not found: $BACKUP_SAMPLE_VERIFY_PATH" >&2
    exit 5
  fi
  echo "$TS OK: Weekly restore spot-check passed"
fi

exit $RET
