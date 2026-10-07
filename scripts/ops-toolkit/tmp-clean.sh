#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

find /tmp /var/tmp -xdev -mindepth 1 -mtime +"${TMP_RETENTION_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
find /var/cache -xdev -type f -mtime +"${CACHE_RETENTION_DAYS}" -delete 2>/dev/null || true

echo "$(date -Iseconds) Temp & cache cleanup complete"
