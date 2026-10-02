#!/usr/bin/env bash
# ==============================================================================
# Script: backup-integrity-cli.sh
# Purpose: Automates SHA256 manifest generation and cryptographic verification.
# ==============================================================================

# Bash Strict Mode Configuration
# -e: Exit immediately if any command returns a non-zero exit status.
# -u: Exit immediately if an uninitialized variable is referenced.
# -o pipefail: Ensure pipeline errors are not masked by the last command's success.
set -euo pipefail

# ------------------------------------------------------------------------------
# Function: usage
# Purpose: Displays help text and exits with an error code (1).
# ------------------------------------------------------------------------------
usage() {
    # 'cat <<EOF' initiates a heredoc, printing everything until the closing 'EOF'
    cat <<EOF
Usage: $(basename "$0") [COMMAND] [TARGET_DIRECTORY]

Commands:
  generate    Creates a manifest-YYYYMM.sha256 file for all files.
  verify      Verifies the directory against the most recent manifest-*.sha256.

Examples:
  $(basename "$0") generate /mnt/backup/infrastructure
  $(basename "$0") verify /mnt/backup/infrastructure
EOF
    exit 1
}

# ------------------------------------------------------------------------------
# Argument Validation & Initialization
# ------------------------------------------------------------------------------

# '$#' holds the number of arguments passed to the script.
# '-ne' evaluates to "not equal to".
if [[ $# -ne 2 ]]; then
    usage
fi

# Assign arguments to descriptive, read-only local variables for readability
readonly ACTION=$1
readonly TARGET_DIR=$2

# Directory state validation: Ensure the target actually exists and is a directory ('-d').
if [[ ! -d "$TARGET_DIR" ]]; then
    # '>&2' redirects standard output (stdout) to standard error (stderr).
    echo "FATAL: Directory '$TARGET_DIR' does not exist or is not mounted." >&2
    exit 1
fi

# Change execution context to the target directory.
# Due to 'set -e', if 'cd' fails (e.g., permissions), the script halts here.
cd "$TARGET_DIR"

# ------------------------------------------------------------------------------
# Core Logic Execution Routing
# ------------------------------------------------------------------------------
case "$ACTION" in
    generate)
        # Create a timestamp tag using 'date'. Format: YYYYMM (e.g., 202606)
        DATE_TAG=$(date +%Y%m)
        readonly DATE_TAG
        readonly MANIFEST="manifest-${DATE_TAG}.sha256"

        echo "INFO: Generating $MANIFEST for $TARGET_DIR..."

        # Pipeline breakdown:
        # 1. find . -type f : Locate all regular files recursively.
        # 2. ! -name "manifest-*.sha256" : Exclude existing/current manifests to prevent hashing the hash file.
        # 3. -print0 : Delimit output with null characters (\0) instead of newlines.
        # 4. xargs -0 : Read null-delimited input. This securely handles filenames with spaces or special characters.
        # 5. > "$MANIFEST" : Write standard output to the designated manifest file.
        find . -type f ! -name "manifest-*.sha256" -print0 | xargs -0 sha256sum > "$MANIFEST"

        echo "SUCCESS: Manifest written to ${TARGET_DIR}/${MANIFEST}"
        ;;

    verify)
        # Locate the most recent manifest.
        # maxdepth 1 prevents searching subdirectories for old manifests.
        # sort -r reverses the sort (newest at the top).
        # head -n 1 extracts only the top result.
        MANIFEST=$(find . -maxdepth 1 -name "manifest-*.sha256" | sort -r | head -n 1)

        # '-z' checks if the string length is zero (empty variable).
        if [[ -z "$MANIFEST" ]]; then
            echo "FATAL: No manifest-*.sha256 found in $TARGET_DIR." >&2
            exit 1
        fi

        echo "INFO: Executing integrity check against $MANIFEST..."

        # 'sha256sum -c' reads the manifest and checks the files.
        # '--quiet' suppresses the "OK" output for every single file, only printing failures.
        # The 'if' statement evaluates the native exit code of the sha256sum command.
        if sha256sum --quiet -c "$MANIFEST"; then
            echo "SUCCESS: Cryptographic integrity check passed. No silent corruption detected."
        else
            echo "FATAL: Integrity check failed. Delta drift or corruption detected." >&2
            exit 1
        fi
        ;;

    *)
        # Catch-all for invalid commands
        usage
        ;;
esac
