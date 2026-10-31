# Maintenance playbooks

Fleet upkeep playbooks: installs, rollouts, and recurring maintenance
that do not belong to a single service.

## node-exporter-rollout

`node-exporter-rollout/` installs Prometheus node_exporter on the
Raspberry Pi fleet (pi0 to pi4) as one Ansible run: checksum-verified
binary, hardened systemd unit, and port 9100 open only to the
Prometheus host (neo1, 192.168.0.105). See the README inside the
folder for pins, usage, and verification.
