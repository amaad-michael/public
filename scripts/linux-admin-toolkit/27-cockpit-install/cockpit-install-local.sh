#!/usr/bin/env bash
# Install Cockpit, enable/start cockpit.socket, and open 9090/tcp in the
# active firewall. Idempotent.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cockpit-install-local.sh [--check] [--help]

  Install the cockpit package, enable and start cockpit.socket via systemd,
  and open TCP port 9090 in the active firewall. Idempotent: re-running
  changes nothing once everything is in place.

Options:
  --check     Dry-run: print what would be done; change nothing.
  --help      Show this help.

Behavior:
  * Package manager: dnf (yum fallback) on RHEL-family, apt-get on
    Debian-family.
  * If systemd is not PID 1, the package is still installed but the socket
    is not enabled; the script prints the manual step instead of failing
    silently.
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

cockpit_installed() {
  case "$DISTRO" in
    redhat) rpm -q cockpit >/dev/null 2>&1 ;;
    debian) dpkg -s cockpit >/dev/null 2>&1 ;;
  esac
}

systemd_running() { [[ -d /run/systemd/system ]]; }

# --- package ---------------------------------------------------------------
install_package() {
  if cockpit_installed; then
    log "cockpit package already installed"
    return 0
  fi
  case "$DISTRO" in
    redhat)
      local mgr=dnf
      command -v dnf >/dev/null 2>&1 || mgr=yum
      if [[ "$CHECK" -eq 1 ]]; then
        log "[check] would run: $mgr -y install cockpit"
      else
        log "installing cockpit via $mgr"
        "$mgr" -y install cockpit
      fi
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      if [[ "$CHECK" -eq 1 ]]; then
        log "[check] would run: apt-get -y install cockpit"
      else
        log "installing cockpit via apt-get"
        apt_refresh
        apt-get -y install cockpit
      fi
      ;;
  esac
}

# --- socket ----------------------------------------------------------------
enable_socket() {
  if ! systemd_running; then
    log "systemd is not PID 1 on this host, so cockpit.socket cannot be enabled here."
    log "manual step: on a systemd host run: systemctl enable --now cockpit.socket"
    return 0
  fi
  if cockpit_installed && systemctl is-active --quiet cockpit.socket 2>/dev/null; then
    log "cockpit.socket already active"
    if ! systemctl is-enabled --quiet cockpit.socket 2>/dev/null; then
      if [[ "$CHECK" -eq 1 ]]; then
        log "[check] would run: systemctl enable cockpit.socket"
      else
        systemctl enable --quiet cockpit.socket
        log "cockpit.socket enabled"
      fi
    else
      log "cockpit.socket already enabled"
    fi
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    if cockpit_installed; then
      log "[check] would run: systemctl enable --now cockpit.socket"
    else
      log "[check] would run (after install): systemctl enable --now cockpit.socket"
    fi
  else
    log "enabling and starting cockpit.socket"
    systemctl enable --now cockpit.socket
  fi
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
  if systemd_running && cockpit_installed; then
    if systemctl is-active --quiet cockpit.socket 2>/dev/null; then
      log "verified: cockpit.socket is active"
    else
      warn "cockpit.socket is not active after enable --now"
    fi
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

install_package
enable_socket
open_firewall
verify
log "done"
