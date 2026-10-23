# Health check playbooks

Two report-generating health checks and one SMART data harvester. All three are read-only against the systems they inspect, apart from installing their own prerequisite packages.

| Playbook | Targets | Output |
|---|---|---|
| `health_check_pihole2.yml` | `pi_dns` group | Markdown report per host, on the host and fetched to `./reports/` |
| `health_check_universal2.yml` | `hosts: all` | Markdown report per host, staged in `/tmp` and fetched to `./reports/` |
| `smart-harvest-v1.0.yml` | `pi_all` group by default | One JSON file per host on the controller |

## health_check_pihole2.yml

Pi-hole and Unbound health check for the DNS pair (pi0 and pi4 in the shipped inventory's `pi_dns` group).

- Installs its own prerequisites when missing: dnsutils, sqlite3, netcat-traditional. It uses `community.general.listen_ports_facts`, so that collection must be available.
- System coverage: disk and inode usage, memory, load, top processes by CPU and memory, and a scan for pending apt updates.
- DNS coverage: resolution through Pi-hole (port 53) and directly through Unbound (port 5335) using `google.com` as the test domain; a blocklist test against `doubleclick.net` (blocked means the answer starts with 0.0.0.0); a DNSSEC test against `dnssec-failed.org` (validation is working when no record comes back).
- Pi-hole coverage: service states, the FTL API socket at `/run/pihole/FTL.sock`, the web UI on port 80, an sqlite3 integrity check of `/etc/pihole/pihole-FTL.db`, and FTL statistics, top clients, and top blocked domains from the FTL API on port 4711.
- Log coverage: pihole-FTL and Unbound journal errors over the last hour by default (log_scan_period); failed SSH logins in auth.log and UFW blocks are not time-filtered — each is the last 50 matching lines (log_lines).
- The report is written on the host to `/var/log/health_checks/pihole_unbound_health_check_<host>_<date>_<time>.md` and then copied to `./reports/` on the controller, relative to where `ansible-playbook` was run.

## health_check_universal2.yml

General monthly health check for any host in the inventory, RHEL or Debian family.

- Gathers only minimal facts, then adapts names per OS family: the SSH service is `sshd` on RedHat and `ssh` on Debian, cron is `crond` or `cron`, and the syslog and auth log paths are chosen the same way.
- Coverage: uptime, disk and inode usage, memory, load, top processes, network interfaces, a ping of the default gateway and of 8.8.8.8 (`external_ping_target`), the two critical services (SSH and cron) with full status output for any that are not active, listening TCP ports, pending security updates on RHEL (dnf check-update --security) and pending updates generally on Debian (an apt-get -s upgrade simulation — not security-only), firewall state (firewall-cmd or ufw), and the Debian reboot-required flag.
- Log coverage: journal errors over the last 7 days (log_scan_period), last 50 matching lines (log_lines); failed logins are grepped from the auth log with the same 50-line tail but no time filter.
- The report is written on the host to `/tmp/monthly_health_check_<host>_<timestamp>.md` and then copied to `./reports/` on the controller, relative to where `ansible-playbook` was run.

## smart-harvest-v1.0.yml

Harvests SMART data from every physical disk on the target hosts and stores one JSON report per host on the controller. Collection is read-only and idempotent: re-running overwrites the same report files and never duplicates data, and drives without SMART support (SD cards, some USB enclosures) are captured as unsupported rather than failing the run.

```bash
cd ansible
ansible-playbook -i hosts playbooks/healthchecks/smart-harvest-v1.0.yml
```

- Targets `pi_all` by default. Override the group with a limit, for example `-l pi_rhel`. Examples in this section assume the shipped `ansible/hosts` inventory.
- Installs smartmontools where missing. Disks are auto-discovered with `lsblk`; each one is probed with `smartctl --json --all` under a 60 second timeout.
- Reports land in `smart-data/` beside the playbook on the controller, as `<host>.json`. Each drive entry records SMART support, overall health, model, serial number, current temperature, and power-on hours, plus the full smartctl JSON.

Options, all passed as extra vars:

| Option | Effect |
|---|---|
| `-e smart_keep_history=true` | Also keep a dated copy per host under `smart-data/history/` |
| `-e smart_extra_args="-d sat"` | Pass a device type to smartctl, for drives behind USB enclosures |
| `-e '{"smart_drives":["/dev/sda"]}'` | Pin the drive list instead of auto-discovering with lsblk |
