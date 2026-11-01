#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Generic Compose Stack Teardown — v1.0
# ═══════════════════════════════════════════════════════════════════════════
# One teardown for every docker-compose stack in containers/ (and any
# other directory holding a compose file). Replaces per-stack removal
# knowledge with the stack's own rendered configuration: services,
# named volumes, and bind mounts are read from `docker compose config`,
# never from a hand-maintained list.
#
# Behavior:
#   - Default: compose down (containers and the project network).
#   - --purge: also removes the project's named volumes and the
#     images it built locally (compose down --volumes --rmi local).
#   - Host bind-mount paths are DATA ON THE HOST. By default they
#     are listed in the plan as PRESERVED and never deleted. The one
#     exception is the optional final step: --wipe-host-data adds a
#     separately confirmed step at the very end that removes them
#     (see below). Without that flag they are never touched.
#   - --dry-run prints the full plan and changes nothing.
#   - A real run requires typing the stack's name to confirm.
#
# READ THIS BEFORE A REAL RUN
#   - Run with --dry-run first and read the plan. Every service,
#     volume, and host path the run touches is labeled in it.
#   - The plan is rendered from the stack's own compose file, so it
#     always matches what is actually defined, never a stale list.
#   - Named volumes hold the stack's data (databases, uploads,
#     configs the stack wrote). They survive a default run;
#     --purge deletes them. There is no undo for --purge.
#   - Redeploying afterwards is one command in the stack's
#     directory (docker compose up -d); the closing summary prints
#     the exact command for the stack you tore down.
#   - --wipe-host-data is a second, separate decision made at the
#     end of the run: after the teardown verifies clean, the script
#     lists the host bind paths again and asks you to type "wipe"
#     before deleting any of them. Declining costs nothing; the
#     teardown result stands either way.
#   - Every action is logged to /var/log/stack-teardown-<stack>.log
#
# Usage:
#   sudo ./stack-teardown-v1.0.sh <stack-name-or-dir> [--dry-run] [--purge] [--wipe-host-data]
#
# <stack-name-or-dir> is either a directory containing
# docker-compose.yml / compose.yml, or a name resolved against
# $STACKS_ROOT (default: the repo's containers/ directory, relative to
# this script) — e.g. `stack-teardown-v1.0.sh monitoring --dry-run`.
#
# Exit codes: 0 clean (including nothing-to-do), 1 aborted or a
# removal failed verification, 2 usage or environment error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

DRY_RUN="no"
PURGE="no"
WIPE_HOST_DATA="no"
STACK_ARG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="yes" ;;
        --purge)   PURGE="yes" ;;
        --wipe-host-data) WIPE_HOST_DATA="yes" ;;
        --help|-h)
            echo "Usage: sudo $0 <stack-name-or-dir> [--dry-run] [--purge] [--wipe-host-data]"
            exit 0
            ;;
        -*)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
        *)
            if [[ -n "$STACK_ARG" ]]; then
                echo "Only one stack may be given." >&2
                exit 2
            fi
            STACK_ARG="$arg"
            ;;
    esac
done

if [[ -z "$STACK_ARG" ]]; then
    echo "Usage: sudo $0 <stack-name-or-dir> [--dry-run] [--purge] [--wipe-host-data]" >&2
    exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root (sudo)." >&2
    exit 2
fi

if ! command -v docker &>/dev/null; then
    echo "docker is not installed on this host: nothing to tear down." >&2
    exit 2
fi
if ! docker compose version &>/dev/null; then
    echo "The docker compose v2 plugin is not available." >&2
    exit 2
fi
if ! command -v python3 &>/dev/null; then
    echo "python3 is required to read the rendered compose config." >&2
    exit 2
fi

# ───────────────────────────────────────────────────────────────────────────
# Resolve the stack directory and its compose file
# ───────────────────────────────────────────────────────────────────────────

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STACKS_ROOT="${STACKS_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)/containers}"

STACK_DIR=""
if [[ -d "$STACK_ARG" ]]; then
    STACK_DIR=$(cd -- "$STACK_ARG" && pwd)
elif [[ -d "$STACKS_ROOT/$STACK_ARG" ]]; then
    STACK_DIR=$(cd -- "$STACKS_ROOT/$STACK_ARG" && pwd)
fi

COMPOSE_FILE=""
if [[ -n "$STACK_DIR" ]]; then
    for cand in "$STACK_DIR/docker-compose.yml" "$STACK_DIR/docker-compose.yaml" \
                "$STACK_DIR/compose.yml" "$STACK_DIR/compose.yaml"; do
        if [[ -f "$cand" ]]; then
            COMPOSE_FILE="$cand"
            break
        fi
    done
fi

if [[ -z "$COMPOSE_FILE" ]]; then
    echo "No compose file found for '$STACK_ARG'." >&2
    echo "Looked in the directory itself and under $STACKS_ROOT." >&2
    echo "Nested stacks resolve by relative name too, e.g. pihole/legacy." >&2
    exit 2
fi

STACK_NAME=$(basename -- "$STACK_DIR")
LOG_FILE="/var/log/stack-teardown-${STACK_NAME}.log"
FAILURES=0

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

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

# ───────────────────────────────────────────────────────────────────────────
# Render the stack's own config: services, named volumes, bind mounts
# ───────────────────────────────────────────────────────────────────────────

CONFIG_JSON=$(docker compose -f "$COMPOSE_FILE" config --format json 2>&1) || {
    echo "docker compose config failed for $COMPOSE_FILE:" >&2
    printf '%s\n' "$CONFIG_JSON" >&2
    echo "A deployed stack renders cleanly: the usual cause is a missing" >&2
    echo ".env file (or unset required variables) in the stack directory." >&2
    echo "Compose reads .env from the compose file's directory; create it" >&2
    echo "from the stack's .env.example if the stack ships one, then rerun." >&2
    exit 2
}
# A successful render is the JSON document on stdout; compose warnings
# ride stderr, which the capture above merged. Re-render cleanly.
CONFIG_JSON=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null)

PLAN=$(printf '%s' "$CONFIG_JSON" | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
services = sorted((cfg.get("services") or {}).keys())
volumes = sorted((cfg.get("volumes") or {}).keys())
binds = set()
for svc in (cfg.get("services") or {}).values():
    for vol in svc.get("volumes") or []:
        if vol.get("type") == "bind":
            binds.add(vol.get("source", ""))
print("SERVICES:" + ",".join(services))
print("VOLUMES:" + ",".join(volumes))
for b in sorted(binds):
    print("BIND:" + b)
') || {
    echo "Could not parse the rendered compose config." >&2
    exit 2
}

SERVICES_LINE=$(printf '%s\n' "$PLAN" | grep '^SERVICES:' | cut -d: -f2-)
VOLUMES_LINE=$(printf '%s\n' "$PLAN" | grep '^VOLUMES:' | cut -d: -f2-)

log "════════════════════════════════════════════════════════════════"
log "Compose stack teardown v1.0: $STACK_NAME (dry-run=$DRY_RUN purge=$PURGE wipe-host-data=$WIPE_HOST_DATA)"
log "Stack directory: $STACK_DIR"
log "Services: ${SERVICES_LINE:-none}"
log "Named volumes: ${VOLUMES_LINE:-none}"
log "Step 1 of 2: docker compose down (stop and remove the containers"
log "and the project network)."
log "Step 2 of 2: verify no container from this stack remains."
if [[ "$PURGE" == "yes" ]]; then
    log "PURGE: named volumes and locally built images are removed too."
else
    log "Named volumes are preserved (rerun with --purge to remove them)."
fi
BIND_PATHS=()
while IFS= read -r line; do
    case "$line" in
        BIND:*)
            BIND_PATHS+=("${line#BIND:}")
            if [[ "$WIPE_HOST_DATA" == "yes" ]]; then
                log "HOST DATA (removed in the final wipe step, separately confirmed): ${line#BIND:}"
            else
                log "PRESERVED host bind (never deleted by this script): ${line#BIND:}"
            fi
            ;;
    esac
done <<< "$PLAN"
if [[ "$WIPE_HOST_DATA" != "yes" && "${#BIND_PATHS[@]}" -gt 0 ]]; then
    log "Optional: host bind data can be removed as a final step with --wipe-host-data."
fi
if [[ "$WIPE_HOST_DATA" == "yes" ]]; then
    log "Final step (optional): after the teardown verifies clean, you will"
    log "be asked to type wipe to delete the host bind paths listed above."
fi

if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Type $STACK_NAME to confirm this teardown:"
    CONFIRM=""
    if ( exec 9</dev/tty ) 2>/dev/null; then
        read -r CONFIRM < /dev/tty || CONFIRM=""
    else
        read -r CONFIRM || CONFIRM=""
    fi
    if [[ "$CONFIRM" != "$STACK_NAME" ]]; then
        log "Aborted: confirmation not given. Nothing was removed."
        exit 1
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Teardown + verification
# ───────────────────────────────────────────────────────────────────────────

DOWN_ARGS=(compose -f "$COMPOSE_FILE" down)
if [[ "$PURGE" == "yes" ]]; then
    DOWN_ARGS+=(--volumes --rmi local)
fi
run "docker ${DOWN_ARGS[*]}" docker "${DOWN_ARGS[@]}"

if [[ "$DRY_RUN" == "yes" ]]; then
    log "Dry run complete. Nothing was changed."
    log "To perform this teardown: rerun without --dry-run."
    exit 0
fi

STILL=0
REMAINING=$(docker compose -f "$COMPOSE_FILE" ps -a --format '{{.Name}}' 2>/dev/null || true)
if [[ -n "$REMAINING" ]]; then
    log "STILL PRESENT containers: $REMAINING"
    STILL=$((STILL + 1))
fi
if [[ "$PURGE" == "yes" && -n "$VOLUMES_LINE" ]]; then
    PROJECT=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)
    IFS=',' read -ra VOLS <<< "$VOLUMES_LINE"
    for v in "${VOLS[@]}"; do
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "${PROJECT}_${v}" || \
           docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$v"; then
            log "STILL PRESENT volume: $v"
            STILL=$((STILL + 1))
        fi
    done
fi

# ───────────────────────────────────────────────────────────────────────────
# Optional final step: wipe the host bind-mount data (--wipe-host-data)
# Runs only when the teardown itself verified clean. Declining the
# second confirmation leaves the data in place and is not a failure.
# ───────────────────────────────────────────────────────────────────────────

WIPED=0
WIPE_FAIL=0
if [[ "$WIPE_HOST_DATA" == "yes" ]]; then
    if [[ "$FAILURES" -gt 0 || "$STILL" -gt 0 ]]; then
        log "Final wipe step SKIPPED: the teardown did not complete cleanly,"
        log "so host data is left untouched. Fix the teardown first."
    elif [[ "${#BIND_PATHS[@]}" -eq 0 ]]; then
        log "Final wipe step: this stack has no host bind-mount paths; nothing to wipe."
    else
        log "Final step: wipe host bind-mount data"
        for bp in "${BIND_PATHS[@]}"; do
            log "  WIPE      $bp"
        done
        echo "Type wipe to delete these host paths:"
        WCONFIRM=""
        if ( exec 9</dev/tty ) 2>/dev/null; then
            read -r WCONFIRM < /dev/tty || WCONFIRM=""
        else
            read -r WCONFIRM || WCONFIRM=""
        fi
        if [[ "$WCONFIRM" != "wipe" ]]; then
            log "Final wipe step declined: host data left in place."
            log "To remove it later, rerun with --wipe-host-data."
        else
            for bp in "${BIND_PATHS[@]}"; do
                case "$bp" in
                    /|/etc|/var|/usr|/home|/opt|/root|/boot|/srv)
                        log "  REFUSED   $bp (a top-level system directory is never wiped)"
                        WIPE_FAIL=$((WIPE_FAIL + 1))
                        ;;
                    *)
                        if [[ -e "$bp" || -L "$bp" ]]; then
                            if rm -rf -- "$bp" >> "$LOG_FILE" 2>&1; then
                                log "  WIPED     $bp"
                                WIPED=$((WIPED + 1))
                            else
                                log "  !! FAILED to wipe $bp"
                                WIPE_FAIL=$((WIPE_FAIL + 1))
                            fi
                        else
                            log "  skip      $bp (already absent)"
                        fi
                        ;;
                esac
            done
        fi
    fi
fi

log "════════════════════════════════════════════════════════════════"
if [[ "$FAILURES" -gt 0 || "$STILL" -gt 0 || "$WIPE_FAIL" -gt 0 ]]; then
    log "Teardown finished WITH PROBLEMS: $FAILURES failed actions, $STILL checks still present, $WIPE_FAIL wipe failures."
    exit 1
fi
log "Teardown complete for $STACK_NAME."
if [[ "$PURGE" != "yes" && -n "$VOLUMES_LINE" ]]; then
    log "Kept for a redeploy: the named volumes listed in the plan."
    log "To remove those too, rerun with --purge."
fi
if [[ "$WIPED" -gt 0 ]]; then
    log "Host bind data wiped in the final step: $WIPED path(s)."
fi
log "To redeploy: cd $STACK_DIR && docker compose up -d"
log "Full log: $LOG_FILE"
exit 0
