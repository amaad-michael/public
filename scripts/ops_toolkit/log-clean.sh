#!/usr/bin/env bash
#
# NAME: log-clean.sh
# WHAT: Three-stage log hygiene: (1) logrotate dry-run saved to
#       ${LOG_DIR}/logrotate-dryrun.txt, then a real logrotate pass;
#       (2) gzip -9 any *.log under /var/log over LOG_GZIP_AFTER_MB
#       (default 200); (3) delete *.gz logs older than
#       LOG_DELETE_GZ_AFTER_DAYS (default 90). Finishes with the same
#       tmp/cache prune as tmp-clean.sh.
# WHY:  /var/log grows without bound on always-on hosts; this keeps it
#       rotating, compressed, and eventually purged instead of filling /.
# HOW:  sudo ./log-clean.sh   (run from cron, e.g. weekly)
#       Tune via /etc/ops/ops.conf: LOG_GZIP_AFTER_MB,
#       LOG_DELETE_GZ_AFTER_DAYS, TMP_RETENTION_DAYS, CACHE_RETENTION_DAYS.
#
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

# logrotate dry-run and actual run (if present)
if command -v logrotate >/dev/null 2>&1; then
  logrotate -d /etc/logrotate.conf >"${LOG_DIR}/logrotate-dryrun.txt" 2>&1 || true
  logrotate /etc/logrotate.conf || true
fi

# Compress large .log files
find /var/log -xdev -type f -name "*.log" -size +"${LOG_GZIP_AFTER_MB}"M \
  -print -exec gzip -9 {} \; 2>/dev/null || true

# Delete old compressed logs
find /var/log -xdev -type f -name "*.gz" -mtime +"${LOG_DELETE_GZ_AFTER_DAYS}" -delete 2>/dev/null || true

# Prune tmp and cache
find /tmp /var/tmp -xdev -mindepth 1 -mtime +"${TMP_RETENTION_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
find /var/cache -xdev -type f -mtime +"${CACHE_RETENTION_DAYS}" -delete 2>/dev/null || true

log "Log rotation & cleanup complete"
