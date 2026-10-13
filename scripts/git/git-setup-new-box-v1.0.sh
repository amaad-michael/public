#!/usr/bin/env bash
#
# NAME: git-setup-new-box-v1.0.sh
# WHAT: Applies Michael's standard global git config on a new Linux box:
#       identity, nano editor, global ignore file, main default branch,
#       merge-on-pull, fetch prune, and push autoSetupRemote.
# WHY:  Every new box gets the same git behavior without re-deriving the
#       settings by hand.
# HOW:  ./git-setup-new-box-v1.0.sh
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
# Linux HTTPS auth — pick the one you use on this box:
# git config --global credential.helper cache
# git config --global credential.helper store

# --- Optional: SSH commit signing (uncomment and set your key) ---
# git config --global user.signingkey "ssh-ed25519 AAAA..."
# git config --global gpg.format ssh
# git config --global commit.gpgsign true

echo "--- git global config ---"
git config --global --list | sort
