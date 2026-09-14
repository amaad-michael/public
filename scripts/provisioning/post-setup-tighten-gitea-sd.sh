#!/usr/bin/env bash
#===============================================================================
# post-setup-tighten.sh v2.0-sd — Gitea lockdown + canary + backup cycle
#
# PURPOSE
#   Run ONCE per node, AFTER the first-run web installer at
#   http://<host>:3000 has completed. Closes the config-write surface,
#   validates HTTP/SSH/hook paths under the FINAL hardened profile,
#   verifies WAL is live on the sqlite DB, and installs the nightly
#   gitea-dump backup timer — the measure that turns SD-card death into
#   a reflash instead of an incident.
#
# PREREQUISITES (script exits early if unmet)
#   1. install-gitea.sh v2.0-sd completed; web installer finished.
#   2. A canary repo exists in the Gitea UI (empty repo is fine).
#   3. The SSH pubkey of the user RUNNING THIS SCRIPT (normally root's
#      ~/.ssh/id_*.pub) is uploaded to a Gitea account with write access
#      to the canary repo.
#   4. Environment variables:
#        export TEST_REPO="michael/canary"     # <owner>/<repo>, no .git
#        export GITEA_HOST="127.0.0.1"         # optional, default shown
#
# EXIT CODES
#   0 = all gates passed; node clear for fleet rollout.
#   1 = a gate failed; message on stdout identifies which.
#
# IDEMPOTENCY
#   Safe to re-run: chmod/sed/unit-writes converge; gates re-confirm state.
#
# BACKUP CYCLE INSTALLED BY THIS SCRIPT
#   systemd timer (not cron.d): zero package deps on minimal Rocky (no
#   cronie), runs as User=git natively, logs to journald, Persistent=true
#   catches missed windows after downtime. 03:00 nightly, 7-day local
#   retention in /var/lib/gitea/dump/.
#   *** Dumps live on the SAME SD card — they are STAGING ONLY. Point
#   your off-node pull (neo1 backup runner) at /var/lib/gitea/dump/. ***
#
# PLATFORM NOTES
#   - systemd-analyze security requires systemd >= 240 (Rocky 8 = 239 ->
#     notice, not failure; Rocky 10 = 257, runs natively).
#   - StrictHostKeyChecking=accept-new (TOFU) for the unattended canary
#     clone: acceptable first contact with a node you just built on your
#     own LAN; pin known_hosts afterward for long-lived nodes.
#   - WAL check is skipped with a notice if the DB isn't sqlite at the
#     default path (i.e. you picked another DB in the installer).
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

echo "==> [1/5] Tightening config surface..."
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

echo "==> [2/5] Verifying lockdown took..."
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

echo "==> [3/5] Verifying WAL mode on sqlite DB (SD write-pattern fix)..."
GITEA_DB="/var/lib/gitea/data/gitea.db"
if [ -f "$GITEA_DB" ]; then
    # Read-only pragma query; safe against the live DB. -wal sidecar
    # existing is itself evidence WAL is active.
    JMODE=$(runuser -s /bin/sh -u git -- sqlite3 "file:${GITEA_DB}?mode=ro" 'PRAGMA journal_mode;' 2>/dev/null || echo unknown)
    if [ "$JMODE" = "wal" ]; then
        echo "PASS: sqlite journal_mode=wal"
    else
        # Not fatal: instance works, but the SD endurance win is absent.
        echo "WARN: journal_mode='${JMODE}' (expected wal) — check [database]"
        echo "      SQLITE_JOURNAL_MODE in app.ini, then restart gitea"
    fi
else
    echo "NOTICE: no sqlite DB at ${GITEA_DB} (non-sqlite backend?) — skipped"
fi

echo "==> [4/5] Canary: HTTP, SSH, and hook paths under final sandbox..."
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

echo "==> [5/5] Installing nightly backup timer + first-dump probe..."
cat <<'EOF' > /etc/systemd/system/gitea-dump.service
[Unit]
Description=Gitea dump backup (staging: /var/lib/gitea/dump — pull off-node!)
After=gitea.service

[Service]
Type=oneshot
User=git
Group=git
WorkingDirectory=/var/lib/gitea/dump
# 03:00 = low-write window; gitea dump against a live low-traffic
# instance is the supported pattern. %% escapes date specifiers for systemd.
ExecStart=/bin/sh -c '/usr/local/bin/gitea dump --config /etc/gitea/app.ini --work-path /var/lib/gitea --file /var/lib/gitea/dump/gitea-$(date +%%Y%%m%%d-%%H%%M).zip'
# 7-day LOCAL retention. Off-node copies (neo1 pull) own long-term policy.
ExecStartPost=/usr/bin/find /var/lib/gitea/dump -name 'gitea-*.zip' -mtime +7 -delete
PrivateTmp=true
NoNewPrivileges=true
EOF
cat <<'EOF' > /etc/systemd/system/gitea-dump.timer
[Unit]
Description=Nightly Gitea dump

[Timer]
OnCalendar=*-*-* 03:00:00
# Catch up after downtime instead of silently skipping a night.
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now gitea-dump.timer
# First dump runs NOW, not at 03:00: an untested backup is not a backup,
# and this also exercises `gitea dump` under the git user before you
# walk away from the node.
if systemctl start gitea-dump.service; then
    # Newest dump by mtime (find, not ls: filenames are machine-generated).
    LATEST_DUMP=$(find /var/lib/gitea/dump -maxdepth 1 -name 'gitea-*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d ' ' -f 2- || true)
    if [ -n "$LATEST_DUMP" ] && [ -s "$LATEST_DUMP" ]; then
        echo "PASS: dump cycle live — $(du -h "$LATEST_DUMP" | cut -f1) at ${LATEST_DUMP}"
    else
        echo "FAIL: dump service ran but produced no archive"; exit 1
    fi
else
    echo "FAIL: gitea-dump.service — journalctl -u gitea-dump -n 30"; exit 1
fi
echo "REMINDER: dumps are staging on the SAME SD card. Point the neo1"
echo "          backup runner at /var/lib/gitea/dump/ before rollout."

echo "==> Sweeping journal for sandbox violations (since restart)..."
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
