#!/usr/bin/env bash
# fedora-desktop-swap-v1.3.sh
#
# ===========================================================================
# READ THIS BEFORE A REAL RUN
# ===========================================================================
#
# What this is: a desktop environment replacement tool for
# Fedora-family systems (Ludora, Fedora, Nobara). It detects every
# desktop environment and standalone window manager it knows, and
# removes any of them you name, or every one that is not on the
# protected list. Desktops on the protected list are never removed.
# The protected list defaults to MATE, Xfce, Cinnamon, LXDE, and
# Openbox; edit PROTECTED below to change it. Structure follows
# new-nobara-setup and laptop-role-prep-setup in this repository.
#
# Version history: v1.0 removed KDE Plasma only, in two phases with
# scripted snapshots. v1.1 generalized removal to any known desktop.
# v1.2 set the protected list. v1.3 consolidates the work into a
# single run from a TTY and removes the scripted snapshot steps.
#
# HOW TO RUN IT (required procedure for real runs):
#
#   1. Log OUT of your graphical session completely. Not lock, not
#      switch user: log out, so no desktop session exists at all.
#   2. Switch to a TTY: Ctrl+Alt+F3. Log in at the text console.
#   3. Run the script with sudo from there.
#
# One run then does everything, in this order: makes sure a
# protected desktop is installed (installing one first if none is),
# installs LightDM and makes it the display manager, stops the old
# display manager, removes the selected desktops, sweeps orphaned
# packages, and verifies the result. You reboot into the updated
# system.
#
# The script enforces the TTY requirement itself: it refuses to run
# while any graphical session exists (checked through loginctl,
# plus the session environment), because removing a desktop out
# from under a live session can destroy that session and the login
# screen with it. Plan mode (--plan) changes nothing and is not
# gated, so it can be previewed from a desktop session.
#
# Snapshots: the script takes none. On Ludora, dnf itself snapshots
# every transaction (the libdnf5 snapper plugin), and those
# snapshots are bootable from the GRUB menu; if anything goes
# wrong, boot one, or run: sudo snapper rollback. To create a named
# restore point before a run, run: sudo snapper create -d
# pre-desktop-swap. On Fedora or Nobara without snapper, there is
# no automatic snapshot; rely on your own backup.
#
# Limitation, stated plainly: earlier versions let you log into the
# new desktop and verify it before the old one was removed. This
# version installs the replacement first and verifies its session
# file and binary are present before anything is removed, but the
# first actual login happens after removal. If that login fails,
# the GRUB snapshot is the recovery path.
#
# Safety properties:
#   - A protected desktop must be installed before anything is
#     removed; the run installs one itself when none is present.
#   - Protected desktops can never be named as removal targets.
#   - Detection is by core package or session binary, and group
#     names are resolved against dnf on THIS system before use.
#     Nothing is removed on the strength of a guessed group name.
#   - Packages that belong to no removed desktop are not touched,
#     including gaming software. Your home directory is not touched.
#   - Idempotent: safe to re-run; completed steps are detected, and
#     a run with nothing to do reports that the system already
#     matches the requested state.
#   - --plan prints the full labeled plan with the exact commands
#     and changes nothing. A real run reprints the plan and asks
#     you to type CONFIRM before it changes anything (or --yes).
#
# Usage (real runs from a TTY):
#   sudo ./fedora-desktop-swap-v1.3.sh                  install a protected desktop + LightDM, remove nothing
#   sudo ./fedora-desktop-swap-v1.3.sh --remove kde     remove KDE Plasma only
#   sudo ./fedora-desktop-swap-v1.3.sh --remove gnome --remove sway
#   sudo ./fedora-desktop-swap-v1.3.sh --remove-unprotected
#   sudo ./fedora-desktop-swap-v1.3.sh --plan --remove-unprotected   print the plan only
#
# When no protected desktop is installed, the run installs Cinnamon
# by default; name a different protected desktop to install instead:
#   sudo ./fedora-desktop-swap-v1.3.sh mate --remove kde
#
# Known desktop ids: kde gnome cinnamon xfce cosmic budgie pantheon
# lxqt lxde mate deepin sway i3 hyprland openbox
#
# ===========================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The protected list: detected desktops on this list are never
# removed. When no protected desktop is installed, the run installs
# one (see DEFAULT_PROTECTED) before removing anything.
PROTECTED=("mate" "xfce" "cinnamon" "lxde" "openbox")

# The protected desktop installed when none is present and none is
# named on the command line.
DEFAULT_PROTECTED="cinnamon"

# Test seams (leave unset in real runs): point the script at a
# fixture os-release or a fixture display-manager symlink.
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
DM_LINK_PATH="${DM_LINK_PATH:-/etc/systemd/system/display-manager.service}"

# ---------------------------------------------------------------------------
# The desktop registry
# ---------------------------------------------------------------------------
# de_field <id> <field>: label | groups (space separated, may be
# empty) | core (core package; also the package removed for window
# managers) | binary (session binary) | dm (its display manager
# package, may be empty) | match (words matched against a session's
# desktop name)

de_field() {
    local id="$1" field="$2"
    case "${id}:${field}" in
        kde:label)      printf 'KDE Plasma' ;;
        kde:groups)     printf 'kde-desktop-environment kde-desktop' ;;
        kde:core)       printf 'plasma-desktop' ;;
        kde:binary)     printf 'plasmashell' ;;
        kde:dm)         printf 'sddm' ;;
        kde:match)      printf 'kde plasma' ;;
        gnome:label)    printf 'GNOME' ;;
        gnome:groups)   printf 'gnome-desktop-environment gnome-desktop' ;;
        gnome:core)    printf 'gnome-shell' ;;
        gnome:binary)   printf 'gnome-shell' ;;
        gnome:dm)       printf 'gdm' ;;
        gnome:match)    printf 'gnome' ;;
        cinnamon:label) printf 'Cinnamon' ;;
        cinnamon:groups) printf 'cinnamon-desktop-environment cinnamon-desktop' ;;
        cinnamon:core)  printf 'cinnamon' ;;
        cinnamon:binary) printf 'cinnamon' ;;
        cinnamon:dm)    printf '' ;;
        cinnamon:match) printf 'cinnamon' ;;
        xfce:label)     printf 'Xfce' ;;
        xfce:groups)    printf 'xfce-desktop-environment xfce-desktop' ;;
        xfce:core)      printf 'xfce4-session' ;;
        xfce:binary)    printf 'xfce4-session' ;;
        xfce:dm)        printf '' ;;
        xfce:match)     printf 'xfce' ;;
        cosmic:label)   printf 'COSMIC' ;;
        cosmic:groups)  printf 'cosmic-desktop-environment cosmic-desktop' ;;
        cosmic:core)    printf 'cosmic-session' ;;
        cosmic:binary)  printf 'cosmic-session' ;;
        cosmic:dm)      printf 'cosmic-greeter' ;;
        cosmic:match)   printf 'cosmic' ;;
        budgie:label)   printf 'Budgie' ;;
        budgie:groups)  printf 'budgie-desktop-environment budgie-desktop' ;;
        budgie:core)    printf 'budgie-desktop' ;;
        budgie:binary)  printf 'budgie-panel' ;;
        budgie:dm)      printf '' ;;
        budgie:match)   printf 'budgie' ;;
        pantheon:label) printf 'Pantheon' ;;
        pantheon:groups) printf 'pantheon-desktop-environment pantheon-desktop' ;;
        pantheon:core)  printf 'gala' ;;
        pantheon:binary) printf 'gala' ;;
        pantheon:dm)    printf '' ;;
        pantheon:match) printf 'pantheon' ;;
        lxqt:label)     printf 'LXQt' ;;
        lxqt:groups)    printf 'lxqt-desktop-environment lxqt-desktop' ;;
        lxqt:core)      printf 'lxqt-session' ;;
        lxqt:binary)    printf 'lxqt-session' ;;
        lxqt:dm)        printf '' ;;
        lxqt:match)     printf 'lxqt' ;;
        lxde:label)     printf 'LXDE' ;;
        lxde:groups)    printf 'lxde-desktop-environment lxde-desktop' ;;
        lxde:core)      printf 'lxsession' ;;
        lxde:binary)    printf 'lxsession' ;;
        lxde:dm)        printf '' ;;
        lxde:match)     printf 'lxde' ;;
        mate:label)     printf 'MATE' ;;
        mate:groups)    printf 'mate-desktop-environment mate-desktop' ;;
        mate:core)      printf 'mate-session-manager' ;;
        mate:binary)    printf 'mate-session' ;;
        mate:dm)        printf '' ;;
        mate:match)     printf 'mate' ;;
        deepin:label)   printf 'Deepin' ;;
        deepin:groups)  printf 'deepin-desktop-environment deepin-desktop' ;;
        deepin:core)    printf 'deepin-daemon' ;;
        deepin:binary)  printf 'dde-desktop' ;;
        deepin:dm)      printf '' ;;
        deepin:match)   printf 'deepin' ;;
        sway:label)     printf 'Sway (window manager)' ;;
        sway:groups)    printf '' ;;
        sway:core)      printf 'sway' ;;
        sway:binary)    printf 'sway' ;;
        sway:dm)        printf '' ;;
        sway:match)     printf 'sway' ;;
        i3:label)       printf 'i3 (window manager)' ;;
        i3:groups)      printf '' ;;
        i3:core)        printf 'i3' ;;
        i3:binary)      printf 'i3' ;;
        i3:dm)          printf '' ;;
        i3:match)       printf 'i3' ;;
        openbox:label)  printf 'Openbox (window manager)' ;;
        openbox:groups) printf '' ;;
        openbox:core)   printf 'openbox' ;;
        openbox:binary) printf 'openbox' ;;
        openbox:dm)     printf '' ;;
        openbox:match)  printf 'openbox' ;;
        hyprland:label) printf 'Hyprland (window manager)' ;;
        hyprland:groups) printf '' ;;
        hyprland:core)  printf 'hyprland' ;;
        hyprland:binary) printf 'Hyprland' ;;
        hyprland:dm)    printf '' ;;
        hyprland:match) printf 'hyprland' ;;
        *)              return 1 ;;
    esac
}

ALL_DE_IDS="kde gnome cinnamon xfce cosmic budgie pantheon lxqt lxde mate deepin sway i3 hyprland openbox"

known_id() {
    case " ${ALL_DE_IDS} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

is_protected() {
    local b
    for b in "${PROTECTED[@]}"; do
        [[ "$1" == "${b}" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Bookkeeping (the laptop-role-prep pattern)
# ---------------------------------------------------------------------------

DONE_ITEMS=()
MANUAL_ITEMS=()
WARNINGS=()

done_item()   { DONE_ITEMS+=("$1"); }
manual_item() { MANUAL_ITEMS+=("$1"); }
warn_item()   { WARNINGS+=("$1"); }

say()  { printf '%s\n' "$*"; }
step() { printf '\n== Step %s: %s ==\n' "$1" "$2"; }

# run <cmd...>: print the command, then execute it. In --plan mode
# the command is printed and never executed.
run() {
    printf '+ %s\n' "$*"
    if [[ "${PLAN_ONLY:-0}" -eq 1 ]]; then
        return 0
    fi
    "$@"
}

print_summary() {
    local items
    say ""
    say "==================================================================="
    say "SUMMARY"
    say "==================================================================="
    if [[ ${#DONE_ITEMS[@]} -gt 0 ]]; then
        say "Done:"
        for items in "${DONE_ITEMS[@]}"; do say "  - ${items}"; done
    fi
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        say "Warnings:"
        for items in "${WARNINGS[@]}"; do say "  - ${items}"; done
    fi
    if [[ ${#MANUAL_ITEMS[@]} -gt 0 ]]; then
        say "Manual follow-ups:"
        for items in "${MANUAL_ITEMS[@]}"; do say "  - ${items}"; done
    fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

INSTALL_PROTECTED="${DEFAULT_PROTECTED}"
PLAN_ONLY=0
ASSUME_YES=0
REMOVE_UNPROTECTED=0
REMOVE_TARGETS=()

usage() {
    printf '%s\n' \
        "Usage (run real runs from a TTY, after logging out):" \
        "  sudo ./fedora-desktop-swap-v1.3.sh [--plan] [--yes] [protected id to install if none is present]" \
        "  sudo ./fedora-desktop-swap-v1.3.sh --remove <id> [--remove <id>] [--plan] [--yes]" \
        "  sudo ./fedora-desktop-swap-v1.3.sh --remove-unprotected [--plan] [--yes]" \
        "" \
        "  (no remove flag)   install a protected desktop + LightDM, remove nothing" \
        "  --remove <id>      remove the named desktop (repeatable)" \
        "  --remove-unprotected  remove every detected desktop that is not protected" \
        "  --purge <id>, --purge-unprotected, --purge-kde" \
        "                     accepted as aliases of the --remove spellings (v1.0-v1.2 compatibility)" \
        "  --plan             print the plan with exact commands; change nothing" \
        "  --yes              skip the typed confirmation (the plan still prints)" \
        "" \
        "  Known ids: ${ALL_DE_IDS}" \
        "  Protected (never removed): ${PROTECTED[*]}" \
        "  Installed when none is present: ${DEFAULT_PROTECTED} (name another protected desktop to change)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        cinnamon|xfce|mate|lxde|openbox) INSTALL_PROTECTED="$1"; shift ;;
        --remove|--purge)
            if [[ $# -lt 2 ]] || ! known_id "$2"; then
                printf '%s needs a known desktop id.\n\n' "$1"
                usage
                exit 2
            fi
            REMOVE_TARGETS+=("$2")
            shift 2
            ;;
        --purge-kde)   REMOVE_TARGETS+=("kde"); shift ;;
        --remove-unprotected|--purge-unprotected) REMOVE_UNPROTECTED=1; shift ;;
        --plan)        PLAN_ONLY=1; shift ;;
        --yes)         ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)
            printf 'Unknown argument: %s\n\n' "$1"
            usage
            exit 2
            ;;
    esac
done

# Dedupe removal targets, preserving order.
if [[ ${#REMOVE_TARGETS[@]} -gt 0 ]]; then
    DEDUPED=()
    for t in "${REMOVE_TARGETS[@]}"; do
        seen=0
        if [[ ${#DEDUPED[@]} -gt 0 ]]; then
            for d in "${DEDUPED[@]}"; do
                [[ "${d}" == "${t}" ]] && seen=1
            done
        fi
        [[ "${seen}" -eq 0 ]] && DEDUPED+=("${t}")
    done
    REMOVE_TARGETS=("${DEDUPED[@]}")
fi

# A protected desktop named as a removal target is refused outright.
if [[ ${#REMOVE_TARGETS[@]} -gt 0 ]]; then
    for t in "${REMOVE_TARGETS[@]}"; do
        if is_protected "${t}"; then
            printf '%s is on the protected list and cannot be removed. Edit PROTECTED in the script to change the protected list.\n' "$(de_field "${t}" label)"
            exit 2
        fi
    done
fi

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }

# resolve_group <candidate...>: print the first group id that dnf on
# THIS system actually knows, so no group name is ever guessed blind.
resolve_group() {
    local candidate
    for candidate in "$@"; do
        if [[ -n "${candidate}" ]] && dnf group info "@${candidate}" >/dev/null 2>&1; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

# de_installed <id>: detected by core package or session binary.
de_installed() {
    local core binary
    core="$(de_field "$1" core)"
    binary="$(de_field "$1" binary)"
    if [[ -n "${core}" ]] && pkg_installed "${core}"; then
        return 0
    fi
    if [[ -n "${binary}" ]] && command -v "${binary}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# detected_ids: every known id detected on this system, protected
# desktops included.
detected_ids() {
    local id
    for id in ${ALL_DE_IDS}; do
        if de_installed "${id}"; then
            printf '%s\n' "${id}"
        fi
    done
}

current_dm() {
    local target=""
    if [[ -L "${DM_LINK_PATH}" ]]; then
        target="$(readlink "${DM_LINK_PATH}")"
        printf '%s' "$(basename "${target}")"
    else
        printf 'unknown'
    fi
}

# protected_present: protected ids currently installed, one per line.
protected_present() {
    local b
    for b in "${PROTECTED[@]}"; do
        if de_installed "${b}"; then
            printf '%s\n' "${b}"
        fi
    done
}

# graphical_session_present: the TTY gate's evidence. True when this
# process sits inside a graphical session, or when loginctl reports
# any session of type wayland or x11 (a graphical session is still
# logged in, and removing a desktop under it is the failure the TTY
# procedure exists to prevent).
graphical_session_present() {
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        return 0
    fi
    case "${XDG_SESSION_TYPE:-}" in
        wayland|x11) return 0 ;;
    esac
    if command -v loginctl >/dev/null 2>&1; then
        local sid stype
        while IFS= read -r sid; do
            [[ -n "${sid}" ]] || continue
            stype="$(loginctl show-session "${sid}" -P Type 2>/dev/null || true)"
            case "${stype}" in
                wayland|x11) return 0 ;;
            esac
        done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
    fi
    return 1
}

# report_detected: the census, printed in plans and real runs alike.
report_detected() {
    local found=0 id mark
    say "Detected on this system:"
    for id in ${ALL_DE_IDS}; do
        if de_installed "${id}"; then
            found=1
            if is_protected "${id}"; then
                mark="protected, stays"
            else
                mark="removable"
            fi
            say "  - $(de_field "${id}" label) [${id}] (${mark})"
        fi
    done
    if [[ "${found}" -eq 0 ]]; then
        say "  (none of the known desktops detected)"
    fi
}

# session_file_for <id>: print the session .desktop file the install
# provided (found by glob, never assumed), or nothing.
session_file_for() {
    local id="$1" sdir sfile sbase
    for sdir in /usr/share/xsessions /usr/share/wayland-sessions; do
        [[ -d "${sdir}" ]] || continue
        for sfile in "${sdir}"/*.desktop; do
            [[ -e "${sfile}" ]] || continue
            sbase="$(basename "${sfile}" | tr '[:upper:]' '[:lower:]')"
            case "${sbase}" in
                *"${id}"*) printf '%s' "${sfile}"; return 0 ;;
            esac
        done
    done
    return 1
}

# ---------------------------------------------------------------------------
# Plan and confirmation
# ---------------------------------------------------------------------------

print_plan() {
    local n=0 t method
    say "==================================================================="
    if [[ ${#ACTIVE_TARGETS[@]} -gt 0 ]]; then
        say "PLAN: desktop removal (single run, from a TTY)"
    else
        say "PLAN: install a protected desktop and LightDM, remove nothing"
    fi
    say "==================================================================="
    if [[ "${NEED_INSTALL}" -eq 1 ]]; then
        n=$((n+1))
        say "Step ${n}: install the $(de_field "${INSTALL_PROTECTED}" label) desktop (its group, or its package when it has no group), and verify its session before anything is removed"
    else
        n=$((n+1))
        say "Step ${n}: no install needed; a protected desktop is already present (${PRESENT_PROTECTED_LABELS})"
    fi
    n=$((n+1))
    say "Step ${n}: install LightDM if missing, stop the current display manager if it is running, and make LightDM the display manager"
    for t in "${ACTIVE_TARGETS[@]}"; do
        n=$((n+1))
        method="${METHODS[${t}]}"
        case "${method}" in
            group:*) say "Step ${n}: remove $(de_field "${t}" label) via its group (@${method#group:}), then remove its display manager if it remains installed" ;;
            pkg:*)   say "Step ${n}: remove the $(de_field "${t}" label) package (${method#pkg:})" ;;
        esac
    done
    if [[ ${#ACTIVE_TARGETS[@]} -gt 0 ]]; then
        n=$((n+1))
        say "Step ${n}: dnf autoremove, to sweep orphaned packages"
        n=$((n+1))
        say "Step ${n}: verify the targets are gone and the protected desktops remain"
        say ""
        say "Rollback, if the removal misbehaves: dnf on Ludora snapshots"
        say "every transaction automatically; boot the pre-removal snapshot"
        say "from the GRUB menu, or run: sudo snapper rollback"
    fi
    say ""
    say "Untouched either way: the protected desktops (${PROTECTED[*]}),"
    say "gaming software, your home directory, and every package that"
    say "belongs to no removed desktop."
}

confirm_or_stop() {
    if [[ "${PLAN_ONLY}" -eq 1 || "${ASSUME_YES}" -eq 1 ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        say "No terminal attached and --yes not given. Stopping before any change."
        exit 1
    fi
    local reply=""
    printf 'Type CONFIRM to proceed: '
    read -r reply
    if [[ "${reply}" != "CONFIRM" ]]; then
        say "Not confirmed. Stopping before any change."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Target resolution (shared by plan mode and real runs)
# ---------------------------------------------------------------------------

# resolve_targets_and_methods: fills ACTIVE_TARGETS, METHODS,
# NEED_INSTALL, PRESENT_PROTECTED_LABELS. Read-only: safe in plan
# mode.
resolve_targets_and_methods() {
    # --remove-unprotected: every detected desktop that is not
    # protected joins the named targets.
    if [[ "${REMOVE_UNPROTECTED}" -eq 1 ]]; then
        local id already
        while IFS= read -r id; do
            if [[ -n "${id}" ]] && ! is_protected "${id}"; then
                already=0
                if [[ ${#REMOVE_TARGETS[@]} -gt 0 ]]; then
                    for t in "${REMOVE_TARGETS[@]}"; do
                        [[ "${t}" == "${id}" ]] && already=1
                    done
                fi
                [[ "${already}" -eq 0 ]] && REMOVE_TARGETS+=("${id}")
            fi
        done < <(detected_ids)
        REMOVE_UNPROTECTED=0
    fi

    # Partition into installed targets (act) and absent ones (note).
    ACTIVE_TARGETS=()
    if [[ ${#REMOVE_TARGETS[@]} -gt 0 ]]; then
        for t in "${REMOVE_TARGETS[@]}"; do
            if de_installed "${t}"; then
                ACTIVE_TARGETS+=("${t}")
            else
                warn_item "$(de_field "${t}" label) is not detected on this system; nothing to remove for [${t}]"
            fi
        done
    fi

    # Which protected desktops are present, and whether one must be
    # installed.
    PRESENT_PROTECTED_LABELS=""
    NEED_INSTALL=0
    local b
    while IFS= read -r b; do
        [[ -n "${b}" ]] || continue
        if [[ -n "${PRESENT_PROTECTED_LABELS}" ]]; then
            PRESENT_PROTECTED_LABELS="${PRESENT_PROTECTED_LABELS}, $(de_field "${b}" label)"
        else
            PRESENT_PROTECTED_LABELS="$(de_field "${b}" label)"
        fi
    done < <(protected_present)
    if [[ -z "${PRESENT_PROTECTED_LABELS}" ]]; then
        NEED_INSTALL=1
    fi

    # Resolve each target's removal method against this system's dnf.
    declare -g -A METHODS=()
    local groups_str gid
    if [[ ${#ACTIVE_TARGETS[@]} -gt 0 ]]; then
        for t in "${ACTIVE_TARGETS[@]}"; do
            groups_str="$(de_field "${t}" groups)"
            if [[ -n "${groups_str}" ]]; then
                # shellcheck disable=SC2206
                gcands=(${groups_str})
                gid="$(resolve_group "${gcands[@]}" || true)"
                if [[ -n "${gid}" ]]; then
                    METHODS["${t}"]="group:${gid}"
                else
                    METHODS["${t}"]="pkg:$(de_field "${t}" core)"
                    if [[ "${PLAN_ONLY}" -eq 0 ]]; then
                        warn_item "no group resolved for $(de_field "${t}" label); falling back to removing its core package"
                    fi
                fi
            else
                METHODS["${t}"]="pkg:$(de_field "${t}" core)"
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# Plan mode: census, plan, and out. Nothing changes.
# ---------------------------------------------------------------------------

if [[ "${PLAN_ONLY}" -eq 1 ]]; then
    if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
        report_detected
        say ""
    fi
    resolve_targets_and_methods
    print_plan
    say ""
    say "Plan mode: nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight (real runs)
# ---------------------------------------------------------------------------

if [[ ${EUID} -ne 0 ]]; then
    say "This script must run as root: sudo ./fedora-desktop-swap-v1.3.sh"
    exit 1
fi

if [[ ! -r "${OS_RELEASE_FILE}" ]]; then
    say "Cannot read ${OS_RELEASE_FILE}; cannot identify this system. Stopping."
    exit 1
fi
# shellcheck disable=SC1090
. "${OS_RELEASE_FILE}"
OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"
case " ${OS_ID} ${OS_LIKE} " in
    *" fedora "*|*" ludora "*|*" nobara "*)
        : # the dnf family this tool is written for
        ;;
    *)
        say "This tool targets the Fedora family (Ludora, Fedora, Nobara)."
        say "Detected ID=${OS_ID}, ID_LIKE=${OS_LIKE}. Stopping."
        exit 1
        ;;
esac
if ! command -v dnf >/dev/null 2>&1; then
    say "dnf not found. Stopping."
    exit 1
fi

# The TTY gate: the single-run design's one hard precondition.
if graphical_session_present; then
    say "A graphical session is present, or you are running this from"
    say "inside one. This tool only runs with no graphical session:"
    say "  1. Log OUT of your graphical session completely."
    say "  2. Switch to a TTY (Ctrl+Alt+F3) and log in at the console."
    say "  3. Run the script again from there."
    say "Stopping before any change. (To preview without changing"
    say "anything from your desktop, add --plan.)"
    exit 1
fi
if ! command -v loginctl >/dev/null 2>&1; then
    warn_item "loginctl not found; the graphical-session check relied on the environment alone"
fi
say "Detected: ${PRETTY_NAME:-${OS_ID}} (no graphical session; TTY requirement satisfied)"
report_detected
say ""

resolve_targets_and_methods

# Nothing to remove and nothing to set up: the system already
# matches the requested state.
DM_NOW_EARLY="$(current_dm)"
if [[ ${#ACTIVE_TARGETS[@]} -eq 0 && "${NEED_INSTALL}" -eq 0 && "${DM_NOW_EARLY}" == "lightdm.service" ]]; then
    say "Nothing to do: no removal target is installed, a protected"
    say "desktop is present (${PRESENT_PROTECTED_LABELS}), and LightDM"
    say "is already the display manager."
    print_summary
    exit 0
fi

print_plan
confirm_or_stop

STEP_N=0

# ---------------------------------------------------------------------------
# Step: make sure a protected desktop is installed (installing one
# if none is), and verify its session BEFORE anything is removed.
# ---------------------------------------------------------------------------

STEP_N=$((STEP_N+1))
step "${STEP_N}" "Make sure a protected desktop is installed"
if [[ "${NEED_INSTALL}" -eq 0 ]]; then
    done_item "protected desktop already present: ${PRESENT_PROTECTED_LABELS}"
else
    DE_LABEL="$(de_field "${INSTALL_PROTECTED}" label)"
    DE_GROUPS_STR="$(de_field "${INSTALL_PROTECTED}" groups)"
    if [[ -z "${DE_GROUPS_STR}" ]]; then
        # No desktop group exists for this one (the window managers):
        # it installs as a plain package.
        run dnf install -y "$(de_field "${INSTALL_PROTECTED}" core)"
        done_item "${DE_LABEL} installed as a package (it has no desktop group)"
    else
        # shellcheck disable=SC2206
        DE_GROUPS=(${DE_GROUPS_STR})
        DE_GROUP="$(resolve_group "${DE_GROUPS[@]}" || true)"
        if [[ -z "${DE_GROUP}" ]]; then
            say "None of the expected ${DE_LABEL} group ids exist on this system"
            say "(${DE_GROUPS_STR}). Stopping before any change."
            print_summary
            exit 1
        fi
        run dnf group install -y "@${DE_GROUP}"
        done_item "${DE_LABEL} desktop group installed (@${DE_GROUP})"
    fi
    # The verification is the single-run design's safety anchor: the
    # replacement must demonstrably exist before anything is removed.
    DE_BINARY="$(de_field "${INSTALL_PROTECTED}" binary)"
    DE_SESSION_FILE="$(session_file_for "${INSTALL_PROTECTED}" || true)"
    if [[ -n "${DE_SESSION_FILE}" ]] && command -v "${DE_BINARY}" >/dev/null 2>&1; then
        done_item "${DE_LABEL} session verified: ${DE_SESSION_FILE} and the ${DE_BINARY} binary are present"
    else
        say "${DE_LABEL} was installed but its session could not be verified"
        say "(looked for a .desktop entry naming ${INSTALL_PROTECTED} under"
        say "/usr/share/xsessions or /usr/share/wayland-sessions, and the"
        say "${DE_BINARY} binary). Nothing has been removed. Stopping"
        say "before the removal; fix the install and re-run."
        print_summary
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step: LightDM as display manager (install if missing, stop the old
# display manager, switch). From a TTY, stopping the display
# manager affects no session.
# ---------------------------------------------------------------------------

STEP_N=$((STEP_N+1))
step "${STEP_N}" "Set LightDM as the display manager"
if ! pkg_installed lightdm; then
    run dnf install -y lightdm lightdm-gtk
    done_item "LightDM installed"
fi
if ! systemctl cat lightdm.service >/dev/null 2>&1; then
    say "lightdm.service does not exist after install; switching the"
    say "display manager would strand the login screen. Nothing has"
    say "been removed. Stopping."
    print_summary
    exit 1
fi
DM_NOW="$(current_dm)"
if [[ "${DM_NOW}" == "lightdm.service" ]]; then
    done_item "LightDM is already the display manager"
else
    if [[ "${DM_NOW}" != "unknown" ]]; then
        if systemctl is-active --quiet "${DM_NOW}"; then
            run systemctl stop "${DM_NOW}"
            done_item "stopped the running display manager (${DM_NOW})"
        fi
        run systemctl disable "${DM_NOW}"
    fi
    run systemctl enable -f lightdm.service
    done_item "display manager switched from ${DM_NOW} to lightdm.service (the old one is disabled, not removed)"
fi

# ---------------------------------------------------------------------------
# Steps: remove each target, then remove its display manager if it
# remains installed and is not the active one.
# ---------------------------------------------------------------------------

for t in "${ACTIVE_TARGETS[@]}"; do
    STEP_N=$((STEP_N+1))
    step "${STEP_N}" "Remove $(de_field "${t}" label)"
    method="${METHODS[${t}]}"
    case "${method}" in
        group:*)
            run dnf group remove -y "@${method#group:}"
            done_item "$(de_field "${t}" label) group removed (@${method#group:})"
            ;;
        pkg:*)
            run dnf remove -y "${method#pkg:}"
            done_item "$(de_field "${t}" label) package removed (${method#pkg:})"
            ;;
    esac
    t_dm="$(de_field "${t}" dm)"
    if [[ -n "${t_dm}" ]] && pkg_installed "${t_dm}"; then
        if [[ "$(current_dm)" != "${t_dm}.service" ]]; then
            run dnf remove -y "${t_dm}"
            done_item "${t_dm} removed (it belonged to $(de_field "${t}" label) and is not the active display manager)"
        else
            warn_item "${t_dm} is still the active display manager; left in place"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Final steps: sweep orphaned packages, verify.
# ---------------------------------------------------------------------------

if [[ ${#ACTIVE_TARGETS[@]} -gt 0 ]]; then
    STEP_N=$((STEP_N+1))
    step "${STEP_N}" "Remove orphaned packages"
    run dnf autoremove -y
    done_item "dnf autoremove completed"

    STEP_N=$((STEP_N+1))
    step "${STEP_N}" "Verify the result"
    for t in "${ACTIVE_TARGETS[@]}"; do
        core="$(de_field "${t}" core)"
        if [[ -n "${core}" ]] && pkg_installed "${core}"; then
            warn_item "$(de_field "${t}" label) core package (${core}) is STILL installed; the removal did not fully take"
            manual_item "Inspect the dnf output above for [${t}]; the automatic dnf snapshot from this run is the rollback if the system misbehaves."
        else
            done_item "$(de_field "${t}" label) is removed"
        fi
    done
    for b in "${PROTECTED[@]}"; do
        if de_installed "${b}"; then
            done_item "protected desktop $(de_field "${b}" label) is still installed"
        fi
    done
    if [[ "$(current_dm)" == "lightdm.service" ]]; then
        done_item "display manager is lightdm.service"
    fi
fi

print_summary
say ""
if [[ ${#ACTIVE_TARGETS[@]} -gt 0 ]]; then
    say "Removal complete. Reboot into the updated system:"
    say "  sudo reboot"
    say "If anything is wrong, boot the snapshot dnf took of this run"
    say "from the GRUB menu, or roll back with: sudo snapper rollback"
else
    say "Setup complete; nothing was removed. Reboot when ready:"
    say "  sudo reboot"
    say "Select your desktop on the LightDM login screen."
fi
