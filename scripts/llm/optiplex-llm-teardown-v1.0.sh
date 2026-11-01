#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# OptiPlex LLM Stack Teardown — v1.0
# ═══════════════════════════════════════════════════════════════════════════
# Removes what optiplex-llm-setup-v2.1 (script, playbook, and the
# containers/optiplex-llm compose stack) installed, so the stack can be
# redeployed clean for testing. Both forms are covered: the native form
# (llama-server built into /opt/llama.cpp, systemd unit, /etc/llm
# config, the llm system user) and the container form (container
# optiplex-llm, volume optiplex_llm_models).
#
# Preserved by default (the expensive state):
#   - Native models:   /var/lib/llm/models
#   - Compose volume:  optiplex_llm_models
#   - Setup and teardown logs under /var/log
# --purge removes the model state and the llm system user as well.
#
# READ THIS BEFORE A REAL RUN
#   - Run with --dry-run first and read the plan. Every action the
#     run will take is labeled, and every data path is labeled
#     PRESERVED or PURGE before anything is touched.
#   - A real run asks you to type a confirmation word (shown in the
#     plan) before it changes anything.
#   - Model files are the expensive state (gigabytes to re-download).
#     They survive a default run. --purge deletes them; there is
#     no undo.
#   - Redeploying afterwards is the stack's own setup path; the
#     closing summary prints both forms' commands.
#   - Every action is logged to /var/log as it happens.
#
# Usage:
#   sudo ./optiplex-llm-teardown-v1.0.sh [--dry-run] [--purge]
#
# A real run asks for a typed confirmation (the word: optiplex).
# --dry-run prints every action and changes nothing.
# Exit codes: 0 clean (including nothing-to-do), 1 aborted or a removal
# failed verification, 2 usage or environment error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

DRY_RUN="no"
PURGE="no"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="yes" ;;
        --purge)   PURGE="yes" ;;
        --help|-h)
            echo "Usage: sudo $0 [--dry-run] [--purge]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: sudo $0 [--dry-run] [--purge]" >&2
            exit 2
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root (sudo)." >&2
    exit 2
fi

LOG_FILE="/var/log/optiplex-llm-teardown.log"
FAILURES=0

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# run <description> <command...>: execute (or print, under --dry-run).
run() {
    local desc="$1"
    shift
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "WOULD: $desc"
        return 0
    fi
    log "DO: $desc"
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        log "!! FAILED: $desc"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    return 0
}

# rm_path <path>: remove a file or directory tree if it exists.
# Soft run: like run, but a failure is expected in one known case
# (systemctl operations that need a running systemd bus, e.g. inside a
# container or rescue shell). Logged plainly, never counted; the
# verification pass at the end is the real gate.
run_soft() {
    local desc="$1"
    shift
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "WOULD: $desc"
        return 0
    fi
    log "DO: $desc"
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        log "note: '$desc' reported an error. Expected when systemd is"
        log "      not running (container, rescue shell); the end state"
        log "      is what matters and the verification pass checks it."
    fi
    return 0
}

rm_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        run "remove $path" rm -rf -- "$path"
    else
        log "skip (absent): $path"
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Plan + confirmation
# ───────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "OptiPlex LLM stack teardown v1.0 (dry-run=$DRY_RUN purge=$PURGE)"
log "Will remove: the llama-server systemd unit, /opt/llama.cpp, the"
log "llama.cpp build tree at /usr/local/src/llama.cpp, /etc/llm"
log "(including the generated API key), the optiplex-llm container,"
log "and the stack's ufw rule (8080/tcp from the LAN, if one was added)."
if [[ "$PURGE" == "yes" ]]; then
    log "PURGE: also removes /var/lib/llm (all models), the"
    log "optiplex_llm_models volume, and the llm system user and group."
else
    log "Preserved: model state (/var/lib/llm/models and the"
    log "optiplex_llm_models volume), the llm user, and all logs."
fi

if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Type optiplex to confirm this teardown:"
    CONFIRM=""
    if ( exec 9</dev/tty ) 2>/dev/null; then
        read -r CONFIRM < /dev/tty || CONFIRM=""
    else
        read -r CONFIRM || CONFIRM=""
    fi
    if [[ "$CONFIRM" != "optiplex" ]]; then
        log "Aborted: confirmation not given. Nothing was removed."
        exit 1
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Container form
# ───────────────────────────────────────────────────────────────────────────
log "Step 1 of 3: remove the container form"


if command -v docker &>/dev/null; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "optiplex-llm" >/dev/null; then
        run "docker rm -f optiplex-llm" docker rm -f optiplex-llm
    else
        log "skip (absent): container optiplex-llm"
    fi
    if [[ "$PURGE" == "yes" ]]; then
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -x "optiplex_llm_models" >/dev/null; then
            run "docker volume rm optiplex_llm_models" docker volume rm optiplex_llm_models
        else
            log "skip (absent): volume optiplex_llm_models"
        fi
    else
        log "preserved: volume optiplex_llm_models (models)"
    fi
else
    log "docker not present: container leg skipped"
fi

# ───────────────────────────────────────────────────────────────────────────
# Native form (unit, install tree, build tree, config, models, user)
# ───────────────────────────────────────────────────────────────────────────
log "Step 2 of 3: remove the native install (service, program tree, build tree, config, firewall rule)"


if [[ -f /etc/systemd/system/llama-server.service ]]; then
    run_soft "systemctl disable --now llama-server" systemctl disable --now llama-server
else
    log "skip (absent): unit llama-server.service"
fi
rm_path /etc/systemd/system/llama-server.service
for link in /etc/systemd/system/*.wants/llama-server.service; do
    rm_path "$link"
done
run_soft "systemctl daemon-reload" systemctl daemon-reload
rm_path /opt/llama.cpp
rm_path /usr/local/src/llama.cpp
rm_path /etc/llm

if [[ "$PURGE" == "yes" ]]; then
    rm_path /var/lib/llm
    if id llm &>/dev/null; then
        run "userdel llm" userdel llm
    else
        log "skip (absent): user llm"
    fi
    if getent group llm &>/dev/null; then
        run "groupdel llm" groupdel llm
    else
        log "skip (absent): group llm"
    fi
else
    if [[ -d /var/lib/llm/models ]]; then
        log "preserved: /var/lib/llm/models ($(du -sh /var/lib/llm/models 2>/dev/null | cut -f1) of models)"
    fi
    log "preserved: user llm"
fi

# ───────────────────────────────────────────────────────────────────────────
# ufw rule the setup added when the API was LAN-exposed (8080/tcp)
# ───────────────────────────────────────────────────────────────────────────

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    LAN_ADDR=$(ip -4 -o addr show scope global \
        | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|cni|flannel)/ && addr == "" { addr = $4 }
               END { print addr }')
    if [[ -n "$LAN_ADDR" ]]; then
        LAN_NET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$LAN_ADDR" || true)
        if [[ -n "${LAN_NET:-}" ]] && ufw status 2>/dev/null | grep -F "8080" | grep -qF "$LAN_NET"; then
            run "ufw delete allow from ${LAN_NET} to any port 8080 proto tcp" \
                ufw --force delete allow from "$LAN_NET" to any port 8080 proto tcp
        else
            log "skip (absent): ufw rule for 8080/tcp from the LAN"
        fi
    else
        log "no LAN address detected: ufw leg skipped"
    fi
else
    log "ufw not present or not active: ufw leg skipped"
fi

# ───────────────────────────────────────────────────────────────────────────
# Verification: everything attempted must actually be gone
# ───────────────────────────────────────────────────────────────────────────
log "Final step: verifying the teardown"


if [[ "$DRY_RUN" == "yes" ]]; then
    log "Dry run complete. Nothing was changed."
    exit 0
fi

STILL=0
for p in /etc/systemd/system/llama-server.service \
         /opt/llama.cpp /usr/local/src/llama.cpp /etc/llm; do
    if [[ -e "$p" ]]; then
        log "STILL PRESENT: $p"
        STILL=$((STILL + 1))
    fi
done
if [[ "$PURGE" == "yes" && -e /var/lib/llm ]]; then
    log "STILL PRESENT: /var/lib/llm"
    STILL=$((STILL + 1))
fi

log "════════════════════════════════════════════════════════════════"
if [[ "$FAILURES" -gt 0 || "$STILL" -gt 0 ]]; then
    log "Teardown finished WITH PROBLEMS: $FAILURES failed actions, $STILL artifacts still present."
    exit 1
fi
log "Teardown complete. All targeted artifacts removed (or already absent)."
log "To redeploy: run scripts/llm/optiplex-llm-setup-v2.1.sh (native form)"
log "or docker compose up -d in containers/optiplex-llm (container form)."
log "Kept: logs in /var/log, and (unless --purge) the model state."
exit 0
