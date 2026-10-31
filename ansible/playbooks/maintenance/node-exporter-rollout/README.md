# node_exporter fleet rollout

Ansible playbook that installs Prometheus node_exporter on the
Raspberry Pi fleet (pi0 to pi4, mixed Debian-family and Rocky, mixed
arm64 and armv7) in a single run.

Strategy: the official static binary plus a hardened systemd unit,
identical on every node. OS branches exist only where the fleet
actually differs: firewall (firewalld rich rule on Rocky, ufw on
Debian) and the SELinux relabel on the RedHat family.

## Pins

- node_exporter 1.12.1, the same version the neo1 observability
  stack runs (see `scripts/provisioning/neo1-observability-native/`).
- sha256 per architecture in `group_vars/all.yml`, taken from the
  official v1.12.1 `sha256sums.txt` on the prometheus/node_exporter
  GitHub release.
- The play refuses to run with a blank version or a missing
  checksum for a node's architecture. armv6 stays blank: no such
  host in the fleet.

## Run

```bash
cd ansible/playbooks/maintenance/node-exporter-rollout
ansible-playbook -i inventory.ini playbook.yml --limit pi0,pi1,pi2,pi4
```

The inventory covers pi0 to pi4 at 192.168.0.100 to 192.168.0.104.
The playbook is idempotent, so a later full run safely picks up any
node that was down or not yet built.

## What it does

- Creates the `nodeexp` system user.
- Downloads the release tarball for the node's architecture and
  verifies its sha256 before installing to /usr/local/bin.
- Installs the systemd unit from `templates/` (no new privileges,
  strict system protection, 48M memory cap) and enables the service.
- Opens tcp/9100 only to 192.168.0.105 (neo1). A Debian node without
  ufw gets a warning instead of a rule.
- Checks `http://127.0.0.1:9100/metrics` on the node itself, then
  cleans up the download.

## Verify

From neo1, every fleet node should answer on 9100, and the node job
in Prometheus (192.168.0.105:9091) should show all targets UP.
