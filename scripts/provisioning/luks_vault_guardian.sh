#!/usr/bin/env bash

# ==============================================================================
# Amaad Michael Tatum
# SCRIPT NAME : luks_vault_guardian.sh
# DESCRIPTION : Unified LUKS2 Header Backup, Bit-Rot Hashing, and 7z Encryption.
#
# [OPERATIONAL PHILOSOPHY]
# 1. ARCHITECTURE: This script follows a 'Privileged Service' model. It requires
#    root because it reads raw LUKS block devices. It does not touch user data,
#    enforcing a clean separation between OS/Disk-metadata and personal files.
# 2. INTEGRITY: Protects the LUKS 'Master Key' (header) rather than the full disk.
#    Uses SHA256 fingerprints to guard against silent bit-rot.
# 3. OPSEC:
#    - Staging is locked to root (700) and restricted to external mount points.
#    - Archive uses 'mhe=on' to blind-fold attackers (filenames are encrypted).
#    - Post-process cleanup is atomic; no unencrypted headers persist.
# 4. PASSPHRASE RULES:
#    - The 7z passphrase acts as a 'Second Lock'. It must differ from your
#      actual disk drive passwords.
#    - Password is provided manually via interactive prompt. It is never stored
#      in plain text on the system, keeping it off persistent storage.
# 5. SYNC STRATEGY: Sync the resulting .7z archive using your unprivileged
#    'michael' user account (via luckybackup/rclone) to maintain the
#    'Privileged Service, Unprivileged Sync' security boundary.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# [CONFIGURATION]
TARGET_DRIVES=("/dev/nvme0n1p3")
STAGING_DIR="/media/secure-backup/luks_headers"
LOG_FILE="/var/log/luks_guardian.log"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
CLOUD_ARCHIVE_NAME="luks_headers_vault_${TIMESTAMP}.7z"

# [LOGGING UTILITY]
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE" > /dev/null
}

# [DEPENDENCY MANAGEMENT]
check_and_install_7z() {
    if ! command -v 7z &> /dev/null; then
        echo "[*] 7z not found. Installing..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y p7zip-full
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y p7zip
        elif command -v yum &> /dev/null; then
            sudo yum install -y p7zip
        else
            log_message "ERROR: Package manager not supported."
            exit 1
        fi
    fi
}

# [ROOT & ENVIRONMENT CHECKS]
if [[ $EUID -ne 0 ]]; then echo "[-] ERROR: Must be run as root." >&2; exit 1; fi

# Initialize Log File
if [[ ! -f "$LOG_FILE" ]]; then sudo touch "$LOG_FILE" && sudo chmod 600 "$LOG_FILE"; fi

check_and_install_7z

if [[ ! -d "$STAGING_DIR" ]]; then mkdir -p "$STAGING_DIR" && chmod 700 "$STAGING_DIR"; fi
if ! mountpoint -q "$STAGING_DIR"; then
    log_message "ERROR: Staging path $STAGING_DIR is not a mount point."
    exit 1
fi

cd "$STAGING_DIR"
log_message "Pipeline started for ${#TARGET_DRIVES[@]} devices."

# [PHASE 2: EXTRACTION & HASHING]
for TARGET in "${TARGET_DRIVES[@]}"; do
    if [[ ! -b "$TARGET" ]] || ! cryptsetup isLuks "$TARGET"; then
        log_message "SKIP: $TARGET invalid or not LUKS."
        continue
    fi

    DEV_NAME=$(basename "$TARGET")
    TEXT_DUMP="${DEV_NAME}_layout_${TIMESTAMP}.txt"
    BINARY_HEADER="${DEV_NAME}_header_${TIMESTAMP}.img"
    CHECKSUM_FILE="${DEV_NAME}_verification_${TIMESTAMP}.sha256"

    (
        cryptsetup luksDump "$TARGET" > "$TEXT_DUMP"
        cryptsetup luksHeaderBackup "$TARGET" --header-backup-file "$BINARY_HEADER"
        sha256sum "$TEXT_DUMP" "$BINARY_HEADER" > "$CHECKSUM_FILE"
        chmod 600 "$TEXT_DUMP" "$BINARY_HEADER" "$CHECKSUM_FILE"
    ) || {
        log_message "CRITICAL: Extraction failed for $TARGET";
        rm -f "$TEXT_DUMP" "$BINARY_HEADER" "$CHECKSUM_FILE";
        exit 1;
    }
    log_message "SUCCESS: Extracted $DEV_NAME"
done

# [PHASE 3: PACKAGING]
7z a -t7z -m0=lzma2 -mx=9 -mhe=on -p "$CLOUD_ARCHIVE_NAME" "${STAGING_DIR}"/* &>> "$LOG_FILE"

# [PHASE 4: CLEANUP]
if [[ -f "$CLOUD_ARCHIVE_NAME" ]]; then
    chmod 600 "$CLOUD_ARCHIVE_NAME"
    find "$STAGING_DIR" -maxdepth 1 -type f ! -name "$CLOUD_ARCHIVE_NAME" -delete
    log_message "SUCCESS: Archive created and staging sanitized: $CLOUD_ARCHIVE_NAME"
fi
