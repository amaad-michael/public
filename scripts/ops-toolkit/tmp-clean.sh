#!/usr/bin/env bash
#
# NAME: tmp-clean.sh
# WHAT: Deletes stale files from /tmp and /var/tmp (older than
#       TMP_RETENTION_DAYS, default 3) and stale files from /var/cache
#       (older than CACHE_RETENTION_DAYS, default 14).
# WHY:  Keeps scratch and cache dirs from filling the disk on long-running
#       hosts. Stays on the same filesystem (-xdev) so it never walks into
#       other mounts.
# HOW:  sudo ./tmp-clean.sh   (run from cron or by hand)
#       Tune via /etc/ops/ops.conf: TMP_RETENTION_DAYS, CACHE_RETENTION_DAYS.
#
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

find /tmp /var/tmp -xdev -mindepth 1 -mtime +"${TMP_RETENTION_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
find /var/cache -xdev -type f -mtime +"${CACHE_RETENTION_DAYS}" -delete 2>/dev/null || true

echo "$(date -Iseconds) Temp & cache cleanup complete"
