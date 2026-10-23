# scripts

Utility scripts for the homelab, grouped by job. Each folder README is
the usage guide for the scripts in that folder.

- [backups](backups/backup_integrity_tool_guide-v1.md): SHA-256
  manifest integrity for backup directories
  (`backup_integrity_tool_v1.sh`).
- [gaming](gaming/README.md): lsfg-vk installer, Lossless Scaling frame
  generation on Nobara Linux.
- [git](git/README.md): new-box git configuration and a commit-and-push
  helper.
- [linux-admin-toolkit](linux-admin-toolkit/README.md): 27 everyday
  admin tasks, each as a local Bash script and a fleet Ansible
  playbook.
- [llm](llm/README.md): bare-metal LLM installers for the GPU box and
  the OptiPlex, a llama-ui container deploy, and the Open Terminal
  file service.
- [monitoring](monitoring/README.md): local and remote cron checkers
  for the fleet.
- [network](network/README.md): firewall audit and host firewall
  setup, plus the nmap scan set (ad hoc, hourly, monthly, vuln).
- [ops-toolkit](ops-toolkit/README.md): six Bash jobs with systemd
  timers: system health, backup verification, log cleanup, certificate
  expiry, service uptime, temp cleanup.
- [pihole](pihole/README.md): Pi-hole + Unbound DNS test suite, log
  cleanup, and blocklist initialization.
- [provisioning](provisioning/README.md): Gitea, Jenkins, and LAMP
  installers, the Gitea post-setup tightening scripts, and the LUKS
  Vault Guardian.
- [security](security/README.md): the secure-server-init hardening
  family, SSH access tooling, and repo-public-check.
- [workstation](workstation/README.md): Nobara setup, the GPU box
  and OptiPlex update scripts, and the laptop role-prep pair.

Also at this level: `run_monthly_maintenance.sh`, the wrapper that
runs the monthly maintenance playbooks (see
[ansible/README.md](../ansible/README.md)) and logs to
`scripts/logs/maintenance.log`; and `fleet-reboot.sh`, the bash
form of the reboot playbooks (see
[ansible/playbooks/reboots](../ansible/playbooks/reboots/README.md)),
which reboots the fleet one host at a time over SSH with the
playbooks' pre-check, 600-second return wait, and `whoami`
confirmation.
