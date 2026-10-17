# containers

code for docker and podman

## Host-local files (never committed)

Three files the monitoring compose mounts are created on the host and are
git-ignored by name — a fresh clone will not have them, and those services
will not start until they exist:

- containers/monitoring/ntfy.conf — ntfy server config
- containers/monitoring/headscale.conf — headscale config
- containers/monitoring/policy.hujson — headscale ACL policy

The Grafana admin password is likewise host-side: copy
containers/monitoring/.env.example to containers/monitoring/.env, set
GRAFANA_ADMIN_PASSWORD there, and chmod 600 the .env. Compose refuses to
start Grafana until the variable is set. The pihole project follows the
same pattern (see containers/pihole/pi-dns-env.example).
