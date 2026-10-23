# Ops Toolkit (Bash + systemd timers)

This toolkit provides ready-to-use Bash scripts and systemd timers for routine Linux administration tasks that lend themselves well to shell automation.

## 📦 Included jobs

- Weekly System Resource Health Check (`sys-health.sh`)
- Daily Backup Verification (weekly restore test) (`backup-verify.sh`)
- Monthly Log Rotation & Cleanup (`log-clean.sh`)
- Monthly SSL Certificate Expiry Review (`cert-expiry-audit.sh`)
- Weekly Service Uptime Review (`service-uptime.sh`)
- Weekly Temp & Junk File Cleanup (`tmp-clean.sh`)

## 📋 Requirements

- systemd (timers and services)
- Common utilities: `bash`, `awk`, `grep`, `sed`, `find`, `gzip`, `tar`, `logrotate`, `openssl`, `vmstat` (from `procps`), `timeout` (from GNU coreutils)
- Network access from the server to SSL endpoints for certificate checks

## 🛠️ Install (as root)

Run from this folder (scripts/ops-toolkit/):

```bash

# Copy scripts

install -d /usr/local/sbin
install -m 0755 *.sh /usr/local/sbin/

# Config and lists

install -d /etc/ops
[ -f /etc/ops/ops.conf ] || install -m 0644 ops.conf /etc/ops/ops.conf
[ -f /etc/ops/services.txt ] || install -m 0644 lists/services.txt /etc/ops/services.txt
[ -f /etc/ops/ssl_endpoints.txt ] || install -m 0644 lists/ssl_endpoints.txt /etc/ops/ssl_endpoints.txt

# Prepare log and state dirs

install -d -m 0755 /var/log/ops
install -d -m 0755 /var/lib/ops-toolkit

# systemd units

install -m 0644 systemd/*.service /etc/systemd/system/
install -m 0644 systemd/*.timer /etc/systemd/system/

# Enable timers

systemctl daemon-reload
systemctl enable --now sys-health.timer
systemctl enable --now backup-verify.timer
systemctl enable --now log-clean.timer
systemctl enable --now cert-expiry-audit.timer
systemctl enable --now service-uptime.timer
systemctl enable --now tmp-clean.timer

```

## 🛠️ Uninstall (as root)

```bash
systemctl disable --now sys-health.timer backup-verify.timer log-clean.timer \
  cert-expiry-audit.timer service-uptime.timer tmp-clean.timer
systemctl daemon-reload
rm -f /etc/systemd/system/{sys-health,backup-verify,log-clean,cert-expiry-audit,service-uptime,tmp-clean}.{service,timer}
rm -f /usr/local/sbin/{sys-health.sh,backup-verify.sh,log-clean.sh,cert-expiry-audit.sh,service-uptime.sh,tmp-clean.sh,common.sh}

# Optional: keep /etc/ops for your customizations

```

## ⚙️ Configuration

Main config file: `/etc/ops/ops.conf`. Defaults are sensible; override as needed.

See `lists/services.txt` and `lists/ssl_endpoints.txt` for starter lists.

## Notes

- Scripts exit non-zero if acceptance criteria are not met; timers will show failures in `systemctl list-timers` and `journalctl -u <service>`.
- CSV outputs under `/var/log/ops` can be ingested later for trend analysis.
