# Ops Toolkit playbooks

The Ansible form of the Ops Toolkit (`scripts/ops-toolkit/`). One
playbook installs the toolkit's six job scripts, its configuration, and
its six systemd timer/service pairs onto a target host.

| Playbook | Targets | Output |
|---|---|---|
| `ops_toolkit.yml` | `hosts: all` (scope with `--limit`) | Scripts in `/usr/local/sbin`, config in `/etc/ops`, units in `/etc/systemd/system`, six timers enabled |

## 📦 What it installs

Exactly the bash README's "Install (as root)" procedure, step for step:

- The six job scripts plus `common.sh`, mode 0755, into
  `/usr/local/sbin`: `sys-health.sh`, `backup-verify.sh`, `log-clean.sh`,
  `cert-expiry-audit.sh`, `service-uptime.sh`, `tmp-clean.sh`.
- `ops.conf`, `lists/services.txt`, and `lists/ssl_endpoints.txt` into
  `/etc/ops`, mode 0644 — without overwriting files that already exist
  there, so local customisations survive a re-run, exactly like the
  bash install's `[ -f ... ] || install` guard.
- `/var/log/ops` and `/var/lib/ops-toolkit`, mode 0755.
- The six `.service` and six `.timer` unit files, copied **unchanged**
  from `scripts/ops-toolkit/systemd/` (mode 0644 into
  `/etc/systemd/system`). Job set, descriptions, `ExecStart` paths,
  `Nice`/`IOScheduling` settings, and every `OnCalendar` schedule are
  therefore identical by construction, not by transcription.

The schedule each timer carries:

| Job | Schedule (from the timer unit) |
|---|---|
| `sys-health` | Sunday 04:00 |
| `backup-verify` | daily 03:30 |
| `log-clean` | 1st of month 03:00 |
| `cert-expiry-audit` | 1st of month 03:30 |
| `service-uptime` | Sunday 04:30 |
| `tmp-clean` | Monday 02:30 |

All timers keep `Persistent=true` and `RandomizedDelaySec=15m`.

- The six timers are enabled, systemd is reloaded, and the timers are
  started. The scripts themselves run as root via the oneshot services,
  the same user context as the bash install (no `User=` line in the
  units, no account is created).

## 🛠️ Usage

```bash
cd ansible
ansible-playbook -i hosts playbooks/ops-toolkit/ops_toolkit.yml -l pi1
```

Options, passed as extra vars:

| Option | Effect |
|---|---|
| `-e ops_toolkit_manage_systemd_state=false` | Install and enable only; skip the daemon-reload and timer start. For targets whose systemd is not running (containers, chroot test rigs). |

## ✅ Idempotence

Re-running the playbook changes nothing on a converged host: the copy
tasks compare content, the config and lists are never overwritten once
present, and the enable/start tasks report no change. Uninstall is the
bash README's uninstall block run on the target; there is no separate
uninstall playbook for the toolkit.
