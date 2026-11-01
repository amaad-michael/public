#!/usr/bin/env bash
#===============================================================================
# extended-observability-control-v1.0.sh - one controller for the whole
# Extended Observability Stack lifecycle
# Version: 1.0 (2026-10-31)
#
# READ THIS BEFORE A REAL RUN
#   This script owns the Extended Observability Stack end to end, in the
#   same shape as the neo1 observability control script and the Gitea
#   controller: one entry point, symmetrical verbs, and no verb
#   reimplements what another repo script already does.
#
#   The stack is the 9-service Docker stack in containers/monitoring/
#   (Prometheus, Grafana, Alertmanager, Traefik, ntfy, step-ca,
#   Headscale, Vaultwarden, Uptime Kuma on the standby-net bridge). It
#   is the container-form counterpart of neo1's native observability
#   stack, extended with an access layer (Traefik, step-ca, Headscale,
#   Vaultwarden, Uptime Kuma). Until 2026-10-31 it was called the
#   standby monitoring stack; the rename changes prose and titles
#   only. The functional identifiers keep the standby- prefix on
#   purpose: container names (standby-prometheus, ...), the network
#   (standby-net), and the volume names below.
#
#   FORMS (deploy routes; pick with --form on the deploy verb)
#     The runtime state is the compose project. The three forms are
#     three deployment routes into that same project, not three
#     different stacks:
#     container (default)  This controller runs the deploy gates and
#               drives docker compose itself, locally.
#     bash      Delegates to the sibling local-run wrapper,
#               scripts/monitoring/deploy-monitoring-stack.sh, as-is.
#     ansible   Delegates to the playbook-run form,
#               ansible/playbooks/monitoring/deploy-monitoring.yml,
#               against a fleet host (--host is required; the playbook
#               deploys the checkout that already exists on the target
#               at --target-dir and does not clone the repo).
#     verify, status, up, down, restart, and uninstall act on the
#     compose project directly, whichever form deployed it.
#
#   PROJECT NAME (read this; it decides your volume names)
#     Compose names the data volumes <project>_<volume>. Every backup
#     and disaster-recovery command in the stack's own docs uses
#     standby_prometheus_data, standby_vaultwarden_data, and so on,
#     which only exist when the compose project is named "standby".
#     Neither shipped deploy route sets a project name, so a deploy
#     from the checkout directory silently used the directory name
#     instead. This controller pins the project name to "standby"
#     for every compose call (override with --project-name or
#     EOS_PROJECT_NAME if you really mean it). status also probes
#     the default directory-named project and warns if it holds
#     containers, which is the fingerprint of a pre-controller deploy.
#
#   VERBS
#     deploy   Run the deploy gates (below), pull the pinned images,
#              bring the stack up, and verify health. --form picks the
#              deployment route. --skip-pull and --wait SECONDS carry
#              the same meaning in every form.
#     verify   Health gate only: every service's container must exist
#              and report (healthy) within --wait seconds.
#     status   Print the footprint and per-service state. Exit 0 when
#              every service has a container, 1 when any is missing
#              or the footprint is partial. Run and health state are
#              reported as fields, not folded into the exit code:
#              this is a lifecycle controller, and "installed but
#              stopped" is a normal state during a redeploy cycle.
#     up       docker compose up -d for an already-configured host,
#              then verify.
#     down     docker compose down: containers and the project
#              network are removed; all data volumes are PRESERVED.
#              Down is not uninstall and asks for no confirmation.
#     restart  docker compose restart, then verify.
#     uninstall  Remove the stack (containers and network). Data is
#              PRESERVED by default (see below). Needs a typed
#              confirmation.
#
#   DEPLOY GATES (container form; the bash and Ansible forms run the
#   same gates in their own code, which is why they exist as forms)
#     In order, each failing loudly before anything starts: project
#     directory and docker-compose.yml present; Docker with the
#     Compose v2 plugin present; .env present (mode 600 expected; a
#     different mode warns); no REPLACE_ME placeholder left in .env;
#     GRAFANA_ADMIN_PASSWORD set to a non-empty value in .env (checked
#     by presence only, see SECRETS); the host-local configs the
#     compose mounts (ntfy.conf, headscale.conf, policy.hujson)
#     present; docker compose config renders.
#
#   SECRETS (containers/monitoring/SECRETS_MANAGEMENT.md is the
#   stack's own rulebook; this controller follows it)
#     .env is never printed, in whole or in part, by any verb. The
#     gates check that values exist without reading them into output.
#     Rendered compose data is limited to service, volume, and image
#     names: a full "docker compose config" render interpolates .env
#     values (the Grafana admin password among them) into its output,
#     so this controller never produces one. Do not paste a full
#     render into tickets or chat either.
#
#   DATA RULES (down and uninstall)
#     PRESERVED by default: the 8 named volumes (prometheus_data,
#     grafana_data, alertmanager_data, traefik_data with the ACME
#     certificates, step_ca_data with the CA's PKI, headscale_data,
#     vaultwarden_data with the password vault, uptime_kuma_data),
#     the host-side .env, the host-local configs, and the checkout.
#     PURGE (--purge on uninstall) removes the volumes too. A purge
#     destroys the step-ca PKI (every certificate it issued is
#     orphaned), the Vaultwarden vault, and the Headscale node
#     registry. There is no undo for a purge.
#
#   CONFIRMATION
#     uninstall asks you to type the word: observability
#     A wrong or empty answer aborts with nothing changed.
#     --dry-run prints the full labeled plan and changes nothing,
#     and never asks for confirmation.
#
#   Exit codes: 0 = done or already in the requested state,
#   1 = a step or the closing verification failed, 2 = usage error.
#===============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)

PROJECT_DIR="${EOS_PROJECT_DIR:-${MONITORING_PROJECT_DIR:-$REPO_ROOT/containers/monitoring}}"
PROJECT_NAME="${EOS_PROJECT_NAME:-standby}"
FORM="container"
HOST=""
TARGET_DIR=""
DRY_RUN=0
PURGE=0
SKIP_PULL=0
WAIT_SECONDS=120

CONFIRM_WORD="observability"

# Facts from containers/monitoring/docker-compose.yml (v1.0, 2026-10-31).
# The render is authoritative at runtime; these lists ground the plan,
# the status table, and the drift warning when they disagree.
EXPECTED_SERVICES=(prometheus grafana alertmanager traefik ntfy step-ca headscale vaultwarden uptime-kuma)
EXPECTED_VOLUMES=(prometheus_data grafana_data alertmanager_data traefik_data step_ca_data headscale_data vaultwarden_data uptime_kuma_data)
HOST_CONFIGS=(ntfy.conf headscale.conf policy.hujson)

declare -A PORTS=(
    [prometheus]="9090"
    [grafana]="3000"
    [alertmanager]="9093"
    [traefik]="80, 443, 8080"
    [ntfy]="8081"
    [step-ca]="9000"
    [headscale]="8082, 3478/udp"
    [vaultwarden]="8000"
    [uptime-kuma]="3001"
)

declare -A VOLUME_NOTES=(
    [prometheus_data]="metrics TSDB"
    [grafana_data]="dashboards and Grafana state"
    [alertmanager_data]="alert state"
    [traefik_data]="ACME certificates"
    [step_ca_data]="the step-ca PKI"
    [headscale_data]="Headscale node registry"
    [vaultwarden_data]="the Vaultwarden password vault"
    [uptime_kuma_data]="monitors and status history"
)

usage() {
    cat <<'EOF'
Usage:
  extended-observability-control-v1.0.sh deploy
      [--form container|bash|ansible] [--host HOST] [--target-dir DIR]
      [--skip-pull] [--wait SECONDS] [--dry-run]
  extended-observability-control-v1.0.sh verify [--wait SECONDS]
  extended-observability-control-v1.0.sh status
  extended-observability-control-v1.0.sh up [--wait SECONDS] [--dry-run]
  extended-observability-control-v1.0.sh down [--dry-run]
  extended-observability-control-v1.0.sh restart [--wait SECONDS] [--dry-run]
  extended-observability-control-v1.0.sh uninstall [--purge] [--dry-run]

  Global options (before or after the verb):
    --project-dir DIR    Compose project directory (default: the
                         containers/monitoring/ folder of this repo;
                         EOS_PROJECT_DIR / MONITORING_PROJECT_DIR)
    --project-name NAME  Compose project name (default: standby;
                         EOS_PROJECT_NAME). The name decides the
                         data volume names; see the header.

  deploy forms:
    container  This controller runs the gates and compose itself.
    bash       Delegate to scripts/monitoring/deploy-monitoring-stack.sh.
    ansible    Delegate to ansible/playbooks/monitoring/
               deploy-monitoring.yml. --host HOST (the ansible -l
               limit) is required. --target-dir DIR is the repo
               checkout path on the target (default: --project-dir).
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
die_usage() {
    printf 'error: %s\n' "$*" >&2
    usage >&2
    exit 2
}
info() { printf '==> %s\n' "$*"; }

# run: execute, or print under --dry-run. (Local IFS: joining "$*" for
# the printout must not inherit an unusual IFS.)
run() {
    local IFS=' '
    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'DRY-RUN: %s\n' "$*"
    else
        "$@"
    fi
}

# --- Argument parsing -------------------------------------------------------
VERB=""
while (($#)); do
    case "$1" in
        --project-dir)
            (($# >= 2)) || die_usage "--project-dir requires a value"
            PROJECT_DIR="$2"; shift ;;
        --project-name)
            (($# >= 2)) || die_usage "--project-name requires a value"
            PROJECT_NAME="$2"; shift ;;
        --form)
            (($# >= 2)) || die_usage "--form requires a value"
            FORM="$2"; shift ;;
        --host)
            (($# >= 2)) || die_usage "--host requires a value"
            HOST="$2"; shift ;;
        --target-dir)
            (($# >= 2)) || die_usage "--target-dir requires a value"
            TARGET_DIR="$2"; shift ;;
        --wait)
            (($# >= 2)) || die_usage "--wait requires a value (seconds)"
            [[ "$2" =~ ^[0-9]+$ ]] || die_usage "--wait must be a non-negative integer, got: $2"
            WAIT_SECONDS="$2"; shift ;;
        --skip-pull) SKIP_PULL=1 ;;
        --purge) PURGE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            die_usage "unknown option: $1 (try --help)" ;;
        *)
            [[ -z "$VERB" ]] || die_usage "unexpected extra argument: $1"
            VERB="$1" ;;
    esac
    shift
done
[[ -n "$VERB" ]] || { usage >&2; exit 2; }
case "$VERB" in
    deploy|verify|status|up|down|restart|uninstall) ;;
    *) die_usage "unknown verb: $VERB (try --help)" ;;
esac
case "$FORM" in
    container|bash|ansible) ;;
    *) die_usage "unknown form: $FORM (container, bash, or ansible)" ;;
esac

# --- Project layout ---------------------------------------------------------
[[ -d "$PROJECT_DIR" ]] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR=$(cd -- "$PROJECT_DIR" &>/dev/null && pwd)
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] \
    || die "no docker-compose.yml in $PROJECT_DIR"
[[ -n "$TARGET_DIR" ]] || TARGET_DIR="$PROJECT_DIR"

compose() {
    docker compose -p "$PROJECT_NAME" --project-directory "$PROJECT_DIR" \
        -f "$PROJECT_DIR/docker-compose.yml" "$@"
}

require_docker() {
    command -v docker >/dev/null 2>&1 \
        || die "docker not found in PATH: install Docker with the Compose v2 plugin first"
    docker compose version >/dev/null 2>&1 \
        || die "'docker compose' (v2 plugin) not available: 'docker compose version' failed"
}

# Services and volumes from the render; falls back to the expected
# lists when the render cannot run (for example .env absent), so
# status can still describe the footprint.
SERVICES=()
VOLUMES=()
load_render() {
    local rendered=()
    if docker compose version >/dev/null 2>&1; then
        mapfile -t rendered < <(compose config --services 2>/dev/null || true)
        if ((${#rendered[@]})); then
            SERVICES=("${rendered[@]}")
        fi
        mapfile -t rendered < <(compose config --volumes 2>/dev/null || true)
        if ((${#rendered[@]})); then
            VOLUMES=("${rendered[@]}")
        fi
    fi
    if ((${#SERVICES[@]} == 0)); then
        SERVICES=("${EXPECTED_SERVICES[@]}")
    fi
    if ((${#VOLUMES[@]} == 0)); then
        VOLUMES=("${EXPECTED_VOLUMES[@]}")
    fi
}

warn_on_drift() {
    # Order-insensitive: the render's service order is compose's, not
    # the file's, and order is not drift.
    local rendered_sorted expected_sorted
    rendered_sorted=$(printf '%s\n' "${SERVICES[@]}" | sort | tr '\n' ' ')
    expected_sorted=$(printf '%s\n' "${EXPECTED_SERVICES[@]}" | sort | tr '\n' ' ')
    if [[ "$rendered_sorted" != "$expected_sorted" ]]; then
        printf 'warning: rendered services (%s) differ from the v1.0 list (%s): the compose file changed; the render wins\n' \
            "${SERVICES[*]}" "${EXPECTED_SERVICES[*]}" >&2
    fi
    rendered_sorted=$(printf '%s\n' "${VOLUMES[@]}" | sort | tr '\n' ' ')
    expected_sorted=$(printf '%s\n' "${EXPECTED_VOLUMES[@]}" | sort | tr '\n' ' ')
    if [[ "$rendered_sorted" != "$expected_sorted" ]]; then
        printf 'warning: rendered volumes (%s) differ from the v1.0 list (%s): the compose file changed; the render wins\n' \
            "${VOLUMES[*]}" "${EXPECTED_VOLUMES[*]}" >&2
    fi
}

# --- Deploy gates -------------------------------------------------------------
run_gates() {
    info "Step 1: deploy gates"
    require_docker
    info "docker compose: $(docker compose version --short 2>/dev/null || docker compose version)"

    local env_file="$PROJECT_DIR/.env"
    if [[ ! -f "$env_file" ]]; then
        die ".env missing in $PROJECT_DIR: create it with: cp .env.example .env && chmod 600 .env, then set GRAFANA_ADMIN_PASSWORD and the TRAEFIK_AUTH_HASH line (see containers/monitoring/SECRETS_MANAGEMENT.md)"
    fi
    local env_mode
    env_mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file")
    if [[ "$env_mode" != "600" ]]; then
        printf 'warning: %s has mode %s, expected 600\n' "$env_file" "$env_mode" >&2
    fi
    if grep -q 'REPLACE_ME' "$env_file"; then
        die ".env still contains REPLACE_ME placeholders: set GRAFANA_ADMIN_PASSWORD (and TRAEFIK_AUTH_HASH) before deploying"
    fi
    # Presence only: the value is never read into a variable or output.
    if ! grep -qE '^GRAFANA_ADMIN_PASSWORD=.+' "$env_file"; then
        die ".env has no GRAFANA_ADMIN_PASSWORD value: .env.example ships it empty; set a real one (generate: openssl rand -base64 32)"
    fi
    info ".env present, mode $env_mode, placeholders absent, Grafana password set (value not read)"

    local missing=() cfg
    for cfg in "${HOST_CONFIGS[@]}"; do
        [[ -f "$PROJECT_DIR/$cfg" ]] || missing+=("$cfg")
    done
    if ((${#missing[@]})); then
        die "host-local config(s) missing in $PROJECT_DIR: ${missing[*]}: create them from the examples in COMPLETE_DEPLOYMENT_GUIDE.md (Docker would otherwise create directories at the mount paths and the services could never start)"
    fi
    info "host-local configs present (${HOST_CONFIGS[*]})"

    compose config -q || die "docker compose config failed: fix the compose file or .env before deploying"
    load_render
    warn_on_drift
    info "compose renders: ${#SERVICES[@]} services (${SERVICES[*]})"
}

# --- Health verification ------------------------------------------------------
# Every service in the compose file defines a healthcheck; a service is
# verified when its container's compose ps line reports (healthy).
unhealthy_services() {
    local ps_out svc line
    ps_out=$(compose ps 2>/dev/null || true)
    UNHEALTHY=()
    for svc in "${SERVICES[@]}"; do
        line=$(grep -F "standby-$svc" <<<"$ps_out" || true)
        if [[ -z "$line" ]] || ! grep -q '(healthy)' <<<"$line"; then
            UNHEALTHY+=("$svc")
        fi
    done
}

verify_health() {
    info "waiting up to ${WAIT_SECONDS}s for all services to report healthy"
    local deadline=$((SECONDS + WAIT_SECONDS))
    unhealthy_services
    while ((${#UNHEALTHY[@]})) && ((SECONDS < deadline)); do
        sleep 5
        unhealthy_services
    done
    if ((${#UNHEALTHY[@]})); then
        compose ps >&2 || true
        die "services not healthy after ${WAIT_SECONDS}s: ${UNHEALTHY[*]}: inspect with: docker compose -p $PROJECT_NAME -f $PROJECT_DIR/docker-compose.yml logs --tail 100 <service>"
    fi
    info "all ${#SERVICES[@]} services healthy"
}

# --- Deploy -------------------------------------------------------------------
deploy_container_form() {
    run_gates
    info "Step 2: pull the pinned images and bring the stack up"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "plan:"
        printf '  CREATE/UPDATE  %s containers and the %s_standby-net network (project %s)\n' \
            "${#SERVICES[@]}" "$PROJECT_NAME" "$PROJECT_NAME"
        printf '  PRESERVED      existing volume data is reused; .env is read, never printed\n'
        [[ $SKIP_PULL -eq 1 ]] || run compose pull
        run compose up -d
        info "dry-run complete: no changes made"
        return 0
    fi
    if [[ $SKIP_PULL -eq 0 ]]; then
        compose pull
    else
        info "skipping image pull (--skip-pull)"
    fi
    compose up -d
    info "Step 3: verify health"
    verify_health
    compose ps
    print_redeploy_summary "deploy (form: container)"
}

deploy_bash_form() {
    local wrapper="$SCRIPT_DIR/deploy-monitoring-stack.sh"
    [[ -x "$wrapper" ]] || die "bash form wrapper not found or not executable: $wrapper"
    info "delegating to the bash form: $wrapper"
    local args=(--project-dir "$PROJECT_DIR" --wait "$WAIT_SECONDS")
    [[ $SKIP_PULL -eq 1 ]] && args+=(--skip-pull)
    # The wrapper has no project-name option; compose honors
    # COMPOSE_PROJECT_NAME, which pins the project (and therefore
    # the volume names) without modifying the wrapper.
    if [[ $DRY_RUN -eq 1 ]]; then
        # The wrapper's own dry-run validates every gate and renders,
        # and changes nothing; passing it through gives real gate
        # coverage instead of a printed guess.
        args+=(--dry-run)
        COMPOSE_PROJECT_NAME="$PROJECT_NAME" "$wrapper" "${args[@]}"
        info "dry-run complete: the wrapper validated and rendered; no changes made"
        return 0
    fi
    COMPOSE_PROJECT_NAME="$PROJECT_NAME" "$wrapper" "${args[@]}"
    print_redeploy_summary "deploy (form: bash)"
}

deploy_ansible_form() {
    local playbook="$REPO_ROOT/ansible/playbooks/monitoring/deploy-monitoring.yml"
    [[ -f "$playbook" ]] || die "Ansible form playbook not found: $playbook"
    [[ -n "$HOST" ]] || die_usage "the ansible form requires --host HOST (the ansible -l limit)"
    local cmd=(ansible-playbook -i hosts "playbooks/monitoring/deploy-monitoring.yml"
        -l "$HOST"
        -e "monitoring_project_dir=$TARGET_DIR"
        -e "monitoring_wait_seconds=$WAIT_SECONDS")
    [[ $SKIP_PULL -eq 1 ]] && cmd+=(-e "monitoring_skip_pull=true")
    if [[ $DRY_RUN -eq 1 ]]; then
        info "plan: run the Ansible form from $REPO_ROOT/ansible with:"
        printf 'DRY-RUN: %s\n' "${cmd[*]}"
        info "dry-run complete: no changes made"
        return 0
    fi
    command -v ansible-playbook >/dev/null 2>&1 \
        || die "ansible-playbook not found in PATH: the Ansible form runs from a host with Ansible installed"
    info "delegating to the Ansible form (target checkout: $TARGET_DIR on $HOST)"
    (cd "$REPO_ROOT/ansible" && "${cmd[@]}")
    print_redeploy_summary "deploy (form: ansible)"
}

print_redeploy_summary() {
    cat <<EOF
==> done: $1
    project: $PROJECT_DIR (compose project name: $PROJECT_NAME)
    redeploy: $0 deploy --form $FORM --project-dir $PROJECT_DIR
    day-2:    $0 status | verify | down | restart | uninstall
EOF
}

# --- Status -------------------------------------------------------------------
container_line() {
    # $1 = service; prints the compose ps -a line for its container
    local ps_out
    ps_out=$(compose ps -a 2>/dev/null || true)
    grep -F "standby-$1" <<<"$ps_out" || true
}

do_status() {
    require_docker
    load_render
    info "Extended Observability Stack: status"
    printf '  project dir:   %s\n' "$PROJECT_DIR"
    printf '  project name:  %s\n' "$PROJECT_NAME"
    local env_file="$PROJECT_DIR/.env" env_mode="absent"
    if [[ -f "$env_file" ]]; then
        env_mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file")
        printf '  .env:          present (mode %s; values never printed)\n' "$env_mode"
    else
        printf '  .env:          ABSENT: the stack cannot deploy without it\n'
    fi
    printf '\n  %-14s %-24s %-10s %-12s %s\n' "SERVICE" "CONTAINER" "STATE" "HEALTH" "HOST PORTS"
    local missing_count=0 svc line state health
    for svc in "${SERVICES[@]}"; do
        line=$(container_line "$svc")
        if [[ -z "$line" ]]; then
            state="missing"; health="-"; missing_count=$((missing_count + 1))
        elif grep -q 'Up' <<<"$line"; then
            state="up"
            if grep -q '(healthy)' <<<"$line"; then
                health="healthy"
            elif grep -q '(unhealthy)' <<<"$line"; then
                health="unhealthy"
            elif grep -q '(health: starting)' <<<"$line"; then
                health="starting"
            else
                health="no report"
            fi
        else
            state="not up"; health="-"
        fi
        printf '  %-14s %-24s %-10s %-12s %s\n' "$svc" "standby-$svc" "$state" "$health" "${PORTS[$svc]:--}"
    done
    printf '\n  volumes (project %s):\n' "$PROJECT_NAME"
    local vol real
    local existing=()
    mapfile -t existing < <(docker volume ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Name}}' 2>/dev/null || true)
    for vol in "${VOLUMES[@]}"; do
        real="${PROJECT_NAME}_${vol}"
        if printf '%s\n' "${existing[@]}" | grep -qx "$real"; then
            printf '    %-28s present  (%s)\n' "$real" "${VOLUME_NOTES[$vol]:-data}"
        else
            printf '    %-28s absent\n' "$real"
        fi
    done
    # Pre-controller deploys used the default project name (the
    # directory basename); flag them so nobody "fixes" a port
    # conflict by deploying a second copy of the stack.
    local legacy
    legacy=$(basename "$PROJECT_DIR")
    if [[ "$legacy" != "$PROJECT_NAME" ]]; then
        local legacy_containers
        legacy_containers=$(docker ps -a --filter "label=com.docker.compose.project=$legacy" --format '{{.Names}}' 2>/dev/null || true)
        if [[ -n "$legacy_containers" ]]; then
            printf '\n  warning: containers exist under the default compose project name "%s":\n' "$legacy" >&2
            printf '    %s\n' "$legacy_containers" >&2
            printf '  That is a pre-controller deploy. This controller manages project "%s";\n' "$PROJECT_NAME" >&2
            printf '  reconcile manually (the old project owns the host ports until it is down).\n' >&2
        fi
    fi
    if [[ $missing_count -gt 0 ]]; then
        printf '\n%s of %s services have no container: the stack is missing or partial.\n' \
            "$missing_count" "${#SERVICES[@]}" >&2
        return 1
    fi
    printf '\nall %s services have containers; health is a field above (use verify for the health gate).\n' "${#SERVICES[@]}"
    return 0
}

# --- Down / uninstall verification ---------------------------------------------
project_containers() {
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}' 2>/dev/null || true
}

project_volumes() {
    docker volume ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Name}}' 2>/dev/null || true
}

verify_removed() {
    local fail=0 left
    left=$(project_containers)
    if [[ -n "$left" ]]; then
        printf 'LEFTOVER: project containers still exist: %s\n' "$left" >&2
        fail=1
    fi
    left=$(docker network ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Name}}' 2>/dev/null || true)
    if [[ -n "$left" ]]; then
        printf 'LEFTOVER: project network still exists: %s\n' "$left" >&2
        fail=1
    fi
    if [[ $PURGE -eq 1 ]]; then
        left=$(project_volumes)
        if [[ -n "$left" ]]; then
            printf 'LEFTOVER: project volumes still exist after purge: %s\n' "$left" >&2
            fail=1
        fi
    fi
    return $fail
}

confirm_uninstall() {
    local reply=""
    echo ""
    echo "Type the word '${CONFIRM_WORD}' to proceed with the uninstall:"
    if [[ -r /dev/tty ]]; then
        read -r reply < /dev/tty || reply=""
    else
        read -r reply || reply=""
    fi
    if [[ "$reply" != "$CONFIRM_WORD" ]]; then
        echo "Confirmation did not match. Nothing was changed."
        exit 1
    fi
}

print_teardown_plan() {
    local verb=$1 vol
    cat <<EOF
Plan for $verb (project $PROJECT_NAME in $PROJECT_DIR):
  REMOVE      the ${#SERVICES[@]} service containers (${SERVICES[*]})
  REMOVE      the project network ${PROJECT_NAME}_standby-net
  PRESERVED   the host-side .env in $PROJECT_DIR (your secrets; delete it yourself if retiring the host)
  PRESERVED   the host-local configs (${HOST_CONFIGS[*]})
  PRESERVED   the checkout at $PROJECT_DIR and everything in git
EOF
    if [[ $PURGE -eq 1 ]]; then
        printf '  PURGE       the %s named volumes and ALL their data:\n' "${#VOLUMES[@]}"
        for vol in "${VOLUMES[@]}"; do
            printf '    - %-28s %s\n' "${PROJECT_NAME}_${vol}" "${VOLUME_NOTES[$vol]:-data}"
        done
        cat <<'EOF'
  WARNING     a purge destroys the step-ca PKI (every certificate it
              issued is orphaned), the Vaultwarden vault, and the
              Headscale node registry. There is no undo.
EOF
    else
        printf '  PRESERVED   the %s named volumes and all stack data (re-run with --purge to remove them):\n' "${#VOLUMES[@]}"
        for vol in "${VOLUMES[@]}"; do
            printf '    - %-28s %s\n' "${PROJECT_NAME}_${vol}" "${VOLUME_NOTES[$vol]:-data}"
        done
    fi
}

do_down() {
    require_docker
    load_render
    PURGE=0
    print_teardown_plan "down"
    info "Step 1: docker compose down (volumes preserved)"
    run compose down
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dry-run complete: no changes made"
        return 0
    fi
    info "Step 2: verification pass"
    if ! verify_removed; then
        die "down finished but the verification pass found leftovers (above)"
    fi
    info "stack is down; all data volumes preserved"
    print_redeploy_summary "down"
}

do_uninstall() {
    require_docker
    load_render
    print_teardown_plan "uninstall"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dry-run complete: no changes made, no confirmation asked"
        return 0
    fi
    confirm_uninstall
    if [[ $PURGE -eq 1 ]]; then
        info "Step 1: docker compose down --volumes (purge)"
        run compose down --volumes
    else
        info "Step 1: docker compose down (volumes preserved)"
        run compose down
    fi
    info "Step 2: verification pass"
    if ! verify_removed; then
        die "uninstall finished but the verification pass found leftovers (above)"
    fi
    if [[ $PURGE -eq 1 ]]; then
        info "stack uninstalled and data volumes purged"
    else
        info "stack uninstalled; data volumes preserved (uninstall --purge removes them)"
    fi
    print_redeploy_summary "uninstall"
}

# --- Main ---------------------------------------------------------------------
case "$VERB" in
    deploy)
        case "$FORM" in
            container) deploy_container_form ;;
            bash) deploy_bash_form ;;
            ansible) deploy_ansible_form ;;
        esac
        ;;
    verify)
        require_docker
        load_render
        verify_health
        ;;
    status)
        if [[ $DRY_RUN -eq 1 || $PURGE -eq 1 ]]; then
            die_usage "status takes no --dry-run or --purge"
        fi
        do_status
        ;;
    up)
        require_docker
        load_render
        info "Step 1: docker compose up -d"
        run compose up -d
        if [[ $DRY_RUN -eq 1 ]]; then
            info "dry-run complete: no changes made"
            exit 0
        fi
        info "Step 2: verify health"
        verify_health
        print_redeploy_summary "up"
        ;;
    down)
        do_down
        ;;
    restart)
        require_docker
        load_render
        info "Step 1: docker compose restart"
        run compose restart
        if [[ $DRY_RUN -eq 1 ]]; then
            info "dry-run complete: no changes made"
            exit 0
        fi
        info "Step 2: verify health"
        verify_health
        print_redeploy_summary "restart"
        ;;
    uninstall)
        do_uninstall
        ;;
esac
