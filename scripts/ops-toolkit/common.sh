#!/usr/bin/env bash
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
