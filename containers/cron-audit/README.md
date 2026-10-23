# Fleet cron audit (container)

A run-on-demand collector that produces the cron audit report of
`scripts/monitoring/local_cron_checker.sh` and
`remote_cron_checker.sh` (Ansible form:
`ansible/playbooks/audits/cron_audit.yml`) from a container. It
collects user crontabs (UID 1000+, bash/sh login shell — the local
checker's filter), `/etc/crontab`, every file in `/etc/cron.d/`, and
listings of the four cron period directories, and flags
world-writable cron files and cron entries executing from `/tmp`,
`/var/tmp`, or `/dev/shm`.

## 🌐 Access model: how host cron state reaches a container

A container sees none of the host's cron state by default. This
project supports the two honest ways in — pick per run:

**Mounted mode (default).** The host's `/etc` and `/var/spool/cron`
are bind-mounted read-only at `/host`, and the collector reads the
files directly, including both spool layouts (RHEL keeps per-user
files in `/var/spool/cron/`; Debian keeps them in
`/var/spool/cron/crontabs/`). Limits of this mode, stated plainly:

- It reads **this** host only — the one whose directories are
  mounted. Fleet coverage means running it per host, or using SSH
  mode / the Ansible form.
- It **cannot read systemd timer state**: timers live in the host's
  running systemd, not in files under the mounts. The report's timer
  section says exactly that instead of printing an empty list that
  would look like "no timers".
- It runs as root because host spools are root-only (0700/0600). The
  mounts are read-only; the collector changes nothing.

**SSH mode.** The collector SSHes to each named host and runs the
same collection there, like the bash remote checker (10-second
connect timeout; unreachable hosts are logged as `ERROR` and
skipped). This mode **does** include `systemctl list-timers` output.
It needs an SSH key the targets accept — mount one read-only in an
override file, never bake it into the image:

```yaml
services:
  cron-audit:
    volumes:
      - ~/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro
      - ~/.ssh/known_hosts:/root/.ssh/known_hosts:ro
```

## ✅ Build and verify

```bash
cd containers/cron-audit
docker compose build
docker compose run --rm cron-audit --root /host
```

A healthy run prints the sectioned report for the host whose
directories are mounted and ends with `Cron job collection complete.`

## 🔧 Usage

Mounted mode, report saved to a file (mode 0600, like the bash
checkers' logs):

```bash
docker compose run --rm cron-audit --root /host --output /tmp/cron-report.log
```

SSH mode, whole fleet (addresses from `ansible/hosts`):

```bash
docker compose run --rm cron-audit --ssh 192.168.0.100 192.168.0.101 192.168.0.102 192.168.0.103 192.168.0.104 192.168.0.105
```

## Notes

- Nothing is scheduled and nothing is a daemon: like the bash
  checkers, each run is one collection. Scheduling it is the
  operator's cron/systemd choice on the Docker host.
- The base image is `debian:bookworm-slim` pinned by digest in the
  Dockerfile (multi-arch: amd64 and arm64, so the Pis build the same
  image). Re-verify the digest before bumping it.
