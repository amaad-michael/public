#!/usr/bin/env bash
#
# NAME: deploy-monitoring-stack.sh
# WHAT: Bash deploy wrapper for the cluster Extended Observability
#       Stack (containers/monitoring/: Prometheus v3.15.1, Grafana
#       13.3.0, Alertmanager v0.34.1, Traefik, ntfy, step-ca,
#       Headscale, Vaultwarden, Uptime Kuma on standby-net).
#       Validates the host-side files, renders the compose project,
#       pulls the pinned images, brings the stack up, and verifies
#       health. Day-2 lifecycle (verify, status, down, restart,
#       uninstall) for all three deploy forms is owned by
#       scripts/monitoring/extended-observability-control-v1.0.sh;
#       this wrapper remains the bash deploy form it delegates to.
# WHY:  The stack is Docker-native by design; this wrapper is the
#       local-run form of its deployment — the same checks and steps
#       as COMPLETE_DEPLOYMENT_GUIDE.md, scripted so a deploy either
#       passes every gate or fails loudly before anything starts.
#       The Ansible form of the same deployment is
#       ansible/playbooks/monitoring/deploy-monitoring.yml.
# HOW:  ./deploy-monitoring-stack.sh [--dry-run] [--skip-pull]
#         [--project-dir DIR] [--wait SECONDS]
#       Run from anywhere; by default the project is located at
#       containers/monitoring/ relative to this script's repo root.
#
# Options:
#   --project-dir DIR   Compose project directory (default: the
#                       containers/monitoring/ folder of this repo)
#   --dry-run           Checks and compose render only; prints the
#                       pull/up commands instead of running them
#   --skip-pull         Skip `docker compose pull` (images already
#                       present on the host)
#   --wait SECONDS      Health verification budget (default: 120)
#   -h, --help          Show this help
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_DIR="${MONITORING_PROJECT_DIR:-$SCRIPT_DIR/../../containers/monitoring}"
DRY_RUN=0
SKIP_PULL=0
WAIT_SECONDS=120

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

usage() {
    sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
    case "$1" in
        --project-dir)
            (($# >= 2)) || die "--project-dir requires a value"
            PROJECT_DIR="$2"; shift ;;
        --dry-run)  DRY_RUN=1 ;;
        --skip-pull) SKIP_PULL=1 ;;
        --wait)
            (($# >= 2)) || die "--wait requires a value (seconds)"
            [[ "$2" =~ ^[0-9]+$ ]] || die "--wait must be a non-negative integer, got: $2"
            WAIT_SECONDS="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# --- Project layout ---------------------------------------------------------
[[ -d "$PROJECT_DIR" ]] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR=$(cd -- "$PROJECT_DIR" &>/dev/null && pwd)
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] \
    || die "no docker-compose.yml in $PROJECT_DIR"
info "project: $PROJECT_DIR"

# --- Docker + Compose plugin --------------------------------------------------
command -v docker >/dev/null 2>&1 \
    || die "docker not found in PATH — install Docker with the Compose v2 plugin first"
docker compose version >/dev/null 2>&1 \
    || die "'docker compose' (v2 plugin) not available — 'docker compose version' failed"
info "docker compose: $(docker compose version --short 2>/dev/null || docker compose version)"

compose() { docker compose --project-directory "$PROJECT_DIR" -f "$PROJECT_DIR/docker-compose.yml" "$@"; }

# --- Host-side .env -------------------------------------------------------------
ENV_FILE="$PROJECT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    die ".env missing in $PROJECT_DIR — create it with: cp .env.example .env && chmod 600 .env, then set GRAFANA_ADMIN_PASSWORD and the TRAEFIK_AUTH_HASH line (see containers/monitoring/SECRETS_MANAGEMENT.md)"
fi
ENV_MODE=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")
[[ "$ENV_MODE" == "600" ]] \
    || printf 'warning: %s has mode %s, expected 600\n' "$ENV_FILE" "$ENV_MODE" >&2
if grep -q 'REPLACE_ME' "$ENV_FILE"; then
    die ".env still contains REPLACE_ME placeholders — set GRAFANA_ADMIN_PASSWORD (and TRAEFIK_AUTH_HASH) before deploying"
fi
GRAFANA_PW=$(grep '^GRAFANA_ADMIN_PASSWORD=' "$ENV_FILE" | head -n 1 | cut -d= -f2-)
[[ -n "$GRAFANA_PW" ]] \
    || die ".env has no GRAFANA_ADMIN_PASSWORD value — .env.example ships it empty; set a real one (generate: openssl rand -base64 32)"
info ".env present and free of placeholders"

# --- Host-local configs the compose mounts --------------------------------------
MISSING=()
for cfg in ntfy.conf headscale.conf policy.hujson; do
    [[ -f "$PROJECT_DIR/$cfg" ]] || MISSING+=("$cfg")
done
if ((${#MISSING[@]})); then
    die "host-local config(s) missing in $PROJECT_DIR: ${MISSING[*]} — create them from the examples in COMPLETE_DEPLOYMENT_GUIDE.md (Docker would otherwise create directories at the mount paths and the services could never start)"
fi
info "host-local configs present (ntfy.conf, headscale.conf, policy.hujson)"

# --- Render check -----------------------------------------------------------------
info "rendering compose project (docker compose config)"
compose config -q || die "docker compose config failed — fix the compose file or .env before deploying"
mapfile -t SERVICES < <(compose config --services)
((${#SERVICES[@]})) || die "compose rendered zero services — nothing to deploy"
info "services (${#SERVICES[@]}): ${SERVICES[*]}"

# --- Deploy -------------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
    info "dry-run: would run the following in $PROJECT_DIR:"
    [[ $SKIP_PULL -eq 1 ]] || printf '  docker compose pull\n'
    printf '  docker compose up -d\n'
    info "dry-run complete — no changes made"
    exit 0
fi

if [[ $SKIP_PULL -eq 0 ]]; then
    info "pulling pinned images"
    compose pull
else
    info "skipping image pull (--skip-pull)"
fi

info "bringing the stack up"
compose up -d

# --- Verify ---------------------------------------------------------------------------
info "waiting up to ${WAIT_SECONDS}s for all services to report healthy"
DEADLINE=$((SECONDS + WAIT_SECONDS))
UNHEALTHY=("${SERVICES[@]}")
while ((SECONDS < DEADLINE)); do
    PS_OUT=$(compose ps 2>/dev/null || true)
    UNHEALTHY=()
    for svc in "${SERVICES[@]}"; do
        line=$(grep -F "standby-$svc" <<<"$PS_OUT" || true)
        if [[ -z "$line" ]] || ! grep -q '(healthy)' <<<"$line"; then
            UNHEALTHY+=("$svc")
        fi
    done
    ((${#UNHEALTHY[@]} == 0)) && break
    sleep 5
done
if ((${#UNHEALTHY[@]})); then
    compose ps >&2 || true
    die "services not healthy after ${WAIT_SECONDS}s: ${UNHEALTHY[*]} — inspect with: docker compose -f $PROJECT_DIR/docker-compose.yml logs --tail 100 <service>"
fi
info "all ${#SERVICES[@]} services healthy"
compose ps
