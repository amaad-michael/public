#!/usr/bin/env bash
#
# NAME: ssh-setup-new-box-v1.3.sh
# WHAT: Provisions SSH access from a new controller box to the homelab:
#       installs keychain, generates an ed25519 keypair if missing, loads
#       it into a persistent agent, and copies the public key to pi0-pi4
#       plus neo1 (192.168.0.100-105) as user michael.
# WHY:  One run replaces the manual key and agent setup repeated on every
#       new controller box before ansible can reach the fleet.
# HOW:  ./ssh-setup-new-box-v1.3.sh
#       Idempotent: safe to re-run. dnf and apt family boxes (v1.1 added
#       the apt branch; v1.0 was Rocky-family only). v1.2 adds a
#       5-second ConnectTimeout to the key-copy loop so an off-fleet
#       run fails fast on unreachable hosts instead of burning the
#       full TCP timeout six times. v1.3 makes the copy loop
#       graceful: every host gets its attempt, failed copies are
#       collected and named in a closing warning, and the exit
#       status reflects the local setup instead of the first
#       unreachable host (the v1.2 loop, unguarded under set -e,
#       stopped at the first failed copy).
set -euo pipefail

KEY="$HOME/.ssh/id_ed25519"
SSH_USER="michael"
NODES=(192.168.0.100 192.168.0.101 192.168.0.102 192.168.0.103 192.168.0.104 192.168.0.105)

# --- Package family: keychain's install path is the only distro delta ---
FAMILY=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" rocky "*|*" rhel "*|*" fedora "*|*" centos "*) FAMILY="dnf" ;;
        *" debian "*|*" ubuntu "*) FAMILY="apt" ;;
    esac
fi
if [[ -z "$FAMILY" ]]; then
    echo "unsupported distro family (need a dnf or apt system); stopping" >&2
    exit 1
fi

# --- 1. keychain: one ssh-agent reused across logins (no orphan agents) ---
if ! command -v keychain >/dev/null 2>&1; then
    echo "installing keychain..."
    if [[ "$FAMILY" == "dnf" ]]; then
        if ! sudo dnf install -y keychain; then
            echo "keychain not in enabled repos, enabling EPEL..."
            sudo dnf install -y epel-release
            sudo dnf install -y keychain
        fi
    else
        if ! sudo apt-get install -y keychain; then
            echo "apt lists may be stale, updating and retrying..."
            sudo apt-get update
            sudo apt-get install -y keychain
        fi
    fi
fi
if ! grep -qF "keychain --eval" "$HOME/.bashrc"; then
    # The eval line must reach .bashrc literally; it expands at shell startup, not now.
    # shellcheck disable=SC2016
    echo 'eval $(keychain --eval --quiet ~/.ssh/id_ed25519)' >> "$HOME/.bashrc"
    echo "added keychain line to ~/.bashrc"
fi

# --- 2. ed25519 keypair (generate only if missing) ---
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -f "$KEY" ]]; then
    ssh-keygen -t ed25519 -C "michael@homelab" -f "$KEY"
else
    echo "keeping existing $KEY"
fi
chmod 600 "$KEY"

# --- 3. load the key into the agent (passphrase asked once) ---
eval "$(keychain --eval --quiet "$KEY")"

# --- 4. copy the public key to every node ---
# ConnectTimeout=5: off the fleet LAN each unreachable host would
# otherwise stall for the full TCP connection timeout.
# Every host gets its attempt: a failed copy is collected and
# named in the closing warning below instead of stopping the
# loop. Unguarded under set -e, any single host timing out
# would keep the key from ever reaching the hosts behind it,
# and the script's exit status reports the local setup
# (sections 1-3), not per-host reachability.
FAILED_NODES=()
for ip in "${NODES[@]}"; do
    echo "--- $ip ---"
    if ! ssh-copy-id -o ConnectTimeout=5 -i "$KEY.pub" "$SSH_USER@$ip"; then
        FAILED_NODES+=("$ip")
    fi
done
if (( ${#FAILED_NODES[@]} > 0 )); then
    echo "WARNING: the public key was NOT copied to: ${FAILED_NODES[*]}" >&2
    echo "the key still needs copying to those hosts; re-run from the fleet LAN or copy it by hand." >&2
fi

echo "done. verify with: ansible pi_all -i ~/git/ansible/hosts -m ping"
