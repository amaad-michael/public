# syntax=docker/dockerfile:1
# Fleet health + SMART collector — container form of the repo's
# health tooling: the bash SMART harvest
# (scripts/monitoring/smart-harvest.sh, the bash twin of
# ansible/playbooks/healthchecks/smart-harvest-v1.0.yml) and the
# toolkit health check
# (scripts/linux-admin-toolkit/08-health-check/health-check-local.sh).
#
# The image carries the tooling those scripts need: smartmontools
# (smartctl), util-linux (lsblk), python3 (the harvest's JSON
# assembly), and procps (free/ps for the health check). The scripts
# themselves are NOT copied in: the compose file bind-mounts them
# read-only from the repo checkout at runtime, the same pattern as
# containers/neo1-observability-docker's backup-runner, so the
# container can never drift from the repo's scripts.
#
# The base is pinned by digest, matching containers/scanner —
# re-verify the digest before bumping it.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

LABEL org.opencontainers.image.title="health-smart-collector" \
      org.opencontainers.image.description="One-shot fleet health + SMART collector (smartmontools + the repo health scripts, bind-mounted read-only)" \
      org.opencontainers.image.base.name="debian:bookworm-slim"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        procps \
        python3 \
        smartmontools \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
