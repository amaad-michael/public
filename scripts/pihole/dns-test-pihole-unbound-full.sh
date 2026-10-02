#!/usr/bin/env bash
set -euo pipefail

# DNS Test Suite: Pi-hole + Unbound Validation
# Tests: resolution targets, port routing, DNSSEC validation, ad-block verification

readonly PIHOLE_CONTAINER="pihole-backup"
readonly UNBOUND_CONTAINER="unbound-backup"
readonly UNBOUND_IP="172.20.0.3"
readonly UNBOUND_PORT="5335"

# Color codes for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

PASS=0
FAIL=0

# Execute DNS test and capture result
run_test() {
    local test_name="$1"
    local container="$2"
    shift 2
    local dig_args=("$@")

    printf '%s[TEST]%s %s\n' "$BLUE" "$NC" "$test_name"

    if output=$(sudo docker exec "$container" dig "${dig_args[@]}" 2>&1); then
        # Extract status line from dig output
        status_line=$(grep -E "^;; ->>HEADER" <<< "$output" || echo "")

        printf '%s[PASS]%s\n%s\n\n' "$GREEN" "$NC" "$status_line"
        ((PASS++))
    else
        # Truncate error output to 200 chars to prevent log spam
        printf '%s[FAIL]%s\n%s\n\n' "$RED" "$NC" "${output:0:200}"
        ((FAIL++))
    fi
}

main() {
    printf '%s=== DNS Test Suite ===%s\n\n' "$BLUE" "$NC"

    # Test 1: Pi-hole local resolution
    run_test "Pi-hole: Resolve pi.hole (localhost)" \
        "$PIHOLE_CONTAINER" "@localhost" "pi.hole"

    # Test 2: Unbound direct localhost
    run_test "Unbound: Resolve google.com (localhost)" \
        "$UNBOUND_CONTAINER" "@localhost" "google.com"

    # Test 3: Pi-hole to Unbound via IP
    run_test "Pi-hole > Unbound: Resolve google.com (@172.20.0.3)" \
        "$PIHOLE_CONTAINER" "@${UNBOUND_IP}" "google.com"

    # Test 4: Unbound non-standard port (fragment syntax)
    run_test "Unbound: Port ${UNBOUND_PORT} (fragment syntax)" \
        "$PIHOLE_CONTAINER" "@${UNBOUND_IP}#${UNBOUND_PORT}" "google.com"

    # Test 5: Unbound non-standard port (flag syntax)
    run_test "Unbound: Port ${UNBOUND_PORT} (flag syntax)" \
        "$PIHOLE_CONTAINER" "@${UNBOUND_IP}" "-p" "${UNBOUND_PORT}" "google.com"

    # Test 6: DNSSEC on failed domain
    run_test "DNSSEC: dnssec-failed.org (should fail validation)" \
        "$PIHOLE_CONTAINER" "@${UNBOUND_IP}" "-p" "${UNBOUND_PORT}" "dnssec-failed.org" "+dnssec"

    # Test 7: DNSSEC on valid domain
    run_test "DNSSEC: google.com (should validate)" \
        "$PIHOLE_CONTAINER" "@${UNBOUND_IP}" "-p" "${UNBOUND_PORT}" "google.com" "+dnssec"

    # Test 8: Ad-block verification (doubleclick.net)
    run_test "Ad-block: doubleclick.net (should be blocked)" \
        "$PIHOLE_CONTAINER" "@localhost" "doubleclick.net"

    # Summary
    printf '\n%s=== Summary ===%s\n' "$BLUE" "$NC"
    printf 'Passed: %s%d%s | Failed: %s%d%s\n' "$GREEN" "$PASS" "$NC" "$RED" "$FAIL" "$NC"

    [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}

main
