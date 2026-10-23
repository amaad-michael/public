# Monitoring playbooks

## deploy-monitoring.yml

The Ansible deploy playbook for the cluster standby monitoring
stack in `containers/monitoring/` (Prometheus 2.45, Grafana 10.2,
Alertmanager 0.26, Traefik, ntfy, step-ca, Headscale, Vaultwarden,
Uptime Kuma on `standby-net`). The bash form of the same deployment
is `scripts/monitoring/deploy-monitoring-stack.sh`.

```bash
cd ansible
ansible-playbook -i hosts playbooks/monitoring/deploy-monitoring.yml -l <host> \
  -e monitoring_project_dir=/path/to/repo/containers/monitoring
```

- The stack is Docker-native by design, and this playbook is a
  deploy wrapper around its compose project, not a
  re-implementation: it validates the host-side files on the
  target, renders the project, pulls the pinned images, brings
  the stack up, and verifies every service reports healthy.
- The checkout must already exist on the target at
  `monitoring_project_dir` (the playbook does not clone), and
  Docker with the Compose v2 plugin must already be installed
  there.
- Gates, in order, each failing loudly: project directory set,
  compose file present, `docker compose version` works, `.env`
  present with no `REPLACE_ME` placeholder left and a non-empty
  `GRAFANA_ADMIN_PASSWORD` value, the three
  host-local configs (`ntfy.conf`, `headscale.conf`,
  `policy.hujson`) present, and `docker compose config -q`
  renders clean.

Options, all passed as extra vars:

| Option | Effect |
|---|---|
| `-e monitoring_project_dir=<path>` | Required: the `containers/monitoring` checkout on the target |
| `-e monitoring_dry_run=true` | Checks and render only; prints the plan, deploys nothing |
| `-e monitoring_skip_pull=true` | Skip `docker compose pull` (images already on the host) |
| `-e monitoring_wait_seconds=120` | Health verification budget (default 120) |
