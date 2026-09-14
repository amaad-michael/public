#!/usr/bin/env bash
#===============================================================================
# post-setup-tighten.sh — Gitea post-install lockdown + canary validation
#
# PURPOSE
#   Run ONCE per node, AFTER the first-run web installer at
#   http://<host>:3000 has completed. Closes the config-write surface
#   (app.ini group-write + ReadWritePaths=/etc/gitea) that only the web
#   installer legitimately needs, then validates HTTP, SSH, and the
#   server-side hook chain under the FINAL hardened profile.
#
# PREREQUISITES (script exits early if unmet)
#   1. install-gitea.sh completed; web installer finished.
#   2. A canary repo exists in the Gitea UI (empty repo is fine).
#   3. The SSH pubkey of the user RUNNING THIS SCRIPT (normally root's
#      ~/.ssh/id_*.pub) is uploaded to a Gitea account with write access
#      to the canary repo.
#   4. Environment variables set:
#        export TEST_REPO="michael/canary"     # <owner>/<repo>, no .git
#        export GITEA_HOST="127.0.0.1"         # optional, default shown
#
# EXIT CODES
#   0 = all gates passed; node clear for fleet rollout (safe to gate
#       an Ansible play on this).
#   1 = a gate failed; message on stdout identifies which.
#
# IDEMPOTENCY
#   Safe to re-run: chmod/sed are no-ops on an already-tightened node
#   and verification gates re-confirm state.
#
# PLATFORM NOTES
#   - systemd-analyze security requires systemd >= 240. Rocky 8 ships
#     239, so that step degrades to a notice on the pi1/pi3 parity
#     cluster instead of failing.
#   - StrictHostKeyChecking=accept-new (TOFU) is used for the canary
#     clone so the script runs unattended. Acceptable for a first
#     contact with a node you just built on your own LAN; pin known_hosts
#     afterward if the node is long-lived.
#===============================================================================
set -euo pipefail

GITEA_HOST="${GITEA_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
HTTP_PORT="${HTTP_PORT:-3000}"

# Hard-require TEST_REPO: a placeholder default would build a garbage
# clone URL and produce a confusing SSH failure instead of a clear error.
: "${TEST_REPO:?set TEST_REPO=<owner>/<repo> (canary repo, no .git suffix)}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }
[ -f /etc/gitea/app.ini ] || { echo "ERROR: no app.ini — run install first"; exit 1; }

echo "==> [1/4] Tightening config surface..."
# DAC layer: root writes, git group reads, world nothing.
chmod 640 /etc/gitea/app.ini
# Namespace layer: close the /etc write hole punched through
# ProtectSystem=full for the installer. sed is a no-op if already done;
# the verification gate below catches any unexpected unit state.
sed -i 's|^ReadWritePaths=/var/lib/gitea /etc/gitea$|ReadWritePaths=/var/lib/gitea|' \
    /etc/systemd/system/gitea.service
systemctl daemon-reload
# Sandbox/mount namespace is constructed at process start; daemon-reload
# alone does NOT apply it. Timestamp captured so the journal sweep only
# covers the post-restart window (no pre-tighten noise).
RESTART_TS=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart gitea

echo "==> [2/4] Verifying lockdown took..."
if systemctl show gitea -p ReadWritePaths | grep -qx 'ReadWritePaths=/var/lib/gitea'; then
    echo "PASS: namespace hole closed"
else
    echo "FAIL: ReadWritePaths still includes /etc/gitea"; exit 1
fi
# git's login shell is nologin; force /bin/sh or runuser can't exec the
# test at all (which would false-PASS the inverted check below).
if runuser -s /bin/sh -u git -- test -w /etc/gitea/app.ini; then
    echo "FAIL: app.ini still writable by git"; exit 1
else
    echo "PASS: app.ini read-only for git"
fi
if systemctl is-active --quiet gitea; then
    echo "PASS: service active post-restart"
else
    echo "FAIL: service down — journalctl -u gitea -n 50"; exit 1
fi

echo "==> [3/4] Canary: HTTP, SSH, and hook paths under final sandbox..."
# HTTP with retry: gitea needs a moment to bind after restart; a single
# immediate probe races the listener. wget used (installed by the
# install script) — curl is NOT a guaranteed dependency on these nodes.
HTTP_OK=0
for _ in 1 2 3 4 5; do
    if wget -q --spider "http://127.0.0.1:${HTTP_PORT}"; then HTTP_OK=1; break; fi
    sleep 2
done
if [ "$HTTP_OK" -eq 1 ]; then
    echo "PASS: HTTP plane"
else
    echo "FAIL: HTTP not answering on :${HTTP_PORT}"; exit 1
fi

CANARY_DIR=$(mktemp -d)
trap 'rm -rf "$CANARY_DIR"' EXIT
# accept-new: see PLATFORM NOTES header. Scoped to this invocation only.
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
if git clone -q "ssh://git@${GITEA_HOST}:${SSH_PORT}/${TEST_REPO}.git" "$CANARY_DIR/repo"; then
    echo "PASS: SSH clone (built-in SSH server, inside seccomp filter)"
else
    echo "FAIL: SSH clone — key uploaded? repo exists?"; exit 1
fi
cd "$CANARY_DIR/repo"
date > canary.txt
git add canary.txt
# -c identity: fresh nodes have no global git identity for root; without
# this the commit fails and false-FAILs the hook probe.
git -c user.name="canary" -c user.email="canary@localhost" \
    commit -qm "sandbox canary $(date '+%s')"
# THE critical probe: push traverses pre-receive/update/post-receive —
# the child-exec path SystemCallFilter=@system-service could plausibly
# break. HTTP 200 alone never exercises it.
if git push -q origin HEAD; then
    echo "PASS: push (server-side hook chain traversed)"
else
    echo "FAIL: push — sweep below for seccomp denials"; exit 1
fi

echo "==> [4/4] Sweeping journal for sandbox violations (since restart)..."
# EPERM/SIGSYS            -> seccomp (SystemCallFilter) denial
# read-only file system   -> something wants config write post-lockdown
if journalctl -u gitea --since "$RESTART_TS" --no-pager \
     | grep -iE 'eperm|sigsys|operation not permitted|read-only file system'; then
    echo "WARN: denials found — triage before fleet rollout"; exit 1
else
    echo "PASS: no seccomp/namespace denials"
fi

echo ""
# security verb: systemd >= 240 only (Rocky 8 = 239 -> notice, not failure)
if systemd-analyze security gitea >/dev/null 2>&1; then
    systemd-analyze security gitea | tail -1
else
    echo "NOTICE: systemd-analyze security unavailable (systemd < 240) — skipped"
fi
echo "OK: node validated under final hardened profile. Clear for fleet rollout."
