# neo1-observability-docker — single-node observability for neo1

The Docker form of the neo1 observability node: the whole monitoring
design for one 512 MB ARMv7 box (neo1, 192.168.0.105, Armbian) in a
single compose project. Same configs, same probes, same alerts as the
bare-metal form in `scripts/provisioning/neo1-observability-native/` —
the runtime is swapped to Docker, nothing else.

This is the single-node variant. The multi-service standby stack for
the cluster lives in `containers/monitoring/`. As of 2026-10-18, neo1
itself runs the native systemd form
(`scripts/provisioning/neo1-observability-native/`); this Docker form
is the alternative on the same ports, is not deployed, and would
replace the native form on a host rather than run beside it.

**Always-on (6 containers):** prometheus, alertmanager, blackbox,
node_exporter, ntfy, backup-runner
**Profile-gated (1):** grafana — `docker compose --profile dashboard up -d grafana`; stop manually when done
**Backups:** crond inside backup-runner (03:15 pihole, 03:30 unbound), SSH-only, NO docker.sock

Shipped files not named elsewhere here: the service configs
`configs/blackbox.yml`, `configs/grafana.ini`, and
`configs/ntfy-server.yml`; the backup jobs `scripts/pihole-backup.sh`
and `scripts/unbound-backup.sh`; and the backup-runner image
definition, `backup-runner/Dockerfile` with `backup-runner/crontab`.

## 🌐 Why host networking everywhere

Docker's published-port iptables chains bypass UFW. `network_mode: host`
on all services keeps UFW authoritative and makes the loopback binds
(9093/9115) real. No `ports:` blocks exist in this compose — verify.sh
enforces both properties.

## 💾 Memory budget

| Set | Budget |
| --- | --- |
| Base OS + dockerd + always-on 6 | ~460 MB (verify.sh gate: <460 used) |
| + Grafana session | over-budget into zram — sessions only, stop when done |

## 🛠️ Deploy order

1. `cp .env.example .env && chmod 600 .env` — the tags in the example
   were pinned 2026-10-18 after verifying (registry API) that each
   publishes a linux/arm/v7 manifest, Grafana included. Re-verify
   before any bump (`docker manifest inspect <image>:<tag>`). Grafana
   especially: if a future tag has no armv7 build, run Grafana on the
   workstation instead (datasource -> neo1:9091).
1. Pre-create secrets (MUST exist as files before first `up -d`, or
   docker creates directories at the mount paths and alertmanager can
   never read the token):

   ```bash
   mkdir -p secrets/ssh
   install -m 600 /dev/null secrets/ntfy.token
   # place pihole_backup, unbound_backup keys (600) + known_hosts (pi4+pi0
   # host keys, e.g. ssh-keyscan 192.168.0.104 192.168.0.100) in secrets/ssh/
   ```

1. Lint configs BEFORE first start (uses the pinned images, no install
   needed):

   ```bash
   docker run --rm -v ./configs:/c:ro --entrypoint promtool prom/prometheus:$PROM_TAG check config /c/prometheus.yml
   docker run --rm -v ./configs:/c:ro --entrypoint promtool prom/prometheus:$PROM_TAG check rules /c/alert_rules.yml
   docker run --rm -v ./configs:/c:ro --entrypoint amtool prom/alertmanager:$AM_TAG check-config /c/alertmanager.yml
   ```

1. `docker compose up -d` (grafana excluded automatically by profile).
1. Provision ntfy auth (deny-all default):

   ```bash
   docker exec neo1-ntfy ntfy user add alertmanager
   docker exec neo1-ntfy ntfy access alertmanager alerts write-only
   docker exec neo1-ntfy ntfy token add alertmanager \
     | grep -o 'tk_[A-Za-z0-9]*' > secrets/ntfy.token && chmod 600 secrets/ntfy.token
   docker exec neo1-ntfy ntfy user add phone && docker exec neo1-ntfy ntfy access phone alerts read-only
   docker compose restart alertmanager                 # picks up mounted token
   ```

1. `sudo scripts/ufw.sh`
1. `scripts/verify.sh` — 21 automated checks + 2 manual gates.

## 🔧 Ops

| Action | Command |
| --- | --- |
| Dashboard session | `docker compose --profile dashboard up -d grafana` / `docker compose stop grafana` |
| Logs | `docker compose logs -f --tail 100 <svc>` |
| Wipe & rebuild | `docker compose down -v && docker compose up -d` (backups volume dies too — export first) |
| Update a pin | edit .env -> `docker compose up -d <svc>` |

## 📌 Open items (carried from the native design, still true)

- Dead-man's switch: external Watchdog route once a second node runs
  anything.
- ntfy `template=alertmanager` — the pinned ntfy (v2.32.0) is current;
  if rendering misbehaves, the fallback is raw JSON (drop the query
  param in configs/alertmanager.yml).
- Fleet node_exporter rollout to pi0–pi4 (targets are hot in
  prometheus.yml — comment out per-node until deployed or NodeDown
  fires immediately).
- Post-tailnet migration: tighten ufw ntfy rule to 100.64.0.0/10.

## ⚖️ Docker vs native tradeoff (recorded)

- \+ cleaner wipe/rebuild, per-service image pinning, no host binary
  management
- \- ~80–100MB dockerd tax on a 512MB box, armv7 image availability
  risk (Grafana), UFW/iptables interaction requires the host-net
  discipline this file enforces
