#!/usr/bin/env bash
#
# NAME: new-box-prep-v1.0.sh
# WHAT: The single new-box workflow. Runs this repo's prep scripts in
#       order for a laptop or a server, with GPU tuning as an
#       optional final step (the only delta for a gaming rig):
#         laptop: git setup, ssh setup, laptop role prep,
#                 optional GPU step
#         server: secure-server-init (conservative, the named
#                 server leg), git setup for the michael user,
#                 then the controller-side follow-ons are printed
# WHY:  One entry point replaces remembering which scripts run in
#       which order on which kind of box (prep scripting audit,
#       2026-10-29). Every step is one of the repo's existing
#       scripts, each idempotent and runnable on its own; this
#       runner only sequences them.
# HOW:  ./new-box-prep-v1.0.sh laptop|server [--with-gpu] [--dry-run]
#       Run it from inside a clone of this repo; sibling scripts
#       are resolved relative to this file and the newest version
#       of each wins. --dry-run prints the resolved plan and runs
#       nothing. Run the server form as root on the target.
set -uo pipefail

usage() {
    echo "usage: $0 laptop|server [--with-gpu] [--dry-run]" >&2
    exit 2
}

ROLE="${1:-}"
[[ "$ROLE" == "laptop" || "$ROLE" == "server" ]] || usage
shift

WITH_GPU=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --with-gpu) WITH_GPU=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) usage ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

newest() {
    find "$REPO_ROOT/$1" -maxdepth 1 -name "$2" -printf '%f\n' 2>/dev/null | sort -V | tail -n 1
}

require() {
    if [[ -z "$2" ]]; then
        echo "missing step script: $1 (looked in $REPO_ROOT)" >&2
        exit 1
    fi
}

GIT_SETUP="$(newest scripts/git 'git-setup-new-box-v*.sh')"
SSH_SETUP="$(newest scripts/security 'ssh-setup-new-box-v*.sh')"
ROLE_PREP="$(newest scripts/workstation 'laptop-role-prep-setup-v*.sh')"
SERVER_INIT="$(newest scripts/security 'secure-server-init-conservative-v*.sh')"
GPU_STEP="$(newest scripts/workstation 'new-nobara-setup-v*.sh')"

STEP=0
run_step() {
    STEP=$((STEP + 1))
    echo ""
    echo "=== Step $STEP: $1 ==="
    shift
    echo "  $*"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        "$@"
    fi
}

if [[ "$ROLE" == "laptop" ]]; then
    require "git setup" "$GIT_SETUP"
    require "ssh setup" "$SSH_SETUP"
    require "laptop role prep" "$ROLE_PREP"
    echo "New-box workflow: laptop"
    run_step "git setup (identity, defaults, efficiency settings)" bash "$REPO_ROOT/scripts/git/$GIT_SETUP"
    run_step "ssh setup (keychain, keypair, keys to the fleet)" bash "$REPO_ROOT/scripts/security/$SSH_SETUP"
    run_step "laptop role prep (accounts, tooling, gh, hardening)" bash "$REPO_ROOT/scripts/workstation/$ROLE_PREP"
    if [[ "$WITH_GPU" -eq 1 ]]; then
        require "GPU step" "$GPU_STEP"
        run_step "GPU tuning (optional final step; skips without a discrete AMD GPU)" sudo bash "$REPO_ROOT/scripts/workstation/$GPU_STEP" gpu-high
    fi
    echo ""
    echo "Workflow done. Remaining manual items are the ones the role"
    echo "prep printed (vendor sign-ins, gh auth login, LUKS recovery"
    echo "key into Proton Pass, a tested restore)."
else
    require "server init" "$SERVER_INIT"
    require "git setup" "$GIT_SETUP"
    if [[ "$DRY_RUN" -eq 0 && "$EUID" -ne 0 ]]; then
        echo "the server workflow runs as root on the target; re-run with sudo" >&2
        exit 1
    fi
    echo "New-box workflow: server"
    run_step "server init, conservative leg (users, SSH hardening, journal, time sync, hosts, MOTD)" bash "$REPO_ROOT/scripts/security/$SERVER_INIT"
    run_step "git setup for the michael user" sudo -u michael -H bash "$REPO_ROOT/scripts/git/$GIT_SETUP"
    if [[ "$WITH_GPU" -eq 1 ]]; then
        echo ""
        echo "GPU step requested for a server: skipped (the GPU step is a workstation delta)."
    fi
    echo ""
    echo "On-box steps done. Controller-side follow-ons, run from pi1:"
    echo "  1. Set the trio passwords: scripts/security/cycle-fleet-passwords.sh"
    echo "     with the vault vars file (root, michael, ansible for this host)."
    echo "  2. Add the host to monitoring: the node_exporter fleet rollout"
    echo "     playbook (ansible/playbooks/monitoring/)."
    echo "  3. Run the first audit on the box: sudo lynis audit system"
fi
