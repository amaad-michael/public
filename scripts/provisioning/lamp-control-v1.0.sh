#!/usr/bin/env bash
# lamp-control-v1.0.sh - one controller for the whole LAMP stack lifecycle
#
# ═══════════════════════════════════════════════════════════════════════
# READ THIS BEFORE A REAL RUN
#
# This script owns the LAMP stack (Apache, PHP-FPM, MariaDB) end to end:
# install, up, down, restart, status, and uninstall, in the pattern of
# the neo1 observability control script. It covers the stack's forms:
#
#   native     The bare-metal install on a Debian-family or RHEL-family
#              host. The family is detected from /etc/os-release (or set
#              with LAMP_FAMILY=debian|rocky) and everything family
#              specific follows the two repo installers exactly:
#                debian: lamp-install-debian13.sh (pi2's rebuild path)
#                        apache2, php<version>-fpm, mariadb
#                rocky:  lamp-install-rocky10.sh
#                        httpd, php-fpm, mariadb
#   container  The Docker form in containers/lamp (web, php, db on
#              lamp-net, host port 8083, data on the lamp_db volume).
#              Selected with --form container. Deploy and runtime go
#              through docker compose in that directory.
#
# The Ansible form (ansible/playbooks/lamp/lamp.yml) is a parallel
# install path and stays one: this controller notes it but does not
# wrap it. Installing through Ansible and later running this
# controller's native verbs against the result is fine, because both
# produce the same footprint.
#
# What uninstall does, in plain language: it stops and disables the
# three services, removes their unit files, removes the stack's
# packages, and removes the stack's config directories. It PRESERVES
# the two places your own state lives:
#   /var/www/html   the web root (your site files)
#   /var/lib/mysql  the MariaDB data (your databases)
# --purge removes those two as well, and only then. Packages are
# REMOVED, never purged: the controller deletes the config directories
# itself, because a Debian package purge of mariadb-server can delete
# /var/lib/mysql from its maintainer scripts, which would break the
# preserve promise above. The distro service accounts (www-data or
# apache, and mysql) are never removed; other software on the box may
# use them. Firewall openings the installers added (UFW 80/443 on
# Debian, firewalld http/https on Rocky) are removed when present.
#
# Destructive verbs (uninstall) print the full labeled plan first and
# require you to type the confirmation word: lamp
# Every verb accepts --dry-run, which prints the plan and every
# command without changing anything. Running any verb against a host
# where the stack is absent is safe: absent pieces are skipped and
# reported, and a clean host exits 0.
#
# There is deliberately no interactive panel. The neo1 panel serves
# daily runtime operations; this controller's verbs are install-day
# and teardown-day actions, where the labeled plan is the interface.
# ═══════════════════════════════════════════════════════════════════════
#
# Usage:
#   lamp-control-v1.0.sh install [--dry-run]
#   lamp-control-v1.0.sh up|down|restart [--dry-run]
#   lamp-control-v1.0.sh status
#   lamp-control-v1.0.sh uninstall [--purge] [--dry-run]
#   lamp-control-v1.0.sh [--form container] <verb> [options]
#
# Exit codes: 0 = the stack is in the requested end state (or status
# found a complete footprint), 1 = a step failed, a leftover survived
# uninstall's verification pass, or status found a partial footprint,
# 2 = usage error.
#
# Status exit contract (a deliberate, documented difference from the
# neo1 runtime script): status reports the footprint and each unit's
# run state as fields. Exit 0 means the footprint is complete or the
# stack is not installed at all; exit 1 means a PARTIAL footprint,
# which is the state that needs a human. A stopped unit is a normal
# mid-cycle state for a lifecycle controller, not a failure.
#
# Environment knobs (defaults are the repo layout; the knobs exist
# for relocated kits and for testing):
#   LAMP_FAMILY=auto|debian|rocky   native family selection
#   LAMP_INSTALLER=/path/to.sh      installer the install verb runs
#   LAMP_STACK_DIR=/path            containers/lamp directory

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORM="native"
DRY_RUN="no"
PURGE="no"
TOKEN="lamp"

# ─────────────────────────────────────────────────────────────────────
# Small helpers (the teardown engines' idioms)
# ─────────────────────────────────────────────────────────────────────

log() { printf '%s\n' "$*"; }

die_usage() {
    log "ERROR: $*" >&2
    usage >&2
    exit 2
}

# act: a step the run depends on; failure aborts the run.
act() {
    local desc="$1"; shift
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "  DRY-RUN: $*"
        return 0
    fi
    log "  run: $desc"
    if ! "$@"; then
        log "FAILED: $desc (command: $*)" >&2
        exit 1
    fi
}

# act_soft: bus-dependent systemctl work. Without a running systemd
# (containers, rescue shells) these calls exit 1 even when their
# offline half (enable/disable symlinks) succeeded. They never abort
# the run; the verification pass is the gate.
act_soft() {
    local desc="$1"; shift
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "  DRY-RUN: $*"
        return 0
    fi
    log "  run (soft): $desc"
    if ! "$@"; then
        log "  note: '$desc' reported failure; continuing (no systemd bus, or already in the target state). The verification pass decides."
    fi
}

rm_labeled() {
    local p="$1"
    if [[ -e "$p" || -L "$p" ]]; then
        act "remove $p" rm -rf -- "$p"
    else
        log "  skip: $p (already absent)"
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
    [[ -e "/etc/systemd/system/$f" || -L "/etc/systemd/system/$f" \
       || -e "/lib/systemd/system/$f" || -e "/usr/lib/systemd/system/$f" ]]
}

unit_active() {
    systemctl is-active --quiet "$(unit_file "$1")" 2>/dev/null
}

# Presence guards over docker listings DRAIN the listing (grep -x
# without -q). Under pipefail, grep -q exiting on the first match
# SIGPIPEs the docker CLI and the pipeline reports a present object
# as absent. Never reintroduce grep -q here.
docker_container_present() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "$1" >/dev/null
}
docker_volume_present() {
    docker volume ls --format '{{.Name}}' 2>/dev/null | grep -x "$1" >/dev/null
}

# ─────────────────────────────────────────────────────────────────────
# Family model (native form), from the two repo installers
# ─────────────────────────────────────────────────────────────────────

FAMILY="${LAMP_FAMILY:-auto}"
PHPV=""
WEB_UNIT="" FPM_UNIT="" DB_UNIT=""
INSTALLER_NAME=""
declare -a PKGS=() CONFIG_PATHS=()
DATA_PATHS=(/var/www/html /var/lib/mysql)
UP_ORDER=()
DOWN_ORDER=()

detect_family() {
    if [[ "$FAMILY" != "auto" ]]; then
        return 0
    fi
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        id="$(grep -E '^ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')"
        like="$(grep -E '^ID_LIKE=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')"
    fi
    case " $id $like " in
        *" debian "*|*" ubuntu "*) FAMILY="debian" ;;
        *" rocky "*|*" rhel "*|*" fedora "*|*" centos "*) FAMILY="rocky" ;;
        *) FAMILY="" ;;
    esac
}

detect_phpv() {
    # Debian only: the FPM unit and package carry the PHP version
    # (php8.4-fpm on trixie). Ask PHP itself first, then the config
    # tree the installer leaves, then installed unit files.
    if command -v php >/dev/null 2>&1; then
        PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
        [[ -n "$PHPV" ]] && return 0
    fi
    local d f
    for d in /etc/php/*/; do
        if [[ -d "${d}fpm" ]]; then
            PHPV="$(basename "$d")"
            return 0
        fi
    done
    for f in /etc/systemd/system/php*-fpm.service /lib/systemd/system/php*-fpm.service /usr/lib/systemd/system/php*-fpm.service; do
        if [[ -e "$f" ]]; then
            PHPV="$(basename "$f" .service | sed 's/^php//; s/-fpm$//')"
            return 0
        fi
    done
    PHPV=""
}

load_family() {
    detect_family
    case "$FAMILY" in
        debian)
            detect_phpv
            WEB_UNIT="apache2"
            DB_UNIT="mariadb"
            if [[ -n "$PHPV" ]]; then
                FPM_UNIT="php${PHPV}-fpm"
                PKGS=(apache2 mariadb-server php-fpm "php${PHPV}-fpm" php-mysql)
                CONFIG_PATHS=(/etc/apache2 "/etc/php/${PHPV}" /etc/mysql)
            else
                FPM_UNIT=""
                PKGS=(apache2 mariadb-server php-fpm php-mysql)
                CONFIG_PATHS=(/etc/apache2 /etc/php /etc/mysql)
            fi
            INSTALLER_NAME="lamp-install-debian13.sh"
            ;;
        rocky)
            WEB_UNIT="httpd"
            FPM_UNIT="php-fpm"
            DB_UNIT="mariadb"
            PKGS=(httpd mariadb-server php php-fpm php-mysqlnd)
            CONFIG_PATHS=(/etc/httpd /etc/php-fpm.d /etc/php.ini /etc/my.cnf.d /etc/my.cnf)
            INSTALLER_NAME="lamp-install-rocky10.sh"
            ;;
        *)
            log "ERROR: could not detect the OS family from /etc/os-release." >&2
            log "This controller covers the Debian family (lamp-install-debian13.sh) and the RHEL family (lamp-install-rocky10.sh)." >&2
            log "Set LAMP_FAMILY=debian or LAMP_FAMILY=rocky to choose explicitly." >&2
            exit 2
            ;;
    esac
    UP_ORDER=("$DB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$WEB_UNIT")
    DOWN_ORDER=("$WEB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$DB_UNIT")
}

stack_dir() {
    printf '%s' "${LAMP_STACK_DIR:-$SCRIPT_DIR/../../containers/lamp}"
}

compose() {
    (cd "$(stack_dir)" && docker compose "$@")
}

# ─────────────────────────────────────────────────────────────────────
# Confirmation
# ─────────────────────────────────────────────────────────────────────

confirm_or_abort() {
    local reply=""
    log "Type \"$TOKEN\" to proceed, anything else to abort:"
    if [[ -r /dev/tty ]]; then
        read -r reply < /dev/tty || reply=""
    else
        read -r reply || reply=""
    fi
    if [[ "$reply" != "$TOKEN" ]]; then
        log "Aborted: confirmation not given. Nothing was changed."
        exit 1
    fi
}

usage() {
    cat <<'EOF'
Usage:
  lamp-control-v1.0.sh [--form native|container] <verb> [options]

Verbs:
  install     Run the stack's installer (native: the family installer
              beside this script; container: check .env, then compose
              up --build)
  up          Start the three services (container: compose up -d)
  down        Stop the three services (container: compose down,
              volumes kept)
  restart     down, then up
  status      Read-only report: footprint and run state
  uninstall   Remove the stack; data preserved unless --purge

Options:
  --purge     With uninstall: also remove preserved data
              (native: /var/www/html and /var/lib/mysql;
              container: the lamp_db volume)
  --dry-run   Print the plan and commands; change nothing
EOF
}

# ─────────────────────────────────────────────────────────────────────
# Native form
# ─────────────────────────────────────────────────────────────────────

native_installer_path() {
    printf '%s' "${LAMP_INSTALLER:-$SCRIPT_DIR/$INSTALLER_NAME}"
}

do_install_native() {
    local installer; installer="$(native_installer_path)"
    log "Step 1 of 1: running the $FAMILY installer"
    if [[ ! -f "$installer" ]]; then
        log "ERROR: installer not found: $installer" >&2
        log "The install verb delegates to the family installer that ships beside this controller in scripts/provisioning." >&2
        exit 1
    fi
    act "run installer $installer" bash "$installer"
    log ""
    log "Install finished. The installer ended with its own verification"
    log "pass (versions, service states, PHP probe, MariaDB socket auth)."
    log "Next: lamp-control-v1.0.sh status"
}

native_any_installed() {
    local u p
    for u in "$WEB_UNIT" "$DB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"}; do
        unit_present "$u" && return 0
    done
    for p in "${CONFIG_PATHS[@]}"; do
        [[ -e "$p" ]] && return 0
    done
    return 1
}

do_up_native() {
    if ! native_any_installed; then
        log "The LAMP stack is not installed on this host (no unit files or config found)."
        log "Run: lamp-control-v1.0.sh install"
        exit 1
    fi
    log "Step 1 of 1: starting services (database, PHP-FPM, web)"
    local u failures=0
    for u in "${UP_ORDER[@]}"; do
        if ! unit_present "$u"; then
            log "  skip: $u (unit file absent)"
            continue
        fi
        if unit_active "$u"; then
            log "  $u: already active"
        else
            act_soft "start $u" systemctl start "$(unit_file "$u")"
        fi
    done
    if [[ "$DRY_RUN" == "yes" ]]; then
        return 0
    fi
    for u in "${UP_ORDER[@]}"; do
        if unit_present "$u" && ! unit_active "$u"; then
            log "FAILED: $u did not become active" >&2
            failures=1
        fi
    done
    [[ "$failures" -eq 0 ]] || exit 1
    log "LAMP stack is up."
}

do_down_native() {
    log "Step 1 of 1: stopping services (web, PHP-FPM, database)"
    local u
    for u in "${DOWN_ORDER[@]}"; do
        if ! unit_present "$u"; then
            log "  skip: $u (unit file absent)"
            continue
        fi
        if unit_active "$u"; then
            act_soft "stop $u" systemctl stop "$(unit_file "$u")"
        else
            log "  $u: already stopped"
        fi
    done
    if [[ "$DRY_RUN" == "yes" ]]; then
        return 0
    fi
    local failures=0
    for u in "${DOWN_ORDER[@]}"; do
        if unit_present "$u" && unit_active "$u"; then
            log "FAILED: $u is still active" >&2
            failures=1
        fi
    done
    [[ "$failures" -eq 0 ]] || exit 1
    log "LAMP stack is down."
}

do_status_native() {
    log "Form: native   Family: $FAMILY"
    local complete=1 any=0 u state f
    printf '%-16s %-12s %s\n' "UNIT" "FILE" "STATE"
    for u in "$WEB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$DB_UNIT"; do
        if unit_present "$u"; then
            f="present"; any=1
            if unit_active "$u"; then state="active"; else state="inactive"; fi
        else
            f="absent"; state="-"; complete=0
        fi
        printf '%-16s %-12s %s\n' "$(unit_file "$u")" "$f" "$state"
    done
    if [[ -z "$FPM_UNIT" ]]; then
        log "NOTE: PHP version could not be detected, so the PHP-FPM unit cannot be named."
        complete=0
    fi
    local p
    for p in "${CONFIG_PATHS[@]}"; do
        if [[ -e "$p" ]]; then any=1; else complete=0; fi
    done
    log ""
    log "Data (preserved by a default uninstall):"
    for p in "${DATA_PATHS[@]}"; do
        if [[ -e "$p" ]]; then
            log "  $p: present"
        else
            log "  $p: absent"
        fi
    done
    if [[ "$any" -eq 0 ]]; then
        log ""
        log "The LAMP stack is not installed on this host."
        return 0
    fi
    if [[ "$complete" -eq 0 ]]; then
        log ""
        log "PARTIAL footprint: some stack pieces are missing (see above)."
        return 1
    fi
    log ""
    log "Footprint complete. Run state is reported per unit above."
    return 0
}

print_plan_native_uninstall() {
    log "════════════════════════════════════════════════════════════"
    log "UNINSTALL PLAN: LAMP stack, native form, $FAMILY family"
    log "════════════════════════════════════════════════════════════"
    log "REMOVE (services and enablement):"
    local u
    for u in "$WEB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$DB_UNIT"; do
        log "  $(unit_file "$u") (stop, disable, unit file and enable links)"
    done
    log "REMOVE (packages, removed not purged):"
    local pkg
    for pkg in "${PKGS[@]}"; do
        log "  $pkg"
    done
    log "REMOVE (configuration):"
    local p
    for p in "${CONFIG_PATHS[@]}"; do
        log "  $p"
    done
    if [[ "$FAMILY" == "debian" ]]; then
        log "REMOVE (firewall, only if present): UFW rules 80/tcp and 443/tcp"
    else
        log "REMOVE (firewall, only if present): firewalld services http and https"
    fi
    log "PRESERVED (your state; kept by a default uninstall):"
    for p in "${DATA_PATHS[@]}"; do
        log "  $p"
    done
    log "  distro service accounts (never removed by this controller)"
    if [[ "$PURGE" == "yes" ]]; then
        log "PURGE (because --purge was given):"
        for p in "${DATA_PATHS[@]}"; do
            log "  $p"
        done
    fi
    log "════════════════════════════════════════════════════════════"
}

do_uninstall_native() {
    print_plan_native_uninstall
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "Dry run: nothing was changed."
        return 0
    fi
    confirm_or_abort

    log ""
    log "Step 1 of 5: stopping and disabling units"
    local u pkg p
    for u in "$WEB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$DB_UNIT"; do
        if unit_present "$u"; then
            act_soft "disable and stop $u" systemctl disable --now "$(unit_file "$u")"
        else
            log "  skip: $u (unit file absent)"
        fi
    done

    log "Step 2 of 5: removing unit files and enable links"
    local wants
    for u in "$WEB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$DB_UNIT"; do
        rm_labeled "/etc/systemd/system/$(unit_file "$u")"
        for wants in /etc/systemd/system/*.wants; do
            [[ -d "$wants" ]] || continue
            rm_labeled "$wants/$(unit_file "$u")"
        done
    done
    act_soft "reload systemd manager configuration" systemctl daemon-reload

    log "Step 3 of 5: removing packages (remove, not purge; data stays)"
    if [[ "$FAMILY" == "debian" ]]; then
        act "apt-get remove the stack packages" apt-get remove -y "${PKGS[@]}"
    else
        act "dnf remove the stack packages" dnf remove -y "${PKGS[@]}"
    fi

    log "Step 4 of 5: removing configuration and firewall openings"
    for p in "${CONFIG_PATHS[@]}"; do
        rm_labeled "$p"
    done
    if [[ "$FAMILY" == "debian" && -d /etc/php ]]; then
        # The versioned subtree is the config path; drop the parent
        # too when nothing else uses it, so no empty husk remains.
        act_soft "remove /etc/php parent if now empty" rmdir --ignore-fail-on-non-empty /etc/php
    fi
    if [[ "$FAMILY" == "debian" ]]; then
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -x "Status: active" >/dev/null; then
            act_soft "remove UFW rule 80/tcp" ufw --force delete allow 80/tcp
            act_soft "remove UFW rule 443/tcp" ufw --force delete allow 443/tcp
        else
            log "  skip: UFW not active (the installer only adds rules when it is)"
        fi
    else
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            act_soft "remove firewalld service http" firewall-cmd --permanent --remove-service=http
            act_soft "remove firewalld service https" firewall-cmd --permanent --remove-service=https
            act_soft "reload firewalld" firewall-cmd --reload
        else
            log "  skip: firewalld not active (the installer only adds services when it is)"
        fi
    fi

    if [[ "$PURGE" == "yes" ]]; then
        log "Step 5 of 5: purging preserved data (--purge was given)"
        for p in "${DATA_PATHS[@]}"; do
            rm_labeled "$p"
        done
    else
        log "Step 5 of 5: data preservation check"
        for p in "${DATA_PATHS[@]}"; do
            if [[ -e "$p" ]]; then
                log "  preserved: $p"
            else
                log "  absent: $p (nothing to preserve)"
            fi
        done
    fi

    log ""
    log "Verification pass:"
    local leftover=0
    for u in "$WEB_UNIT" ${FPM_UNIT:+"$FPM_UNIT"} "$DB_UNIT"; do
        if unit_present "$u"; then
            log "  LEFTOVER: unit $(unit_file "$u") still present" >&2
            leftover=1
        fi
        for wants in /etc/systemd/system/*.wants; do
            [[ -d "$wants" ]] || continue
            if [[ -e "$wants/$(unit_file "$u")" || -L "$wants/$(unit_file "$u")" ]]; then
                log "  LEFTOVER: enable link $wants/$(unit_file "$u")" >&2
                leftover=1
            fi
        done
    done
    for p in "${CONFIG_PATHS[@]}"; do
        if [[ -e "$p" ]]; then
            log "  LEFTOVER: config path $p still present" >&2
            leftover=1
        fi
    done
    if [[ "$PURGE" == "yes" ]]; then
        for p in "${DATA_PATHS[@]}"; do
            if [[ -e "$p" ]]; then
                log "  LEFTOVER: data path $p still present after --purge" >&2
                leftover=1
            fi
        done
    fi
    if [[ "$leftover" -ne 0 ]]; then
        log "Verification FAILED: leftovers above. The stack is not fully removed." >&2
        exit 1
    fi
    log "  clean: no unit files, enable links, or config paths remain."
    log ""
    log "════════════════════════════════════════════════════════════"
    log "LAMP stack uninstalled (native, $FAMILY)."
    if [[ "$PURGE" == "yes" ]]; then
        log "Data was purged: /var/www/html and /var/lib/mysql are gone."
    else
        log "Preserved: /var/www/html (site files) and /var/lib/mysql (databases)."
        log "To remove them too, re-run with --purge."
    fi
    log "Redeploy with: lamp-control-v1.0.sh install"
    log "════════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────
# Container form (containers/lamp)
# ─────────────────────────────────────────────────────────────────────

CONTAINERS=(lamp-web lamp-php lamp-db)
DB_VOLUME_SUFFIX="lamp_db"

print_plan_container_uninstall() {
    log "════════════════════════════════════════════════════════════"
    log "UNINSTALL PLAN: LAMP stack, container form"
    log "Stack directory: $(stack_dir)"
    log "════════════════════════════════════════════════════════════"
    log "REMOVE (containers and the lamp-net network, via compose down):"
    local c
    for c in "${CONTAINERS[@]}"; do
        log "  $c"
    done
    log "PRESERVED (kept by a default uninstall):"
    log "  the lamp_db volume (MariaDB data)"
    log "  the stack directory itself, including .env and html/"
    if [[ "$PURGE" == "yes" ]]; then
        log "PURGE (because --purge was given):"
        log "  the lamp_db volume (via compose down --volumes)"
    fi
    log "════════════════════════════════════════════════════════════"
}

do_install_container() {
    local dir; dir="$(stack_dir)"
    log "Step 1 of 2: checking the stack directory and .env"
    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        log "ERROR: no docker-compose.yml in $dir" >&2
        exit 1
    fi
    if [[ ! -f "$dir/.env" ]]; then
        log "ERROR: $dir/.env is missing." >&2
        log "Copy lamp-env.example to .env there, fill MYSQL_ROOT_PASSWORD, MYSQL_USER and MYSQL_PASSWORD (32 characters), and chmod 600 .env. Compose refuses to start without them, and so does this controller." >&2
        exit 1
    fi
    log "  .env present (values are never printed by this controller)"
    log "Step 2 of 2: building and starting the stack"
    act "docker compose up -d --build" compose up -d --build
    log ""
    log "Verify with the canary: curl -s http://localhost:8083/ (expect lines ending in LAMP OK)"
    log "Next: lamp-control-v1.0.sh --form container status"
}

do_up_container() {
    act "docker compose up -d" compose up -d
    log "LAMP stack (container form) is up. Canary: curl -s http://localhost:8083/"
}

do_down_container() {
    act "docker compose down (volumes kept)" compose down
    log "LAMP stack (container form) is down. The lamp_db volume is preserved."
}

do_status_container() {
    log "Form: container   Stack directory: $(stack_dir)"
    if ! command -v docker >/dev/null 2>&1; then
        log "docker is not installed on this host; the container form cannot be running here."
        return 0
    fi
    local c state
    printf '%-16s %s\n' "CONTAINER" "STATE"
    for c in "${CONTAINERS[@]}"; do
        if docker_container_present "$c"; then state="present"; else state="absent"; fi
        printf '%-16s %s\n' "$c" "$state"
    done
    if docker_volume_present "lamp_$DB_VOLUME_SUFFIX" || docker_volume_present "$DB_VOLUME_SUFFIX"; then
        log "Volume lamp_db: present (MariaDB data preserved)"
    else
        log "Volume lamp_db: absent"
    fi
    return 0
}

do_uninstall_container() {
    print_plan_container_uninstall
    if [[ "$DRY_RUN" == "yes" ]]; then
        log "Dry run: nothing was changed."
        return 0
    fi
    confirm_or_abort
    log ""
    log "Step 1 of 2: bringing the compose project down"
    if [[ "$PURGE" == "yes" ]]; then
        act "docker compose down --volumes" compose down --volumes
    else
        act "docker compose down" compose down
    fi
    log "Step 2 of 2: verification pass"
    local leftover=0 c
    for c in "${CONTAINERS[@]}"; do
        if docker_container_present "$c"; then
            log "  LEFTOVER: container $c still present" >&2
            leftover=1
        fi
    done
    if [[ "$PURGE" == "yes" ]]; then
        if docker_volume_present "lamp_$DB_VOLUME_SUFFIX"; then
            log "  LEFTOVER: volume lamp_$DB_VOLUME_SUFFIX still present after --purge" >&2
            leftover=1
        fi
    else
        if docker_volume_present "lamp_$DB_VOLUME_SUFFIX"; then
            log "  preserved: volume lamp_$DB_VOLUME_SUFFIX (MariaDB data)"
        fi
    fi
    if [[ "$leftover" -ne 0 ]]; then
        log "Verification FAILED: leftovers above." >&2
        exit 1
    fi
    log "  clean: no lamp containers remain."
    log ""
    log "════════════════════════════════════════════════════════════"
    log "LAMP stack uninstalled (container form)."
    if [[ "$PURGE" == "yes" ]]; then
        log "The lamp_db volume was removed with the stack."
    else
        log "Preserved: the lamp_db volume. Re-run with --purge to remove it."
    fi
    log "Redeploy with: lamp-control-v1.0.sh --form container install"
    log "════════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────

main() {
    local verb=""
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --form)
                [[ $# -ge 2 ]] || die_usage "--form needs a value (native or container)"
                FORM="$2"; shift 2 ;;
            --form=*) FORM="${1#--form=}"; shift ;;
            --dry-run) DRY_RUN="yes"; shift ;;
            --purge) PURGE="yes"; shift ;;
            -h|--help|help) usage; exit 0 ;;
            -*) die_usage "unknown option: $1" ;;
            *)
                if [[ -z "$verb" ]]; then verb="$1"; else args+=("$1"); fi
                shift ;;
        esac
    done
    [[ -n "$verb" ]] || die_usage "no verb given"
    [[ ${#args[@]} -eq 0 ]] || die_usage "unexpected arguments: ${args[*]}"
    case "$FORM" in
        native|container) ;;
        *) die_usage "unknown form: $FORM (native or container)" ;;
    esac
    case "$verb" in
        install|up|down|restart|status|uninstall) ;;
        *) die_usage "unknown verb: $verb" ;;
    esac
    if [[ "$PURGE" == "yes" && "$verb" != "uninstall" ]]; then
        die_usage "--purge is only valid with uninstall"
    fi
    if [[ "$verb" == "status" && "$DRY_RUN" == "yes" ]]; then
        die_usage "status takes no --dry-run"
    fi

    if [[ "$FORM" == "native" ]]; then
        load_family
        case "$verb" in
            install) do_install_native ;;
            up) do_up_native ;;
            down) do_down_native ;;
            restart) do_down_native; do_up_native ;;
            status) do_status_native ;;
            uninstall) do_uninstall_native ;;
        esac
    else
        case "$verb" in
            install) do_install_container ;;
            up) do_up_container ;;
            down) do_down_container ;;
            restart) do_down_container; do_up_container ;;
            status) do_status_container ;;
            uninstall) do_uninstall_container ;;
        esac
    fi
}

main "$@"
