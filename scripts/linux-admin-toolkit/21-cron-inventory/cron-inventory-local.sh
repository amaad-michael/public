#!/usr/bin/env bash
# Read-only inventory of cron jobs: every user's crontab (enumerated from
# /etc/passwd), /etc/crontab, /etc/cron.d/*, and the cron period directories.
# Changes nothing; always exits 0.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cron-inventory-local.sh [--help]

  Print a read-only inventory of cron jobs on this host:
    - every user's crontab (users enumerated from /etc/passwd; skipped
      quietly when a user has no crontab)
    - /etc/crontab
    - each file in /etc/cron.d/
    - contents of /etc/cron.hourly /etc/cron.daily /etc/cron.weekly
      /etc/cron.monthly

  Each section is labeled with its origin. Changes nothing; exit 0.
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
section() { printf '\n=== %s ===\n' "$1"; }

for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0 ;;
    *)      warn "unknown option: $arg"; usage; exit 2 ;;
  esac
done

# --- Distro sanity check (cron layout is identical on both families) --------
DISTRO_ID=""; DISTRO_ID_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-}"; DISTRO_ID_LIKE="${ID_LIKE:-}"
fi
DISTRO="unknown"
case " ${DISTRO_ID} ${DISTRO_ID_LIKE} " in
  *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" alma "*|*" fedora "*|*" ol "*|*" oracle "*)
    DISTRO="rhel" ;;
  *" debian "*|*" ubuntu "*)
    DISTRO="debian" ;;
esac
if [[ "$DISTRO" == "unknown" ]]; then
  warn "unsupported distribution (ID='${DISTRO_ID}' ID_LIKE='${DISTRO_ID_LIKE}'); only RHEL- and Debian-family hosts are supported"
  exit 2
fi

log "cron inventory for $(hostname) (distro family: $DISTRO)"

# --- Per-user crontabs -------------------------------------------------------
# Reading other users' crontabs requires root; non-root runs only see their own.
if [[ "$(id -u)" -eq 0 ]]; then
  mapfile -t USERS < <(cut -d: -f1 /etc/passwd)
else
  warn "not running as root; only the current user's ($(id -un)) crontab can be read"
  USERS=("$(id -un)")
fi

for user in "${USERS[@]}"; do
  # Skip users without a crontab quietly (crontab -l exits non-zero there).
  out="$(crontab -l -u "$user" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    section "user crontab: $user"
    printf '%s\n' "$out"
  fi
done

# --- System crontab ----------------------------------------------------------
if [[ -r /etc/crontab ]]; then
  section "file: /etc/crontab"
  cat /etc/crontab
else
  section "file: /etc/crontab"
  log "(not present or not readable)"
fi

# --- /etc/cron.d -------------------------------------------------------------
if [[ -d /etc/cron.d ]]; then
  for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    section "file: $f"
    cat "$f"
  done
else
  section "directory: /etc/cron.d"
  log "(not present)"
fi

# --- Cron period directories -------------------------------------------------
for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
  section "directory listing: $d"
  if [[ -d "$d" ]]; then
    ls -la "$d"
  else
    log "(not present)"
  fi
done

exit 0
