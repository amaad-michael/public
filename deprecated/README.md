# deprecated

Files moved here in the 2026-09-18 reorganization (PR #3), a follow-up
pass on 2026-09-21, and a duplicate-consolidation pass on 2026-10-22,
because their filenames mark them as superseded (`_OLD`, `-old`, `.bak`,
`~`) or a successor has replaced them. Git history is intact: use
`git log --follow` on any file to see where it came from.

## 📦 Manifest

| File | Original path | Moved | Superseded by |
|------|---------------|-------|---------------|
| firewall_local_pi_OLD.yml | ansible/playbooks/maintenance/firewall/firewall_local_pi_OLD.yml | 2026-09-18 | ansible/playbooks/firewall/firewall_local_pi.yml |
| health_check_pihole_OLD.yml | ansible/playbooks/maintenance/healthchecks/health_check_pihole_OLD.yml | 2026-09-18 | health_check_pihole2.yml |
| health_check_universal_OLD.yml | ansible/playbooks/maintenance/healthchecks/health_check_universal_OLD.yml | 2026-09-18 | health_check_universal2.yml |
| pihole+unbound_OLD.yml | ansible/playbooks/maintenance/pihole/pihole+unbound_OLD.yml | 2026-09-18 | ansible/playbooks/pihole/ (attended and automated) and containers/pihole/ |
| docker-compose-old.yml | containers/docker-files-pihole-v1.1/docker-compose-old.yml | 2026-09-18 | containers/pihole/docker-compose.yml (the hardened v2) |
| cleanup_logs_pihole.yml | ansible/playbooks/cleanup/cleanup_logs_pihole.yml | 2026-09-21 | cleanup_logs_pihole2.yml |
| health_check_pihole.yml | ansible/playbooks/healthchecks/health_check_pihole.yml | 2026-09-21 | health_check_pihole2.yml |
| health_check_universal.yml | ansible/playbooks/healthchecks/health_check_universal.yml | 2026-09-21 | health_check_universal2.yml |
| cleanup_logs_pihole.sh | scripts/pihole/cleanup_logs_pihole.sh | 2026-09-21 | cleanup_logs_pihole2.sh |
| docker-compose-new.yml | containers/docker-files-pihole-v1.1/docker-compose-new.yml | 2026-09-21 | docker-compose.yml (renamed from pi-dns-docker-compose.yml, the hardened v2) |
| uninstall_pihole.yml | ansible/playbooks/cleanup/uninstall_pihole.yml | 2026-10-22 | ansible/playbooks/cleanup/uninstall_pihole2.yml (which also gained this file's gated final DNS check in the same pass) |
| new-nobara-setup-alt-v1.1.sh | scripts/workstation/new-nobara-setup-alt-v1.1.sh | 2026-10-22 | scripts/workstation/new-nobara-setup-v1.1.sh (its `gpu-high` subcommand was folded into the survivor) |
| neofetch_motd.yml | ansible/playbooks/motd/neofetch_motd.yml | 2026-10-22 | ansible/playbooks/motd/fastfetch_motd.yml |
