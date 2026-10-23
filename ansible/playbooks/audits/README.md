# Audit playbooks

Fleet audit playbooks: read-only collection from every target host,
assembled into one timestamped report file on the controller. These
mirror the bash audit scripts; they change nothing on the targets.

| Playbook | Bash form | Report (on the controller) |
|---|---|---|
| `cron_audit.yml` | `scripts/monitoring/local_cron_checker.sh` + `remote_cron_checker.sh` | `/var/log/cron_audit/cronjobs_full_YYYYMMDD_HHMMSS.log` |

The firewall audit's Ansible form lives with the other firewall
playbooks: `ansible/playbooks/firewall/firewall_audit.yml` (bash form:
`scripts/network/firewall_audit.sh`).

## 📦 cron_audit.yml

Collects, per host, the same material as the bash checkers:

- User crontabs for every account with UID 1000 or higher and a bash
  or sh login shell. This is the **local** checker's filter; the
  remote checker omits the shell filter. Ansible executes on the
  host, so the local checker's rule is the one mirrored — the one
  deliberate difference from the remote script.
- `/etc/crontab`
- Every file in `/etc/cron.d/`
- Listings of `/etc/cron.hourly`, `/etc/cron.daily`, `/etc/cron.weekly`,
  and `/etc/cron.monthly`

Plus one addition, marked as such in the report: systemd timer state
(`systemctl list-timers --all` and the timer unit-file list). The bash
checkers predate the fleet's timer-based jobs; a cron audit that
cannot see timers misses half the schedule on a modern host.

Unlike the bash checkers, which only collect, the playbook also
**flags** two findings per host in a `--- Findings ---` section:

- `FLAG world-writable:` a world-writable file under `/etc/crontab`,
  `/etc/cron.d`, or the crontab spool — anyone could rewrite a
  privileged schedule.
- `FLAG tmp-exec:` a cron entry executing a path under `/tmp`,
  `/var/tmp`, or `/dev/shm` — a scheduled job running from a
  world-writable directory.

Hosts that cannot be reached are reported by Ansible itself (the
bash remote checker logs `ERROR: Unable to connect` and skips; the
playbook's unreachable-host recap is the equivalent record).

## 🛠️ Usage

```bash
cd ansible
ansible-playbook -i hosts playbooks/audits/cron_audit.yml
```

Options, passed as extra vars:

| Option | Effect |
|---|---|
| `-e cron_audit_report_dir=/path` | Where the report lands on the controller. Default: `/var/log/cron_audit`. |
| `-e cron_audit_fail_on_findings=true` | Also fail the run when any host raises a FLAG. Default: flag in the report only. |

Reading other users' crontabs and the spool requires privilege; the
collection play runs with `become: true`, as do the controller-side
report tasks (the default report directory is root-owned).
