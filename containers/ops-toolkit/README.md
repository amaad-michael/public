# Ops Toolkit (container)

The same six Ops Toolkit jobs as `scripts/ops-toolkit/`, packaged in
an image with their scheduler. The job scripts in `scripts/` here are
byte-for-byte copies of the bash toolkit (same files that the Ansible
form installs on a host), and they run on the same wall-clock
schedule. What is **not** the same is the machine they act on — this
section states the limits plainly, because a scheduled host job in a
container is a partial equivalence, not a full one.

## 📦 Included jobs

| Job | Schedule (cron) | Source timer |
|---|---|---|
| `sys-health.sh` | Sun 04:00 | `Sun *-*-* 04:00:00` |
| `backup-verify.sh` | daily 03:30 | `*-*-* 03:30:00` |
| `log-clean.sh` | 1st of month 03:00 | `*-*-01 03:00:00` |
| `cert-expiry-audit.sh` | 1st of month 03:30 | `*-*-01 03:30:00` |
| `service-uptime.sh` | Sun 04:30 | `Sun *-*-* 04:30:00` |
| `tmp-clean.sh` | Mon 02:30 | `Mon *-*-* 02:30:00` |

## ⚠️ What this form can and cannot do

The scheduler inside the container is cron. Two systemd timer
properties have no cron equivalent and are **not** reproduced:

- `Persistent=true` — a timer that missed its slot while the host was
  off runs at next boot. A container that was stopped simply misses
  the run.
- `RandomizedDelaySec=15m` — the timers jitter their starts by up to
  15 minutes. The cron jobs start on the minute.

Job by job, against the container's own namespaces:

- **Works as on a host:** `cert-expiry-audit.sh` (it probes TLS
  endpoints over the network; the container's network is enough) and
  `backup-verify.sh` **when** the backup log and sample archive are
  mounted in at the paths `/etc/ops/ops.conf` names
  (`/var/log/backup/last.log`, `/backups/sample.tar.gz` by default).
- **Describes the container, not the host:** `sys-health.sh` samples
  the container's `/proc`, memory view, and root filesystem (which,
  under Docker's default limits, may show host-wide values or cgroup
  limits depending on the runtime — either way it is not the host
  health series the systemd form builds). `service-uptime.sh` checks
  services with the `service` fallback (there is no systemd in the
  container), so it reports on the container's init scripts — the
  container runs cron and little else, so most listed services will
  read as down. Treat both as tooling smoke tests in this form, not
  as host monitoring.
- **Acts on the container's files unless you mount the host's:**
  `log-clean.sh` and `tmp-clean.sh` prune `/var/log`, `/tmp`,
  `/var/tmp`, and `/var/cache` **inside the container**. They only
  clean the host's directories if those directories are bind-mounted
  in read-write — do that deliberately, because the scripts delete
  files by age with no confirmation.

For real host coverage, install one of the other two forms on the
host (bash or Ansible). This form is for running the toolkit's
portable jobs (certificate expiry, backup verification) from any
Docker host, and for exercising the scripts themselves.

## ✅ Build and verify

```bash
cd containers/ops-toolkit
docker compose build
docker compose run --rm ops-toolkit /usr/local/sbin/sys-health.sh
docker compose run --rm ops-toolkit /usr/local/sbin/tmp-clean.sh
```

A healthy run: `sys-health.sh` appends a row to
`/var/log/ops/sys-health.csv` (in the `ops_log` volume) and logs
`Health metrics captured`; `tmp-clean.sh` prints its completion line.

## 🔧 Usage

Run the scheduler (all six jobs on their schedule):

```bash
docker compose up -d
docker compose logs -f ops-toolkit
```

Run one job now, in a throwaway container:

```bash
docker compose run --rm ops-toolkit /usr/local/sbin/cert-expiry-audit.sh
```

Edit the endpoints and services lists in `/etc/ops` inside the
`ops_state`-style layout by replacing the files under `scripts/` and
rebuilding, or by bind-mounting your own copies over `/etc/ops/`.

Making `backup-verify` and the cleaners act on host paths — an
override file (`docker-compose.override.yml`, kept on the host):

```yaml
services:
  ops-toolkit:
    volumes:
      - /var/log/backup:/var/log/backup:ro
      - /backups:/backups:ro
```

Add host `/var/log`, `/tmp`, `/var/tmp`, or `/var/cache` binds the
same way only if you intend the container to delete aged files there.

## Notes

- The image runs as root: cron and the jobs need it (the host form's
  systemd units also run the scripts as root — no `User=` line). All
  capabilities are dropped except the setuid/setgid set cron needs.
- Config is the toolkit's own: `/etc/ops/ops.conf` in the image is the
  shipped `ops.conf`, and `load_config` honours the same overrides.
- The base image is `debian:bookworm-slim` pinned by digest in the
  Dockerfile (multi-arch: amd64 and arm64, so the Pis build the same
  image). Re-verify the digest before bumping it.
