# scripts/monitoring

Three standalone checkers, one deploy wrapper, and one SMART
harvester. Two checkers collect cron configuration (one host at a
time, or the whole fleet over SSH); the third verifies backup
integrity with SHA-256 manifests. The harvester collects
drive-health data. The checkers change nothing on the hosts they
inspect; the harvester writes only its report files; the deploy
wrapper is the one script here that changes state, and only on the
host it runs on.

## deploy-monitoring-stack.sh

Bash deploy wrapper for the cluster standby monitoring stack in
`containers/monitoring/` (Prometheus, Grafana, Alertmanager, Traefik,
ntfy, step-ca, Headscale, Vaultwarden, Uptime Kuma). The stack is
Docker-native by design; this is the local-run form of its
deployment, and the Ansible form is
`ansible/playbooks/monitoring/deploy-monitoring.yml`.

```bash
./deploy-monitoring-stack.sh              # validate, pull, up, verify
./deploy-monitoring-stack.sh --dry-run    # validate and render only
```

- Gates, in order, each failing loudly before anything starts:
  Docker with the Compose v2 plugin present, `.env` present with
  mode 600 expected, no `REPLACE_ME` placeholder left, and a
  non-empty `GRAFANA_ADMIN_PASSWORD` value, the three
  host-local configs (`ntfy.conf`, `headscale.conf`,
  `policy.hujson`) present, and `docker compose config` renders.
- Then: `docker compose pull` (unless `--skip-pull`), `docker
  compose up -d`, and a health loop that requires every service to
  report `(healthy)` within `--wait` seconds (default 120).
- `--project-dir DIR` deploys a checkout elsewhere; by default the
  project is `containers/monitoring/` relative to this script.

## smart-harvest.sh

The bash form of the SMART harvest: the Ansible form is
`ansible/playbooks/healthchecks/smart-harvest-v1.0.yml` and the
Docker form is `containers/health-smart/`. It collects SMART data
from every physical disk on the host it runs on and writes one
JSON report per host (`./smart-data/<host>.json` by default), with
the same fields as the Ansible form: per-drive device, rc, SMART
support, overall health, model, serial number, temperature, and
power-on hours, plus the full smartctl JSON.

```bash
sudo ./smart-harvest.sh                          # auto-discover via lsblk
sudo ./smart-harvest.sh /dev/sda                 # pinned drive list
sudo ./smart-harvest.sh --keep-history --extra-args "-d sat"
```

- Needs smartmontools and python3 on the host; both are checked up
  front and a missing one fails loudly before anything runs.
- Collection is read-only (`smartctl --json --all`, 60 second
  timeout per drive). Drives without SMART support are captured as
  unsupported rather than failing the run, and re-running
  overwrites the same report file — it never duplicates data.
- `--output-dir DIR` changes where reports land;
  `--keep-history` also keeps a dated copy under
  `<output-dir>/history/`.

## local_cron_checker.sh

Run on the host it audits. It collects, in one file:

- User crontabs for every account with UID 1000 or higher and a bash
  or sh login shell (`crontab -u <user> -l`)
- `/etc/crontab`
- Every file in `/etc/cron.d/`
- Listings of `/etc/cron.hourly`, `/etc/cron.daily`,
  `/etc/cron.weekly`, and `/etc/cron.monthly`

Output: `/var/log/cron_audit/local_cronjobs_YYYYMMDD_HHMMSS.log`,
created with mode 600. Reading other users' crontabs and writing
under `/var/log` require root.

## remote_cron_checker.sh

Run from one host; it SSHes to the six fleet addresses
(192.168.0.100 to 105, pi0 to pi4 and neo1) and collects the same
material from each into a single file,
`/var/log/cron_audit/cronjobs_full_YYYYMMDD_HHMMSS.log`, with one
section per host. A host that fails the 10-second SSH check is logged
as an error and skipped. One difference from the local checker: the
remote version collects crontabs for all users with UID 1000 or
higher, without the login-shell filter.

Both checkers suit an on-demand or scheduled audit. Every run writes
a new timestamped file; nothing is overwritten, so the directory
becomes the audit history.

## Backup manifest integrity

This folder no longer carries its own backup checker: the repo's
single SHA-256 manifest tool is
[`scripts/backups/backup_integrity_tool_v1.sh`](../backups/backup_integrity_tool_v1.sh)
(guide: [`backup_integrity_tool_guide-v1.md`](../backups/backup_integrity_tool_guide-v1.md)).
The former `local_backups_checker.sh` was removed on 2026-10-22
because the two tools wrote incompatible manifests that could not
verify each other's output. Note that any `backup.manifest` files
the old tool produced cannot be verified by the surviving tool;
regenerate manifests with the backups tool.
