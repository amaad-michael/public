#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# OptiPlex LLM Stack Controller - v1.0
# ═══════════════════════════════════════════════════════════════════════════
# One entry point for the whole OptiPlex LLM stack, in the shape of
# the neo1 observability control script: setup, start, stop, restart,
# status, and uninstall as verbs of a single script.
#
# The stack (per optiplex-llm-setup-v2.1.sh, its Ansible playbook
# form, and containers/optiplex-llm):
#   Native form:  llama.cpp built from /usr/local/src/llama.cpp and
#                 installed to /opt/llama.cpp, run as the systemd unit
#                 llama-server (user llm), config and generated API
#                 key in /etc/llm, models in /var/lib/llm/models, API
#                 on port 8080 (loopback unless the setup's BIND_ADDR
#                 was changed).
#   Compose form: container optiplex-llm with the optiplex_llm_models
#                 volume. Day-to-day lifecycle of a pure compose
#                 deployment belongs to the generic compose teardown
#                 engine (scripts/teardown/stack-teardown-v1.0.sh);
#                 this controller's uninstall still removes the
#                 compose form's container and volume by name, exactly
#                 as the standalone teardown does.
#
# The setup verb runs the stack's own setup script
# (optiplex-llm-setup-v2.1.sh, beside this one). There is one install
# implementation and it stays there; this controller owns the
# lifecycle around it. The setup script's environment knobs
# (MODEL_PRESET, THREADS, and friends) pass through this controller's
# environment unchanged.
#
# The uninstall verb folds in optiplex-llm-teardown-v1.0.sh (board
# item [a5391c]) with its verified footprint and semantics unchanged.
# When both packages have landed, this controller supersedes the
# standalone teardown as the entry point; the teardown script remains
# as built.
#
# Preserved by default on uninstall (the expensive state):
#   - Native models:   /var/lib/llm/models
#   - Compose volume:  optiplex_llm_models
#   - Logs under /var/log
# --purge removes the model state and the llm system user as well.
#
# READ THIS BEFORE A REAL RUN
#   - Run any verb with --dry-run first and read the plan. Actions are
#     labeled, and on uninstall every data path is labeled PRESERVED
#     or PURGE before anything is touched.
#   - uninstall asks you to type a confirmation word (optiplex)
#     before it changes anything. start, stop, and restart do not
#     ask: they change runtime state only, nothing is removed.
#   - Model files are the expensive state (gigabytes to re-download
#     on this box's disk). They survive a default uninstall. --purge
#     deletes them; there is no undo.
#   - This controller never installs, removes, starts, or stops the
#     Docker daemon itself. Docker is shared infrastructure. If the
#     daemon is not reachable, container legs are skipped with a note.
#   - systemctl calls that need a running systemd bus (start, stop,
#     disable, daemon-reload) are soft actions: in a container or
#     rescue shell they report an error despite doing their offline
#     half, so the script logs a plain note and the state table and
#     verification pass are the gate.
#   - Every action is logged to /var/log/optiplex-llm-control.log.
#
# Usage:
#   sudo ./optiplex-llm-control-v1.0.sh setup [--dry-run]
#   sudo ./optiplex-llm-control-v1.0.sh start [--dry-run]
#   sudo ./optiplex-llm-control-v1.0.sh stop [--dry-run]
#   sudo ./optiplex-llm-control-v1.0.sh restart [--dry-run]
#   ./optiplex-llm-control-v1.0.sh status
#   sudo ./optiplex-llm-control-v1.0.sh uninstall [--dry-run] [--purge]
#
# Exit codes: 0 = the requested state is in place (or nothing to do),
# 1 = a verb failed, was aborted, or status found the stack not fully
# up, 2 = usage or environment error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/optiplex-llm-setup-v2.1.sh"
LOG_FILE="/var/log/optiplex-llm-control.log"
CONFIRM_WORD="optiplex"
SERVER_PORT="8080"

DRY_RUN="no"
PURGE="no"
VERB=""

usage() {
    cat <<'EOF'
Usage:
  optiplex-llm-control-v1.0.sh setup [--dry-run]
  optiplex-llm-control-v1.0.sh start [--dry-run]
  optiplex-llm-control-v1.0.sh stop [--dry-run]
  optiplex-llm-control-v1.0.sh restart [--dry-run]
  optiplex-llm-control-v1.0.sh status
  optiplex-llm-control-v1.0.sh uninstall [--dry-run] [--purge]

  setup      Run the stack's setup script (beside this one) to
             install or refresh the native form, then show status.
  start      Start the llama-server unit (if installed) and the
             optiplex-llm container (if it exists). Runtime only.
  stop       Stop the optiplex-llm container and the unit.
  restart    stop, then start.
  status     Show every member's state; exit 1 if anything that is
             installed is not running, or nothing is installed.
  uninstall  Remove the stack (both install forms) after a typed
             confirmation. Models and the llm user survive unless
             --purge is given.
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
    local state
    MEMBERS_PRESENT=0
    MEMBERS_DOWN=0
    printf '%-24s %s\n' "MEMBER" "STATE"
    if [[ -f /etc/systemd/system/llama-server.service ]]; then
        MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
        state=$(unit_state llama-server)
        printf '%-24s %s\n' "llama-server unit" "$state"
        [[ "$state" == "active" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
    else
        printf '%-24s %s\n' "llama-server unit" "not installed"
    fi
    state=$(container_state optiplex-llm)
    if [[ "$state" == "absent" ]]; then
        printf '%-24s %s\n' "container optiplex-llm" "absent"
    else
        MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
        printf '%-24s %s\n' "container optiplex-llm" "$state"
        [[ "$state" == "running" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
    fi
    # Informational only: the native server binds loopback by
    # default, and 0.0.0.0 includes loopback, so the health route
    # answers locally either way when the server is up.
    if curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/health" 2>/dev/null; then
        printf '%-24s %s\n' "API /health" "responding"
    else
        printf '%-24s %s\n' "API /health" "not responding"
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# setup: run the stack's own setup script, then show the state table
# ───────────────────────────────────────────────────────────────────────────

do_setup() {
    log "════════════════════════════════════════════════════════════════"
    log "OptiPlex LLM stack setup via the stack's setup script"
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
    log "DO: run $SETUP_SCRIPT (its own log: /var/log/optiplex-llm-setup.log)"
    local rc=0
    "$SETUP_SCRIPT" || rc=$?
    if [[ $rc -ne 0 ]]; then
        log "Setup script exited with status $rc. See /var/log/optiplex-llm-setup.log."
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
    if [[ -f /etc/systemd/system/llama-server.service ]]; then
        run_soft "systemctl start llama-server" systemctl start llama-server
    else
        log "skip (absent): unit llama-server.service"
    fi
    if docker_ready; then
        local state
        state=$(container_state optiplex-llm)
        case "$state" in
            running) log "already running: container optiplex-llm" ;;
            stopped) run "docker start optiplex-llm" docker start optiplex-llm ;;
            absent)  log "skip (absent): container optiplex-llm" ;;
            *)       log "state unknown: container optiplex-llm" ;;
        esac
    else
        log "docker not present or daemon not reachable: container legs skipped"
        log "(the controller never manages the Docker daemon itself)"
    fi
}

stop_members() {
    log "Step 1 of 2: stop the stack members"
    if docker_ready; then
        local state
        state=$(container_state optiplex-llm)
        case "$state" in
            running) run "docker stop optiplex-llm" docker stop optiplex-llm ;;
            stopped) log "already stopped: container optiplex-llm" ;;
            absent)  log "skip (absent): container optiplex-llm" ;;
            *)       log "state unknown: container optiplex-llm" ;;
        esac
    else
        log "docker not present or daemon not reachable: container legs skipped"
        log "(the controller never manages the Docker daemon itself)"
    fi
    if [[ -f /etc/systemd/system/llama-server.service ]]; then
        run_soft "systemctl stop llama-server" systemctl stop llama-server
    else
        log "skip (absent): unit llama-server.service"
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
    log "OptiPlex LLM stack start (dry-run=$DRY_RUN)"
    start_members
    finish_runtime_verb "Start"
}

do_stop() {
    log "════════════════════════════════════════════════════════════════"
    log "OptiPlex LLM stack stop (dry-run=$DRY_RUN)"
    stop_members
    finish_runtime_verb "Stop"
}

do_restart() {
    log "════════════════════════════════════════════════════════════════"
    log "OptiPlex LLM stack restart (dry-run=$DRY_RUN)"
    stop_members
    start_members
    finish_runtime_verb "Restart"
}

# ───────────────────────────────────────────────────────────────────────────
# status: read-only, any user, the strict gate
# ───────────────────────────────────────────────────────────────────────────

do_status() {
    say "OptiPlex LLM stack status"
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
# optiplex-llm-teardown-v1.0.sh)
# ───────────────────────────────────────────────────────────────────────────

do_uninstall() {
    log "════════════════════════════════════════════════════════════════"
    log "OptiPlex LLM stack uninstall (dry-run=$DRY_RUN purge=$PURGE)"
    log "Will remove: the llama-server systemd unit, /opt/llama.cpp, the"
    log "llama.cpp build tree at /usr/local/src/llama.cpp, /etc/llm"
    log "(including the generated API key), the optiplex-llm container,"
    log "and the stack's ufw rule (8080/tcp from the LAN, if one was"
    log "added; the setup adds it only when the API is LAN-exposed)."
    if [[ "$PURGE" == "yes" ]]; then
        log "PURGE: also removes /var/lib/llm (all models), the"
        log "optiplex_llm_models volume, and the llm system user and group."
    else
        log "Preserved: model state (/var/lib/llm/models and the"
        log "optiplex_llm_models volume), the llm user, and all logs."
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

    # Container form
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

    # Native form (unit, install tree, build tree, config, models, user)
    log "Step 2 of 3: remove the native install (service, program tree, build tree, config)"
    if [[ -f /etc/systemd/system/llama-server.service ]]; then
        run_soft "systemctl disable --now llama-server" systemctl disable --now llama-server
    else
        log "skip (absent): unit llama-server.service"
    fi
    rm_path /etc/systemd/system/llama-server.service
    local link
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

    # ufw rule the setup added when the API was LAN-exposed (8080/tcp)
    log "Step 3 of 3: remove the ufw rule the setup added, if present"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -F "Status: active" >/dev/null; then
        local lan_addr lan_net
        lan_addr=$(ip -4 -o addr show scope global \
            | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap)/ && addr == "" { addr = $4 }
                   END { print addr }')
        if [[ -n "$lan_addr" ]]; then
            lan_net=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$lan_addr" || true)
            if [[ -n "${lan_net:-}" ]] && ufw status 2>/dev/null | grep -F "8080" | grep -F "$lan_net" >/dev/null; then
                run "ufw delete allow from ${lan_net} to any port 8080 proto tcp" \
                    ufw --force delete allow from "$lan_net" to any port 8080 proto tcp
            else
                log "skip (absent): ufw rule for 8080/tcp from the LAN"
            fi
        else
            log "no LAN address detected: ufw leg skipped"
        fi
    else
        log "ufw not present or not active: ufw leg skipped"
    fi

    # Verification: everything attempted must actually be gone
    log "Final step: verifying the uninstall"
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "Dry run complete. Nothing was changed."
        exit 0
    fi

    local still=0 p
    for p in /etc/systemd/system/llama-server.service \
             /opt/llama.cpp /usr/local/src/llama.cpp /etc/llm; do
        if [[ -e "$p" ]]; then
            log "STILL PRESENT: $p"
            still=$((still + 1))
        fi
    done
    if [[ "$PURGE" == "yes" && -e /var/lib/llm ]]; then
        log "STILL PRESENT: /var/lib/llm"
        still=$((still + 1))
    fi

    log "════════════════════════════════════════════════════════════════"
    if [[ $FAILURES -gt 0 || $still -gt 0 ]]; then
        log "Uninstall finished WITH PROBLEMS: $FAILURES failed actions, $still artifacts still present."
        exit 1
    fi
    log "Uninstall complete. All targeted artifacts removed (or already absent)."
    log "To redeploy the native form: $0 setup"
    log "(equivalently: scripts/llm/optiplex-llm-setup-v2.1.sh)"
    log "To redeploy the container form: docker compose up -d in containers/optiplex-llm,"
    log "or manage that form with scripts/teardown/stack-teardown-v1.0.sh."
    log "Kept: logs in /var/log, and (unless --purge) the model state."
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
