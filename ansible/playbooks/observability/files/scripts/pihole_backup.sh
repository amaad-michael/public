#!/usr/bin/env bash
# Pull Pi-hole Teleporter backups from BOTH resolvers (containerized).
# Runs as 'backup' with command-restricted SSH keys on pi4/pi0.
set -euo pipefail
DEST="/var/backups/pihole"
KEEP=14
CONTAINER="pihole-backup"   # verified via docker ps on pi4+pi0, 2026-07-07

declare -A HOSTS=( [pi4]="192.168.0.104" [pi0]="192.168.0.100" )
STAMP=$(date +%Y%m%d-%H%M%S)

for name in "${!HOSTS[@]}"; do
  out="${DEST}/pihole-${name}-${STAMP}.zip"
  # Teleporter writes a file (no stdout stream): create in container tmp, cat back, clean up.
  # v6 syntax — /usr/bin/pihole-FTL confirmed present in container on both nodes.
  ssh -i /home/backup/.ssh/pihole_backup "backup@${HOSTS[$name]}" \
    "set -e; docker exec ${CONTAINER} pihole-FTL --teleporter /tmp/pb.zip >/dev/null; \
     docker exec ${CONTAINER} cat /tmp/pb.zip; \
     docker exec ${CONTAINER} rm -f /tmp/pb.zip" > "$out"
  [ -s "$out" ] || { rm -f "$out"; echo "backup failed: $name"; exit 1; }
done

find "${DEST}" -maxdepth 1 -name 'pihole-*.zip' -printf '%T@ %p\n' \
  | sort -rn | tail -n +$(( KEEP*2 + 1 )) | cut -d' ' -f2- | xargs -r rm --
