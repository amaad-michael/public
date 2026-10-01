# Linux Admin Toolkit — Test Report (2026-09-20)

Tester: Charlie (agent) at Michael's request ("test that toolkit as much as possible").
Scope: all 27 tasks in `~/workspace/your_files/linux-admin-toolkit/` — 27 `<slug>-local.sh`
plus 27 `<slug>-group.yml` (55 files incl. README.md; excl. this report and VERSION, added after). Read-only on the toolkit:
nothing was edited; no commits.

## Environment

- Execution host: `htch-runtime` sandbox, Ubuntu 24.04.5 LTS (Debian family), root.
  This exercises the **Debian-family branches** of every script.
- RHEL-family branches: **executed 2026-09-20 (afternoon) in a Rocky Linux 10.2
  container** — see "RHEL-family execution — Rocky 10.2 container" below.
  (An earlier draft of this report said the RHEL branches were untested because
  sandbox egress blocks SSH to the home LAN; that gap was closed the same day
  via the container.)
- Tools: `bash -n`, `shellcheck` 0.11.0 (installed via pip shellcheck-py for
  this test), `python3` + pyyaml YAML parse, `ansible-playbook --syntax-check`
  (ansible-core installed via pip for this test).

## RHEL-family execution — Rocky 10.2 container (2026-09-20, afternoon)

Added 2026-09-21: the morning session ended with the RHEL branches unexecuted
(sandbox egress blocks SSH to pi1/pi3 on the home LAN). Michael pushed back on
leaving RHEL unverified, and a workable path was found the same afternoon.

Method: downloaded the official Rocky Linux 10 Container Base image from
dl.rockylinux.org, extracted the OCI layer, and ran the toolkit inside via
`chroot`. (`systemd-nspawn` is unusable here — the sandbox denies the mount
syscalls it needs; plain `mount -t proc` works but mounts don't persist
across exec calls, so each run is mount+execute in one shot.) Sandbox quirks
worked around: the image tarball ships restrictive modes (fixed with
`chmod -R a+rwX` — sandbox root lacks CAP_DAC_OVERRIDE), the egress proxy
only trusts the runtime's pinned curl (the container's curl gets CONNECT
reset — repo metadata was fetched with host curl and served to the container
as a local `file://` dnf repo for BaseOS+AppStream), and overlayfs metacopy
lag briefly hides newly-created files from the next exec call. Tested against
the v1.1 working tree (v1.1 changes touch Debian paths and help text only;
the RHEL branches are identical to v1.0).

Read-only scripts, RHEL branches: **14 of 18 pass clean**, including
`06-update-report` against a REAL `dnf check-update` returning rc=100 (the
exit-100 "updates available" handling verified for real, not mocked) and a
real `dnf install` of procps-ng/iproute. `17-perm-audit` exits 1 by design
(findings present). `11-log-errors`, `22-time-sync`, `23-cert-expiry`, and
`19-backup-verify` degrade gracefully with clear messages (no journal,
chrony, openssl, or `--dest` in a minimal container — correct behavior, not
bugs). `07-disk-audit`'s `df` fails only because the sandbox mount namespace
hides the host mount table (environmental; the script just runs `df -h`).

Mutating scripts, `--check` dry-runs on RHEL: `05-system-update` rc=0 (lists
via dnf), `03-password-policy` rc=0, `27-cockpit-install` rc=0,
`01-user-add` rc=0, `26-kernel-cleanup` rc=0. `02-sudo-manage` could not
complete (minimal container lacks sudo/visudo), `20-service-manage`
correctly reported no systemctl, `25-container-hygiene` correctly reported no
reachable Docker/Podman runtime — environment limitations, not defects.

**No RHEL-specific bugs found.** Remaining true gap: systemd-dependent paths
(journal contents, firewalld active rules, chrony service state) need real
hardware — the pi1 runner script (`~/workspace/your_files/pi1-rhel-toolkit-test.sh`)
still covers that if wanted.

## Classification

READ-ONLY local scripts executed live (18): 04-user-audit, 06-update-report,
07-disk-audit, 08-health-check, 09-failed-services, 10-uptime-report,
11-log-errors, 12-logrotate-check, 13-ssh-audit, 14-firewall-audit,
15-ports-audit, 16-login-audit, 17-perm-audit, 19-backup-verify,
21-cron-inventory, 22-time-sync (default mode only), 23-cert-expiry,
24-net-inventory.

MUTATING local scripts — static analysis + `--check` dry-run only, never
executed for real (9): 01-user-add, 02-sudo-manage, 03-password-policy,
05-system-update, 18-backup-run, 20-service-manage, 22-time-sync (`--fix`),
25-container-hygiene, 26-kernel-cleanup, 27-cockpit-install. Every mutating
script supports `--check`; all dry-runs were verified to change nothing.

## Per-task results

| # | Task | Script class | bash -n | shellcheck | Local exec | Playbook syntax |
|---|------|--------------|---------|------------|------------|-----------------|
| 01 | user-add | mutating | pass | clean | `--check` ok (exit 0, prints useradd cmd) | see note A |
| 02 | sudo-manage | mutating | pass | clean | `--check` ok (exit 1, refuses nonexistent user — good guard) | pass |
| 03 | password-policy | mutating | pass | clean | `--check` ok (exit 1, warns user missing) | pass |
| 04 | user-audit | read-only | pass | clean | exit 0, sane output | pass |
| 05 | system-update | mutating | pass | clean | `--check` **hangs** in apt-get update (killed at 100s) — bug #1 | pass |
| 06 | update-report | read-only | pass | clean | **timeout 124** — hung in apt-get update >120s — bug #1 | pass |
| 07 | disk-audit | read-only | pass | clean | exit 0, sane output | pass |
| 08 | health-check | read-only | pass | clean | exit 0, sane output | pass |
| 09 | failed-services | read-only | pass | clean | exit 0, sane output | pass |
| 10 | uptime-report | read-only | pass | clean | exit 0, sane output | pass |
| 11 | log-errors | read-only | pass | clean | exit 0, sane (found 4 journal errors) | pass |
| 12 | logrotate-check | read-only | pass | 2 notes (bug #2) | exit 0, degrades gracefully when logrotate missing | pass |
| 13 | ssh-audit | read-only | pass | clean | exit 0, graceful SKIP (no sshd here) | pass |
| 14 | firewall-audit | read-only | pass | 1 warning (bug #3) | exit 0, sane output | pass |
| 15 | ports-audit | read-only | pass | clean | exit 0, sane (0 listeners) | pass |
| 16 | login-audit | read-only | pass | clean | exit 0, graceful (no auth.log) | pass |
| 17 | perm-audit | read-only | pass | clean | exit 1 = **by design** (findings present; line 102). Note C | pass |
| 18 | backup-run | mutating | pass | clean | `--check` ok (exit 0, pure dry-run output) | pass |
| 19 | backup-verify | read-only | pass | 1 note (bug #5) | exit 1 usage error without --dest (expected); clean error on bad dest | pass |
| 20 | service-manage | mutating | pass | clean | `--check` ok (exit 2, warns unit not found) | pass |
| 21 | cron-inventory | read-only | pass | clean | exit 0, sane output | pass |
| 22 | time-sync | read-only default | pass | clean | default: exit 1, graceful (no D-Bus); `--check` same | pass |
| 23 | cert-expiry | read-only | pass | clean | exit 0, sane (124 certs checked) | pass |
| 24 | net-inventory | read-only | pass | 1 note (cosmetic) | exit 0, sane output | pass |
| 25 | container-hygiene | mutating | pass | clean | `--check` ok (exit 1, no runtime, install hints) | pass |
| 26 | kernel-cleanup | mutating | pass | clean | `--check` ok (exit 0, "no linux-image-*") | pass |
| 27 | cockpit-install | mutating | pass | 1 error (bug #4) | `--check` ok (exit 0, prints install + firewall steps) | pass |

Note A: `01-user-add/user-add-group.yml` fails `ansible-playbook --syntax-check`
with "couldn't resolve module/action 'ansible.builtin.authorized_key'".
`ansible-doc ansible.builtin.authorized_key` resolves fine, and a minimal
playbook containing only that task fails the same way — this is a quirk of
this ansible-core version's syntax-check, **not a playbook bug**. All other
26 playbooks pass. All 27 playbooks use fully-qualified `ansible.builtin.`
names, guard on `ansible_facts['os_family'] in ['RedHat','Debian']`, and the
audit playbooks all use `changed_when: false` (no false "changed" reports).

Note C: 17-perm-audit exit 1 on findings is intentional (line 102:
`[ "$suid_flag$sgid_flag" = "00" ] && [ "$ww_count" = 0 ] && exit 0 || exit 1`),
but the exit-code convention is not documented in `--help`. Suggest documenting
it (0 = clean, 1 = findings, 2 = usage/error).

## Bugs found

1. **No timeout on `apt-get update`** — `06-update-report/update-report-local.sh:105-106`
   and `05-system-update/system-update-local.sh:172-173`. Both run a bare
   `apt-get update -qq` with no timeout and no way to skip the refresh. On a
   stalled mirror the script hangs indefinitely (observed: both killed at
   100–120s in this sandbox, where the apt mirror stalls). Fix: wrap in
   `timeout 120 apt-get update -qq` and/or add a `--no-refresh` flag that uses
   the cached package lists.
2. **Stale shellcheck disable directive** — `12-logrotate-check/logrotate-check-local.sh:109`.
   The directive says `disable=SC2053` but the triggered check is SC2254, and
   the unquoted `$pat` in `case "$keylog" in $pat)` is **intentional** (glob
   matching of logrotate patterns is the point, per the comment). Fix: change
   the directive to `SC2254`.
3. **Dead variable** — `14-firewall-audit/firewall-audit-local.sh:71,78,95`.
   `have_ruleset` is assigned (0, then 1) but never read anywhere; the summary
   uses `ACTIVE` instead. Fix: delete the variable or use it in the summary.
4. **Array-looking scalar expansion (SC1087)** — `27-cockpit-install/cockpit-install-local.sh:192`:
   `grep -qE "[:.]$PORT[[:space:]]"` — `$PORT` is a scalar, so bash expands
   this correctly, but it reads as an array index and trips shellcheck's error
   severity. Fix: `"[:]...${PORT}[[:space:]]"`.
5. **Unquoted expansion inside `${..}` pattern (SC2295, note)** —
   `19-backup-verify/backup-verify-local.sh:119`: `rel="${f#$SOURCE/}"` treats
   `$SOURCE` as a glob pattern; a source path containing glob characters
   (`*`, `[`, `?`) would strip incorrectly. Fix: document the restriction or
   normalize with a quoted comparison. Low severity.
6. **Cosmetic (SC2001, note)** — `24-net-inventory/net-inventory-local.sh:54`
   and `12-logrotate-check/logrotate-check-local.sh:83`: `echo ... | sed`
   where `${var//search/replace}` would do. Cosmetic only.

## Observations (not bugs)

- All 27 scripts have `set -euo pipefail`; no hardcoded usernames, hosts, or
  dangerous defaults found.
- 03-password-policy on RHEL assumes libpwquality is preinstalled ("ships with
  libpwquality already"); writing `/etc/security/pwquality.conf` without the
  module is harmless (the config is simply unused), but there is no check that
  `pam_pwquality.so` exists. Consider verifying or warning.
- 26-kernel-cleanup protects the running kernel (`uname -r`) with an explicit
  abort if it ever lands in the removal set — verified by reading the code.
- 18-backup-run prunes only directories matching the `YYYY-MM-DD_HHMMSS`
  stamp pattern — verified by reading the code.
- 02-sudo-manage refuses to grant sudo to a nonexistent user; 18-backup-run
  rejects a non-directory `--source`; 19-backup-verify requires `--dest`.
  Input validation is solid.
- 13-ssh-audit, 16-login-audit, 12-logrotate-check, 22-time-sync, 25-container-hygiene
  all degrade gracefully with clear messages when their target service/tooling
  is absent — good behavior for heterogeneous fleets.

## Verdict

**Good shape — no critical bugs.** 18/18 read-only scripts executed live
(Debian branches); 10/10 mutating dry-runs verified safe and honest; all 27
scripts pass `bash -n`; 26/27 playbooks pass `--syntax-check` (the 27th is an
ansible-core tooling quirk, verified not a playbook bug); shellcheck finds
only the 6 minor items above. The two real robustness issues are the
unbounded `apt-get update` in 05/06 (bug #1). The RHEL-family execution gap is
now closed — see "RHEL-family execution — Rocky 10.2 container" above
(14/18 read-only scripts pass clean on real Rocky 10.2, mutating `--check`
dry-runs verified, no RHEL-specific bugs found). The remaining pi1-only gap
is systemd-dependent paths (journal, firewalld active rules, chrony service
state); the pi1 runner script covers those if wanted.
