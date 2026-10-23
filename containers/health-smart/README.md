# Fleet health + SMART collector

The Docker form of the fleet health checks and SMART harvest. It
runs the repo's own scripts in a one-shot collector container: the
bash SMART harvest (`scripts/monitoring/smart-harvest.sh`, twin of
`ansible/playbooks/healthchecks/smart-harvest-v1.0.yml`) and the
toolkit health check
(`scripts/linux-admin-toolkit/08-health-check/health-check-local.sh`).

## 📦 Files

- `docker-compose.yml`: the one-shot collector service, with the
  host-access requirements spelled out in its header.
- `Dockerfile`: Debian bookworm-slim (digest-pinned, matching
  `containers/scanner`) plus smartmontools, util-linux, python3,
  and procps — the tooling the scripts need.
- `entrypoint.sh`: runs the harvest, then the health check, and
  fails loudly if the script mounts are absent.

## ⚙️ How it works

The scripts are not copied into the image. The compose file
bind-mounts them read-only from the repo checkout
(`../../scripts/...`), the same pattern as the neo1 Docker kit's
backup-runner, so the container always runs exactly the repo's
code. Run it from a checkout of the repo:

```bash
cd containers/health-smart
docker compose build
docker compose run --rm health-smart            # all drives
docker compose run --rm health-smart /dev/sda   # one drive
```

Reports land in `./reports/` on the host:

- `reports/smart-data/<host>.json` — the harvest report, same
  fields as the Ansible and bash forms (per-drive device, rc,
  supported, health, model, serial, temperature, power-on hours,
  plus the full smartctl JSON).
- `reports/health-check.txt` — the toolkit health check output.

## ⚠️ Host-device access (honest requirements)

SMART queries are ioctls against the host's physical drives;
there is no unprivileged container form of that. This project
therefore runs with `privileged: true`, the host's `/dev` mounted
through (smartctl opens drive nodes read-write), and `pid: host`
(so the hostname and `/proc` state describe the host, not the
container). Treat the collector accordingly:

- Run it one-shot on a host you control, and let
  `docker compose run --rm` remove it afterwards. It is not a
  daemon and has no `restart` policy, ports, or network need.
- Arguments after the service name pass straight through to
  `smart-harvest.sh`, so drives behind USB enclosures work the
  same as in the other forms:
  `docker compose run --rm health-smart --extra-args "-d sat" /dev/sda`.
  SD cards and unsupported enclosures are reported as
  unsupported, exactly as in the other two forms.

## ✅ Verify

- `docker compose config` renders clean.
- A run on a host with at least one SMART drive produces a
  `reports/smart-data/<host>.json` whose drives carry real model,
  serial, temperature, and power-on-hours values; a run with the
  script mounts removed fails loudly at the entrypoint instead of
  reporting an empty success.
