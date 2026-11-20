#!/usr/bin/env bash
# Pull Unbound config from BOTH resolver nodes (containerized).
set -euo pipefail
DEST="/var/backups/unbound"
KEEP=14
CONTAINER="unbound-backup"   # verified via docker ps on pi4+pi0, 2026-07-07
CONF_DIR="/usr/local/unbound"   # compiled-in prefix per `unbound -V` on live container
                                # (--with-conf-file=/usr/local/unbound/unbound.conf)

declare -A HOSTS=( [pi4]="192.168.0.104" [pi0]="192.168.0.100" )
STAMP=$(date +%Y%m%d-%H%M%S)

for name in "${!HOSTS[@]}"; do
  out="${DEST}/unbound-${name}-${STAMP}.tar.gz"
  ssh -o UserKnownHostsFile=/keys/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -i /keys/unbound_backup "backup@${HOSTS[$name]}" \
    "docker exec ${CONTAINER} tar czf - ${CONF_DIR}" > "$out"
  [ -s "$out" ] || { rm -f "$out"; echo "backup failed: $name"; exit 1; }
done

find "${DEST}" -maxdepth 1 -name 'unbound-*.tar.gz' -printf '%T@ %p\n' \
  | sort -rn | tail -n +$(( KEEP*2 + 1 )) | cut -d' ' -f2- | xargs -r rm --
