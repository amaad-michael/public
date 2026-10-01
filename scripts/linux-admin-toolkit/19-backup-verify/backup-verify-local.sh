#!/usr/bin/env bash
#
# backup-verify-local.sh — READ-ONLY verification of timestamped backups made
# by backup-run-local.sh.
#
# Checks the latest DEST/YYYY-MM-DD_HHMMSS/ backup:
#   1. a timestamped backup exists
#   2. its age is within --max-age-days
#   3. MANIFEST.txt is present and well-formed (and rsync_exit == 0)
#   4. integrity spot-check:
#        - with --source: sha256 of up to 20 sample files, source vs backup
#        - without --source: manifest file/byte counts vs actual counts
#
# Prints PASS/FAIL per check. Changes nothing. Exit 0 only if all checks pass.
#
# Usage:
#   backup-verify-local.sh --dest DEST [--source SRC] [--max-age-days N]

set -euo pipefail

PROG="$(basename "$0")"
DEST=""
SOURCE=""
MAX_AGE=1
SAMPLE_N=20

usage() {
  cat <<EOF
Usage: $PROG --dest DEST [--source SRC] [--max-age-days N] [--help]

  --dest DEST         Backup root containing YYYY-MM-DD_HHMMSS/ dirs (required).
  --source SRC        Original source dir; enables a sha256 spot-check of up
                      to $SAMPLE_N files between source and the latest backup.
  --max-age-days N    Latest backup must be at most N days old. Default: 1.
  --help              Show this help and exit.

Examples:
  $PROG --dest /mnt/backups/docs --source /home/user/docs
  $PROG --dest /mnt/backups/etc --max-age-days 7

Read-only: this script never creates, modifies, or deletes anything.
EOF
}

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)         DEST="${2:?--dest requires a value}"; shift 2 ;;
    --source)       SOURCE="${2:?--source requires a value}"; shift 2 ;;
    --max-age-days) MAX_AGE="${2:?--max-age-days requires a value}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$DEST" ] || die "--dest is required"
[ -d "$DEST" ] || die "dest is not a directory: $DEST"
case "$MAX_AGE" in
  ''|*[!0-9]*) die "--max-age-days must be a non-negative integer (got: $MAX_AGE)" ;;
esac
if [ -n "$SOURCE" ] && [ ! -d "$SOURCE" ]; then
  die "source is not a directory: $SOURCE"
fi

FAILURES=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# --- check 1: latest timestamped backup exists ------------------------------
latest=""
while IFS= read -r d; do
  case "$(basename "$d")" in
    ????-??-??_??????|????-??-??_??????_*) latest="$d" ;;
  esac
done < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)

if [ -z "$latest" ]; then
  fail "no timestamped backup (YYYY-MM-DD_HHMMSS) found in $DEST"
  printf 'RESULT: FAIL (%d check(s) failed)\n' "$FAILURES"
  exit 1
fi
pass "latest backup exists: $latest"

# --- check 2: age within max-age --------------------------------------------
now="$(date +%s)"
mtime="$(stat -c %Y "$latest")"
age_days=$(( (now - mtime) / 86400 ))
if [ "$age_days" -le "$MAX_AGE" ]; then
  pass "backup age ${age_days}d is within max-age ${MAX_AGE}d"
else
  fail "backup age ${age_days}d exceeds max-age ${MAX_AGE}d"
fi

# --- check 3: manifest present and well-formed --------------------------------
manifest="$latest/MANIFEST.txt"
m_files=""; m_bytes=""; m_rsync=""
if [ -f "$manifest" ]; then
  m_files="$(sed -n 's/^files=//p' "$manifest" | head -1)"
  m_bytes="$(sed -n 's/^bytes=//p' "$manifest" | head -1)"
  m_rsync="$(sed -n 's/^rsync_exit=//p' "$manifest" | head -1)"
fi
if [ -n "$m_files" ] && [ -n "$m_bytes" ] && [ -n "$m_rsync" ]; then
  pass "manifest present with files=$m_files bytes=$m_bytes rsync_exit=$m_rsync"
  if [ "$m_rsync" = "0" ]; then
    pass "manifest reports rsync_exit=0"
  else
    fail "manifest reports rsync_exit=$m_rsync (backup run had errors)"
  fi
else
  fail "manifest $manifest missing or malformed"
fi

# --- check 4: integrity ------------------------------------------------------
if [ -n "$SOURCE" ]; then
  # Spot-check: sha256 of up to SAMPLE_N files, source vs backup.
  checked=0; bad=0
  while IFS= read -r f; do
    # Quote the pattern so glob characters in $SOURCE are matched literally.
    src_prefix="${SOURCE%/}/"
    rel="${f#"$src_prefix"}"
    b="$latest/$rel"
    if [ ! -f "$b" ]; then
      printf '  missing in backup: %s\n' "$rel"; bad=$((bad + 1))
    elif [ "$(sha256sum < "$f")" != "$(sha256sum < "$b")" ]; then
      printf '  checksum MISMATCH: %s\n' "$rel"; bad=$((bad + 1))
    fi
    checked=$((checked + 1))
  done < <(find "$SOURCE" -type f 2>/dev/null | LC_ALL=C sort | head -n "$SAMPLE_N")
  if [ "$checked" -eq 0 ]; then
    fail "integrity spot-check: source contains no regular files to sample"
  elif [ "$bad" -eq 0 ]; then
    pass "integrity spot-check: $checked/$checked sampled file checksums match"
  else
    fail "integrity spot-check: $bad of $checked sampled files differ or are missing"
  fi
else
  # No source: compare manifest counts against actual counts in the backup.
  actual="$(find "$latest" -type f ! -name 'MANIFEST.txt' 2>/dev/null \
    | awk 'END {print NR+0}')"
  actual_bytes="$(find "$latest" -type f ! -name 'MANIFEST.txt' -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}')"
  if [ -n "$m_files" ] && [ "$actual" = "$m_files" ] && [ "$actual_bytes" = "$m_bytes" ]; then
    pass "manifest counts match actual backup contents (files=$actual bytes=$actual_bytes)"
  else
    fail "manifest counts (files=$m_files bytes=$m_bytes) != actual (files=$actual bytes=$actual_bytes)"
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  printf 'RESULT: PASS (all checks passed)\n'
  exit 0
else
  printf 'RESULT: FAIL (%d check(s) failed)\n' "$FAILURES"
  exit 1
fi
