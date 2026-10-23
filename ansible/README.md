# ansible

Ansible content for the homelab fleet: pi0 to pi4 plus neo1, in the
`hosts` inventory (groups `pi_all`, `pi_debian`, `pi_rhel`, `pi_dns`,
`pi_monitoring`, `pi_lamp`; `ansible_user` is michael). `ansible.cfg`
points at that inventory by default. Collection requirements are in
`requirements.yml` (community.docker, community.general, ansible.posix):

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

Playbooks are grouped by job under `playbooks/`. Most groups have a README that is the usage guide for its playbooks (motd is the exception — see its entry below):

- [accounts](playbooks/accounts/README.md): credential cycling and
  account removal. The fleet password-cycle kit has its own guide at
  [password-cycle](playbooks/accounts/password-cycle/README.md).
- [audits](playbooks/audits/README.md): read-only fleet audits
  (the cron audit; the firewall audit lives under firewall/),
  assembled into timestamped reports on the controller.
- [backups](playbooks/backups/README.md): backup integrity —
  generates and verifies the same SHA-256 manifests as the bash tool.
- [cleanup](playbooks/cleanup/README.md): log cleanup, update
  disabling, and the uninstall playbooks (Jenkins, Pi-hole). These
  remove things; read the guide first.
- [cockpit](playbooks/cockpit/README.md): Cockpit install and the PCP
  performance collection setup.
- [firewall](playbooks/firewall/README.md): the firewalld playbooks
  and which hosts each one targets.
- [gitea](playbooks/gitea/README.md): the primary-host Gitea install
  and tighten playbook, mirroring `scripts/provisioning/install-gitea.sh`
  and its tighten script (not the mirror container).
- [healthchecks](playbooks/healthchecks/README.md): the fleet health
  checks and the SMART harvest.
- [lamp](playbooks/lamp/README.md): the LAMP stack (Apache, PHP-FPM,
  MariaDB) on the Debian and RHEL families — the Ansible form of the
  two `scripts/provisioning/lamp-install-*.sh` installers.
- [jenkins](playbooks/jenkins/README.md): the Jenkins LTS install
  playbook, mirroring `scripts/provisioning/install-jenkins-rocky.sh`.
- [llm](playbooks/llm/README.md): the NanoPi inference fleet (server
  and load balancer), plus the two full deployment guides,
  [gpu-box-llm-setup-v2.2.md](playbooks/llm/gpu-box-llm-setup-v2.2.md)
  and [optiplex-llm-v2.3.md](playbooks/llm/optiplex-llm-v2.3.md).
- [monitoring](playbooks/monitoring/README.md): the deploy playbook
  for the standby monitoring stack in `containers/monitoring/`
  (a wrapper around its compose project, not a re-implementation).
- [observability](playbooks/observability/README.md): the neo1
  observability stack (Prometheus, Alertmanager, blackbox_exporter,
  node_exporter, ntfy, on-demand Grafana) — the Ansible form of the
  native kit in `scripts/provisioning/neo1-observability-native/`.
- [ops-toolkit](playbooks/ops-toolkit/README.md): installs the Ops
  Toolkit's six job scripts, its configuration, and its systemd
  timer/service pairs onto a target host.
- [monthly](playbooks/monthly/README.md): monthly patching for the
  fleet, Nobara, and the Pi-hole hosts, driven by
  `scripts/run_monthly_maintenance.sh`.
- [motd](playbooks/motd/): login banners (fastfetch on login), plus
  the hosts file and MOTD updater. Small enough to read directly;
  no group guide.
- [pihole](playbooks/pihole/README.md): Pi-hole + Unbound, attended
  and automated variants.
- [proxmox](playbooks/proxmox/README.md): Proxmox VE install,
  hardening, and template builds on a bare Debian host.
- [reboots](playbooks/reboots/README.md): simple and complex fleet
  reboot playbooks.
- [security](playbooks/security/README.md): the secure-server-init
  hardening baseline as a single playbook, plus the SSH access
  toolkit form.
- [vuln](playbooks/vuln/README.md): the scanner node setup and the
  Nmap scan playbook.
- [workstation](playbooks/workstation/): the Nobara first-boot
  setup (`nobara_first_boot.yml`, the Ansible form of the bash
  first-boot script); its usage header is the guide. Recurring
  Nobara patching lives in the monthly group
  (`monthly_maint_nobara.yml`).

---
Copyright (c) Michael Tatum.
