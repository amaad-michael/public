#!/usr/bin/env bash
#
# NAME: new-box-prep-v1.4.sh
# WHAT: The single new-box workflow. Runs this repo's prep scripts in
#       order for a laptop or a server, with GPU tuning as an
#       optional final step (the only delta for a gaming rig):
#         laptop: git setup, ssh setup, Proton VPN, laptop role
#                 prep, desktop environments, optional GPU step
#         server: secure-server-init (conservative, the named
#                 server leg), git setup for the michael user,
#                 then the controller-side follow-ons are printed
#       A laptop run also carries a designation, work or personal:
#       the laptop role prep runs only on a work box, and a
#       personal box skips it. The designation comes from --work
#       or --personal; with neither flag the runner asks on the
#       terminal, and with no terminal and no flag it stops and
#       runs nothing, so a scripted run must pass the flag.
#       A laptop run also carries a desktop choice, resolved up
#       front with the designation: which of MATE, Cinnamon,
#       Xfce, Openbox, and LXDE the box should have, as a
#       multi-select (any one, several, all, or none). The
#       choice comes from --desktop (a comma-separated list, or
#       all, or none); with no flag the runner asks on the
#       terminal, with a checkbox panel where the terminal can
#       draw one and a plain prompt where it cannot, and with
#       no terminal and no flag it stops and runs nothing, so a
#       scripted run must pass the flag.
#       The Proton VPN step is a step of the runner's own: every
#       workstation gets it, work box or personal. It installs
#       the Proton VPN app from Proton's own repositories on the
#       Fedora and Debian families; on the RHEL family, where
#       Proton publishes no app, it records the manual
#       WireGuard/OpenVPN route as a follow-on instead. The
#       desktop step is the runner's other own step: it installs
#       the chosen desktops per OS family (install only; the
#       desktop is picked at the login screen).
# WHY:  One entry point replaces remembering which scripts run in
#       which order on which kind of box (prep scripting audit,
#       2026-10-29). The steps are the repo's existing scripts,
#       each idempotent and runnable on its own; this runner
#       sequences them. The steps of its own are the Proton VPN
#       install and the desktop install, which have no sibling
#       scripts to sequence.
# HOW:  ./new-box-prep-v1.4.sh laptop|server [--work|--personal]
#       [--desktop=<list>] [--with-gpu] [--dry-run]
#       Run it from inside a clone of this repo; sibling scripts
#       are resolved relative to this file and the newest version
#       of each wins. --dry-run prints the resolved plan and runs
#       nothing. Run the server form as root on the target; a
#       server run takes no designation and no desktop choice.
#       The laptop role prep runs under sudo (it requires root);
#       the git and ssh setup steps run as the invoking user. A
#       step that exits nonzero stops the workflow: it names the
#       failed step, exits nonzero itself, and never prints the
#       done footer.
set -uo pipefail

usage() {
    echo "usage: $0 laptop|server [--work|--personal] [--desktop=<list>] [--with-gpu] [--dry-run]" >&2
    exit 2
}

# normalize_desktop_choice <raw answer>: print the canonical
# desktop selection on stdout (the word none, or the chosen
# desktops in the fixed order mate cinnamon xfce openbox lxde,
# space-separated), or print the reason on stderr and return 1.
# The raw answer is a comma-separated list of desktop names,
# or all, or none; case and spaces do not matter, and duplicate
# names collapse. none combined with any desktop (or with all)
# is a contradiction and fails, as does any unknown name.
normalize_desktop_choice() {
    local raw="${1,,}"
    raw="${raw//[[:space:]]/}"
    if [[ -z "$raw" ]]; then
        echo "the desktop choice is empty: name at least one of mate, cinnamon, xfce, openbox, lxde, or all, or none" >&2
        return 1
    fi
    local -a tokens=()
    IFS=',' read -r -a tokens <<< "$raw"
    local -A picked=()
    local saw_none=0 saw_all=0 tok de
    for tok in "${tokens[@]}"; do
        case "$tok" in
            mate|cinnamon|xfce|openbox|lxde) picked["$tok"]=1 ;;
            all) saw_all=1 ;;
            none) saw_none=1 ;;
            *)
                echo "unknown desktop '${tok}': choose from mate, cinnamon, xfce, openbox, lxde, all, or none" >&2
                return 1
                ;;
        esac
    done
    if [[ "$saw_none" -eq 1 && ( "$saw_all" -eq 1 || "${#picked[@]}" -gt 0 ) ]]; then
        echo "none cannot be combined with a desktop choice" >&2
        return 1
    fi
    if [[ "$saw_all" -eq 1 ]]; then
        echo "mate cinnamon xfce openbox lxde"
        return 0
    fi
    if [[ "$saw_none" -eq 1 ]]; then
        echo "none"
        return 0
    fi
    local out=""
    for de in mate cinnamon xfce openbox lxde; do
        if [[ -n "${picked[$de]:-}" ]]; then
            out="${out:+$out }$de"
        fi
    done
    echo "$out"
}

ROLE="${1:-}"
[[ "$ROLE" == "laptop" || "$ROLE" == "server" ]] || usage
shift

BOX_KIND=""
DESKTOP=""
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
        --desktop=*)
            [[ -z "$DESKTOP" ]] || usage
            DESKTOP="$(normalize_desktop_choice "${arg#--desktop=}")" || usage
            ;;
        --desktop)
            echo "--desktop takes a value: --desktop=<list> (comma-separated), --desktop=all, or --desktop=none" >&2
            usage
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

if [[ "$ROLE" == "server" && -n "$DESKTOP" ]]; then
    echo "the desktop choice is for laptops; a server run does not take one" >&2
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

# --- Desktop step (begin) ---------------------------------------
# The runner's second step of its own: install the desktop
# environments the operator chose, on both laptop legs, after
# the role prep and before the GPU step. The choice itself is
# resolved up front with the designation (see the laptop leg):
# a multi-select over MATE, Cinnamon, Xfce, Openbox, and LXDE,
# from --desktop or from the terminal question. On a terminal
# that can draw, the question is the checkbox panel below
# (pure bash and ANSI: no dialog, whiptail, or other TUI
# dependency, so the step stays self-contained on a bare
# box); on any other terminal it is a plain prompt with the
# same parsing. The panel's rules: the up and down arrows (or
# j and k) move, space toggles the row under the cursor, a
# toggles all five desktops at once, and enter confirms. None
# is exclusive in both directions, and the selection is never
# empty inside the panel: none starts selected, choosing a
# desktop clears it, and clearing the last desktop brings it
# back, so enter always confirms a real answer.
# Scope is install only, by design: no display manager is
# installed or switched, no default session is set, and no
# auto-login changes; the step's closing lines say the desktop
# is picked at the login screen's session picker. The
# installed test is the desktop's session file in
# /usr/share/xsessions, because that file is exactly what the
# picker lists, on every family. Provision per family, from
# the exact /etc/os-release ID only (never ID_LIKE): Fedora
# takes its desktop groups (@mate-desktop, @cinnamon-desktop,
# @xfce-desktop, @lxde-desktop; Openbox is a plain package
# there), Debian takes the distro meta-packages, and the
# RHEL family takes each desktop's session package, the form
# EPEL would carry it in. Availability is probed before any
# install (group info, repoquery, or apt-cache), and a
# desktop the family's configured repositories do not carry
# gets a named warning line and the step continues with the
# rest of the selection; it never invents a repository. On
# the evidence of 2026-10-30 that is all five on the RHEL
# family: neither Rocky 10's repos nor the live EPEL 10
# index carries any of the five session packages or a
# desktop group for them, so a Rocky run reports each chosen
# desktop as a manual item and installs none.
desktop_spec() {
    case "$1:$2" in
        fedora:mate)     echo "group mate-desktop mate.desktop the @mate-desktop group" ;;
        fedora:cinnamon) echo "group cinnamon-desktop cinnamon.desktop the @cinnamon-desktop group" ;;
        fedora:xfce)     echo "group xfce-desktop xfce.desktop the @xfce-desktop group" ;;
        fedora:openbox)  echo "package openbox openbox.desktop the openbox package" ;;
        fedora:lxde)     echo "group lxde-desktop LXDE.desktop the @lxde-desktop group" ;;
        debian:mate)     echo "package mate-desktop-environment mate.desktop the mate-desktop-environment package" ;;
        debian:cinnamon) echo "package cinnamon-desktop-environment cinnamon.desktop the cinnamon-desktop-environment package" ;;
        debian:xfce)     echo "package xfce4 xfce.desktop the xfce4 package" ;;
        debian:openbox)  echo "package openbox openbox.desktop the openbox package" ;;
        debian:lxde)     echo "package lxde LXDE.desktop the lxde package" ;;
        rhel:mate)       echo "package mate-session-manager mate.desktop the mate-session-manager package" ;;
        rhel:cinnamon)   echo "package cinnamon cinnamon.desktop the cinnamon package" ;;
        rhel:xfce)       echo "package xfce4-session xfce.desktop the xfce4-session package" ;;
        rhel:openbox)    echo "package openbox openbox.desktop the openbox package" ;;
        rhel:lxde)       echo "package lxsession LXDE.desktop the lxsession package" ;;
    esac
}

desktop_label() {
    case "$1" in
        mate) echo "MATE" ;;
        cinnamon) echo "Cinnamon" ;;
        xfce) echo "Xfce" ;;
        openbox) echo "Openbox" ;;
        lxde) echo "LXDE" ;;
    esac
}

desktop_pick_tui() {
    local -a labels=("MATE" "Cinnamon" "Xfce" "Openbox" "LXDE" "None")
    local -a values=("mate" "cinnamon" "xfce" "openbox" "lxde" "none")
    local -a on=(0 0 0 0 0 1)
    local cursor=0 i j any first=1
    local inner=44 dashes="" border="" line="" key="" rest=""
    local -a frame=()
    printf -v dashes '%*s' 46 ''
    dashes="${dashes// /-}"
    border="+${dashes}+"
    printf '\033[?25l'
    trap 'printf "\033[?25h" >&2; exit 130' INT TERM
    while true; do
        frame=()
        frame+=("$border")
        printf -v line '| %-*s |' "$inner" "Desktop environments"
        frame+=("$line")
        frame+=("$border")
        for i in 0 1 2 3 4 5; do
            local mark="  " box="[ ]"
            [[ "$i" -eq "$cursor" ]] && mark="> "
            [[ "${on[$i]}" -eq 1 ]] && box="[x]"
            printf -v line '| %-*s |' "$inner" "${mark}${box} ${labels[$i]}"
            frame+=("$line")
        done
        frame+=("$border")
        printf -v line '| %-*s |' "$inner" "arrows or j/k move, space toggles,"
        frame+=("$line")
        printf -v line '| %-*s |' "$inner" "a toggles all five, enter confirms"
        frame+=("$line")
        frame+=("$border")
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            printf '\033[%dA' "${#frame[@]}"
        fi
        for i in "${!frame[@]}"; do
            if [[ "$i" -eq $((cursor + 3)) ]]; then
                printf '\r\033[7m%s\033[0m\n' "${frame[$i]}"
            else
                printf '\r%s\n' "${frame[$i]}"
            fi
        done
        key=""
        rest=""
        IFS= read -rsn1 key || key=""
        if [[ "$key" == $'\033' ]]; then
            IFS= read -rsn2 -t 0.1 rest || rest=""
            key="${key}${rest}"
        fi
        case "$key" in
            $'\033[A'|k) cursor=$(( (cursor + 5) % 6 )) ;;
            $'\033[B'|j) cursor=$(( (cursor + 1) % 6 )) ;;
            ' ')
                if [[ "$cursor" -eq 5 ]]; then
                    if [[ "${on[5]}" -eq 0 ]]; then
                        on=(0 0 0 0 0 1)
                    fi
                else
                    if [[ "${on[$cursor]}" -eq 1 ]]; then
                        on[cursor]=0
                    else
                        on[cursor]=1
                    fi
                    on[5]=0
                    any=0
                    for j in 0 1 2 3 4; do
                        [[ "${on[$j]}" -eq 1 ]] && any=1
                    done
                    if [[ "$any" -eq 0 ]]; then
                        on[5]=1
                    fi
                fi
                ;;
            a)
                any=1
                for j in 0 1 2 3 4; do
                    [[ "${on[$j]}" -eq 0 ]] && any=0
                done
                if [[ "$any" -eq 1 ]]; then
                    on=(0 0 0 0 0 1)
                else
                    on=(1 1 1 1 1 0)
                fi
                ;;
            ''|$'\n'|$'\r')
                break
                ;;
        esac
    done
    printf '\033[%dA' "${#frame[@]}"
    for i in "${!frame[@]}"; do
        printf '\033[2K'
        if [[ "$i" -lt $(( ${#frame[@]} - 1 )) ]]; then
            printf '\n'
        fi
    done
    printf '\033[%dA' $(( ${#frame[@]} - 1 ))
    printf '\033[?25h'
    trap - INT TERM
    if [[ "${on[5]}" -eq 1 ]]; then
        DESKTOP="none"
    else
        local out=""
        for j in 0 1 2 3 4; do
            if [[ "${on[$j]}" -eq 1 ]]; then
                out="${out:+$out }${values[$j]}"
            fi
        done
        DESKTOP="$out"
    fi
}

desktop_step() {
    if [[ "$DESKTOP" == "none" ]]; then
        echo "  Desktop environments: none chosen; this step installs nothing."
        return 0
    fi
    local os_id=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1 | tr -d "\"'")"
    fi
    local fam="" fam_name=""
    case "$os_id" in
        fedora|nobara) fam="fedora"; fam_name="Fedora" ;;
        debian|ubuntu) fam="debian"; fam_name="Debian" ;;
        rocky|rhel|centos|almalinux) fam="rhel"; fam_name="RHEL" ;;
        *)
            echo "  Desktop environments: OS ID '${os_id}' is not a family this step knows; skipped."
            return 0
            ;;
    esac
    local sudo_cmd=()
    if [[ "$EUID" -ne 0 ]]; then
        sudo_cmd=(sudo)
    fi
    local -a chosen=()
    read -r -a chosen <<< "$DESKTOP"
    local de label kind spec session phrase
    local needs_install=0
    for de in "${chosen[@]}"; do
        read -r kind spec session phrase <<< "$(desktop_spec "$fam" "$de")"
        if [[ ! -f "/usr/share/xsessions/$session" ]]; then
            needs_install=1
        fi
    done
    if [[ "$fam" == "debian" && "$needs_install" -eq 1 ]]; then
        if ! "${sudo_cmd[@]}" apt-get update; then
            return 1
        fi
    fi
    local ready=0 avail=0
    for de in "${chosen[@]}"; do
        read -r kind spec session phrase <<< "$(desktop_spec "$fam" "$de")"
        label="$(desktop_label "$de")"
        if [[ -f "/usr/share/xsessions/$session" ]]; then
            echo "  Desktop $label: already installed (session file /usr/share/xsessions/$session present); skipped."
            ready=$((ready + 1))
            continue
        fi
        avail=0
        case "$fam:$kind" in
            *:group)
                if dnf group info "$spec" >/dev/null 2>&1; then
                    avail=1
                fi
                ;;
            fedora:package|rhel:package)
                if [[ -n "$(dnf repoquery "$spec" 2>/dev/null)" ]]; then
                    avail=1
                fi
                ;;
            debian:package)
                if apt-cache show "$spec" >/dev/null 2>&1; then
                    avail=1
                fi
                ;;
        esac
        if [[ "$avail" -eq 0 ]]; then
            echo "  Desktop $label: ${phrase} is not available in the configured repositories on the ${fam_name} family; skipped. Install it by hand if you want it."
            continue
        fi
        case "$fam:$kind" in
            *:group)
                if ! "${sudo_cmd[@]}" dnf install -y "@$spec"; then
                    return 1
                fi
                ;;
            fedora:package|rhel:package)
                if ! "${sudo_cmd[@]}" dnf install -y "$spec"; then
                    return 1
                fi
                ;;
            debian:package)
                if ! "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$spec"; then
                    return 1
                fi
                ;;
        esac
        echo "  Desktop $label: installed ${phrase}."
        ready=$((ready + 1))
    done
    if [[ "$ready" -gt 0 ]]; then
        echo "  Pick the desktop at the login screen's session picker;"
        echo "  this step installs only and changes no display manager,"
        echo "  no default session, and no auto-login setting."
    fi
    return 0
}
# --- Desktop step (end) -----------------------------------------

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
    if [[ -z "$DESKTOP" ]]; then
        if [[ -t 0 ]]; then
            if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]]; then
                desktop_pick_tui
            else
                read -r -p "Which desktop environments should this box have, if any? [comma-separated list of mate, cinnamon, xfce, openbox, lxde, or all, or none]: " reply || reply=""
                if ! DESKTOP="$(normalize_desktop_choice "$reply")"; then
                    echo "no valid desktop choice was given; nothing was run" >&2
                    exit 2
                fi
            fi
        fi
    fi
    if [[ -z "$DESKTOP" ]]; then
        echo "a laptop run needs a desktop choice: pass --desktop=<list>, --desktop=all, or --desktop=none, or answer the prompt on a terminal; nothing was run" >&2
        exit 2
    fi
    echo "Desktop selection: ${DESKTOP// /, }"
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
    run_step "desktop environments (the chosen desktops, install only)" desktop_step
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
