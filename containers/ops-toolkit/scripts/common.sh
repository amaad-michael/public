#!/usr/bin/env bash
#
# NAME: common.sh
# WHAT: Shared library for the ops-toolkit scripts — NOT a standalone script.
#       Provides load_config (defaults + /etc/ops/ops.conf overrides),
#       log (timestamped stdout), and assert_cmd (dependency check).
# WHY:  Every ops-toolkit script sources this so paths, retentions, and
#       thresholds live in one place instead of being copy-pasted.
# HOW:  Do NOT run directly. Sibling scripts source it like this:
#         SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
#         . "$SCRIPT_DIR/common.sh"
#         load_config
#       Override any default by setting the variable in /etc/ops/ops.conf
#       (sourced after the defaults, so it wins). Full variable list is in
#       the load_config body below.
#
set -euo pipefail
export LC_ALL=C

# Load config with defaults, then override from /etc/ops/ops.conf if present
load_config() {
  : "${LOG_DIR:=/var/log/ops}"
  : "${STATE_DIR:=/var/lib/ops-toolkit}"

  : "${HEALTH_CSV:=${LOG_DIR}/sys-health.csv}"
  : "${TOP_PROC_COUNT:=10}"

  : "${BACKUP_LOG:=/var/log/backup/last.log}"
  : "${BACKUP_SAMPLE_ARCHIVE:=/backups/sample.tar.gz}"
  : "${BACKUP_SAMPLE_VERIFY_PATH:=path/to/knownfile}"
  : "${RESTORE_TEST_WEEKDAY:=7}"

  : "${LOG_GZIP_AFTER_MB:=200}"
  : "${LOG_DELETE_GZ_AFTER_DAYS:=90}"
  : "${TMP_RETENTION_DAYS:=3}"
  : "${CACHE_RETENTION_DAYS:=14}"

  : "${SSL_ENDPOINTS_FILE:=/etc/ops/ssl_endpoints.txt}"
  : "${SSL_EXPIRY_THRESHOLD_DAYS:=60}"
  : "${SSL_CONNECT_TIMEOUT:=10s}"

  : "${SERVICES_FILE:=/etc/ops/services.txt}"
  : "${JOURNAL_PRIORITY:=3}"
  : "${JOURNAL_SINCE_DAYS:=7}"

  if [ -f /etc/ops/ops.conf ]; then
    # shellcheck source=/dev/null
    . /etc/ops/ops.conf
  fi

  mkdir -p "$LOG_DIR" "$STATE_DIR"
}

log() { echo "$(date -Iseconds) $*"; }

assert_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 127; }; }
