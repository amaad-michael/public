#!/usr/bin/env bash
#
# NAME: git-setup-new-box-v1.1.sh
# WHAT: Applies Michael's standard global git config on a new Linux box:
#       identity, nano editor, global ignore file, main default branch,
#       merge-on-pull, fetch prune, push autoSetupRemote, and the
#       efficient-work settings (recency-sorted branches, histogram
#       diffs, zdiff3 conflicts, rerere). Reports whether the GitHub
#       CLI is installed; installing and signing in to it are setup
#       steps, not config, and stay out of this script.
# WHY:  Every new box gets the same git behavior without re-deriving the
#       settings by hand.
# HOW:  ./git-setup-new-box-v1.1.sh
#       Idempotent: safe to re-run; an existing global ignore file is kept.
set -euo pipefail

# --- Identity ---
git config --global user.name "A. Michael Tatum"
git config --global user.email "amaad.michael@gmail.com"

# --- Editor and global ignores ---
git config --global core.editor "nano"
git config --global core.excludesfile "$HOME/git/.gitignore_global"

# --- Sensible defaults ---
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global color.ui auto
git config --global push.autoSetupRemote true
git config --global fetch.prune true

# --- Efficient-work settings ---
# Listings sorted the way a landing session thinks: recent branches
# first, version tags in version order, columns when the terminal fits.
git config --global branch.sort -committerdate
git config --global tag.sort -version:refname
git config --global column.ui auto
# Review-quality diffs: the histogram algorithm, moved code shown as
# moves, and conflict blocks that include the base version for context.
git config --global diff.algorithm histogram
git config --global diff.colorMoved default
git config --global merge.conflictstyle zdiff3
# Reuse recorded conflict resolutions across merges, and never let a
# CRLF line ending slip into a commit from a Linux box.
git config --global rerere.enabled true
git config --global core.autocrlf input

# --- Global ignore file: create only if missing, never clobber ---
IGNORE_FILE="$HOME/git/.gitignore_global"
if [[ ! -f "$IGNORE_FILE" ]]; then
    mkdir -p "$(dirname "$IGNORE_FILE")"
    cat > "$IGNORE_FILE" <<'EOF'
# OS / editor noise
.DS_Store
*~
*.swp
*.swo
.vscode/
.idea/
# Build / dependency dirs
node_modules/
__pycache__/
*.pyc
# Logs
*.log
EOF
    echo "created $IGNORE_FILE"
else
    echo "kept existing $IGNORE_FILE"
fi

# --- Optional: credential helper (uncomment ONE) ---
# With the GitHub CLI authenticated, wire git to it for HTTPS instead:
# gh auth setup-git
# Linux HTTPS auth without gh — pick the one you use on this box:
# git config --global credential.helper cache
# git config --global credential.helper store

# --- Optional: SSH commit signing (uncomment and set your key) ---
# git config --global user.signingkey "ssh-ed25519 AAAA..."
# git config --global gpg.format ssh
# git config --global commit.gpgsign true

# --- GitHub CLI: report only ---
if command -v gh >/dev/null 2>&1; then
    echo "gh installed: $(gh --version | head -1)"
    echo "gh sign-in is once per box: gh auth login (then gh auth status)"
else
    echo "gh not installed: the laptop role-prep setup script installs it,"
    echo "or see https://cli.github.com for this distro's package route"
fi

echo "--- git global config ---"
git config --global --list | sort
