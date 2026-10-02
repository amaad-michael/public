#!/usr/bin/env bash
# ssh-audit — audit effective sshd config against a hardening baseline.
# Read-only. Usage: ssh-audit-local.sh [--config FILE] [--help]
set -euo pipefail

CONFIG_OVERRIDE=""

usage() {
  cat <<'EOF'
ssh-audit-local.sh — Audit sshd configuration against a hardening baseline.

Usage: ssh-audit-local.sh [--config FILE]

Options:
  --config FILE   Parse FILE instead of the effective config (testing/debugging).
  --help          Show this help.

Reads effective config via `sshd -T` when available; otherwise parses
/etc/ssh/sshd_config (noted in output). Never changes anything.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:?--config needs a file}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- distro detection ----
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  echo "ERROR: cannot detect distro (/etc/os-release missing)" >&2
  exit 2
fi
case "${ID_LIKE:-$ID} ${ID}" in
  *rhel*|*fedora*|*centos*) FAMILY=redhat ;;
  *debian*|*ubuntu*)        FAMILY=debian ;;
  *) echo "ERROR: unsupported distro (ID=${ID}, ID_LIKE=${ID_LIKE:-unset})" >&2; exit 2 ;;
esac
echo "Distro: ${PRETTY_NAME:-$ID} (family: $FAMILY)"

# ---- gather effective config into KEY=value lines (lowercase keys) ----
declare -A CFG
SOURCE_NOTE=""

if [ -n "$CONFIG_OVERRIDE" ]; then
  [ -r "$CONFIG_OVERRIDE" ] || { echo "ERROR: cannot read $CONFIG_OVERRIDE" >&2; exit 2; }
  # sshd uses the FIRST occurrence of each option in sshd_config.
  while read -r key val _rest; do
    case "$key" in ''|\#*) continue ;; esac
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    [ -z "${CFG[$key]+x}" ] && CFG[$key]="$val"
  done < "$CONFIG_OVERRIDE"
  SOURCE_NOTE="parsed $CONFIG_OVERRIDE directly (first occurrence wins)"
elif command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
  while IFS=' ' read -r key val _rest; do
    [ -z "${CFG[$key]+x}" ] && CFG[$key]="$val"
  done < <(sshd -T 2>/dev/null)
  SOURCE_NOTE="effective config from 'sshd -T'"
elif [ -r /etc/ssh/sshd_config ]; then
  while read -r key val _rest; do
    case "$key" in ''|\#*) continue ;; esac
    key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    [ -z "${CFG[$key]+x}" ] && CFG[$key]="$val"
  done < /etc/ssh/sshd_config
  SOURCE_NOTE="NOTE: 'sshd -T' unavailable — parsed /etc/ssh/sshd_config directly (first occurrence wins; may differ from effective config due to includes/defaults)"
else
  echo "SKIP: no sshd binary and no readable /etc/ssh/sshd_config — nothing to audit" >&2
  exit 0
fi

echo "Source: $SOURCE_NOTE"
echo

get() { printf '%s' "${CFG[$1]:-<unset>}"; }

# sshd LoginGraceTime may be like '120', '2m', '1h'. Convert to seconds.
to_seconds() {
  local v="${1,,}" n s
  if [[ "$v" =~ ^([0-9]+)([smh]?)$ ]]; then
    n="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"
    case "$s" in m) echo $((n*60)) ;; h) echo $((n*3600)) ;; *) echo "$n" ;; esac
  else
    echo "unparseable"
  fi
}

PASS=0; FAIL=0; NOTE=0
check() { # name current expected comparator
  local name="$1" cur="$2" exp="$3" cmp="$4" ok=0
  case "$cmp" in
    eq)  [ "${cur,,}" = "${exp,,}" ] && ok=1 ;;
    le)  [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" -le "$exp" ] && ok=1 ;;
    in)  case ",${exp,,}," in *",${cur,,},"*) ok=1 ;; esac ;;
  esac
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); printf 'PASS  %-28s current=%-18s expected=%s\n' "$name" "$cur" "$exp";
  else FAIL=$((FAIL+1)); printf 'FAIL  %-28s current=%-18s expected=%s\n' "$name" "$cur" "$exp"; fi
}

echo "=== SSH hardening baseline ==="
check "PermitRootLogin"            "$(get permitrootlogin)"            "no,prohibit-password"        in
check "PasswordAuthentication"     "$(get passwordauthentication)"     "no"                          eq
# OpenSSH >= 8.7 renamed ChallengeResponseAuthentication -> KbdInteractiveAuthentication
kia="$(get kbdinteractiveauthentication)"
[ "$kia" = "<unset>" ] && kia="$(get challengeresponseauthentication)"
check "KbdInteractiveAuthentication" "$kia"                            "no"                          eq
check "X11Forwarding"              "$(get x11forwarding)"              "no"                          eq
check "MaxAuthTries"               "$(get maxauthtries)"               "4"                           le
check "LoginGraceTime (seconds)"   "$(to_seconds "$(get logingracetime)")" "60"                      le
check "Protocol"                   "$(get protocol)"                   "2"                           eq

au="$(get allowusers)"; ag="$(get allowgroups)"
if [ "$au" = "<unset>" ] && [ "$ag" = "<unset>" ]; then
  NOTE=$((NOTE+1)); echo "NOTE  AllowUsers/AllowGroups not set — any account may attempt login"
else
  NOTE=$((NOTE+1)); echo "NOTE  AllowUsers=${au} AllowGroups=${ag}"
fi

echo
echo "Result: $PASS PASS, $FAIL FAIL, $NOTE note(s)"
[ "$FAIL" -eq 0 ]
