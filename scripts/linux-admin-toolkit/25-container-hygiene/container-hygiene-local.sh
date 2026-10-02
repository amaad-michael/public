#!/usr/bin/env bash
#
# container-hygiene-local.sh — report on (and optionally prune) container
# runtime clutter: stopped containers, dangling images, unused networks,
# build cache.
#
# Runtime detection: prefers docker when its daemon is reachable, falls back
# to podman, and fails cleanly with install hints when neither exists.
#
# Safety: the default mode (no flags) is REPORT ONLY — nothing is deleted.
# Real pruning requires an explicit --yes (or --force). --check is a dry-run
# that reports reclaimable space without deleting anything.
#
# Usage:
#   container-hygiene-local.sh [--check] [--yes|--force]

set -euo pipefail

PROG="$(basename "$0")"
MODE="report" # report | check | prune

usage() {
  cat <<EOF
Usage: $PROG [--check] [--yes|--force] [--help]

  (no flags)   Report only: show disk usage, reclaimable space, and counts of
               stopped containers, dangling images, unused networks, and
               build cache. Deletes nothing.
  --check      Dry-run: same report plus an estimate of what pruning would
               reclaim. Deletes nothing.
  --yes        Actually prune: stopped containers, dangling images, unused
  --force      networks, and build cache. (Synonym of --yes.)
  --help       Show this help and exit.

Examples:
  $PROG            # report only
  $PROG --check    # dry-run with reclaimable-space estimate
  $PROG --yes      # prune for real

Runtime: docker (if its daemon is reachable), else podman.
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      MODE="check"; shift ;;
    --yes|--force) MODE="prune"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# --- distro detection (for install hints) -----------------------------------
FAMILY="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*)
      FAMILY="rhel" ;;
    *" debian "*|*" ubuntu "*)
      FAMILY="debian" ;;
  esac
fi

install_hints() {
  case "$FAMILY" in
    rhel)
      log "Install a runtime with one of:"
      log "  sudo dnf install -y podman"
      log "  # or Docker: https://docs.docker.com/engine/install/ (dnf repo)"
      ;;
    debian)
      log "Install a runtime with one of:"
      log "  sudo apt-get update && sudo apt-get install -y docker.io"
      log "  sudo apt-get update && sudo apt-get install -y podman"
      ;;
    *)
      die "no container runtime found and distro not recognized (need docker or podman)"
      ;;
  esac
}

# --- runtime detection: docker first, then podman ---------------------------
RUNTIME=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  RUNTIME="docker"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  RUNTIME="podman"
else
  log "$PROG: no reachable container runtime (tried docker, then podman)."
  install_hints
  exit 1
fi
log "runtime: $RUNTIME"

count_lines() { printf '%s' "$1" | grep -c . || true; }

# --- report -----------------------------------------------------------------
report() {
  log "--- $RUNTIME system df ---"
  "$RUNTIME" system df
  log "--- prune candidates ---"
  stopped="$("$RUNTIME" ps -a --filter status=exited -q 2>/dev/null || true)"
  dangling="$("$RUNTIME" images --filter dangling=true -q 2>/dev/null || true)"
  log "stopped containers : $(count_lines "$stopped")"
  log "dangling images    : $(count_lines "$dangling")"
  log "unused networks    : (see 'system df' RECLAIMABLE column / dry-run below)"
  log "build cache        : (see 'system df' BUILD CACHE row)"
}

# --- dry-run: reclaimable-space estimate ------------------------------------
dry_run() {
  report
  log "--- dry-run: what pruning would remove ---"
  if [ "$RUNTIME" = "docker" ]; then
    docker system prune --dry-run 2>/dev/null || \
      log "(this docker version has no 'system prune --dry-run'; use the RECLAIMABLE column above)"
  else
    podman system prune --dry-run 2>/dev/null || \
      log "(this podman version has no 'system prune --dry-run'; use the RECLAIMABLE column above)"
  fi
  log "DRY-RUN: nothing was deleted."
}

# --- prune (requires --yes/--force) ------------------------------------------
prune() {
  log "--- disk usage BEFORE ---"
  "$RUNTIME" system df
  log "--- pruning ---"
  if [ "$RUNTIME" = "docker" ]; then
    docker container prune -f
    docker image prune -f        # dangling images only (no -a)
    docker network prune -f      # unused networks only
    docker builder prune -f      # build cache
  else
    podman container prune -f
    podman image prune -f        # dangling images only (no -a)
    podman network prune -f      # unused networks only
    podman builder prune -f      # build cache
  fi
  log "--- disk usage AFTER ---"
  "$RUNTIME" system df
  log "prune complete."
}

case "$MODE" in
  report)
    report
    log "Report only: nothing was deleted. Re-run with --yes to prune."
    ;;
  check)
    dry_run
    ;;
  prune)
    prune
    ;;
esac
