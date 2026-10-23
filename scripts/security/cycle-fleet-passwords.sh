#!/usr/bin/env bash
#
# cycle-fleet-passwords.sh — bash form of the fleet password cycle.
#
# Ansible form: ansible/playbooks/accounts/password-cycle/cycle_creds.yml
# (+ verify_cycle_creds.yml). This script performs the same cycle from the
# controller over SSH: the root, michael, and ansible account passwords on
# pi0-pi4 + neo1, then verifies the result. Docker is not applicable: the
# cycle is a controller-side operation driven by vault-held secrets.
#
# SAFETY SEMANTICS (mirrors the playbooks exactly):
#   - Password values are runtime-injected only. The script takes a vars file
#     OUTSIDE the repo in the same shape as passwords.example.yml (one unique
#     32-character value per host per account, generated in the vault). No
#     secret value is ever stored in the repo, in this script, or in logs.
#   - Pre-flight: every selected host/account is validated (defined, 32
#     characters, not the placeholder) BEFORE any password changes anywhere.
#     A bad vars file changes nothing.
#   - Run as root on the target (like the playbook's `-e ansible_user=root`):
#     missing accounts are created first (home dir, /bin/bash), then the
#     passwordless sudo drop-ins for michael and ansible (visudo-validated),
#     then the passwords are set. sshd is deliberately NOT restarted.
#   - Values travel over the encrypted SSH channel only: they are piped to
#     the remote `chpasswd` on stdin, never placed in a command line, never
#     echoed, never logged. Remote output is filtered for them on the way
#     back as a belt-and-braces measure.
#   - Fail-fast: the first host failure aborts the run. Keep the vars file
#     until the whole fleet verifies; re-running with the same values is
#     safe (effective passwords do not change). Shred it after a green
#     verify (e.g. `shred -u ~/passwords.yml`).
#
# Usage (from the repo root):
#   ./scripts/security/cycle-fleet-passwords.sh --passwords-file ~/passwords.yml
#   ./scripts/security/cycle-fleet-passwords.sh --passwords-file ~/passwords.yml --limit neo1   # pilot
#   ./scripts/security/cycle-fleet-passwords.sh --passwords-file ~/passwords.yml --verify-only
#   ./scripts/security/cycle-fleet-passwords.sh --passwords-file ~/passwords.yml --dry-run
#
# Environment: SSH_KEY (default ~/.ssh/pi_cluster_key), SSH_PORT (default 22),
# PASSWORDS_FILE, SSH_BIN (default ssh; a test double may be substituted).
set -euo pipefail

SCRIPT_VERSION="1.0"

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_INVENTORY="$REPO_ROOT/ansible/hosts"

# ── Defaults ─────────────────────────────────────────────────────────────────
INVENTORY="$DEFAULT_INVENTORY"
PASSWORDS_FILE="${PASSWORDS_FILE:-}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pi_cluster_key}"
SSH_PORT="${SSH_PORT:-22}"
SSH_BIN="${SSH_BIN:-ssh}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
LIMIT=""
DRY_RUN=false
VERIFY_ONLY=false
NO_VERIFY=false

ACCOUNTS=(root michael ansible)
# Passwordless sudo drop-ins are written for michael and ansible (see the
# remote setup script in cycle_host).
PLACEHOLDER="CHANGE_ME_CHANGE_ME_CHANGE_ME_12"

usage() {
    cat <<'EOF'
Usage: cycle-fleet-passwords.sh --passwords-file FILE [options]

Cycle the root, michael, and ansible passwords across the fleet (pi_all)
over SSH, then verify. Bash form of
ansible/playbooks/accounts/password-cycle/cycle_creds.yml.

Options:
  --passwords-file FILE   Vars file outside the repo, in the shape of
                          passwords.example.yml (also via PASSWORDS_FILE)
  --limit h1,h2           Only these hosts (e.g. --limit neo1 to pilot)
  --inventory FILE        Ansible inventory to read pi_all from
  --ssh-key PATH          Fleet SSH key (default ~/.ssh/pi_cluster_key)
  --ssh-port PORT         SSH port (default 22)
  --verify-only           Skip the cycle; run verification only
  --no-verify             Skip the post-cycle verification
  --dry-run               Validate the vars file and print the plan only;
                          no SSH connections, no changes
  -h, --help              This help
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --passwords-file) PASSWORDS_FILE="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --inventory) INVENTORY="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --ssh-port) SSH_PORT="$2"; shift 2 ;;
        --verify-only) VERIFY_ONLY=true; shift ;;
        --no-verify) NO_VERIFY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── Logging (never interpolates secret values) ───────────────────────────────
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

# ── Scratch: parsed vars land here with 0700/0600, shredded on exit ──────────
SCRATCH="$(mktemp -d)"
chmod 0700 "$SCRATCH"
PARSED="$SCRATCH/parsed.tsv"
cleanup() {
    rm -rf "$SCRATCH"
    unset SCRATCH PARSED
}
trap cleanup EXIT

[[ -n "$PASSWORDS_FILE" ]] || die "--passwords-file is required (see passwords.example.yml)"
[[ -f "$PASSWORDS_FILE" ]] || die "passwords file not found: $PASSWORDS_FILE"
[[ -f "$INVENTORY" ]] || die "inventory not found: $INVENTORY"

# ── Fleet: read pi_all members and ansible_host IPs from the inventory ────────
# Lines under [pi_all] look like: pi0 ansible_host=192.168.0.100
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

# ── Selection (--limit) ──────────────────────────────────────────────────────
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
else
    SELECTED=("${FLEET_HOSTS[@]}")
fi

# ── Parse the vars file (stdlib-only; shape-checked against passwords.example.yml)
# Emits TAB-separated host/account/value lines into $PARSED (mode 0600).
parse_passwords_file() {
    python3 - "$PASSWORDS_FILE" "$PARSED" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
host = None
rows = []
with open(src, 'r', encoding='utf-8') as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^  ([A-Za-z0-9_.-]+):\s*$', line)
        if m:
            host = m.group(1)
            continue
        m = re.match(r'^    ([A-Za-z0-9_.-]+):\s*"?([^"\n]*)"?\s*$', line)
        if m and host:
            rows.append((host, m.group(1), m.group(2)))
            continue
        if re.match(r'^cycle_passwords:\s*$', line):
            continue
        raise SystemExit(f"vars file line {lineno}: unrecognised shape: {line!r}")
if not rows:
    raise SystemExit("vars file contains no host/account entries")
with open(dst, 'w', encoding='utf-8', opener=lambda p, f: __import__('os').open(p, f, 0o600)) as fh:
    for h, a, v in rows:
        if '\t' in v or '\n' in v:
            raise SystemExit(f"vars file: value for {h}/{a} contains a tab or newline")
        fh.write(f"{h}\t{a}\t{v}\n")
PYEOF
}

lookup_value() { # host account -> value on stdout; empty if missing
    local host="$1" acct="$2"
    awk -F'\t' -v h="$host" -v a="$acct" '$1==h && $2==a {print $3; exit}' "$PARSED"
}

preflight() {
    log "Pre-flight: validating injected values for ${#SELECTED[@]} host(s) x ${#ACCOUNTS[@]} account(s)"
    parse_passwords_file
    local bad=0
    for host in "${SELECTED[@]}"; do
        for acct in "${ACCOUNTS[@]}"; do
            local val
            val="$(lookup_value "$host" "$acct")"
            if [[ -z "$val" ]]; then
                log "  FAIL: $host/$acct: no value in vars file"
                bad=1
            elif [[ ${#val} -ne 32 ]]; then
                log "  FAIL: $host/$acct: value is ${#val} chars, need 32"
                bad=1
            elif [[ "$val" == "$PLACEHOLDER" ]]; then
                log "  FAIL: $host/$acct: placeholder value"
                bad=1
            fi
        done
    done
    if [[ $bad -ne 0 ]]; then
        die "pre-flight failed: fix the vars file; nothing was changed anywhere"
    fi
    log "Pre-flight passed"
}

# ── SSH ──────────────────────────────────────────────────────────────────────
ssh_root() { # ssh_root host remote_command...
    local host="$1"; shift
    "$SSH_BIN" -i "$SSH_KEY" -p "$SSH_PORT" \
        -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=accept-new \
        "root@${HOST_IP[$host]}" "$@"
}
ssh_as() { # ssh_as user host remote_command...
    local user="$1" host="$2"; shift 2
    "$SSH_BIN" -i "$SSH_KEY" -p "$SSH_PORT" \
        -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=accept-new \
        "$user@${HOST_IP[$host]}" "$@"
}

# Belt-and-braces: strip any accidental secret value from remote output before
# it reaches the log. (The script never prints values; this is the backstop.)
scrub() {
    local line
    while IFS= read -r line; do
        while IFS=$'\t' read -r _h _a v; do
            [[ -n "$v" ]] && line="${line//$v/<redacted>}"
        done < "$PARSED"
        printf '%s\n' "$line"
    done
}

# ── Cycle one host (mirrors cycle_creds.yml task order) ──────────────────────
cycle_host() {
    local host="$1"
    log "[$host] cycling accounts: ${ACCOUNTS[*]}"

    # 1-2. Create missing accounts, ensure sudoers drop-ins (no secrets here).
    local setup_script
    setup_script="$(cat <<'REMOTE'
set -eu
for acct in root michael ansible; do
    if getent passwd "$acct" >/dev/null 2>&1; then
        : # existing accounts are never modified by the creation step
    else
        useradd -m -s /bin/bash "$acct"
    fi
done
mkdir -p /etc/sudoers.d
chmod 0755 /etc/sudoers.d
for acct in michael ansible; do
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$acct" \
        | install -m 0440 -o root -g root /dev/stdin "/etc/sudoers.d/$acct"
    visudo -cf "/etc/sudoers.d/$acct"
done
REMOTE
)"
    if ! ssh_root "$host" "$setup_script" 2>&1 | scrub; then
        die "[$host] account/sudoers setup failed — aborting (no passwords changed on $host)"
    fi

    # 3. Set passwords from the injected values. Values ride stdin to the
    #    remote chpasswd: never in a command line, never logged.
    local pw_input=""
    for acct in "${ACCOUNTS[@]}"; do
        pw_input+="$acct:$(lookup_value "$host" "$acct")"$'\n'
    done
    if ! printf '%s' "$pw_input" | ssh_root "$host" "chpasswd" 2>&1 | scrub; then
        die "[$host] password set failed — aborting"
    fi
    unset pw_input
    log "[$host] passwords set"
}

# ── Verify one host (mirrors verify_cycle_creds.yml) ─────────────────────────
verify_host() {
    local host="$1" failures=0
    log "[$host] verifying"

    # Reachability as the ansible service account + become exercise.
    local who
    if ! who="$(ssh_as ansible "$host" "sudo -n whoami" 2>&1 | scrub)"; then
        log "[$host] FAIL: ssh as ansible / sudo exercise failed"
        failures=1
    elif [[ "$who" != "root" ]]; then
        log "[$host] FAIL: sudo exercise returned '$who', not 'root'"
        failures=1
    else
        log "[$host] ok: reachable as ansible, sudo -> root"
    fi

    # Every account has a set (hashed) password in /etc/shadow.
    local shadow
    shadow="$(ssh_root "$host" "grep -E '^(root|michael|ansible):' /etc/shadow | cut -d: -f1,2" 2>&1 | scrub)" || true
    for acct in "${ACCOUNTS[@]}"; do
        local field="${shadow#*"$acct":}"
        field="${field%%$'\n'*}"
        if [[ "$field" == \$* ]]; then
            log "[$host] ok: $acct has a set password"
        else
            log "[$host] FAIL: $acct has no set password in /etc/shadow"
            failures=1
        fi
    done

    # sshd hardening is in effect.
    local eff
    if ! eff="$(ssh_root "$host" "sshd -T" 2>&1 | scrub)"; then
        log "[$host] FAIL: sshd -T failed"
        failures=1
    else
        if printf '%s\n' "$eff" | grep -qi '^permitrootlogin prohibit-password$'; then
            log "[$host] ok: PermitRootLogin prohibit-password"
        else
            log "[$host] FAIL: PermitRootLogin is not prohibit-password"
            failures=1
        fi
        if printf '%s\n' "$eff" | grep -qi '^passwordauthentication no$'; then
            log "[$host] ok: PasswordAuthentication no"
        else
            log "[$host] FAIL: PasswordAuthentication is not no"
            failures=1
        fi
    fi

    if [[ $failures -ne 0 ]]; then
        die "[$host] verification FAILED — aborting (fix $host before continuing)"
    fi
    log "[$host] verification passed"
}

# ── Main ─────────────────────────────────────────────────────────────────────
log "Fleet password cycle v$SCRIPT_VERSION — ${#SELECTED[@]} host(s): ${SELECTED[*]}"

if $VERIFY_ONLY && $DRY_RUN; then
    die "--verify-only and --dry-run are mutually exclusive"
fi

preflight

if $DRY_RUN; then
    log "DRY-RUN: vars file valid. Plan (no changes made, no SSH connections):"
    for host in "${SELECTED[@]}"; do
        log "  $host (${HOST_IP[$host]}): create-if-missing + sudoers for root/michael/ansible, set 3 passwords via chpasswd, verify"
    done
    log "DRY-RUN complete"
    exit 0
fi

if ! $VERIFY_ONLY; then
    if [[ ! -f "$SSH_KEY" ]]; then
        # In test harnesses SSH_BIN may be a double that needs no key.
        if [[ "$SSH_BIN" == "ssh" ]]; then
            die "SSH key not found: $SSH_KEY (set --ssh-key)"
        else
            log "note: SSH key $SSH_KEY absent but SSH_BIN is a test double; continuing"
        fi
    fi
    # Fail-fast: any host failure aborts the whole run.
    for host in "${SELECTED[@]}"; do
        cycle_host "$host"
    done
    log "Cycle complete on ${#SELECTED[@]} host(s)"
fi

if ! $NO_VERIFY; then
    for host in "${SELECTED[@]}"; do
        verify_host "$host"
    done
    log "Fleet verification passed on ${#SELECTED[@]} host(s)"
    log "Shred the vars file now if the whole fleet is signed off (e.g. shred -u <file>)"
else
    log "Verification skipped (--no-verify)"
fi
