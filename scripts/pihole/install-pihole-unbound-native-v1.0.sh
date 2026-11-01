#!/usr/bin/env bash
# install-pihole-unbound-native-v1.0.sh - bash installer for the bare-metal
# Pi-hole + Unbound form
# Version: 1.0 (2026-10-31)
#
# ═══════════════════════════════════════════════════════════════════════════
# READ THIS BEFORE A REAL RUN
#
# This is the bash form of the bare-metal Pi-hole + Unbound install. The
# stack's other forms are the Ansible playbooks in
# ansible/playbooks/pihole/ (the parallel route to the same end state)
# and the container pair in containers/pihole (deployed by
# install-pihole-unbound.sh). This script mirrors the two playbooks
# (pihole_unbound_automated.yml and pihole_unbound_attended.yml) step for
# step: same package set, same pinned vendor installer, same upstream
# switch to the local Unbound at 127.0.0.1#5335, same Unbound config
# (ansible/playbooks/pihole/unbound.conf), same root anchor handling,
# same closing restarts. The one deliberate difference: the blocklist
# step delegates to the sibling pihole-init-blocklists.sh, which seeds
# the OISD list the playbooks add plus the Hagezi lists the container
# form standardizes on, then runs gravity; the playbooks add OISD via
# the pihole CLI and run gravity as a separate step. End state is
# otherwise the playbooks' end state.
#
# THIS IS PRODUCTION DNS. While this script runs, the host's resolver
# is being rebuilt: Pi-hole's own installer restarts DNS services, and
# the closing steps restart Pi-hole DNS and Unbound. Run it on the
# secondary (pi0) first and confirm resolution there before touching
# the primary (pi4), the same order every other form prescribes.
#
# Modes (mirroring the two playbooks):
#   --unattended   (default) Pi-hole's installer runs with
#                  --unattended, exactly as pihole_unbound_automated.yml
#                  drives it. Idempotent: if /etc/pihole/setupVars.conf
#                  already exists, the vendor installer is not run
#                  again (the playbook's "creates" gate).
#   --attended     Mirrors pihole_unbound_attended.yml: this script
#                  downloads the vendor installer, prints the manual
#                  steps, and pauses. You run the vendor installer
#                  interactively in another session, choosing a public
#                  upstream for now (this script switches it to Unbound
#                  afterwards), then return and press Enter. If
#                  setupVars.conf does not exist after the pause, the
#                  script fails, exactly as the attended playbook does.
#
# The vendor installer is verified against the SHA-256 the playbooks
# pin (bd558069..., pinned 2026-09-20 against the live installer).
# Upstream updates that file in place; if verification fails, the
# script stops before executing anything and prints the actual hash.
# Re-pin deliberately: pass --installer-sha256 <hash> for one run after
# reviewing the new upstream file, and update the pin in this script
# and in both playbooks so the three forms stay in agreement.
#
# --dry-run prints the full plan and every command and changes
# nothing: no packages, no download, no file writes, no service
# restarts. Read-only checks (OS family, presence of existing config)
# still run so the plan reflects the host's actual state.
#
# Nothing is removed by this script. Existing Pi-hole and Unbound
# configuration is respected: the vendor installer is gated on
# setupVars.conf, the upstream line is edited in place, the Unbound
# config is only rewritten when its content differs, and the root
# anchor is only fetched when /var/lib/unbound/root.key is absent.
# Lifecycle after install (status, restart, logs-clean, uninstall) is
# pihole-control-v1.0.sh's job; its native install verb delegates here.
#
# Exit codes: 0 = done, 1 = a step or the verification pass failed,
# 2 = usage error.
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UNBOUND_CONF_SRC="${SCRIPT_DIR}/../../ansible/playbooks/pihole/unbound.conf"
BLOCKLIST_INIT="${SCRIPT_DIR}/pihole-init-blocklists.sh"
LOG_FILE="/var/log/install-pihole-unbound-native.log"

PIHOLE_INSTALL_URL="https://install.pi-hole.net"
PIHOLE_INSTALL_TMP="/tmp/install_pihole.sh"
PIHOLE_INSTALL_SHA256="bd558069a224910e4b6264a44e2cd4bdb5a8fb45d232e10e6fb91dd804590dc7"
SETUPVARS="/etc/pihole/setupVars.conf"
UPSTREAM_LINE="PIHOLE_DNS_1=127.0.0.1#5335"
UNBOUND_CONF_DEST="/etc/unbound/unbound.conf"
ROOT_KEY="/var/lib/unbound/root.key"
# curl, sudo, unbound, unbound-anchor are the playbooks' package set;
# sqlite3 is added because the delegated blocklist initializer
# (pihole-init-blocklists.sh) drives gravity.db through it.
PACKAGES=(curl sudo unbound unbound-anchor sqlite3)

MODE="unattended"
DRY_RUN=0
EXPECTED_SHA256="$PIHOLE_INSTALL_SHA256"

log() { printf '%s\n' "$*"; }
note() { log "  note: $*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'error: %s\n' "$*" >&2; exit 2; }

stamp() { date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'now'; }

act() {
    # A step whose failure the caller adjudicates (usually with || die).
    local desc=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] $*"
        return 0
    fi
    log "  run: $*"
    printf '[%s] %s: %s\n' "$(stamp)" "$desc" "$*" >>"$LOG_FILE" 2>/dev/null || true
    "$@"
}

act_soft() {
    # A step that legitimately fails off a live system (systemctl with
    # no running systemd bus). The verification pass is the gate.
    local desc=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] $*"
        return 0
    fi
    log "  run: $*"
    printf '[%s] %s: %s\n' "$(stamp)" "$desc" "$*" >>"$LOG_FILE" 2>/dev/null || true
    if ! "$@"; then
        note "$desc did not complete (soft step; the verification pass decides)"
    fi
    return 0
}

path_present() { [[ -e $1 || -L $1 ]]; }

require_root() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ $EUID -eq 0 ]] || die "run as root, e.g.: sudo $0"
}

usage() {
    sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -n -2
}

# ───────────────────────────────────────────────────────────────────────────
# Arguments
# ───────────────────────────────────────────────────────────────────────────

MODE_SEEN=""
while (($#)); do
    case "$1" in
        --unattended)
            [[ -z $MODE_SEEN ]] || usage_die "--attended and --unattended are mutually exclusive"
            MODE="unattended"; MODE_SEEN=1 ;;
        --attended)
            [[ -z $MODE_SEEN ]] || usage_die "--attended and --unattended are mutually exclusive"
            MODE="attended"; MODE_SEEN=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --unbound-conf)
            (($# >= 2)) || usage_die "--unbound-conf requires a value"
            UNBOUND_CONF_SRC=$2; shift ;;
        --installer-sha256)
            (($# >= 2)) || usage_die "--installer-sha256 requires a value"
            EXPECTED_SHA256=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_die "unknown option: $1" ;;
    esac
    shift
done

# ───────────────────────────────────────────────────────────────────────────
# The plan
# ───────────────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════════"
log "INSTALL PLAN: Pi-hole + Unbound, native form (bare metal)"
log "Mode: $MODE (mirrors pihole_unbound_${MODE}.yml)"
log "════════════════════════════════════════════════════════════════"
log "  *** DNS WARNING: this host's resolver is rebuilt while this"
log "      script runs. Work the secondary (pi0) first, verify, then"
log "      the primary (pi4). ***"
log "Step 1 of 8: update the system and install the package set"
log "Step 2 of 8: download Pi-hole's installer and verify its SHA-256"
if [[ $MODE == "attended" ]]; then
    log "Step 3 of 8: pause for the manual Pi-hole install, then verify it"
else
    log "Step 3 of 8: run Pi-hole's installer with --unattended"
fi
log "Step 4 of 8: point Pi-hole at the local Unbound (127.0.0.1#5335)"
log "Step 5 of 8: initialize blocklists (pihole-init-blocklists.sh)"
log "Step 6 of 8: deploy the Unbound configuration"
log "Step 7 of 8: ensure Unbound's root anchor (DNSSEC trust anchor)"
log "Step 8 of 8: apply the closing restarts and verify the end state"
log "PRESERVED: any existing setupVars.conf, Unbound config, and root"
log "anchor are respected per the idempotence gates in the header."
log ""

# ───────────────────────────────────────────────────────────────────────────
# Pre-flight
# ───────────────────────────────────────────────────────────────────────────

require_root

OS_ID="" OS_ID_LIKE=""
if [[ -r /etc/os-release ]]; then
    OS_ID=$(grep '^ID=' /etc/os-release | head -n 1 | cut -d= -f2- | tr -d '"')
    OS_ID_LIKE=$(grep '^ID_LIKE=' /etc/os-release | head -n 1 | cut -d= -f2- | tr -d '"')
fi
case " $OS_ID $OS_ID_LIKE " in
    *" debian "*) ;;
    *) die "this installer mirrors the playbooks, which gate on the Debian OS family; this host reports ID='$OS_ID' ID_LIKE='$OS_ID_LIKE'" ;;
esac

[[ -f $UNBOUND_CONF_SRC ]] || die "Unbound config source not found: $UNBOUND_CONF_SRC (run from a repo checkout, or pass --unbound-conf PATH)"
[[ -f $BLOCKLIST_INIT ]] || die "blocklist initializer not found beside this script: $BLOCKLIST_INIT"

# ───────────────────────────────────────────────────────────────────────────
# Step 1: system update and packages (playbooks: apt update_cache,
# upgrade dist, then curl, sudo, unbound, unbound-anchor)
# ───────────────────────────────────────────────────────────────────────────

log "Step 1 of 8: update the system and install the package set"
act "refresh package lists" apt-get update || die "apt-get update failed"
act "dist upgrade (mirrors the playbooks)" apt-get dist-upgrade -y || die "apt-get dist-upgrade failed"
act "install packages" apt-get install -y "${PACKAGES[@]}" || die "package installation failed"

# ───────────────────────────────────────────────────────────────────────────
# Step 2: download the vendor installer and verify the pinned SHA-256
# (playbooks: get_url with checksum, mode 0755)
# ───────────────────────────────────────────────────────────────────────────

log "Step 2 of 8: download Pi-hole's installer and verify its SHA-256"
if [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] curl -fsSL $PIHOLE_INSTALL_URL -o $PIHOLE_INSTALL_TMP"
    log "  [dry-run] chmod 0755 $PIHOLE_INSTALL_TMP"
    log "  [dry-run] verify sha256 equals $EXPECTED_SHA256"
else
    act "download the Pi-hole installer" curl -fsSL "$PIHOLE_INSTALL_URL" -o "$PIHOLE_INSTALL_TMP" || die "download of $PIHOLE_INSTALL_URL failed"
    act "make the installer executable" chmod 0755 "$PIHOLE_INSTALL_TMP" || die "chmod on $PIHOLE_INSTALL_TMP failed"
    ACTUAL_SHA256=$(sha256sum "$PIHOLE_INSTALL_TMP" | awk '{print $1}')
    if [[ $ACTUAL_SHA256 != "$EXPECTED_SHA256" ]]; then
        die "installer checksum mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256. Upstream updates this file in place; nothing was executed. Review the new file, then re-pin with --installer-sha256 $ACTUAL_SHA256 and update the pin in this script and both playbooks."
    fi
    log "  checksum verified: $ACTUAL_SHA256"
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 3: Pi-hole's own installer (playbooks: command with creates
# gate in automated mode; debug + pause + stat-verify in attended mode)
# ───────────────────────────────────────────────────────────────────────────

log "Step 3 of 8: Pi-hole's own installer ($MODE mode)"
if [[ $MODE == "unattended" ]]; then
    if path_present "$SETUPVARS"; then
        log "  skip  $SETUPVARS already exists; Pi-hole is installed"
        log "        (the playbook's creates gate makes this a no-op)"
    else
        act "run the Pi-hole installer unattended" "$PIHOLE_INSTALL_TMP" --unattended || die "the Pi-hole installer failed"
    fi
else
    log "  ======================================================="
    log "  ||        ACTION REQUIRED: Install Pi-hole Manually  ||"
    log "  ======================================================="
    log ""
    log "  Pi-hole's interactive installer is ready at:"
    log "    $PIHOLE_INSTALL_TMP"
    log ""
    log "  1. Open a new terminal session and SSH into this machine."
    log "  2. Run the Pi-hole installer:"
    log "       sudo bash $PIHOLE_INSTALL_TMP"
    log "  3. Follow the on-screen prompts. IMPORTANT: when prompted"
    log "     for upstream DNS, choose a public DNS provider for now"
    log "     (e.g. Google, Cloudflare, OpenDNS). This script switches"
    log "     Pi-hole to the local Unbound afterwards."
    log "  4. Return here and press Enter to continue."
    log ""
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [dry-run] pause skipped; the verification below is also skipped"
    else
        if [[ -e /dev/tty ]]; then
            read -r _ < /dev/tty || true
        else
            read -r _ || true
        fi
        if ! path_present "$SETUPVARS"; then
            die "Pi-hole installation not found: $SETUPVARS does not exist after the attended pause. The attended playbook fails at the same check. Complete the manual install, then re-run this script."
        fi
        log "  Pi-hole installation confirmed ($SETUPVARS exists)."
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 4: point Pi-hole at the local Unbound (playbooks: lineinfile
# PIHOLE_DNS_1, notify Restart Pi-hole DNS)
# ───────────────────────────────────────────────────────────────────────────

log "Step 4 of 8: point Pi-hole at the local Unbound (127.0.0.1#5335)"
DNS_CHANGED=0
if [[ $DRY_RUN -eq 1 ]]; then
    if path_present "$SETUPVARS" && grep -Fxq "$UPSTREAM_LINE" "$SETUPVARS"; then
        log "  [dry-run] $SETUPVARS already carries $UPSTREAM_LINE; no change"
    else
        log "  [dry-run] would set $UPSTREAM_LINE in $SETUPVARS"
        DNS_CHANGED=1
    fi
else
    [[ -f $SETUPVARS ]] || die "$SETUPVARS missing after step 3; cannot set the upstream"
    if grep -Fxq "$UPSTREAM_LINE" "$SETUPVARS"; then
        log "  skip  $UPSTREAM_LINE already set in $SETUPVARS"
    elif grep -q '^PIHOLE_DNS_1=' "$SETUPVARS"; then
        act "replace the PIHOLE_DNS_1 line" sed -i "s|^PIHOLE_DNS_1=.*|$UPSTREAM_LINE|" "$SETUPVARS" || die "editing $SETUPVARS failed"
        DNS_CHANGED=1
    else
        printf '%s\n' "$UPSTREAM_LINE" >> "$SETUPVARS" || die "editing $SETUPVARS failed"
        log "  run: appended $UPSTREAM_LINE to $SETUPVARS"
        DNS_CHANGED=1
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 5: blocklists (playbooks: pihole -a -i the OISD list, then
# pihole -g; here delegated to the sibling initializer, which seeds
# OISD plus the Hagezi set and runs gravity itself)
# ───────────────────────────────────────────────────────────────────────────

log "Step 5 of 8: initialize blocklists (pihole-init-blocklists.sh)"
note "the initializer seeds the playbooks' OISD list plus the Hagezi"
note "lists the container form uses, then updates gravity."
if [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] $BLOCKLIST_INIT"
else
    act "initialize blocklists and update gravity" "$BLOCKLIST_INIT" || die "blocklist initialization failed (it needs /etc/pihole/gravity.db from step 3)"
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 6: deploy the Unbound configuration (playbooks: copy
# unbound.conf, mode 0644, notify Restart Unbound service)
# ───────────────────────────────────────────────────────────────────────────

log "Step 6 of 8: deploy the Unbound configuration"
UNBOUND_CHANGED=0
act "ensure the Unbound config directory" mkdir -p /etc/unbound || die "cannot create /etc/unbound"
if cmp -s "$UNBOUND_CONF_SRC" "$UNBOUND_CONF_DEST" 2>/dev/null; then
    log "  skip  $UNBOUND_CONF_DEST already matches the playbooks' unbound.conf"
else
    act "deploy the Unbound configuration" install -m 0644 "$UNBOUND_CONF_SRC" "$UNBOUND_CONF_DEST" || die "deploying $UNBOUND_CONF_DEST failed"
    UNBOUND_CHANGED=1
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 7: root anchor (playbooks: unbound-anchor with creates gate,
# notify Restart Unbound service)
# ───────────────────────────────────────────────────────────────────────────

log "Step 7 of 8: ensure Unbound's root anchor (DNSSEC trust anchor)"
ANCHOR_RAN=0
act "ensure the Unbound state directory" mkdir -p /var/lib/unbound || die "cannot create /var/lib/unbound"
if path_present "$ROOT_KEY"; then
    log "  skip  $ROOT_KEY already exists (the playbook's creates gate)"
elif [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] unbound-anchor -a $ROOT_KEY"
    ANCHOR_RAN=1
else
    act "fetch the root anchor" unbound-anchor -a "$ROOT_KEY" || die "unbound-anchor failed"
    ANCHOR_RAN=1
fi

# ───────────────────────────────────────────────────────────────────────────
# Step 8: closing restarts (the playbooks' handlers, in their
# definition order) and the verification pass
# ───────────────────────────────────────────────────────────────────────────

log "Step 8 of 8: apply the closing restarts and verify the end state"
if [[ $DNS_CHANGED -eq 1 ]]; then
    act_soft "restart Pi-hole DNS (handler)" pihole restartdns
else
    log "  skip  Pi-hole DNS restart (upstream unchanged; the handler would not fire)"
fi
if [[ $UNBOUND_CHANGED -eq 1 || $ANCHOR_RAN -eq 1 ]]; then
    act_soft "enable Unbound (handler)" systemctl enable unbound
    act_soft "restart Unbound (handler)" systemctl restart unbound
else
    log "  skip  Unbound restart (config and anchor unchanged; the handler would not fire)"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    log "Dry run complete: the plan and every command above were printed;"
    log "nothing was downloaded, installed, written, or restarted."
    exit 0
fi

FAILED=0
grep -Fxq "$UPSTREAM_LINE" "$SETUPVARS" || { log "  LEFTOVER: $SETUPVARS does not carry $UPSTREAM_LINE"; FAILED=1; }
cmp -s "$UNBOUND_CONF_SRC" "$UNBOUND_CONF_DEST" || { log "  LEFTOVER: $UNBOUND_CONF_DEST does not match the playbooks' unbound.conf"; FAILED=1; }
path_present "$ROOT_KEY" || { log "  LEFTOVER: $ROOT_KEY missing"; FAILED=1; }
path_present /etc/pihole/gravity.db || { log "  LEFTOVER: /etc/pihole/gravity.db missing (blocklist state)"; FAILED=1; }
if [[ $FAILED -eq 1 ]]; then
    log "Verification FAILED: the end state above is incomplete."
    exit 1
fi
log "Verification passed: upstream set, Unbound configured, anchor in place."

log ""
log "════════════════════════════════════════════════════════════════"
log "DONE: Pi-hole + Unbound installed (native form, $MODE mode)."
log "  DNS:        this host, port 53 (Pi-hole; upstream Unbound"
log "              at 127.0.0.1 port 5335)"
log "  Config:     $SETUPVARS (upstream $UPSTREAM_LINE)"
log "              $UNBOUND_CONF_DEST (from ansible/playbooks/pihole/)"
log "  Lifecycle:  ${SCRIPT_DIR}/pihole-control-v1.0.sh status --form native"
log "  Full check: ${SCRIPT_DIR}/dns-test-pihole-unbound-linted.sh"
log "════════════════════════════════════════════════════════════════"
