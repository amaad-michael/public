# Backup Integrity CLI (backup-integrity-cli.sh)

A cryptographic integrity tool designed to lock and validate the state of backup directories. It provides a deterministic method to detect silent data corruption, bit rot, or delta drift on storage media over time.

## Architecture Workflow

This script is designed to operate distinctly from your synchronization engine (e.g., rsync or LuckyBackup).

1. Sync Phase: Duplicate data to the backup medium (e.g., rsync -avh --delete).
1. Lock Phase (generate): Run this script immediately after syncing to calculate the mathematical hash of every file and establish a cryptographic baseline.
1. Audit Phase (verify): Run this script during routine maintenance to recalculate the hashes and ensure they match the baseline perfectly, proving no bit rot has occurred.

---

## Installation

Save the script to a secure execution path (e.g., /usr/local/bin/ or /opt/scripts/) and make it executable:

chmod +x backup-integrity-cli.sh

---

## Usage

./backup-integrity-cli.sh [COMMAND] [TARGET_DIRECTORY]

### Commands

* generate: Recursively scans the target directory and creates a timestamped manifest-YYYYMM.sha256 file at the root of the target. Excludes existing manifests to prevent recursive hashing errors.
* verify: Locates the most recent manifest-*.sha256 file at the root of the target directory and recalculates all hashes to ensure cryptographic integrity.

---

## Examples

### 1. Generating a Manifest (Locking State)

Execute this against a newly synced drive to lock in its state:

/opt/scripts/backup-integrity-cli.sh generate /mnt/offsite-drive

Result: Creates /mnt/offsite-drive/manifest-YYYYMM.sha256 containing the hashes of all files.

### 2. Verifying a Manifest (Auditing State)

Execute this during your semiannual rotation to audit a drive:

/opt/scripts/backup-integrity-cli.sh verify /mnt/offsite-drive

Result: Silently checks all files. Prints a success message if perfect, or a fatal error if even a single bit has flipped.

---

## Exit Codes

Designed for pipeline and cron compatibility, the script relies strictly on standard exit codes:

* 0 (Success): Operations completed successfully. Manifest generated, or all files passed the cryptographic integrity check.
* 1 (Fatal Error): Operation aborted. Caused by a missing target directory, missing manifest file, unreadable files, or a failed cryptographic check (corruption detected).
