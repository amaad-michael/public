#!/usr/bin/env bash
#===============================================================================
# jenkins-control-v1.0.sh - one controller for the whole Jenkins lifecycle
#
# READ THIS BEFORE A REAL RUN
#   This script owns Jenkins end to end, in the same shape as the neo1
#   observability control script and the Gitea controller: one entry
#   point, symmetrical verbs, and no verb reimplements what another
#   repo script already does well.
#
#   FORMS (pick with --form; default native)
#     native    The package install. Two install routes create the
#               identical footprint, and this controller's status and
#               uninstall cover both: the bash installer
#               (scripts/provisioning/install-jenkins-rocky.sh, which
#               this controller's install verb runs as-is) and the
#               Ansible playbook (ansible/playbooks/jenkins/
#               install_jenkins.yml, a parallel path this controller
#               does not wrap). Jenkins runs as the systemd unit
#               jenkins.service (the package's unit file lives under
#               /usr/lib/systemd/system; an admin copy may shadow it
#               from /etc/systemd/system), data at /var/lib/jenkins,
#               service account jenkins, web port 8080. The JNLP
#               agent port 50000 is opened only when the installer
#               was run with --with-agent-port.
#     container containers/jenkins: a single container named jenkins
#               (image jenkins/jenkins:2.580.1-lts, the same LTS the
#               Ansible form pins), home in the named Docker volume
#               whose name ends in jenkins_home (mounted at
#               /var/jenkins_home inside the container), web port
#               8080, agent port not published. The stack needs no
#               .env file; it holds no host-side secrets.
#
#   VERBS
#     install    Native: run the sibling bash installer as-is (pass
#                its options after a -- separator, for example
#                install -- --with-agent-port). Container: check the
#                stack and bring it up with docker compose.
#     up         Native: systemctl start jenkins. Container: compose up.
#     down       Native: systemctl stop jenkins. Container: compose
#                down (the data volume is kept; down is not uninstall).
#     restart    Native: systemctl restart jenkins. Container: restart.
#     status     Print the footprint and the service state. Exit 0
#                when the stack is fully installed, 1 when it is
#                missing or partial. Run state is reported as a field,
#                not folded into the exit code: this is a lifecycle
#                controller, and "installed but stopped" is a normal
#                state during a redeploy cycle.
#     uninstall  Remove the stack (the footprint below). Needs a
#                typed confirmation.
#
#   FOOTPRINT (native; the same removal set as
#   ansible/playbooks/cleanup/uninstall_jenkins.yml)
#     REMOVE: the jenkins package (dnf or apt, when a package manager
#     has it), the unit files and the enable symlink, the repository
#     files (/etc/yum.repos.d/jenkins.repo and the Debian apt list and
#     keyring paths, removed when present), /etc/sysconfig/jenkins,
#     /etc/default/jenkins, /etc/jenkins, /var/cache/jenkins, and
#     /var/log/jenkins.
#     PRESERVED by default: /var/lib/jenkins (every job, plugin,
#     credential, and build record), and the jenkins user and group
#     that own it.
#     PURGE (--purge on uninstall) removes the preserved data too and
#     deletes the jenkins user and group. There is no undo for a purge.
#     The purge removes the user before the group on purpose: groupdel
#     refuses to remove a primary group while its user still exists.
#
#   DIFFERENCE FROM THE ANSIBLE UNINSTALL, ON PURPOSE
#     The Ansible uninstall playbook archives /var/lib/jenkins to
#     /var/backups/jenkins and then deletes everything, home included.
#     This controller preserves the home in place instead of archiving
#     it; a --purge run reaches the same end state minus the archive.
#     If you want the forensic archive, run the Ansible playbook.
#     /var/backups/jenkins is the playbook's directory: this controller
#     never creates it and never removes it.
#
#   LEFT IN PLACE ON PURPOSE
#     Firewall rules: the installers open 8080 (and 50000 with the
#     agent option) in firewalld; closing them is a separate operator
#     decision, and the uninstall summary prints the commands. Java
#     stays (the installers install it, but it is a shared tool).
#
#   CONFIRMATION
#     uninstall asks you to type the word: jenkins
#     A wrong or empty answer aborts with nothing changed.
#     --dry-run prints the full labeled plan and changes nothing,
#     and never asks for confirmation.
#
#   Every mutating verb logs to /var/log/jenkins-control.log
#   (screen output plus the file; command output goes to the file).
#
#   Exit codes: 0 = done or already in the requested state,
#   1 = a step or the closing verification failed, 2 = usage error.
#===============================================================================
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

FORM="native"
DRY_RUN=0
PURGE=0
STACK_DIR="${JENKINS_STACK_DIR:-${REPO_ROOT}/containers/jenkins}"
INSTALLER="${SCRIPT_DIR}/install-jenkins-rocky.sh"
declare -a INSTALLER_ARGS=()

UNIT="jenkins"
UNIT_FILES=("/etc/systemd/system/jenkins.service" "/usr/lib/systemd/system/jenkins.service")
WANTS_LINK="/etc/systemd/system/multi-user.target.wants/jenkins.service"
DATA_DIR="/var/lib/jenkins"
LOG_DIR_J="/var/log/jenkins"
CACHE_DIR="/var/cache/jenkins"
ETC_DIR="/etc/jenkins"
ENV_FILES=("/etc/sysconfig/jenkins" "/etc/default/jenkins")
REPO_FILES=("/etc/yum.repos.d/jenkins.repo" "/etc/apt/sources.list.d/jenkins.list" "/usr/share/keyrings/jenkins-keyring.gpg" "/etc/apt/trusted.gpg.d/jenkins.gpg" "/etc/apt/trusted.gpg.d/jenkins-keyring.gpg")
JENKINS_USER="jenkins"
JENKINS_GROUP="jenkins"
WEB_PORT=8080
AGENT_PORT=50000
CONTAINER_NAME="jenkins"

CONFIRM_TOKEN="jenkins"
LOG_FILE="/var/log/jenkins-control.log"
LOG_TARGET="$LOG_FILE"
FAILURES=0

usage() {
    cat <<'EOF'
Usage:
  jenkins-control-v1.0.sh install   [--form native|container] [--dry-run]
                                    [-- installer options, native only]
  jenkins-control-v1.0.sh up        [--form native|container] [--dry-run]
  jenkins-control-v1.0.sh down      [--form native|container] [--dry-run]
  jenkins-control-v1.0.sh restart   [--form native|container] [--dry-run]
  jenkins-control-v1.0.sh status    [--form native|container]
  jenkins-control-v1.0.sh uninstall [--form native|container] [--dry-run] [--purge]
  jenkins-control-v1.0.sh --stack-dir PATH   (container form stack location;
                                              may appear before the verb)

  Native install runs scripts/provisioning/install-jenkins-rocky.sh
  as-is; anything after a -- separator is passed to it (for example
  install -- --with-agent-port --java 21). The Ansible install
  playbook (ansible/playbooks/jenkins/install_jenkins.yml) is the
  parallel install route and is not wrapped; status and uninstall
  cover its installs identically.
EOF
}

die_usage() {
    echo "ERROR: $1" >&2
    usage >&2
    exit 2
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: this verb must run as root" >&2
        exit 1
    fi
}

#---------------------------------------------------------------------------
# Logging and command runners (mutating verbs)
#---------------------------------------------------------------------------
setup_log() {
    # If the log file cannot be opened (read-only /var/log), fall back
    # to /dev/null so the screen output keeps working unchanged.
    if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
        LOG_TARGET="/dev/null"
        echo "note: cannot write $LOG_FILE; this run will not be logged to a file"
    fi
}

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_TARGET"
}

say() {
    printf '%s\n' "$*"
}

# run <description> <command...>: execute (or print, under --dry-run).
# Command output goes to the log file. A failure is counted; the
# verb's verification pass decides the final exit code.
run() {
    local desc="$1"
    shift
    if [ "$DRY_RUN" -eq 1 ]; then
        log "WOULD: $desc"
        return 0
    fi
    log "DO: $desc"
    if ! "$@" >> "$LOG_TARGET" 2>&1; then
        log "!! FAILED: $desc"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    return 0
}

# run_soft <description> <command...>: like run, but a failure is
# expected in one known case: systemctl operations that need a
# running systemd bus (disable --now, daemon-reload, stop in a
# container or rescue shell). Logged plainly, never counted; the
# closing verification pass is the gate.
run_soft() {
    local desc="$1"
    shift
    if [ "$DRY_RUN" -eq 1 ]; then
        log "WOULD: $desc"
        return 0
    fi
    log "DO: $desc"
    if ! "$@" >> "$LOG_TARGET" 2>&1; then
        log "note: '$desc' reported an error (no running systemd bus is the usual cause); continuing, the verification pass at the end is the gate"
    fi
    return 0
}

# rm_path <path>: remove a file or directory tree when it exists.
rm_path() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        run "remove $path" rm -rf -- "$path"
    else
        log "skip (absent): $path"
    fi
}

path_state() {
    # prints: present | absent (dangling symlinks count as present)
    if [ -e "$1" ] || [ -L "$1" ]; then
        echo "present"
    else
        echo "absent"
    fi
}

#---------------------------------------------------------------------------
# Native-form state probes
#---------------------------------------------------------------------------
service_state() {
    local out
    out=$(systemctl is-active "$UNIT" 2>/dev/null) || true
    if [ -z "$out" ]; then
        echo "unknown (no systemd bus)"
    else
        echo "$out"
    fi
}

unit_file_found() {
    local f
    for f in "${UNIT_FILES[@]}"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

pkg_manager() {
    if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
        echo "apt"
    else
        echo "none"
    fi
}

pkg_installed() {
    local mgr status
    mgr=$(pkg_manager)
    case "$mgr" in
        dnf)
            rpm -q jenkins >/dev/null 2>&1
            ;;
        apt)
            status=$(dpkg-query -W -f='${Status}' jenkins 2>/dev/null) || return 1
            [ "${status#*install ok installed}" != "$status" ]
            ;;
        *)
            return 1
            ;;
    esac
}

#---------------------------------------------------------------------------
# Container-form state probes. Listings are captured whole into a
# variable and matched line by line in pure bash: nothing is piped
# into an early-exit grep, so a producer can never be SIGPIPEd into
# reporting a present container or volume as absent (the pipefail
# grep -q defect found in sibling packages on 2026-10-31).
#---------------------------------------------------------------------------
docker_names() {
    docker ps -a --format '{{.Names}}' 2>/dev/null
}

container_present() {
    local out line
    out=$(docker_names) || out=""
    while IFS= read -r line; do
        if [ "$line" = "$CONTAINER_NAME" ]; then
            return 0
        fi
    done <<< "$out"
    return 1
}

volume_present() {
    local out line
    out=$(docker volume ls --format '{{.Name}}' 2>/dev/null) || out=""
    while IFS= read -r line; do
        if [ "$line" = "jenkins_home" ] || [ "${line%_jenkins_home}" != "$line" ]; then
            return 0
        fi
    done <<< "$out"
    return 1
}

compose_containers_exist() {
    local out line
    out=$(cd "$STACK_DIR" && docker compose ps -a --format '{{.Name}}' 2>/dev/null) || out=""
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            return 0
        fi
    done <<< "$out"
    return 1
}

compose_run() {
    # run a docker compose command inside the stack dir, in this
    # shell (not a subshell) so run() failure counting still works.
    local desc="$1"
    shift
    local old="$PWD"
    cd "$STACK_DIR" || return 1
    run "$desc" docker compose "$@"
    local rc=$?
    cd "$old" || true
    return $rc
}

confirm_uninstall() {
    local reply=""
    echo ""
    echo "Type the word '${CONFIRM_TOKEN}' to proceed with the uninstall:"
    if [ -r /dev/tty ]; then
        read -r reply < /dev/tty || reply=""
    else
        read -r reply || reply=""
    fi
    if [ "$reply" != "$CONFIRM_TOKEN" ]; then
        echo "Confirmation did not match. Nothing was changed."
        exit 1
    fi
}

redeploy_hint() {
    case "$FORM" in
        native)
            echo "scripts/provisioning/jenkins-control-v1.0.sh install (bash installer), or the Ansible route: ansible-playbook -i hosts playbooks/jenkins/install_jenkins.yml" ;;
        container)
            echo "scripts/provisioning/jenkins-control-v1.0.sh install --form container" ;;
    esac
}

#---------------------------------------------------------------------------
# install
#---------------------------------------------------------------------------
do_install() {
    require_root
    setup_log
    log "Step 1 of 1: Install Jenkins (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { log "ERROR: container stack not found at ${STACK_DIR}"; exit 1; }
        [ -f "${STACK_DIR}/docker-compose.yml" ] || { log "ERROR: no docker-compose.yml in ${STACK_DIR}"; exit 1; }
        if ! command -v docker >/dev/null 2>&1; then
            log "ERROR: docker is not installed; the container form needs Docker with the compose plugin"
            exit 1
        fi
        log "Bringing the stack up from ${STACK_DIR} (no .env needed; the stack holds no host-side secrets):"
        compose_run "docker compose up -d" up -d
        if [ "$FAILURES" -gt 0 ]; then
            log "Install finished WITH PROBLEMS: $FAILURES failed actions."
            exit 1
        fi
        log "Next step (from containers/jenkins/README.md): read the first-run password with:"
        log "  docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
        log "Web UI: http://<host>:${WEB_PORT}. The agent port ${AGENT_PORT} stays unpublished by design."
        return 0
    fi
    [ -f "$INSTALLER" ] || { log "ERROR: installer not found: ${INSTALLER}"; exit 1; }
    log "Running the sibling installer as-is (it is idempotent; re-running is its upgrade path):"
    run "run scripts/provisioning/install-jenkins-rocky.sh" bash "$INSTALLER" "${INSTALLER_ARGS[@]}"
    if [ "$FAILURES" -gt 0 ]; then
        log "Install finished WITH PROBLEMS: $FAILURES failed actions."
        exit 1
    fi
    log "Next steps:"
    log "  1. Open http://<host>:${WEB_PORT} and paste the initial admin password from"
    log "     ${DATA_DIR}/secrets/initialAdminPassword into the Unlock Jenkins page."
    log "  2. The Ansible route (ansible/playbooks/jenkins/install_jenkins.yml) installs"
    log "     the identical footprint; this controller's status and uninstall cover it."
}

#---------------------------------------------------------------------------
# up / down / restart
#---------------------------------------------------------------------------
do_up() {
    require_root
    setup_log
    log "Step 1 of 1: Bring Jenkins up (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { log "ERROR: container stack not found at ${STACK_DIR}"; exit 1; }
        compose_run "docker compose up -d" up -d
        if [ "$FAILURES" -gt 0 ]; then
            exit 1
        fi
        log "Container stack up requested. Check with: jenkins-control-v1.0.sh status --form container"
        return 0
    fi
    run_soft "start the jenkins service" systemctl start "$UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        log "jenkins service state: $(service_state)"
    fi
}

do_down() {
    require_root
    setup_log
    log "Step 1 of 1: Bring Jenkins down (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { log "ERROR: container stack not found at ${STACK_DIR}"; exit 1; }
        compose_run "docker compose down" down
        if [ "$FAILURES" -gt 0 ]; then
            exit 1
        fi
        log "Container stack is down. The jenkins_home volume is untouched;"
        log "uninstall is the verb that talks about removing anything."
        return 0
    fi
    run_soft "stop the jenkins service" systemctl stop "$UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        log "jenkins service state: $(service_state)"
    fi
}

do_restart() {
    require_root
    setup_log
    log "Step 1 of 1: Restart Jenkins (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { log "ERROR: container stack not found at ${STACK_DIR}"; exit 1; }
        compose_run "docker compose restart" restart
        if [ "$FAILURES" -gt 0 ]; then
            exit 1
        fi
        return 0
    fi
    run_soft "restart the jenkins service" systemctl restart "$UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        log "jenkins service state: $(service_state)"
    fi
}

#---------------------------------------------------------------------------
# status
#---------------------------------------------------------------------------
row() {
    printf '%-24s %s\n' "$1" "$2"
}

do_status_native() {
    local missing=0 uf mgr
    say "Jenkins status (form: native)"
    if uf=$(unit_file_found); then
        row "unit file" "$uf"
    else
        row "unit file" "ABSENT (looked in /etc/systemd/system and /usr/lib/systemd/system)"
        missing=1
    fi
    mgr=$(pkg_manager)
    if pkg_installed; then
        row "package" "jenkins (installed, via ${mgr})"
    elif [ "$mgr" = "none" ]; then
        row "package" "unknown (no package manager found)"
    else
        row "package" "not installed (via ${mgr})"
    fi
    if [ -f "${ENV_FILES[0]}" ] || [ -f "${ENV_FILES[1]}" ]; then
        row "environment file" "present (${ENV_FILES[0]} or ${ENV_FILES[1]})"
    else
        row "environment file" "absent (neither ${ENV_FILES[0]} nor ${ENV_FILES[1]})"
    fi
    if [ -f "${REPO_FILES[0]}" ]; then
        row "repository file" "${REPO_FILES[0]}"
    else
        row "repository file" "absent (${REPO_FILES[0]})"
    fi
    if [ -d "$DATA_DIR" ]; then
        row "data" "$DATA_DIR"
    else
        row "data" "ABSENT ($DATA_DIR)"
        missing=1
    fi
    if id "$JENKINS_USER" >/dev/null 2>&1; then
        row "service account" "${JENKINS_USER} (home ${DATA_DIR})"
    else
        row "service account" "ABSENT (${JENKINS_USER})"
        missing=1
    fi
    row "service state" "$(service_state)"
    row "ports" "web ${WEB_PORT}; agent ${AGENT_PORT} only if opened at install"
    if [ "$missing" -eq 1 ]; then
        say "Verdict: not fully installed (see ABSENT lines above)."
        return 1
    fi
    say "Verdict: installed. Service state is the field above."
    return 0
}

do_status_container() {
    say "Jenkins status (form: container)"
    local missing=0
    if [ -d "$STACK_DIR" ]; then
        row "stack dir" "$STACK_DIR"
    else
        row "stack dir" "ABSENT ($STACK_DIR)"
        missing=1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        row "docker" "not installed"
        say "Verdict: cannot inspect containers without docker."
        return 1
    fi
    row "docker" "available"
    if [ "$missing" -eq 0 ]; then
        say ""
        ( cd "$STACK_DIR" && docker compose ps ) || true
        say ""
        if container_present; then
            row "container" "${CONTAINER_NAME} exists"
        else
            row "container" "${CONTAINER_NAME} not created yet"
        fi
        if volume_present; then
            row "data volume" "present (name ends in jenkins_home)"
        else
            row "data volume" "not created yet"
        fi
    fi
    if [ "$missing" -eq 1 ]; then
        say "Verdict: not fully installed (see ABSENT lines above)."
        return 1
    fi
    say "Verdict: installed. Container state is the table above."
    return 0
}

do_status() {
    if [ "$FORM" = "container" ]; then
        do_status_container
    else
        do_status_native
    fi
}

#---------------------------------------------------------------------------
# uninstall (native)
#---------------------------------------------------------------------------
native_remove_set_present() {
    local p
    local -a paths=("${UNIT_FILES[@]}" "$WANTS_LINK" "${REPO_FILES[@]}" "${ENV_FILES[@]}" "$ETC_DIR" "$CACHE_DIR" "$LOG_DIR_J")
    for p in "${paths[@]}"; do
        if [ "$(path_state "$p")" = "present" ]; then
            return 0
        fi
    done
    if pkg_installed; then
        return 0
    fi
    return 1
}

print_native_uninstall_plan() {
    log "Uninstall plan: Jenkins (form: native)"
    log ""
    log "REMOVE:"
    log "  the jenkins package (dnf or apt, when a package manager has it)"
    log "  the unit files (/etc/systemd/system/jenkins.service and"
    log "    /usr/lib/systemd/system/jenkins.service, whichever exist)"
    log "  ${WANTS_LINK} (enable symlink, if present)"
    log "  the repository files (removed when present):"
    local p
    for p in "${REPO_FILES[@]}"; do
        log "    $p"
    done
    log "  ${ENV_FILES[0]} and ${ENV_FILES[1]} (environment files, when present)"
    log "  ${ETC_DIR} (config directory)"
    log "  ${CACHE_DIR} (cache directory)"
    log "  ${LOG_DIR_J} (log directory)"
    log ""
    log "PRESERVED:"
    log "  ${DATA_DIR} (every job, plugin, credential, and build record)"
    if [ "$PURGE" -eq 1 ]; then
        log ""
        log "PURGE (because --purge was given):"
        log "  ${DATA_DIR} (the preserved data above is removed after all)"
        log "  user ${JENKINS_USER} and group ${JENKINS_GROUP}"
    else
        log "  the ${JENKINS_USER} user and group (they own the preserved data)"
        log "  (Re-run with --purge to remove the data and the account too.)"
    fi
    log ""
    log "LEFT IN PLACE ON PURPOSE:"
    log "  firewalld rules for ports ${WEB_PORT} and ${AGENT_PORT} (the uninstall summary"
    log "    prints the commands to close them, if you want them closed)"
    log "  Java (a shared tool), and /var/backups/jenkins (the Ansible"
    log "    uninstall's archive directory; this controller never touches it)"
    log ""
    log "The service is stopped and disabled first."
}

verify_native_uninstall() {
    local fail=0 p
    local -a paths=("${UNIT_FILES[@]}" "$WANTS_LINK" "${REPO_FILES[@]}" "${ENV_FILES[@]}" "$ETC_DIR" "$CACHE_DIR" "$LOG_DIR_J")
    for p in "${paths[@]}"; do
        if [ "$(path_state "$p")" = "present" ]; then
            log "  LEFTOVER: $p is still present"
            fail=1
        fi
    done
    if pkg_installed; then
        log "  LEFTOVER: the jenkins package is still installed"
        fail=1
    fi
    if [ "$PURGE" -eq 1 ]; then
        if [ "$(path_state "$DATA_DIR")" = "present" ]; then
            log "  LEFTOVER: $DATA_DIR is still present"
            fail=1
        fi
        if id "$JENKINS_USER" >/dev/null 2>&1; then
            log "  LEFTOVER: user ${JENKINS_USER} still exists"
            fail=1
        fi
        if getent group "$JENKINS_GROUP" >/dev/null 2>&1; then
            log "  LEFTOVER: group ${JENKINS_GROUP} still exists"
            fail=1
        fi
    else
        if [ "$(path_state "$DATA_DIR")" != "present" ]; then
            log "  PROBLEM: ${DATA_DIR} should have been preserved but is gone"
            fail=1
        fi
    fi
    return $fail
}

do_uninstall_native() {
    # Armed by the REMOVE set (or the package) still being present.
    # Preserved data alone does not re-arm a default uninstall; a
    # --purge run is armed by the data or the account still existing.
    if ! native_remove_set_present; then
        if [ "$PURGE" -eq 1 ] && { [ "$(path_state "$DATA_DIR")" = "present" ] || id "$JENKINS_USER" >/dev/null 2>&1; }; then
            :
        elif [ "$(path_state "$DATA_DIR")" = "present" ]; then
            log "Jenkins (form: native) is already uninstalled."
            log "Preserved data remains at ${DATA_DIR}; the ${JENKINS_USER} account remains too."
            log "Re-run with --purge to remove both."
            return 0
        else
            log "Jenkins (form: native) is not installed on this host. Nothing to do."
            return 0
        fi
    fi

    print_native_uninstall_plan
    if [ "$DRY_RUN" -eq 1 ]; then
        log ""
        log "DRY-RUN: nothing was changed."
        return 0
    fi
    confirm_uninstall

    log ""
    log "Step 1 of 4: Stop and disable the service"
    run_soft "disable and stop jenkins" systemctl disable --now "$UNIT"

    log ""
    log "Step 2 of 4: Remove the package"
    local mgr
    mgr=$(pkg_manager)
    if pkg_installed; then
        case "$mgr" in
            dnf) run "remove the jenkins package (dnf)" dnf remove -y jenkins ;;
            apt) run "remove the jenkins package (apt)" apt-get remove --purge -y jenkins ;;
        esac
    else
        log "skip: no package manager reports jenkins installed (files are removed directly below)"
    fi

    log ""
    log "Step 3 of 4: Remove unit files, repository and config files, cache and logs"
    local p
    for p in "${UNIT_FILES[@]}"; do
        rm_path "$p"
    done
    rm_path "$WANTS_LINK"
    for p in "${REPO_FILES[@]}"; do
        rm_path "$p"
    done
    for p in "${ENV_FILES[@]}"; do
        rm_path "$p"
    done
    rm_path "$ETC_DIR"
    rm_path "$CACHE_DIR"
    rm_path "$LOG_DIR_J"
    run_soft "reload systemd manager configuration" systemctl daemon-reload

    log ""
    if [ "$PURGE" -eq 1 ]; then
        log "Step 4 of 4: Purge data and the service account"
        rm_path "$DATA_DIR"
        if id "$JENKINS_USER" >/dev/null 2>&1; then
            run "remove user ${JENKINS_USER}" userdel "$JENKINS_USER"
        else
            log "skip (absent): user ${JENKINS_USER}"
        fi
        if getent group "$JENKINS_GROUP" >/dev/null 2>&1; then
            run "remove group ${JENKINS_GROUP}" groupdel "$JENKINS_GROUP"
        else
            log "skip (absent): group ${JENKINS_GROUP}"
        fi
    else
        log "Step 4 of 4: Data preserved (no purge requested)"
        log "  kept: ${DATA_DIR}"
        log "  kept: the ${JENKINS_USER} user and group"
    fi

    log ""
    log "Verification:"
    if ! verify_native_uninstall || [ "$FAILURES" -gt 0 ]; then
        log "UNINSTALL INCOMPLETE: leftovers or failed steps listed above."
        exit 1
    fi
    log "  all REMOVE paths gone; preservation rules held"

    log ""
    log "Summary: Jenkins (form: native) is uninstalled."
    if [ "$PURGE" -eq 1 ]; then
        log "Data and the jenkins account were purged. Nothing remains."
    else
        log "Data preserved at ${DATA_DIR}; the jenkins account remains."
    fi
    log "Firewall rules were left as the installers left them. To close the ports:"
    log "  firewall-cmd --permanent --remove-port=${WEB_PORT}/tcp"
    log "  firewall-cmd --permanent --remove-port=${AGENT_PORT}/tcp (only if it was opened)"
    log "  firewall-cmd --reload"
    log "Redeploy with: $(redeploy_hint)"
}

#---------------------------------------------------------------------------
# uninstall (container)
#---------------------------------------------------------------------------
do_uninstall_container() {
    [ -d "$STACK_DIR" ] || { log "ERROR: container stack not found at ${STACK_DIR}"; exit 1; }
    if ! command -v docker >/dev/null 2>&1; then
        log "ERROR: docker is not installed; nothing to uninstall through compose"
        exit 1
    fi
    log "Uninstall plan: Jenkins (form: container, stack dir ${STACK_DIR})"
    log ""
    log "REMOVE:"
    log "  the jenkins container and the jenkins-net network (docker compose down)"
    log ""
    log "PRESERVED:"
    if [ "$PURGE" -eq 1 ]; then
        log "  (nothing: --purge removes the data volume too)"
        log ""
        log "PURGE (because --purge was given):"
        log "  the jenkins_home volume (every job, plugin, credential, and build record)"
    else
        log "  the jenkins_home volume (every job, plugin, credential, and build record)"
        log "  (Re-run with --purge to remove the volume too.)"
    fi
    log "  ${STACK_DIR} itself (your checkout of the stack files)"
    if [ "$DRY_RUN" -eq 1 ]; then
        log ""
        log "DRY-RUN: nothing was changed."
        return 0
    fi
    confirm_uninstall

    log ""
    log "Step 1 of 2: Bring the stack down"
    if [ "$PURGE" -eq 1 ]; then
        compose_run "docker compose down --volumes" down --volumes
    else
        compose_run "docker compose down" down
    fi

    log ""
    log "Step 2 of 2: Verification"
    local fail=0
    if compose_containers_exist; then
        log "  LEFTOVER: containers from this stack still exist"
        fail=1
    fi
    if container_present; then
        log "  LEFTOVER: the ${CONTAINER_NAME} container still exists"
        fail=1
    fi
    if [ "$PURGE" -eq 1 ]; then
        if volume_present; then
            log "  LEFTOVER: the jenkins_home volume still exists"
            fail=1
        fi
    else
        if volume_present; then
            log "  data volume preserved, as planned"
        else
            log "  note: no jenkins_home volume found (the stack may never have been started)"
        fi
    fi
    if [ "$fail" -ne 0 ] || [ "$FAILURES" -gt 0 ]; then
        log "UNINSTALL INCOMPLETE: leftovers or failed steps listed above."
        exit 1
    fi
    log "  stack is down; preservation rules held"
    log ""
    log "Summary: Jenkins (form: container) is uninstalled."
    log "Redeploy with: $(redeploy_hint)"
}

do_uninstall() {
    require_root
    setup_log
    if [ "$FORM" = "container" ]; then
        do_uninstall_container
    else
        do_uninstall_native
    fi
}

#---------------------------------------------------------------------------
# main
#---------------------------------------------------------------------------
main() {
    local verb=""
    # Global option first: --stack-dir may precede the verb.
    while [ $# -gt 0 ]; do
        case "$1" in
            --stack-dir)
                [ $# -ge 2 ] || die_usage "--stack-dir needs a path"
                STACK_DIR="$2"
                shift 2
                ;;
            --stack-dir=*)
                STACK_DIR="${1#--stack-dir=}"
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    verb="$1"
    shift
    local -a args=("$@")
    local i arg seen_sep=0
    for (( i=0; i<${#args[@]}; i++ )); do
        arg="${args[i]}"
        if [ "$seen_sep" -eq 1 ]; then
            INSTALLER_ARGS+=("$arg")
            continue
        fi
        case "$arg" in
            --form)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    die_usage "--form needs a value (native or container)"
                fi
                case "${args[i]}" in
                    native|container) FORM="${args[i]}" ;;
                    *) die_usage "unknown form '${args[i]}' (native or container)" ;;
                esac
                ;;
            --form=native|--form=container)
                FORM="${arg#--form=}"
                ;;
            --form=*)
                die_usage "unknown form '${arg#--form=}' (native or container)"
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --purge)
                PURGE=1
                ;;
            --stack-dir)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    die_usage "--stack-dir needs a path"
                fi
                STACK_DIR="${args[i]}"
                ;;
            --stack-dir=*)
                STACK_DIR="${arg#--stack-dir=}"
                ;;
            --)
                seen_sep=1
                ;;
            *)
                die_usage "unknown option: $arg"
                ;;
        esac
    done
    if [ "$PURGE" -eq 1 ] && [ "$verb" != "uninstall" ]; then
        die_usage "--purge is only valid with the uninstall verb"
    fi
    if [ "$verb" = "status" ] && { [ "$DRY_RUN" -eq 1 ] || [ "$PURGE" -eq 1 ]; }; then
        die_usage "status takes no --dry-run or --purge options"
    fi
    if [ "${#INSTALLER_ARGS[@]}" -gt 0 ] && { [ "$verb" != "install" ] || [ "$FORM" != "native" ]; }; then
        die_usage "installer options after -- are only valid for install --form native"
    fi
    case "$verb" in
        install)   do_install ;;
        up)        do_up ;;
        down)      do_down ;;
        restart)   do_restart ;;
        status)     do_status ;;
        uninstall) do_uninstall ;;
        -h|--help|help) usage ;;
        *) die_usage "unknown verb: $verb" ;;
    esac
}

main "$@"
