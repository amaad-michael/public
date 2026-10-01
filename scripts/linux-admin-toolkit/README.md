# Linux Admin Toolkit

27 everyday Linux sysadmin tasks, each with two implementations:

- **`<slug>-local.sh`** — standalone Bash script for one server. Auto-detects the
  distro from `/etc/os-release` and works on RHEL-family (`dnf`/`yum`) and
  Debian-family (`apt-get`). Run with `--help` for usage.
- **`<slug>-group.yml`** — Ansible playbook that does the same job across a fleet.
  Run with `-e target_group=<group>` (defaults to `all`).

## Version

**v1.1** (2026-09-20) — fixed 6 minor bugs found by independent testing
(see `TEST-REPORT-2026-09-20.md`):

- `update-report` / `system-update`: `apt-get update` now runs under
  `timeout 120` and both scripts gained a `--no-refresh` flag; previously a
  stalled mirror hung the script indefinitely.
- `password-policy` / `cockpit-install`: same `apt-get update` timeout fix
  (same bug class, found while patching).
- `logrotate-check`: corrected a stale shellcheck directive (SC2053 →
  SC2254).
- `firewall-audit`: the summary now reports whether a ruleset dump was
  actually captured (`have_ruleset` was assigned but never read).
- `cockpit-install`: `${PORT}[[:space:]]` (was `$PORT[[:space:]]`, flagged
  as a possible array expansion).
- `backup-verify`: the `$SOURCE` prefix-strip is now glob-safe for paths
  containing glob characters.
- `net-inventory` / `logrotate-check`: dropped useless `echo | sed`.
- `perm-audit`: `--help` now documents the exit-1-on-findings status.
- Test report amended 2026-09-21 with the Rocky Linux 10.2 container results
  (RHEL branches executed; no RHEL-specific bugs found).

**v1.0** (2026-09-16) — initial build: 27 tasks, Bash + Ansible per task.

## Task index

| # | Task | What it does | Bash | Ansible |
|---|------|--------------|------|---------|
| 01 | User add/remove | Create a user with SSH key and optional sudo, or remove cleanly | [01-user-add/user-add-local.sh](01-user-add/user-add-local.sh) | [01-user-add/user-add-group.yml](01-user-add/user-add-group.yml) |
| 02 | Sudo management | Grant/revoke sudo via `/etc/sudoers.d` drop-in, validated with visudo | [02-sudo-manage/sudo-manage-local.sh](02-sudo-manage/sudo-manage-local.sh) | [02-sudo-manage/sudo-manage-group.yml](02-sudo-manage/sudo-manage-group.yml) |
| 03 | Password policy | Enforce password aging (`chage`) and pam_pwquality baseline | [03-password-policy/password-policy-local.sh](03-password-policy/password-policy-local.sh) | [03-password-policy/password-policy-group.yml](03-password-policy/password-policy-group.yml) |
| 04 | User audit | Report dormant users, empty passwords, duplicate UID 0 (read-only) | [04-user-audit/user-audit-local.sh](04-user-audit/user-audit-local.sh) | [04-user-audit/user-audit-group.yml](04-user-audit/user-audit-group.yml) |
| 05 | System update | Apply full or security-only updates | [05-system-update/system-update-local.sh](05-system-update/system-update-local.sh) | [05-system-update/system-update-group.yml](05-system-update/system-update-group.yml) |
| 06 | Update report | List pending updates, flag reboot-required (read-only) | [06-update-report/update-report-local.sh](06-update-report/update-report-local.sh) | [06-update-report/update-report-group.yml](06-update-report/update-report-group.yml) |
| 07 | Disk audit | Top consumers, largest dirs/files, inode usage (read-only) | [07-disk-audit/disk-audit-local.sh](07-disk-audit/disk-audit-local.sh) | [07-disk-audit/disk-audit-group.yml](07-disk-audit/disk-audit-group.yml) |
| 08 | Health check | CPU, memory, load vs cores with warn/crit thresholds (read-only) | [08-health-check/health-check-local.sh](08-health-check/health-check-local.sh) | [08-health-check/health-check-group.yml](08-health-check/health-check-group.yml) |
| 09 | Failed services | List failed systemd units (read-only) | [09-failed-services/failed-services-local.sh](09-failed-services/failed-services-local.sh) | [09-failed-services/failed-services-group.yml](09-failed-services/failed-services-group.yml) |
| 10 | Uptime report | Uptime, boot time, recent reboot history (read-only) | [10-uptime-report/uptime-report-local.sh](10-uptime-report/uptime-report-local.sh) | [10-uptime-report/uptime-report-group.yml](10-uptime-report/uptime-report-group.yml) |
| 11 | Log errors | Errors/warnings since yesterday via journal or syslog (read-only) | [11-log-errors/log-errors-local.sh](11-log-errors/log-errors-local.sh) | [11-log-errors/log-errors-group.yml](11-log-errors/log-errors-group.yml) |
| 12 | Logrotate check | Verify logrotate configs parse and key logs are covered (read-only) | [12-logrotate-check/logrotate-check-local.sh](12-logrotate-check/logrotate-check-local.sh) | [12-logrotate-check/logrotate-check-group.yml](12-logrotate-check/logrotate-check-group.yml) |
| 13 | SSH audit | Audit sshd_config against a hardening baseline (read-only) | [13-ssh-audit/ssh-audit-local.sh](13-ssh-audit/ssh-audit-local.sh) | [13-ssh-audit/ssh-audit-group.yml](13-ssh-audit/ssh-audit-group.yml) |
| 14 | Firewall audit | Dump active rules: firewalld, ufw, or nftables/iptables (read-only) | [14-firewall-audit/firewall-audit-local.sh](14-firewall-audit/firewall-audit-local.sh) | [14-firewall-audit/firewall-audit-group.yml](14-firewall-audit/firewall-audit-group.yml) |
| 15 | Ports audit | Listening TCP/UDP ports with owning process (read-only) | [15-ports-audit/ports-audit-local.sh](15-ports-audit/ports-audit-local.sh) | [15-ports-audit/ports-audit-group.yml](15-ports-audit/ports-audit-group.yml) |
| 16 | Login audit | Failed logins, per-IP counts, brute-force flags (read-only) | [16-login-audit/login-audit-local.sh](16-login-audit/login-audit-local.sh) | [16-login-audit/login-audit-group.yml](16-login-audit/login-audit-group.yml) |
| 17 | Permission audit | World-writable files, SUID/SGID outside standard paths (read-only) | [17-perm-audit/perm-audit-local.sh](17-perm-audit/perm-audit-local.sh) | [17-perm-audit/perm-audit-group.yml](17-perm-audit/perm-audit-group.yml) |
| 18 | Backup run | rsync to timestamped dir with N-day retention pruning | [18-backup-run/backup-run-local.sh](18-backup-run/backup-run-local.sh) | [18-backup-run/backup-run-group.yml](18-backup-run/backup-run-group.yml) |
| 19 | Backup verify | Latest backup exists, recent enough, spot-check integrity (read-only) | [19-backup-verify/backup-verify-local.sh](19-backup-verify/backup-verify-local.sh) | [19-backup-verify/backup-verify-group.yml](19-backup-verify/backup-verify-group.yml) |
| 20 | Service manage | Enable/start/restart/status a systemd service consistently | [20-service-manage/service-manage-local.sh](20-service-manage/service-manage-local.sh) | [20-service-manage/service-manage-group.yml](20-service-manage/service-manage-group.yml) |
| 21 | Cron inventory | All users' crontabs plus /etc/cron.d and cron.* dirs (read-only) | [21-cron-inventory/cron-inventory-local.sh](21-cron-inventory/cron-inventory-local.sh) | [21-cron-inventory/cron-inventory-group.yml](21-cron-inventory/cron-inventory-group.yml) |
| 22 | Time sync | Check sync health; optionally fix via chrony/systemd-timesyncd | [22-time-sync/time-sync-local.sh](22-time-sync/time-sync-local.sh) | [22-time-sync/time-sync-group.yml](22-time-sync/time-sync-group.yml) |
| 23 | Cert expiry | Scan common cert locations, warn on expiry within N days (read-only) | [23-cert-expiry/cert-expiry-local.sh](23-cert-expiry/cert-expiry-local.sh) | [23-cert-expiry/cert-expiry-group.yml](23-cert-expiry/cert-expiry-group.yml) |
| 24 | Network inventory | Interfaces, IPs, default routes, DNS resolvers (read-only) | [24-net-inventory/net-inventory-local.sh](24-net-inventory/net-inventory-local.sh) | [24-net-inventory/net-inventory-group.yml](24-net-inventory/net-inventory-group.yml) |
| 25 | Container hygiene | Prune stopped containers, dangling images, build cache (docker/podman) | [25-container-hygiene/container-hygiene-local.sh](25-container-hygiene/container-hygiene-local.sh) | [25-container-hygiene/container-hygiene-group.yml](25-container-hygiene/container-hygiene-group.yml) |
| 26 | Kernel cleanup | Remove old kernels, keep N newest, never the running one | [26-kernel-cleanup/kernel-cleanup-local.sh](26-kernel-cleanup/kernel-cleanup-local.sh) | [26-kernel-cleanup/kernel-cleanup-group.yml](26-kernel-cleanup/kernel-cleanup-group.yml) |
| 27 | Cockpit install | Install cockpit, enable cockpit.socket, open 9090/tcp | [27-cockpit-install/cockpit-install-local.sh](27-cockpit-install/cockpit-install-local.sh) | [27-cockpit-install/cockpit-install-group.yml](27-cockpit-install/cockpit-install-group.yml) |

## Distro support

- Scripts read `/etc/os-release` (`ID`/`ID_LIKE`) and pick the right package
  manager and paths automatically: `dnf` (falling back to `yum`) on RHEL-family,
  `apt-get` on Debian-family. Anything else fails with a clear message.
- Playbooks branch on `ansible_facts['os_family']` (`RedHat` / `Debian`).
- Service/tool differences are handled per task: firewalld vs ufw,
  chrony vs systemd-timesyncd, journalctl vs `/var/log/syslog|messages`,
  `/var/log/auth.log` vs `/var/log/secure`.

## Quick start

Bash (single server):

```bash
sudo ./01-user-add/user-add-local.sh --help
sudo ./01-user-add/user-add-local.sh deploy --ssh-key ~/.ssh/id_ed25519.pub --sudo
sudo ./05-system-update/system-update-local.sh --check        # dry run first
sudo ./05-system-update/system-update-local.sh --security-only
./07-disk-audit/disk-audit-local.sh                           # read-only, no sudo needed for most
```

Ansible (fleet):

```bash
ansible-playbook -i inventory 01-user-add/user-add-group.yml \
  -e target_group=webservers -e username=deploy
ansible-playbook -i inventory 05-system-update/system-update-group.yml \
  -e target_group=webservers --check                         # dry run first
ansible-playbook -i inventory 07-disk-audit/disk-audit-group.yml \
  -l db01
```

## Conventions

- Every mutating script supports `--check` (dry run): it prints what it would do
  and changes nothing. Run `--check` before the real thing.
- Read-only scripts (marked above) never change anything.
- Scripts are idempotent where possible: running twice is safe.
- No hardcoded usernames, hosts, or paths — everything is a flag or env var.
- Playbooks use fully-qualified `ansible.builtin.` module names and
  `become: true` only where privilege is actually required.
