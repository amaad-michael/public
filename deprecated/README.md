# deprecated

Files moved here by `organize-public-repo.sh` because their filenames mark them
as superseded (`_OLD`, `-old`, `.bak`, `~`). Git history is intact — use
`git log --follow` on any file to see where it came from.

## Manifest

| File | Original path | Moved | Superseded by |
|------|---------------|-------|---------------|
| firewall_local_pi_OLD.yml | ansible/playbooks/maintenance/firewall/firewall_local_pi_OLD.yml | 2026-09-18 |  |
| health_check_pihole_OLD.yml | ansible/playbooks/maintenance/healthchecks/health_check_pihole_OLD.yml | 2026-09-18 |  |
| health_check_universal_OLD.yml | ansible/playbooks/maintenance/healthchecks/health_check_universal_OLD.yml | 2026-09-18 |  |
| pihole+unbound_OLD.yml | ansible/playbooks/maintenance/pihole/pihole+unbound_OLD.yml | 2026-09-18 |  |
| docker-compose-old.yml | containers/docker-files-pihole-v1.1/docker-compose-old.yml | 2026-09-18 |  |
| cleanup_logs_pihole.yml | ansible/playbooks/cleanup/cleanup_logs_pihole.yml | 2026-09-21 | cleanup_logs_pihole2.yml |
| health_check_pihole.yml | ansible/playbooks/healthchecks/health_check_pihole.yml | 2026-09-21 | health_check_pihole2.yml |
| health_check_universal.yml | ansible/playbooks/healthchecks/health_check_universal.yml | 2026-09-21 | health_check_universal2.yml |
| cleanup_logs_pihole.sh | scripts/pihole/cleanup_logs_pihole.sh | 2026-09-21 | cleanup_logs_pihole2.sh |
| docker-compose-new.yml | containers/docker-files-pihole-v1.1/docker-compose-new.yml | 2026-09-21 | docker-compose.yml (renamed from pi-dns-docker-compose.yml, the hardened v2) |
