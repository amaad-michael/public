#!/usr/bin/env bash
# Apply OS package updates: full (default) or security-only.
# Supports RHEL-family (dnf, yum fallback) and Debian-family (apt-get).
# Never reboots automatically; reports at the end if a reboot is needed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: system-update-local.sh [--security-only] [--check] [--no-refresh] [--help]

  Apply pending OS package updates. Idempotent: a second run is a no-op
  once everything is up to date.

Options:
  --security-only   RedHat: 'dnf update --security' / 'yum update --security'.
                    Debian: upgrade only packages whose candidate version is
                    served by a *-security repository (see NOTES below).
  --check           Dry-run: list what would change; change nothing.
  --no-refresh      Debian: skip 'apt-get update'; install from the cached
                    package lists (may fail if the cache is stale).
  --help            Show this help.

Examples:
  system-update-local.sh --check
  system-update-local.sh --security-only

NOTES (Debian security-only): apt-get has no equivalent of
"dnf update --security". This script upgrades only packages whose candidate
version comes from a repository whose URI contains "security"
(e.g. noble-security). Limitation: this is a heuristic — it depends on your
sources naming the security archive that way, and pulling a security
package can still drag in non-security dependencies. For production hosts,
prefer unattended-upgrades with its Origins-Pattern restricted to
security origins.

A reboot is never performed automatically. If one is required afterwards
(/var/run/reboot-required on Debian; 'needs-restarting -r' on RedHat),
the script says so at the end.
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

SECURITY_ONLY=0
CHECK=0
NO_REFRESH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --security-only) SECURITY_ONLY=1; shift ;;
    --check)         CHECK=1; shift ;;
    --no-refresh)    NO_REFRESH=1; shift ;;
    --help)          usage; exit 0 ;;
    --*)             warn "unknown option: $1"; usage; exit 2 ;;
    *)               warn "unexpected argument: $1"; usage; exit 2 ;;
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

# --- reboot-needed reporting ------------------------------------------------
reboot_needed_redhat() {
  # Returns 0 (and prints reason) if a reboot is required.
  if command -v needs-restarting >/dev/null 2>&1; then
    if ! needs-restarting -r >/dev/null 2>&1; then
      log "reboot required: needs-restarting reports core libraries or the kernel were updated"
      return 0
    fi
    return 1
  fi
  # Fallback: compare running kernel to newest installed kernel package.
  local running newest
  running="$(uname -r | sed 's/\.[^.]*$//')"   # strip .x86_64 / .aarch64 suffix
  newest="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}\n' kernel 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -n "$newest" && "$running" != "$newest" ]]; then
    log "reboot required: running kernel $running differs from newest installed $newest"
    return 0
  fi
  return 1
}

reboot_needed_debian() {
  if [[ -f /var/run/reboot-required ]]; then
    log "reboot required: /var/run/reboot-required exists"
    return 0
  fi
  # Fallback: compare running kernel to newest installed linux-image.
  local running newest
  running="$(uname -r)"
  newest="$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
            | sed 's/^linux-image-//' | sort -V | tail -n 1 || true)"
  if [[ -n "$newest" && "$running" != "$newest" ]]; then
    log "reboot required: running kernel $running differs from newest installed $newest"
    return 0
  fi
  return 1
}

# --- RedHat -----------------------------------------------------------------
redhat_pkgmgr() {
  if command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  else warn "neither dnf nor yum found"; exit 2; fi
}

run_redhat() {
  local mgr sec_flag rc
  mgr="$(redhat_pkgmgr)"
  sec_flag=()
  [[ "$SECURITY_ONLY" -eq 1 ]] && sec_flag=(--security)

  if [[ "$CHECK" -eq 1 ]]; then
    log "dry-run: pending updates ($mgr check-update${sec_flag[*]:+ ${sec_flag[*]}})"
    local cmd=("$mgr" check-update)
    ((${#sec_flag[@]})) && cmd+=("${sec_flag[@]}")
    rc=0
    "${cmd[@]}" || rc=$?
    # dnf/yum exit 100 when updates are available; that is not an error here.
    if [[ "$rc" -ne 0 && "$rc" -ne 100 ]]; then
      warn "$mgr check-update failed with exit code $rc"
      exit 1
    fi
    [[ "$rc" -eq 0 ]] && log "no updates pending"
    return 0
  fi

  log "applying updates: $mgr -y update${sec_flag[*]:+ ${sec_flag[*]}}"
  local cmd=("$mgr" -y update)
  ((${#sec_flag[@]})) && cmd+=("${sec_flag[@]}")
  "${cmd[@]}"
  log "update complete"
}

# --- Debian -----------------------------------------------------------------
# Print (one per line) the upgradable packages whose candidate version is
# served by a repository whose URI contains "security".
debian_security_pkgs() {
  local pkg cand
  apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 {print $1}' | while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/^ *Candidate:/ {print $2}')"
    [[ -n "$cand" && "$cand" != "(none)" ]] || continue
    if apt-cache policy "$pkg" 2>/dev/null | awk -v cand="$cand" '
        /^[[:space:]]*\*\*\* /      { ver=$2; inblock=1; next }
        /^[[:space:]]+[0-9][^ ]*[[:space:]]+[0-9]+$/ { ver=$1; inblock=1; next }
        inblock && /^[[:space:]]+[0-9]+ http/ {
          if (ver == cand && $2 ~ /security/) { found=1 }
          inblock=0
        }
        END { exit found ? 0 : 1 }'; then
      printf '%s\n' "$pkg"
    fi
  done
}

run_debian() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$NO_REFRESH" -eq 1 ]]; then
    log "skipping package-list refresh (--no-refresh); using cached lists"
  else
    log "refreshing package lists (apt-get update; installs nothing)"
    apt_refresh
  fi

  local pkgs=()
  if [[ "$SECURITY_ONLY" -eq 1 ]]; then
    log "selecting upgradable packages served by *-security repositories (heuristic)"
    mapfile -t pkgs < <(debian_security_pkgs)
    if [[ "${#pkgs[@]}" -eq 0 ]]; then
      log "no security updates pending"
      return 0
    fi
    log "security updates pending for ${#pkgs[@]} package(s): ${pkgs[*]}"
  fi

  if [[ "$CHECK" -eq 1 ]]; then
    if [[ "$SECURITY_ONLY" -eq 1 ]]; then
      log "dry-run: apt-get -s -y install --only-upgrade ${pkgs[*]}"
      apt-get -s -y install --only-upgrade "${pkgs[@]}"
    else
      log "dry-run: apt-get -s -y dist-upgrade"
      apt-get -s -y dist-upgrade
    fi
    return 0
  fi

  if [[ "$SECURITY_ONLY" -eq 1 ]]; then
    log "applying security updates: apt-get -y install --only-upgrade ${pkgs[*]}"
    apt-get -y install --only-upgrade "${pkgs[@]}"
  else
    log "applying full update: apt-get -y dist-upgrade"
    apt-get -y dist-upgrade
  fi
  log "update complete"
}

# --- main -------------------------------------------------------------------
case "$DISTRO" in
  redhat) run_redhat ;;
  debian) run_debian ;;
esac

log ""
if [[ "$DISTRO" == redhat ]]; then
  reboot_needed_redhat || log "no reboot required"
else
  reboot_needed_debian || log "no reboot required"
fi
