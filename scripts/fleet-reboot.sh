#!/usr/bin/env bash
#
# fleet-reboot.sh — bash form of the fleet reboot playbooks.
#
# Ansible forms: ansible/playbooks/reboots/reboot_complex.yml (default
# here) and reboot_simple.yml (--simple). Docker is not applicable:
# rebooting a host is an operation on the host itself.
#
# Semantics mirrored from the playbooks:
#   - Hosts are rebooted one at a time, in inventory order, and each host
#     must be verified back before the next one is touched. (The playbooks
#     set no pre/post-reboot delays; serial-with-verification is the
#     staggering the bash form applies.)
#   - Complex (default): a pre-check runs `uptime` on the host first. If
#     it errors, that host is NOT rebooted and the run aborts. The uptime
#     output is printed, as in the playbook.
#   - The reboot waits up to --reboot-timeout seconds (playbook default
#     600) for the host to come back, and confirms the return by running
#     the playbook's test command, `whoami`, over a fresh SSH connection.
#     The bash form also requires the kernel boot ID to have changed, so
#     a host that never actually went down is not counted as rebooted.
#   - Simple (--simple): no pre-check, exactly like reboot_simple.yml;
#     the wait and whoami confirmation still apply.
#   - Any failure aborts the run (remaining hosts are left untouched)
#     unless --continue-on-error is given.
#   - Only Debian/RedHat family hosts are rebooted (the playbooks' `when`
#     condition): the host's OS family is read from /etc/os-release over
#     SSH and any other family is skipped with an error.
#
# The monthly maintenance wrapper (scripts/run_monthly_maintenance.sh)
# reboots pi0, pi2, pi3, and pi4 with the simple playbook; the bash
# equivalent is:
#   ./scripts/fleet-reboot.sh --simple --limit pi0,pi2,pi3,pi4
#
# Usage (from the repo root):
#   ./scripts/fleet-reboot.sh                      # complex, all of pi_all
#   ./scripts/fleet-reboot.sh --limit pi4          # one host
#   ./scripts/fleet-reboot.sh --dry-run            # pre-checks + plan only
#
# Run without --limit on a terminal, the bare form opens a
# host-selection panel over the [pi_all] hosts (checkboxes, all
# starting checked: the no-limit meaning) to build the host set
# instead of taking the whole group sight unseen. The panel only
# selects; it never authorizes a reboot. A confirmed selection
# still stops for an explicit typed confirmation (the word
# "reboot") before the first host is touched, and declining it
# reboots nothing. Off a terminal (or with TERM=dumb) the bare
# form keeps its long-standing meaning exactly: all of pi_all,
# no panel, no confirmation. The --limit path and the Ansible
# forms are untouched by any of this.
#
# Environment: SSH_KEY (default ~/.ssh/pi_cluster_key), SSH_USER (default
# michael, the inventory user; the reboot itself goes through sudo),
# SSH_PORT (default 22), SSH_BIN (default ssh; a test double may be
# substituted).
set -euo pipefail

SCRIPT_VERSION="1.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_INVENTORY="$REPO_ROOT/ansible/hosts"

INVENTORY="$DEFAULT_INVENTORY"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pi_cluster_key}"
SSH_USER="${SSH_USER:-michael}"
SSH_PORT="${SSH_PORT:-22}"
SSH_BIN="${SSH_BIN:-ssh}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
LIMIT=""
MODE="complex"
DRY_RUN=false
CONTINUE_ON_ERROR=false
REBOOT_TIMEOUT=600
DOWN_TIMEOUT=120
POLL_INTERVAL=5

usage() {
    cat <<'EOF'
Usage: fleet-reboot.sh [options]

Reboot fleet hosts one at a time over SSH, verifying each host returns
before touching the next. Bash form of ansible/playbooks/reboots/.

Options:
  --limit h1,h2           Only these hosts (default: all of pi_all)
  --simple                Mirror reboot_simple.yml (no uptime pre-check)
  --complex               Mirror reboot_complex.yml (default)
  --reboot-timeout SECS   Max wait for a host to return (default 600)
  --down-timeout SECS     Max wait for a host to go down (default 120)
  --poll-interval SECS    Poll interval while waiting (default 5)
  --continue-on-error     Continue with the next host after a failure
  --inventory FILE        Ansible inventory to read pi_all from
  --ssh-key PATH          Fleet SSH key (default ~/.ssh/pi_cluster_key)
  --dry-run               Run pre-checks and print the plan; reboot nothing
  -h, --help              This help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit) LIMIT="$2"; shift 2 ;;
        --simple) MODE="simple"; shift ;;
        --complex) MODE="complex"; shift ;;
        --reboot-timeout) REBOOT_TIMEOUT="$2"; shift 2 ;;
        --down-timeout) DOWN_TIMEOUT="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
        --inventory) INVENTORY="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

[[ -f "$INVENTORY" ]] || die "inventory not found: $INVENTORY"

# ── Fleet (same inventory parsing as the other fleet bash forms) ─────────────
readarray -t FLEET_HOSTS < <(awk '
    /^\[pi_all\]/{ in_pi=1; next }
    /^\[/{ in_pi=0 }
    in_pi && NF && $0 !~ /^#/ { print $1 }
' "$INVENTORY")
[[ ${#FLEET_HOSTS[@]} -gt 0 ]] || die "no hosts found in [pi_all] of $INVENTORY"

declare -A HOST_IP
while IFS= read -r line; do
    name="${line%% *}"
    if [[ "$line" =~ ansible_host=([^[:space:]]+) ]]; then
        HOST_IP["$name"]="${BASH_REMATCH[1]}"
    else
        HOST_IP["$name"]="$name"
    fi
done < <(awk '
    /^\[pi_all\]/{ in_pi=1; next }
    /^\[/{ in_pi=0 }
    in_pi && NF && $0 !~ /^#/ { print }
' "$INVENTORY")

# ── Host-selection panel ─────────────────────────────────────────────────────
# On a terminal, running without --limit opens a checkbox panel
# over the [pi_all] hosts to build the host set, instead of the
# operator typing the set as a --limit list (where a typo either
# reboots a host that was not meant or dies on an unknown name).
# The panel is an added entry path only, in the repo's panel
# conventions (pure bash and ANSI, no TUI dependency): an ASCII
# frame, a reverse-video cursor row, the cursor hidden while the
# panel is drawn and restored on every exit from it, and a trap
# on INT/TERM that restores the cursor and exits 130. Arrows or
# j/k move, space toggles the host under the cursor, a toggles
# all hosts at once, enter confirms the selection, q cancels.
#
# The panel opens with every host checked, because it stands in
# for the no-limit default, whose meaning is all of pi_all; the
# operator trims from there. The frame always shows how many
# hosts are selected, so an empty selection is visibly empty,
# and enter with zero hosts selected does not confirm: the panel
# stays open with a notice. The caller also dies on an empty
# selection rather than ever treating one as the whole fleet.
#
# SELECTION ONLY: the panel never authorizes a reboot. This
# script has never had a confirmation step on any path, so the
# panel path carries one of its own, after the panel and before
# main: confirm_panel_selection makes the operator type the
# word "reboot" at a plain prompt, and anything else aborts the
# run with nothing rebooted. The confirmation exists only on
# the panel path: --limit runs, off-terminal runs, and TERM=dumb
# runs behave exactly as they always have, byte for byte, and
# never see the panel or the prompt.

HP_ON=()
HP_CURSOR=0
HP_NOTICE=""
HP_FIRST=1
HP_FRAME_LINES=0

host_pick_draw() {
    local -a frame=()
    local line="" dashes="" border=""
    local width=44 len i mark="" box=""
    local total=${#FLEET_HOSTS[@]} picked=0
    local title="fleet-reboot: select hosts"
    local count="" keys1="arrows or j/k move, space toggles,"
    local keys2="a toggles all, enter confirms, q cancels"
    for i in "${!FLEET_HOSTS[@]}"; do
        if [[ "${HP_ON[$i]}" -eq 1 ]]; then
            picked=$((picked + 1))
        fi
    done
    printf -v count '%d of %d hosts selected' "$picked" "$total"
    len=${#title};    [[ $len -gt $width ]] && width=$len
    len=${#count};    [[ $len -gt $width ]] && width=$len
    len=${#keys1};    [[ $len -gt $width ]] && width=$len
    len=${#keys2};    [[ $len -gt $width ]] && width=$len
    len=${#HP_NOTICE}; [[ $len -gt $width ]] && width=$len
    for i in "${!FLEET_HOSTS[@]}"; do
        len=$((6 + ${#FLEET_HOSTS[$i]}))
        [[ $len -gt $width ]] && width=$len
    done
    printf -v dashes '%*s' $((width + 2)) ''
    dashes="${dashes// /-}"
    border="+${dashes}+"
    frame+=("$border")
    printf -v line '| %-*s |' "$width" "$title"
    frame+=("$line")
    frame+=("$border")
    for i in "${!FLEET_HOSTS[@]}"; do
        mark="  "
        if [[ $i -eq $HP_CURSOR ]]; then
            mark="> "
        fi
        box="[ ]"
        if [[ "${HP_ON[$i]}" -eq 1 ]]; then
            box="[x]"
        fi
        printf -v line '| %-*s |' "$width" "${mark}${box} ${FLEET_HOSTS[$i]}"
        frame+=("$line")
    done
    frame+=("$border")
    printf -v line '| %-*s |' "$width" "$count"
    frame+=("$line")
    printf -v line '| %-*s |' "$width" "$keys1"
    frame+=("$line")
    printf -v line '| %-*s |' "$width" "$keys2"
    frame+=("$line")
    if [[ -n "$HP_NOTICE" ]]; then
        printf -v line '| %-*s |' "$width" "$HP_NOTICE"
        frame+=("$line")
    fi
    frame+=("$border")
    if [[ $HP_FIRST -eq 1 ]]; then
        HP_FIRST=0
    else
        printf '\033[%dA' "$HP_FRAME_LINES"
    fi
    HP_FRAME_LINES=${#frame[@]}
    for i in "${!frame[@]}"; do
        if [[ $i -eq $((HP_CURSOR + 3)) ]]; then
            printf '\r\033[7m%s\033[0m\n' "${frame[$i]}"
        else
            printf '\r%s\n' "${frame[$i]}"
        fi
    done
}

host_pick_erase() {
    local i
    printf '\033[%dA' "$HP_FRAME_LINES"
    for ((i = 0; i < HP_FRAME_LINES; i++)); do
        printf '\033[2K'
        if [[ $i -lt $((HP_FRAME_LINES - 1)) ]]; then
            printf '\n'
        fi
    done
    printf '\033[%dA' $((HP_FRAME_LINES - 1))
    printf '\033[?25h'
}

host_pick_panel() {
    local i j key="" rest="" all_on=0 picked=0
    HP_ON=()
    for i in "${!FLEET_HOSTS[@]}"; do
        HP_ON+=(1)
    done
    HP_CURSOR=0
    HP_NOTICE=""
    HP_FIRST=1
    HP_FRAME_LINES=0
    printf '\033[?25l'
    trap 'printf "\033[?25h" >&2; exit 130' INT TERM
    while true; do
        host_pick_draw
        key=""
        rest=""
        IFS= read -rsn1 key || key=""
        if [[ "$key" == $'\033' ]]; then
            IFS= read -rsn2 -t 0.1 rest || rest=""
            key="${key}${rest}"
        fi
        HP_NOTICE=""
        case "$key" in
            $'\033[A'|k)
                HP_CURSOR=$(( (HP_CURSOR + ${#FLEET_HOSTS[@]} - 1) % ${#FLEET_HOSTS[@]} ))
                ;;
            $'\033[B'|j)
                HP_CURSOR=$(( (HP_CURSOR + 1) % ${#FLEET_HOSTS[@]} ))
                ;;
            ' ')
                if [[ "${HP_ON[$HP_CURSOR]}" -eq 1 ]]; then
                    HP_ON[HP_CURSOR]=0
                else
                    HP_ON[HP_CURSOR]=1
                fi
                ;;
            a)
                all_on=1
                for j in "${!FLEET_HOSTS[@]}"; do
                    if [[ "${HP_ON[$j]}" -eq 0 ]]; then
                        all_on=0
                    fi
                done
                for j in "${!FLEET_HOSTS[@]}"; do
                    if [[ $all_on -eq 1 ]]; then
                        HP_ON[j]=0
                    else
                        HP_ON[j]=1
                    fi
                done
                ;;
            ''|$'\n'|$'\r')
                picked=0
                for j in "${!FLEET_HOSTS[@]}"; do
                    if [[ "${HP_ON[$j]}" -eq 1 ]]; then
                        picked=$((picked + 1))
                    fi
                done
                if [[ $picked -gt 0 ]]; then
                    break
                fi
                HP_NOTICE="no hosts selected: space toggles a host, q cancels"
                ;;
            q)
                host_pick_erase
                trap - INT TERM
                log "host selection cancelled; nothing was rebooted"
                exit 0
                ;;
        esac
    done
    host_pick_erase
    trap - INT TERM
    SELECTED=()
    for i in "${!FLEET_HOSTS[@]}"; do
        if [[ "${HP_ON[$i]}" -eq 1 ]]; then
            SELECTED+=("${FLEET_HOSTS[$i]}")
        fi
    done
}

confirm_panel_selection() {
    local answer=""
    printf 'Selected hosts: %s\n' "${SELECTED[*]}"
    printf 'Each host will be rebooted in turn and verified back before the next is touched.\n'
    printf "Type 'reboot' to continue: "
    IFS= read -r answer || answer=""
    if [[ "$answer" != "reboot" ]]; then
        log "confirmation not given; aborting, nothing was rebooted"
        exit 0
    fi
}

SELECTED=()
if [[ -n "$LIMIT" ]]; then
    IFS=',' read -r -a wanted <<< "$LIMIT"
    for w in "${wanted[@]}"; do
        found=false
        for h in "${FLEET_HOSTS[@]}"; do
            [[ "$h" == "$w" ]] && { SELECTED+=("$w"); found=true; break; }
        done
        $found || die "--limit names unknown host: $w"
    done
elif [[ -t 0 && -t 1 && "${TERM:-}" != "dumb" ]]; then
    host_pick_panel
    [[ ${#SELECTED[@]} -gt 0 ]] || die "panel returned an empty host selection; nothing to reboot"
    confirm_panel_selection
else
    SELECTED=("${FLEET_HOSTS[@]}")
fi

ssh_host() { # ssh_host host remote_command...
    local host="$1"; shift
    "$SSH_BIN" -i "$SSH_KEY" -p "$SSH_PORT" \
        -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=accept-new \
        "$SSH_USER@${HOST_IP[$host]}" "$@"
}

host_family() { # -> debian|redhat|other (from the host's /etc/os-release)
    local host="$1" rel id like
    rel="$(ssh_host "$host" "cat /etc/os-release" 2>/dev/null)" || { echo "unreachable"; return 0; }
    id="$(grep -E '^ID=' <<< "$rel" | cut -d= -f2 | tr -d '"')"
    like="$(grep -E '^ID_LIKE=' <<< "$rel" | cut -d= -f2 | tr -d '"')"
    case " $id $like " in
        *" debian "*|*" ubuntu "*|*" raspbian "*) echo "debian" ;;
        *" rhel "*|*" fedora "*|*" rocky "*|*" centos "*) echo "redhat" ;;
        *) echo "other" ;;
    esac
}

boot_id() { ssh_host "$1" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true; }

reboot_one() {
    local host="$1"
    log "[$host] (${HOST_IP[$host]}) starting ($MODE mode)"

    local family
    family="$(host_family "$host")"
    if [[ "$family" != "debian" && "$family" != "redhat" ]]; then
        log "[$host] FAIL: OS family '$family' is not Debian/RedHat — playbooks skip this host; treating as failure"
        return 1
    fi

    if [[ "$MODE" == "complex" ]]; then
        local up
        if ! up="$(ssh_host "$host" "uptime" 2>&1)"; then
            log "[$host] FAIL: pre-reboot uptime check errored — NOT rebooting this host"
            return 1
        fi
        log "[$host] pre-reboot uptime: $up"
    fi

    local before
    before="$(boot_id "$host")"
    [[ -n "$before" ]] || { log "[$host] FAIL: cannot read boot_id before reboot"; return 1; }

    if $DRY_RUN; then
        log "[$host] DRY-RUN: would reboot now (sudo systemctl reboot), wait up to ${REBOOT_TIMEOUT}s, verify with whoami + boot_id change"
        return 0
    fi

    log "[$host] issuing reboot"
    # The connection drops as the host goes down; a failed ssh here is the
    # expected shape of success, so the result is deliberately ignored.
    ssh_host "$host" "sudo -n systemctl reboot" >/dev/null 2>&1 || true

    # Wait for the host to go down (or at least for its boot_id to change).
    local waited=0
    while [[ $waited -lt $DOWN_TIMEOUT ]]; do
        local probe
        probe="$(boot_id "$host")"
        if [[ -z "$probe" || "$probe" != "$before" ]]; then
            break
        fi
        sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
    done
    if [[ $waited -ge $DOWN_TIMEOUT ]]; then
        probe="$(boot_id "$host")"
        if [[ "$probe" == "$before" ]]; then
            log "[$host] FAIL: host did not go down within ${DOWN_TIMEOUT}s (boot_id unchanged)"
            return 1
        fi
    fi
    log "[$host] host is down / rebooting; waiting for return (timeout ${REBOOT_TIMEOUT}s)"

    # Wait for return: the playbook's test_command (whoami) must succeed on
    # a fresh connection AND the boot_id must be new.
    waited=0
    while [[ $waited -lt $REBOOT_TIMEOUT ]]; do
        local who now
        who="$(ssh_host "$host" "whoami" 2>/dev/null || true)"
        now="$(boot_id "$host")"
        if [[ "$who" == "$SSH_USER" && -n "$now" && "$now" != "$before" ]]; then
            log "[$host] back up: whoami=$who, boot_id changed, after ~${waited}s of waiting"
            log "[$host] has successfully rebooted and is accessible"
            return 0
        fi
        sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
    done
    log "[$host] FAIL: host did not return within ${REBOOT_TIMEOUT}s"
    return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────
log "Fleet reboot v$SCRIPT_VERSION mode=$MODE hosts: ${SELECTED[*]}"
if [[ ! -f "$SSH_KEY" && "$SSH_BIN" == "ssh" ]]; then
    die "SSH key not found: $SSH_KEY (set --ssh-key)"
fi

failures=0
for host in "${SELECTED[@]}"; do
    if reboot_one "$host"; then
        :
    else
        failures=$((failures + 1))
        if $CONTINUE_ON_ERROR; then
            log "[$host] failure recorded; continuing (--continue-on-error)"
        else
            die "aborting: $host failed; remaining hosts were NOT rebooted"
        fi
    fi
done

if [[ $failures -gt 0 ]]; then
    die "completed with $failures failed host(s)"
fi
if $DRY_RUN; then
    log "DRY-RUN complete: nothing was rebooted"
else
    log "All ${#SELECTED[@]} host(s) rebooted and verified"
fi
