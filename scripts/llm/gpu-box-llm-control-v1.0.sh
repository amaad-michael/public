#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# GPU Box LLM Stack Controller - v1.0
# ═══════════════════════════════════════════════════════════════════════════
# One entry point for the whole GPU box LLM stack, in the shape of the
# neo1 observability control script: setup, start, stop, restart,
# status, and uninstall as verbs of a single script.
#
# The stack (per gpu-box-llm-setup-v1.9.sh, its Ansible playbook form,
# and containers/gpu-llm):
#   Native form:  bare-metal Ollama (systemd unit ollama, drop-in
#                 /etc/systemd/system/ollama.service.d/10-gpu-box.conf,
#                 models in /usr/share/ollama/.ollama) plus the Open
#                 WebUI and SearXNG containers the setup runs beside
#                 it (containers open-webui and searxng, volumes
#                 open-webui-storage and searxng-data, config in
#                 /etc/searxng).
#   Compose form: the same three pieces as one compose project
#                 (containers ollama, ollama-model-init, open-webui,
#                 searxng; volumes ollama_data, open-webui-storage,
#                 searxng-data). Day-to-day lifecycle of a pure compose
#                 deployment belongs to the generic compose teardown
#                 engine (scripts/teardown/stack-teardown-v1.0.sh);
#                 this controller's uninstall still removes the compose
#                 form's containers and volumes by name, exactly as the
#                 standalone teardown does.
#
# The setup verb runs the stack's own setup script
# (gpu-box-llm-setup-v1.9.sh, beside this one). There is one install
# implementation and it stays there; this controller owns the
# lifecycle around it.
#
# The uninstall verb folds in gpu-box-llm-teardown-v1.0.sh (board item
# [a5391c]) with its verified footprint and semantics unchanged. When
# both packages have landed, this controller supersedes the standalone
# teardown as the entry point; the teardown script remains as built.
#
# Preserved by default on uninstall (the expensive state):
#   - Native Ollama models:  /usr/share/ollama/.ollama
#   - Compose Ollama volume: ollama_data
#   - Logs under /var/log
#   - Docker itself (shared infrastructure, installed by many things)
# --purge removes the model state and the ollama system user as well.
#
# READ THIS BEFORE A REAL RUN
#   - Run any verb with --dry-run first and read the plan. Actions are
#     labeled, and on uninstall every data path is labeled PRESERVED
#     or PURGE before anything is touched.
#   - uninstall asks you to type a confirmation word (gpu-box) before
#     it changes anything. start, stop, and restart do not ask: they
#     change runtime state only, nothing is removed.
#   - Model files are the expensive state (gigabytes to re-download).
#     They survive a default uninstall. --purge deletes them; there
#     is no undo.
#   - This controller never installs, removes, starts, or stops the
#     Docker daemon itself. Docker is shared infrastructure. If the
#     daemon is not reachable, container legs are skipped with a note.
#   - systemctl calls that need a running systemd bus (start, stop,
#     disable, daemon-reload) are soft actions: in a container or
#     rescue shell they report an error despite doing their offline
#     half, so the script logs a plain note and the state table and
#     verification pass are the gate.
#   - Every action is logged to /var/log/gpu-box-llm-control.log.
#
# Usage:
#   sudo ./gpu-box-llm-control-v1.0.sh setup [--dry-run]
#   sudo ./gpu-box-llm-control-v1.0.sh start [--dry-run]
#   sudo ./gpu-box-llm-control-v1.0.sh stop [--dry-run]
#   sudo ./gpu-box-llm-control-v1.0.sh restart [--dry-run]
#   ./gpu-box-llm-control-v1.0.sh status
#   sudo ./gpu-box-llm-control-v1.0.sh uninstall [--dry-run] [--purge]
#
# Exit codes: 0 = the requested state is in place (or nothing to do),
# 1 = a verb failed, was aborted, or status found the stack not fully
# up, 2 = usage or environment error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/gpu-box-llm-setup-v1.9.sh"
LOG_FILE="/var/log/gpu-box-llm-control.log"
CONFIRM_WORD="gpu-box"

DRY_RUN="no"
PURGE="no"
VERB=""

usage() {
    cat <<'EOF'
Usage:
  gpu-box-llm-control-v1.0.sh setup [--dry-run]
  gpu-box-llm-control-v1.0.sh start [--dry-run]
  gpu-box-llm-control-v1.0.sh stop [--dry-run]
  gpu-box-llm-control-v1.0.sh restart [--dry-run]
  gpu-box-llm-control-v1.0.sh status
  gpu-box-llm-control-v1.0.sh uninstall [--dry-run] [--purge]

  setup      Run the stack's setup script (beside this one) to
             install or refresh the native form, then show status.
  start      Start the Ollama unit (if installed) and the stack
             containers that exist. Runtime state only.
  stop       Stop the stack containers and the Ollama unit.
  restart    stop, then start.
  status     Show every member's state; exit 1 if anything that is
             installed is not running, or nothing is installed.
  uninstall  Remove the stack (both install forms) after a typed
             confirmation. Models and the ollama user survive
             unless --purge is given. Docker is never removed.
  --dry-run  Print every action and change nothing.
EOF
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
fi
VERB="$1"
shift
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="yes" ;;
        --purge)   PURGE="yes" ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$VERB" in
    setup|start|stop|restart|status|uninstall) ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown verb: $VERB" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ "$PURGE" == "yes" && "$VERB" != "uninstall" ]]; then
    echo "--purge is only valid with uninstall." >&2
    usage >&2
    exit 2
fi
if [[ "$VERB" == "status" && ( "$DRY_RUN" == "yes" || "$PURGE" == "yes" ) ]]; then
    echo "status takes no options." >&2
    usage >&2
    exit 2
fi

if [[ "$VERB" != "status" && "${EUID}" -ne 0 ]]; then
    echo "This verb must run as root (sudo). status is read-only and does not." >&2
    exit 2
fi

FAILURES=0

# log: timestamped, to the screen and the log file. State-changing
# verbs only; status uses say() so it works for any user.
log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

say() {
    printf '%s\n' "$*"
}

# run <description> <command...>: execute (or print, under --dry-run).
# A failure is counted; the verb's verification decides the exit code.
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

# run_soft <description> <command...>: like run, but a failure is
# expected in one known case (systemctl operations that need a
# running systemd bus, e.g. inside a container or rescue shell).
# Logged plainly, never counted; the end state is the gate.
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
        log "      is what matters and the state table checks it."
    fi
    return 0
}

# rm_path <path>: remove a file or directory tree if it exists.
rm_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        run "remove $path" rm -rf -- "$path"
    else
        log "skip (absent): $path"
    fi
}

# unit_state <unit>: active, inactive, or unknown (no systemd bus, or
# systemctl itself missing). File presence is checked by the caller;
# this only reports runtime state.
unit_state() {
    local out
    if ! command -v systemctl &>/dev/null; then
        echo "unknown"
        return 0
    fi
    out=$(systemctl is-active "$1" 2>/dev/null || true)
    case "$out" in
        active)          echo "active" ;;
        inactive|failed) echo "inactive" ;;
        *)               echo "unknown" ;;
    esac
}

# docker_ready: 0 when the docker CLI exists and the daemon answers.
docker_ready() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

# container_state <name>: running, stopped, absent (no such
# container, or no docker CLI for one to exist under), or unknown
# (CLI present but daemon unreachable).
# Note: the listing greps below deliberately avoid grep -q. Under
# pipefail, an early grep -q exit SIGPIPEs the producer whenever the
# match is not its last line, and the pipeline then reports failure
# for a name that is present. grep without -q drains the listing.
container_state() {
    local name="$1"
    if ! command -v docker &>/dev/null; then
        echo "absent"
        return 0
    fi
    if ! docker info &>/dev/null; then
        echo "unknown"
        return 0
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -x "$name" >/dev/null; then
        echo "running"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "$name" >/dev/null; then
        echo "stopped"
    else
        echo "absent"
    fi
}

# Member table, shared by status and by the closing step of the
# state-changing verbs. Sets MEMBERS_PRESENT and MEMBERS_DOWN.
MEMBERS_PRESENT=0
MEMBERS_DOWN=0
print_member_table() {
    local state c
    MEMBERS_PRESENT=0
    MEMBERS_DOWN=0
    printf '%-24s %s\n' "MEMBER" "STATE"
    if [[ -f /etc/systemd/system/ollama.service ]]; then
        MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
        state=$(unit_state ollama)
        printf '%-24s %s\n' "ollama unit (native)" "$state"
        [[ "$state" == "active" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
    else
        printf '%-24s %s\n' "ollama unit (native)" "not installed"
    fi
    for c in ollama open-webui searxng; do
        state=$(container_state "$c")
        if [[ "$state" == "absent" ]]; then
            printf '%-24s %s\n' "container $c" "absent"
        else
            MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
            printf '%-24s %s\n' "container $c" "$state"
            [[ "$state" == "running" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
        fi
    done
}

# ───────────────────────────────────────────────────────────────────────────
# setup: run the stack's own setup script, then show the state table
# ───────────────────────────────────────────────────────────────────────────

do_setup() {
    log "════════════════════════════════════════════════════════════════"
    log "GPU Box LLM stack setup via the stack's setup script"
    log "Step 1 of 2: run the setup script (native form)"
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        log "Setup script not found: $SETUP_SCRIPT"
        log "This controller expects the setup script beside it in scripts/llm."
        exit 2
    fi
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "WOULD: run $SETUP_SCRIPT"
        log "Step 2 of 2: show the member state table"
        log "Dry run complete. Nothing was changed."
        exit 0
    fi
    log "DO: run $SETUP_SCRIPT (its own log: /var/log/gpu-box-llm-setup.log)"
    local rc=0
    "$SETUP_SCRIPT" || rc=$?
    if [[ $rc -ne 0 ]]; then
        log "Setup script exited with status $rc. See /var/log/gpu-box-llm-setup.log."
        exit 1
    fi
    log "Step 2 of 2: member state after setup"
    print_member_table
    log "Setup complete. The setup script's own verification ran as part of it."
    log "Manage the stack with: $0 start|stop|restart|status|uninstall"
    exit 0
}

# ───────────────────────────────────────────────────────────────────────────
# start / stop / restart: runtime state only, nothing is removed
# ───────────────────────────────────────────────────────────────────────────

start_members() {
    log "Step 1 of 2: start the stack members"
    if [[ -f /etc/systemd/system/ollama.service ]]; then
        run_soft "systemctl start ollama" systemctl start ollama
    else
        log "skip (absent): unit ollama.service"
    fi
    if docker_ready; then
        local c state
        for c in ollama open-webui searxng; do
            state=$(container_state "$c")
            case "$state" in
                running) log "already running: container $c" ;;
                stopped) run "docker start $c" docker start "$c" ;;
                absent)  log "skip (absent): container $c" ;;
                *)       log "state unknown: container $c" ;;
            esac
        done
    else
        log "docker not present or daemon not reachable: container legs skipped"
        log "(the controller never manages the Docker daemon itself)"
    fi
}

stop_members() {
    log "Step 1 of 2: stop the stack members"
    if docker_ready; then
        local c state
        for c in searxng open-webui ollama; do
            state=$(container_state "$c")
            case "$state" in
                running) run "docker stop $c" docker stop "$c" ;;
                stopped) log "already stopped: container $c" ;;
                absent)  log "skip (absent): container $c" ;;
                *)       log "state unknown: container $c" ;;
            esac
        done
    else
        log "docker not present or daemon not reachable: container legs skipped"
        log "(the controller never manages the Docker daemon itself)"
    fi
    if [[ -f /etc/systemd/system/ollama.service ]]; then
        run_soft "systemctl stop ollama" systemctl stop ollama
    else
        log "skip (absent): unit ollama.service"
    fi
}

finish_runtime_verb() {
    local verb="$1"
    log "Step 2 of 2: member state"
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "Dry run complete. Nothing was changed."
        exit 0
    fi
    print_member_table
    log "════════════════════════════════════════════════════════════════"
    if [[ $FAILURES -gt 0 ]]; then
        log "$verb finished WITH PROBLEMS: $FAILURES failed actions."
        exit 1
    fi
    log "$verb complete. State table above is the end state."
    log "Note: a member showing unknown has no live systemd bus or"
    log "Docker daemon to report its state in this environment."
    exit 0
}

do_start() {
    log "════════════════════════════════════════════════════════════════"
    log "GPU Box LLM stack start (dry-run=$DRY_RUN)"
    start_members
    finish_runtime_verb "Start"
}

do_stop() {
    log "════════════════════════════════════════════════════════════════"
    log "GPU Box LLM stack stop (dry-run=$DRY_RUN)"
    stop_members
    finish_runtime_verb "Stop"
}

do_restart() {
    log "════════════════════════════════════════════════════════════════"
    log "GPU Box LLM stack restart (dry-run=$DRY_RUN)"
    stop_members
    start_members
    finish_runtime_verb "Restart"
}

# ───────────────────────────────────────────────────────────────────────────
# status: read-only, any user, the strict gate
# ───────────────────────────────────────────────────────────────────────────

do_status() {
    say "GPU Box LLM stack status"
    print_member_table
    if [[ $MEMBERS_PRESENT -eq 0 ]]; then
        say "Nothing of the stack is installed on this host."
        exit 1
    fi
    if [[ $MEMBERS_DOWN -gt 0 ]]; then
        say "Stack is not fully up: $MEMBERS_DOWN installed member(s) not running."
        exit 1
    fi
    say "Every installed member is running."
    exit 0
}

# ───────────────────────────────────────────────────────────────────────────
# uninstall: the teardown, folded in (footprint and semantics as in
# gpu-box-llm-teardown-v1.0.sh)
# ───────────────────────────────────────────────────────────────────────────

do_uninstall() {
    log "════════════════════════════════════════════════════════════════"
    log "GPU Box LLM stack uninstall (dry-run=$DRY_RUN purge=$PURGE)"
    log "Will remove: ollama systemd unit + drop-in + binaries, the stack"
    log "containers (ollama, ollama-model-init, open-webui, searxng), the"
    log "open-webui-storage and searxng-data volumes, /etc/searxng, the"
    log "OLLAMA_HOST line in the invoking user's .bashrc, and the stack's"
    log "firewalld rich rules (ports 11434 and 8080 from the LAN, and 8888"
    log "if the setup created one, which it does only when SearXNG is"
    log "LAN-exposed)."
    if [[ "$PURGE" == "yes" ]]; then
        log "PURGE: also removes /usr/share/ollama (all native models), the"
        log "ollama_data volume, and the ollama system user and group."
    else
        log "Preserved: model state (/usr/share/ollama/.ollama, ollama_data"
        log "volume), the ollama user, Docker itself, and all logs."
    fi

    if [[ "$DRY_RUN" != "yes" ]]; then
        echo "Type $CONFIRM_WORD to confirm this uninstall:"
        local confirm=""
        if ( exec 9</dev/tty ) 2>/dev/null; then
            read -r confirm < /dev/tty || confirm=""
        else
            read -r confirm || confirm=""
        fi
        if [[ "$confirm" != "$CONFIRM_WORD" ]]; then
            log "Aborted: confirmation not given. Nothing was removed."
            exit 1
        fi
    fi

    # Containers (both forms share these names)
    log "Step 1 of 4: remove the Open WebUI and SearXNG containers (present in both install forms)"
    if command -v docker &>/dev/null; then
        local c v
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

    # Native Ollama (systemd unit, drop-in, binaries, user)
    log "Step 2 of 4: remove the native Ollama install (service, drop-in, binaries, config)"
    if [[ -f /etc/systemd/system/ollama.service ]]; then
        run_soft "systemctl disable --now ollama" systemctl disable --now ollama
    else
        log "skip (absent): unit ollama.service"
    fi
    rm_path /etc/systemd/system/ollama.service.d
    rm_path /etc/systemd/system/ollama.service
    local link
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

    # SearXNG config + the .bashrc OLLAMA_HOST line the setup persists
    log "Step 3 of 4: remove the SearXNG config and the OLLAMA_HOST line in the user bashrc"
    rm_path /etc/searxng

    local real_user="${SUDO_USER:-}"
    if [[ -z "$real_user" ]]; then
        real_user=$(logname 2>/dev/null || true)
    fi
    if [[ -n "$real_user" ]]; then
        local real_home
        real_home=$(getent passwd "$real_user" | cut -d: -f6 || true)
        if [[ -n "$real_home" && -f "${real_home}/.bashrc" ]]; then
            if grep -q "^export OLLAMA_HOST=" "${real_home}/.bashrc"; then
                run "strip OLLAMA_HOST line from ${real_home}/.bashrc" \
                    sed -i "/^export OLLAMA_HOST=/d" "${real_home}/.bashrc"
            else
                log "skip (absent): OLLAMA_HOST line in ${real_home}/.bashrc"
            fi
        fi
    fi

    # firewalld rich rules the setup added (LAN-scoped, one per port;
    # the 8888 rule exists only when SearXNG was LAN-exposed)
    log "Step 4 of 4: remove the firewalld rich rules the setup added"
    if systemctl is-active --quiet firewalld; then
        local lan_addr lan_net rule port reloaded
        lan_addr=$(ip -4 -o addr show scope global \
            | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap|cni|flannel)/ && addr == "" { addr = $4 }
                   END { print addr }')
        if [[ -n "$lan_addr" ]]; then
            lan_net=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$lan_addr" || true)
            if [[ -n "${lan_net:-}" ]]; then
                reloaded="no"
                for port in 11434 8080 8888; do
                    rule="rule family=ipv4 source address=${lan_net} port port=${port} protocol=tcp accept"
                    if firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
                        if run "firewalld remove rich rule ${port}/tcp from ${lan_net}" \
                            firewall-cmd --permanent --remove-rich-rule="$rule"; then
                            reloaded="yes"
                        fi
                    else
                        log "skip (absent): firewalld rich rule ${port}/tcp from ${lan_net}"
                    fi
                done
                if [[ "$reloaded" == "yes" && "$DRY_RUN" != "yes" ]]; then
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

    # Verification: everything attempted must actually be gone
    log "Final step: verifying the uninstall"
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "Dry run complete. Nothing was changed."
        exit 0
    fi

    local still=0 p
    for p in /etc/systemd/system/ollama.service \
             /etc/systemd/system/ollama.service.d \
             /usr/local/bin/ollama /etc/searxng; do
        if [[ -e "$p" ]]; then
            log "STILL PRESENT: $p"
            still=$((still + 1))
        fi
    done
    if [[ "$PURGE" == "yes" && -e /usr/share/ollama ]]; then
        log "STILL PRESENT: /usr/share/ollama"
        still=$((still + 1))
    fi

    log "════════════════════════════════════════════════════════════════"
    if [[ $FAILURES -gt 0 || $still -gt 0 ]]; then
        log "Uninstall finished WITH PROBLEMS: $FAILURES failed actions, $still artifacts still present."
        exit 1
    fi
    log "Uninstall complete. All targeted artifacts removed (or already absent)."
    log "To redeploy the native form: $0 setup"
    log "(equivalently: scripts/llm/gpu-box-llm-setup-v1.9.sh)"
    log "To redeploy the container form: docker compose up -d in containers/gpu-llm,"
    log "or manage that form with scripts/teardown/stack-teardown-v1.0.sh."
    log "Kept: Docker, logs in /var/log, and (unless --purge) the model state."
    exit 0
}

case "$VERB" in
    setup)     do_setup ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
esac
