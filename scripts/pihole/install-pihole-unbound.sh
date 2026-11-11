#!/usr/bin/env bash
#
# install-pihole-unbound.sh
#
# Deploy the Pi-hole + Unbound container pair from containers/pihole/
# (the v2 compose project) on a local Docker host. This is the bash form
# of the deployment whose other forms are the Ansible playbooks in
# ansible/playbooks/pihole/ (bare-metal install) and the compose project
# itself (containers/pihole/docker-compose.yml).
#
# The compose pair is deployed exactly as shipped: Pi-hole is the only
# LAN-facing service (ports 53/tcp, 53/udp, 80, 443); Unbound has NO
# ports block and is reachable only on the pihole bridge network
# (172.20.0.0/16) at 172.20.0.3:5335. This script refuses to deploy a
# compose project in which Unbound publishes a host port.
#
# Usage:
#   sudo ./install-pihole-unbound.sh [OPTIONS]
#
# Options:
#   --compose-dir DIR     Compose project directory
#                         (default: <repo>/containers/pihole)
#   --with-blocklists     After a healthy start, seed the five blocklists
#                         with pihole-init-blocklists.sh (run inside the
#                         Pi-hole container)
#   --dry-run             Validate prerequisites and .env, render the
#                         compose config, check the Unbound exposure
#                         guard, then print the deploy commands without
#                         running them
#   -h, --help            Show this help
#
# Prerequisites: root, the docker CLI with the compose plugin (or the
# standalone docker-compose binary), and a filled-in .env beside the
# compose file (PIHOLE_TAG, UNBOUND_TAG, PIHOLE_API_PASSWORD). The
# script fails closed on any missing or empty .env value and rejects
# the "latest" tag: there is no :latest fallback on the DNS plane.
#
# Deploy order (from the compose header): pi0 (secondary) first, verify,
# then pi4 (primary). Idempotent: safe to re-run.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR="${SCRIPT_DIR}/../../containers/pihole"
WITH_BLOCKLISTS=0
DRY_RUN=0

usage() {
    sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while (($#)); do
    case "$1" in
        --compose-dir)
            (($# >= 2)) || die "--compose-dir requires a value"
            COMPOSE_DIR="$2"; shift ;;
        --with-blocklists) WITH_BLOCKLISTS=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "run as root, e.g.: sudo $0"

# --- Compose project -----------------------------------------------------
[[ -d $COMPOSE_DIR ]] || die "compose directory not found: $COMPOSE_DIR"
COMPOSE_DIR=$(cd -- "$COMPOSE_DIR" && pwd)
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
[[ -f $COMPOSE_FILE ]] || die "compose file not found: $COMPOSE_FILE"
ENV_FILE="${COMPOSE_DIR}/.env"
# The example .env ships only with the current stack, so when
# --compose-dir points at a directory that carries no copy of its own
# (where the missing-.env refusal below is the first thing an
# operator hits), the remediation still has to name a file that
# exists. Resolve it by probing with
# plain -f tests, never by a path resolution that can fail the run:
# the compose directory's own copy first (the staged layout, where
# the scripts sit flat in their own directory), then the checkout
# layout's copy, and as a last resort the path in the repo as text.
if [[ -f ${COMPOSE_DIR}/pi-dns-env.example ]]; then
    ENV_EXAMPLE="${COMPOSE_DIR}/pi-dns-env.example"
elif [[ -f ${SCRIPT_DIR}/../../containers/pihole/pi-dns-env.example ]]; then
    ENV_EXAMPLE="${SCRIPT_DIR}/../../containers/pihole/pi-dns-env.example"
else
    ENV_EXAMPLE="containers/pihole/pi-dns-env.example (in the public repo)"
fi

# --- Prerequisites ---------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker CLI not found in PATH"
COMPOSE=()
if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    die "neither 'docker compose' (plugin) nor 'docker-compose' found"
fi
info "compose backend: ${COMPOSE[*]}"

if command -v ss >/dev/null 2>&1; then
    if ss -lntup 2>/dev/null | grep -Eq '[:.]53[[:space:]]'; then
        info "note: something already listens on port 53; if it is not this pair, the deploy will fail at container start"
    fi
fi

# --- .env handling (fail closed, mirror containers/pihole/README.md) -------
if [[ ! -f $ENV_FILE ]]; then
    die ".env not found at $ENV_FILE — create it first: cp $ENV_EXAMPLE $ENV_FILE && chmod 600 $ENV_FILE, then fill in PIHOLE_TAG, UNBOUND_TAG and PIHOLE_API_PASSWORD"
fi
ENV_PERMS=$(stat -c '%a' "$ENV_FILE")
if [[ $ENV_PERMS != 600 ]]; then
    info ".env permissions are $ENV_PERMS; tightening to 600"
    chmod 600 "$ENV_FILE"
fi

env_value() {
    # Print the value of KEY from the .env file (last assignment wins,
    # surrounding single/double quotes stripped). The file is parsed,
    # never sourced, so a hostile or broken line cannot execute.
    local key="$1" line value
    line=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n 1 || true)
    [[ -n $line ]] || { printf ''; return 0; }
    value=${line#*=}
    value=${value%$'\r'}
    if [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value:1:-1}
    fi
    printf '%s' "$value"
}

PIHOLE_TAG=$(env_value PIHOLE_TAG)
UNBOUND_TAG=$(env_value UNBOUND_TAG)
PIHOLE_API_PASSWORD=$(env_value PIHOLE_API_PASSWORD)

MISSING=()
[[ -n $PIHOLE_TAG ]] || MISSING+=(PIHOLE_TAG)
[[ -n $UNBOUND_TAG ]] || MISSING+=(UNBOUND_TAG)
[[ -n $PIHOLE_API_PASSWORD ]] || MISSING+=(PIHOLE_API_PASSWORD)
((${#MISSING[@]} == 0)) || die ".env is missing values for: ${MISSING[*]} — refusing to deploy (no defaults on the DNS plane)"
[[ $PIHOLE_TAG != latest ]] || die "PIHOLE_TAG=latest is not allowed — pin an exact tag in .env"
[[ $UNBOUND_TAG != latest ]] || die "UNBOUND_TAG=latest is not allowed — pin an exact tag in .env"
info ".env OK: pihole/pihole:${PIHOLE_TAG}, madnuttah/unbound:${UNBOUND_TAG}, API password set"

# --- Pre-flight: render the compose project and guard the v2 posture ------
RENDERED=$(mktemp)
trap 'rm -f "$RENDERED"' EXIT
if ! "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >"$RENDERED" 2>/dev/null; then
    die "compose config render failed for $COMPOSE_FILE — run '${COMPOSE[*]} -f $COMPOSE_FILE config' to see the error"
fi
info "compose config renders cleanly"

# Extract the rendered unbound service block and refuse to deploy if it
# publishes any host port. This is the v2 exposure fix; a monitoring
# tripwire on neo1 (UnboundExposedToLAN) alerts on the same condition.
UNBOUND_BLOCK=$(awk '
    /^  [A-Za-z0-9_-]+:$/ { inblock = ($0 ~ /^  unbound:$/) }
    inblock { print }
' "$RENDERED")
[[ -n $UNBOUND_BLOCK ]] || die "rendered compose config has no 'unbound' service — unexpected project layout, refusing to deploy"
if printf '%s\n' "$UNBOUND_BLOCK" | grep -Eq '^[[:space:]]+ports:|published:'; then
    die "rendered unbound service publishes a host port — the v2 compose posture forbids this; remove the ports block from the unbound service"
fi
info "unbound publishes no host port (v2 posture intact)"

# --- Deploy ------------------------------------------------------------------
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf 'dry-run: %s\n' "$*"
    else
        info "running: $*"
        "$@"
    fi
}

# --- Stale-network sweep (same-host migration from an older form) ---------
# Older deployments of this pair created a bridge network named
# *_pihole-backup on the same fixed 172.20.0.0/16 subnet this stack
# uses: the legacy form (docker-files-pihole_pihole-backup) and
# pre-rename installs of this form
# (pihole_pihole-backup, the name neo1's test deployment runs today).
# The controller's down verb is stop-only, so a torn-down pair leaves
# its network behind and this stack's network creation dies with
# "Pool overlaps with other one on this address space" (seen live on
# neo1's first install attempt, 2026-11-11). This project's own
# network ends in _pihole and can never match the pattern below.
# Remove any foreign *_pihole-backup network with nothing attached;
# refuse if one still has containers, because downing a running pair
# is the operator's call, not this script's.
OWN_NETWORK=$(grep -oE 'name: [A-Za-z0-9_.-]+_pihole$' "$RENDERED" | head -n 1 | awk '{print $2}' || true)
[[ -n $OWN_NETWORK ]] || die "rendered compose config has no *_pihole network — unexpected project layout, refusing to deploy"
while IFS= read -r NET; do
    if [[ -z $NET || $NET == "$OWN_NETWORK" ]]; then
        continue
    fi
    ENDPOINTS=$(docker network inspect -f '{{range $id, $c := .Containers}}{{$c.Name}} {{end}}' "$NET" 2>/dev/null || true)
    if [[ -n ${ENDPOINTS//[[:space:]]/} ]]; then
        die "network $NET (owned by another compose project) still has containers attached: $ENDPOINTS — down that project first (docker compose down in its directory), then re-run this installer"
    fi
    info "removing stale network $NET left behind by an older deployment (it holds the same fixed subnet as $OWN_NETWORK)"
    run docker network rm "$NET"
done < <(docker network ls --format '{{.Name}}' | grep -E '_pihole-backup$' || true)
info "no stale *_pihole-backup network in the way"

run "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
run "${COMPOSE[@]}" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

if [[ $DRY_RUN -eq 1 ]]; then
    info "dry-run complete: prerequisites, .env, compose render and the Unbound exposure guard all passed; nothing was deployed"
    exit 0
fi

# --- Post-deploy verification -------------------------------------------------
info "waiting for both containers to report healthy"
HEALTHY=0
for _ in $(seq 1 24); do
    P=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' pihole 2>/dev/null || echo missing)
    U=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' unbound 2>/dev/null || echo missing)
    if [[ $P == healthy && $U == healthy ]]; then HEALTHY=1; break; fi
    sleep 5
done
[[ $HEALTHY -eq 1 ]] || die "containers did not become healthy (pihole: ${P:-?}, unbound: ${U:-?}); check '${COMPOSE[*]} -f $COMPOSE_FILE logs'"

info "verifying Unbound is not reachable from the LAN"
PUBLISHED=$(docker port unbound 2>/dev/null || true)
[[ -z $PUBLISHED ]] || die "unbound publishes host ports: $PUBLISHED — this breaks the v2 posture; remove the ports block and redeploy"
PORTS_JSON=$(docker inspect -f '{{json .NetworkSettings.Ports}}' unbound)
[[ $PORTS_JSON == '{}' || $PORTS_JSON == 'null' ]] || die "unbound has non-empty NetworkSettings.Ports: $PORTS_JSON"
info "unbound publishes no host ports"

info "verifying DNS resolution at both layers"
# Pi-hole v6's FTL answers pi.hole itself (127.0.0.1) before the query
# ever reaches Unbound, so pi.hole cannot be verified through Pi-hole;
# the old expectation (172.20.0.2 through Pi-hole) could never pass
# (neo1, 2026-11-11). Ask Unbound directly at its bridge address.
UNBOUND_ANSWER=$(docker exec pihole dig +short @172.20.0.3 -p 5335 pi.hole 2>/dev/null || true)
[[ $UNBOUND_ANSWER == 172.20.0.2 ]] || die "pi.hole did not resolve to exactly 172.20.0.2 from Unbound directly (got: '${UNBOUND_ANSWER:-nothing}')"
# An external name through Pi-hole proves the Pi-hole -> Unbound
# forwarding path end to end; require the resolver's own NOERROR.
EXT_STATUS=$(docker exec pihole dig @127.0.0.1 example.com 2>/dev/null | grep -oE 'status: [A-Z]+' | head -n 1 || true)
[[ $EXT_STATUS == 'status: NOERROR' ]] || die "example.com did not return NOERROR through Pi-hole (got: '${EXT_STATUS:-no answer}'; Pi-hole to Unbound forwarding broken)"
info "pi.hole -> 172.20.0.2 from Unbound directly; example.com NOERROR through Pi-hole (forwarding verified)"

# --- Optional blocklist seeding ------------------------------------------------
if [[ $WITH_BLOCKLISTS -eq 1 ]]; then
    SEED_SCRIPT="${SCRIPT_DIR}/pihole-init-blocklists.sh"
    [[ -f $SEED_SCRIPT ]] || die "--with-blocklists given but seed script not found: $SEED_SCRIPT"
    info "seeding blocklists inside pihole (idempotent)"
    docker exec -i pihole bash -s < "$SEED_SCRIPT"
else
    info "blocklists not seeded; run pihole-init-blocklists.sh inside the container once, as containers/pihole/README.md describes"
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP=${IP:-<server-ip>}
printf '\nPi-hole + Unbound is up.\n'
printf '  DNS:        %s port 53 (Pi-hole, upstream Unbound 172.20.0.3:5335, bridge-only)\n' "$IP"
printf '  Admin:      http://%s/admin\n' "$IP"
printf '  Full check: run the DNS test suite in scripts/pihole/ on this host.\n'
