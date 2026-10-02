#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # common.sh ships alongside; resolved via $SCRIPT_DIR at runtime
. "$SCRIPT_DIR/common.sh"
load_config

HOST=$(hostname)
TS=$(date -Iseconds)
OUT="$HEALTH_CSV"
[ -f "$OUT" ] || echo "timestamp,host,load1,load5,load15,mem_used_mb,mem_free_mb,disk_pct_root,io_wait" > "$OUT"

# Load averages
read -r L1 L5 L15 _ < <(awk '{print $1,$2,$3,$4}' /proc/loadavg)
# Memory (MB)
MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
MEM_FREE=$(free -m | awk '/Mem:/ {print $4}')
# Disk usage of root
DISK_ROOT=$(df -P / | awk 'END{gsub("%","",$5); print $5}')
# IO wait (vmstat 1 2, take the second sample)
assert_cmd vmstat
IOWAIT=$(vmstat 1 2 | tail -1 | awk '{print $16}')

echo "$TS,$HOST,$L1,$L5,$L15,$MEM_USED,$MEM_FREE,$DISK_ROOT,$IOWAIT" >> "$OUT"

# Top processes (CPU and MEM)
TP_OUT="${LOG_DIR}/top-procs-$(date +%Y%m%d).log"
{
  echo "==== $TS Top CPU ===="
  ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu | head -n $((TOP_PROC_COUNT+1))
  echo
  echo "==== $TS Top MEM ===="
  ps -eo pid,ppid,comm,%mem,%cpu --sort=-%mem | head -n $((TOP_PROC_COUNT+1))
} >> "$TP_OUT"

log "Health metrics captured -> $OUT; top processes -> $TP_OUT"
