#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\033[1;31m[ERR] Line $LINENO: Command failed.\033[0m" >&2' ERR

# ============================================================
#  Local DNS Test Suite — Pi-hole + Unbound (Docker)
#  Deduplicated & Linted
# ============================================================

PIHOLE_CTR="pihole-backup"
UNBOUND_CTR="unbound-backup"
UNBOUND_IP="172.20.0.3"
UNBOUND_PORT="5335"

declare -i PASS=0
declare -i FAIL=0
declare -i TOTAL=0
FAIL_LOG="/tmp/dns-test-failures-$(date +%s).log"

# ---------- Helpers ----------

run_dig() {
  local label="$1"; shift
  local container="$1"; shift

  TOTAL+=1
  printf '\n\033[1;36m[%02d] %s\033[0m\n' "$TOTAL" "$label"
  printf '\033[2m$ docker exec %s dig %s\033[0m\n' "$container" "$*"

  local out rc
  out="$(sudo docker exec "$container" dig "$@" 2>&1)" && rc=0 || rc=$?

  if (( rc == 0 )); then
    printf '\033[1;32m  ✓ PASS\033[0m\n'
    PASS+=1
  else
    printf '\033[1;31m  ✗ FAIL (exit %d)\033[0m\n' "$rc"
    printf '  \033[2mFailure log: %s\033[0m\n' "$FAIL_LOG"
    printf '[%s] [%02d] %s\nexit=%d\n%s\n---\n' \
      "$(date -Iseconds)" "$TOTAL" "$label" "$rc" "$out" >> "$FAIL_LOG"
    FAIL+=1
  fi

  return 0
}

section() {
  printf '\n\033[1;35m══════ %s ══════\033[0m\n' "$1"
}

# ---------- Pre-flight ----------

if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
  printf '\033[1;33m⚠ Not root and sudo requires password.\033[0m\n'
  printf '\033[2m  Interactive prompt may appear or CI runs may hang.\033[0m\n\n'
fi

section "PRE-FLIGHT — Container Status"

for ctr in "$PIHOLE_CTR" "$UNBOUND_CTR"; do
  if sudo docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -q true; then
    printf '  \033[1;32m%s — running\033[0m\n' "$ctr"
  else
    if sudo docker inspect "$ctr" &>/dev/null; then
      printf '  \033[1;31m%s — STOPPED. Aborting.\033[0m\n' "$ctr"
    else
      printf '  \033[1;31m%s — MISSING (not found). Aborting.\033[0m\n' "$ctr"
    fi
    exit 1
  fi
done

# ---------- Tests ----------

section "1 — PI-HOLE LOCAL RESOLUTION"
run_dig "pi.hole via localhost"       "$PIHOLE_CTR" "@localhost" "pi.hole"
run_dig "doubleclick.net (blocklist)" "$PIHOLE_CTR" "@localhost" "doubleclick.net"

section "2 — UNBOUND DIRECT RESOLVER"
run_dig "google.com via localhost"    "$UNBOUND_CTR" "@localhost" "google.com"

section "3 — PI-HOLE → UNBOUND FORWARDER"
run_dig "google.com @${UNBOUND_IP}:53"          "$PIHOLE_CTR" "@${UNBOUND_IP}" "google.com"
run_dig "google.com @${UNBOUND_IP}:${UNBOUND_PORT}" "$PIHOLE_CTR" "@${UNBOUND_IP}" "-p" "${UNBOUND_PORT}" "google.com"

section "4 — DNSSEC VALIDATION"
run_dig "dnssec-failed.org (expect SERVFAIL)" "$PIHOLE_CTR" "@${UNBOUND_IP}" "-p" "${UNBOUND_PORT}" "dnssec-failed.org" "+dnssec"
run_dig "google.com (expect AD flag)"          "$PIHOLE_CTR" "@${UNBOUND_IP}" "-p" "${UNBOUND_PORT}" "google.com" "+dnssec"

# ---------- Summary ----------

section "SUMMARY"

printf '  Total : %d | \033[1;32mPASS : %d\033[0m | \033[1;31mFAIL : %d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"

if (( FAIL > 0 )); then
  printf '  \033[2mDiagnostics: %s\033[0m\n\n' "$FAIL_LOG"
else
  rm -f "$FAIL_LOG"
  printf '\n'
fi

(( FAIL == 0 )) && exit 0 || exit 1
