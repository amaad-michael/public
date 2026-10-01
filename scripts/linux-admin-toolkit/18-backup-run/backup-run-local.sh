#!/usr/bin/env bash
#
# backup-run-local.sh — rsync a source directory into a timestamped backup
# directory DEST/YYYY-MM-DD_HHMMSS/, write a manifest, and prune old backups.
#
# Idempotency note: re-runs NEVER overwrite an existing backup. Every run
# creates a brand-new timestamped directory (a numeric _N suffix is appended
# if two runs land in the same second). Old backups are removed only by the
# retention prune, never by the backup itself.
#
# Usage:
#   backup-run-local.sh --source SRC --dest DEST [--retention N] [--check]
#
# Exit codes: 0 on success (rsync's exit code is recorded in the manifest
# and also becomes this script's exit code).

set -euo pipefail

PROG="$(basename "$0")"
SOURCE=""
DEST=""
RETENTION=7
CHECK_MODE=0

usage() {
  cat <<EOF
Usage: $PROG --source SRC --dest DEST [--retention N] [--check] [--help]

  --source SRC     Directory to back up (required).
  --dest DEST      Backup root; each run creates DEST/YYYY-MM-DD_HHMMSS/
                   (required; created if missing).
  --retention N    Prune timestamped subdirs of DEST older than N days.
                   Only directories matching the YYYY-MM-DD_HHMMSS stamp
                   pattern are ever pruned. Default: 7. 0 keeps only the
                   newest backup.
  --check          Dry-run: show what rsync would copy and which backup dirs
                   would be pruned. Creates nothing, deletes nothing.
  --help           Show this help and exit.

Examples:
  $PROG --source /home/user/docs --dest /mnt/backups/docs
  $PROG --source /etc --dest /mnt/backups/etc --retention 30
  $PROG --source /etc --dest /mnt/backups/etc --check

Mechanism: rsync -a --delete SRC/ DEST/YYYY-MM-DD_HHMMSS/
A MANIFEST.txt (timestamp, source, file count, bytes, rsync exit code) is
written into each new backup directory.
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

# --- argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --source)    SOURCE="${2:?--source requires a value}"; shift 2 ;;
    --dest)      DEST="${2:?--dest requires a value}"; shift 2 ;;
    --retention) RETENTION="${2:?--retention requires a value}"; shift 2 ;;
    --check)     CHECK_MODE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$SOURCE" ] || die "--source is required"
[ -n "$DEST" ]   || die "--dest is required"
[ -d "$SOURCE" ] || die "source is not a directory: $SOURCE"
case "$RETENTION" in
  ''|*[!0-9]*) die "--retention must be a non-negative integer (got: $RETENTION)" ;;
esac
command -v rsync >/dev/null 2>&1 || die "rsync not found in PATH"

STAMP="$(date '+%Y-%m-%d_%H%M%S')"
NEWDIR="$DEST/$STAMP"
if [ -e "$NEWDIR" ]; then
  # Same-second re-run: never overwrite, append a counter instead.
  n=1
  while [ -e "${NEWDIR}_${n}" ]; do n=$((n + 1)); done
  NEWDIR="${NEWDIR}_${n}"
fi

# --- retention pruning ------------------------------------------------------
# Prints timestamped backup dirs in DEST that fall outside the retention
# window. Only stamp-patterned directories are ever candidates.
find_old_backups() {
  local find_cmd
  if [ "$RETENTION" -eq 0 ]; then
    # Keep only the newest: everything already in DEST is a prune candidate.
    find_cmd=(find "$DEST" -mindepth 1 -maxdepth 1 -type d)
  else
    find_cmd=(find "$DEST" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION")
  fi
  "${find_cmd[@]}" 2>/dev/null | while IFS= read -r d; do
    [ "$d" = "$NEWDIR" ] && continue # never prune the dir we are making
    case "$(basename "$d")" in
      ????-??-??_??????|????-??-??_??????_*) printf '%s\n' "$d" ;;
    esac
  done
}

prune_backups() {
  # $1 = 1 for dry-run (list only), 0 to actually delete.
  local dry="$1" d count=0
  while IFS= read -r d; do
    if [ "$dry" = 1 ]; then
      log "  would prune: $d"
    else
      rm -rf -- "$d"
      log "pruned: $d"
    fi
    count=$((count + 1))
  done < <(find_old_backups)
  [ "$dry" = 1 ] || log "pruned $count old backup(s)"
}

# --- dry-run ----------------------------------------------------------------
if [ "$CHECK_MODE" = 1 ]; then
  log "DRY-RUN: would create backup dir: $NEWDIR/"
  log "DRY-RUN: rsync -a --delete $SOURCE/ -> $NEWDIR/"
  if [ -d "$DEST" ]; then
    rsync -a --delete --dry-run --stats "$SOURCE/" "$NEWDIR/" 2>/dev/null \
      | sed -n '/Number of files/,$p'
    log "DRY-RUN: retention prune (older than $RETENTION day(s)):"
    prune_backups 1
  else
    log "DRY-RUN: dest $DEST does not exist yet; nothing to prune."
  fi
  log "DRY-RUN: no changes made."
  exit 0
fi

# --- real run ---------------------------------------------------------------
mkdir -p "$DEST"

# Prune first so a full disk has room for the new backup.
prune_backups 0

mkdir -p "$NEWDIR"
log "backing up: $SOURCE/ -> $NEWDIR/"

rc=0
rsync -a --delete "$SOURCE/" "$NEWDIR/" || rc=$?

# File count and byte total (regular files only; MANIFEST.txt itself is
# excluded — the verify tool recomputes the same way).
stats="$(find "$NEWDIR" -type f -printf '%s\n' 2>/dev/null \
  | awk '{c++; s+=$1} END {print (c+0), (s+0)}')"
fcount="${stats%% *}"
fbytes="${stats##* }"

cat > "$NEWDIR/MANIFEST.txt" <<EOF
# backup-run-local.sh manifest
# NOTE: 'files' and 'bytes' count regular files copied from the source and
# exclude this MANIFEST.txt itself.
tool=backup-run-local.sh
timestamp=$(basename "$NEWDIR")
host=$(hostname)
source=$SOURCE
dest_dir=$NEWDIR
files=$fcount
bytes=$fbytes
rsync_exit=$rc
retention_days=$RETENTION
EOF

log "manifest: $NEWDIR/MANIFEST.txt (files=$fcount bytes=$fbytes rsync_exit=$rc)"
if [ "$rc" -ne 0 ]; then
  die "rsync exited $rc; partial backup retained at $NEWDIR"
fi
log "backup complete: $NEWDIR"
