#!/usr/bin/env bash
#
# health-smart collector entrypoint. Runs the repo's two health
# scripts (bind-mounted read-only at /opt/repo-scripts by the compose
# file) and leaves their reports in /reports:
#
#   /reports/smart-data/<host>.json   (smart-harvest.sh)
#   /reports/health-check.txt         (health-check-local.sh)
#
# Fails loudly if the script mounts are absent: a collector that
# silently skips its scripts would look exactly like a healthy run.
#
set -euo pipefail

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

SMART_SCRIPT=/opt/repo-scripts/smart-harvest.sh
HEALTH_SCRIPT=/opt/repo-scripts/health-check-local.sh

[[ -f "$SMART_SCRIPT" ]] \
    || die "$SMART_SCRIPT not mounted — run from a repo checkout via the shipped docker-compose.yml (it bind-mounts the repo scripts read-only)"
[[ -f "$HEALTH_SCRIPT" ]] \
    || die "$HEALTH_SCRIPT not mounted — run from a repo checkout via the shipped docker-compose.yml (it bind-mounts the repo scripts read-only)"
command -v smartctl >/dev/null 2>&1 || die "smartctl missing from the image (smartmontools not installed)"
command -v python3 >/dev/null 2>&1 || die "python3 missing from the image"

mkdir -p /reports/smart-data

info "running SMART harvest (drives: ${*:-auto-discovered})"
bash "$SMART_SCRIPT" --output-dir /reports/smart-data "$@"

info "running toolkit health check"
bash "$HEALTH_SCRIPT" | tee /reports/health-check.txt

info "collection complete — reports in /reports"
