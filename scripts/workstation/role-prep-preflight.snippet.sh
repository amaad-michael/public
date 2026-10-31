# shellcheck shell=bash
# role-prep-preflight.snippet.sh
#
# A pre-flight settings review panel for laptop-role-prep-setup
# (built against version 2.0). NOT a standalone script: this file
# defines one function, role_prep_preflight, and does nothing else.
# Sourcing it is inert (no output, no variables set, safe to source
# twice); executing it is pointless. The maintainer of the setup
# script embeds the function when wanted, by one of the two
# mechanisms below; the setup script itself does not call it.
#
# What the panel does: called after the setup script's
# Configuration block, it shows the nine settings that block
# defines, lets the operator edit the value settings and toggle
# the two switches on a terminal, and writes the reviewed values
# back into the same variables the rest of the script reads, so a
# run after the panel sees the panel's choices exactly as if they
# had been edited into the Configuration block by hand.
#
# Variable contract (names and defaults from the Configuration
# block of laptop-role-prep-setup-v2.0.sh):
#
#   WORK_USER           michael-work                          (value)
#   PERSONAL_USER       michael                               (value)
#   PERSONAL_GIT_NAME   (empty)                               (value)
#   PERSONAL_GIT_EMAIL  (empty)                               (value)
#   WORK_GIT_NAME       (empty)                               (value)
#   WORK_GIT_EMAIL      (empty)                               (value)
#   INSTALL_VIRT        1; the script installs the libvirt
#                       stack only when this is exactly 1     (toggle)
#   GRANT_SUDO_WORK     0; the script adds the work user to
#                       the sudo/wheel group only when this
#                       is exactly 1                          (toggle)
#   PUBLIC_REPO_URL     https://github.com/amaad-michael/public.git
#                                                             (value)
#
# The variables are expected to be set already (the Configuration
# block guarantees it at the call point below); an unset one is
# tolerated and treated as empty. There is deliberately nothing
# else on the panel: the package lists are fixed per distro
# family in the script's install sections, there is no desktop
# choice in the setup script (desktops are the new-box runner's
# step, not this script's), and the firewall, screen lock,
# journal, and backup items are not switches in the script, so
# the panel does not invent switches for them.
#
# Return contract:
#   0    Proceed. Either the operator chose Run (the variables
#        hold the reviewed values), or there was no terminal to
#        review on (stdin or stdout not a TTY, or TERM unset or
#        dumb): then the panel is skipped silently, nothing is
#        printed, and the variables stand as configured.
#   1    Cancel (q, the Cancel row, or end of input at the
#        panel): every variable is restored to the value it had
#        when the function was called; the run should not
#        proceed.
#   130  Interrupted (Ctrl-C or SIGTERM): the terminal and every
#        variable are restored exactly as for Cancel, and the
#        function RETURNS 130. It never exits or kills the
#        calling shell; stopping the run is the call site's
#        business (below).
#
# Edits are tentative until Run: the function snapshots the nine
# variables on entry and restores the snapshot on any non-zero
# return. While the panel is open the function holds the INT and
# TERM traps; it resets both before returning, on every path.
# The setup script sets neither trap, so nothing of its is lost;
# a different host script that sets its own must re-set them
# after the call.
#
# Why the interrupt is handled inside the trap: in bash, a
# trapped Ctrl-C or SIGTERM that arrives while the panel waits
# in a terminal read runs the trap handler and then RESUMES the
# read; a handler that only records a flag therefore leaves the
# panel waiting for the next key (measured, not assumed: the
# flag design hangs, the return design does not). The handler
# below instead does the whole interrupt path itself: reset the
# traps, erase the frame, restore the cursor, put the snapshot
# back, and return 130 from the function. It runs in the
# function's own scope, so it sees the function's locals.
#
# Call wiring: the setup script does NOT run under set -e, so a
# bare call would let a cancelled review fall through into the
# run. Wire the call so a non-zero return stops the script:
#
#   role_prep_preflight || exit 1
#
# Embed mechanism 1 (source this file; preferred, nothing is
# copied): keep this file next to the setup script and add these
# lines immediately after the Configuration block (after its
# closing ---- separator line, before the Bookkeeping section):
#
#   # shellcheck disable=SC1091
#   . "$(dirname "${BASH_SOURCE[0]}")/role-prep-preflight.snippet.sh"
#   role_prep_preflight || exit 1
#
# Embed mechanism 2 (extract): copy every line from the
# ">>> role-prep-preflight >>>" marker line through the
# "<<< role-prep-preflight <<<" marker line, inclusive, into the
# setup script at the same place (immediately after the
# Configuration block), and add the call line after the block:
#
#   role_prep_preflight || exit 1
#
# Both mechanisms load the identical function bytes: the marked
# block below is the whole function, and its byte identity
# between this file and an embedded copy is part of the package's
# test evidence. One consequence of mechanism 2 to know about:
# the checklist embeds the setup script verbatim in its
# section 11, so a setup script with the block pasted in no
# longer matches that copy byte for byte; mechanism 1 leaves the
# setup script untouched and has no such consequence.
#
# Panel keys: the Up/Down arrows or j/k move (wrapping), space
# toggles a switch row, Enter toggles a switch row, edits a value
# row (a prefilled line edit at the panel's foot: Enter accepts,
# and clearing the line on purpose sets an empty value), or
# confirms the Run/Cancel row under the cursor. q cancels from
# anywhere. Pure bash and ANSI, in the same conventions as the
# repo's other panels: an ASCII frame, a reverse-video cursor
# row, the cursor hidden while the panel is drawn and restored
# on every exit from it.

# >>> role-prep-preflight >>>
role_prep_preflight() {
    # No terminal, no review: proceed with the settings as
    # configured, silently (see the return contract above).
    if [[ ! -t 0 || ! -t 1 || -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
        return 0
    fi

    local -a _rpp_vars=(
        WORK_USER PERSONAL_USER
        PERSONAL_GIT_NAME PERSONAL_GIT_EMAIL
        WORK_GIT_NAME WORK_GIT_EMAIL
        INSTALL_VIRT GRANT_SUDO_WORK
        PUBLIC_REPO_URL
    )
    # Parallel to _rpp_vars: "value" rows edit, "toggle" rows flip
    # between 1 and 0 (the script tests both toggles against
    # exactly 1).
    local -a _rpp_kinds=(
        value value
        value value
        value value
        toggle toggle
        value
    )
    local -a _rpp_snap=()
    local _rpp_i="" _rpp_var="" _rpp_val=""
    for _rpp_i in "${!_rpp_vars[@]}"; do
        _rpp_var="${_rpp_vars[$_rpp_i]}"
        _rpp_snap+=("${!_rpp_var:-}")
    done

    local _rpp_cursor=0 _rpp_first=1 _rpp_frame_lines=0
    local _rpp_result="" _rpp_key="" _rpp_rest=""
    local _rpp_line="" _rpp_disp="" _rpp_cur="" _rpp_new=""
    local _rpp_read_rc=0
    local -a _rpp_frame=()

    # The interrupt path lives in this handler, for the reason
    # given in the header: it resets the traps first (no
    # re-entry), erases the frame if one is drawn, restores the
    # cursor and the snapshot, and returns 130 from the function.
    # It never exits, so a shell that sourced the function stays
    # alive. The string is single-quoted on purpose: everything
    # in it is evaluated when a signal arrives, in this
    # function's scope, not when the trap is set.
    trap '
        trap - INT TERM
        if [[ ${_rpp_frame_lines} -gt 0 ]]; then
            printf "\033[%dA" "${_rpp_frame_lines}"
            for ((_rpp_i = 0; _rpp_i < _rpp_frame_lines; _rpp_i++)); do
                printf "\033[2K"
                if [[ ${_rpp_i} -lt $((_rpp_frame_lines - 1)) ]]; then
                    printf "\n"
                fi
            done
            printf "\033[%dA" $((_rpp_frame_lines - 1))
        fi
        printf "\033[?25h"
        for _rpp_i in "${!_rpp_vars[@]}"; do
            printf -v "${_rpp_vars[$_rpp_i]}" "%s" "${_rpp_snap[$_rpp_i]}"
        done
        return 130
    ' INT TERM

    printf '\033[?25l'

    while [[ -z "${_rpp_result}" ]]; do
        # Build the frame.
        _rpp_frame=()
        local _rpp_width=44 _rpp_len=0 _rpp_cursor_line=0
        local _rpp_dashes="" _rpp_border=""
        local -a _rpp_rows=()
        for _rpp_i in "${!_rpp_vars[@]}"; do
            _rpp_var="${_rpp_vars[$_rpp_i]}"
            _rpp_val="${!_rpp_var:-}"
            if [[ "${_rpp_kinds[$_rpp_i]}" == "toggle" ]]; then
                if [[ "${_rpp_val}" == "1" ]]; then
                    _rpp_disp="${_rpp_val} (on)"
                elif [[ -z "${_rpp_val}" ]]; then
                    _rpp_disp="(unset) (off)"
                else
                    _rpp_disp="${_rpp_val} (off)"
                fi
            elif [[ -z "${_rpp_val}" ]]; then
                _rpp_disp="(unset)"
            else
                _rpp_disp="${_rpp_val}"
            fi
            printf -v _rpp_line '%-18s %s' "${_rpp_var}" "${_rpp_disp}"
            _rpp_rows+=("${_rpp_line}")
            _rpp_len=${#_rpp_line}
            if [[ ${_rpp_len} -gt ${_rpp_width} ]]; then
                _rpp_width=${_rpp_len}
            fi
        done
        _rpp_line="laptop-role-prep-setup v2.0: pre-flight settings"
        _rpp_len=${#_rpp_line}
        if [[ ${_rpp_len} -gt ${_rpp_width} ]]; then
            _rpp_width=${_rpp_len}
        fi
        printf -v _rpp_dashes '%*s' $((_rpp_width + 2)) ''
        _rpp_dashes="${_rpp_dashes// /-}"
        _rpp_border="+${_rpp_dashes}+"
        _rpp_frame+=("${_rpp_border}")
        printf -v _rpp_line '| %-*s |' "${_rpp_width}" \
            "laptop-role-prep-setup v2.0: pre-flight settings"
        _rpp_frame+=("${_rpp_line}")
        _rpp_frame+=("${_rpp_border}")
        for _rpp_i in "${!_rpp_rows[@]}"; do
            printf -v _rpp_line '| %-*s |' "${_rpp_width}" "${_rpp_rows[$_rpp_i]}"
            _rpp_frame+=("${_rpp_line}")
        done
        _rpp_frame+=("${_rpp_border}")
        printf -v _rpp_line '| %-*s |' "${_rpp_width}" "Run with these settings"
        _rpp_frame+=("${_rpp_line}")
        printf -v _rpp_line '| %-*s |' "${_rpp_width}" "Cancel (restore settings, run nothing)"
        _rpp_frame+=("${_rpp_line}")
        _rpp_frame+=("${_rpp_border}")
        printf -v _rpp_line '| %-*s |' "${_rpp_width}" "arrows or j/k move, space toggles,"
        _rpp_frame+=("${_rpp_line}")
        printf -v _rpp_line '| %-*s |' "${_rpp_width}" "enter edits or confirms, q cancels"
        _rpp_frame+=("${_rpp_line}")
        _rpp_frame+=("${_rpp_border}")
        if [[ ${_rpp_cursor} -le 8 ]]; then
            _rpp_cursor_line=$((_rpp_cursor + 3))
        else
            _rpp_cursor_line=$((_rpp_cursor + 4))
        fi

        # Draw the frame in place.
        if [[ ${_rpp_first} -eq 1 ]]; then
            _rpp_first=0
        else
            printf '\033[%dA' "${_rpp_frame_lines}"
        fi
        _rpp_frame_lines=${#_rpp_frame[@]}
        for _rpp_i in "${!_rpp_frame[@]}"; do
            if [[ ${_rpp_i} -eq ${_rpp_cursor_line} ]]; then
                printf '\r\033[7m%s\033[0m\n' "${_rpp_frame[$_rpp_i]}"
            else
                printf '\r%s\n' "${_rpp_frame[$_rpp_i]}"
            fi
        done

        # Read one key. A signal here is handled by the trap,
        # which returns from the function; a failed read with no
        # key is end of input, which is a cancel, never a
        # confirm.
        _rpp_key=""
        _rpp_rest=""
        _rpp_read_rc=0
        IFS= read -rsn1 _rpp_key || _rpp_read_rc=$?
        if [[ ${_rpp_read_rc} -ne 0 && -z "${_rpp_key}" ]]; then
            _rpp_result=1
            break
        fi
        if [[ "${_rpp_key}" == $'\033' ]]; then
            IFS= read -rsn2 -t 0.1 _rpp_rest || _rpp_rest=""
            _rpp_key="${_rpp_key}${_rpp_rest}"
        fi

        case "${_rpp_key}" in
            $'\033[A' | k)
                _rpp_cursor=$(((_rpp_cursor + 10) % 11))
                ;;
            $'\033[B' | j)
                _rpp_cursor=$(((_rpp_cursor + 1) % 11))
                ;;
            ' ')
                if [[ ${_rpp_cursor} -le 8 && "${_rpp_kinds[$_rpp_cursor]}" == "toggle" ]]; then
                    _rpp_var="${_rpp_vars[$_rpp_cursor]}"
                    if [[ "${!_rpp_var:-}" == "1" ]]; then
                        printf -v "${_rpp_var}" '%s' "0"
                    else
                        printf -v "${_rpp_var}" '%s' "1"
                    fi
                fi
                ;;
            q)
                _rpp_result=1
                ;;
            '' | $'\n' | $'\r')
                if [[ ${_rpp_cursor} -eq 9 ]]; then
                    _rpp_result=0
                elif [[ ${_rpp_cursor} -eq 10 ]]; then
                    _rpp_result=1
                elif [[ "${_rpp_kinds[$_rpp_cursor]}" == "toggle" ]]; then
                    _rpp_var="${_rpp_vars[$_rpp_cursor]}"
                    if [[ "${!_rpp_var:-}" == "1" ]]; then
                        printf -v "${_rpp_var}" '%s' "0"
                    else
                        printf -v "${_rpp_var}" '%s' "1"
                    fi
                else
                    # Value row: erase the frame and take a
                    # prefilled line edit at its foot. The trap
                    # stays armed during the edit, so an interrupt
                    # here takes the same return-130 path as
                    # anywhere else (the frame is already erased,
                    # so the handler skips its own erase).
                    _rpp_var="${_rpp_vars[$_rpp_cursor]}"
                    _rpp_cur="${!_rpp_var:-}"
                    if [[ ${_rpp_frame_lines} -gt 0 ]]; then
                        printf '\033[%dA' "${_rpp_frame_lines}"
                        for ((_rpp_i = 0; _rpp_i < _rpp_frame_lines; _rpp_i++)); do
                            printf '\033[2K'
                            if [[ ${_rpp_i} -lt $((_rpp_frame_lines - 1)) ]]; then
                                printf '\n'
                            fi
                        done
                        printf '\033[%dA' $((_rpp_frame_lines - 1))
                        printf '\033[?25h'
                        _rpp_frame_lines=0
                    fi
                    printf '%s: ' "${_rpp_var}"
                    _rpp_new=""
                    if ! IFS= read -r -e -i "${_rpp_cur}" _rpp_new; then
                        # End of input mid-edit keeps the current
                        # value; clearing a value is done by
                        # emptying the line and pressing Enter.
                        _rpp_new="${_rpp_cur}"
                    fi
                    printf -v "${_rpp_var}" '%s' "${_rpp_new}"
                    _rpp_first=1
                    printf '\033[?25l'
                fi
                ;;
        esac
    done

    # Single exit path for Run and Cancel: reset the traps first,
    # erase the frame if it is drawn, restore the cursor, and put
    # the snapshot back on a cancel.
    trap - INT TERM
    if [[ ${_rpp_frame_lines} -gt 0 ]]; then
        printf '\033[%dA' "${_rpp_frame_lines}"
        for ((_rpp_i = 0; _rpp_i < _rpp_frame_lines; _rpp_i++)); do
            printf '\033[2K'
            if [[ ${_rpp_i} -lt $((_rpp_frame_lines - 1)) ]]; then
                printf '\n'
            fi
        done
        printf '\033[%dA' $((_rpp_frame_lines - 1))
        _rpp_frame_lines=0
    fi
    printf '\033[?25h'
    if [[ "${_rpp_result}" != "0" ]]; then
        for _rpp_i in "${!_rpp_vars[@]}"; do
            printf -v "${_rpp_vars[$_rpp_i]}" '%s' "${_rpp_snap[$_rpp_i]}"
        done
    fi
    return "${_rpp_result}"
}
# <<< role-prep-preflight <<<
