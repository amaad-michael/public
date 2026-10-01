#!/usr/bin/env bash
# --------------------------------------------------------------
# A. Michael Tatum – Commit & push helper (v1.1)
# * Uses `set -euo pipefail` for deterministic error handling
# * `read -r` prevents backslash mangling
# * Checks command success directly (no `$?` indirection)
# * All output goes to stdout; errors go to stderr
# * Pushes to the currently checked-out branch (never hardcodes main)
# * Asks for confirmation before pushing, as a reminder of where
#   the commits are going
# --------------------------------------------------------------

set -euo pipefail
trap 'echo "❌ Git helper failed at line $LINENO" >&2; exit 1' ERR

# -----------------------------------------------------------------
# Detect the currently checked-out branch
# -----------------------------------------------------------------
current_branch="$(git branch --show-current)"
if [[ -z "$current_branch" ]]; then
    echo "❌ Not on a branch (detached HEAD?) — aborting." >&2
    exit 1
fi
echo "📍 Current branch: $current_branch"

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
# Confirm before pushing – a reminder of where this is going
# -----------------------------------------------------------------
echo ""
echo "⚠️  About to push to: origin/$current_branch"
read -r -p "Push now? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "⏸️  Push cancelled. Commit is kept locally on '$current_branch'."
    exit 0
fi

# -----------------------------------------------------------------
# Push to the current branch
# -----------------------------------------------------------------
echo "🚀 Pushing to 'origin/$current_branch'..."
if git push origin "$current_branch"; then
    echo "✅ Push succeeded."
else
    echo "❌ Push failed." >&2
    exit 1
fi

echo "🎉 All steps completed successfully!"
