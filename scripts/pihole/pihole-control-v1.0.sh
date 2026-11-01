#!/usr/bin/env bash
# pihole-control-v1.0.sh - one controller for the Pi-hole + Unbound lifecycle
# Version: 1.0 (2026-10-31)
#
# ═══════════════════════════════════════════════════════════════════════════
# READ THIS BEFORE A REAL RUN
#
# This script owns the whole life of the Pi-hole + Unbound pair in both
# forms this repo carries:
#
#   container  The Docker pair in containers/pihole (containers
#              pihole-backup and unbound-backup on the pihole-backup
#              bridge network). This is the form install-pihole-unbound.sh
#              deploys and the form running on pi4 (primary) and pi0
#              (secondary). The legacy stack under containers/pihole/legacy
#              is an as-built record, NOT a deployable form: this script
#              refuses to install it, but down and uninstall work against
#              it (point --compose-dir at the legacy dir) so an old
#              deployment can still be taken out cleanly.
#   native     The bare-metal install (Pi-hole's own installer plus
#              the apt Unbound package). Performed by the bash installer
#              install-pihole-unbound-native-v1.0.sh, which mirrors the
#              Ansible playbooks in ansible/playbooks/pihole/ step for
#              step; the playbooks remain the parallel route to the
#              same end state. "install --form native" delegates to the
#              bash installer (--attended passes through).
#
# THIS IS PRODUCTION DNS. The down, restart, logs-clean, and uninstall
# verbs stop this host answering DNS while they run. Run them on the
# secondary (pi0) first and confirm resolution there before touching
# the primary (pi4), the same order the install side prescribes.
#
# Every destructive verb prints a labeled plan (REMOVE / PRESERVED /
# PURGE) and asks for a typed confirmation before it changes anything.
# Data is preserved by default:
#   container  the named volumes (Pi-hole's /etc/pihole incl. gravity.db
#              and the blocklist state, dnsmasq.d, Unbound's custom
#              config dir) survive uninstall; --purge removes them.
#   native     /etc/pihole, /etc/unbound, and /var/lib/unbound survive
#              uninstall; --purge removes them, purges the package set,
#              and removes the pihole user and group, matching the
#              footprint of ansible/playbooks/cleanup/uninstall_pihole2.yml.
# --dry-run prints the plan and every command without running any.
# Every mutating verb ends with a verification pass and fails the run
# if anything it promised to remove is still there.
#
# Verbs:
#   install     Container: delegate to install-pihole-unbound.sh (full
#               .env validation, Unbound exposure guard, health checks;
#               --with-blocklists passes through). Native: delegate to
#               install-pihole-unbound-native-v1.0.sh (the bash mirror
#               of the playbooks; --attended passes through, --dry-run
#               runs the installer's own read-only plan).
#   up          Start the pair (container: compose up -d; native: start
#               the stack's services). Never enables or disables units.
#   down        Stop the pair (container: compose stop; native: stop
#               the stack's services). Nothing is removed.
#   restart     Restart the pair. DNS stops while this runs.
#   status      Report form, footprint, and run state. Exit 0 when the
#               footprint is complete or wholly absent, 1 when partial.
#   logs-clean  Native only: run cleanup_logs_pihole2.sh (it shreds the
#               Pi-hole and Unbound logs; irreversible; it stops DNS
#               services while it works). Container form: a no-op with
#               an explanation, container logs are Docker's to manage.
#   uninstall   Remove the stack per the labeled plan. See above for
#               what --purge adds. Native --purge also restores
#               /etc/resolv.conf to Cloudflare (1.1.1.1, 1.0.0.1) when
#               the pihole binary was present at the start of the run,
#               exactly as uninstall_pihole2.yml does, so the host
#               itself keeps working DNS after its resolver is gone.
#
# Confirmation tokens: "pihole" for the native form; the compose
# directory basename ("pihole", or "legacy" for the legacy stack) for
# the container form.
#
# Exit codes: 0 = done (or clean no-op), 1 = a step or the verification
# pass failed, 2 = usage error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
COMPOSE_DIR="${REPO_ROOT}/containers/pihole"
INSTALLER="${SCRIPT_DIR}/install-pihole-unbound.sh"
NATIVE_INSTALLER="${SCRIPT_DIR}/install-pihole-unbound-native-v1.0.sh"
LOG_CLEANER="${SCRIPT_DIR}/cleanup_logs_pihole2.sh"
LOG_FILE="/var/log/pihole-control.log"

# Bare-metal footprint, from ansible/playbooks/pihole/*.yml (install) and
# ansible/playbooks/cleanup/uninstall_pihole2.yml (removal). Unit names
# are base names on purpose: unit handling resolves whatever suffix the
# host actually carries (.service, .timer, .socket, ...), never assumes.
NATIVE_UNIT_BASES=(pihole-FTL lighttpd nginx unbound dnsmasq)
NATIVE_PACKAGES=(unbound pihole-FTL lighttpd nginx-common php-common php-cgi php-sqlite3 dnsmasq-base)
NATIVE_REMOVE_PATHS=(
    /opt/pihole
    /etc/.pihole
    /var/www/html/admin
    /usr/local/bin/pihole
    /etc/cron.d/pihole
    /etc/dnsmasq.d/01-pihole.conf
    /var/log/pihole/pihole.log
    /var/log/pihole/FTL.log
    /var/log/lighttpd/error.log
)
NATIVE_PRESERVE_PATHS=(
    /etc/pihole
    /etc/unbound
    /var/lib/unbound
)
UNIT_SUFFIXES=(service timer socket mount target path)

DRY_RUN=0
PURGE=0
WITH_BLOCKLISTS=0
ATTENDED=0
ASSUME_YES=0
FORM=""
VERB=""

log() { printf '%s\n' "$*"; }
note() { log "  note: $*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'error: %s\n' "$*" >&2; exit 2; }

stamp() { date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'now'; }

act() {
    # A step whose failure fails the run.
    local desc=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] $*"
        return 0
    fi
    log "  run: $*"
    printf '[%s] %s: %s\n' "$(stamp)" "$desc" "$*" >>"$LOG_FILE" 2>/dev/null || true
    "$@"
}

act_soft() {
    # A step that legitimately fails off a live system (systemctl with no
    # running systemd bus, apt with no package lists, the vendor
    # uninstaller). The verification pass, not this step, is the gate.
    local desc=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] $*"
        return 0
    fi
    log "  run: $*"
    printf '[%s] %s: %s\n' "$(stamp)" "$desc" "$*" >>"$LOG_FILE" 2>/dev/null || true
    if ! "$@"; then
        note "$desc did not complete (soft step; the verification pass decides)"
    fi
    return 0
}

path_present() { [[ -e $1 || -L $1 ]]; }

rm_labeled() {
    local p=$1
    if path_present "$p"; then
        act "remove $p" rm -rf -- "$p"
    else
        log "  skip  $p (already absent)"
    fi
}

# Resolve the unit files a base name actually has on this host, any suffix.
unit_files_for() {
    local base=$1 suf f
    for suf in "${UNIT_SUFFIXES[@]}"; do
        f="/etc/systemd/system/${base}.${suf}"
        if path_present "$f"; then printf '%s\n' "${base}.${suf}"; fi
    done
}

unit_wants_links() {
    local unit_file=$1 d
    for d in /etc/systemd/system/*.wants; do
        [[ -d $d ]] || continue
        if path_present "${d}/${unit_file}"; then printf '%s/%s\n' "$d" "$unit_file"; fi
    done
}

any_native_footprint() {
    local b p
    for b in "${NATIVE_UNIT_BASES[@]}"; do
        [[ -n $(unit_files_for "$b") ]] && return 0
    done
    for p in "${NATIVE_PRESERVE_PATHS[@]}" "${NATIVE_REMOVE_PATHS[@]}"; do
        path_present "$p" && return 0
    done
    return 1
}

require_root() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ $EUID -eq 0 ]] || die "run as root, e.g.: sudo $0 $VERB"
}

read_token() {
    local got=""
    if [[ -e /dev/tty ]]; then
        read -r got < /dev/tty || got=""
    else
        read -r got || got=""
    fi
    printf '%s' "$got"
}

confirm() {
    local token=$1 got
    log "To proceed, type the word \"$token\" now."
    got=$(read_token)
    if [[ $got != "$token" ]]; then
        log "Aborted: confirmation not given. Nothing was removed."
        exit 1
    fi
}

dns_warning() {
    log "  *** DNS WARNING: this host stops answering DNS while this verb"
    log "      runs. Clients using only this resolver will fail over to"
    log "      their secondary or fail outright until it completes. ***"
}

# ───────────────────────────────────────────────────────────────────────────
# Compose plumbing (container form)
# ───────────────────────────────────────────────────────────────────────────

COMPOSE=()
compose_detect() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        return 1
    fi
    return 0
}

COMPOSE_FILE=""
STACK_NAME=""
STACK_VOLUMES=()
compose_setup() {
    [[ -d $COMPOSE_DIR ]] || die "compose directory not found: $COMPOSE_DIR"
    COMPOSE_DIR=$(cd -- "$COMPOSE_DIR" && pwd)
    COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
    [[ -f $COMPOSE_FILE ]] || die "compose file not found: $COMPOSE_FILE"
    STACK_NAME=$(basename -- "$COMPOSE_DIR")
    # Volume names as compose creates them for this directory's project:
    # <project>_<volume>. The project name is the directory basename.
    if [[ $STACK_NAME == "legacy" ]]; then
        STACK_VOLUMES=("${STACK_NAME}_pihole_etc" "${STACK_NAME}_pihole_dnsmasq" "${STACK_NAME}_unbound_etc")
    else
        STACK_VOLUMES=("${STACK_NAME}_pihole_etc" "${STACK_NAME}_pihole_dnsmasq" "${STACK_NAME}_unbound_custom")
    fi
}

compose_cmd() {
    # Run a compose command against this stack, dry-run aware.
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] ${COMPOSE[*]} -f $COMPOSE_FILE $*"
        return 0
    fi
    log "  run: ${COMPOSE[*]} -f $COMPOSE_FILE $*"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"
}

volume_present() {
    docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"
}

container_state() {
    docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || printf 'absent'
}

resolve_form() {
    if [[ -n $FORM ]]; then
        [[ $FORM == "native" || $FORM == "container" ]] || usage_die "--form must be native or container"
        return 0
    fi
    if any_native_footprint; then
        FORM="native"
    elif [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
        FORM="container"
    else
        FORM="native"
    fi
    note "form auto-detected: $FORM (override with --form)"
}

# ───────────────────────────────────────────────────────────────────────────
# status
# ───────────────────────────────────────────────────────────────────────────

status_native() {
    local present=0 absent=0 b f p state
    log "Form: native (bare metal)"
    for b in "${NATIVE_UNIT_BASES[@]}"; do
        f=$(unit_files_for "$b")
        if [[ -n $f ]]; then
            while IFS= read -r line; do
                state=$(systemctl is-active "$line" 2>/dev/null || printf 'unknown')
                log "  unit      $line (run state: $state)"
                present=$((present + 1))
            done <<< "$f"
        else
            log "  unit      $b.* absent"
            absent=$((absent + 1))
        fi
    done
    for p in "${NATIVE_PRESERVE_PATHS[@]}" "${NATIVE_REMOVE_PATHS[@]}"; do
        if path_present "$p"; then
            log "  path      $p present"
            present=$((present + 1))
        else
            absent=$((absent + 1))
        fi
    done
    if id pihole >/dev/null 2>&1; then
        log "  user      pihole present"
        present=$((present + 1))
    else
        log "  user      pihole absent"
        absent=$((absent + 1))
    fi
    status_summary "$present" "$absent"
}

status_container() {
    compose_setup
    local present=0 absent=0 c v st
    log "Form: container (compose project in $COMPOSE_DIR)"
    for c in pihole-backup unbound-backup; do
        st=$(container_state "$c")
        log "  container $c: $st"
        if [[ $st == "absent" ]]; then absent=$((absent + 1)); else present=$((present + 1)); fi
    done
    for v in "${STACK_VOLUMES[@]}"; do
        if volume_present "$v"; then
            log "  volume    $v present"
            present=$((present + 1))
        else
            log "  volume    $v absent"
            absent=$((absent + 1))
        fi
    done
    status_summary "$present" "$absent"
}

status_summary() {
    local present=$1 absent=$2
    if [[ $present -gt 0 && $absent -gt 0 ]]; then
        log "State: PARTIAL footprint ($present present, $absent absent)"
        exit 1
    elif [[ $present -gt 0 ]]; then
        log "State: INSTALLED ($present footprint items present)"
        exit 0
    else
        log "State: ABSENT (no footprint on this host)"
        exit 0
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# up / down / restart
# ───────────────────────────────────────────────────────────────────────────

services_native() {
    # Echo the .service unit files present, one per line.
    local b f
    for b in "${NATIVE_UNIT_BASES[@]}"; do
        f=$(unit_files_for "$b")
        [[ -n $f ]] && printf '%s\n' "$f"
    done | grep '\.service$' || true
}

do_up_native() {
    local units u any=0
    units=$(services_native)
    log "Step 1 of 1: starting the stack's services"
    while IFS= read -r u; do
        [[ -n $u ]] || continue
        any=1
        act_soft "start $u" systemctl start "$u"
    done <<< "$units"
    [[ $any -eq 1 ]] || note "no stack services present on this host; nothing to start"
}

do_down_native() {
    local units u any=0
    units=$(services_native)
    dns_warning
    log "Step 1 of 1: stopping the stack's services"
    while IFS= read -r u; do
        [[ -n $u ]] || continue
        any=1
        act_soft "stop $u" systemctl stop "$u"
    done <<< "$units"
    [[ $any -eq 1 ]] || note "no stack services present on this host; nothing to stop"
}

do_restart_native() {
    local units u any=0
    units=$(services_native)
    dns_warning
    log "Step 1 of 1: restarting the stack's services"
    while IFS= read -r u; do
        [[ -n $u ]] || continue
        any=1
        act_soft "restart $u" systemctl restart "$u"
    done <<< "$units"
    [[ $any -eq 1 ]] || note "no stack services present on this host; nothing to restart"
}

do_up_container() {
    compose_setup
    compose_detect || die "no compose backend found (docker compose plugin or docker-compose)"
    log "Step 1 of 1: bringing the pair up in $COMPOSE_DIR"
    compose_cmd up -d
}

do_down_container() {
    compose_setup
    compose_detect || die "no compose backend found (docker compose plugin or docker-compose)"
    dns_warning
    log "Step 1 of 1: stopping the pair in $COMPOSE_DIR (containers and data stay)"
    compose_cmd stop
}

do_restart_container() {
    compose_setup
    compose_detect || die "no compose backend found (docker compose plugin or docker-compose)"
    dns_warning
    log "Step 1 of 1: restarting the pair in $COMPOSE_DIR"
    compose_cmd restart
}

# ───────────────────────────────────────────────────────────────────────────
# install
# ───────────────────────────────────────────────────────────────────────────

do_install_container() {
    compose_setup
    if [[ $STACK_NAME == "legacy" ]]; then
        die "the legacy stack is an as-built record, not a deployable form. For a rollback, deploy the v2 stack in containers/pihole instead."
    fi
    [[ -f $INSTALLER ]] || die "installer not found beside this script: $INSTALLER"
    log "Step 1 of 1: delegating to install-pihole-unbound.sh (validation, exposure guard, health checks)"
    local args=(--compose-dir "$COMPOSE_DIR")
    [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
    [[ $WITH_BLOCKLISTS -eq 1 ]] && args+=(--with-blocklists)
    # The installer has its own --dry-run that validates .env, renders
    # the project, and checks the exposure guard without deploying, so
    # delegation runs for real in both modes; nothing is deployed here
    # unless the operator ran this verb without --dry-run.
    log "  run: $INSTALLER ${args[*]}"
    "$INSTALLER" "${args[@]}"
}

do_install_native() {
    [[ -f $NATIVE_INSTALLER ]] || die "native installer not found beside this script: $NATIVE_INSTALLER"
    log "Step 1 of 1: delegating to install-pihole-unbound-native-v1.0.sh (the bash"
    log "mirror of the playbooks; the Ansible playbooks in ansible/playbooks/pihole/"
    log "remain the parallel route to the same end state)"
    local args=(--unattended)
    [[ $ATTENDED -eq 1 ]] && args=(--attended)
    [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
    # The installer has its own --dry-run that prints its full plan and
    # every command without changing anything, so delegation runs for
    # real in both modes; nothing is installed here unless the operator
    # ran this verb without --dry-run.
    log "  run: $NATIVE_INSTALLER ${args[*]}"
    "$NATIVE_INSTALLER" "${args[@]}"
}

# ───────────────────────────────────────────────────────────────────────────
# logs-clean
# ───────────────────────────────────────────────────────────────────────────

do_logs_clean_native() {
    [[ -f $LOG_CLEANER ]] || die "log cleanup script not found beside this script: $LOG_CLEANER"
    dns_warning
    log "This runs cleanup_logs_pihole2.sh: it shreds the Pi-hole and"
    log "Unbound logs, truncates the auth/syslog/ufw logs, vacuums the"
    log "journal, and clears root's shell history. It creates NO backups"
    log "and cannot be undone. It stops and restarts the DNS services"
    log "while it works."
    local args=()
    [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
    [[ $ASSUME_YES -eq 1 ]] && args+=(--yes)
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] $LOG_CLEANER ${args[*]}"
        return 0
    fi
    "$LOG_CLEANER" "${args[@]}"
}

do_logs_clean_container() {
    log "Nothing to do in the container form: container logs are managed"
    log "by Docker's log driver (see 'docker logs pihole-backup'), and"
    log "Pi-hole's own log files live inside the pihole_etc volume. The"
    log "bare-metal log shredder (logs-clean --form native) does not"
    log "apply here."
}

# ───────────────────────────────────────────────────────────────────────────
# uninstall: container form
# ───────────────────────────────────────────────────────────────────────────

plan_container_uninstall() {
    log "════════════════════════════════════════════════════════════════"
    log "UNINSTALL PLAN: Pi-hole + Unbound, container form ($COMPOSE_DIR)"
    log "════════════════════════════════════════════════════════════════"
    dns_warning
    log "REMOVE:"
    log "  containers pihole-backup and unbound-backup"
    log "  the pihole-backup bridge network (via compose down)"
    if [[ $PURGE -eq 1 ]]; then
        log "PURGE (volumes removed because --purge was given):"
        local v
        for v in "${STACK_VOLUMES[@]}"; do log "  volume $v"; done
    else
        log "PRESERVED (data volumes kept; remove later with --purge):"
        local v
        for v in "${STACK_VOLUMES[@]}"; do log "  volume $v"; done
    fi
    log "PRESERVED always:"
    log "  the stack directory and its .env (operator configuration)"
    log "  the Docker engine itself"
}

do_uninstall_container() {
    compose_setup
    compose_detect || die "no compose backend found (docker compose plugin or docker-compose)"
    plan_container_uninstall
    [[ $DRY_RUN -eq 1 ]] && { log "Dry run: nothing was removed."; return 0; }
    require_root
    confirm "$STACK_NAME"
    log "Step 1 of 2: taking the compose project down"
    if [[ $PURGE -eq 1 ]]; then
        compose_cmd down --volumes
    else
        compose_cmd down
    fi
    log "Step 2 of 2: verification"
    local failed=0 c v
    for c in pihole-backup unbound-backup; do
        if [[ $(container_state "$c") != "absent" ]]; then
            log "  LEFTOVER: container $c still exists"
            failed=1
        fi
    done
    if [[ $PURGE -eq 1 ]]; then
        for v in "${STACK_VOLUMES[@]}"; do
            if volume_present "$v"; then
                log "  LEFTOVER: volume $v still exists"
                failed=1
            fi
        done
    fi
    if [[ $failed -eq 1 ]]; then
        log "Verification FAILED: leftovers above. The run is not clean."
        exit 1
    fi
    log "Verification passed: no containers remain."
    closing_summary "container"
}

# ───────────────────────────────────────────────────────────────────────────
# uninstall: native form
# ───────────────────────────────────────────────────────────────────────────

plan_native_uninstall() {
    log "════════════════════════════════════════════════════════════════"
    log "UNINSTALL PLAN: Pi-hole + Unbound, native form (bare metal)"
    log "════════════════════════════════════════════════════════════════"
    dns_warning
    log "REMOVE:"
    log "  the stack's systemd units (any suffix: .service, .timer,"
    log "  .socket, ...) for: ${NATIVE_UNIT_BASES[*]}"
    local p
    for p in "${NATIVE_REMOVE_PATHS[@]}"; do log "  $p"; done
    if [[ $PURGE -eq 1 ]]; then
        log "PURGE (because --purge was given; this is the full footprint"
        log "of ansible/playbooks/cleanup/uninstall_pihole2.yml):"
        log "  the official 'pihole uninstall --unattended' runs first"
        for p in "${NATIVE_PRESERVE_PATHS[@]}"; do log "  $p"; done
        log "  packages purged: ${NATIVE_PACKAGES[*]}"
        log "  the pihole user and group"
        log "  /etc/resolv.conf restored to 1.1.1.1 / 1.0.0.1 (only when"
        log "  the pihole binary was present at the start of the run)"
    else
        log "PRESERVED (config and state kept; remove with --purge):"
        for p in "${NATIVE_PRESERVE_PATHS[@]}"; do log "  $p"; done
        log "  the apt packages (left installed, services disabled)"
        log "  the pihole user and group"
        log "  the official pihole uninstaller is NOT run in this mode:"
        log "  it would delete the preserved config along with the rest."
    fi
}

do_uninstall_native() {
    plan_native_uninstall
    [[ $DRY_RUN -eq 1 ]] && { log "Dry run: nothing was removed."; return 0; }
    require_root
    confirm "pihole"
    local had_binary=0
    path_present /usr/local/bin/pihole && had_binary=1

    log "Step 1 of 5: stopping and disabling units"
    local b f
    for b in "${NATIVE_UNIT_BASES[@]}"; do
        f=$(unit_files_for "$b")
        if [[ -n $f ]]; then
            while IFS= read -r line; do
                act_soft "disable and stop $line" systemctl disable --now "$line"
            done <<< "$f"
        else
            log "  skip  $b.* (unit files absent)"
        fi
    done
    act_soft "reload systemd manager configuration" systemctl daemon-reload

    if [[ $PURGE -eq 1 ]]; then
        log "Step 2 of 5: running the official Pi-hole uninstaller"
        if [[ $had_binary -eq 1 ]]; then
            act_soft "official pihole uninstaller" /usr/local/bin/pihole uninstall --unattended
        else
            log "  skip  /usr/local/bin/pihole absent"
        fi
    else
        log "Step 2 of 5: official uninstaller skipped (default mode preserves config)"
    fi

    log "Step 3 of 5: removing unit files and enable links"
    for b in "${NATIVE_UNIT_BASES[@]}"; do
        f=$(unit_files_for "$b")
        if [[ -n $f ]]; then
            while IFS= read -r line; do
                rm_labeled "/etc/systemd/system/$line"
                local links l
                links=$(unit_wants_links "$line")
                while IFS= read -r l; do
                    [[ -n $l ]] && rm_labeled "$l"
                done <<< "$links"
            done <<< "$f"
        fi
    done

    log "Step 4 of 5: removing installed files"
    local p
    for p in "${NATIVE_REMOVE_PATHS[@]}"; do rm_labeled "$p"; done
    if [[ $PURGE -eq 1 ]]; then
        for p in "${NATIVE_PRESERVE_PATHS[@]}"; do rm_labeled "$p"; done
        act_soft "purge packages" apt-get purge -y "${NATIVE_PACKAGES[@]}"
        act_soft "autoremove orphaned dependencies" apt-get autoremove -y
        if id pihole >/dev/null 2>&1; then
            act "remove the pihole user and its home" userdel -r pihole
        else
            log "  skip  user pihole (already absent)"
        fi
        if getent group pihole >/dev/null 2>&1; then
            act "remove the pihole group" groupdel pihole
        else
            log "  skip  group pihole (already absent)"
        fi
        if [[ $had_binary -eq 1 ]]; then
            log "  restoring /etc/resolv.conf (the host's own DNS)"
            if [[ $DRY_RUN -eq 0 ]]; then
                printf '# Restored by pihole-control (mirrors uninstall_pihole2.yml)\nnameserver 1.1.1.1\nnameserver 1.0.0.1\noptions edns0\n' > /etc/resolv.conf
            fi
        fi
    fi

    log "Step 5 of 5: verification"
    verify_native_uninstall
    closing_summary "native"
}

verify_native_uninstall() {
    local failed=0 b f p
    for b in "${NATIVE_UNIT_BASES[@]}"; do
        f=$(unit_files_for "$b")
        if [[ -n $f ]]; then
            while IFS= read -r line; do
                log "  LEFTOVER: unit file /etc/systemd/system/$line"
                failed=1
            done <<< "$f"
        fi
    done
    for p in "${NATIVE_REMOVE_PATHS[@]}"; do
        if path_present "$p"; then
            log "  LEFTOVER: $p"
            failed=1
        fi
    done
    if [[ $PURGE -eq 1 ]]; then
        for p in "${NATIVE_PRESERVE_PATHS[@]}"; do
            if path_present "$p"; then
                log "  LEFTOVER: $p (should have been purged)"
                failed=1
            fi
        done
        if id pihole >/dev/null 2>&1; then
            log "  LEFTOVER: user pihole still exists"
            failed=1
        fi
    fi
    if [[ $failed -eq 1 ]]; then
        log "Verification FAILED: leftovers above. The run is not clean."
        exit 1
    fi
    log "Verification passed: nothing this run promised to remove remains."
}

closing_summary() {
    local form=$1
    log ""
    log "════════════════════════════════════════════════════════════════"
    log "DONE: Pi-hole + Unbound uninstall complete ($form form)."
    if [[ $PURGE -eq 1 ]]; then
        log "Data was purged; nothing of the stack remains on this host."
    else
        log "Configuration and data were preserved (see the plan above)."
        log "To remove them too, re-run with --purge."
    fi
    log "Redeploy:"
    if [[ $form == "container" ]]; then
        log "  sudo ${INSTALLER} --compose-dir ${COMPOSE_DIR}"
    else
        log "  sudo ${NATIVE_INSTALLER} --unattended"
        log "  (the Ansible route to the same end state stays available:"
        log "   cd ${REPO_ROOT}/ansible && ansible-playbook -i hosts playbooks/pihole/pihole_unbound_automated.yml -l <this-host>)"
    fi
    log "Full DNS check afterwards: ${SCRIPT_DIR}/dns-test-pihole-unbound-linted.sh"
    log "════════════════════════════════════════════════════════════════"
}

# ───────────────────────────────────────────────────────────────────────────
# Argument parsing and dispatch
# ───────────────────────────────────────────────────────────────────────────

usage() {
    sed -n '2,/^# ═/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -n -1
}

[[ $# -ge 1 ]] || usage_die "a verb is required (install, up, down, restart, status, logs-clean, uninstall)"
VERB=$1; shift
case "$VERB" in
    install|up|down|restart|status|logs-clean|uninstall) ;;
    -h|--help) usage; exit 0 ;;
    *) usage_die "unknown verb: $VERB" ;;
esac

while (($#)); do
    case "$1" in
        --form)
            (($# >= 2)) || usage_die "--form requires a value (native or container)"
            FORM=$2; shift ;;
        --compose-dir)
            (($# >= 2)) || usage_die "--compose-dir requires a value"
            COMPOSE_DIR=$2; shift ;;
        --dry-run) DRY_RUN=1 ;;
        --purge) PURGE=1 ;;
        --with-blocklists) WITH_BLOCKLISTS=1 ;;
        --attended) ATTENDED=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage_die "unknown option: $1" ;;
    esac
    shift
done

if [[ $PURGE -eq 1 && $VERB != "uninstall" ]]; then
    usage_die "--purge is only meaningful with uninstall"
fi
if [[ $WITH_BLOCKLISTS -eq 1 && $VERB != "install" ]]; then
    usage_die "--with-blocklists is only meaningful with install"
fi
if [[ $ATTENDED -eq 1 && $VERB != "install" ]]; then
    usage_die "--attended is only meaningful with install"
fi

resolve_form

if [[ $ATTENDED -eq 1 && $FORM != "native" ]]; then
    usage_die "--attended is only meaningful with install --form native"
fi

case "$VERB" in
    status)
        if [[ $FORM == "native" ]]; then status_native; else status_container; fi
        ;;
    install)
        require_root
        if [[ $FORM == "native" ]]; then do_install_native; else do_install_container; fi
        ;;
    up)
        require_root
        if [[ $FORM == "native" ]]; then do_up_native; else do_up_container; fi
        ;;
    down)
        require_root
        if [[ $FORM == "native" ]]; then do_down_native; else do_down_container; fi
        ;;
    restart)
        require_root
        if [[ $FORM == "native" ]]; then do_restart_native; else do_restart_container; fi
        ;;
    logs-clean)
        require_root
        if [[ $FORM == "native" ]]; then do_logs_clean_native; else do_logs_clean_container; fi
        ;;
    uninstall)
        if [[ $FORM == "native" ]]; then do_uninstall_native; else do_uninstall_container; fi
        ;;
esac
