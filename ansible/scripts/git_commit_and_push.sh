#!/usr/bin/env bash
# --------------------------------------------------------------
# HarborSonar – Commit & push helper (v1.0)
# * Uses `set -euo pipefail` for deterministic error handling
# * `read -r` prevents backslash mangling
# * Checks command success directly (no `$?` indirection)
# * All output goes to stdout; errors go to stderr
# --------------------------------------------------------------

set -euo pipefail
trap 'echo "❌ Git helper failed at line $LINENO" >&2; exit 1' ERR

# -----------------------------------------------------------------
# Prompt for a commit message – keep backslashes intact with -r
# -----------------------------------------------------------------
read -r -p "Enter commit message: " commit_message

# -----------------------------------------------------------------
# Stage all changes
# -----------------------------------------------------------------
echo "🔧 Staging all changes..."
if git add .; then
    echo "✅ Staged."
else
    echo "❌ Failed to stage changes." >&2
    exit 1
fi

# -----------------------------------------------------------------
# Commit with the supplied message
# -----------------------------------------------------------------
echo "📝 Committing changes with message: \"$commit_message\""
if git commit -m "$commit_message"; then
    echo "✅ Commit created."
else
    echo "❌ Commit failed (maybe nothing to commit)." >&2
    exit 1
fi

# -----------------------------------------------------------------
# Push to the main branch
# -----------------------------------------------------------------
echo "🚀 Pushing to 'main' branch..."
if git push origin main; then
    echo "✅ Push succeeded."
else
    echo "❌ Push failed." >&2
    exit 1
fi

echo "🎉 All steps completed successfully!"
