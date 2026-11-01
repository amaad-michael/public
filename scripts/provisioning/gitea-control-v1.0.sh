#!/usr/bin/env bash
#===============================================================================
# gitea-control-v1.0.sh - one controller for the whole Gitea lifecycle
#
# READ THIS BEFORE A REAL RUN
#   This script owns Gitea end to end, in the same shape as the neo1
#   observability control script: one entry point, symmetrical verbs,
#   and no verb reimplements what another repo script already does.
#
#   FORMS (pick with --form; default native)
#     native    scripts/provisioning/install-gitea.sh plus
#               post-setup-tighten-gitea.sh; Gitea runs as the systemd
#               unit gitea.service, binary at /usr/local/bin/gitea,
#               config at /etc/gitea, data at /var/lib/gitea, service
#               account git with home /home/git.
#     sd        The SD-endurance pair (install-gitea-sd.sh plus
#               post-setup-tighten-gitea-sd.sh). Same Gitea footprint,
#               plus the gitea-dump backup timer the SD tighten script
#               installs. The SD installer's HOST tuning (zram swap,
#               /etc/fstab edits, the journald drop-in) is host
#               configuration, not Gitea state: this controller never
#               touches it, on install or on uninstall.
#     container containers/gitea: a single hardened container
#               (gitea/gitea:1.26.4) wrapping docker compose in that
#               directory. Web on host port 3003, SSH on 2222, all
#               state in the named Docker volume gitea_data.
#
#   VERBS
#     install    Run the form's installer. Native forms run the sibling
#                installer script as-is. The container form checks for
#                the stack's .env first (secrets are yours to create;
#                see containers/gitea/README.md) and then brings the
#                stack up.
#     tighten    Run the form's post-setup lockdown. Native forms run
#                the sibling tighten script as-is, which needs the web
#                installer finished, a canary repo, and TEST_REPO set
#                (export TEST_REPO=<owner>/<repo>). The container form
#                carries its hardening in the compose file by design,
#                so its tighten is a verification pass plus the canary
#                steps from the stack README.
#     up         Native: systemctl start gitea. Container: compose up.
#     down       Native: systemctl stop gitea. Container: compose down
#                (the data volume is kept; down is not uninstall).
#     restart    Native: systemctl restart gitea. Container: restart.
#     status     Print the footprint and the service state. Exit 0
#                when the stack is fully installed, 1 when it is
#                missing or partial. Run state is reported as a field,
#                not folded into the exit code: this is a lifecycle
#                controller, and "installed but stopped" is a normal
#                state during a redeploy cycle.
#     uninstall  Remove the stack. Native: the unit file, /etc/gitea,
#                and the binary (plus the dump timer units on the SD
#                form). Container: compose down. Data is PRESERVED by
#                default (see below). Needs a typed confirmation.
#
#   DATA RULES (uninstall)
#     PRESERVED by default: /var/lib/gitea (every repository) and
#     /home/git plus the git account on native forms; the gitea_data
#     volume on the container form. .env and the stack files are
#     always preserved; they are your checkout and your secrets.
#     PURGE (--purge on uninstall) removes the preserved data too,
#     and on native forms deletes the git user and group. There is no
#     undo for a purge.
#
#   CONFIRMATION
#     uninstall asks you to type the word: gitea
#     A wrong or empty answer aborts with nothing changed.
#     --dry-run prints the full labeled plan and changes nothing,
#     and never asks for confirmation.
#
#   NOT COVERED, ON PURPOSE
#     The Ansible install playbook (ansible/playbooks/gitea/
#     install_gitea.yml) stays a parallel install path; this
#     controller does not wrap it. Firewall rules are untouched,
#     exactly as the installers leave them. Gitea upgrades are the
#     installers' job (re-running install is their upgrade path).
#
#   Exit codes: 0 = done or already in the requested state,
#   1 = a step or the closing verification failed, 2 = usage error.
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

FORM="native"
DRY_RUN=0
PURGE=0
STACK_DIR="${GITEA_STACK_DIR:-${REPO_ROOT}/containers/gitea}"

UNIT="gitea"
UNIT_FILE="/etc/systemd/system/gitea.service"
WANTS_LINK="/etc/systemd/system/multi-user.target.wants/gitea.service"
BINARY="/usr/local/bin/gitea"
CONFIG_DIR="/etc/gitea"
DATA_DIR="/var/lib/gitea"
GIT_HOME="/home/git"
GIT_USER="git"
DUMP_SERVICE_FILE="/etc/systemd/system/gitea-dump.service"
DUMP_TIMER_FILE="/etc/systemd/system/gitea-dump.timer"
DUMP_WANTS_LINK="/etc/systemd/system/timers.target.wants/gitea-dump.timer"

CONFIRM_TOKEN="gitea"

usage() {
    cat <<'EOF'
Usage:
  gitea-control-v1.0.sh install   [--form native|sd|container] [--dry-run]
  gitea-control-v1.0.sh tighten   [--form native|sd|container] [--dry-run]
  gitea-control-v1.0.sh up        [--form native|sd|container] [--dry-run]
  gitea-control-v1.0.sh down      [--form native|sd|container] [--dry-run]
  gitea-control-v1.0.sh restart   [--form native|sd|container] [--dry-run]
  gitea-control-v1.0.sh status    [--form native|sd|container]
  gitea-control-v1.0.sh uninstall [--form native|sd|container] [--dry-run] [--purge]
  gitea-control-v1.0.sh --stack-dir PATH   (container form stack location;
                                            may appear before the verb)

  TEST_REPO=<owner>/<repo> is required for native tighten (canary repo).
  GITEA_HOST, SSH_PORT, HTTP_PORT pass through to the tighten scripts.
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

# run: execute, or print under --dry-run. (Local IFS: the script's
# global IFS would join "$*" with newlines and mangle the printout.)
run() {
    local IFS=' '
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRY-RUN: %s\n' "$*"
    else
        "$@"
    fi
}

# run_soft: for systemctl calls that need a running systemd bus
# (disable --now, daemon-reload, stop on an offline system). Without a
# bus they legitimately fail after doing their offline half, or fail
# outright in a rescue shell or container. The file changes below are
# the substance; the closing verification pass is the gate.
SOFT_NOTES=0
run_soft() {
    local IFS=' '
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRY-RUN: %s\n' "$*"
        return 0
    fi
    if ! "$@"; then
        SOFT_NOTES=$((SOFT_NOTES + 1))
        echo "    note: '$1' step reported a failure (no running systemd bus is the usual cause); continuing, the verification pass at the end is the gate"
    fi
}

path_state() {
    # prints: present | absent
    if [ -e "$1" ] || [ -L "$1" ]; then
        echo "present"
    else
        echo "absent"
    fi
}

service_state() {
    local out
    out=$(systemctl is-active "$UNIT" 2>/dev/null || true)
    if [ -z "$out" ]; then
        echo "unknown (no systemd bus)"
    else
        echo "$out"
    fi
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

installer_for_form() {
    case "$FORM" in
        native) echo "${SCRIPT_DIR}/install-gitea.sh" ;;
        sd)     echo "${SCRIPT_DIR}/install-gitea-sd.sh" ;;
    esac
}

tighten_for_form() {
    case "$FORM" in
        native) echo "${SCRIPT_DIR}/post-setup-tighten-gitea.sh" ;;
        sd)     echo "${SCRIPT_DIR}/post-setup-tighten-gitea-sd.sh" ;;
    esac
}

redeploy_hint() {
    case "$FORM" in
        native)
            echo "scripts/provisioning/install-gitea.sh, finish the web installer, then: scripts/provisioning/gitea-control-v1.0.sh tighten --form native" ;;
        sd)
            echo "scripts/provisioning/install-gitea-sd.sh, finish the web installer, then: scripts/provisioning/gitea-control-v1.0.sh tighten --form sd" ;;
        container)
            echo "scripts/provisioning/gitea-control-v1.0.sh install --form container" ;;
    esac
}

#---------------------------------------------------------------------------
# install
#---------------------------------------------------------------------------
do_install() {
    require_root
    echo "Step 1 of 1: Install Gitea (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { echo "ERROR: container stack not found at ${STACK_DIR}" >&2; exit 1; }
        [ -f "${STACK_DIR}/docker-compose.yml" ] || { echo "ERROR: no docker-compose.yml in ${STACK_DIR}" >&2; exit 1; }
        if ! command -v docker >/dev/null 2>&1; then
            echo "ERROR: docker is not installed; the container form needs Docker with the compose plugin" >&2
            exit 1
        fi
        if [ ! -f "${STACK_DIR}/.env" ]; then
            cat <<EOF
ERROR: ${STACK_DIR}/.env does not exist yet, and creating it is an
operator step (it holds the stack secrets). Do this first:
  cp ${STACK_DIR}/gitea-env.example ${STACK_DIR}/.env
  generate GITEA_SECRET_KEY and GITEA_INTERNAL_TOKEN with the commands
  written in that file, set GITEA_DOMAIN and GITEA_ROOT_URL, then:
  chmod 600 ${STACK_DIR}/.env
Then re-run this install. Full walkthrough: containers/gitea/README.md
EOF
            exit 1
        fi
        echo "Bringing the stack up from ${STACK_DIR}:"
        ( cd "$STACK_DIR" && run docker compose up -d )
        echo ""
        echo "Next step (from containers/gitea/README.md): create the first admin:"
        echo "  docker compose exec gitea gitea admin user create --username michael --password '<generated-password>' --email '<your-email>' --admin"
        echo "Generate the password in Proton Pass (32 characters) and store it there."
        echo "Web UI: host port 3003. SSH: port 2222."
        return 0
    fi
    local installer
    installer=$(installer_for_form)
    [ -f "$installer" ] || { echo "ERROR: installer not found: ${installer}" >&2; exit 1; }
    if [ "$FORM" = "native" ] && [ "$DRY_RUN" -eq 0 ]; then
        # Advisory only: the SD installer auto-detects and gates its
        # flash measures itself; this just keeps an SD host from
        # quietly getting the standard app.ini seed.
        if findmnt -no SOURCE / 2>/dev/null | grep -q 'mmcblk'; then
            echo "NOTE: the root filesystem is on an SD/MMC device. Consider --form sd"
            echo "      (WAL journal mode, dump staging, flash endurance measures)."
        fi
    fi
    echo "Running the sibling installer (it is idempotent; re-running is its upgrade path):"
    run bash "$installer"
    echo ""
    echo "Next steps:"
    echo "  1. Complete the first-run web installer at http://<host>:3000"
    echo "  2. Create a canary repo and upload your SSH public key"
    echo "  3. export TEST_REPO=<owner>/<repo>"
    echo "  4. scripts/provisioning/gitea-control-v1.0.sh tighten --form ${FORM}"
}

#---------------------------------------------------------------------------
# tighten
#---------------------------------------------------------------------------
do_tighten() {
    require_root
    echo "Step 1 of 1: Tighten Gitea (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { echo "ERROR: container stack not found at ${STACK_DIR}" >&2; exit 1; }
        if ! command -v docker >/dev/null 2>&1; then
            echo "ERROR: docker is not installed" >&2
            exit 1
        fi
        echo "The container form carries its hardening in the compose file by"
        echo "design (cap_drop ALL, read-only root, no-new-privileges, resource"
        echo "limits, web installer locked in app.ini). Tighten here means:"
        echo "verify the stack is up, then run the README canary by hand."
        if [ "$DRY_RUN" -eq 1 ]; then
            ( cd "$STACK_DIR" && run docker compose ps )
            return 0
        fi
        if ( cd "$STACK_DIR" && docker compose ps --status running 2>/dev/null | grep -q gitea ); then
            echo "PASS: gitea container is running"
        else
            echo "FAIL: gitea container is not running; run install --form container first" >&2
            exit 1
        fi
        cat <<'EOF'
Canary (from containers/gitea/README.md):
  1. Create an empty repo in the UI and add your SSH key to your account.
  2. git clone ssh://git@<host>:2222/michael/<repo>.git
  3. Commit, push, and confirm the commit appears in the UI.
  4. Check http://<host>:3003/api/healthz answers.
EOF
        return 0
    fi
    local tighten
    tighten=$(tighten_for_form)
    [ -f "$tighten" ] || { echo "ERROR: tighten script not found: ${tighten}" >&2; exit 1; }
    if [ -z "${TEST_REPO:-}" ]; then
        cat <<'EOF'
ERROR: TEST_REPO is not set. The tighten scripts validate against a
canary repo and refuse to guess one. Set it first:
  export TEST_REPO=<owner>/<repo>
  export GITEA_HOST=127.0.0.1 (optional; SSH_PORT and HTTP_PORT too)
Then re-run this verb.
EOF
        exit 1
    fi
    echo "Running the sibling tighten script (idempotent; it tightens, canaries, and verifies):"
    run bash "$tighten"
}

#---------------------------------------------------------------------------
# up / down / restart
#---------------------------------------------------------------------------
compose_cmd() {
    # Runs a docker compose command inside the stack dir.
    ( cd "$STACK_DIR" && run docker compose "$@" )
}

do_up() {
    require_root
    echo "Step 1 of 1: Bring Gitea up (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { echo "ERROR: container stack not found at ${STACK_DIR}" >&2; exit 1; }
        compose_cmd up -d
        echo "Container stack up requested. Check with: gitea-control-v1.0.sh status --form container"
        return 0
    fi
    run_soft systemctl start "$UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "gitea service state: $(service_state)"
    fi
}

do_down() {
    require_root
    echo "Step 1 of 1: Bring Gitea down (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { echo "ERROR: container stack not found at ${STACK_DIR}" >&2; exit 1; }
        compose_cmd down
        echo "Container stack is down. The gitea_data volume is untouched;"
        echo "uninstall is the verb that talks about removing anything."
        return 0
    fi
    run_soft systemctl stop "$UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "gitea service state: $(service_state)"
    fi
}

do_restart() {
    require_root
    echo "Step 1 of 1: Restart Gitea (form: ${FORM})"
    if [ "$FORM" = "container" ]; then
        [ -d "$STACK_DIR" ] || { echo "ERROR: container stack not found at ${STACK_DIR}" >&2; exit 1; }
        compose_cmd restart
        return 0
    fi
    run_soft systemctl restart "$UNIT"
    if [ "$DRY_RUN" -eq 0 ]; then
        echo "gitea service state: $(service_state)"
    fi
}

#---------------------------------------------------------------------------
# status
#---------------------------------------------------------------------------
row() {
    printf '%-24s %s\n' "$1" "$2"
}

do_status_native() {
    local missing=0
    echo "Gitea status (form: ${FORM})"
    if [ -f "$UNIT_FILE" ]; then
        row "unit file" "$UNIT_FILE"
    else
        row "unit file" "ABSENT ($UNIT_FILE)"
        missing=1
    fi
    if [ -f "$BINARY" ]; then
        row "binary" "$BINARY"
    else
        row "binary" "ABSENT ($BINARY)"
        missing=1
    fi
    if [ -f "${CONFIG_DIR}/app.ini" ]; then
        local perms surface
        perms=$(stat -c '%a' "${CONFIG_DIR}/app.ini" 2>/dev/null || echo '?')
        if grep -q '^ReadWritePaths=/var/lib/gitea$' "$UNIT_FILE" 2>/dev/null; then
            surface="tightened"
        else
            surface="open (pre-tighten)"
        fi
        row "config" "${CONFIG_DIR}/app.ini (mode ${perms}, unit surface: ${surface})"
    else
        row "config" "ABSENT (${CONFIG_DIR}/app.ini)"
        missing=1
    fi
    if [ -d "$DATA_DIR" ]; then
        row "data" "$DATA_DIR"
    else
        row "data" "ABSENT ($DATA_DIR)"
        missing=1
    fi
    if id "$GIT_USER" >/dev/null 2>&1; then
        row "service account" "${GIT_USER} (home ${GIT_HOME})"
    else
        row "service account" "ABSENT (${GIT_USER})"
        missing=1
    fi
    row "service state" "$(service_state)"
    if [ "$FORM" = "sd" ]; then
        if [ -f "$DUMP_TIMER_FILE" ]; then
            row "dump timer" "installed (gitea-dump.timer)"
        else
            row "dump timer" "not installed (SD tighten installs it)"
        fi
        if [ -f /etc/systemd/system/zram-swap.service ]; then
            row "SD host tuning" "present (host configuration, left in place by design)"
        fi
    fi
    if [ "$missing" -eq 1 ]; then
        echo "Verdict: not fully installed (see ABSENT lines above)."
        return 1
    fi
    echo "Verdict: installed. Service state is the field above."
    return 0
}

do_status_container() {
    echo "Gitea status (form: container)"
    local missing=0
    if [ -d "$STACK_DIR" ]; then
        row "stack dir" "$STACK_DIR"
    else
        row "stack dir" "ABSENT ($STACK_DIR)"
        missing=1
    fi
    if [ -f "${STACK_DIR}/.env" ]; then
        row "secrets file" ".env present"
    else
        row "secrets file" ".env ABSENT (install cannot run without it)"
    fi
    if ! command -v docker >/dev/null 2>&1; then
        row "docker" "not installed"
        echo "Verdict: cannot inspect containers without docker."
        return 1
    fi
    row "docker" "available"
    if [ "$missing" -eq 0 ]; then
        echo ""
        ( cd "$STACK_DIR" && docker compose ps ) || true
        echo ""
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'gitea_data$'; then
            row "data volume" "present (name ends in gitea_data)"
        else
            row "data volume" "not created yet"
        fi
    fi
    if [ "$missing" -eq 1 ]; then
        echo "Verdict: not fully installed (see ABSENT lines above)."
        return 1
    fi
    echo "Verdict: installed. Container state is the table above."
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
# uninstall
#---------------------------------------------------------------------------
print_native_uninstall_plan() {
    echo "Uninstall plan: Gitea (form: ${FORM})"
    echo ""
    echo "REMOVE:"
    echo "  ${UNIT_FILE} (systemd unit)"
    echo "  ${WANTS_LINK} (enable symlink, if present)"
    echo "  ${CONFIG_DIR} (seeded config, including app.ini)"
    echo "  ${BINARY} (Gitea binary)"
    if [ "$FORM" = "sd" ]; then
        echo "  ${DUMP_SERVICE_FILE} (backup cycle installed by the SD tighten script)"
        echo "  ${DUMP_TIMER_FILE} (backup timer)"
        echo "  ${DUMP_WANTS_LINK} (timer enable symlink, if present)"
    fi
    echo ""
    echo "PRESERVED:"
    echo "  ${DATA_DIR} (every repository and Gitea's data)"
    if [ "$PURGE" -eq 1 ]; then
        echo ""
        echo "PURGE (because --purge was given):"
        echo "  ${DATA_DIR} (the preserved data above is removed after all)"
        echo "  ${GIT_HOME} (service account home)"
        echo "  user ${GIT_USER} and group ${GIT_USER}"
    else
        echo "  ${GIT_HOME} and the ${GIT_USER} user and group"
        echo "  (Re-run with --purge to remove the data and the account too.)"
    fi
    if [ "$FORM" = "sd" ]; then
        echo ""
        echo "LEFT IN PLACE ON PURPOSE (host configuration, not Gitea state):"
        echo "  zram swap unit and helpers, /etc/fstab edits, journald drop-in"
    fi
    echo ""
    echo "The service is stopped and disabled first. Package-installed"
    echo "dependencies (git, sqlite, wget) are shared tools and stay."
}

verify_native_uninstall() {
    local fail=0 p
    for p in "$UNIT_FILE" "$WANTS_LINK" "$CONFIG_DIR" "$BINARY"; do
        if [ "$(path_state "$p")" = "present" ]; then
            echo "  LEFTOVER: $p is still present"
            fail=1
        fi
    done
    if [ "$FORM" = "sd" ]; then
        for p in "$DUMP_SERVICE_FILE" "$DUMP_TIMER_FILE" "$DUMP_WANTS_LINK"; do
            if [ "$(path_state "$p")" = "present" ]; then
                echo "  LEFTOVER: $p is still present"
                fail=1
            fi
        done
    fi
    if [ "$PURGE" -eq 1 ]; then
        for p in "$DATA_DIR" "$GIT_HOME"; do
            if [ "$(path_state "$p")" = "present" ]; then
                echo "  LEFTOVER: $p is still present"
                fail=1
            fi
        done
        if id "$GIT_USER" >/dev/null 2>&1; then
            echo "  LEFTOVER: user ${GIT_USER} still exists"
            fail=1
        fi
        if getent group "$GIT_USER" >/dev/null 2>&1; then
            echo "  LEFTOVER: group ${GIT_USER} still exists"
            fail=1
        fi
    else
        if [ "$(path_state "$DATA_DIR")" != "present" ]; then
            echo "  PROBLEM: ${DATA_DIR} should have been preserved but is gone"
            fail=1
        fi
    fi
    return $fail
}

do_uninstall_native() {
    # "Installed" for uninstall purposes means a REMOVE-set path is
    # still on disk. Preserved data alone does not re-arm the verb:
    # after a default uninstall, re-running reports the preserved data
    # and exits 0 without asking for confirmation again. A --purge run
    # is armed by the data or the account still existing.
    local present=0 p
    for p in "$UNIT_FILE" "$WANTS_LINK" "$BINARY" "$CONFIG_DIR"; do
        if [ "$(path_state "$p")" = "present" ]; then
            present=1
        fi
    done
    if [ "$FORM" = "sd" ]; then
        for p in "$DUMP_SERVICE_FILE" "$DUMP_TIMER_FILE"; do
            if [ "$(path_state "$p")" = "present" ]; then
                present=1
            fi
        done
    fi
    if [ "$present" -eq 0 ]; then
        if [ "$PURGE" -eq 1 ] && { [ "$(path_state "$DATA_DIR")" = "present" ] || id "$GIT_USER" >/dev/null 2>&1; }; then
            present=1
        elif [ "$(path_state "$DATA_DIR")" = "present" ]; then
            echo "Gitea (form: ${FORM}) is already uninstalled."
            echo "Preserved data remains at ${DATA_DIR}; the ${GIT_USER} account remains too."
            echo "Re-run with --purge to remove both."
            return 0
        else
            echo "Gitea (form: ${FORM}) is not installed on this host. Nothing to do."
            return 0
        fi
    fi

    print_native_uninstall_plan
    if [ "$DRY_RUN" -eq 1 ]; then
        echo ""
        echo "DRY-RUN: nothing was changed."
        return 0
    fi
    confirm_uninstall

    echo ""
    echo "Step 1 of 3: Stop and disable the service"
    run_soft systemctl disable --now "$UNIT"
    if [ "$FORM" = "sd" ]; then
        run_soft systemctl disable --now gitea-dump.timer
    fi
    run_soft systemctl daemon-reload

    echo ""
    echo "Step 2 of 3: Remove units, config, and binary"
    run rm -f "$WANTS_LINK"
    if [ "$FORM" = "sd" ]; then
        run rm -f "$DUMP_WANTS_LINK"
        run rm -f "$DUMP_SERVICE_FILE" "$DUMP_TIMER_FILE"
    fi
    run rm -f "$UNIT_FILE"
    run rm -rf "$CONFIG_DIR"
    run rm -f "$BINARY"

    echo ""
    if [ "$PURGE" -eq 1 ]; then
        echo "Step 3 of 3: Purge data and the service account"
        run rm -rf "$DATA_DIR"
        if id "$GIT_USER" >/dev/null 2>&1; then
            run userdel "$GIT_USER" || true
        fi
        if getent group "$GIT_USER" >/dev/null 2>&1; then
            run groupdel "$GIT_USER" || true
        fi
        run rm -rf "$GIT_HOME"
    else
        echo "Step 3 of 3: Data preserved (no purge requested)"
        echo "  kept: ${DATA_DIR}"
        echo "  kept: ${GIT_HOME} and the ${GIT_USER} user and group"
    fi

    echo ""
    echo "Verification:"
    if ! verify_native_uninstall; then
        echo "UNINSTALL INCOMPLETE: leftovers listed above." >&2
        exit 1
    fi
    echo "  all REMOVE paths gone; preservation rules held"
    if [ "$SOFT_NOTES" -gt 0 ]; then
        echo "  (${SOFT_NOTES} systemctl step(s) noted a bus-less failure along the way; the file state above is verified.)"
    fi

    echo ""
    echo "Summary: Gitea (form: ${FORM}) is uninstalled."
    if [ "$PURGE" -eq 1 ]; then
        echo "Data and the git account were purged. Nothing remains."
    else
        echo "Data preserved at ${DATA_DIR}; the git account remains."
    fi
    echo "Redeploy with: $(redeploy_hint)"
}

do_uninstall_container() {
    [ -d "$STACK_DIR" ] || { echo "ERROR: container stack not found at ${STACK_DIR}" >&2; exit 1; }
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker is not installed; nothing to uninstall through compose" >&2
        exit 1
    fi
    echo "Uninstall plan: Gitea (form: container, stack dir ${STACK_DIR})"
    echo ""
    echo "REMOVE:"
    echo "  the gitea container and the gitea-net network (docker compose down)"
    echo ""
    echo "PRESERVED:"
    if [ "$PURGE" -eq 1 ]; then
        echo "  (nothing: --purge removes the data volume too)"
        echo ""
        echo "PURGE (because --purge was given):"
        echo "  the gitea_data volume (every repository and the database)"
    else
        echo "  the gitea_data volume (every repository and the database)"
        echo "  (Re-run with --purge to remove the volume too.)"
    fi
    echo "  ${STACK_DIR} itself, including .env (your checkout and secrets)"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo ""
        echo "DRY-RUN: nothing was changed."
        return 0
    fi
    confirm_uninstall

    echo ""
    echo "Step 1 of 2: Bring the stack down"
    if [ "$PURGE" -eq 1 ]; then
        ( cd "$STACK_DIR" && run docker compose down --volumes )
    else
        ( cd "$STACK_DIR" && run docker compose down )
    fi

    echo ""
    echo "Step 2 of 2: Verification"
    local fail=0
    if ( cd "$STACK_DIR" && docker compose ps -a --format '{{.Name}}' 2>/dev/null | grep -q . ); then
        echo "  LEFTOVER: containers from this stack still exist"
        fail=1
    fi
    if [ "$PURGE" -eq 1 ]; then
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'gitea_data$'; then
            echo "  LEFTOVER: the gitea_data volume still exists"
            fail=1
        fi
    else
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q 'gitea_data$'; then
            echo "  data volume preserved, as planned"
        else
            echo "  note: no gitea_data volume found (the stack may never have been started)"
        fi
    fi
    if [ "$fail" -ne 0 ]; then
        echo "UNINSTALL INCOMPLETE: leftovers listed above." >&2
        exit 1
    fi
    echo "  stack is down; preservation rules held"
    echo ""
    echo "Summary: Gitea (form: container) is uninstalled."
    echo "Redeploy with: $(redeploy_hint)"
}

do_uninstall() {
    require_root
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
    local i arg
    for (( i=0; i<${#args[@]}; i++ )); do
        arg="${args[i]}"
        case "$arg" in
            --form)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    die_usage "--form needs a value (native, sd, or container)"
                fi
                case "${args[i]}" in
                    native|sd|container) FORM="${args[i]}" ;;
                    *) die_usage "unknown form '${args[i]}' (native, sd, or container)" ;;
                esac
                ;;
            --form=native|--form=sd|--form=container)
                FORM="${arg#--form=}"
                ;;
            --form=*)
                die_usage "unknown form '${arg#--form=}' (native, sd, or container)"
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
            *)
                die_usage "unknown option: $arg"
                ;;
        esac
    done
    if [ "$PURGE" -eq 1 ] && [ "$verb" != "uninstall" ]; then
        die_usage "--purge is only valid with the uninstall verb"
    fi
    case "$verb" in
        install)   do_install ;;
        tighten)   do_tighten ;;
        up)        do_up ;;
        down)      do_down ;;
        restart)   do_restart ;;
        status)    do_status ;;
        uninstall) do_uninstall ;;
        -h|--help|help) usage ;;
        *) die_usage "unknown verb: $verb" ;;
    esac
}

main "$@"
