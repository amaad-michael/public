# neo1 Observability Node — v2.6.2 (native systemd, ARMv7/512MB)

The bare-metal form of the neo1 observability node: the monitoring
design for one 512 MB ARMv7 box (neo1, 192.168.0.105, Armbian) as
static binaries under hardened systemd units — no Docker. The Docker
form of the same design (identical configs, probes, and alerts) is
`containers/neo1-observability-docker/`; the multi-service standby
stack for the cluster is `containers/monitoring/`.

**Design:** No Docker. Static Go binaries + hardened systemd units.
**Always-on set (5):** prometheus, alertmanager, blackbox_exporter, node_exporter, ntfy
**On-demand (1):** grafana — `systemctl start grafana`, auto-kills after 6h, never enabled. Its admin password lives in `/etc/grafana/grafana.env` (root-only, created by the installer); the unit refuses to start without that file, so a session can never come up on the factory password
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
   root). Downloads stage in `${TMPDIR:-/tmp}/neo1-dl`; the six
   tarballs total ~602 MiB, so the installer checks free space on
   that filesystem before downloading and fails early if the set
   cannot fit. On neo1, whose /tmp is a 243 MB tmpfs, run it as
   `sudo TMPDIR=/var/tmp scripts/install.sh`. It creates the service users, installs the checksum-verified
   binaries (promtool and amtool alongside their daemons), the backup
   scripts, the configs, and the units, then enables the always-on set plus the two backup timers — grafana deliberately excluded.
1. Provision ntfy auth (deny-all is default-on):

   ```bash
   sudo -u ntfy ntfy user add alertmanager
   sudo -u ntfy ntfy access alertmanager alerts write-only
   sudo -u ntfy ntfy token add alertmanager | grep -o 'tk_[A-Za-z0-9]*' | sudo tee /etc/alertmanager/ntfy.token >/dev/null  # then: sudo chown root:alertmanager /etc/alertmanager/ntfy.token && sudo chmod 640 /etc/alertmanager/ntfy.token
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

## 🔁 Day-2 operation

`scripts/neo1-observability-stack.sh` brings the stack up or
down as a unit: `up [--with-grafana]`, `down`, `restart`, and
`status` (exit 1 when a core unit is down; Grafana is started
only with `--with-grafana` and is always stopped by `down`).
The up/down verbs start and stop units only — they never enable
or disable them, so boot behaviour stays exactly as install.sh
left it. `--dry-run` prints the systemctl commands without
running them.
The script also carries an `uninstall [--dry-run] [--purge]`
verb, the kit's removal path: it prints a labeled plan, asks
for a typed confirmation, then removes every unit install.sh
installed (the pihole-backup and unbound-backup services and
timers included), the binaries, the Grafana tree, and the
configs. The data directories and the Pi-hole/Unbound backup
copies are preserved unless `--purge` is given; `--purge` also
removes the kit's service accounts.
Run with no arguments on a terminal, the script opens an
interactive panel instead: the live status table on top and an
action menu (Up, Up with Grafana, Down, Restart, Uninstall,
Refresh, Quit) below it, driving the same code paths as the
subcommands. With no terminal (or TERM=dumb) the no-argument
form prints usage and exits 2, as before.

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
- Fleet node_exporter rollout (pi0–pi4) is an Ansible play away; the pi0–pi4 targets in prometheus.yml are already live (uncommented), so NodeDown fires for a node until its exporter is deployed.
