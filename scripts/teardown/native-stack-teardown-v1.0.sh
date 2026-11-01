#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Native Stack Teardown — v1.0 (manifest-driven)
# ═══════════════════════════════════════════════════════════════════════════
# Removes a natively installed stack (systemd units, files, service
# accounts) from this host. Everything stack-specific lives in a small
# MANIFEST file under manifests/ next to this script: the unit names,
# the paths to remove, the data paths to preserve, the service account.
# Adding a stack means writing a manifest, not a new script. (The two
# LLM stacks predate this engine and keep their own dedicated scripts
# under scripts/llm/; everything else native uses this one.)
#
# READ THIS BEFORE A REAL RUN
#   - Run with --dry-run first. It prints the complete plan with every
#     path labeled REMOVE or PRESERVED, and changes nothing.
#   - A real run asks you to type the stack's confirmation word (shown
#     in the plan) before anything is touched.
#   - PRESERVED paths hold the stack's data (repositories, models,
#     databases). They survive a default run. --purge removes them,
#     plus the service account. There is no undo for --purge.
#   - --wipe-data makes data removal a separate FINAL step instead:
#     the teardown runs normally, and only after it verifies clean
#     does the script list the data paths and accounts again and ask
#     you to type "wipe" before deleting them. Declining costs
#     nothing; the teardown result stands either way.
#   - Redeploying afterwards is the stack's own setup script; the plan
#     prints which one, and so does the closing summary.
#   - Every action is logged to /var/log/native-stack-teardown-<stack>.log
#     as it happens, in plain language.
#
# Usage:
#   sudo ./native-stack-teardown-v1.0.sh <manifest> [--dry-run] [--purge] [--wipe-data]
#
# <manifest> is a name from manifests/ (gitea, nanopi-llm) or a path to
# a manifest file. Exit codes: 0 clean (including nothing-to-do),
# 1 aborted or verification found leftovers, 2 usage/environment error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

DRY_RUN="no"
PURGE="no"
WIPE_DATA="no"
MANIFEST_ARG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="yes" ;;
        --purge)   PURGE="yes" ;;
        --wipe-data) WIPE_DATA="yes" ;;
        --help|-h)
            echo "Usage: sudo $0 <manifest> [--dry-run] [--purge] [--wipe-data]"
            exit 0
            ;;
        -*)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
        *)
            if [[ -n "$MANIFEST_ARG" ]]; then
                echo "Only one manifest may be given." >&2
                exit 2
            fi
            MANIFEST_ARG="$arg"
            ;;
    esac
done

if [[ -z "$MANIFEST_ARG" ]]; then
    echo "Usage: sudo $0 <manifest> [--dry-run] [--purge] [--wipe-data]" >&2
    exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root (sudo): it removes systemd units and service accounts." >&2
    exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MANIFEST_FILE=""
if [[ -f "$MANIFEST_ARG" ]]; then
    MANIFEST_FILE="$MANIFEST_ARG"
elif [[ -f "$SCRIPT_DIR/manifests/$MANIFEST_ARG.manifest" ]]; then
    MANIFEST_FILE="$SCRIPT_DIR/manifests/$MANIFEST_ARG.manifest"
else
    echo "Manifest not found: $MANIFEST_ARG" >&2
    echo "Available manifests:" >&2
    find "$SCRIPT_DIR/manifests" -maxdepth 1 -name '*.manifest' -printf '%f\n' 2>/dev/null | sed 's/\.manifest$//' >&2
    exit 2
fi

# Manifest contract (all set by the manifest file):
#   STACK_NAME, CONFIRM_TOKEN, STACK_DESC, REDEPLOY_HINT
#   UNITS=()          systemd unit base names the stack installed
#   REMOVE_PATHS=()   files and directories always removed
#   PRESERVE_PATHS=() data paths kept on a default run (labeled in plan)
#   PURGE_PATHS=()    extra paths removed only under --purge
#   USERS=() REMOVE_GROUPS=() service accounts removed only under --purge
#   NOTES=()          plain-language notes printed in the plan
STACK_NAME=""
CONFIRM_TOKEN=""
STACK_DESC=""
REDEPLOY_HINT=""
UNITS=()
REMOVE_PATHS=()
PRESERVE_PATHS=()
PURGE_PATHS=()
USERS=()
REMOVE_GROUPS=()
NOTES=()
# shellcheck disable=SC1090
source "$MANIFEST_FILE"

if [[ -z "$STACK_NAME" || -z "$CONFIRM_TOKEN" ]]; then
    echo "Manifest $MANIFEST_FILE is incomplete (STACK_NAME and CONFIRM_TOKEN are required)." >&2
    exit 2
fi

LOG_FILE="/var/log/native-stack-teardown-${STACK_NAME}.log"
FAILURES=0

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

act() {
    local label="$1"
    shift
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "  WOULD $label"
        return 0
    fi
    log "  DO    $label"
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        log "  !! FAILED: $label"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    return 0
}

# Soft action: like act, but a failure is expected in one known case
# (systemctl operations that need a running systemd bus, e.g. inside a
# container or rescue shell) and the end state is verified in step 5
# anyway. Logged plainly, never counted as a failure.
act_soft() {
    local label="$1"
    shift
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "  WOULD $label"
        return 0
    fi
    log "  DO    $label"
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        log "  note: '$label' reported an error. This is expected when"
        log "        systemd is not running (container, rescue shell); the"
        log "        end state is what matters and step 5 verifies it."
    fi
    return 0
}

rm_labeled() {
    local p="$1"
    if [[ -e "$p" || -L "$p" ]]; then
        act "remove $p" rm -rf -- "$p"
    else
        log "  skip  $p (already absent)"
    fi
}

unit_file() {
    case "$1" in
        *.service|*.timer|*.socket|*.mount|*.target|*.path|*.slice) printf '%s' "$1" ;;
        *) printf '%s.service' "$1" ;;
    esac
}

unit_present() {
    local f; f="$(unit_file "$1")"
    [[ -e "/etc/systemd/system/$f" || -L "/etc/systemd/system/$f" ]]
}

# ───────────────────────────────────────────────────────────────────────────
# The plan: everything this run will and will not touch, labeled
# ───────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "Native stack teardown v1.0: $STACK_NAME"
log "$STACK_DESC"
log "Mode: dry-run=$DRY_RUN purge=$PURGE wipe-data=$WIPE_DATA"
log ""
log "Step 1 of 5 will stop and disable these systemd units:"
if [[ "${#UNITS[@]}" -gt 0 ]]; then
    for u in "${UNITS[@]}"; do log "  UNIT      $u"; done
else
    log "  (none)"
fi
log "Step 2 of 5 removes the stack's unit files and their enable links."
log "Step 3 of 5 removes these installed files and directories:"
if [[ "${#REMOVE_PATHS[@]}" -gt 0 ]]; then
    for p in "${REMOVE_PATHS[@]}"; do log "  REMOVE    $p"; done
else
    log "  (none)"
fi
if [[ "${#PRESERVE_PATHS[@]}" -gt 0 ]]; then
    if [[ "$PURGE" == "yes" ]]; then
        log "These data paths are removed too, because --purge was given:"
        for p in "${PRESERVE_PATHS[@]}"; do log "  PURGE     $p"; done
    elif [[ "$WIPE_DATA" == "yes" ]]; then
        log "These data paths are PRESERVED during the teardown and removed"
        log "in the final wipe step (separately confirmed):"
        for p in "${PRESERVE_PATHS[@]}"; do log "  WIPE      $p"; done
    else
        log "These data paths are PRESERVED (kept for a redeploy):"
        for p in "${PRESERVE_PATHS[@]}"; do log "  PRESERVED $p"; done
        log "Rerun with --purge if you want them gone as well."
    fi
fi
if [[ "$PURGE" == "yes" && "${#PURGE_PATHS[@]}" -gt 0 ]]; then
    log "Also removed under --purge:"
    for p in "${PURGE_PATHS[@]}"; do log "  PURGE     $p"; done
fi
if [[ "$PURGE" == "yes" && "${#USERS[@]}" -gt 0 ]]; then
    log "Step 4 of 5 also removes the service account(s): ${USERS[*]}"
else
    log "Step 4 of 5: service accounts are kept (they are removed only under --purge)."
fi
log "Step 5 of 5 verifies nothing targeted is left behind."
if [[ "$WIPE_DATA" == "yes" ]]; then
    log "Final step (optional): wipe the preserved data and service accounts,"
    log "separately confirmed after step 5 verifies clean."
fi
if [[ "${#NOTES[@]}" -gt 0 ]]; then
    log ""
    log "Notes for this stack:"
    for n in "${NOTES[@]}"; do log "  NOTE  $n"; done
fi
log "To redeploy afterwards: $REDEPLOY_HINT"
log ""

if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Type $CONFIRM_TOKEN to confirm this teardown:"
    CONFIRM=""
    if ( exec 9</dev/tty ) 2>/dev/null; then
        read -r CONFIRM < /dev/tty || CONFIRM=""
    else
        read -r CONFIRM || CONFIRM=""
    fi
    if [[ "$CONFIRM" != "$CONFIRM_TOKEN" ]]; then
        log "Aborted: confirmation not given. Nothing was removed."
        exit 1
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 1: stop and disable the units
# ───────────────────────────────────────────────────────────────────────────

log "Step 1 of 5: stopping and disabling units"
for u in "${UNITS[@]}"; do
    if unit_present "$u"; then
        act_soft "disable and stop $u" systemctl disable --now "$(unit_file "$u")"
    else
        log "  skip  $u (unit file absent)"
    fi
done

# ───────────────────────────────────────────────────────────────────────────
# Step 2: unit files and enable links
# ───────────────────────────────────────────────────────────────────────────

log "Step 2 of 5: removing unit files and enable links"
for u in "${UNITS[@]}"; do
    rm_labeled "/etc/systemd/system/$(unit_file "$u")"
    for wants in /etc/systemd/system/*.wants; do
        [[ -d "$wants" ]] || continue
        rm_labeled "$wants/$(unit_file "$u")"
    done
done
act_soft "reload systemd manager configuration" systemctl daemon-reload

# ───────────────────────────────────────────────────────────────────────────
# Step 3: installed files (and data paths, under --purge)
# ───────────────────────────────────────────────────────────────────────────

log "Step 3 of 5: removing installed files"
for p in "${REMOVE_PATHS[@]}"; do
    rm_labeled "$p"
done
if [[ "$PURGE" == "yes" ]]; then
    for p in "${PRESERVE_PATHS[@]}" "${PURGE_PATHS[@]}"; do
        rm_labeled "$p"
    done
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 4: service accounts (only under --purge)
# ───────────────────────────────────────────────────────────────────────────

log "Step 4 of 5: service accounts"
if [[ "$PURGE" == "yes" ]]; then
    for usr in "${USERS[@]}"; do
        if id "$usr" &>/dev/null; then
            act "remove user $usr" userdel "$usr"
        else
            log "  skip  user $usr (absent)"
        fi
    done
    for grp in "${REMOVE_GROUPS[@]}"; do
        if getent group "$grp" &>/dev/null; then
            act "remove group $grp" groupdel "$grp"
        else
            log "  skip  group $grp (absent)"
        fi
    done
else
    log "  kept (rerun with --purge to remove them)"
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 5: verification, then the closing summary in plain language
# ───────────────────────────────────────────────────────────────────────────

log "Step 5 of 5: verifying the teardown"
LEFT=0
if [[ "$DRY_RUN" != "yes" ]]; then
    for u in "${UNITS[@]}"; do
        if unit_present "$u"; then
            log "  STILL PRESENT unit: $u"
            LEFT=$((LEFT + 1))
        fi
    done
    for p in "${REMOVE_PATHS[@]}"; do
        if [[ -e "$p" || -L "$p" ]]; then
            log "  STILL PRESENT: $p"
            LEFT=$((LEFT + 1))
        fi
    done
    if [[ "$PURGE" == "yes" ]]; then
        for p in "${PRESERVE_PATHS[@]}" "${PURGE_PATHS[@]}"; do
            if [[ -e "$p" || -L "$p" ]]; then
                log "  STILL PRESENT: $p"
                LEFT=$((LEFT + 1))
            fi
        done
        for usr in "${USERS[@]}"; do
            if id "$usr" &>/dev/null; then
                log "  STILL PRESENT user: $usr"
                LEFT=$((LEFT + 1))
            fi
        done
    fi
fi


# ───────────────────────────────────────────────────────────────────────────
# Optional final step: wipe the preserved data (--wipe-data)
# Runs only when the teardown itself verified clean. Declining the
# second confirmation leaves the data in place and is not a failure.
# ───────────────────────────────────────────────────────────────────────────

WIPED_DATA=0
WIPE_LEFT=0
if [[ "$WIPE_DATA" == "yes" && "$DRY_RUN" != "yes" ]]; then
    if [[ "$FAILURES" -gt 0 || "$LEFT" -gt 0 ]]; then
        log "Final wipe step SKIPPED: the teardown did not complete cleanly,"
        log "so the data is left untouched. Fix the teardown first."
    else
        WIPE_TARGETS=()
        for p in "${PRESERVE_PATHS[@]}" "${PURGE_PATHS[@]}"; do
            if [[ -e "$p" || -L "$p" ]]; then
                WIPE_TARGETS+=("$p")
            fi
        done
        WIPE_USERS=()
        for usr in "${USERS[@]}"; do
            if id "$usr" &>/dev/null; then
                WIPE_USERS+=("$usr")
            fi
        done
        WIPE_GROUPS=()
        for grp in "${REMOVE_GROUPS[@]}"; do
            if getent group "$grp" &>/dev/null; then
                WIPE_GROUPS+=("$grp")
            fi
        done
        if [[ "${#WIPE_TARGETS[@]}" -eq 0 && "${#WIPE_USERS[@]}" -eq 0 && "${#WIPE_GROUPS[@]}" -eq 0 ]]; then
            log "Final wipe step: no data paths or accounts remain to wipe."
        else
            log "Final step: wipe the preserved data"
            for p in "${WIPE_TARGETS[@]}"; do log "  WIPE      $p"; done
            for usr in "${WIPE_USERS[@]}"; do log "  WIPE      user $usr"; done
            for grp in "${WIPE_GROUPS[@]}"; do log "  WIPE      group $grp"; done
            echo "Type wipe to delete this data:"
            WCONFIRM=""
            if ( exec 9</dev/tty ) 2>/dev/null; then
                read -r WCONFIRM < /dev/tty || WCONFIRM=""
            else
                read -r WCONFIRM || WCONFIRM=""
            fi
            if [[ "$WCONFIRM" != "wipe" ]]; then
                log "Final wipe step declined: the data is left in place."
                log "To remove it later, rerun with --purge or --wipe-data."
            else
                for p in "${WIPE_TARGETS[@]}"; do
                    rm_labeled "$p"
                done
                for usr in "${WIPE_USERS[@]}"; do
                    act "remove user $usr" userdel "$usr"
                done
                for grp in "${WIPE_GROUPS[@]}"; do
                    if getent group "$grp" &>/dev/null; then
                        act "remove group $grp" groupdel "$grp"
                    else
                        log "  skip  group $grp (already gone with its user)"
                    fi
                done
                WIPED_DATA=1
                for p in "${WIPE_TARGETS[@]}"; do
                    if [[ -e "$p" || -L "$p" ]]; then
                        log "  STILL PRESENT after wipe: $p"
                        WIPE_LEFT=$((WIPE_LEFT + 1))
                    fi
                done
                for usr in "${WIPE_USERS[@]}"; do
                    if id "$usr" &>/dev/null; then
                        log "  STILL PRESENT after wipe: user $usr"
                        WIPE_LEFT=$((WIPE_LEFT + 1))
                    fi
                done
            fi
        fi
    fi
fi

log "════════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "yes" ]]; then
    log "Dry run complete. Nothing was changed."
    log "To perform this teardown: rerun without --dry-run."
    exit 0
fi
if [[ "$FAILURES" -gt 0 || "$LEFT" -gt 0 || "$WIPE_LEFT" -gt 0 ]]; then
    log "Teardown finished WITH PROBLEMS: $FAILURES failed actions, $LEFT items still present, $WIPE_LEFT wipe leftovers."
    log "The full log is $LOG_FILE. Nothing about the leftovers is hidden:"
    log "rerun the script (it is idempotent) or remove the listed items by hand."
    exit 1
fi
log "Teardown complete: $STACK_NAME is removed from this host."
if [[ "$WIPED_DATA" -eq 1 ]]; then
    log "The preserved data and service accounts were wiped in the final step."
elif [[ "$PURGE" != "yes" && "${#PRESERVE_PATHS[@]}" -gt 0 ]]; then
    log "Kept for a redeploy: ${PRESERVE_PATHS[*]}"
    log "To remove those too, rerun with --purge or --wipe-data."
fi
log "To redeploy: $REDEPLOY_HINT"
log "Full log: $LOG_FILE"
exit 0
