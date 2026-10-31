#!/usr/bin/env bash
#
# NAME: new-box-prep-v1.2.sh
# WHAT: The single new-box workflow. Runs this repo's prep scripts in
#       order for a laptop or a server, with GPU tuning as an
#       optional final step (the only delta for a gaming rig):
#         laptop: git setup, ssh setup, laptop role prep,
#                 optional GPU step
#         server: secure-server-init (conservative, the named
#                 server leg), git setup for the michael user,
#                 then the controller-side follow-ons are printed
#       A laptop run also carries a designation, work or personal:
#       the laptop role prep runs only on a work box, and a
#       personal box skips it. The designation comes from --work
#       or --personal; with neither flag the runner asks on the
#       terminal, and with no terminal and no flag it stops and
#       runs nothing, so a scripted run must pass the flag.
# WHY:  One entry point replaces remembering which scripts run in
#       which order on which kind of box (prep scripting audit,
#       2026-10-29). Every step is one of the repo's existing
#       scripts, each idempotent and runnable on its own; this
#       runner only sequences them.
# HOW:  ./new-box-prep-v1.2.sh laptop|server [--work|--personal]
#       [--with-gpu] [--dry-run]
#       Run it from inside a clone of this repo; sibling scripts
#       are resolved relative to this file and the newest version
#       of each wins. --dry-run prints the resolved plan and runs
#       nothing. Run the server form as root on the target; a
#       server run takes no designation. The laptop role prep
#       runs under sudo (it requires root); the git and ssh setup
#       steps run as the invoking user. A step that exits nonzero
#       stops the workflow: it names the failed step, exits
#       nonzero itself, and never prints the done footer.
set -uo pipefail

usage() {
    echo "usage: $0 laptop|server [--work|--personal] [--with-gpu] [--dry-run]" >&2
    exit 2
}

ROLE="${1:-}"
[[ "$ROLE" == "laptop" || "$ROLE" == "server" ]] || usage
shift

BOX_KIND=""
WITH_GPU=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --work)
            [[ -z "$BOX_KIND" ]] || usage
            BOX_KIND="work"
            ;;
        --personal)
            [[ -z "$BOX_KIND" ]] || usage
            BOX_KIND="personal"
            ;;
        --with-gpu) WITH_GPU=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) usage ;;
    esac
done

if [[ "$ROLE" == "server" && -n "$BOX_KIND" ]]; then
    echo "the work/personal designation is for laptops; a server run does not take one" >&2
    usage
fi

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
    local desc="$1"
    STEP=$((STEP + 1))
    echo ""
    echo "=== Step $STEP: $desc ==="
    shift
    echo "  $*"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! "$@"; then
            echo "FAILED: step $STEP ($desc) exited nonzero; workflow stopped." >&2
            exit 1
        fi
    fi
}

if [[ "$ROLE" == "laptop" ]]; then
    if [[ -z "$BOX_KIND" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Is this laptop a work box or a personal box? [work/personal]: " reply || reply=""
            BOX_KIND="${reply,,}"
        fi
    fi
    if [[ "$BOX_KIND" != "work" && "$BOX_KIND" != "personal" ]]; then
        echo "a laptop run needs a designation: pass --work or --personal, or answer the prompt on a terminal; nothing was run" >&2
        exit 2
    fi
    require "git setup" "$GIT_SETUP"
    require "ssh setup" "$SSH_SETUP"
    if [[ "$BOX_KIND" == "work" ]]; then
        require "laptop role prep" "$ROLE_PREP"
    fi
    echo "New-box workflow: laptop ($BOX_KIND box)"
    run_step "git setup (identity, defaults, efficiency settings)" bash "$REPO_ROOT/scripts/git/$GIT_SETUP"
    run_step "ssh setup (keychain, keypair, keys to the fleet)" bash "$REPO_ROOT/scripts/security/$SSH_SETUP"
    if [[ "$BOX_KIND" == "work" ]]; then
        run_step "laptop role prep (accounts, tooling, gh, hardening)" sudo bash "$REPO_ROOT/scripts/workstation/$ROLE_PREP"
    else
        echo ""
        echo "Skipping laptop role prep: this box is designated personal;"
        echo "the role prep runs on work boxes only."
    fi
    if [[ "$WITH_GPU" -eq 1 ]]; then
        require "GPU step" "$GPU_STEP"
        run_step "GPU tuning (optional final step; skips without a discrete AMD GPU)" sudo bash "$REPO_ROOT/scripts/workstation/$GPU_STEP" gpu-high
    fi
    echo ""
    if [[ "$BOX_KIND" == "work" ]]; then
        echo "Workflow done. Remaining manual items are the ones the role"
        echo "prep printed (vendor sign-ins, gh auth login, LUKS recovery"
        echo "key into Proton Pass, a tested restore)."
    else
        echo "Workflow done. This box is designated personal, so the role"
        echo "prep did not run and printed no manual list; re-run with"
        echo "--work if the box takes a work role later."
    fi
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
