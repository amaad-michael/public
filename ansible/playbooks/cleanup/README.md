# Cleanup and removal playbooks

> **Warning: this folder deletes things.** Every playbook here removes packages, users, configuration, or logs. The removals are not reversible by re-running anything in this folder; recovery means reinstalling and restoring from whatever backup existed beforehand. Read the per-playbook notes before running one, and note which backups are opt-in.

All four playbooks target `hosts: all` with privilege escalation, so always scope a run with `--limit`.

## cleanup_logs_pihole2.yml

Golden-image log sanitisation for a Pi-hole and Unbound host. Built to wipe logs before a system is imaged or cloned.

Safety gate: the playbook refuses to run unless you pass `-e "sanitize_confirm=true"`, and it fails if it is not running as root (use `--become`).

What it does, in order:

- Stops rsyslog, systemd-journald, pihole-FTL, and unbound.
- Deletes archived Pi-hole logs (`pihole.log.*`, `FTL.log.*`), then deletes and recreates empty `pihole.log` and `FTL.log` owned by the pihole user.
- Deletes archived Unbound logs and recreates an empty `/var/log/unbound.log` if one existed.
- Deletes archived `auth.log`, `syslog`, and `ufw.log` rotations and recreates the active files empty.
- Empties `/root/.bash_history` and `/etc/skel/.bash_history` (deleted and recreated empty, mode 0600).
- Deletes the entire contents of `/var/log/journal` and recreates the directory.
- Restarts the four services.

Deleted log content is gone. There is no backup step in this playbook.

## disable_auto_updates.yml

Turns off automatic system updates so patching stays a deliberate, attended act. It removes nothing, but the change persists until someone reverses it by hand.

- Debian family: stops and disables the `unattended-upgrades` service when present, and writes `APT::Periodic::Unattended-Upgrade "0";` into `/etc/apt/apt.conf.d/20auto-upgrades`.
- RedHat family, version 8 and newer: stops and disables the `dnf-automatic.timer` unit.
- RHEL 7: stops and disables the `yum-cron` service.

## uninstall_jenkins.yml

Complete Jenkins removal for Debian and RedHat family hosts, with a forensic archive taken first.

- Pre-checks for Jenkins artifacts and skips hosts that have none.
- Safety gate: it aborts on any host in a group named `production`, or when `is_production: true` is set for the host.
- Before deleting anything it archives `/var/lib/jenkins`, `/var/log/jenkins`, `/etc/jenkins`, `/var/cache/jenkins`, `/etc/default/jenkins`, and `/etc/sysconfig/jenkins` into `/var/backups/jenkins/jenkins_backup_<timestamp>.tar.gz`, records the archive's SHA-256 in `/var/log/ansible/jenkins_removal.log` and in a `.sha256` file beside the archive, and logs each removal stage to the same log file.
- Then it stops and disables the service, purges the package (apt purge with autoremove, or dnf remove with autoremove), removes the package repository files and keyrings, removes the `jenkins` user (including its home) and group, and deletes the data, log, config, and cache directories.

The installed Jenkins is not recoverable from the playbook; the archive in `/var/backups/jenkins` is the only restore source, and restoring it is a manual job.

## uninstall_pihole2.yml

The Pi-hole and Unbound uninstaller: removes both completely, returning the host to a clean slate for reinstallation. It stops pihole-FTL, lighttpd, nginx, unbound, and dnsmasq; runs the official `pihole uninstall --unattended` when the binary exists; purges the package set (unbound, pihole-FTL, lighttpd, nginx-common, php-common, php-cgi, php-sqlite3, dnsmasq-base) with autoremove; deletes the configuration directories and the `pihole.log`/`FTL.log` files; removes the `pihole` user (including its home) and group; restores `/etc/resolv.conf` to Cloudflare (1.1.1.1 and 1.0.0.1); and finishes with an explicit autoremove and autoclean.

Details that matter:

- Optional backup: `-e backup_enabled=true` archives each configuration directory separately to `/root/pihole_backup_<name>.tar.gz` before deletion. Off by default; with the flag unset, the configuration is deleted with everything else and a reinstall starts from nothing.
- Each run writes a start line to `/var/log/uninstall_dns.log`.
- Final DNS check is gated: `getent hosts google.com` must resolve or the playbook fails. (This gate came from the retired `uninstall_pihole.yml`, whose check was gated while this one's was report-only; the consolidation kept the gate.)

`uninstall_pihole.yml`, the older version of this job, was retired to `deprecated/` on 2026-10-22; this playbook is the only live uninstaller.
