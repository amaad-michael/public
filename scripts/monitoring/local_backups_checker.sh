#!/usr/bin/env bash
#
# backup_check.sh – Create a SHA‑256 manifest and/or verify file integrity.
#
# Usage:
#   # 1️⃣  Create a manifest (run on the *source* side)
#   ./backup_check.sh --generate [-o manifest_name]
#
#   # 2️⃣  Verify a manifest (run on the *destination* side)
#   ./backup_check.sh --verify [-m manifest_name]
#
#   # 3️⃣  Do both in one go (useful for quick sanity checks)
#   ./backup_check.sh --generate-and-verify [-o manifest_name]
#
# Options:
#   -o <file>   Output manifest name (default: backup.manifest)
#   -m <file>   Manifest to verify (default: backup.manifest)
#
# The script writes a timestamped log file (verify_YYYYMMDD_HHMMSS.log)
# and returns:
#   0 – everything OK
#   1 – one or more files missing / corrupted
#   2 – usage error / missing manifest for verification
#
# ---------------------------------------------------------------

set -euo pipefail

# ---------- Default values ----------
MANIFEST="backup.manifest"
ACTION=""   # will hold "generate", "verify", or "both"

# ---------- Helper functions ----------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}
die() {
    log "ERROR: $*"
    exit 2
}
show_help() {
    grep '^#' "$0" | sed -e 's/^# //;s/^#//'
    exit 0
}

# ---------- Parse arguments ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --generate)
            ACTION="generate"
            shift
            ;;
        --verify)
            ACTION="verify"
            shift
            ;;
        --generate-and-verify)
            ACTION="both"
            shift
            ;;
        -o)
            MANIFEST="$2"
            shift 2
            ;;
        -m)
            MANIFEST="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ -n "$ACTION" ]] || die "You must specify --generate, --verify or --generate-and-verify"

# ---------- Logging ----------
LOGFILE="verify_$(date +%Y%m%d_%H%M%S).log"
log "=== START $(basename "$0") ==="
log "Action      : $ACTION"
log "Manifest    : $MANIFEST"

# ---------- 1️⃣  Manifest generation ----------
if [[ "$ACTION" == "generate" || "$ACTION" == "both" ]]; then
    log "Generating manifest ..."
    # The manifest contains relative paths (starting with ./) so it works
    # regardless of where you later run the verification.
    #
    #   find . -type f -print0 | xargs -0 sha256sum > backup.manifest
    #
    # Using `-print0` + `xargs -0` guarantees correct handling of
    # whitespace, newlines, and Unicode characters in filenames.
    # Exclude the manifest itself and this run's verify log: both change as
    # the script runs, so hashing them guarantees a CORRUPT verdict.
    find . -type f -not -name "$(basename "$MANIFEST")" -not -name 'verify_*.log' -print0 | xargs -0 sha256sum > "$MANIFEST"
    log "Manifest written to $MANIFEST ($(wc -l <"$MANIFEST") entries)"
fi

# ---------- 2️⃣  Verification ----------
if [[ "$ACTION" == "verify" || "$ACTION" == "both" ]]; then
    # Make sure the manifest exists before we start checking.
    [[ -f "$MANIFEST" ]] || die "Manifest file '$MANIFEST' not found – cannot verify"

    log "Starting integrity verification ..."
    FAILURES=0

    while IFS= read -r line; do
        # Each line looks like: <sha256>  <relative_path>
        checksum=$(echo "$line" | awk '{print $1}')
        relpath=$(echo "$line" | cut -d' ' -f3-)

        # Skip empty lines (possible trailing newline)
        [[ -z "$relpath" ]] && continue

        if [[ ! -e "$relpath" ]]; then
            log "MISSING: $relpath"
            ((FAILURES++))
            continue
        fi

        computed=$(sha256sum "$relpath" | awk '{print $1}')
        if [[ "$computed" != "$checksum" ]]; then
            log "CORRUPT: $relpath"
            ((FAILURES++))
        else
            # Uncomment the next line if you want per‑file OK messages
            # log "OK: $relpath"
            :
        fi
    done < "$MANIFEST"

    if (( FAILURES == 0 )); then
        log "✅ Verification succeeded – all files match the manifest."
        RESULT=0
    else
        log "❌ Verification failed – $FAILURES problem(s) detected."
        RESULT=1
    fi
else
    # If we only generated a manifest, we consider that a success.
    RESULT=0
fi

log "=== END $(basename "$0") ==="
exit $RESULT
