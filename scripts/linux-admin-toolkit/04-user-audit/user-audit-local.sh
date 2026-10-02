#!/usr/bin/env bash
# READ-ONLY user audit: dormant users, empty-password accounts, duplicate UID 0.
# Changes nothing on the system.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: user-audit-local.sh [--days N] [--help]

  Report on local user accounts. Read-only.

  (a) Dormant users: human users (UID >= 1000 with a login-capable shell)
      with no login recorded in the last N days (from lastlog).
  (b) Accounts with an empty password field in /etc/shadow.
  (c) Duplicate UID 0 accounts.

Options:
  --days N     Dormancy threshold in days (default 90).
  --help       Show this help.

Exit status is always 0.
EOF
}

DAYS=90

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) [[ -n "${2:-}" ]] || { echo "warning: --days requires a value" >&2; exit 2; }
            DAYS="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    --*)    echo "warning: unknown option: $1" >&2; usage; exit 2 ;;
    *)      echo "warning: unexpected argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "warning: --days must be a non-negative integer" >&2; exit 2; }

echo "=== User audit (read-only) ==="
echo "Threshold: no login in last $DAYS day(s)"
echo

# --- (a) Dormant users -------------------------------------------------------
echo "--- (a) Dormant users (UID>=1000, login shell, no login in $DAYS days) ---"
cutoff_epoch="$(date -d "$DAYS days ago" +%s 2>/dev/null || echo 0)"
dormant_count=0

while IFS=: read -r name _ uid _ _ _ shell; do
  [[ "$uid" =~ ^[0-9]+$ ]] || continue
  (( uid >= 1000 )) || continue
  case "$shell" in
    */nologin|*/false|"") continue ;;
  esac
  line="$(lastlog -u "$name" 2>/dev/null | tail -n +2)"
  if [[ "$line" == *"**Never logged in**"* ]]; then
    echo "  $name (uid $uid): never logged in"
    dormant_count=$((dormant_count+1))
    continue
  fi
  # Extract the trailing date ("Mon Sep 15 22:19:19 +0000 2026"); the leading
  # columns vary in width across lastlog versions, so anchor on the date shape.
  last_seen="$(grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9:]+ [^ ]+ [0-9]{4}$' <<<"$line" || true)"
  if [[ -z "$last_seen" ]]; then
    echo "  $name (uid $uid): lastlog output unparseable (treating as unknown)"
    continue
  fi
  login_epoch="$(date -d "$last_seen" +%s 2>/dev/null || echo '')"
  if [[ -z "$login_epoch" ]]; then
    echo "  $name (uid $uid): last login '$last_seen' (unparseable date; treating as unknown)"
    continue
  fi
  if (( login_epoch < cutoff_epoch )); then
    echo "  $name (uid $uid): last login $last_seen"
    dormant_count=$((dormant_count+1))
  fi
done </etc/passwd

(( dormant_count == 0 )) && echo "  none"
echo

# --- (b) Empty password fields -----------------------------------------------
echo "--- (b) Accounts with empty password field in /etc/shadow ---"
empty_count=0
while IFS=: read -r name pass _; do
  if [[ -z "$pass" ]]; then
    echo "  $name"
    empty_count=$((empty_count+1))
  fi
done </etc/shadow
(( empty_count == 0 )) && echo "  none"
echo

# --- (c) Duplicate UID 0 ------------------------------------------------------
echo "--- (c) Accounts with UID 0 ---"
uid0="$(awk -F: '$3 == 0 {print $1}' /etc/passwd)"
uid0_count="$(echo "$uid0" | grep -c . || true)"
while IFS= read -r n; do
  [[ -n "$n" ]] && echo "  $n"
done <<<"$uid0"
if (( uid0_count > 1 )); then
  echo "  FINDING: $uid0_count accounts share UID 0 (only root should have UID 0)"
elif (( uid0_count == 1 )); then
  echo "  ok: only root has UID 0"
else
  echo "  FINDING: no UID 0 account found"
fi
echo

echo "=== Audit complete (no changes made) ==="
exit 0
