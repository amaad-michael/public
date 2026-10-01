#!/usr/bin/env bash
# Enforce password aging (chage) and a minimum password-quality baseline.
# Idempotent; supports --check dry-run.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: password-policy-local.sh [USERNAME|--all]
       [--maxdays N] [--mindays N] [--warndays N]
       [--inactive D] [--expiredate YYYY-MM-DD]
       [--minlen N] [--check]

  Apply password aging to one user or to all real users (UID >= 1000,
  excluding accounts with a nologin/false shell), and ensure a minimum
  password-quality baseline:
    - RedHat family: write /etc/security/pwquality.conf.d/toolkit.conf
    - Debian family: ensure libpam-pwquality is installed, then write the
      same toolkit.conf (pam_pwquality reads *.d snippets where supported;
      otherwise pam_pwquality.so already honors /etc/security/pwquality.conf)

Options:
  USERNAME / --all      One login name, or all real users (default: --all).
  --maxdays N          chage -M : password expires after N days (default 90).
  --mindays N          chage -m : days before password may be changed (default 1).
  --warndays N         chage -W : warning days before expiry (default 7).
  --inactive D         chage -I : days of inactivity before lock (default: unchanged).
  --expiredate DATE    chage -E YYYY-MM-DD : account expiry date (default: unchanged).
  --minlen N           Minimum password length in the quality baseline (default 12).
  --skip-pwquality     Apply only password aging; do not touch the pwquality
                       package or config (useful for testing on live systems).
  --check              Dry-run: print what would be done, change nothing.
  --help               Show this help.

Examples:
  password-policy-local.sh --all --check
  password-policy-local.sh deploy --maxdays 60 --warndays 14
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

MAXDAYS=90
MINDAYS=1
WARNDAYS=7
INACTIVE=""
EXPIREDATE=""
MINLEN=12
USER_SPEC=""
ALL=1
CHECK=0
SKIP_PWQUALITY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --maxdays)   MAXDAYS="${2:?--maxdays requires a value}"; shift 2 ;;
    --mindays)   MINDAYS="${2:?--mindays requires a value}"; shift 2 ;;
    --warndays)  WARNDAYS="${2:?--warndays requires a value}"; shift 2 ;;
    --inactive)  INACTIVE="${2:?--inactive requires a value}"; shift 2 ;;
    --expiredate) EXPIREDATE="${2:?--expiredate requires a value}"; shift 2 ;;
    --minlen)    MINLEN="${2:?--minlen requires a value}"; shift 2 ;;
    --skip-pwquality) SKIP_PWQUALITY=1; shift ;;
    --all)       ALL=1; USER_SPEC=""; shift ;;
    --check)     CHECK=1; shift ;;
    --help)      usage; exit 0 ;;
    --*)         warn "unknown option: $1"; usage; exit 2 ;;
    *)           USER_SPEC="$1"; ALL=0; shift ;;
  esac
done

for v in MAXDAYS MINDAYS WARNDAYS MINLEN; do
  if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
    warn "--${v,,} must be a non-negative integer (got '${!v}')"
    exit 2
  fi
done
if [[ -n "$INACTIVE" ]] && ! [[ "$INACTIVE" =~ ^[0-9]+$ ]]; then
  warn "--inactive must be a non-negative integer"
  exit 2
fi
if [[ -n "$EXPIREDATE" ]] && ! [[ "$EXPIREDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  warn "--expiredate must be YYYY-MM-DD (got '$EXPIREDATE')"
  exit 2
fi
if [[ -n "$EXPIREDATE" ]] && ! date -d "$EXPIREDATE" +%F >/dev/null 2>&1; then
  warn "--expiredate is not a valid date: $EXPIREDATE"
  exit 2
fi

# Detect distro family for the pwquality step.
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
else
  warn "cannot read /etc/os-release; refusing to proceed"
  exit 1
fi
FAMILY=""
case "${ID:-} ${ID_LIKE:-}" in
  *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*ol*)
    FAMILY="redhat" ;;
  *debian*|*ubuntu*)
    FAMILY="debian" ;;
  *)
    warn "unsupported distro (ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}); only RHEL and Debian families are supported"
    exit 1 ;;
esac

# List target users: real (UID>=1000) with a login-capable shell.
list_users() {
  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 )) || continue
    case "$shell" in
      */nologin|*/false|"") continue ;;
    esac
    printf '%s\n' "$name"
  done </etc/passwd
}

TARGETS=()
if [[ "$ALL" -eq 1 ]]; then
  while IFS= read -r u; do TARGETS+=("$u"); done < <(list_users)
  [[ "${#TARGETS[@]}" -gt 0 ]] || { warn "no real users (UID>=1000 with login shell) found"; }
else
  if ! id "$USER_SPEC" &>/dev/null; then
    warn "user $USER_SPEC does not exist"
    exit 1
  fi
  TARGETS+=("$USER_SPEC")
fi

# Desired chage values, for idempotency checks (empty means "leave as-is").
current_field() { # $1=user $2=field-name from chage -l
  # chage -l pads field names with tabs before the colon; trim them.
  chage -l "$1" | awk -F':' -v f="$2" '{name=$1; sub(/[ \t]+$/, "", name)} name == f {v=$2; sub(/^[ \t]+/, "", v); print v}'
}

apply_aging() {
  local user="$1" needs=()
  [[ "$(current_field "$user" 'Maximum number of days between password change')" == "$MAXDAYS" ]] || needs+=(-M "$MAXDAYS")
  [[ "$(current_field "$user" 'Minimum number of days between password change')" == "$MINDAYS" ]] || needs+=(-m "$MINDAYS")
  [[ "$(current_field "$user" 'Number of days of warning before password expires')" == "$WARNDAYS" ]] || needs+=(-W "$WARNDAYS")
  if [[ -n "$INACTIVE" ]]; then
    # chage -l reports inactivity as a DATE (expiry + N days), not the day count.
    cur_inactive="$(current_field "$user" 'Password inactive')"
    expiry="$(current_field "$user" 'Password expires')"
    expect=""
    if [[ "$cur_inactive" != "never" && "$expiry" != "never" ]]; then
      expect="$(date -d "$expiry + $INACTIVE days" '+%b %d, %Y' 2>/dev/null || true)"
    fi
    [[ -n "$expect" && "$cur_inactive" == "$expect" ]] || needs+=(-I "$INACTIVE")
  fi
  if [[ -n "$EXPIREDATE" ]]; then
    [[ "$(current_field "$user" 'Account expires')" == "$(date -d "$EXPIREDATE" '+%b %d, %Y')" ]] || needs+=(-E "$EXPIREDATE")
  fi

  if [[ "${#needs[@]}" -eq 0 ]]; then
    log "user $user: aging already correct"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would run: chage ${needs[*]} $user"
  else
    chage "${needs[@]}" "$user"
    log "user $user: aging updated (chage ${needs[*]})"
  fi
}

PWCONF_DIR="/etc/security/pwquality.conf.d"
PWCONF_FILE="$PWCONF_DIR/toolkit.conf"

pwquality_desired_content() {
  cat <<EOF
# Managed by linux-admin-toolkit password-policy (do not hand-edit).
minlen = $MINLEN
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
retry = 3
EOF
}

ensure_pwquality() {
  # On Debian ensure the package exists first.
  if [[ "$FAMILY" == "debian" ]]; then
    if ! dpkg -s libpam-pwquality >/dev/null 2>&1; then
      if [[ "$CHECK" -eq 1 ]]; then
        log "[check] would install libpam-pwquality (apt-get)"
        return 0
      fi
      DEBIAN_FRONTEND=noninteractive apt_refresh
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libpam-pwquality
      log "installed libpam-pwquality"
    fi
  fi
  # Note: RHEL family ships pam_pwquality with libpwquality already.
  local desired tmp
  desired="$(pwquality_desired_content)"
  if [[ -f "$PWCONF_FILE" ]] && [[ "$(cat "$PWCONF_FILE")" == "$desired" ]]; then
    log "pwquality baseline $PWCONF_FILE already correct"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would write $PWCONF_FILE with minlen=$MINLEN and credit requirements"
    return 0
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$desired" >"$tmp"
  install -m 0644 "$tmp" "$PWCONF_FILE"
  rm -f "$tmp"
  log "wrote $PWCONF_FILE (minlen=$MINLEN)"
}

for u in "${TARGETS[@]}"; do
  apply_aging "$u"
done
if [[ "$SKIP_PWQUALITY" -eq 1 ]]; then
  log "skipping pwquality baseline (--skip-pwquality)"
else
  ensure_pwquality
fi
log "done"
