#!/usr/bin/env bash
#
# fleet-firewall.sh — bash form of the fleet host firewall configuration.
#
# Ansible forms (ansible/playbooks/firewall/):
#   firewall_local_pi.yml   -> --profile pi        (the fleet default)
#   firewall_local_new.yml  -> --profile new       (pi list + 853/tcp)
#   default-firewalld.yml   -> --profile baseline  (firewalld hosts only)
#
# Runs ON the target host as root, like the per-workstation firewall
# scripts in this folder and the neo1 kits' ufw.sh. The tool is chosen by
# OS family exactly as the playbooks choose it: Debian family -> UFW,
# RedHat family -> firewalld (Rocky hosts pi1/pi3; Debian/RPiOS hosts
# pi0/pi2/pi4/neo1). Docker is not applicable: this configures the host's
# own firewall.
#
# Semantics mirrored from the playbooks:
#   - SSH (22/tcp) is allowed FIRST on the UFW path, before any policy
#     change, specifically to prevent a lockout.
#   - UFW defaults: deny incoming, allow outgoing; UFW is force-enabled
#     only after the rules are in place.
#   - firewalld rules are permanent and immediate in the zone (default
#     public, override with --zone), with one reload at the end when
#     anything changed (the playbooks' handler).
#   - After applying, an SSH lockout probe runs: port 22 must be covered
#     by the resulting ruleset. A failed probe warns; with
#     --fail-on-probe-failure it aborts the run (the playbooks'
#     fail_on_probe_failure toggle).
#
# Idempotent: every rule is checked before it is added; re-running
# changes nothing. Modes:
#   (default)    apply the profile
#   --dry-run    print what would change; change nothing
#   --verify     diff live rules against the profile; exit 1 on drift
#
# Usage:
#   sudo ./fleet-firewall.sh [--profile pi|new|baseline] [--zone public]
#   sudo ./fleet-firewall.sh --verify
#   sudo ./fleet-firewall.sh --dry-run
#
# Environment: LOG_FILE (default /var/log/fleet-firewall.log),
# FLEET_FW_OS_FAMILY (debian|redhat; overrides OS detection, for tests).
set -euo pipefail

SCRIPT_VERSION="1.1"
LOG_FILE="${LOG_FILE:-/var/log/fleet-firewall.log}"
PROFILE="pi"; PROFILE_GIVEN=false
ZONE="public"
MODE="apply"
FAIL_ON_PROBE_FAILURE=false

usage() {
    cat <<'EOF'
Usage: fleet-firewall.sh [--profile pi|new|baseline] [options]

Bash form of ansible/playbooks/firewall/. Run on the host as root.

  --profile pi|new|baseline  Rule set (default pi = firewall_local_pi.yml)
  --zone ZONE                firewalld zone (default public)
  --dry-run                  Print changes; change nothing
  --verify                   Diff live rules against the profile; exit 1 on drift
  --fail-on-probe-failure    Abort if the post-apply SSH probe fails
  -h, --help                 This help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; PROFILE_GIVEN=true; shift 2 ;;
        --zone) ZONE="$2"; shift 2 ;;
        --dry-run) MODE="dry-run"; shift ;;
        --verify) MODE="verify"; shift ;;
        --fail-on-probe-failure) FAIL_ON_PROBE_FAILURE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── Profile picker panel (added entry path, TTY only) ─────────────────────
# With --profile absent on a terminal, a one-of panel offers the three
# profiles defined below and writes the chosen one into PROFILE, the
# same variable --profile writes; the value then passes the validation
# and every code path below exactly as a flag value does. With
# --profile given in any form, with no terminal, or with TERM=dumb,
# the script takes the paths it has always taken, byte for byte. Pure
# bash and ANSI, in the repo's panel conventions: an ASCII frame, a
# reverse-video cursor row, the cursor hidden while the panel is
# drawn and restored on every exit from it, and a trap on INT/TERM
# that restores the cursor and exits 130. The panel only chooses; it
# reimplements no profile. Rows marked * are the profiles whose UFW
# path also sets the default policies (deny incoming, allow
# outgoing); baseline never touches them. q or EOF cancels: the
# script exits 0 having run nothing.
PANEL_PROFILES=(pi new baseline)
PANEL_ROWS=(
    "pi - fleet default (firewall_local_pi.yml): TCP 53 80 443 9090, UDP 53 *"
    "new - pi list plus TCP 853, DNS-over-TLS (firewall_local_new.yml) *"
    "baseline - firewalld only (default-firewalld.yml): ssh http https, 8080/tcp, 5000-5010/udp, cockpit removed"
)
PANEL_CURSOR=0
PANEL_FIRST=1
PANEL_FRAME_LINES=0

panel_erase() {
    local i
    printf '\033[%dA' "$PANEL_FRAME_LINES"
    for ((i = 0; i < PANEL_FRAME_LINES; i++)); do
        printf '\033[2K'
        if [[ $i -lt $((PANEL_FRAME_LINES - 1)) ]]; then
            printf '\n'
        fi
    done
    printf '\033[%dA' $((PANEL_FRAME_LINES - 1))
    printf '\033[?25h'
}

panel_draw() {
    local -a frame=()
    local line="" dashes="" border=""
    local width=44 len i mark=""
    local title="fleet-firewall v$SCRIPT_VERSION: choose a profile"
    local note="* UFW path also sets the default policies: deny incoming, allow outgoing"
    local keys="arrows or j/k move, enter selects, q cancels"
    for line in "$title" "$note" "$keys" "${PANEL_ROWS[@]}"; do
        len=${#line}
        if [[ $len -gt $width ]]; then
            width=$len
        fi
    done
    printf -v dashes '%*s' $((width + 2)) ''
    dashes="${dashes// /-}"
    border="+${dashes}+"
    frame+=("$border")
    printf -v line '| %-*s |' "$width" "$title"
    frame+=("$line")
    frame+=("$border")
    for i in "${!PANEL_ROWS[@]}"; do
        mark="  "
        if [[ $i -eq $PANEL_CURSOR ]]; then
            mark="> "
        fi
        printf -v line '| %-*s |' "$width" "${mark}${PANEL_ROWS[$i]}"
        frame+=("$line")
    done
    frame+=("$border")
    printf -v line '| %-*s |' "$width" "$note"
    frame+=("$line")
    printf -v line '| %-*s |' "$width" "$keys"
    frame+=("$line")
    frame+=("$border")
    PANEL_FRAME_LINES=${#frame[@]}
    if [[ $PANEL_FIRST -eq 1 ]]; then
        PANEL_FIRST=0
    else
        printf '\033[%dA' "${#frame[@]}"
    fi
    for i in "${!frame[@]}"; do
        if [[ $i -eq $((PANEL_CURSOR + 3)) ]]; then
            printf '\r\033[7m%s\033[0m\n' "${frame[$i]}"
        else
            printf '\r%s\n' "${frame[$i]}"
        fi
    done
}

profile_pick_panel() {
    local key="" rest=""
    PANEL_CURSOR=0
    PANEL_FIRST=1
    printf '\033[?25l'
    trap 'printf "\033[?25h" >&2; exit 130' INT TERM
    while true; do
        panel_draw
        if ! IFS= read -rsn1 key; then
            key="q"
        fi
        if [[ $key == $'\033' ]]; then
            IFS= read -rsn2 -t 0.1 rest || rest=""
            key="${key}${rest}"
        fi
        case $key in
            $'\033[A' | k)
                PANEL_CURSOR=$(((PANEL_CURSOR + 2) % 3))
                ;;
            $'\033[B' | j)
                PANEL_CURSOR=$(((PANEL_CURSOR + 1) % 3))
                ;;
            q)
                panel_erase
                trap - INT TERM
                echo "Profile picker cancelled; nothing was applied."
                exit 0
                ;;
            '' | $'\n' | $'\r')
                PROFILE="${PANEL_PROFILES[$PANEL_CURSOR]}"
                panel_erase
                trap - INT TERM
                return 0
                ;;
        esac
    done
}

if [[ $PROFILE_GIVEN == false && -t 0 && -t 1 && -n ${TERM:-} && $TERM != "dumb" ]]; then
    profile_pick_panel
fi

case "$PROFILE" in pi|new|baseline) ;; *) echo "ERROR: unknown profile: $PROFILE" >&2; exit 2 ;; esac

# ── Profiles (port lists copied from the playbooks) ──────────────────────────
TCP_PORTS=()
UDP_PORTS=()
BASELINE_SERVICES=()
BASELINE_PORTS=()
BASELINE_REMOVE_SERVICES=()
case "$PROFILE" in
    pi)  # firewall_local_pi.yml
        TCP_PORTS=(53 80 443 9090)
        UDP_PORTS=(53)
        ;;
    new) # firewall_local_new.yml (pi list + DNS-over-TLS)
        TCP_PORTS=(53 80 443 853 9090)
        UDP_PORTS=(53)
        ;;
    baseline) # default-firewalld.yml
        BASELINE_SERVICES=(ssh http https)
        BASELINE_PORTS=("8080/tcp" "5000-5010/udp")
        BASELINE_REMOVE_SERVICES=(cockpit)
        ;;
esac

# ── Logging ──────────────────────────────────────────────────────────────────
log() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        echo "[$ts] $*" | tee -a "$LOG_FILE"
    else
        echo "[$ts] $*"
    fi
}
die() { log "ERROR: $*"; exit 1; }
CHANGED=0
note_change() { CHANGED=1; log "  changed: $*"; }
note_ok() { log "  ok: $*"; }
would() { log "  [dry-run] would: $*"; }

# ── OS family (playbooks branch on ansible_os_family) ────────────────────────
detect_family() {
    if [[ -n "${FLEET_FW_OS_FAMILY:-}" ]]; then
        echo "$FLEET_FW_OS_FAMILY"; return 0
    fi
    local id="" like=""
    if [[ -r /etc/os-release ]]; then
        id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
        like="$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    fi
    case " $id $like " in
        *" debian "*|*" ubuntu "*|*" raspbian "*) echo "debian" ;;
        *" rhel "*|*" fedora "*|*" rocky "*|*" centos "*) echo "redhat" ;;
        *) return 1 ;;
    esac
}
OS_FAMILY="$(detect_family)" || die "cannot determine OS family from /etc/os-release (set FLEET_FW_OS_FAMILY=debian|redhat)"

if [[ "$PROFILE" == "baseline" && "$OS_FAMILY" != "redhat" ]]; then
    die "profile baseline is firewalld-only (default-firewalld.yml) but this host is $OS_FAMILY family"
fi

if [[ "$MODE" == "apply" && $EUID -ne 0 ]]; then
    die "apply mode must run as root"
fi

log "fleet-firewall v$SCRIPT_VERSION profile=$PROFILE family=$OS_FAMILY mode=$MODE zone=$ZONE"

# ═══ UFW (Debian family) ═════════════════════════════════════════════════════
ufw_status() { ufw status 2>/dev/null || true; }
ufw_status_verbose() { ufw status verbose 2>/dev/null || true; }

ufw_has_rule() { # port proto
    local st; st="$(ufw_status)"
    local lines
    lines="$(grep -E "^$1/$2[[:space:]]" <<< "$st" || true)"
    grep -q "ALLOW" <<< "$lines"
}

ufw_defaults_ok() {
    local st; st="$(ufw_status_verbose)"
    grep -q "deny (incoming)" <<< "$st" \
        && grep -q "allow (outgoing)" <<< "$st"
}

ufw_active() {
    local st; st="$(ufw_status)"
    grep -q "^Status: active" <<< "$st"
}

ufw_apply() {
    if ! command -v ufw >/dev/null 2>&1; then
        if [[ "$MODE" == "dry-run" ]]; then would "apt-get install ufw"; else
            log "Installing UFW..."
            apt-get update -qq || die "apt-get update failed"
            apt-get install -y ufw || die "UFW installation failed"
        fi
    fi

    # SSH first — before any policy change (lockout prevention).
    if ufw_has_rule 22 tcp; then note_ok "22/tcp already allowed"
    elif [[ "$MODE" == "dry-run" ]]; then would "ufw allow 22/tcp (SSH, first)"
    else ufw allow 22/tcp >/dev/null || die "failed to allow 22/tcp"; note_change "ufw allow 22/tcp"; fi

    # Default policies.
    if ufw_defaults_ok; then note_ok "defaults already deny incoming / allow outgoing"
    elif [[ "$MODE" == "dry-run" ]]; then would "ufw default deny incoming; ufw default allow outgoing"
    else
        ufw default deny incoming >/dev/null || die "failed to set default deny incoming"
        ufw default allow outgoing >/dev/null || die "failed to set default allow outgoing"
        note_change "ufw defaults deny incoming / allow outgoing"
    fi

    local p
    for p in "${TCP_PORTS[@]}"; do
        if ufw_has_rule "$p" tcp; then note_ok "$p/tcp already allowed"
        elif [[ "$MODE" == "dry-run" ]]; then would "ufw allow $p/tcp"
        else ufw allow "$p/tcp" >/dev/null || die "failed to allow $p/tcp"; note_change "ufw allow $p/tcp"; fi
    done
    for p in "${UDP_PORTS[@]}"; do
        if ufw_has_rule "$p" udp; then note_ok "$p/udp already allowed"
        elif [[ "$MODE" == "dry-run" ]]; then would "ufw allow $p/udp"
        else ufw allow "$p/udp" >/dev/null || die "failed to allow $p/udp"; note_change "ufw allow $p/udp"; fi
    done

    # Enable only after the rules are in place.
    if ufw_active; then note_ok "UFW already active"
    elif [[ "$MODE" == "dry-run" ]]; then would "ufw --force enable"
    else ufw --force enable >/dev/null || die "failed to enable UFW"; note_change "ufw enabled"; fi
}

ufw_verify() {
    local drift=0 p
    ufw_has_rule 22 tcp || { log "  DRIFT: 22/tcp not allowed"; drift=1; }
    for p in "${TCP_PORTS[@]}"; do
        ufw_has_rule "$p" tcp || { log "  DRIFT: $p/tcp not allowed"; drift=1; }
    done
    for p in "${UDP_PORTS[@]}"; do
        ufw_has_rule "$p" udp || { log "  DRIFT: $p/udp not allowed"; drift=1; }
    done
    ufw_defaults_ok || { log "  DRIFT: defaults are not deny incoming / allow outgoing"; drift=1; }
    ufw_active || { log "  DRIFT: UFW is not active"; drift=1; }
    return $drift
}

ufw_probe_ok() { ufw_has_rule 22 tcp; }

# ═══ firewalld (RedHat family) ═══════════════════════════════════════════════
fw_has_port() { # port/proto (permanent ruleset, as the playbooks manage it)
    firewall-cmd --permanent --zone="$ZONE" --query-port="$1" >/dev/null 2>&1
}
fw_has_service() {
    firewall-cmd --permanent --zone="$ZONE" --query-service="$1" >/dev/null 2>&1
}

fw_apply() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        if [[ "$MODE" == "dry-run" ]]; then would "install firewalld"
        else
            log "Installing firewalld..."
            dnf install -y firewalld || die "firewalld installation failed"
        fi
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        would "systemctl enable --now firewalld (if not already)"
    else
        systemctl enable firewalld >/dev/null 2>&1 || die "failed to enable firewalld"
        if ! systemctl is-active --quiet firewalld; then
            systemctl start firewalld || die "failed to start firewalld"
        fi
    fi

    if [[ "$PROFILE" == "baseline" ]]; then
        fw_apply_baseline
        return 0
    fi

    local p
    for p in "${TCP_PORTS[@]}"; do
        if fw_has_port "$p/tcp"; then note_ok "$p/tcp already open (permanent, zone $ZONE)"
        elif [[ "$MODE" == "dry-run" ]]; then would "firewall-cmd --permanent --zone=$ZONE --add-port=$p/tcp (+ runtime)"
        else
            firewall-cmd --permanent --zone="$ZONE" --add-port="$p/tcp" >/dev/null || die "failed to add $p/tcp"
            firewall-cmd --zone="$ZONE" --add-port="$p/tcp" >/dev/null || die "failed to add $p/tcp (runtime)"
            note_change "firewalld add $p/tcp"
        fi
    done
    for p in "${UDP_PORTS[@]}"; do
        if fw_has_port "$p/udp"; then note_ok "$p/udp already open (permanent, zone $ZONE)"
        elif [[ "$MODE" == "dry-run" ]]; then would "firewall-cmd --permanent --zone=$ZONE --add-port=$p/udp (+ runtime)"
        else
            firewall-cmd --permanent --zone="$ZONE" --add-port="$p/udp" >/dev/null || die "failed to add $p/udp"
            firewall-cmd --zone="$ZONE" --add-port="$p/udp" >/dev/null || die "failed to add $p/udp (runtime)"
            note_change "firewalld add $p/udp"
        fi
    done

    if [[ $CHANGED -eq 1 && "$MODE" != "dry-run" ]]; then
        firewall-cmd --reload >/dev/null || die "firewalld reload failed"
        log "firewalld reloaded"
    fi
}

fw_apply_baseline() {
    # default-firewalld.yml: public is the default zone.
    local cur="public"
    cur="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
    if [[ "$cur" == "public" ]]; then note_ok "default zone already public"
    elif [[ "$MODE" == "dry-run" ]]; then would "firewall-cmd --set-default-zone=public"
    else firewall-cmd --set-default-zone=public >/dev/null || die "failed to set default zone"; note_change "default zone public"; fi

    local s
    for s in "${BASELINE_SERVICES[@]}"; do
        if fw_has_service "$s"; then note_ok "service $s already enabled"
        elif [[ "$MODE" == "dry-run" ]]; then would "firewall-cmd --permanent --zone=$ZONE --add-service=$s (+ runtime)"
        else
            firewall-cmd --permanent --zone="$ZONE" --add-service="$s" >/dev/null || die "failed to add service $s"
            firewall-cmd --zone="$ZONE" --add-service="$s" >/dev/null || die "failed to add service $s (runtime)"
            note_change "firewalld add service $s"
        fi
    done
    local pp
    for pp in "${BASELINE_PORTS[@]}"; do
        if fw_has_port "$pp"; then note_ok "$pp already open"
        elif [[ "$MODE" == "dry-run" ]]; then would "firewall-cmd --permanent --zone=$ZONE --add-port=$pp (+ runtime)"
        else
            firewall-cmd --permanent --zone="$ZONE" --add-port="$pp" >/dev/null || die "failed to add $pp"
            firewall-cmd --zone="$ZONE" --add-port="$pp" >/dev/null || die "failed to add $pp (runtime)"
            note_change "firewalld add $pp"
        fi
    done
    for s in "${BASELINE_REMOVE_SERVICES[@]}"; do
        if ! fw_has_service "$s"; then note_ok "service $s already absent"
        elif [[ "$MODE" == "dry-run" ]]; then would "firewall-cmd --permanent --zone=$ZONE --remove-service=$s (+ runtime)"
        else
            firewall-cmd --permanent --zone="$ZONE" --remove-service="$s" >/dev/null || die "failed to remove service $s"
            firewall-cmd --zone="$ZONE" --remove-service="$s" >/dev/null || true
            note_change "firewalld remove service $s"
        fi
    done

    if [[ $CHANGED -eq 1 && "$MODE" != "dry-run" ]]; then
        firewall-cmd --reload >/dev/null || die "firewalld reload failed"
        log "firewalld reloaded"
    fi
}

fw_verify() {
    local drift=0
    if [[ "$PROFILE" == "baseline" ]]; then
        local cur s pp
        cur="$(firewall-cmd --get-default-zone 2>/dev/null || echo '?')"
        [[ "$cur" == "public" ]] || { log "  DRIFT: default zone is $cur, not public"; drift=1; }
        for s in "${BASELINE_SERVICES[@]}"; do
            fw_has_service "$s" || { log "  DRIFT: service $s not enabled"; drift=1; }
        done
        for pp in "${BASELINE_PORTS[@]}"; do
            fw_has_port "$pp" || { log "  DRIFT: $pp not open"; drift=1; }
        done
        for s in "${BASELINE_REMOVE_SERVICES[@]}"; do
            fw_has_service "$s" && { log "  DRIFT: service $s present but profile removes it"; drift=1; }
        done
        return $drift
    fi
    local p
    for p in "${TCP_PORTS[@]}"; do
        fw_has_port "$p/tcp" || { log "  DRIFT: $p/tcp not open (permanent, zone $ZONE)"; drift=1; }
    done
    for p in "${UDP_PORTS[@]}"; do
        fw_has_port "$p/udp" || { log "  DRIFT: $p/udp not open (permanent, zone $ZONE)"; drift=1; }
    done
    return $drift
}

fw_probe_ok() {
    # SSH counts as covered when 22/tcp is open or the ssh service is on.
    fw_has_port "22/tcp" || fw_has_service "ssh"
}

# ═══ Dispatch ════════════════════════════════════════════════════════════════
case "$MODE" in
    verify)
        if [[ "$OS_FAMILY" == "debian" ]]; then
            if ufw_verify; then log "VERIFY OK: live UFW rules match profile $PROFILE"; else die "VERIFY FAILED: live UFW rules drift from profile $PROFILE"; fi
        else
            if fw_verify; then log "VERIFY OK: live firewalld rules match profile $PROFILE"; else die "VERIFY FAILED: live firewalld rules drift from profile $PROFILE"; fi
        fi
        ;;
    apply|dry-run)
        if [[ "$OS_FAMILY" == "debian" ]]; then ufw_apply; else fw_apply; fi
        if [[ "$MODE" == "dry-run" ]]; then
            log "DRY-RUN complete: nothing was changed"
            exit 0
        fi
        # Lockout safety probe (the playbooks' post-change SSH probe,
        # evaluated against the resulting local ruleset).
        probe_ok=false
        if [[ "$OS_FAMILY" == "debian" ]]; then
            ufw_probe_ok && probe_ok=true
        else
            fw_probe_ok && probe_ok=true
        fi
        if $probe_ok; then
            log "SSH probe: port 22 is covered by the resulting ruleset"
        elif $FAIL_ON_PROBE_FAILURE; then
            die "SSH probe failed: port 22 is not covered after applying profile $PROFILE — aborting"
        else
            log "WARNING: SSH probe failed: port 22 is not covered by the resulting ruleset. Verify out-of-band access before proceeding."
        fi
        if [[ $CHANGED -eq 1 ]]; then log "Apply complete: profile $PROFILE (changes made)"; else log "Apply complete: profile $PROFILE (already converged)"; fi
        ;;
esac
