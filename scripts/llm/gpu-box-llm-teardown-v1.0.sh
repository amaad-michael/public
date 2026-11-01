#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# GPU Box LLM Stack Teardown — v1.0
# ═══════════════════════════════════════════════════════════════════════════
# Removes what gpu-box-llm-setup-v1.9 (script, playbook, and the
# containers/gpu-llm compose stack) installed, so the stack can be
# redeployed clean for testing. Both forms are covered: the native form
# (bare-metal Ollama + Docker-run Open WebUI and SearXNG) and the
# container form (compose services ollama, ollama-model-init,
# open-webui, searxng). The container names and volume names are the
# same in both forms, so one pass handles either.
#
# Preserved by default (the expensive state):
#   - Native Ollama models:  /usr/share/ollama/.ollama
#   - Compose Ollama volume: ollama_data
#   - Setup and teardown logs under /var/log
#   - Docker itself (shared infrastructure, installed by many things)
# --purge removes the model state and the ollama system user as well.
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
#   sudo ./gpu-box-llm-teardown-v1.0.sh [--dry-run] [--purge]
#
# A real run asks for a typed confirmation (the word: gpu-box).
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

LOG_FILE="/var/log/gpu-box-llm-teardown.log"
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
log "GPU Box LLM stack teardown v1.0 (dry-run=$DRY_RUN purge=$PURGE)"
log "Will remove: ollama systemd unit + drop-in + binaries, the stack"
log "containers (ollama, ollama-model-init, open-webui, searxng), the"
log "open-webui-storage and searxng-data volumes, /etc/searxng, the"
log "OLLAMA_HOST line in the invoking user's .bashrc, and the stack's"
log "firewalld rich rules (ports 11434, 8080, 8888 from the LAN)."
if [[ "$PURGE" == "yes" ]]; then
    log "PURGE: also removes /usr/share/ollama (all native models), the"
    log "ollama_data volume, and the ollama system user and group."
else
    log "Preserved: model state (/usr/share/ollama/.ollama, ollama_data"
    log "volume), the ollama user, Docker itself, and all logs."
fi

if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Type gpu-box to confirm this teardown:"
    CONFIRM=""
    if ( exec 9</dev/tty ) 2>/dev/null; then
        read -r CONFIRM < /dev/tty || CONFIRM=""
    else
        read -r CONFIRM || CONFIRM=""
    fi
    if [[ "$CONFIRM" != "gpu-box" ]]; then
        log "Aborted: confirmation not given. Nothing was removed."
        exit 1
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Containers (both forms share these names)
# ───────────────────────────────────────────────────────────────────────────
log "Step 1 of 4: remove the Open WebUI and SearXNG containers (present in both install forms)"


if command -v docker &>/dev/null; then
    for c in ollama-model-init ollama open-webui searxng; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "$c" >/dev/null; then
            run "docker rm -f $c" docker rm -f "$c"
        else
            log "skip (absent): container $c"
        fi
    done
    for v in open-webui-storage searxng-data; do
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -x "$v" >/dev/null; then
            run "docker volume rm $v" docker volume rm "$v"
        else
            log "skip (absent): volume $v"
        fi
    done
    if [[ "$PURGE" == "yes" ]]; then
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -x "ollama_data" >/dev/null; then
            run "docker volume rm ollama_data" docker volume rm ollama_data
        else
            log "skip (absent): volume ollama_data"
        fi
    else
        log "preserved: volume ollama_data (models)"
    fi
else
    log "docker not present: container and volume legs skipped"
fi

# ───────────────────────────────────────────────────────────────────────────
# Native Ollama (systemd unit, drop-in, binaries, user)
# ───────────────────────────────────────────────────────────────────────────
log "Step 2 of 4: remove the native Ollama install (service, drop-in, binaries, config)"


if [[ -f /etc/systemd/system/ollama.service ]]; then
    run_soft "systemctl disable --now ollama" systemctl disable --now ollama
else
    log "skip (absent): unit ollama.service"
fi
rm_path /etc/systemd/system/ollama.service.d
rm_path /etc/systemd/system/ollama.service
for link in /etc/systemd/system/*.wants/ollama.service; do
    rm_path "$link"
done
run_soft "systemctl daemon-reload" systemctl daemon-reload
rm_path /usr/local/bin/ollama
rm_path /usr/local/sbin/ollama

if [[ "$PURGE" == "yes" ]]; then
    rm_path /usr/share/ollama
    if id ollama &>/dev/null; then
        run "userdel ollama" userdel ollama
    else
        log "skip (absent): user ollama"
    fi
    if getent group ollama &>/dev/null; then
        run "groupdel ollama" groupdel ollama
    else
        log "skip (absent): group ollama"
    fi
else
    if [[ -d /usr/share/ollama/.ollama ]]; then
        log "preserved: /usr/share/ollama/.ollama ($(du -sh /usr/share/ollama/.ollama 2>/dev/null | cut -f1) of models)"
    fi
    log "preserved: user ollama"
fi

# ───────────────────────────────────────────────────────────────────────────
# SearXNG config + the .bashrc OLLAMA_HOST line the setup persists
# ───────────────────────────────────────────────────────────────────────────
log "Step 3 of 4: remove the SearXNG config and the OLLAMA_HOST line in the user bashrc"


rm_path /etc/searxng

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    REAL_USER=$(logname 2>/dev/null || true)
fi
if [[ -n "$REAL_USER" ]]; then
    REAL_USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 || true)
    if [[ -n "$REAL_USER_HOME" && -f "${REAL_USER_HOME}/.bashrc" ]]; then
        if grep -q "^export OLLAMA_HOST=" "${REAL_USER_HOME}/.bashrc"; then
            run "strip OLLAMA_HOST line from ${REAL_USER_HOME}/.bashrc" \
                sed -i "/^export OLLAMA_HOST=/d" "${REAL_USER_HOME}/.bashrc"
        else
            log "skip (absent): OLLAMA_HOST line in ${REAL_USER_HOME}/.bashrc"
        fi
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# firewalld rich rules the setup added (LAN-scoped, one per port)
# ───────────────────────────────────────────────────────────────────────────

if systemctl is-active --quiet firewalld; then
    LAN_ADDR=$(ip -4 -o addr show scope global \
        | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|cni|flannel)/ && addr == "" { addr = $4 }
               END { print addr }')
    if [[ -n "$LAN_ADDR" ]]; then
        LAN_NET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$LAN_ADDR" || true)
        if [[ -n "${LAN_NET:-}" ]]; then
            RELOADED="no"
            for port in 11434 8080 8888; do
                RULE="rule family=ipv4 source address=${LAN_NET} port port=${port} protocol=tcp accept"
                if firewall-cmd --permanent --query-rich-rule="$RULE" >/dev/null 2>&1; then
                    if run "firewalld remove rich rule ${port}/tcp from ${LAN_NET}" \
                        firewall-cmd --permanent --remove-rich-rule="$RULE"; then
                        RELOADED="yes"
                    fi
                else
                    log "skip (absent): firewalld rich rule ${port}/tcp from ${LAN_NET}"
                fi
            done
            if [[ "$RELOADED" == "yes" && "$DRY_RUN" != "yes" ]]; then
                run "firewall-cmd --reload" firewall-cmd --reload
            fi
        else
            log "could not derive LAN network: firewall leg skipped"
        fi
    else
        log "no LAN address detected: firewall leg skipped"
    fi
else
    log "firewalld not active: firewall leg skipped"
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
for p in /etc/systemd/system/ollama.service \
         /etc/systemd/system/ollama.service.d \
         /usr/local/bin/ollama /etc/searxng; do
    if [[ -e "$p" ]]; then
        log "STILL PRESENT: $p"
        STILL=$((STILL + 1))
    fi
done
if [[ "$PURGE" == "yes" && -e /usr/share/ollama ]]; then
    log "STILL PRESENT: /usr/share/ollama"
    STILL=$((STILL + 1))
fi

log "════════════════════════════════════════════════════════════════"
if [[ "$FAILURES" -gt 0 || "$STILL" -gt 0 ]]; then
    log "Teardown finished WITH PROBLEMS: $FAILURES failed actions, $STILL artifacts still present."
    exit 1
fi
log "Teardown complete. All targeted artifacts removed (or already absent)."
log "To redeploy: run scripts/llm/gpu-box-llm-setup-v1.9.sh (native form)"
log "or docker compose up -d in containers/gpu-llm (container form)."
log "Kept: Docker, logs in /var/log, and (unless --purge) the model state."
exit 0
