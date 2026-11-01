#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# NanoPi LLM Stack Controller - v1.0
# ═══════════════════════════════════════════════════════════════════════════
# One entry point for the whole NanoPi LLM stack, in the shape of
# the neo1 observability control script: setup, start, stop, restart,
# status, and uninstall as verbs of a single script.
#
# This stack's shape differs from its siblings, and the controller
# follows the shape instead of forcing the pattern:
#   - TWO ROLES, one per board. A server board runs llama.cpp
#     inference (the llama-server systemd unit); a load balancer
#     board runs nginx with the llm-lb site. A board normally holds
#     exactly one role. The controller detects which roles are
#     installed on the host it runs on, from the footprint, and
#     acts on those; a host with both roles installed gets both
#     handled.
#   - OPERATOR STATE. There is no service account and no /etc or
#     /var/lib state for the native form: the unit runs as the
#     operator who installed it, and the llama.cpp checkout and the
#     models live in that operator's home (~/llama.cpp, ~/models).
#     Uninstall resolves that home from the unit's own User= line
#     (what the setup recorded), falling back to $NANOPI_LLM_USER,
#     then to the invoking sudo user. The operator account itself
#     is never touched.
#   - NGINX IS SHARED. On a load balancer board the stack's own
#     footprint is the llm-lb site (sites-available plus the
#     sites-enabled link) and nothing else: nginx, its package, and
#     its unit stay installed. Start and stop still operate the
#     nginx unit when the llm-lb site is present, because on that
#     board nginx is the stack's runtime.
#
# The stack (per nanopi-llm-setup.sh, its Ansible forms
# llm-server-setup.yml and llm-lb-setup.yml, and containers/llm):
#   Native server role: /etc/systemd/system/llama-server.service
#                 (User = the operator), ~/llama.cpp build tree,
#                 ~/models GGUF files, UFW allow for the server
#                 port (8080) from the LAN /24.
#   Native LB role: /etc/nginx/sites-available/llm-lb.conf and
#                 /etc/nginx/sites-enabled/llm-lb.conf, UFW allow
#                 for the LB port (80) from the LAN /24. The setup
#                 also removed the default site's enable symlink;
#                 uninstall does not restore it (the native
#                 teardown engine's manifest records the same).
#   Container form: containers/llm, one compose project holding
#                 the whole pool on a single Docker host:
#                 llm-heavy and llm-light inference containers
#                 behind the llm-lb container. Models are host
#                 files bind-mounted read-only; they are operator
#                 state and are never removed by this controller.
#                 Day-to-day lifecycle of a pure compose deployment
#                 belongs to docker compose in containers/llm and
#                 to the generic compose teardown engine
#                 (scripts/teardown/stack-teardown-v1.0.sh); this
#                 controller's uninstall still removes the three
#                 containers by name, as the sibling controllers do
#                 for their compose forms.
#
# The setup verb runs the stack's own setup script
# (nanopi-llm-setup.sh, beside this one) with everything after --
# passed through, because the setup needs a role (and a tier for
# the server role) that the controller will not guess:
#   sudo ./nanopi-llm-control-v1.0.sh setup -- --role server --tier 4gb
#   sudo ./nanopi-llm-control-v1.0.sh setup -- --role lb
# There is one install implementation and it stays there; this
# controller owns the lifecycle around it. The Ansible playbooks
# remain a parallel install path and are not wrapped.
#
# The uninstall footprint agrees with the native teardown engine's
# nanopi-llm manifest (scripts/teardown/manifests/nanopi-llm.manifest)
# and extends it in three recorded places: the UFW allow rules the
# setup created (the manifest does not track firewall rules; the
# sibling controllers remove theirs, and this one follows them),
# the container form's containers (the manifest is native-only),
# and the operator-home resolution (the manifest derives the home
# from the invoking sudo user; this controller prefers the unit's
# recorded User= and falls back to the same derivation).
#
# Preserved by default on uninstall (the expensive state):
#   - ~/llama.cpp (the source checkout and native build)
#   - ~/models (the GGUF model files)
#   - The container form's host models directory
#   - Logs under /var/log
# --purge removes ~/llama.cpp and ~/models as well. The operator
# account is never removed, purged or not.
#
# READ THIS BEFORE A REAL RUN
#   - Run any verb with --dry-run first and read the plan. Actions
#     are labeled, and on uninstall every data path is labeled
#     PRESERVED or PURGE before anything is touched.
#   - uninstall asks you to type a confirmation word (nanopi)
#     before it changes anything. start, stop, and restart do not
#     ask: they change runtime state only, nothing is removed.
#   - Model files are the expensive state (gigabytes to
#     re-download on a small board). They survive a default
#     uninstall. --purge deletes them and the llama.cpp build;
#     there is no undo.
#   - This controller never installs, removes, starts, or stops
#     the Docker daemon itself, and never removes the nginx
#     package or unit. Both are shared infrastructure. If the
#     Docker daemon is not reachable, container legs are skipped
#     with a note.
#   - systemctl calls that need a running systemd bus (start,
#     stop, disable, daemon-reload) are soft actions: in a
#     container or rescue shell they report an error despite
#     doing their offline half, so the script logs a plain note
#     and the state table and verification pass are the gate.
#   - Every action is logged to /var/log/nanopi-llm-control.log.
#
# Usage:
#   sudo ./nanopi-llm-control-v1.0.sh setup -- <setup options> [--dry-run]
#   sudo ./nanopi-llm-control-v1.0.sh start [--dry-run]
#   sudo ./nanopi-llm-control-v1.0.sh stop [--dry-run]
#   sudo ./nanopi-llm-control-v1.0.sh restart [--dry-run]
#   ./nanopi-llm-control-v1.0.sh status
#   sudo ./nanopi-llm-control-v1.0.sh uninstall [--dry-run] [--purge]
#
# Exit codes: 0 = the requested state is in place (or nothing to
# do), 1 = a verb failed, was aborted, or status found the stack
# not fully up, 2 = usage or environment error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/nanopi-llm-setup.sh"
LOG_FILE="/var/log/nanopi-llm-control.log"
CONFIRM_WORD="nanopi"
SERVER_PORT="8080"
LB_PORT="80"
UNIT_BASE="llama-server"
UNIT_FILE="/etc/systemd/system/llama-server.service"
SITE_AVAILABLE="/etc/nginx/sites-available/llm-lb.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/llm-lb.conf"
CONTAINERS=(llm-heavy llm-light llm-lb)

DRY_RUN="no"
PURGE="no"
VERB=""
SETUP_ARGS=()

usage() {
    cat <<'EOF'
Usage:
  nanopi-llm-control-v1.0.sh setup -- <setup options> [--dry-run]
  nanopi-llm-control-v1.0.sh start [--dry-run]
  nanopi-llm-control-v1.0.sh stop [--dry-run]
  nanopi-llm-control-v1.0.sh restart [--dry-run]
  nanopi-llm-control-v1.0.sh status
  nanopi-llm-control-v1.0.sh uninstall [--dry-run] [--purge]

  setup      Run the stack's setup script (beside this one) with
             the options after --, then show status. The setup
             needs a role: setup -- --role server --tier 4gb, or
             setup -- --role lb.
  start      Start the installed members: the llama-server unit
             (server role), nginx (LB role, when the llm-lb site
             is installed), and the pool containers that exist.
             Runtime only.
  stop       Stop the same members.
  restart    stop, then start.
  status     Show every member's state; exit 1 if anything that
             is installed is not running, or nothing is installed.
  uninstall  Remove the stack (both install forms) after a typed
             confirmation. The operator's llama.cpp build and
             models survive unless --purge is given. nginx and
             the operator account always survive.
  --dry-run  Print every action and change nothing.
EOF
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
fi
VERB="$1"
shift
PASSTHROUGH="no"
for arg in "$@"; do
    if [[ "$PASSTHROUGH" == "yes" ]]; then
        SETUP_ARGS+=("$arg")
        continue
    fi
    case "$arg" in
        --)        PASSTHROUGH="yes" ;;
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
if [[ ${#SETUP_ARGS[@]} -gt 0 && "$VERB" != "setup" ]]; then
    echo "Arguments after -- belong to the setup verb only." >&2
    usage >&2
    exit 2
fi
if [[ "$VERB" == "setup" && ${#SETUP_ARGS[@]} -eq 0 ]]; then
    echo "setup needs the setup script's own options after -- (the" >&2
    echo "controller will not guess a role):" >&2
    echo "  $0 setup -- --role server --tier 4gb" >&2
    echo "  $0 setup -- --role lb" >&2
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

# unit_file <name>: the unit's filename, honoring an explicit
# suffix and defaulting a bare name to .service. (Same resolver as
# the native teardown engine: never hardcode the suffix.)
unit_file() {
    case "$1" in
        *.service|*.timer|*.socket|*.mount|*.target|*.path|*.slice) printf '%s' "$1" ;;
        *) printf '%s.service' "$1" ;;
    esac
}

# unit_state <unit>: active, inactive, or unknown (no systemd bus,
# or systemctl itself missing). File presence is checked by the
# caller; this only reports runtime state.
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
# pipefail, an early grep -q exit SIGPIPEs the producer whenever
# the match is not its last line, and the pipeline then reports
# failure for a name that is present. grep without -q drains the
# listing.
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

# Role detection, from the footprint (a board holds the roles its
# files say it holds; the controller never assumes).
have_server_role() { [[ -f "$UNIT_FILE" ]]; }
have_lb_role() { [[ -e "$SITE_AVAILABLE" || -L "$SITE_ENABLED" || -e "$SITE_ENABLED" ]]; }

# resolve_operator_home: sets LLM_USER_RESOLVED and LLM_HOME_RESOLVED
# for the native server role's state. Order: the unit file's own
# User= (what the setup recorded), then $NANOPI_LLM_USER, then the
# invoking sudo user (the teardown manifest's derivation). The home
# comes from the account database, never from a guessed path.
LLM_USER_RESOLVED=""
LLM_HOME_RESOLVED=""
resolve_operator_home() {
    local user="" entry home=""
    if have_server_role; then
        user=$(awk -F= '$1 == "User" { print $2; exit }' "$UNIT_FILE")
    fi
    if [[ -z "$user" && -n "${NANOPI_LLM_USER:-}" ]]; then
        user="$NANOPI_LLM_USER"
    fi
    if [[ -z "$user" ]]; then
        user="${SUDO_USER:-${USER:-root}}"
    fi
    entry=$(getent passwd "$user" 2>/dev/null || true)
    if [[ -n "$entry" ]]; then
        local _n _p _u _g _gecos _shell
        IFS=: read -r _n _p _u _g _gecos home _shell <<< "$entry"
    fi
    if [[ -z "$home" ]]; then
        if [[ "$user" == "root" ]]; then
            home="/root"
        else
            home="/home/$user"
        fi
    fi
    LLM_USER_RESOLVED="$user"
    LLM_HOME_RESOLVED="$home"
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
    if have_server_role; then
        MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
        state=$(unit_state "$UNIT_BASE")
        printf '%-24s %s\n' "llama-server unit" "$state"
        [[ "$state" == "active" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
    else
        printf '%-24s %s\n' "llama-server unit" "not installed"
    fi
    if have_lb_role; then
        MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
        state=$(unit_state nginx)
        printf '%-24s %s\n' "nginx (llm-lb site)" "$state"
        [[ "$state" == "active" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
    else
        printf '%-24s %s\n' "nginx (llm-lb site)" "not installed"
    fi
    for c in "${CONTAINERS[@]}"; do
        state=$(container_state "$c")
        if [[ "$state" == "absent" ]]; then
            printf '%-24s %s\n' "container $c" "absent"
        else
            MEMBERS_PRESENT=$((MEMBERS_PRESENT + 1))
            printf '%-24s %s\n' "container $c" "$state"
            [[ "$state" == "running" ]] || MEMBERS_DOWN=$((MEMBERS_DOWN + 1))
        fi
    done
    # Informational only: the health endpoints of whichever native
    # roles are installed on this host.
    if have_server_role; then
        if curl -fsS -o /dev/null "http://127.0.0.1:${SERVER_PORT}/health" 2>/dev/null; then
            printf '%-24s %s\n' "server /health" "responding"
        else
            printf '%-24s %s\n' "server /health" "not responding"
        fi
    fi
    if have_lb_role; then
        if curl -fsS "http://127.0.0.1:${LB_PORT}/lb-health" 2>/dev/null | grep -F "llm-lb ok" >/dev/null; then
            printf '%-24s %s\n' "LB /lb-health" "responding"
        else
            printf '%-24s %s\n' "LB /lb-health" "not responding"
        fi
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# setup: run the stack's own setup script (options after --), then
# show the state table
# ───────────────────────────────────────────────────────────────────────────

do_setup() {
    log "════════════════════════════════════════════════════════════════"
    log "NanoPi LLM stack setup via the stack's setup script"
    log "Step 1 of 2: run the setup script (native form)"
    if [[ ! -f "$SETUP_SCRIPT" ]]; then
        log "Setup script not found: $SETUP_SCRIPT"
        log "This controller expects the setup script beside it in scripts/llm."
        exit 2
    fi
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "WOULD: run $SETUP_SCRIPT ${SETUP_ARGS[*]}"
        log "Step 2 of 2: show the member state table"
        log "Dry run complete. Nothing was changed."
        exit 0
    fi
    log "DO: run $SETUP_SCRIPT ${SETUP_ARGS[*]}"
    local rc=0
    "$SETUP_SCRIPT" "${SETUP_ARGS[@]}" || rc=$?
    if [[ $rc -ne 0 ]]; then
        log "Setup script exited with status $rc."
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
    if have_server_role; then
        run_soft "systemctl start $UNIT_BASE" systemctl start "$UNIT_BASE"
    else
        log "skip (absent): unit $(unit_file "$UNIT_BASE")"
    fi
    if have_lb_role; then
        run_soft "systemctl start nginx" systemctl start nginx
    else
        log "skip (absent): llm-lb site (nginx left alone)"
    fi
    if docker_ready; then
        local state c
        for c in "${CONTAINERS[@]}"; do
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
        local state c
        for c in "${CONTAINERS[@]}"; do
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
    if have_lb_role; then
        run_soft "systemctl stop nginx" systemctl stop nginx
    else
        log "skip (absent): llm-lb site (nginx left alone)"
    fi
    if have_server_role; then
        run_soft "systemctl stop $UNIT_BASE" systemctl stop "$UNIT_BASE"
    else
        log "skip (absent): unit $(unit_file "$UNIT_BASE")"
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
    log "NanoPi LLM stack start (dry-run=$DRY_RUN)"
    start_members
    finish_runtime_verb "Start"
}

do_stop() {
    log "════════════════════════════════════════════════════════════════"
    log "NanoPi LLM stack stop (dry-run=$DRY_RUN)"
    stop_members
    finish_runtime_verb "Stop"
}

do_restart() {
    log "════════════════════════════════════════════════════════════════"
    log "NanoPi LLM stack restart (dry-run=$DRY_RUN)"
    stop_members
    start_members
    finish_runtime_verb "Restart"
}

# ───────────────────────────────────────────────────────────────────────────
# status: read-only, any user, the strict gate
# ───────────────────────────────────────────────────────────────────────────

do_status() {
    say "NanoPi LLM stack status"
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
# uninstall: remove both forms; footprint per the setup script and
# the teardown engine's nanopi-llm manifest (see the header for the
# three recorded extensions)
# ───────────────────────────────────────────────────────────────────────────

do_uninstall() {
    local had_server="no" had_lb="no"
    have_server_role && had_server="yes"
    have_lb_role && had_lb="yes"
    resolve_operator_home
    local llama_dir="$LLM_HOME_RESOLVED/llama.cpp"
    local models_dir="$LLM_HOME_RESOLVED/models"

    log "════════════════════════════════════════════════════════════════"
    log "NanoPi LLM stack uninstall (dry-run=$DRY_RUN purge=$PURGE)"
    log "Roles detected on this host: server=$had_server lb=$had_lb"
    log "Operator (server role state owner): $LLM_USER_RESOLVED (home: $LLM_HOME_RESOLVED)"
    log "Will remove: the pool containers (llm-heavy, llm-light,"
    log "llm-lb) if present; the llama-server unit and its enable"
    log "links (server role); the llm-lb nginx site files (LB role);"
    log "and the UFW allow rules the setup added for the installed"
    log "roles' ports (8080 and 80, from the LAN)."
    log "Never removed: nginx itself, the operator account, the"
    log "container form's host models directory, and all logs."
    log "Note: the setup removed the default nginx site's enable"
    log "symlink when the LB role was installed; it is not restored."
    if [[ "$PURGE" == "yes" ]]; then
        log "PURGE: also removes $llama_dir and $models_dir."
    else
        log "Preserved: $llama_dir (llama.cpp checkout and build)"
        log "Preserved: $models_dir (GGUF models)"
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

    # Container form: the whole pool as three containers on one host
    log "Step 1 of 4: remove the container form"
    if command -v docker &>/dev/null; then
        local c
        for c in "${CONTAINERS[@]}"; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "$c" >/dev/null; then
                run "docker rm -f $c" docker rm -f "$c"
            else
                log "skip (absent): container $c"
            fi
        done
        log "preserved: the container form's host models directory"
        log "(a bind-mounted operator path; this controller never removes it)"
    else
        log "docker not present: container leg skipped"
    fi

    # Native server role: unit and enable links; state in the home
    log "Step 2 of 4: remove the native server role (unit; state stays unless --purge)"
    if [[ "$had_server" == "yes" ]]; then
        run_soft "systemctl disable --now $UNIT_BASE" systemctl disable --now "$UNIT_BASE"
    else
        log "skip (absent): unit $(unit_file "$UNIT_BASE")"
    fi
    rm_path "$UNIT_FILE"
    local link
    for link in /etc/systemd/system/*.wants/"$(unit_file "$UNIT_BASE")"; do
        rm_path "$link"
    done
    run_soft "systemctl daemon-reload" systemctl daemon-reload
    if [[ "$PURGE" == "yes" ]]; then
        rm_path "$llama_dir"
        rm_path "$models_dir"
    else
        if [[ -d "$models_dir" ]]; then
            log "preserved: $models_dir ($(du -sh "$models_dir" 2>/dev/null | cut -f1) of models)"
        fi
        if [[ -d "$llama_dir" ]]; then
            log "preserved: $llama_dir (llama.cpp checkout and build)"
        fi
        log "preserved: operator account $LLM_USER_RESOLVED (never removed)"
    fi

    # Native LB role: the stack's site only; nginx stays
    log "Step 3 of 4: remove the native LB role (llm-lb site; nginx stays)"
    rm_path "$SITE_ENABLED"
    rm_path "$SITE_AVAILABLE"
    if [[ "$had_lb" == "yes" ]]; then
        run_soft "systemctl reload nginx (drop the removed site)" systemctl reload nginx
    fi
    log "preserved: nginx package, unit, and its other sites"

    # UFW rules the setup added for the installed roles' ports
    log "Step 4 of 4: remove the UFW rules the setup added, if present"
    local ufw_out=""
    if command -v ufw &>/dev/null; then
        ufw_out=$(ufw status 2>/dev/null || true)
    fi
    if [[ "$ufw_out" == *"Status: active"* ]]; then
        local lan_addr="" lan_net="" port
        lan_addr=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '$2 !~ /^(docker|br-|veth|virbr|tun|tap)/ && addr == "" { addr = $4 }
                   END { print addr }')
        if [[ -n "$lan_addr" ]]; then
            lan_net="${lan_addr%.*}.0/24"
        fi
        if [[ -n "$lan_net" ]]; then
            local -a ports=()
            [[ "$had_server" == "yes" ]] && ports+=("$SERVER_PORT")
            [[ "$had_lb" == "yes" ]] && ports+=("$LB_PORT")
            if [[ ${#ports[@]} -eq 0 ]]; then
                log "no stack roles were installed: no UFW rules to remove"
            fi
            for port in "${ports[@]}"; do
                if grep -F "$port" <<< "$ufw_out" | grep -F "$lan_net" >/dev/null; then
                    run "ufw delete allow from ${lan_net} to any port $port proto tcp" \
                        ufw --force delete allow from "$lan_net" to any port "$port" proto tcp
                else
                    log "skip (absent): ufw rule for $port/tcp from the LAN"
                fi
            done
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

    local still=0 p c
    for p in "$UNIT_FILE" "$SITE_AVAILABLE" "$SITE_ENABLED"; do
        if [[ -e "$p" || -L "$p" ]]; then
            log "STILL PRESENT: $p"
            still=$((still + 1))
        fi
    done
    for link in /etc/systemd/system/*.wants/"$(unit_file "$UNIT_BASE")"; do
        if [[ -e "$link" || -L "$link" ]]; then
            log "STILL PRESENT: $link"
            still=$((still + 1))
        fi
    done
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        for c in "${CONTAINERS[@]}"; do
            if [[ "$(container_state "$c")" != "absent" ]]; then
                log "STILL PRESENT: container $c"
                still=$((still + 1))
            fi
        done
    fi
    if [[ "$PURGE" == "yes" ]]; then
        for p in "$llama_dir" "$models_dir"; do
            if [[ -e "$p" ]]; then
                log "STILL PRESENT: $p"
                still=$((still + 1))
            fi
        done
    fi

    log "════════════════════════════════════════════════════════════════"
    if [[ $FAILURES -gt 0 || $still -gt 0 ]]; then
        log "Uninstall finished WITH PROBLEMS: $FAILURES failed actions, $still artifacts still present."
        exit 1
    fi
    log "Uninstall complete. All targeted artifacts removed (or already absent)."
    log "To redeploy a native role: $0 setup -- --role server --tier 4gb"
    log "(or --role lb; equivalently: scripts/llm/nanopi-llm-setup.sh with the same options)"
    log "To redeploy the container form: docker compose up -d in containers/llm,"
    log "or manage that form with scripts/teardown/stack-teardown-v1.0.sh."
    log "Kept: logs in /var/log, the nginx install, the operator"
    log "account, and (unless --purge) the operator's llama.cpp"
    log "build and models."
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
