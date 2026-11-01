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
  policy.hujson), plus a `.env` copied from `.env.example` holding GRAFANA_ADMIN_PASSWORD, with a TRAEFIK_AUTH_HASH line added to it (generation: see the monitoring README). Compose refuses to start Grafana until the password variable is set.
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
- **backup-integrity**: no `.env` and no secrets. The image is built
  locally and run on demand against a data directory
  (`BACKUP_INTEGRITY_DIR`, default `./data`).
- **cron-audit**: no `.env` and no secrets. The image is built locally;
  the host's cron configuration is mounted read-only at `/host`.
- **firewall-audit**: no `.env` and no secrets. The image is built
  locally and runs with host networking (`network_mode: host`,
  CAP_NET_ADMIN) against the host's firewall, with its configuration
  directories mounted read-only.
- **ops-toolkit**: no `.env` and no secrets. The image is built locally;
  configuration ships in the image and output persists in named
  volumes (`ops_log`, `ops_state`).
- **open-terminal**: a `.env` copied from
  `open-terminal-env.example`, holding OPEN_TERMINAL_API_KEY (the
  key the bash form generates at
  `/var/lib/open-terminal/api_key.txt`; reuse that value when
  switching forms) and optionally OPEN_TERMINAL_WORKSPACE. Compose
  refuses to start until the API key is set.

## 🐳 Running these stacks on Rocky with Podman

> **Status: UNTESTED (2026-10-31).** Nothing in this section has
> been run yet. The stacks are developed and verified against
> Docker on Debian-family hosts. The first proof is the pi3
> shakedown, after pi3's rebuild puts a Rocky host with Podman
> into service; until then, treat every behavioral statement
> below as an expectation to verify, not a result.

Rocky does not ship Docker; its native container engine is
Podman. These stacks can in principle run under it, with the
following known considerations.

### Prerequisites

- **podman**: in the base Rocky repositories.
- **podman-compose**: in EPEL. It reimplements the Compose spec
  for Podman; the stacks are written against Docker Compose, so
  its fidelity is the main open question (see the watch items
  below).
- **podman-docker** (optional): a shim that provides the
  `docker` command name on top of Podman, useful because this
  repo's tooling calls `docker` (see the tooling caveat below).

### Run rootful

The stacks were written for rootful Docker. Run them rootful
under Podman as well. Rootless Podman is a fine tool, but it
networks differently (unprivileged ports, user-mode
networking), and these compose files were not written or
tested for that mode.

### SELinux and bind mounts (the main expected friction)

Rocky enforces SELinux. Most compose files here bind-mount
host files or directories into the containers (config files,
site content, scripts). Those mounts were written for
Debian-family Docker hosts, where nothing labels them, and
SELinux will deny the container access until the content is
relabeled.

- Append `:Z` to a bind mount to have its content relabeled
  privately for that container, or `:z` to share the label
  between containers. Which one is right depends on whether
  anything else needs the same content; when in doubt, prefer
  `:Z` on content only that stack uses.
- Named volumes need no action: Podman labels them
  automatically.

Stacks whose compose files bind-mount host paths, from a
survey of every `containers/*/docker-compose.yml` on
2026-10-31: backup-integrity, cockpit, cron-audit,
firewall-audit, gitea, gpu-llm, health-smart, lamp, llm,
monitoring, neo1-observability-docker, open-terminal,
optiplex-llm, pihole. Stacks that use only named volumes and
have no bind mounts to relabel: jenkins, ops-toolkit, scanner.

Some bind mounts are special cases worth a second look before
relabeling: cron-audit mounts the host's `/etc` and
`/var/spool/cron`, firewall-audit mounts `/etc/firewalld`,
and neo1-observability-docker mounts the host root filesystem
read-only. Relabeling shared system directories affects the
host, not just the container; these three need an explicit
decision during the shakedown rather than a mechanical `:Z`.

### Compose-fidelity watch items (unverified)

podman-compose covers most of the Compose spec, but the
following features used in this repo are the ones to test
first, because they are historically the least uniformly
implemented. Each is an expectation to verify during the
shakedown, not a known failure:

- `depends_on` with `condition: service_healthy` (gpu-llm,
  lamp, llm, pihole)
- healthchecks (cockpit, gitea, gpu-llm, jenkins, lamp, llm,
  monitoring, neo1-observability-docker, open-terminal,
  optiplex-llm, pihole)
- required-variable interpolation, `${VAR:?}` (gitea,
  gpu-llm, lamp, llm, monitoring, neo1-observability-docker,
  open-terminal, pihole)
- `build:` sections (backup-integrity, cron-audit,
  firewall-audit, health-smart, lamp,
  neo1-observability-docker, ops-toolkit, scanner)
- the Docker API socket: monitoring's Traefik service mounts
  `/var/run/docker.sock` and reads container state from it.
  Under Podman the equivalent is the Podman API socket, at a
  different path and with its own compatibility surface; that
  wiring is untested.

### Tooling caveat

This repo's lifecycle tooling (the stack controllers and the
teardown engine) invokes `docker compose`, and the teardown
engine parses `docker compose config` JSON output to build
its removal plan. Under the podman-docker shim the simple
verbs translate, but state reporting and the JSON render
under Podman are unverified. Until the shakedown proves
otherwise, treat controller status and verification output
on a Podman host as unreliable, and read the engine's plan
output carefully before confirming any teardown there.
