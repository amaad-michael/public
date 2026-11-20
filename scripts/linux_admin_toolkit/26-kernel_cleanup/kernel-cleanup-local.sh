#!/usr/bin/env bash
# Remove old kernels, keeping the N most recent (default 2).
# NEVER removes the running kernel: the script aborts if the running
# kernel would be in the removal set. Idempotent.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: kernel-cleanup-local.sh [--keep N] [--check] [--help]

  Remove old kernel packages, keeping the N most recent (default 2).
  Idempotent: if N or fewer kernels are installed, nothing is removed.

Options:
  --keep N    Number of most-recent kernels to keep (default 2).
  --check     Dry-run: list what would be removed; remove nothing.
  --help      Show this help.

Safety:
  The running kernel (uname -r) is always protected and the script aborts
  if it would ever land in the removal set.

  RedHat: removes old kernel / kernel-core / kernel-modules(-core/-extra)
          packages via dnf (yum fallback).
  Debian: 'apt-get purge' of old linux-image-* packages. Matching
          linux-headers-* / linux-modules-* packages are left in place;
          remove them separately if desired.
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

KEEP=2
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP="${2:?--keep requires a value}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --help) usage; exit 0 ;;
    --*) warn "unknown option: $1"; usage; exit 2 ;;
    *)   warn "unexpected argument: $1"; usage; exit 2 ;;
  esac
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || ! [[ "$KEEP" -ge 1 ]]; then
  warn "--keep must be a positive integer (got '$KEEP')"
  exit 2
fi

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

# --- shared helpers ---------------------------------------------------------
# newest_first: print arguments sorted newest-first by version.
newest_first() { printf '%s\n' "$@" | sort -rV; }

# --- RedHat -----------------------------------------------------------------
cleanup_redhat() {
  local mgr running_vr
  if command -v dnf >/dev/null 2>&1; then mgr=dnf
  elif command -v yum >/dev/null 2>&1; then mgr=yum
  else warn "neither dnf nor yum found"; exit 2; fi

  # Installed kernel versions, newest first (VERSION-RELEASE, no arch).
  mapfile -t versions < <(rpm -q --queryformat '%{VERSION}-%{RELEASE}\n' kernel 2>/dev/null | grep -v 'is not installed' | sort -rV || true)
  [[ "${#versions[@]}" -gt 0 ]] || { log "no kernel packages installed; nothing to do"; return 0; }

  # Running kernel as VERSION-RELEASE (strip trailing .x86_64 / .aarch64).
  running_vr="$(uname -r | sed 's/\.[^.]*$//')"

  # Keep set: newest $KEEP versions, plus the running kernel, always.
  local keep=() remove=() v k r
  mapfile -t keep < <(newest_first "${versions[@]}" | head -n "$KEEP")
  k=" ${keep[*]} "
  [[ "$k" == *" $running_vr "* ]] || keep+=("$running_vr")

  for v in "${versions[@]}"; do
    r=0
    for k in "${keep[@]}"; do [[ "$v" == "$k" ]] && r=1 && break; done
    [[ "$r" -eq 0 ]] && remove+=("$v")
  done

  log "installed kernels (${#versions[@]}): ${versions[*]}"
  log "running kernel: $running_vr (always protected)"
  log "keeping: ${keep[*]}"

  # Hard safety check: the running kernel must never be in the removal set.
  for v in "${remove[@]}"; do
    if [[ "$v" == "$running_vr" ]]; then
      warn "ABORT: running kernel $running_vr is in the removal set; refusing to continue"
      exit 1
    fi
  done

  if [[ "${#remove[@]}" -eq 0 ]]; then
    log "nothing to remove"
    return 0
  fi

  # Expand each old version to the installed kernel sub-packages.
  local pkgs=() p
  for v in "${remove[@]}"; do
    while IFS= read -r p; do pkgs+=("$p"); done < <(
      rpm -q "kernel-$v" "kernel-core-$v" "kernel-modules-$v" \
             "kernel-modules-core-$v" "kernel-modules-extra-$v" 2>/dev/null || true)
  done
  # rpm -q prints "package X is not installed" on stderr (suppressed); keep
  # only lines that name an installed package.
  mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | grep -v 'is not installed' || true)

  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    log "no removable kernel packages found for old versions: ${remove[*]}"
    return 0
  fi

  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would remove: ${pkgs[*]}"
    return 0
  fi
  log "removing: ${pkgs[*]}"
  "$mgr" -y remove "${pkgs[@]}"
  log "kernel cleanup complete"
}

# --- Debian -----------------------------------------------------------------
cleanup_debian() {
  export DEBIAN_FRONTEND=noninteractive
  local running_img
  running_img="linux-image-$(uname -r)"

  mapfile -t imgs < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -rV || true)
  [[ "${#imgs[@]}" -gt 0 ]] || { log "no linux-image-* packages installed; nothing to do"; return 0; }

  local keep=() remove=() img k r
  mapfile -t keep < <(printf '%s\n' "${imgs[@]}" | head -n "$KEEP")
  k=" ${keep[*]} "
  [[ "$k" == *" $running_img "* ]] || keep+=("$running_img")

  for img in "${imgs[@]}"; do
    r=0
    for k in "${keep[@]}"; do [[ "$img" == "$k" ]] && r=1 && break; done
    [[ "$r" -eq 0 ]] && remove+=("$img")
  done

  log "installed kernel images (${#imgs[@]}): ${imgs[*]}"
  log "running kernel image: $running_img (always protected)"
  log "keeping: ${keep[*]}"

  for img in "${remove[@]}"; do
    if [[ "$img" == "$running_img" ]]; then
      warn "ABORT: running kernel image $running_img is in the removal set; refusing to continue"
      exit 1
    fi
  done

  if [[ "${#remove[@]}" -eq 0 ]]; then
    log "nothing to remove"
    return 0
  fi

  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would purge: ${remove[*]}"
    if sim="$(apt-get -s purge "${remove[@]}" 2>&1)"; then
      log "[check] apt-get -s purge simulation succeeded"
    else
      warn "[check] apt-get -s purge simulation failed:"
      printf '%s\n' "$sim"
      exit 1
    fi
    return 0
  fi
  log "purging: ${remove[*]}"
  apt-get -y purge "${remove[@]}"
  log "kernel cleanup complete"
}

case "$DISTRO" in
  redhat) cleanup_redhat ;;
  debian) cleanup_debian ;;
esac
