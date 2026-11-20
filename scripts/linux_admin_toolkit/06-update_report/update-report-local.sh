#!/usr/bin/env bash
# READ-ONLY: list pending OS updates and report whether a reboot is required.
# Supports RHEL-family (dnf check-update) and Debian-family (apt-get update
# to refresh the cache, then apt list --upgradable). Installs nothing.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: update-report-local.sh [--no-refresh] [--help]

  Read-only report: pending package updates plus reboot-required status.

  RedHat: 'dnf check-update' (yum fallback).
  Debian: runs 'apt-get update' to refresh the package cache (this changes
          no installed packages), then 'apt list --upgradable'.

Options:
  --no-refresh  Debian: skip 'apt-get update'; report from the cached
                package lists instead.
  --help        Show this help.

  Reboot detection:
    Debian: /var/run/reboot-required, plus running kernel vs newest
            installed linux-image-*.
    RedHat: 'needs-restarting -r' when available, else running kernel vs
            newest installed kernel package.

  Exits 0 on success. Changes nothing on the system.
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

NO_REFRESH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-refresh) NO_REFRESH=1; shift ;;
    --help) usage; exit 0 ;;
    --*)    warn "unknown option: $1"; usage; exit 2 ;;
    *)      warn "unexpected argument: $1"; usage; exit 2 ;;
  esac
done

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
      *rhel*|*fedora*|*centos*|*redhat*|*rocky*|*alma*|*ol*) echo redhat ;;
      *debian*|*ubuntu*) echo debian ;;
      *)
        warn "unsupported distro (ID='${ID:-}' ID_LIKE='${ID_LIKE:-}'); only RHEL-family and Debian-family are supported"
        exit 2 ;;
    esac
  else
    warn "/etc/os-release is not readable; cannot detect distro"
    exit 2
  fi
}

DISTRO="$(detect_distro)"

# apt-get update with a hard timeout: a stalled mirror must not hang the
# script forever. On failure/timeout, warns and returns 0 — the caller
# proceeds with whatever package lists are already cached.
apt_refresh() {
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 apt-get update -qq || rc=$?
  else
    apt-get update -qq || rc=$?
  fi
  if [[ $rc -eq 124 ]]; then
    warn "apt-get update timed out after 120s (stalled mirror?) — continuing with cached package lists"
  elif [[ $rc -ne 0 ]]; then
    warn "apt-get update failed (rc=$rc) — continuing with cached package lists"
  fi
  return 0
}

report_redhat() {
  local mgr rc count out
  if command -v dnf >/dev/null 2>&1; then mgr=dnf
  elif command -v yum >/dev/null 2>&1; then mgr=yum
  else warn "neither dnf nor yum found"; exit 2; fi

  log "== pending updates ($mgr check-update) =="
  rc=0
  out="$("$mgr" check-update 2>&1)" || rc=$?
  # dnf/yum exit 100 when updates are available; that is not an error here.
  if [[ "$rc" -ne 0 && "$rc" -ne 100 ]]; then
    warn "$mgr check-update failed (exit $rc)"
    exit 1
  fi
  # Update lines look like: "kernel.x86_64  5.14.0-427.el9  baseos"
  count="$(printf '%s\n' "$out" | grep -cE '^[[:alnum:][:punct:]]+[[:space:]]+[[:alnum:][:punct:].~-]+[[:space:]]' || true)"
  if [[ "$count" -eq 0 ]]; then
    log "no updates pending"
  else
    log "$count package update(s) pending:"
    printf '%s\n' "$out" | grep -E '^[[:alnum:][:punct:]]+[[:space:]]+[[:alnum:][:punct:].~-]+[[:space:]]' || true
  fi

  log ""
  log "== reboot required? =="
  if command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      log "no (needs-restarting -r: core libraries/kernel unchanged)"
    else
      log "YES (needs-restarting -r reports a reboot is required)"
    fi
  else
    local running newest
    running="$(uname -r | sed 's/\.[^.]*$//')"
    newest="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}\n' kernel 2>/dev/null | grep -v 'is not installed' | sort -V | tail -n 1 || true)"
    log "needs-restarting not available; kernel comparison:"
    log "  running kernel:          $running"
    log "  newest installed kernel: ${newest:-unknown}"
    if [[ -n "$newest" && "$running" != "$newest" ]]; then
      log "YES (running kernel differs from newest installed)"
    else
      log "no"
    fi
  fi
}

report_debian() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$NO_REFRESH" -eq 1 ]]; then
    log "skipping package-list refresh (--no-refresh); using cached lists..."
  else
    log "refreshing package lists (apt-get update; installs nothing)..."
    apt_refresh
  fi

  log ""
  log "== pending updates (apt list --upgradable) =="
  local out count
  out="$(apt list --upgradable 2>/dev/null | tail -n +2 || true)"
  if [[ -z "$out" ]]; then
    log "no updates pending"
    count=0
  else
    count="$(printf '%s\n' "$out" | wc -l)"
    log "$count package update(s) pending:"
    printf '%s\n' "$out"
  fi

  # Fast security count via update-notifier when present.
  if [[ -x /usr/lib/update-notifier/apt-check ]]; then
    local sec
    sec="$(/usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f2 || true)"
    log ""
    log "security updates among them: ${sec:-unknown}"
  fi

  log ""
  log "== reboot required? =="
  if [[ -f /var/run/reboot-required ]]; then
    log "YES (/var/run/reboot-required exists)"
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      log "packages requesting the reboot:"
      sed 's/^/  /' /var/run/reboot-required.pkgs
    fi
  else
    log "no (/var/run/reboot-required absent)"
  fi
  local running newest
  running="$(uname -r)"
  newest="$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
            | sed 's/^linux-image-//' | sort -V | tail -n 1 || true)"
  log "kernel check: running=$running newest-installed=${newest:-unknown}"
  if [[ -n "$newest" && "$running" != "$newest" ]]; then
    log "note: a newer kernel ($newest) is installed than the running one ($running); reboot to use it"
  fi
}

log "update report for $(hostname) ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
log ""
case "$DISTRO" in
  redhat) report_redhat ;;
  debian) report_debian ;;
esac
