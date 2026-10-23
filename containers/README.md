# containers

Docker Compose stacks, one folder per project. Each project README
covers its own setup and verification; this page collects the one
pattern they share: files that live only on the deployment host.

## 📦 Host-side files (never committed)

Some stacks read configuration or secrets from files that exist only
on the host. A fresh clone will not have them, and the affected
services will not start until they exist. Keep every `.env` at
chmod 600. The pattern per project:

- **monitoring**: three configs the compose mounts, created on the
  host and git-ignored by name (ntfy.conf, headscale.conf,
  policy.hujson), plus a `.env` copied from `.env.example` holding
  GRAFANA_ADMIN_PASSWORD and the TRAEFIK_AUTH_HASH line. Compose
  refuses to start Grafana until the password variable is set.
- **pihole**: a `.env` copied from `pi-dns-env.example`, holding the
  image pins (PIHOLE_TAG, UNBOUND_TAG) and PIHOLE_API_PASSWORD.
  Compose refuses to render until both tags are pinned.
- **gitea**: a `.env` copied from `gitea-env.example`, holding
  GITEA_SECRET_KEY and GITEA_INTERNAL_TOKEN, plus GITEA_DOMAIN and
  GITEA_ROOT_URL. Compose refuses to start until both secrets are set.
- **jenkins**: no `.env` and no host-side secrets. The stack holds no
  credentials of its own; the first-run setup wizard generates the
  initial admin password inside the container.
- **lamp**: a `.env` copied from `lamp-env.example`, holding
  MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, MYSQL_USER, and
  MYSQL_PASSWORD. Compose refuses to start until the credentials are
  set.
- **llm**: a `.env` copied from `llm-env.example`, holding
  LLM_MODELS_DIR and the two model filenames (LLM_HEAVY_MODEL,
  LLM_LIGHT_MODEL), plus sizing and port options. Compose refuses to
  render while a model filename is unset.
- **gpu-llm**: a `.env` copied from `.env.example`. Four values are
  required (RENDER_GID, VIDEO_GID, WEBUI_SECRET_KEY, SEARXNG_SECRET)
  and compose refuses to render without them; the model list, ports,
  and keep-alive are optional overrides in the same file.
- **optiplex-llm**: no `.env` required. Every setting has a shipped
  default; `.env.example` documents the optional overrides.
- **cockpit**: no `.env` and no secrets by design. The stack holds no
  credentials; authentication happens at login, with each user's own
  account on the target host.
- **neo1-observability-docker**: a `.env` copied from `.env.example`
  (image pins pre-filled with the verified tags; set
  GRAFANA_ADMIN_PASSWORD), plus a `secrets/` directory created on the
  host holding `ntfy.token` and the backup SSH keys under `secrets/ssh/`.
  Compose refuses to start until the pins and the Grafana password are
  set.
- **scanner**: no `.env`. The image is built locally from the
  Dockerfile and run on demand.
- **health-smart**: no `.env` and no secrets. The collector mounts
  the repo's health scripts read-only from the checkout and writes
  reports to `./reports/` on the host; it needs host-device access
  (privileged, `/dev`, `pid: host`) — see its README.
