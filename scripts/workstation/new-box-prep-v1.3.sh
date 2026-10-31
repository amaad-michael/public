#!/usr/bin/env bash
#
# NAME: new-box-prep-v1.3.sh
# WHAT: The single new-box workflow. Runs this repo's prep scripts in
#       order for a laptop or a server, with GPU tuning as an
#       optional final step (the only delta for a gaming rig):
#         laptop: git setup, ssh setup, Proton VPN, laptop role
#                 prep, optional GPU step
#         server: secure-server-init (conservative, the named
#                 server leg), git setup for the michael user,
#                 then the controller-side follow-ons are printed
#       A laptop run also carries a designation, work or personal:
#       the laptop role prep runs only on a work box, and a
#       personal box skips it. The designation comes from --work
#       or --personal; with neither flag the runner asks on the
#       terminal, and with no terminal and no flag it stops and
#       runs nothing, so a scripted run must pass the flag.
#       The Proton VPN step is the runner's one step of its own:
#       every workstation gets it, work box or personal. It
#       installs the Proton VPN app from Proton's own repositories
#       on the Fedora and Debian families; on the RHEL family,
#       where Proton publishes no app, it records the manual
#       WireGuard/OpenVPN route as a follow-on instead.
# WHY:  One entry point replaces remembering which scripts run in
#       which order on which kind of box (prep scripting audit,
#       2026-10-29). The steps are the repo's existing scripts,
#       each idempotent and runnable on its own; this runner
#       sequences them. The one step of its own is the Proton VPN
#       install, which has no sibling script to sequence.
# HOW:  ./new-box-prep-v1.3.sh laptop|server [--work|--personal]
#       [--with-gpu] [--dry-run]
#       Run it from inside a clone of this repo; sibling scripts
#       are resolved relative to this file and the newest version
#       of each wins. --dry-run prints the resolved plan and runs
#       nothing. Run the server form as root on the target; a
#       server run takes no designation. The laptop role prep
#       runs under sudo (it requires root); the git and ssh setup
#       steps run as the invoking user. A step that exits nonzero
#       stops the workflow: it names the failed step, exits
#       nonzero itself, and never prints the done footer.
set -uo pipefail

usage() {
    echo "usage: $0 laptop|server [--work|--personal] [--with-gpu] [--dry-run]" >&2
    exit 2
}

ROLE="${1:-}"
[[ "$ROLE" == "laptop" || "$ROLE" == "server" ]] || usage
shift

BOX_KIND=""
WITH_GPU=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --work)
            [[ -z "$BOX_KIND" ]] || usage
            BOX_KIND="work"
            ;;
        --personal)
            [[ -z "$BOX_KIND" ]] || usage
            BOX_KIND="personal"
            ;;
        --with-gpu) WITH_GPU=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) usage ;;
    esac
done

if [[ "$ROLE" == "server" && -n "$BOX_KIND" ]]; then
    echo "the work/personal designation is for laptops; a server run does not take one" >&2
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

newest() {
    find "$REPO_ROOT/$1" -maxdepth 1 -name "$2" -printf '%f\n' 2>/dev/null | sort -V | tail -n 1
}

require() {
    if [[ -z "$2" ]]; then
        echo "missing step script: $1 (looked in $REPO_ROOT)" >&2
        exit 1
    fi
}

GIT_SETUP="$(newest scripts/git 'git-setup-new-box-v*.sh')"
SSH_SETUP="$(newest scripts/security 'ssh-setup-new-box-v*.sh')"
ROLE_PREP="$(newest scripts/workstation 'laptop-role-prep-setup-v*.sh')"
SERVER_INIT="$(newest scripts/security 'secure-server-init-conservative-v*.sh')"
GPU_STEP="$(newest scripts/workstation 'new-nobara-setup-v*.sh')"

STEP=0
run_step() {
    local desc="$1"
    STEP=$((STEP + 1))
    echo ""
    echo "=== Step $STEP: $desc ==="
    shift
    echo "  $*"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! "$@"; then
            echo "FAILED: step $STEP ($desc) exited nonzero; workflow stopped." >&2
            exit 1
        fi
    fi
}

# --- Proton VPN step (begin) --------------------------------------
# Proton VPN on every workstation, installed from Proton's own
# repositories by exact OS family. The procedure and the pins are
# the ones verified against Proton's live repo and the official
# guides on 2026-10-30 (companion guide:
# protonvpn-nobara-install-guide-v2.0; the official pages are
# protonvpn.com/support/official-linux-vpn-fedora and
# protonvpn.com/support/linux-vpn-debian-ubuntu). The family is
# read from the exact /etc/os-release ID only, never ID_LIKE
# ancestry: ancestry is not lineage (the standing detection
# lesson). Until version 1.2 this install lived in the laptop
# role prep, so only work boxes got it; it is the workflow's own
# step now, ahead of the role prep, so every workstation gets it.
# Signing in on first launch is a vendor sign-in and stays
# manual; the step's report says so.
PROTONVPN_RPM_VERSION="1.0.5-1"
PROTONVPN_DEB_VERSION="1.0.10"
PROTONVPN_DEB_SHA256="c8a9fffb4ebdd63db08ce7f11c9b0ac394064ae6a210feb9ab63a0f7d8d060a7"
PROTON_MANUAL_NOTE=""

proton_vpn_step() {
    local os_id="" version_id=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d "\"'")"
        version_id="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1 | tr -d "\"'")"
    fi
    local sudo_cmd=()
    if [[ "$EUID" -ne 0 ]]; then
        sudo_cmd=(sudo)
    fi
    local tmpdir=""
    case "$os_id" in
        fedora|nobara)
            if rpm -q proton-vpn-gnome-desktop >/dev/null 2>&1; then
                echo "  Proton VPN already installed: proton-vpn-gnome-desktop $(rpm -q --qf '%{VERSION}-%{RELEASE}' proton-vpn-gnome-desktop); step skipped."
                return 0
            fi
            local fed_ver="${version_id%%.*}"
            local rpm_url="https://repo.protonvpn.com/fedora-${fed_ver}-stable/protonvpn-stable-release/protonvpn-stable-release-${PROTONVPN_RPM_VERSION}.noarch.rpm"
            if ! curl -fsSI --max-time 60 "$rpm_url" >/dev/null 2>&1; then
                echo "  Proton VPN: no release package reachable for Fedora ${fed_ver} at"
                echo "  ${rpm_url}; the step is not completable for this version"
                echo "  and the workflow continues. Manual route:"
                echo "  https://protonvpn.com/support/official-linux-vpn-fedora"
                return 0
            fi
            tmpdir="$(mktemp -d)"
            local rpmf="${tmpdir}/protonvpn-stable-release-${PROTONVPN_RPM_VERSION}.noarch.rpm"
            if ! curl -fsSL --max-time 600 -o "$rpmf" "$rpm_url"; then
                echo "  Proton VPN: the release package download failed" >&2
                rm -rf "$tmpdir"
                return 1
            fi
            if ! "${sudo_cmd[@]}" dnf install -y "$rpmf"; then
                rm -rf "$tmpdir"
                return 1
            fi
            rm -rf "$tmpdir"
            # Exit 100 from check-update means updates are
            # available; that is the success case, never a failure.
            "${sudo_cmd[@]}" dnf check-update --refresh >/dev/null 2>&1 || true
            if ! "${sudo_cmd[@]}" dnf install -y proton-vpn-gnome-desktop; then
                return 1
            fi
            if command -v gnome-shell >/dev/null 2>&1; then
                if ! "${sudo_cmd[@]}" dnf install -y libappindicator-gtk3 gnome-shell-extension-appindicator gnome-extensions-app; then
                    return 1
                fi
            else
                if ! "${sudo_cmd[@]}" dnf install -y libappindicator-gtk3; then
                    return 1
                fi
            fi
            echo "  Proton VPN installed: proton-vpn-gnome-desktop $(rpm -q --qf '%{VERSION}-%{RELEASE}' proton-vpn-gnome-desktop) from Proton's fedora-${fed_ver}-stable repo."
            echo "  Remaining manual action: sign in with your Proton account on first launch."
            ;;
        debian|ubuntu)
            if dpkg-query -W -f='${Status}' proton-vpn-gnome-desktop 2>/dev/null | grep -q 'install ok installed'; then
                echo "  Proton VPN already installed: proton-vpn-gnome-desktop $(dpkg-query -W -f='${Version}' proton-vpn-gnome-desktop 2>/dev/null); step skipped."
                return 0
            fi
            tmpdir="$(mktemp -d)"
            local deb="${tmpdir}/protonvpn-stable-release_${PROTONVPN_DEB_VERSION}_all.deb"
            local deb_url="https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_${PROTONVPN_DEB_VERSION}_all.deb"
            if ! curl -fsSL --max-time 600 -o "$deb" "$deb_url"; then
                echo "  Proton VPN: the release package download failed" >&2
                rm -rf "$tmpdir"
                return 1
            fi
            if ! printf '%s  %s\n' "$PROTONVPN_DEB_SHA256" "$deb" | sha256sum --check - >/dev/null 2>&1; then
                echo "  Proton VPN: the downloaded release package does not match" >&2
                echo "  Proton's published SHA256 (${PROTONVPN_DEB_SHA256});" >&2
                echo "  the step is aborted and nothing was installed by it." >&2
                rm -rf "$tmpdir"
                return 1
            fi
            if ! "${sudo_cmd[@]}" dpkg -i "$deb"; then
                rm -rf "$tmpdir"
                return 1
            fi
            rm -rf "$tmpdir"
            if ! "${sudo_cmd[@]}" apt-get update; then
                return 1
            fi
            if ! "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y proton-vpn-gnome-desktop; then
                return 1
            fi
            if command -v gnome-shell >/dev/null 2>&1; then
                if ! "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-shell-extension-appindicator gnome-shell-extension-prefs; then
                    return 1
                fi
            fi
            echo "  Proton VPN installed: proton-vpn-gnome-desktop $(dpkg-query -W -f='${Version}' proton-vpn-gnome-desktop 2>/dev/null) from Proton's Debian repo (release package SHA256 verified)."
            echo "  Remaining manual action: sign in with your Proton account on first launch."
            ;;
        rocky|rhel|centos|almalinux)
            PROTON_MANUAL_NOTE="Proton VPN has no app for the RHEL family: Proton publishes no EL repository. Use the manual WireGuard or OpenVPN configuration files from your Proton account (see https://protonvpn.com/support/linux-vpn-setup); there is no GUI app or CLI on this family."
            echo "  Proton VPN: no app exists for the RHEL family (ID=${os_id});"
            echo "  nothing installed. The manual route is in the follow-on below."
            ;;
        *)
            echo "  Proton VPN: OS ID '${os_id}' is not a family this step knows; skipped."
            ;;
    esac
    return 0
}
# --- Proton VPN step (end) ----------------------------------------

if [[ "$ROLE" == "laptop" ]]; then
    if [[ -z "$BOX_KIND" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Is this laptop a work box or a personal box? [work/personal]: " reply || reply=""
            BOX_KIND="${reply,,}"
        fi
    fi
    if [[ "$BOX_KIND" != "work" && "$BOX_KIND" != "personal" ]]; then
        echo "a laptop run needs a designation: pass --work or --personal, or answer the prompt on a terminal; nothing was run" >&2
        exit 2
    fi
    require "git setup" "$GIT_SETUP"
    require "ssh setup" "$SSH_SETUP"
    if [[ "$BOX_KIND" == "work" ]]; then
        require "laptop role prep" "$ROLE_PREP"
    fi
    echo "New-box workflow: laptop ($BOX_KIND box)"
    run_step "git setup (identity, defaults, efficiency settings)" bash "$REPO_ROOT/scripts/git/$GIT_SETUP"
    run_step "ssh setup (keychain, keypair, keys to the fleet)" bash "$REPO_ROOT/scripts/security/$SSH_SETUP"
    run_step "Proton VPN (app install from Proton's repo, by OS family)" proton_vpn_step
    if [[ "$BOX_KIND" == "work" ]]; then
        run_step "laptop role prep (accounts, tooling, gh, hardening)" sudo bash "$REPO_ROOT/scripts/workstation/$ROLE_PREP"
    else
        echo ""
        echo "Skipping laptop role prep: this box is designated personal;"
        echo "the role prep runs on work boxes only."
    fi
    if [[ "$WITH_GPU" -eq 1 ]]; then
        require "GPU step" "$GPU_STEP"
        run_step "GPU tuning (optional final step; skips without a discrete AMD GPU)" sudo bash "$REPO_ROOT/scripts/workstation/$GPU_STEP" gpu-high
    fi
    echo ""
    if [[ "$BOX_KIND" == "work" ]]; then
        echo "Workflow done. Remaining manual items are the ones the role"
        echo "prep printed (vendor sign-ins, gh auth login, LUKS recovery"
        echo "key into Proton Pass, a tested restore)."
    else
        echo "Workflow done. This box is designated personal, so the role"
        echo "prep did not run and printed no manual list; re-run with"
        echo "--work if the box takes a work role later."
    fi
    if [[ -n "$PROTON_MANUAL_NOTE" ]]; then
        echo ""
        echo "Proton VPN follow-on: $PROTON_MANUAL_NOTE"
    fi
else
    require "server init" "$SERVER_INIT"
    require "git setup" "$GIT_SETUP"
    if [[ "$DRY_RUN" -eq 0 && "$EUID" -ne 0 ]]; then
        echo "the server workflow runs as root on the target; re-run with sudo" >&2
        exit 1
    fi
    echo "New-box workflow: server"
    run_step "server init, conservative leg (users, SSH hardening, journal, time sync, hosts, MOTD)" bash "$REPO_ROOT/scripts/security/$SERVER_INIT"
    run_step "git setup for the michael user" sudo -u michael -H bash "$REPO_ROOT/scripts/git/$GIT_SETUP"
    if [[ "$WITH_GPU" -eq 1 ]]; then
        echo ""
        echo "GPU step requested for a server: skipped (the GPU step is a workstation delta)."
    fi
    echo ""
    echo "On-box steps done. Controller-side follow-ons, run from pi1:"
    echo "  1. Set the trio passwords: scripts/security/cycle-fleet-passwords.sh"
    echo "     with the vault vars file (root, michael, ansible for this host)."
    echo "  2. Add the host to monitoring: the node_exporter fleet rollout"
    echo "     playbook (ansible/playbooks/monitoring/)."
    echo "  3. Run the first audit on the box: sudo lynis audit system"
fi
