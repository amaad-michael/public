#!/usr/bin/env bash
#
# NAME: cron-audit.sh (containers/cron-audit)
# WHAT: Container form of the fleet cron audit (bash:
#       scripts/monitoring/local_cron_checker.sh and
#       remote_cron_checker.sh; Ansible: playbooks/audits/cron_audit.yml).
#       Collects user crontabs, /etc/crontab, /etc/cron.d/*, the cron
#       period directories, and — where the access mode allows —
#       systemd timer state, in the bash checkers' report format, and
#       flags world-writable cron files and cron entries executing
#       from /tmp, /var/tmp, or /dev/shm.
# HOW:  Two access modes (see README.md for the honest tradeoffs):
#         cron-audit.sh --root /host [--output FILE]
#           Reads a host filesystem mounted at /host (layout: /host/etc,
#           /host/var/spool/cron[/crontabs]). No host systemd access in
#           this mode, so the timer section says so instead of guessing.
#         cron-audit.sh --ssh HOST [HOST ...] [--output FILE]
#           Runs the collection on each host over SSH, like the bash
#           remote checker (10s connect timeout; unreachable hosts are
#           logged as ERROR and skipped). Timers included.
#       Default with no mode flag: --root /host.
#
set -uo pipefail

MODE="root"
ROOT="/host"
OUTPUT=""
HOSTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) MODE="root"; ROOT="$2"; shift 2 ;;
    --ssh) MODE="ssh"; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --) shift ;;
    *) if [ "$MODE" = "ssh" ]; then HOSTS+=("$1"); shift; else echo "Unknown option: $1" >&2; exit 2; fi ;;
  esac
done

emit() { printf '%s\n' "$*"; }

findings_for_paths() {
  # Deliberately no process substitution: /dev/fd may not exist in a
  # minimal container rootfs (no /proc mounted), which would silently
  # skip the scans. Command substitution needs no /dev/fd.
  local found=0 p out
  for p in "$@"; do
    [ -e "$p" ] || continue
    out="$(find "$p" -type f -perm -0002 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/FLAG world-writable: /'
      found=1
    fi
    out="$(grep -R -h -E '(^|[[:space:]])/(tmp|var/tmp|dev/shm)/' "$p" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/FLAG tmp-exec: /'
      found=1
    fi
  done
  [ "$found" -eq 0 ] && emit "none"
  return 0
}

collect_root() {
  local root="$1"
  emit "Collecting all local cron jobs..."
  emit "Timestamp: $(date)"
  if [ -f "$root/etc/hostname" ]; then
    emit "Hostname: $(cat "$root/etc/hostname") (mounted root: $root)"
  else
    emit "Hostname: mounted root $root"
  fi
  emit "================================="

  emit "--- User Crontabs ---"
  if [ -f "$root/etc/passwd" ]; then
    while IFS=: read -r user _ uid _ _ _ shell; do
      [ "$uid" -ge 1000 ] 2>/dev/null || continue
      case "$shell" in *bash*|*sh*) ;; *) continue ;; esac
      emit "User: $user"
      if [ -f "$root/var/spool/cron/$user" ]; then
        cat "$root/var/spool/cron/$user"
      elif [ -f "$root/var/spool/cron/crontabs/$user" ]; then
        cat "$root/var/spool/cron/crontabs/$user"
      else
        emit "No crontab for $user"
      fi
      emit ""
    done < "$root/etc/passwd"
  else
    emit "(no passwd file under $root/etc — user crontabs unavailable)"
    emit ""
  fi

  emit "--- /etc/crontab ---"
  cat "$root/etc/crontab" 2>/dev/null || emit "No /etc/crontab found"
  emit ""

  emit "--- /etc/cron.d/ ---"
  if [ -d "$root/etc/cron.d" ]; then
    for file in "$root"/etc/cron.d/*; do
      [ -f "$file" ] || continue
      emit "File: ${file#"$root"}"
      cat "$file"
      emit ""
    done
  fi

  for dir in hourly daily weekly monthly; do
    emit "--- /etc/cron.$dir/ ---"
    ls -l "$root/etc/cron.$dir" 2>/dev/null || emit "/etc/cron.$dir not found"
    emit ""
  done

  emit "--- Systemd Timers (addition to the bash audit) ---"
  emit "not available in mounted mode: reading timer state needs the host's running systemd; use --ssh mode or the Ansible/bash forms on the host"
  emit ""

  emit "--- Findings ---"
  findings_for_paths "$root/etc/crontab" "$root/etc/cron.d" "$root/var/spool/cron" "$root/var/spool/cron/crontabs"
}

collect_ssh_host() {
  local server="$1"
  emit "========== $server =========="
  emit "Timestamp: $(date)"
  emit ""
  emit "--- User Crontabs ---"
  ssh -o ConnectTimeout=10 "$server" 'getent passwd | awk -F: '\''$3 >= 1000 && $7 ~ /bash|sh/ {print $1}'\'' | while read -r user; do
      echo "User: $user"
      crontab -u "$user" -l 2>/dev/null || echo "No crontab for $user"
      echo ""
  done' 2>/dev/null || emit "(collection failed)"
  emit ""
  emit "--- /etc/crontab ---"
  ssh -o ConnectTimeout=10 "$server" 'cat /etc/crontab 2>/dev/null || echo "No /etc/crontab found"' 2>/dev/null || emit "(collection failed)"
  emit ""
  emit "--- /etc/cron.d/ ---"
  ssh -o ConnectTimeout=10 "$server" 'for file in /etc/cron.d/*; do [ -f "$file" ] && { echo "File: $file"; cat "$file"; echo ""; }; done' 2>/dev/null || emit "(collection failed)"
  emit ""
  emit "--- /etc/cron.* directories ---"
  for dir in hourly daily weekly monthly; do
    emit "/etc/cron.$dir:"
    # shellcheck disable=SC2029 # $dir is a loop variable: client-side expansion is intentional (same pattern as the bash remote checker)
    ssh -o ConnectTimeout=10 "$server" "ls -l /etc/cron.$dir 2>/dev/null || echo 'Directory not found'" 2>/dev/null || emit "(collection failed)"
    emit ""
  done
  emit "--- Systemd Timers (addition to the bash audit) ---"
  ssh -o ConnectTimeout=10 "$server" 'systemctl list-timers --all --no-pager 2>/dev/null || echo "systemctl list-timers not available"' 2>/dev/null || emit "(collection failed)"
  emit ""
  emit "--- Findings ---"
  ssh -o ConnectTimeout=10 "$server" 'find /etc/crontab /etc/cron.d /var/spool/cron /var/spool/cron/crontabs -type f -perm -0002 2>/dev/null | sed "s/^/FLAG world-writable: /"; grep -R -h -E "(^|[[:space:]])/(tmp|var/tmp|dev/shm)/" /etc/crontab /etc/cron.d /var/spool/cron /var/spool/cron/crontabs 2>/dev/null | sed "s/^/FLAG tmp-exec: /"; true' 2>/dev/null || emit "(collection failed)"
}

run() {
  if [ "$MODE" = "root" ]; then
    collect_root "$ROOT"
  else
    emit "Collecting all cron jobs from remote servers..."
    emit "Timestamp: $(date)"
    emit "========================================="
    for server in "${HOSTS[@]}"; do
      emit "Fetching cron jobs from $server..."
      if ! ssh -o ConnectTimeout=10 "$server" "echo OK" &>/dev/null; then
        emit "ERROR: Unable to connect to $server"
        continue
      fi
      collect_ssh_host "$server"
    done
  fi
  emit "Cron job collection complete."
}

if [ -n "$OUTPUT" ]; then
  run | tee "$OUTPUT"
  chmod 600 "$OUTPUT"
else
  run
fi
