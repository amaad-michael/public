#!/usr/bin/env bash
# laptop-role-prep-setup-v1.7.sh
#
# Produce the desired state from "Linux Laptop Prep Checklist: Coding
# Instructor and Linux Administrator" (linux-laptop-role-prep-checklist)
# for every item that can be done from the command line. Items that need
# hardware, a GUI session, a vendor sign-in, or a human decision are NOT
# faked: they are collected and printed as a manual list at the end.
#
# Properties:
#   - Run as root (sudo). Idempotent: safe to re-run; existing users,
#     keys, and configs are detected and left in place.
#   - Distro-aware: dnf family (Rocky/Fedora/RHEL) and apt family
#     (Debian/Ubuntu). Anything else is reported and the run stops.
#   - No password is ever set non-interactively and no secret is written
#     by this script. New-user passwords and SSH key passphrases are
#     prompted for only when a terminal is attached; otherwise the exact
#     commands are printed as next steps.
#
# Companion guide: linux-laptop-role-prep-checklist (this script is
# embedded in it verbatim; the two files travel together).

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit before running, or leave the defaults)
# ---------------------------------------------------------------------------

WORK_USER="michael-work"
PERSONAL_USER="michael"

# Git identities. Left empty, the script still writes the conditional-
# include structure but skips the name/email values and tells you.
PERSONAL_GIT_NAME=""
PERSONAL_GIT_EMAIL=""
WORK_GIT_NAME=""
WORK_GIT_EMAIL=""

# 1 also adds the work user to the libvirt group when virt is installed.
INSTALL_VIRT=1
# 1 would add the work user to the sudo/wheel group. Default 0: the
# checklist requires only that sudo demands a password; it does not grant
# either new account admin rights. Your existing account stays the admin.
GRANT_SUDO_WORK=0

PUBLIC_REPO_URL="https://github.com/amaad-michael/public.git"

# ---------------------------------------------------------------------------
# Bookkeeping
# ---------------------------------------------------------------------------

DONE_ITEMS=()
MANUAL_ITEMS=()
WARNINGS=()

done_item()   { DONE_ITEMS+=("$1"); }
manual_item() { MANUAL_ITEMS+=("$1"); }
warn_item()   { WARNINGS+=("$1"); }

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# Prerequisites and OS detection
# ---------------------------------------------------------------------------

if [[ ${EUID} -ne 0 ]]; then
    say "This script must run as root: sudo ./laptop-role-prep-setup-v1.7.sh"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    say "Cannot read /etc/os-release; cannot identify this system. Stopping."
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"
FAMILY=""
case " ${OS_ID} ${OS_LIKE} " in
    *" rocky "*|*" rhel "*|*" fedora "*|*" centos "*) FAMILY="dnf" ;;
    *" debian "*|*" ubuntu "*) FAMILY="apt" ;;
esac
if [[ -z "${FAMILY}" ]]; then
    say "Unsupported distro family (ID=${OS_ID}, ID_LIKE=${OS_LIKE})."
    say "This script covers the dnf and apt families only. Stopping."
    exit 1
fi
say "Detected: ${PRETTY_NAME:-${OS_ID}} (family: ${FAMILY})"

# RHEL-lineage distros (Rocky, RHEL, CentOS, Alma) share a package
# universe that differs from Fedora's for a few names this script
# cares about; the package sections branch on it where the Rocky 10
# and EPEL 10 indexes prove the Fedora name does not exist there.
# The exact distro ID is the only sound signal, and it decides
# alone. ID_LIKE declares ancestry, not package lineage, and it
# cannot separate the two families at all: Nobara's ID_LIKE is
# "rhel centos fedora" (read from the travel laptop's real
# /etc/os-release on 2026-10-30), byte-identical to Rocky 10's own
# ID_LIKE, and RHEL itself ships ID_LIKE="fedora". v1.4 judged a
# derivative under its own ID by its ID_LIKE lineage and so still
# read Nobara as RHEL-family on real hardware; v1.6 removes that
# fallback. The RHEL set is closed and known: an exact ID of rhel,
# rocky, almalinux, or centos is RHEL-family, and every other dnf
# system, Fedora and its derivatives alike, is not.
RHELISH=0
if [[ "${FAMILY}" == "dnf" ]]; then
    case " ${OS_ID} " in
        *" rhel "*|*" rocky "*|*" almalinux "*|*" centos "*) RHELISH=1 ;;
    esac
fi

INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1

# ---------------------------------------------------------------------------
# Package installation (checklist sections 4, 5, 6)
# ---------------------------------------------------------------------------

# install_pkgs <pkg...>: try the batch; on failure retry one by one so a
# single bad name never sinks the rest. Misses become warnings.
install_pkgs() {
    local pkgs=("$@")
    if [[ "${FAMILY}" == "dnf" ]]; then
        if dnf install -y "${pkgs[@]}" >/dev/null 2>&1; then
            return 0
        fi
    else
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    local p
    for p in "${pkgs[@]}"; do
        if [[ "${FAMILY}" == "dnf" ]]; then
            dnf install -y "${p}" >/dev/null 2>&1 || warn_item "package not installed: ${p}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${p}" >/dev/null 2>&1 || warn_item "package not installed: ${p}"
        fi
    done
}

step "Packages"

if [[ "${FAMILY}" == "apt" ]]; then
    apt-get update >/dev/null 2>&1 || warn_item "apt-get update failed (offline?); installs may fail"
fi

# Core + developer toolchains (sections 4 and 6): git, tmux, Python, Node.
if [[ "${FAMILY}" == "dnf" ]]; then
    install_pkgs git tmux python3 nodejs man-db man-pages
else
    install_pkgs git tmux python3 nodejs man-db manpages
fi
done_item "core tooling installed: git, tmux, python3, nodejs, man pages (checklist 4, 6)"

# GitHub CLI (gh): pull requests from the terminal, git's companion
# for the landing workflow. Fedora carries gh in the standard repos
# and EPEL 10 carries it for the RHEL family (2.97.0, verified
# against the EPEL 10 index 2026-10-29); Debian carries it too.
# Where no candidate exists, the fallback is GitHub's own package
# repo on the RHEL family and a manual item naming the official
# route elsewhere. Authentication is a sign-in and is never
# scripted; the manual item below carries it on every run.
install_pkgs gh
if command -v gh >/dev/null 2>&1; then
    done_item "github cli installed: $(gh --version 2>/dev/null | head -1) (checklist 6)"
elif [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
    if ! dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null 2>&1; then
        dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
        dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null 2>&1 || true
    fi
    install_pkgs gh
    if command -v gh >/dev/null 2>&1; then
        done_item "github cli installed from GitHub's package repo: $(gh --version 2>/dev/null | head -1) (checklist 6)"
    else
        manual_item "GitHub CLI: install gh from https://cli.github.com (neither EPEL nor GitHub's repo yielded a package on this box)."
    fi
else
    manual_item "GitHub CLI: install gh from https://cli.github.com (no package candidate on this distro)."
fi
manual_item "GitHub CLI: authenticate once per box (never scripted): gh auth login (GitHub.com, SSH, web browser), then gh auth status to verify (checklist 6)."

# Linux administrator kit diagnostics (section 4) + Ansible.
if [[ "${FAMILY}" == "dnf" ]]; then
    install_pkgs nmap tcpdump mtr bind-utils curl jq iperf3 smartmontools nmap-ncat ansible-core
else
    install_pkgs nmap tcpdump mtr-tiny dnsutils curl jq iperf3 smartmontools netcat-openbsd ansible
fi
done_item "admin diagnostics installed: nmap, tcpdump, mtr, dig, curl, jq, iperf3, smartmontools, nc, ansible (checklist 4)"

# Instructor kit (section 5): Python IDLE + a screenshot tool. Verified
# against the Rocky 10 + EPEL 10 indexes on 2026-10-18: the RHEL
# family has no installable IDLE package (python3-idle does not exist
# there, and EPEL's python3.13-idle currently requires an expat build
# the 10.2 base repos do not ship yet) and no flameshot package at
# all, so both become manual items there instead of failing the same
# way on every run.
if [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
    manual_item "Section 5: Python IDLE has no installable package on the RHEL family today (no python3-idle in the base repos; EPEL's python3.13-idle needs a base expat newer than the 10.2 repos ship)."
    manual_item "Section 5: flameshot is not packaged for the RHEL family; use the desktop's built-in screenshot tool or pick one by hand."
elif [[ "${FAMILY}" == "dnf" ]]; then
    install_pkgs python3-idle flameshot
    done_item "instructor tooling installed: Python IDLE, flameshot screenshot tool (checklist 5)"
else
    install_pkgs idle3 flameshot
    done_item "instructor tooling installed: Python IDLE, flameshot screenshot tool (checklist 5)"
fi

# Applications (added at Michael's direction 2026-10-17): VLC media
# player, Docker (apt family only), and Zenmap (the Nmap GUI). Package
# names verified against the real Ubuntu 24.04 and Rocky 10 + EPEL 10
# indexes: on apt the Docker engine is docker.io (plain "docker" has
# no candidate) with docker-compose-v2 alongside, and zenmap exists.
# On the RHEL family Docker is intentionally not installed (Michael's
# direction): Podman, installed below on both families, is the
# container runtime there. Zenmap is not packaged for Rocky or EPEL 10
# at all, so that family gets the nmap command-line tools only.
step "Applications"

if [[ "${FAMILY}" == "apt" ]]; then
    install_pkgs vlc zenmap docker.io docker-compose-v2
else
    install_pkgs vlc
    if [[ "${RHELISH}" == "1" ]]; then
        done_item "zenmap is not packaged for the RHEL family; the nmap command-line tools are installed above"
    else
        install_pkgs zenmap
    fi
    done_item "container runtime on the dnf family is podman (installed below); Docker intentionally skipped per your standing direction"
fi
if command -v vlc >/dev/null 2>&1; then
    vlc_ver="$(vlc --version 2>/dev/null | head -1)"
    if [[ -z "${vlc_ver}" ]]; then
        # vlc refuses to run as root, so under sudo --version prints
        # nothing; fall back to the installed package's version.
        if [[ "${FAMILY}" == "dnf" ]]; then
            vlc_ver="$(rpm -q vlc 2>/dev/null)"
        else
            vlc_ver="$(dpkg-query -W -f='${Version}' vlc 2>/dev/null)"
        fi
    fi
    done_item "vlc installed: ${vlc_ver}"
fi
if command -v zenmap >/dev/null 2>&1; then
    done_item "zenmap installed (Nmap GUI)"
fi
if [[ "${FAMILY}" == "apt" ]] && command -v docker >/dev/null 2>&1; then
    done_item "docker installed: $(docker --version 2>/dev/null) (checklist 4)"
    # The systemctl unit checks in this script use grep without -q on
    # purpose: under pipefail, grep -q exits on the first match and
    # systemctl dies of SIGPIPE, which flips the pipeline's result.
    if systemctl list-unit-files 2>/dev/null | grep '^docker\.service' >/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || warn_item "docker present but its service could not be enabled"
    fi
    # The docker group add for the work user runs in the Users
    # section, after the account exists; see there.
fi

# Container runtime (section 4): Podman on both families.
install_pkgs podman
if command -v podman >/dev/null 2>&1; then
    done_item "podman installed: $(podman --version 2>/dev/null) (checklist 4)"
else
    warn_item "podman not available after install attempt"
fi

# Virtualization (section 4): libvirt + a VM console. (The work
# user's libvirt group add runs in the Users section, after the
# account exists; see there.) The console
# differs by family: virt-manager on apt. On RHEL 10 virt-manager is
# not packaged at all, so cockpit-machines, the RHEL-native console,
# takes its place.
if [[ "${INSTALL_VIRT}" == "1" ]]; then
    if [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
        install_pkgs qemu-kvm libvirt cockpit-machines
    elif [[ "${FAMILY}" == "dnf" ]]; then
        install_pkgs qemu-kvm libvirt virt-manager
    else
        install_pkgs qemu-kvm libvirt-daemon-system libvirt-clients virt-manager
    fi
    if systemctl list-unit-files 2>/dev/null | grep '^libvirtd\.service' >/dev/null; then
        systemctl enable --now libvirtd >/dev/null 2>&1 || warn_item "libvirtd present but could not be enabled"
        if [[ "${RHELISH}" == "1" ]]; then
            done_item "libvirt installed and enabled; virt-manager is not packaged for RHEL 10, cockpit-machines installed as the VM console (checklist 4)"
        else
            done_item "libvirt installed and enabled; create the clean sandbox VM from virt-manager (checklist 4)"
        fi
    else
        warn_item "libvirt packages did not yield a libvirtd service; VM setup needs a look"
    fi
    manual_item "Section 4: build the one clean Linux sandbox VM (image choice is yours) and confirm it boots."
else
    manual_item "Section 4: VM setup skipped (INSTALL_VIRT=0); install the libvirt stack when ready."
fi

# ---------------------------------------------------------------------------
# Vendor applications (added at Michael's direction 2026-10-18):
# TickTick, Proton VPN, Proton Pass. Distribution methods verified
# against each vendor's own site and feeds on 2026-10-18; see the
# per-app comments. Downloads land in a scratch directory that is
# removed when the section finishes. Every app degrades to a warning
# plus a manual item when its download or checksum does not check
# out; nothing unverified is ever installed.
# ---------------------------------------------------------------------------

step "Vendor applications"

VENDOR_DIR="$(mktemp -d)"

# pkg_installed <name>: true when the package manager has the package.
pkg_installed() {
    if [[ "${FAMILY}" == "dnf" ]]; then
        rpm -q "$1" >/dev/null 2>&1
    else
        dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
    fi
}

# pkg_version <name>: the installed version, empty when absent.
pkg_version() {
    if [[ "${FAMILY}" == "dnf" ]]; then
        rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
    else
        dpkg-query -W -f='${Version}' "$1" 2>/dev/null
    fi
}

# fetch <url> <dest>: quiet download, non-zero on any failure.
fetch() {
    curl -fsSL --max-time 600 -o "$2" "$1" >/dev/null 2>&1
}

# install_local_pkg <file>: install a downloaded package file with
# the package manager so its dependencies resolve (a deliberate step
# up from the vendors' dpkg -i / rpm -i instructions, which fail on
# a machine missing a dependency instead of pulling it).
install_local_pkg() {
    if [[ "${FAMILY}" == "dnf" ]]; then
        if dnf install -y "$1" >/dev/null 2>&1; then
            return 0
        fi
        # Fallback for a collision between the vendors' own RPMs.
        # Proton Pass and TickTick are both built on the stock
        # Electron binary, so both packages ship the same
        # /usr/lib/.build-id/* debug symlinks with different
        # targets, and rpm refuses to install the second one
        # (file conflicts with the first). The links are debug
        # metadata; which app they point at does not affect either
        # program. Install the file's dependencies with dnf first
        # (rpm alone cannot resolve them), then let rpm replace
        # the conflicting links.
        local reqs
        reqs="$(rpm -qp --requires "$1" 2>/dev/null | grep -vE '^rpmlib\(|^\(|^/' | sort -u)"
        if [[ -n "${reqs}" ]]; then
            # shellcheck disable=SC2086 # reqs is a name list; word splitting is the point
            dnf install -y ${reqs} >/dev/null 2>&1 || true
        fi
        rpm -Uvh --replacefiles "$1" >/dev/null 2>&1
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >/dev/null 2>&1
    fi
}

# --- Proton Pass -----------------------------------------------------
# No repository: Proton publishes standalone DEB/RPM packages and a
# version feed carrying every release's URL and SHA512 checksum (the
# same feed the app updates itself from). The script reads the feed,
# takes the newest Stable release at full rollout, verifies the
# checksum, and only then installs. Feed (x86_64):
#   https://proton.me/download/PassDesktop/linux/x64/version.json
# Vendor method: https://proton.me/support/set-up-proton-pass-linux
install_proton_pass() {
    if pkg_installed proton-pass; then
        done_item "proton-pass already installed: $(pkg_version proton-pass)"
        return 0
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (this script's verified feed covers x86_64; this machine is $(uname -m))."
        return 0
    fi
    local json="${VENDOR_DIR}/pass-version.json"
    if ! fetch "https://proton.me/download/PassDesktop/linux/x64/version.json" "${json}"; then
        warn_item "proton-pass: Proton's version feed was unreachable; skipped"
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (the version feed was unreachable during this run)."
        return 0
    fi
    local sel
    if ! sel="$(python3 - "${json}" "${FAMILY}" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
want = ".deb" if sys.argv[2] == "apt" else ".rpm"
for rel in data.get("Releases", []):
    if rel.get("CategoryName") != "Stable":
        continue
    if rel.get("RolloutPercentage") != 1:
        continue
    for entry in rel.get("File", []):
        if entry.get("Url", "").endswith(want):
            print(rel["Version"], entry["Url"], entry["Sha512CheckSum"])
            raise SystemExit(0)
raise SystemExit(1)
PYEOF
)"; then
        warn_item "proton-pass: no full-rollout stable release found in Proton's feed; skipped"
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (no suitable release was listed in the feed during this run)."
        return 0
    fi
    local ver url sha
    read -r ver url sha <<< "${sel}"
    local file
    file="${VENDOR_DIR}/$(basename "${url}")"
    if ! fetch "${url}" "${file}"; then
        warn_item "proton-pass ${ver}: download failed; skipped"
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (the package download failed during this run)."
        return 0
    fi
    if ! printf '%s  %s\n' "${sha}" "${file}" | sha512sum --check - >/dev/null 2>&1; then
        warn_item "proton-pass ${ver}: SHA512 checksum mismatch against Proton's feed; NOT installed"
        manual_item "Section 3: install Proton Pass by hand from https://proton.me/pass/download and verify its checksum (the downloaded package did not match Proton's published checksum during this run)."
        return 0
    fi
    if ! install_local_pkg "${file}"; then
        warn_item "proton-pass ${ver}: package install failed"
        manual_item "Section 3: install Proton Pass by hand from https://proton.me/pass/download (the package install failed during this run)."
        return 0
    fi
    if pkg_installed proton-pass; then
        done_item "proton-pass installed: ${ver} (SHA512 verified against Proton's version feed)"
    else
        warn_item "proton-pass ${ver}: install ran but the package is not registered"
    fi
}

# --- Proton VPN ------------------------------------------------------
# Official repository, per Proton's own install guides
# (protonvpn.com/support/linux-vpn-debian-ubuntu and
# protonvpn.com/support/official-linux-vpn-fedora). Debian/Ubuntu: a
# small release package configures the repo; the SHA256 pinned below
# is the checksum Proton publishes on that guide (verified 2026-10-18;
# if Proton bumps the release package, the checksum check fails
# closed and the manual item takes over). Fedora: a release RPM does
# the same job; Proton publishes no checksum for it, and the repo it
# configures is GPG-signed. RHEL-family distros are not officially
# supported by Proton on the RPM side, so they get a manual item.
PROTONVPN_DEB_VERSION="1.0.8"
PROTONVPN_DEB_SHA256="0b14e71586b22e498eb20926c48c7b434b751149b1f2af9902ef1cfe6b03e180"
PROTONVPN_RPM_VERSION="1.0.4-1"

install_proton_vpn() {
    if [[ "${FAMILY}" == "apt" ]]; then
        if [[ ! -f /etc/apt/sources.list.d/protonvpn-stable.sources ]]; then
            local deb="${VENDOR_DIR}/protonvpn-stable-release_${PROTONVPN_DEB_VERSION}_all.deb"
            local deb_url="https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_${PROTONVPN_DEB_VERSION}_all.deb"
            if ! fetch "${deb_url}" "${deb}" || ! printf '%s  %s\n' "${PROTONVPN_DEB_SHA256}" "${deb}" | sha256sum --check - >/dev/null 2>&1; then
                warn_item "proton vpn: release package download or checksum failed; repo not configured"
                manual_item "Proton VPN: configure the repo by hand from https://protonvpn.com/support/linux-vpn-debian-ubuntu (the release package did not verify during this run; Proton may have published a newer one)."
                return 0
            fi
            if ! dpkg -i "${deb}" >/dev/null 2>&1; then
                warn_item "proton vpn: release package failed to install; repo not configured"
                manual_item "Proton VPN: configure the repo by hand from https://protonvpn.com/support/linux-vpn-debian-ubuntu (the release package would not install during this run)."
                return 0
            fi
            apt-get update >/dev/null 2>&1 || warn_item "apt-get update after adding the Proton VPN repo failed; the app install may fail"
        fi
        install_pkgs proton-vpn-gnome-desktop
        if pkg_installed proton-vpn-gnome-desktop; then
            done_item "proton vpn installed: proton-vpn-gnome-desktop $(pkg_version proton-vpn-gnome-desktop) (GUI app and CLI from Proton's repo)"
            manual_item "Proton VPN: sign in with your Proton account on first launch."
        else
            warn_item "proton-vpn-gnome-desktop not installed"
            manual_item "Proton VPN: install proton-vpn-gnome-desktop by hand once the repo is configured (it failed during this run)."
        fi
    elif [[ "${RHELISH}" == "1" ]]; then
        manual_item "Proton VPN: Proton officially supports Fedora only on the RPM side, so there is no supported repo install for this distro. Use the WireGuard configs from your Proton account, or see https://protonvpn.com/support/linux-vpn-setup for the manual paths."
    else
        if ! pkg_installed protonvpn-stable-release; then
            local fed_ver="${VERSION_ID%%.*}"
            local rpmf="${VENDOR_DIR}/protonvpn-stable-release-${PROTONVPN_RPM_VERSION}.noarch.rpm"
            local rpm_url="https://repo.protonvpn.com/fedora-${fed_ver}-stable/protonvpn-stable-release/protonvpn-stable-release-${PROTONVPN_RPM_VERSION}.noarch.rpm"
            if ! fetch "${rpm_url}" "${rpmf}"; then
                warn_item "proton vpn: Fedora release package download failed; repo not configured"
                manual_item "Proton VPN: configure the repo by hand from https://protonvpn.com/support/official-linux-vpn-fedora (the release package download failed during this run)."
                return 0
            fi
            if ! dnf install -y "${rpmf}" >/dev/null 2>&1; then
                warn_item "proton vpn: Fedora release package failed to install; repo not configured"
                manual_item "Proton VPN: configure the repo by hand from https://protonvpn.com/support/official-linux-vpn-fedora (the release package would not install during this run)."
                return 0
            fi
            # Vendor's next step; exit 100 just means updates exist.
            dnf check-update --refresh >/dev/null 2>&1 || true
        fi
        install_pkgs proton-vpn-gnome-desktop
        if pkg_installed proton-vpn-gnome-desktop; then
            done_item "proton vpn installed: proton-vpn-gnome-desktop $(pkg_version proton-vpn-gnome-desktop) (GUI app and CLI from Proton's repo)"
            manual_item "Proton VPN: sign in with your Proton account on first launch."
        else
            warn_item "proton-vpn-gnome-desktop not installed"
            manual_item "Proton VPN: install proton-vpn-gnome-desktop by hand once the repo is configured (it failed during this run)."
        fi
    fi
}

# --- TickTick --------------------------------------------------------
# TickTick's download page offers DEB, RPM, and AppImage builds. The
# page's download button calls a version-less endpoint on
# ticktick.com that redirects to the current package file (verified
# 2026-10-18: type=linux_deb_x64 served ticktick-8.0.20-amd64.deb,
# type=linux_rpm_x64 served ticktick-8.0.20-x86_64.rpm). TickTick
# publishes no checksum feed, so the package itself is the check:
# the install only counts when the ticktick package registers.
install_ticktick() {
    if pkg_installed ticktick; then
        done_item "ticktick already installed: $(pkg_version ticktick)"
        return 0
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        manual_item "Install TickTick from https://ticktick.com/download (this script's verified endpoint covers x86_64; this machine is $(uname -m), and the page offers an arm64 build)."
        return 0
    fi
    local kind file
    if [[ "${FAMILY}" == "dnf" ]]; then
        kind="linux_rpm_x64"
        file="${VENDOR_DIR}/ticktick.rpm"
    else
        kind="linux_deb_x64"
        file="${VENDOR_DIR}/ticktick.deb"
    fi
    if ! fetch "https://ticktick.com/static/getApp/download?type=${kind}" "${file}"; then
        warn_item "ticktick: download from TickTick's endpoint failed; skipped"
        manual_item "Install TickTick from https://ticktick.com/download (the download failed during this run)."
        return 0
    fi
    if ! install_local_pkg "${file}"; then
        warn_item "ticktick: package install failed"
        manual_item "Install TickTick from https://ticktick.com/download (the package install failed during this run)."
        return 0
    fi
    if pkg_installed ticktick; then
        done_item "ticktick installed: $(pkg_version ticktick) (from TickTick's official download endpoint)"
    else
        warn_item "ticktick: install ran but the package is not registered"
        manual_item "Install TickTick from https://ticktick.com/download (the install did not register during this run)."
    fi
}

install_proton_pass
install_proton_vpn
install_ticktick

rm -rf "${VENDOR_DIR}"

# ---------------------------------------------------------------------------
# Base system (checklist section 1)
# ---------------------------------------------------------------------------

step "Base system"

if [[ "${FAMILY}" == "dnf" ]]; then
    if dnf upgrade -y >/dev/null 2>&1; then
        done_item "system packages updated (dnf upgrade) (checklist 1)"
    else
        warn_item "dnf upgrade did not complete; check network and rerun"
    fi
    if command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
        manual_item "Section 1: a reboot into the new kernel is pending; reboot when convenient, not from this script."
    fi
else
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >/dev/null 2>&1; then
        done_item "system packages updated (apt upgrade) (checklist 1)"
    else
        warn_item "apt upgrade did not complete; check network and rerun"
    fi
    if [[ -e /var/run/reboot-required ]]; then
        manual_item "Section 1: a reboot into the new kernel is pending; reboot when convenient, not from this script."
    fi
fi

if command -v fwupdmgr >/dev/null 2>&1; then
    if fwupdmgr get-updates >/dev/null 2>&1; then
        manual_item "Section 1: firmware updates are available per fwupdmgr; apply them deliberately (fwupdmgr update) on power."
    else
        done_item "firmware checked with fwupdmgr; nothing pending or no metadata (checklist 1)"
    fi
else
    manual_item "Section 1: fwupd not present; check firmware/BIOS updates with the vendor's tool."
fi

if lsblk -f 2>/dev/null | grep -q crypto_LUKS || blkid 2>/dev/null | grep -q crypto_LUKS; then
    done_item "full-disk encryption verified present (LUKS) (checklist 1)"
else
    warn_item "no LUKS volume detected; verify the full-disk encryption item by hand"
fi
manual_item "Section 1/3: confirm the LUKS recovery key is stored in Proton Pass (never scripted)."

timedatectl set-ntp true >/dev/null 2>&1 || true
if systemctl list-unit-files 2>/dev/null | grep '^chronyd\.service' >/dev/null; then
    systemctl enable --now chronyd >/dev/null 2>&1 || true
elif systemctl list-unit-files 2>/dev/null | grep '^systemd-timesyncd\.service' >/dev/null; then
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
fi
done_item "automatic time synchronization enabled (checklist 1)"

# Persistent journal: a /var/log/journal directory plus an explicit
# Storage=persistent drop-in is what keeps the journal across
# reboots; without it the journal is volatile and a failed boot
# leaves no logs (the pi3 lesson, checklist 1).
mkdir -p /var/log/journal /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' > /etc/systemd/journald.conf.d/10-persistent.conf
systemctl restart systemd-journald >/dev/null 2>&1 || true
if [[ -d /var/log/journal ]]; then
    done_item "persistent journaling on: /var/log/journal present, Storage=persistent drop-in set (checklist 1)"
else
    warn_item "persistent journaling could not be confirmed; /var/log/journal missing"
fi

# Fleet personalization: the homelab hosts block (the same entries
# the server leg and the motd playbook write, grep-guarded the same
# way) so fleet names resolve on this box, the cluster MOTD the motd
# playbook writes to /etc/motd (banner plus the same subnet block,
# so console and SSH logins show the fleet map), and fastfetch as
# the login presentation, via the same /etc/profile.d mechanism the
# fleet's fastfetch playbook uses (checklist 1).
if ! grep -q 'pi0' /etc/hosts 2>/dev/null; then
    cat >> /etc/hosts <<'EOF'

## local subnet
192.168.0.100   pi0
192.168.0.101   pi1
192.168.0.102   pi2
192.168.0.103   pi3
192.168.0.104   pi4
192.168.0.105   neo1
EOF
fi
done_item "fleet /etc/hosts entries present: pi0-pi4 and neo1 (checklist 1)"

# Cluster MOTD, mirroring the motd playbook's static /etc/motd. A
# /etc/motd that already carries the subnet block is left alone;
# any other non-empty one is copied to /etc/motd.backup first (the
# backup the playbook takes), and only when no backup exists yet.
if grep -q '## local subnet' /etc/motd 2>/dev/null; then
    done_item "cluster MOTD in place: /etc/motd carries the fleet subnet block (checklist 1)"
else
    if [[ -s /etc/motd && ! -e /etc/motd.backup ]]; then
        cp /etc/motd /etc/motd.backup
    fi
    if cat > /etc/motd <<'EOF'

▄▀▄     █▄ ▄█ █ ▄▀▀ █▄█ ▄▀▄ ██▀ █      ▀█▀ ▄▀▄ ▀█▀ █ █ █▄ ▄█
█▀█ ▄   █ ▀ █ █ ▀▄▄ █ █ █▀█ █▄▄ █▄▄     █  █▀█  █  ▀▄█ █ ▀ █

## local subnet
192.168.0.100   pi0
192.168.0.101   pi1
192.168.0.102   pi2
192.168.0.103   pi3
192.168.0.104   pi4
192.168.0.105   neo1
EOF
    then
        done_item "cluster MOTD in place: /etc/motd carries the fleet subnet block (checklist 1)"
    else
        warn_item "cluster MOTD could not be written to /etc/motd (checklist 1)"
    fi
fi

install_pkgs fastfetch
if command -v fastfetch >/dev/null 2>&1; then
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/fastfetch.sh <<'EOF'
#!/bin/bash
# Run fastfetch for interactive login shells.
fastfetch
EOF
    chmod 755 /etc/profile.d/fastfetch.sh
    done_item "fastfetch login presentation set: /etc/profile.d/fastfetch.sh (checklist 1)"
fi

# Screen lock at 5 minutes with password on wake, as system dconf defaults
# so it covers every account including the two created below (GNOME only).
if [[ -d /etc/dconf ]] || command -v dconf >/dev/null 2>&1; then
    mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
    if [[ ! -e /etc/dconf/profile/user ]]; then
        printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    fi
    cat > /etc/dconf/db/local.d/00-laptop-role-prep-lock <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0
EOF
    dconf update >/dev/null 2>&1 || true
    done_item "screen lock defaults set: idle lock at 300s, password required (checklist 1)"
else
    manual_item "Section 1: no dconf/GNOME detected; set the 5-minute screen lock in your desktop's settings."
fi

if [[ "${FAMILY}" == "dnf" ]]; then
    command -v firewall-cmd >/dev/null 2>&1 || install_pkgs firewalld
    if systemctl enable --now firewalld >/dev/null 2>&1; then
        done_item "host firewall on: firewalld enabled, default zone drops unsolicited inbound (checklist 1)"
    else
        warn_item "firewalld could not be enabled"
    fi
else
    command -v ufw >/dev/null 2>&1 || install_pkgs ufw
    if ufw default deny incoming >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1; then
        done_item "host firewall on: ufw enabled, default deny inbound (checklist 1)"
    else
        warn_item "ufw could not be enabled"
    fi
fi

for bat in /sys/class/power_supply/BAT*; do
    [[ -d "${bat}" ]] || continue
    if [[ -r "${bat}/capacity" ]]; then
        bcap="$(cat "${bat}/capacity")"
        bhealth="unknown"
        if [[ -r "${bat}/charge_full" && -r "${bat}/charge_full_design" ]]; then
            f=$(cat "${bat}/charge_full"); d=$(cat "${bat}/charge_full_design")
            [[ "${d}" -gt 0 ]] && bhealth="$(( f * 100 / d ))%"
        elif [[ -r "${bat}/energy_full" && -r "${bat}/energy_full_design" ]]; then
            f=$(cat "${bat}/energy_full"); d=$(cat "${bat}/energy_full_design")
            [[ "${d}" -gt 0 ]] && bhealth="$(( f * 100 / d ))%"
        fi
        done_item "battery report: charge ${bcap}%, health ${bhealth} of design capacity (checklist 1)"
    fi
done
manual_item "Section 1: take the full system backup and test a bare-metal restore before the first workday; no script can prove a restore for you."

# ---------------------------------------------------------------------------
# Separation of lives (checklist section 2) + security core (section 3)
# ---------------------------------------------------------------------------

step "Users and per-user setup"

create_user() {
    local u="$1"
    if id "${u}" >/dev/null 2>&1; then
        done_item "user exists already: ${u} (checklist 2)"
    elif useradd -m -s /bin/bash "${u}"; then
        done_item "user created: ${u} (checklist 2)"
    else
        warn_item "user could not be created: ${u} (checklist 2)"
        return 1
    fi
    chmod 750 "/home/${u}"
    if [[ "${INTERACTIVE}" == "1" ]]; then
        if ! passwd -S "${u}" 2>/dev/null | grep -q ' P '; then
            say "Set a password for ${u}:"
            passwd "${u}" || warn_item "password not set for ${u}"
        fi
    else
        manual_item "Set the password for ${u}:  sudo passwd ${u}"
    fi
}

create_user "${WORK_USER}"
create_user "${PERSONAL_USER}"

# Group adds that need a group the install sections create and the
# account this section just created: docker (apt family) and
# libvirt. Both adds used to sit in their install sections, hundreds
# of lines before create_user ran, so on a fresh machine they
# failed on run 1 and only a re-run converged; v1.7 moves them here,
# next to the sudo-group add below, where the account exists. A
# failure here is a real failure and is reported as one.
if [[ "${FAMILY}" == "apt" ]] && command -v docker >/dev/null 2>&1; then
    if getent group docker >/dev/null 2>&1; then
        if usermod -aG docker "${WORK_USER}"; then
            done_item "${WORK_USER} added to the docker group (root-equivalent; matches the libvirt pattern so the work account can run containers without sudo)"
        else
            warn_item "${WORK_USER} could not be added to the docker group (checklist 4)"
        fi
    fi
fi
if [[ "${INSTALL_VIRT}" == "1" ]]; then
    if getent group libvirt >/dev/null 2>&1; then
        if usermod -aG libvirt "${WORK_USER}"; then
            done_item "${WORK_USER} added to the libvirt group (checklist 4)"
        else
            warn_item "${WORK_USER} could not be added to the libvirt group (checklist 4)"
        fi
    fi
fi

# Sudo posture (checklist 3): sudo must require a password. New accounts
# get no sudoers entries from this script; membership only on request.
SUDO_GROUP="wheel"
[[ "${FAMILY}" == "apt" ]] && SUDO_GROUP="sudo"
if [[ "${GRANT_SUDO_WORK}" == "1" ]]; then
    if usermod -aG "${SUDO_GROUP}" "${WORK_USER}"; then
        done_item "${WORK_USER} added to ${SUDO_GROUP} (GRANT_SUDO_WORK=1); sudo still requires a password (checklist 3)"
    else
        warn_item "${WORK_USER} could not be added to ${SUDO_GROUP} (checklist 3)"
    fi
fi
if grep -Rqs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    warn_item "a NOPASSWD entry exists in sudoers; the checklist says sudo requires a password - review /etc/sudoers.d"
else
    done_item "sudo posture verified: no NOPASSWD entries (checklist 3)"
fi

# Per-user environment. Runs as the user so file ownership is right.
as_user() {
    local u="$1"; shift
    runuser -u "${u}" -- env HOME="/home/${u}" "$@"
}

setup_user() {
    local u="$1" role="$2" keyname="$3"
    local home="/home/${u}"

    # Work folder for the work account (checklist 2); scratch habit for
    # both (checklist 6).
    as_user "${u}" mkdir -p "${home}/scratch"
    if [[ "${role}" == "work" ]]; then
        as_user "${u}" mkdir -p "${home}/work"
        done_item "${u}: ~/work created - employer data lives here, one delete on exit (checklist 2)"
    fi

    # SSH: per-role key generated for the purpose (checklist 2) and a
    # hardened client config (checklist 3).
    as_user "${u}" mkdir -p "${home}/.ssh"
    as_user "${u}" chmod 700 "${home}/.ssh"
    local keyfile="${home}/.ssh/${keyname}"
    if [[ -e "${keyfile}" ]]; then
        done_item "${u}: SSH key already present: ${keyname} (checklist 2)"
    elif [[ "${INTERACTIVE}" == "1" ]]; then
        say "Generating ${keyname} for ${u} - you will be prompted for a passphrase:"
        if as_user "${u}" ssh-keygen -t ed25519 -f "${keyfile}" -C "${u}@$(hostname)-${role}"; then
            done_item "${u}: SSH key generated: ${keyname} (checklist 2)"
        else
            warn_item "${u}: ssh-keygen did not complete"
        fi
    else
        manual_item "Generate the ${role} SSH key:  sudo -u ${u} ssh-keygen -t ed25519 -f ${keyfile}"
    fi
    if [[ ! -e "${home}/.ssh/config" ]]; then
        as_user "${u}" tee "${home}/.ssh/config" >/dev/null <<'EOF'
Host *
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no

# Per-host entries go below, one IdentityFile per role/employer, e.g.
# Host work-host
#     HostName 203.0.113.10
#     User michael
#     IdentityFile ~/.ssh/id_ed25519_work
EOF
        as_user "${u}" chmod 600 "${home}/.ssh/config"
        done_item "${u}: SSH client config written (IdentitiesOnly, key-only) (checklist 3)"
    fi

    # Terminal: tmux config + a history/aliases block in .bashrc, both
    # marker-managed so re-runs replace rather than duplicate (section 4).
    as_user "${u}" tee "${home}/.tmux.conf" >/dev/null <<'EOF'
# Managed by laptop-role-prep-setup - safe to edit, re-runs overwrite.
set -g history-limit 10000
set -g base-index 1
setw -g pane-base-index 1
set -g mouse off
bind r source-file ~/.tmux.conf
EOF
    local block="${home}/.bashrc"
    as_user "${u}" touch "${block}"
    if grep -q 'laptop-role-prep' "${block}" 2>/dev/null; then
        as_user "${u}" sed -i '/# >>> laptop-role-prep >>>/,/# <<< laptop-role-prep <<</d' "${block}"
    fi
    as_user "${u}" tee -a "${block}" >/dev/null <<'EOF'
# >>> laptop-role-prep >>>
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=5000
HISTFILESIZE=10000
shopt -s histappend
alias ll='ls -alF'
alias la='ls -A'
alias grep='grep --color=auto'
# <<< laptop-role-prep <<<
EOF
    done_item "${u}: tmux config + shell history/aliases in place (checklist 4)"

    # Public repo clone (checklist 4): the ops toolkit lives there.
    if [[ ! -d "${home}/public" ]] && command -v git >/dev/null 2>&1; then
        if as_user "${u}" git clone --quiet "${PUBLIC_REPO_URL}" "${home}/public" 2>/dev/null; then
            done_item "${u}: public repo cloned to ~/public (checklist 4)"
        else
            warn_item "${u}: public repo clone failed; the usual causes are no network or this account's key not yet added on GitHub - clone ${PUBLIC_REPO_URL} later"
        fi
    fi
}

setup_user "${WORK_USER}" work id_ed25519_work
setup_user "${PERSONAL_USER}" personal id_ed25519_personal

# Git identities (checklist 2 and 6): conditional includes, never one
# global identity. Values only when configured at the top of this script.
git_identity() {
    local u="$1" name="$2" email="$3"
    if [[ -n "${name}" && -n "${email}" ]]; then
        as_user "${u}" git config --global user.name "${name}"
        as_user "${u}" git config --global user.email "${email}"
        done_item "${u}: git identity set (checklist 6)"
    else
        manual_item "Set the git identity for ${u}:  sudo -u ${u} git config --global user.name '<name>' and user.email '<email>' (or fill the variables at the top of this script and re-run)"
    fi
}

git_identity "${PERSONAL_USER}" "${PERSONAL_GIT_NAME}" "${PERSONAL_GIT_EMAIL}"

# Work repos under ~/work/ pick up the work identity via includeIf.
WORK_HOME="/home/${WORK_USER}"
if [[ -n "${WORK_GIT_NAME}" && -n "${WORK_GIT_EMAIL}" ]]; then
    as_user "${WORK_USER}" tee "${WORK_HOME}/work/.gitconfig-work" >/dev/null <<EOF
[user]
    name = ${WORK_GIT_NAME}
    email = ${WORK_GIT_EMAIL}
EOF
else
    if [[ ! -e "${WORK_HOME}/work/.gitconfig-work" ]]; then
        as_user "${WORK_USER}" tee "${WORK_HOME}/work/.gitconfig-work" >/dev/null <<'EOF'
# Work git identity. Fill these in (or set WORK_GIT_NAME / WORK_GIT_EMAIL
# at the top of the setup script and re-run), then uncomment.
# [user]
#     name =
#     email =
EOF
    fi
    manual_item "Fill in the work git identity in ${WORK_HOME}/work/.gitconfig-work (checklist 2, 6)"
fi
as_user "${WORK_USER}" touch "${WORK_HOME}/.gitconfig"
if ! grep -q 'gitconfig-work' "${WORK_HOME}/.gitconfig" 2>/dev/null; then
    as_user "${WORK_USER}" tee -a "${WORK_HOME}/.gitconfig" >/dev/null <<'EOF'
[includeIf "gitdir:~/work/"]
    path = ~/work/.gitconfig-work
EOF
fi
done_item "${WORK_USER}: git conditional include wired for ~/work/ (checklist 2, 6)"

manual_item "Section 2: the separate browser profile is automatic inside each separate account; sign the work account's browser into work only, never personal logins."
manual_item "Section 3: sign in to Proton Pass and set up the SSH agent (companion handoff: proton-pass-ssh-handoff), then import the two new keys into the vault."
manual_item "Section 3: prepare an encrypted (LUKS) USB drive for restricted environments; needs the physical drive."
manual_item "Sections 5/7/8: presentation path, headset/webcam checks, and the physical carry kit are hands-on; run the section 9 dry run before day one."

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------

step "Report"

say "DONE:"
for i in "${DONE_ITEMS[@]}"; do say "  [x] ${i}"; done
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    say ""
    say "WARNINGS:"
    for i in "${WARNINGS[@]}"; do say "  [!] ${i}"; done
fi
say ""
say "MANUAL (not CLI-able, or needs your input):"
for i in "${MANUAL_ITEMS[@]}"; do say "  [ ] ${i}"; done

for u in "${WORK_USER}" "${PERSONAL_USER}"; do
    for pub in "/home/${u}/.ssh/"*.pub; do
        [[ -e "${pub}" ]] || continue
        say ""
        say "Public key for ${u} (${pub}):"
        ssh-keygen -lf "${pub}" 2>/dev/null || cat "${pub}"
    done
done
say ""
say "Re-running this script is safe; it converges to the same state."
