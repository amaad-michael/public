# Observability playbooks

## neo1-observability.yml

The Ansible form of the neo1 observability node. It mirrors the
native kit in `scripts/provisioning/neo1-observability-native/`
exactly: same component versions and checksums, same ports, paths,
service users, systemd units, configs, UFW posture, and the same
always-on set. The Docker form of the same design is
`containers/neo1-observability-docker/`.

```bash
cd ansible
ansible-playbook -i hosts playbooks/observability/neo1-observability.yml -l neo1
```

- Always-on set (5): prometheus (9091), alertmanager (9093,
  loopback only), blackbox_exporter (9115, loopback only),
  node_exporter (9100), ntfy (8081). Grafana (3002) is installed but
  deliberately never enabled — on-demand sessions only, exactly as
  in the native kit. The two backup timers (03:15 / 03:30) are
  enabled with their services.
- Pins live at the top of the playbook and are copied verbatim from
  the native kit's `scripts/install.sh` (Prometheus 3.15.0,
  Alertmanager 0.34.1, blackbox_exporter 0.29.0, node_exporter
  1.12.1, ntfy 2.32.0, Grafana 13.2.4, linux-armv7 sha256 values).
  The play refuses to run with a blanked pin, and every download is
  checksum-verified, mirroring the kit's zero-guesswork gate. To
  bump a component, update its version and sha256 together from the
  same release's checksum file.
- The configs, systemd units, and helper scripts under `files/` are
  byte-identical copies of the native kit's files. The backup
  scripts land at `/usr/local/sbin/pihole-backup.sh` and
  `/usr/local/sbin/unbound-backup.sh`, as in the kit; the kit's
  `ufw.sh` and `verify.sh` are installed as
  `/usr/local/sbin/neo1-ufw.sh` and `/usr/local/sbin/neo1-verify.sh`
  for parity, while the playbook itself applies the same UFW rules
  through `community.general.ufw`.
- Out of scope, exactly as in the kit's deploy order: ntfy user and
  token provisioning (interactive, after first start — see the kit
  README) and placing the command-restricted backup SSH keys under
  `/home/backup/.ssh/`.

Options, all passed as extra vars:

| Option | Effect |
|---|---|
| `-e neo1_obs_arch=amd64` plus the matching `neo1_obs_*_sha256` values | Build for another architecture (lab and test runs) |
| `-e neo1_obs_manage_services=false` | Stage users, binaries, configs, and units without systemd changes (chroot and CI runs) |
| `-e neo1_obs_manage_firewall=false` | Skip the UFW tasks |
| `-e neo1_obs_lan=192.168.0.0/24` | LAN range the UFW allowances are scoped to (the kit default) |

After a real run, verify on the target with the same gate the
native kit uses: `sudo /usr/local/sbin/neo1-verify.sh` (14 checks),
after provisioning the ntfy token it checks for.
