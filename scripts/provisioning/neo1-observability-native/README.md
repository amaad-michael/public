# neo1 Observability Node — v2.6.1 (native systemd, ARMv7/512MB)

The bare-metal form of the neo1 observability node: the monitoring
design for one 512 MB ARMv7 box (neo1, 192.168.0.105, Armbian) as
static binaries under hardened systemd units — no Docker. The Docker
form of the same design (identical configs, probes, and alerts) is
`containers/neo1-observability-docker/`; the multi-service standby
stack for the cluster is `containers/monitoring/`.

**Design:** No Docker. Static Go binaries + hardened systemd units.
**Always-on set (5):** prometheus, alertmanager, blackbox_exporter, node_exporter, ntfy
**On-demand (1):** grafana — `systemctl start grafana`, auto-kills after 6h, never enabled
**Timers (2):** pihole-backup, unbound-backup (03:15 / 03:30 nightly)

## 💾 Memory budget (target)

| Set | Budget |
| --- | --- |
| Base OS + always-on 5 | ~385 MB |
| + Grafana session | ~585 MB (dips into zram — acceptable for sessions, hence on-demand) |
| verify.sh gate | steady-state < 420 MB |

## 🛠️ Deploy order

1. Review the pins at the top of `scripts/install.sh`. Versions and
   linux-armv7 sha256 values are filled in (resolved from the upstream
   release checksum files on 2026-10-18) and the script refuses to run
   if any is blanked. To bump a component, update its version and
   sha256 together from the same release's checksum file.
1. `sudo scripts/install.sh` (it locates the kit root itself; run as
   root). It creates the service users, installs the checksum-verified
   binaries (promtool and amtool alongside their daemons), the backup
   scripts, the configs, and the units, then enables the always-on
   set — grafana deliberately excluded.
1. Provision ntfy auth (deny-all is default-on):

   ```bash
   sudo -u ntfy ntfy user add alertmanager
   sudo -u ntfy ntfy access alertmanager alerts write-only
   sudo -u ntfy ntfy token add alertmanager     # -> /etc/alertmanager/ntfy.token (chmod 640 root:alertmanager)
   sudo -u ntfy ntfy user add phone             # subscriber account for your device
   sudo -u ntfy ntfy access phone alerts read-only
   ```

1. Place the command-restricted SSH keys for the backup scripts at
   `/home/backup/.ssh/pihole_backup` and `/home/backup/.ssh/unbound_backup`
   (mode 600, owned by `backup`).
1. `sudo scripts/ufw.sh`
1. **On-box lint (real linters, run before trusting):**

   ```bash
   promtool check config /etc/prometheus/prometheus.yml
   promtool check rules  /etc/prometheus/alert_rules.yml
   amtool  check-config  /etc/alertmanager/alertmanager.yml
   ```

   (promtool/amtool ship inside the prometheus/alertmanager release
   tarballs — install.sh installs them alongside the daemons.)
1. `sudo scripts/verify.sh` — 14 automated checks + manual alert
   round-trip.

## 📌 Open items (tracked, deliberate)

- **Dead-man's switch:** an always-firing Watchdog alert routed to an
  external check (peer node or hosted) is the only way to detect neo1
  itself dying. Add once a second node runs anything.
- `template=alertmanager` in alertmanager.yml requires a recent ntfy —
  the pinned v2.32.0 is current; fallback if rendering misbehaves:
  raw JSON (drop the query param).
- Backup scripts assume a command-restricted SSH key for user `backup`
  on pi-hole/unbound hosts (`command="..."` in authorized_keys) — set
  up per your OpSec standard.
- Post-FriendlyWrt/tailnet migration: tighten ufw.sh ntfy rule from
  LAN to tailnet CIDR (100.64.0.0/10).
- Fleet node_exporter rollout (pi0–pi4) is an Ansible play away;
  targets pre-stubbed in prometheus.yml.
