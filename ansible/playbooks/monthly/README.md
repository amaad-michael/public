# Monthly maintenance playbooks

Three patching playbooks, one per host class, plus a wrapper script that runs the fleet sequence in one sitting.

| Playbook | Targets | Patching behaviour |
|---|---|---|
| `monthly_maint.yml` | `hosts: all` (RHEL and Debian families) | Full package update, reboot detection, summary printout |
| `monthly_maint_pihole.yml` | `hosts: all`, patching tasks gated to the Debian family | apt dist-upgrade plus a Pi-hole update on hosts that run Pi-hole |
| `monthly_maint_nobara.yml` | `hosts: nobara` group | nobara-sync, dnf, Flatpak, snap; notifications only for firmware and reboots |

## monthly_maint.yml

The general fleet playbook.

- RedHat family: installs `dnf-utils`, upgrades every package with dnf, and detects a pending reboot with `needs-restarting -r`.
- Debian family: apt dist-upgrade with autoremove, and checks for `/var/run/reboot-required`.
- It combines both signals into one `reboot_required` result and prints a summary, including a "Will reboot" line.
- It does not reboot. The reboot task is present in the file but commented out, so the `reboot_msg`, `reboot_pre_delay`, `reboot_post_delay`, and `reboot_timeout` (900 seconds) variables are defined but currently unused. Reboots after this playbook are a separate step; see `ansible/playbooks/reboots/`.

## monthly_maint_pihole.yml

Debian patching with Pi-hole awareness. The update, Pi-hole, and reboot tasks are gated on the Debian OS family, so RHEL hosts in the same run skip them; the timestamp task at the start and the summary printout at the end are not gated.

- Refreshes the apt cache (with retries), runs a dist-upgrade keeping existing config files (`force-confdef,force-confold`), autoremoves only when the upgrade changed something, then autocleans.
- Detects Pi-hole with `pihole status`. On a Pi-hole host it archives `/var/log/pihole/pihole.log` to a timestamped copy, runs `pihole -up` (core, web, and FTL) and `pihole -g` (Gravity), and restarts `pihole-FTL` through a handler.
- Unlike `monthly_maint.yml`, this one does reboot: when `/var/run/reboot-required` exists it reboots with a 10 second pre-delay, a 60 second post-delay, and a 900 second timeout.

## monthly_maint_nobara.yml

Full patching for Nobara desktops. This is the only copy of the Nobara patching playbook (the identical `nobara_patch.yml` under `playbooks/workstation/` was removed 2026-10-22). The `nobara` target group is not in the shipped `ansible/hosts` file, so define it in your inventory.

- Primary mechanism is the native updater: `nobara-sync --no-reboot -y`. If `nobara-sync` is missing the playbook warns and falls back to dnf alone.
- A dnf full upgrade plus autoremove runs regardless, to catch anything the sync missed.
- Flatpaks are updated system-wide and per user, unused runtimes are removed, and snaps are refreshed when snapd is active. Most stages can be run alone with their tag (dnf, flatpak, snap). The nobara_sync tag is the exception: only the sync task itself carries it and its availability check is untagged, so a nobara_sync-only run has no check result to test.
- Firmware is check-only: fwupd metadata is refreshed and available updates are printed with instructions to run `fwupdmgr update` by hand. Nothing is applied automatically.
- Reboots are notify-only: the playbook compares the running kernel with the newest installed kernel and tells you to schedule a reboot. It never reboots the desktop itself.
- Patch runs write `/var/log/ansible-patch/nobara_patch_<date>.log` on the target: the start time, nobara-sync output, the dnf changed flag, the system Flatpak and snap results, and a summary. Firmware findings and per-user Flatpak output appear only in the play output, not in the log.

## 🔧 The wrapper script

`scripts/run_monthly_maintenance.sh` runs the attended fleet sequence:

```bash
bash scripts/run_monthly_maintenance.sh
```

- It prompts once for the SSH password and passes it to Ansible with sshpass (`-k`); the password is unset on exit and on error.
- It runs `monthly_maint.yml` limited to `pi_all`, then `monthly_maint_pihole.yml` limited to `pi4`, then `reboot_simple.yml` against pi0, pi2, pi3, and pi4.
- The whole run appends to `scripts/logs/maintenance.log`, with a timestamped header and a START and DONE line per playbook.

What the wrapper adds over running the playbooks by hand: one entry point, the fixed per-playbook limits above, and a single log of the full sitting.
