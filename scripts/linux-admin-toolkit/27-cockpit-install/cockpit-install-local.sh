#!/usr/bin/env bash
# Install Cockpit, enable/start cockpit.socket, and open 9090/tcp in
# the active firewall. Idempotent.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cockpit-install-local.sh [--check] [--help]

  Install the cockpit package, enable and start cockpit.socket via
  systemd, and open TCP port 9090 in the active firewall. Idempotent:
  re-running changes nothing once everything is in place.

  PCP is deliberately not installed (decision 2026-10-22): historical
  metrics for the fleet live in the Prometheus/Grafana stack, so the
  console runs live-only and hosts carry no archiving daemons
  writing to their SD cards.

Options:
  --check     Dry-run: print what would be done; change nothing.
  --help      Show this help.

Behavior:
  * Package manager: dnf (yum fallback) on RHEL-family, apt-get on
    Debian-family.
  * If systemd is not PID 1, the packages are still installed but the
    units are not enabled; the script prints the manual step instead
    of failing silently.
  * Firewall: firewalld (--permanent --add-port=9090/tcp + reload) if
    firewall-cmd exists, else ufw (ufw allow 9090/tcp) if ufw exists.
    If neither is present, the script prints the rule the admin should
    add (iptables / nftables) instead of guessing.
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

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

CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --help)  usage; exit 0 ;;
    --*)     warn "unknown option: $1"; usage; exit 2 ;;
    *)       warn "unexpected argument: $1"; usage; exit 2 ;;
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
PORT=9090
PACKAGES=(cockpit)
UNITS=(cockpit.socket)

pkg_installed() {
  case "$DISTRO" in
    redhat) rpm -q "$1" >/dev/null 2>&1 ;;
    debian) dpkg -s "$1" >/dev/null 2>&1 ;;
  esac
}

systemd_running() { [[ -d /run/systemd/system ]]; }

# --- packages ---------------------------------------------------------------
install_packages() {
  local missing=() pkg
  for pkg in "${PACKAGES[@]}"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log "packages already installed: ${PACKAGES[*]}"
    return 0
  fi
  case "$DISTRO" in
    redhat)
      local mgr=dnf
      command -v dnf >/dev/null 2>&1 || mgr=yum
      if [[ "$CHECK" -eq 1 ]]; then
        log "[check] would run: $mgr -y install ${missing[*]}"
      else
        log "installing via $mgr: ${missing[*]}"
        "$mgr" -y install "${missing[@]}"
      fi
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      if [[ "$CHECK" -eq 1 ]]; then
        log "[check] would run: apt-get -y install ${missing[*]}"
      else
        log "installing via apt-get: ${missing[*]}"
        apt_refresh
        apt-get -y install "${missing[@]}"
      fi
      ;;
  esac
}

# --- units ------------------------------------------------------------------
enable_units() {
  if ! systemd_running; then
    log "systemd is not PID 1 on this host, so these units cannot be enabled here: ${UNITS[*]}"
    log "manual step: on a systemd host run: systemctl enable --now ${UNITS[*]}"
    return 0
  fi
  local unit
  for unit in "${UNITS[@]}"; do
    if systemctl is-active --quiet "$unit" 2>/dev/null && systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      log "$unit already enabled and active"
      continue
    fi
    if [[ "$CHECK" -eq 1 ]]; then
      log "[check] would run: systemctl enable --now $unit"
    else
      log "enabling and starting $unit"
      systemctl enable --now "$unit"
    fi
  done
}

# --- firewall ---------------------------------------------------------------
firewalld_open() {
  # Returns 0 if firewalld handled the port (or it was already open).
  command -v firewall-cmd >/dev/null 2>&1 || return 1
  if firewall-cmd --query-port="$PORT/tcp" >/dev/null 2>&1; then
    log "firewalld: $PORT/tcp already open"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would run: firewall-cmd --permanent --add-port=$PORT/tcp && firewall-cmd --reload"
  else
    log "opening $PORT/tcp in firewalld"
    firewall-cmd --permanent --add-port="$PORT/tcp"
    firewall-cmd --reload
  fi
  return 0
}

ufw_open() {
  # Returns 0 if ufw handled the port (or it was already allowed).
  command -v ufw >/dev/null 2>&1 || return 1
  if ufw status 2>/dev/null | grep -qE "^$PORT/tcp.*ALLOW"; then
    log "ufw: $PORT/tcp already allowed"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would run: ufw allow $PORT/tcp"
  else
    log "allowing $PORT/tcp in ufw"
    ufw allow "$PORT/tcp"
  fi
  return 0
}

open_firewall() {
  if firewalld_open; then return 0; fi
  if ufw_open; then return 0; fi
  log "no supported firewall tool found (neither firewall-cmd nor ufw)."
  log "manual step: allow inbound TCP port $PORT to this host, e.g.:"
  log "  iptables -A INPUT -p tcp --dport $PORT -j ACCEPT     # iptables"
  log "  nft add rule inet filter input tcp dport $PORT accept  # nftables"
  log "  or the equivalent rule in your cloud security group."
}

# --- verify -----------------------------------------------------------------
verify() {
  [[ "$CHECK" -eq 1 ]] && return 0
  if systemd_running; then
    local unit
    for unit in "${UNITS[@]}"; do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        log "verified: $unit is active"
      else
        warn "$unit is not active after enable --now"
      fi
    done
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
      log "verified: something is listening on TCP $PORT"
    else
      warn "nothing appears to be listening on TCP $PORT yet"
    fi
  fi
  log "cockpit should be reachable at https://<this-host>:$PORT/"
}

install_packages
enable_units
open_firewall
verify
log "done"
